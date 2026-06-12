// przma-files/src/lib.rs
//
// PRZMA Files Service - Local file storage orchestrator
// Handles: CAS (blob storage) + Lance (metadata) + Sync queue
//
// Flow: Frontend → Rust → CAS put() → FileRecord → Lance insert → SyncQueue (if Commons/Circle)

pub mod error;
pub mod keymgr;
pub mod models;
pub mod schema;
pub mod store;
pub mod sync_queue;

pub use error::{FilesError, FilesResult};
pub use models::FileRecord;
pub use store::FileStore;
pub use sync_queue::{SyncQueue, SyncQueueEntry};

use std::path::Path;
use przma_platform::{PlatformCas, CasUri, namespace::Space};

// ═════════════════════════════════════════════════════════════════════════════
// MAIN ORCHESTRATOR - FilesService
// ═════════════════════════════════════════════════════════════════════════════

/// Main file service orchestrator
/// Coordinates: CAS (blob) + FileStore (metadata) + SyncQueue (pending uploads)
pub struct FilesService {
    pub store: FileStore,
    pub sync_queue: SyncQueue,
    pub cas: PlatformCas,
    did: String,
    base_path: String,
}

impl FilesService {
    /// Initialize FilesService with local storage paths
    ///
    /// # Arguments
    /// * `base_path` - Base directory for all user vaults (e.g., "C:\Users\alice\AppData\Roaming\przma-files-desktop")
    /// * `did` - User's decentralized identity (e.g., "did:web:alice.com")
    pub async fn new(
        base_path: impl Into<String>,
        did: impl Into<String>,
    ) -> FilesResult<Self> {
        let base = base_path.into();
        let did_str = did.into();

        let store = FileStore::new(base.clone(), did_str.clone()).await?;
        let sync_queue = SyncQueue::new(base.clone(), did_str.clone()).await?;

        // Attach the at-rest cipher from the OS keychain. If the keychain is
        // unavailable, log loudly and continue WITHOUT encryption rather than
        // bricking the app — core blobs are then stored plaintext.
        let mut cas = PlatformCas::new(base.clone(), did_str.clone());
        match keymgr::get_or_create_cipher(&did_str) {
            Ok(cipher) => {
                cas = cas.with_cipher(cipher);
                tracing::info!("Vault encryption enabled (key from OS keychain)");
            }
            Err(e) => {
                tracing::error!("Vault encryption DISABLED — keychain unavailable: {}", e);
            }
        }

        Ok(Self {
            store,
            sync_queue,
            cas,
            did: did_str,
            base_path: base,
        })
    }

    /// Encrypt at rest only for the private Core space. Commons is public and
    /// shareable (must stay plaintext); Circle needs a group key that only
    /// exists after backend key-exchange, so it stays plaintext for now.
    fn should_encrypt(space: &Space) -> bool {
        matches!(space, Space::Core)
    }

    /// Build the FileRecord, persist it to Lance, and enqueue for backend sync.
    /// All spaces (Core, Commons, Circle) sync to backend when online:
    /// - Core → object store (encrypted locally)
    /// - Commons/Circle → backend database (shareable)
    /// Files are marked synced=false (pending) immediately and queued;
    /// the sync worker respects is_online and only syncs when connected.
    async fn persist_record(
        &self,
        name: String,
        path: String,
        space: Space,
        mime_type: String,
        size_bytes: i64,
        cas_uri: String,
    ) -> FilesResult<FileRecord> {
        let mut file = FileRecord::new(
            self.did.clone(),
            space.clone(),
            name,
            path,
            mime_type,
            size_bytes,
            cas_uri,
        );

        // All spaces now sync to backend when online
        file.synced = false; // Mark as pending sync

        self.store.create(&file).await?;
        // Enqueue for backend sync (will sync when device is online)
        let _ = self.sync_queue.enqueue(&file).await;

        tracing::info!(
            file_id = %file.id,
            name = %file.name,
            cas = %file.content_cas,
            space = ?space,
            size_bytes = file.size_bytes,
            "File added to service (queued for sync when online)"
        );
        Ok(file)
    }

    /// Upload a file: Store in CAS + Create Lance record + Enqueue for backend sync when online
    ///
    /// # Arguments
    /// * `name` - Filename (e.g., "photo.jpg")
    /// * `path` - Virtual path (e.g., "/photos/")
    /// * `space` - Storage space: Core (→ object store when online) | Commons (→ backend, public) | Circle (→ backend, group)
    /// * `mime_type` - MIME type (e.g., "image/jpeg")
    /// * `content` - Raw file bytes
    ///
    /// # Returns
    /// FileRecord with id, content_cas (BLAKE3 hash), synced=false (pending sync when online)
    pub async fn add_file(
        &self,
        name: String,
        path: String,
        space: Space,
        mime_type: String,
        content: &[u8],
    ) -> FilesResult<FileRecord> {
        // Store blob in CAS (encrypted at rest for Core).
        let (cas_uri, _new) = self.cas
            .put(content, Some(&mime_type), "files", Self::should_encrypt(&space))
            .await
            .map_err(|e| FilesError::Other(format!("CAS put failed: {}", e)))?;

        self.persist_record(name, path, space, mime_type, content.len() as i64, cas_uri.to_string())
            .await
    }

