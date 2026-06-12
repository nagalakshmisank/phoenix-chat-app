// przma-files/src/sync_queue.rs
//
// Sync Queue - Tracks files pending upload to backend
// Stores in local Lance table: sync/{space}/sync_queue.lance/
//
// Status flow: pending → syncing → complete (or failed with retry_count)

use arrow_array::{
    cast::AsArray, Array, Int32Array, Int64Array, RecordBatch, RecordBatchIterator, StringArray,
};
use futures::TryStreamExt;
use lancedb::{connect, Table};
use lancedb::query::{ExecutableQuery, QueryBase};

use crate::error::{FilesError, FilesResult};
use crate::models::FileRecord;
use crate::schema::sync_queue_schema;
use przma_platform::namespace::Space;

// ═════════════════════════════════════════════════════════════════════════════
// SYNC QUEUE ENTRY - One pending file
// ═════════════════════════════════════════════════════════════════════════════

#[derive(Debug, Clone)]
pub struct SyncQueueEntry {
    pub id: String,              // Queue entry ID (UUID)
    pub did: String,             // User DID (owner)
    pub file_id: String,         // Reference to file
    pub file_name: String,       // For display
    pub przma_uri: String,       // przma://did/files/{space}/file/{id}
    pub space: String,           // "commons" or "circle:{id}"
    pub sync_mode: String,       // "public" or "shared"
    pub content_cas: String,     // "cas:{hash}" for backend push
    pub mime_type: String,
    pub file_size: i64,
    pub status: String,          // "pending" | "syncing" | "complete" | "failed"
    pub enqueued_at: i64,        // Unix microseconds
    pub synced_at: Option<i64>,  // Completion time
    pub retry_count: i32,        // Incremented on each failure
    pub error_msg: Option<String>, // Last error message
}

impl SyncQueueEntry {
    pub fn new(file: &FileRecord) -> Self {
        let now = chrono::Utc::now().timestamp_micros();
        let sync_mode = if file.space == "commons" { "public" } else { "shared" };
        Self {
            id: uuid::Uuid::new_v4().to_string(),
            did: file.did.clone(),
            file_id: file.id.clone(),
            file_name: file.name.clone(),
            przma_uri: file.przma_uri.clone(),
            space: file.space.clone(),
            sync_mode: sync_mode.to_string(),
            content_cas: file.content_cas.clone(),
            mime_type: file.mime_type.clone(),
            file_size: file.size_bytes,
            status: "pending".to_string(),
            enqueued_at: now,
            synced_at: None,
            retry_count: 0,
            error_msg: None,
        }
    }
}

// ═════════════════════════════════════════════════════════════════════════════
// SYNC QUEUE - Manages pending uploads
// ═════════════════════════════════════════════════════════════════════════════

pub struct SyncQueue {
    base_path: String,
    did: String,
}

impl SyncQueue {
    pub async fn new(base_path: impl Into<String>, did: impl Into<String>) -> FilesResult<Self> {
        Ok(Self {
            base_path: base_path.into(),
            did: did.into(),
        })
    }

    fn queue_path(&self) -> String {
        let sanitized_did = self.did.replace(':', "_");
        format!("{}/{}/sync/queue", self.base_path, sanitized_did)
    }

    async fn open_or_create_table(&self) -> FilesResult<Table> {
        let db_path = self.queue_path();
        let conn = connect(&db_path)
            .execute()
            .await
            .map_err(|e| FilesError::Storage(
                format!("Failed to connect to sync queue at {}: {}", db_path, e)
            ))?;

        let expected = sync_queue_schema();
        match conn.open_table("sync_queue").execute().await {
            Ok(table) => {
                // Verify schema
                let schema = table.schema().await
                    .map_err(|e| FilesError::Storage(format!("Schema check failed: {}", e)))?;
                if schema.fields.len() == expected.fields.len() {
                    Ok(table)
                } else {
                    // Schema mismatch, recreate
                    let _ = conn.drop_table("sync_queue").await;
                    conn.create_empty_table("sync_queue", expected)
                        .execute()
                        .await
                        .map_err(|e| FilesError::Storage(format!("Failed to create sync_queue: {}", e)))
                }
            }
            Err(_) => {
                // Table doesn't exist, create it
                conn.create_empty_table("sync_queue", expected)
                    .execute()
                    .await
                    .map_err(|e| FilesError::Storage(format!("Failed to create sync_queue: {}", e)))
            }
        }
    }

