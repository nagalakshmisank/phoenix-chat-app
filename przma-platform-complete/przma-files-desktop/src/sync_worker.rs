// przma-files-desktop/src/sync_worker.rs
//
// Background sync worker - pushes all pending files to the backend when online.
//
// Sync behavior:
//   • Core files: uploaded to object store (encrypted locally with OS keychain key)
//   • Commons/Circle: uploaded to backend database (shareable when online)
//   • Offline: files queue locally, no sync attempted; automatic retry when online
//
// Design:
//   • Event-driven: an upload or a reconnect calls `trigger()`, which wakes the
//     loop immediately. A 30s periodic tick is a safety net.
//   • Online-aware: respects is_online flag before syncing; completely skipped offline
//   • Pooled HTTP: one reqwest::Client is reused for all requests (connection
//     keep-alive), instead of building a fresh client per request.
//   • Bounded parallelism: up to MAX_CONCURRENT files sync at once.
//   • Streamed uploads: each blob streams from disk into the HTTP body — never
//     fully buffered in memory.
//   • Lock discipline: the FilesService mutex is only held for short local DB
//     reads/writes, never across network IO.
//   • Periodic compaction: after activity, the Lance tables are compacted on a
//     tick to merge fragment files.

use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use tokio::sync::{Mutex, Notify};
use tokio::time::{sleep, Duration};

use futures::StreamExt;

use przma_files::FilesService;
use przma_platform::namespace::Space;
use przma_platform::CasUri;

/// Periodic safety-net tick. Real work is normally driven by `trigger()`.
const FALLBACK_TICK_SECS: u64 = 30;
/// Max files syncing concurrently.
const MAX_CONCURRENT: usize = 4;

// ═════════════════════════════════════════════════════════════════════════════
// SYNC WORKER
// ═════════════════════════════════════════════════════════════════════════════

pub struct SyncWorker {
    service: Arc<Mutex<Option<FilesService>>>,
    backend_url: String,
    is_online: Arc<AtomicBool>,
    notify: Arc<Notify>,
    /// Set when files were synced since the last compaction.
    dirty: Arc<AtomicBool>,
    /// Pooled HTTP client (connection reuse across requests).
    client: reqwest::Client,
}

impl SyncWorker {
    pub fn new(
        service: Arc<Mutex<Option<FilesService>>>,
        backend_url: String,
    ) -> Self {
        Self {
            service,
            backend_url,
            is_online: Arc::new(AtomicBool::new(true)),
            notify: Arc::new(Notify::new()),
            dirty: Arc::new(AtomicBool::new(false)),
            client: reqwest::Client::new(),
        }
    }

    pub fn set_online(&self, online: bool) {
        self.is_online.store(online, Ordering::Relaxed);
        if online {
            self.trigger(); // drain queue on reconnect
        }
    }

    /// Wake the sync loop immediately (call after an upload or on reconnect).
    pub fn trigger(&self) {
        self.notify.notify_one();
    }

    /// Spawn the background sync task.
    pub fn start(&self) {
        let worker = SyncWorker {
            service: self.service.clone(),
            backend_url: self.backend_url.clone(),
            is_online: self.is_online.clone(),
            notify: self.notify.clone(),
            dirty: self.dirty.clone(),
            client: self.client.clone(),
        };
        tokio::spawn(async move {
            worker.run().await;
        });
    }

    /// Main loop: wait for a trigger or the fallback tick, drain the queue, and
    /// compact on ticks when there's been activity.
    async fn run(&self) {
        tracing::info!(
            "Sync worker started (event-driven, {}s fallback, {} concurrent)",
            FALLBACK_TICK_SECS, MAX_CONCURRENT
        );

        loop {
            let woke_by_tick = tokio::select! {
                _ = self.notify.notified() => false,
                _ = sleep(Duration::from_secs(FALLBACK_TICK_SECS)) => true,
            };

            if !self.is_online.load(Ordering::Relaxed) {
                tracing::debug!("Offline - skipping sync");
                continue;
            }

            self.process_pending().await;

            // Compact on idle ticks, only if files were synced since last time.
            if woke_by_tick && self.dirty.swap(false, Ordering::Relaxed) {
                let svc = self.service.lock().await;
                if let Some(service) = svc.as_ref() {
                    if let Err(e) = service.compact().await {
                        tracing::warn!("Compaction failed: {}", e);
                    }
                }
            }
        }
    }

    /// Read the pending list (brief lock), then sync files in bounded parallel,
    /// each lock-free during network IO.
    async fn process_pending(&self) {
        let pending = {
            let svc = self.service.lock().await;
            match svc.as_ref() {
                Some(service) => match service.get_pending_syncs().await {
                    Ok(p) => p,
                    Err(e) => {
                        tracing::error!("Failed to query pending syncs: {}", e);
                        return;
                    }
                },
                None => {
                    tracing::warn!("Service not initialized, skipping sync");
                    return;
                }
            }
        }; // service lock released here

        if pending.is_empty() {
            return;
        }
        tracing::info!(count = pending.len(), "Processing pending syncs");

        futures::stream::iter(pending)
            .for_each_concurrent(MAX_CONCURRENT, |entry| async move {
                self.sync_file(&entry).await;
            })
            .await;
    }