    /// Efficient ingest: stream a file from disk into CAS without buffering it
    /// in memory or base64-inflating it. File is immediately queued for backend
    /// sync (when online). Used by the desktop app's path-based upload command
    /// for large files.
    ///
    /// # Arguments
    /// * `src_path` - Absolute path to the source file on disk
    pub async fn add_file_from_path(
        &self,
        name: String,
        path: String,
        space: Space,
        mime_type: String,
        src_path: &Path,
    ) -> FilesResult<FileRecord> {
        // Plaintext size = the original file's size on disk.
        let size_bytes = tokio::fs::metadata(src_path)
            .await
            .map(|m| m.len() as i64)
            .map_err(|e| FilesError::Other(format!("stat source failed: {}", e)))?;

        // Stream blob into CAS (encrypted at rest for Core).
        let (cas_uri, _new) = self.cas
            .put_from_path(src_path, Some(&mime_type), "files", Self::should_encrypt(&space))
            .await
            .map_err(|e| FilesError::Other(format!("CAS stream put failed: {}", e)))?;

        self.persist_record(name, path, space, mime_type, size_bytes, cas_uri.to_string())
            .await
    }

    /// Compact the local Lance tables (files + sync queue) to merge the small
    /// fragment files that accrue from writes/updates. Cheap to call when idle.
    pub async fn compact(&self) -> FilesResult<()> {
        self.store.compact().await?;
        self.sync_queue.compact().await?;
        Ok(())
    }

    /// Retrieve file metadata and content from CAS
    ///
    /// # Arguments
    /// * `id` - File ID (UUID)
    /// * `space` - Storage space where file is stored
    ///
    /// # Returns
    /// Tuple of (FileRecord, Vec<u8> content)
    pub async fn get_file(
        &self,
        id: &str,
        space: &Space,
    ) -> FilesResult<(FileRecord, Vec<u8>)> {
        // ─ Step 1: Get metadata from Lance ─────────────────────────────────
        let file = self.store.get(id, space).await?;

        // ─ Step 2: Retrieve blob from CAS ──────────────────────────────────
        let cas_uri = CasUri::new(file.content_cas.trim_start_matches("cas:"));
        let content = self.cas
            .get(&cas_uri)
            .await
            .map_err(|e| FilesError::Other(format!("CAS get failed: {}", e)))?;

        tracing::info!(
            file_id = %file.id,
            name = %file.name,
            size_bytes = file.size_bytes,
            "File retrieved from service"
        );

        Ok((file, content))
    }

    /// List all files in a space
    ///
    /// # Arguments
    /// * `space` - Storage space to query
    ///
    /// # Returns
    /// Vec of FileRecord (metadata only, not full content)
    pub async fn list_files(&self, space: &Space) -> FilesResult<Vec<FileRecord>> {
        let files = self.store.list(space).await?;
        tracing::info!(
            space = ?space,
            count = files.len(),
            "Files listed from service"
        );
        Ok(files)
    }

    /// Delete a file: Remove from Lance + Deref CAS (auto-deletes blob when ref_count=0)
    ///
    /// # Arguments
    /// * `id` - File ID
    /// * `space` - Storage space
    pub async fn delete_file(&self, id: &str, space: &Space) -> FilesResult<()> {
        // ─ Step 1: Get file metadata to find CAS hash ──────────────────────
        let file = self.store.get(id, space).await?;

        // ─ Step 2: Decrement CAS ref_count (auto-delete if ref_count=0) ────
        let cas_uri = CasUri::new(file.content_cas.trim_start_matches("cas:"));
        self.cas
            .deref(&cas_uri)
            .await
            .map_err(|e| FilesError::Other(format!("CAS deref failed: {}", e)))?;

        // ─ Step 3: Delete metadata from Lance ──────────────────────────────
        self.store.delete(id, space).await?;

        tracing::info!(
            file_id = id,
            name = %file.name,
            space = ?space,
            "File deleted from service"
        );

        Ok(())
    }

    /// Get all files pending sync (Commons + Circle spaces with synced=false)
    ///
    /// # Returns
    /// Vec of SyncQueueEntry (file_id, space, content_cas, retry_count, etc.)
    pub async fn get_pending_syncs(&self) -> FilesResult<Vec<SyncQueueEntry>> {
        self.sync_queue.pending().await
    }

    /// Mark a file as synced after successful backend push
    ///
    /// # Arguments
    /// * `file_id` - File ID
    /// * `space` - Storage space
    pub async fn mark_synced(&self, file_id: &str, space: &Space) -> FilesResult<()> {
        // Update file record
        self.store.mark_synced(file_id, space).await?;

        // Update sync queue
        let _ = self.sync_queue.mark_complete(file_id).await;

        tracing::info!(
            file_id = file_id,
            space = ?space,
            "File marked as synced"
        );

        Ok(())
    }

    /// Mark a sync attempt as failed (increment retry_count, store error message)
    ///
    /// # Arguments
    /// * `file_id` - File ID
    /// * `error` - Error message
    pub async fn mark_sync_failed(
        &self,
        file_id: &str,
        error: &str,
    ) -> FilesResult<()> {
        let _ = self.sync_queue.mark_failed(file_id, error).await;
        Ok(())
    }

    /// Get CAS statistics for display (deduplication effectiveness)
    pub fn get_base_path(&self) -> &str {
        &self.base_path
    }

    pub fn get_did(&self) -> &str {
        &self.did
    }
}