    /// Add file to sync queue for backend sync when online.
    /// All spaces (Core, Commons, Circle) are synced when the device is online:
    /// - Core: uploaded to object store (encrypted locally with OS keychain key)
    /// - Commons: uploaded to backend, shareable (public)
    /// - Circle: uploaded to backend, shareable (group) — backend routes from user context
    ///
    /// Note: Client sends space="circle" (generic); backend determines specific circle
    /// from user's circle memberships. Phase 4: client may send space="circle:id" if
    /// frontend pre-fetches the user's available circles.
    pub async fn enqueue(&self, file: &FileRecord) -> FilesResult<String> {
        // Validate space (all three are now syncable)
        let _ = Space::try_from(file.space.as_str())
            .map_err(|e| FilesError::InvalidSpace(format!("Invalid space: {}", e)))?;

        let table = self.open_or_create_table().await?;
        let entry = SyncQueueEntry::new(file);

        let batch = self.entry_to_batch(&entry)?;
        let schema = sync_queue_schema();
        let reader = RecordBatchIterator::new(vec![Ok(batch)], schema);

        table.add(reader)
            .execute()
            .await
            .map_err(|e| FilesError::Storage(format!("Enqueue failed: {}", e)))?;

        tracing::info!(
            queue_id = %entry.id,
            file_id = %file.id,
            file_name = %file.name,
            space = %file.space,
            "File enqueued for sync (will sync when online)"
        );

        Ok(entry.id)
    }

    /// Get all pending syncs (status='pending')
    /// Background worker polls this every 5 seconds
    pub async fn pending(&self) -> FilesResult<Vec<SyncQueueEntry>> {
        let table = match self.open_or_create_table().await {
            Ok(t) => t,
            Err(_) => return Ok(vec![]), // No queue yet
        };

        let batches: Vec<RecordBatch> = table
            .query()
            .only_if("status = 'pending' OR status = 'syncing'")
            .execute()
            .await
            .map_err(|e| FilesError::Storage(format!("Query failed: {}", e)))?
            .try_collect()
            .await
            .map_err(|e| FilesError::Storage(format!("Stream failed: {}", e)))?;

        let mut entries = vec![];
        for batch in batches {
            entries.extend(self.batch_to_entries(batch)?);
        }

        tracing::debug!(count = entries.len(), "Queried pending syncs");
        Ok(entries)
    }

    /// Fetch a single queue entry by file_id (targeted query, no full scan).
    async fn get_entry(&self, table: &Table, file_id: &str) -> FilesResult<Option<SyncQueueEntry>> {
        let batches: Vec<RecordBatch> = table
            .query()
            .only_if(format!("file_id = '{}'", file_id))
            .limit(1)
            .execute()
            .await
            .map_err(|e| FilesError::Storage(format!("Query failed: {}", e)))?
            .try_collect()
            .await
            .map_err(|e| FilesError::Storage(format!("Stream failed: {}", e)))?;

        for batch in batches {
            if let Some(entry) = self.batch_to_entries(batch)?.into_iter().next() {
                return Ok(Some(entry));
            }
        }
        Ok(None)
    }