    /// Sync one file. Network IO happens with NO service lock held.
    async fn sync_file(&self, entry: &przma_files::SyncQueueEntry) {
        let file_id = entry.file_id.clone();

        let space = match Space::try_from(entry.space.as_str()) {
            Ok(s) => s,
            Err(e) => {
                tracing::error!(file_id = %file_id, error = %e, "Invalid space");
                self.fail(&file_id, "Invalid space").await;
                return;
            }
        };

        // ── 1. Brief lock: gather metadata + blob path ──────────────────────
        let gathered = {
            let svc = self.service.lock().await;
            let service = match svc.as_ref() {
                Some(s) => s,
                None => return,
            };
            match service.store.get(&file_id, &space).await {
                Ok(file) => {
                    let cas_uri = CasUri::new(file.content_cas.trim_start_matches("cas:"));
                    let blob_path = service.cas.blob_file_path(&cas_uri);
                    Some((file, blob_path))
                }
                Err(e) => {
                    tracing::error!(file_id = %file_id, error = %e, "Local file read failed");
                    None
                }
            }
        }; // lock released before any network IO

        let (file, blob_path) = match gathered {
            Some(v) => v,
            None => {
                self.fail(&file_id, "Failed to read local file").await;
                return;
            }
        };

        tracing::info!(
            file_id = %file_id,
            file_name = %file.name,
            size_bytes = file.size_bytes,
            retry = entry.retry_count,
            "Syncing file"
        );

        // ── 2. Stream blob to backend (no lock held) ────────────────────────
        if let Err(e) = self
            .push_blob_streamed(&blob_path, &file.content_cas, &file.mime_type)
            .await
        {
            let msg = format!("Blob push failed: {}", e);
            tracing::warn!(file_id = %file_id, "{}", msg);
            self.fail(&file_id, &msg).await;
            return;
        }

        // ── 3. Push metadata to backend (no lock held) ──────────────────────
        if let Err(e) = self.push_metadata(&file).await {
            let msg = format!("Metadata push failed: {}", e);
            tracing::warn!(file_id = %file_id, "{}", msg);
            self.fail(&file_id, &msg).await;
            return;
        }

        // ── 4. Brief lock: mark synced ──────────────────────────────────────
        {
            let svc = self.service.lock().await;
            if let Some(service) = svc.as_ref() {
                if let Err(e) = service.mark_synced(&file_id, &space).await {
                    tracing::error!(file_id = %file_id, error = %e, "Failed to mark synced");
                    return;
                }
            }
        }

        self.dirty.store(true, Ordering::Relaxed);
        tracing::info!(file_id = %file_id, file_name = %file.name, "File synced");
    }

    /// Record a sync failure (brief lock).
    async fn fail(&self, file_id: &str, error: &str) {
        let svc = self.service.lock().await;
        if let Some(service) = svc.as_ref() {
            let _ = service.mark_sync_failed(file_id, error).await;
        }
    }

    /// POST /api/v1/files/sync/blob — streams the blob from disk.
    async fn push_blob_streamed(
        &self,
        blob_path: &std::path::Path,
        cas_hash: &str,
        mime_type: &str,
    ) -> Result<(), String> {
        let url = format!("{}/api/v1/files/sync/blob", self.backend_url);

        let file = tokio::fs::File::open(blob_path)
            .await
            .map_err(|e| format!("Open blob failed ({}): {}", blob_path.display(), e))?;

        let stream = tokio_util::io::ReaderStream::new(file);
        let body = reqwest::Body::wrap_stream(stream);

        let response = self
            .client
            .post(&url)
            .header("Content-Type", "application/octet-stream")
            .header("X-CAS-Hash", cas_hash)
            .header("X-MIME-Type", mime_type)
            .body(body)
            .send()
            .await
            .map_err(|e| format!("HTTP request failed: {}", e))?;

        if response.status().is_success() {
            Ok(())
        } else {
            Err(format!(
                "Backend returned {}: {}",
                response.status(),
                response.text().await.unwrap_or_default()
            ))
        }
    }

    /// POST /api/v1/files/sync/record — JSON file metadata for all spaces.
    /// Backend routes based on space field:
    ///   - Core → object store (encrypted locally, metadata only)
    ///   - Commons → backend database (public, shareable)
    ///   - Circle → backend database (group, shareable)
    async fn push_metadata(&self, file: &przma_files::FileRecord) -> Result<(), String> {
        let url = format!("{}/api/v1/files/sync/record", self.backend_url);

        let payload = serde_json::json!({
            "id": file.id,
            "did": file.did,
            "space": file.space,  // "core" | "commons" | "circle:{id}"
            "name": file.name,
            "path": file.path,
            "mime_type": file.mime_type,
            "size_bytes": file.size_bytes,
            "content_cas": file.content_cas,
            "is_public": file.is_public,
            "upload_status": file.upload_status,
            "created_at": file.created_at.to_rfc3339(),
            "updated_at": file.updated_at.to_rfc3339(),
        });

        let response = self
            .client
            .post(&url)
            .json(&payload)
            .send()
            .await
            .map_err(|e| format!("HTTP request failed: {}", e))?;

        if response.status().is_success() {
            Ok(())
        } else {
            Err(format!(
                "Backend returned {}: {}",
                response.status(),
                response.text().await.unwrap_or_default()
            ))
        }
    }
}