    /// Replace a single entry's row in place: delete by file_id, insert one row.
    /// O(1) per update — does NOT rewrite the whole table.
    async fn replace_entry(&self, table: &Table, entry: &SyncQueueEntry) -> FilesResult<()> {
        table.delete(&format!("file_id = '{}'", entry.file_id)).await
            .map_err(|e| FilesError::Storage(format!("Delete failed: {}", e)))?;

        let batch = self.entry_to_batch(entry)?;
        let schema = sync_queue_schema();
        let reader = RecordBatchIterator::new(vec![Ok(batch)], schema);
        table.add(reader)
            .execute()
            .await
            .map_err(|e| FilesError::Storage(format!("Insert failed: {}", e)))?;
        Ok(())
    }

    /// Mark sync as complete (status='complete', set synced_at timestamp).
    /// Single-row update — only touches the matching entry.
    pub async fn mark_complete(&self, file_id: &str) -> FilesResult<()> {
        let table = self.open_or_create_table().await?;
        let now = chrono::Utc::now().timestamp_micros();

        let mut entry = match self.get_entry(&table, file_id).await? {
            Some(e) => e,
            None => return Err(FilesError::NotFound(
                format!("File not in sync queue: {}", file_id)
            )),
        };

        entry.status = "complete".to_string();
        entry.synced_at = Some(now);
        entry.retry_count = 0;
        self.replace_entry(&table, &entry).await?;

        tracing::info!(file_id = %file_id, "Sync marked as complete");
        Ok(())
    }

    /// Mark sync as failed (increment retry_count, store error message).
    /// Single-row update — keeps status 'pending' until 5 retries, then 'failed'.
    pub async fn mark_failed(&self, file_id: &str, error: &str) -> FilesResult<()> {
        let table = self.open_or_create_table().await?;

        let mut entry = match self.get_entry(&table, file_id).await? {
            Some(e) => e,
            None => return Ok(()), // Not queued yet — nothing to fail
        };

        entry.retry_count += 1;
        entry.error_msg = Some(error.to_string());
        if entry.retry_count >= 5 {
            entry.status = "failed".to_string();
        }
        self.replace_entry(&table, &entry).await?;

        tracing::warn!(
            file_id = %file_id,
            retry_count = entry.retry_count,
            error = %error,
            status = %entry.status,
            "Sync marked as failed"
        );
        Ok(())
    }

    /// Remove entry from queue after sync completes
    pub async fn remove(&self, file_id: &str) -> FilesResult<()> {
        let table = self.open_or_create_table().await?;
        table.delete(&format!("file_id = '{}'", file_id))
            .await
            .map_err(|e| FilesError::Storage(format!("Delete failed: {}", e)))?;

        tracing::info!(file_id = %file_id, "Removed from sync queue");
        Ok(())
    }

    /// Compact the sync_queue table. Status updates (delete+insert per change)
    /// create many small fragments; periodic compaction keeps it tidy.
    pub async fn compact(&self) -> FilesResult<()> {
        let table = self.open_or_create_table().await?;
        table
            .optimize(lancedb::table::OptimizeAction::Compact {
                options: Default::default(),
                remap_options: None,
            })
            .await
            .map_err(|e| FilesError::Storage(format!("Compaction failed: {}", e)))?;
        tracing::debug!("Sync queue table compacted");
        Ok(())
    }

    // ──────────────────────────────────────────────────────────────────────
    // Conversion helpers
    // ──────────────────────────────────────────────────────────────────────

    fn entry_to_batch(&self, entry: &SyncQueueEntry) -> FilesResult<RecordBatch> {
        let schema = sync_queue_schema();

        let id_array = StringArray::from(vec![entry.id.clone()]);
        let did_array = StringArray::from(vec![entry.did.clone()]);
        let file_id_array = StringArray::from(vec![entry.file_id.clone()]);
        let file_name_array = StringArray::from(vec![entry.file_name.clone()]);
        let przma_uri_array = StringArray::from(vec![entry.przma_uri.clone()]);
        let space_array = StringArray::from(vec![entry.space.clone()]);
        let sync_mode_array = StringArray::from(vec![entry.sync_mode.clone()]);
        let mime_type_array = StringArray::from(vec![entry.mime_type.clone()]);
        let file_size_array = Int64Array::from(vec![entry.file_size]);
        let content_cas_array = StringArray::from(vec![entry.content_cas.clone()]);
        let status_array = StringArray::from(vec![entry.status.clone()]);
        let enqueued_at_array = Int64Array::from(vec![entry.enqueued_at]);
        let synced_at_array = Int64Array::from(vec![entry.synced_at.unwrap_or(0)]);
        let retry_count_array = Int32Array::from(vec![entry.retry_count]);
        let error_msg_array = StringArray::from(vec![
            entry.error_msg.clone().unwrap_or_default()
        ]);

        RecordBatch::try_new(
            schema,
            vec![
                std::sync::Arc::new(id_array),
                std::sync::Arc::new(did_array),
                std::sync::Arc::new(file_id_array),
                std::sync::Arc::new(file_name_array),
                std::sync::Arc::new(przma_uri_array),
                std::sync::Arc::new(space_array),
                std::sync::Arc::new(sync_mode_array),
                std::sync::Arc::new(mime_type_array),
                std::sync::Arc::new(file_size_array),
                std::sync::Arc::new(content_cas_array),
                std::sync::Arc::new(status_array),
                std::sync::Arc::new(enqueued_at_array),
                std::sync::Arc::new(synced_at_array),
                std::sync::Arc::new(retry_count_array),
                std::sync::Arc::new(error_msg_array),
            ],
        )
        .map_err(|e| FilesError::Arrow(e.to_string()))
    }

    fn batch_to_entries(&self, batch: RecordBatch) -> FilesResult<Vec<SyncQueueEntry>> {
        let columns = batch.columns();
        if columns.len() < 15 {
            return Err(FilesError::Arrow("Invalid batch columns".to_string()));
        }

        let ids = columns[0].as_string::<i32>();
        let dids = columns[1].as_string::<i32>();
        let file_ids = columns[2].as_string::<i32>();
        let file_names = columns[3].as_string::<i32>();
        let przma_uris = columns[4].as_string::<i32>();
        let spaces = columns[5].as_string::<i32>();
        let sync_modes = columns[6].as_string::<i32>();
        let mime_types = columns[7].as_string::<i32>();
        let file_sizes = columns[8].as_primitive::<arrow_array::types::Int64Type>();
        let cas_hashes = columns[9].as_string::<i32>();
        let statuses = columns[10].as_string::<i32>();
        let enqueued_ats = columns[11].as_primitive::<arrow_array::types::Int64Type>();
        let synced_ats = columns[12].as_primitive::<arrow_array::types::Int64Type>();
        let retry_counts = columns[13].as_primitive::<arrow_array::types::Int32Type>();
        let error_msgs = columns[14].as_string::<i32>();

        let mut entries = vec![];
        for i in 0..ids.len() {
            entries.push(SyncQueueEntry {
                id: ids.value(i).to_string(),
                did: dids.value(i).to_string(),
                file_id: file_ids.value(i).to_string(),
                file_name: file_names.value(i).to_string(),
                przma_uri: przma_uris.value(i).to_string(),
                space: spaces.value(i).to_string(),
                sync_mode: sync_modes.value(i).to_string(),
                content_cas: cas_hashes.value(i).to_string(),
                mime_type: mime_types.value(i).to_string(),
                file_size: file_sizes.value(i),
                status: statuses.value(i).to_string(),
                enqueued_at: enqueued_ats.value(i),
                synced_at: {
                    let ts = synced_ats.value(i);
                    if ts == 0 { None } else { Some(ts) }
                },
                retry_count: retry_counts.value(i),
                error_msg: {
                    let msg = error_msgs.value(i);
                    if msg.is_empty() { None } else { Some(msg.to_string()) }
                },
            });
        }

        Ok(entries)
    }
}
