// przma-calendar/src/cas.rs
//
// BLAKE3 Content-Addressable Storage for calendar attachments and notes.
// Scoped per-DID — no cross-DID deduplication.

use blake3::Hasher;
use std::path::PathBuf;
use std::sync::Arc;
use tokio::fs;
use futures::TryStreamExt;
use lancedb::connect;
use lancedb::query::{ExecutableQuery, QueryBase};
use arrow_array::{Array, RecordBatch, RecordBatchIterator, StringArray, UInt64Array, Int64Array, UInt32Array};
use crate::error::{CalendarError, CalendarResult};
use crate::schema::{cas_table_schema, tables};

/// Compute BLAKE3 hash of bytes — returns hex string
pub fn hash_bytes(data: &[u8]) -> String {
    let mut hasher = Hasher::new();
    hasher.update(data);
    hasher.finalize().to_hex().to_string()
}

/// Compute BLAKE3 hash of a string (for ID generation)
pub fn hash_id(input: &str) -> String {
    hash_bytes(input.as_bytes())
}

/// CAS store — writes encrypted blobs to per-DID path
pub struct CasStore {
    base_path: PathBuf,
    did:       String,
}

impl CasStore {
    /// Create a CAS store rooted at base_path/{did}/calendar/cas/
    pub fn new(base_path: impl Into<PathBuf>, did: impl Into<String>) -> Self {
        Self {
            base_path: base_path.into(),
            did:       did.into(),
        }
    }

    fn cas_dir(&self) -> PathBuf {
        // Windows doesn't allow colons in filenames (DIDs have colons).
        // Sanitize to match PlatformCas layout: {base}/{sanitized_did}/cas/
        let sanitized_did = self.did.replace(':', "_");
        self.base_path.join(&sanitized_did).join("cas")
    }

    fn blob_path(&self, hash: &str) -> PathBuf {
        // Shard by first 2 chars to avoid too many files in one dir
        self.cas_dir()
            .join(&hash[..2])
            .join(hash)
    }

    /// Write bytes to CAS. Returns BLAKE3 hex hash.
    /// If content already exists (same hash), increments ref count only.
    pub async fn put(&self, data: &[u8]) -> CalendarResult<String> {
        let hash = hash_bytes(data);
        let path = self.blob_path(&hash);

        if !path.exists() {
            if let Some(parent) = path.parent() {
                fs::create_dir_all(parent).await?;
            }
            // In production: encrypt data with DID-derived key before writing.
            // For now: write plaintext (encryption layer added in Phase 5).
            fs::write(&path, data).await?;
            tracing::debug!(hash = %hash, bytes = data.len(), "CAS: wrote blob");
        } else {
            tracing::debug!(hash = %hash, "CAS: blob already exists");
        }

        Ok(hash)
    }

    /// Read bytes by hash. Returns CalendarError::NotFound if absent.
    pub async fn get(&self, hash: &str) -> CalendarResult<Vec<u8>> {
        let path = self.blob_path(hash);
        if !path.exists() {
            return Err(CalendarError::NotFound(format!("CAS blob: {}", hash)));
        }
        let data = fs::read(&path).await?;
        Ok(data)
    }

    /// Check existence without reading
    pub async fn exists(&self, hash: &str) -> bool {
        self.blob_path(hash).exists()
    }

    /// Dereference a blob. In production this decrements ref count in Lance.
    /// When ref count hits 0, the blob is deleted.
    /// For Phase 1: direct delete.
    pub async fn deref(&self, hash: &str) -> CalendarResult<()> {
        let path = self.blob_path(hash);
        if path.exists() {
            fs::remove_file(&path).await?;
            tracing::debug!(hash = %hash, "CAS: dereferenced blob");
        }
        Ok(())
    }
}

// ─── CAS TABLE ───────────────────────────────────────────────────────────────
// Wraps CasStore + a Lance metadata table.
// Every blob written via CasTable gets a row in the `cas` Lance table with:
//   ref_count — how many records point to this blob (for GC)
//   shareable_link — the `cas:{hash}` URI returned to callers
//   file_name, mime_type, size_bytes — for browsing without reading blobs

pub struct CasTable {
    store:     CasStore,
    base_path: String,
    did:       String,
}

impl CasTable {
    pub async fn open(base_path: &str, did: &str) -> CalendarResult<Self> {
        let store      = CasStore::new(base_path, did);
        let sanitized_did = did.replace(':', "_");
        let table_path = format!("{}/{}/cas/cas_table", base_path, sanitized_did);

        let conn = connect(&table_path)
            .execute().await
            .map_err(|e| CalendarError::Storage(e.to_string()))?;

        let expected = cas_table_schema();
        if let Ok(table) = conn.open_table(tables::CAS).execute().await {
            let mismatch = match table.schema().await {
                Ok(schema) => !schemas_match(&schema, &expected),
                Err(_) => true,
            };
            if mismatch {
                tracing::warn!("Schema mismatch for CAS table, recreating...");
                let _ = conn.drop_table(tables::CAS).await;
                conn.create_empty_table(tables::CAS, expected)
                    .execute().await
                    .map_err(|e| CalendarError::Storage(e.to_string()))?;
            }
        } else {
            conn.create_empty_table(tables::CAS, expected)
                .execute().await
                .map_err(|e| CalendarError::Storage(e.to_string()))?;
        }

        Ok(Self {
            store,
            base_path: base_path.to_string(),
            did:       did.to_string(),
        })
    }

    fn table_path(&self) -> String {
        let sanitized_did = self.did.replace(':', "_");
        format!("{}/{}/cas/cas_table", self.base_path, sanitized_did)
    }

    /// Open the CAS table, creating it if it doesn't exist yet.
    /// lancedb 0.9 may not persist an empty table created on a different
    /// connection, so every accessor must be able to (re)create it.
    async fn open_or_create_table(&self) -> CalendarResult<lancedb::Table> {
        let conn = connect(&self.table_path()).execute().await
            .map_err(|e| CalendarError::Storage(e.to_string()))?;
        let expected = cas_table_schema();
        match conn.open_table(tables::CAS).execute().await {
            Ok(table) => {
                let mismatch = match table.schema().await {
                    Ok(schema) => !schemas_match(&schema, &expected),
                    Err(_) => true,
                };
                if mismatch {
                    tracing::warn!("Schema mismatch for CAS table, recreating...");
                    let _ = conn.drop_table(tables::CAS).await;
                    conn.create_empty_table(tables::CAS, expected)
                        .execute().await
                        .map_err(|e| CalendarError::Storage(e.to_string()))
                } else {
                    Ok(table)
                }
            }
            Err(_) => conn
                .create_empty_table(tables::CAS, expected)
                .execute().await
                .map_err(|e| CalendarError::Storage(e.to_string())),
        }
    }

    /// Store a blob. Returns `cas:{hash}` link.
    /// If the same content was already stored, increments ref_count only.
    pub async fn put(
        &self,
        data:       &[u8],
        file_name:  Option<&str>,
        mime_type:  Option<&str>,
        written_by: &str,
    ) -> CalendarResult<String> {
        let hash = hash_bytes(data);
        let link = format!("cas:{}", hash);

        let table = self.open_or_create_table().await?;

        // Check if hash already exists
        let existing: Vec<RecordBatch> = table
            .query()
            .only_if(format!("hash = '{}'", hash))
            .limit(1)
            .execute().await
            .map_err(|e| CalendarError::Storage(e.to_string()))?
            .try_collect().await
            .map_err(|e| CalendarError::Storage(e.to_string()))?;

        let current_ref = existing
            .first()
            .and_then(|b| b.column_by_name("ref_count"))
            .and_then(|c| c.as_any().downcast_ref::<UInt32Array>())
            .map(|a| a.value(0))
            .unwrap_or(0);

        // Blob already stored — increment ref_count via merge_insert
        if current_ref > 0 {
            let schema = cas_table_schema();
            let batch  = existing.into_iter().next()
                .ok_or_else(|| CalendarError::Storage("ref read failed".into()))?;
            // rebuild row with incremented ref_count
            let updated = increment_ref_count_in_batch(batch, current_ref + 1, schema.clone())
                .map_err(|e| CalendarError::Storage(e.to_string()))?;
            let mut merge = table.merge_insert(&["hash"]);
            merge.when_matched_update_all(None);
            merge.when_not_matched_insert_all();
            merge.execute(Box::new(RecordBatchIterator::new(
                    vec![Ok(updated)], schema,
                )))
                .await
                .map_err(|e| CalendarError::Storage(e.to_string()))?;
            return Ok(link);
        }

        // New blob — write to disk first
        self.store.put(data).await?;

        // Then insert metadata row
        let now   = chrono::Utc::now().timestamp_micros();
        let schema = cas_table_schema();
        let batch = RecordBatch::try_new(schema.clone(), vec![
            Arc::new(StringArray::from(vec![hash.as_str()])),
            Arc::new(StringArray::from(vec![self.did.as_str()])),
            Arc::new(StringArray::from(vec![file_name])),
            Arc::new(StringArray::from(vec![mime_type])),
            Arc::new(UInt64Array::from(vec![data.len() as u64])),
            Arc::new(Int64Array::from(vec![now])),
            Arc::new(StringArray::from(vec![written_by])),
            Arc::new(UInt32Array::from(vec![1u32])),
            Arc::new(StringArray::from(vec![link.as_str()])),
        ]).map_err(|e| CalendarError::Storage(e.to_string()))?;

        let mut merge = table.merge_insert(&["hash"]);
        merge.when_matched_update_all(None);
        merge.when_not_matched_insert_all();
        merge.execute(Box::new(RecordBatchIterator::new(
                vec![Ok(batch)], schema,
            )))
            .await
            .map_err(|e| CalendarError::Storage(e.to_string()))?;

        Ok(link)
    }

    /// Query the cas_table with custom filters
    pub async fn query_cas(&self, filter: &str) -> CalendarResult<Vec<RecordBatch>> {
        let table = self.open_or_create_table().await?;
        let mut q = table.query();
        if !filter.is_empty() {
            q = q.only_if(filter);
        }
        let batches: Vec<RecordBatch> = q
            .execute()
            .await
            .map_err(|e| CalendarError::Storage(e.to_string()))?
            .try_collect()
            .await
            .map_err(|e| CalendarError::Storage(e.to_string()))?;
        Ok(batches)
    }

    /// Read blob bytes by `cas:{hash}` link.
    pub async fn get_bytes(&self, link: &str) -> CalendarResult<Vec<u8>> {
        let hash = link.strip_prefix("cas:").unwrap_or(link);
        self.store.get(hash).await
    }

    /// Look up the shareable_link stored in Lance for a given hash.
    pub async fn get_link(&self, hash: &str) -> CalendarResult<Option<String>> {
        let table = self.open_or_create_table().await?;

        let batches: Vec<RecordBatch> = table
            .query()
            .only_if(format!("hash = '{}'", hash))
            .limit(1)
            .execute().await
            .map_err(|e| CalendarError::Storage(e.to_string()))?
            .try_collect().await
            .map_err(|e| CalendarError::Storage(e.to_string()))?;

        let link = batches
            .first()
            .and_then(|b| b.column_by_name("shareable_link"))
            .and_then(|c| c.as_any().downcast_ref::<StringArray>())
            .filter(|a| !a.is_empty())
            .map(|a| a.value(0).to_string());

        Ok(link)
    }

    /// Decrement the ref_count for a blob hash. When it reaches zero, the
    /// metadata row and the underlying blob are removed (GC). Accepts either a
    /// bare hash or a `cas:{hash}` link.
    pub async fn deref(&self, hash_or_link: &str) -> CalendarResult<()> {
        let hash = hash_or_link.strip_prefix("cas:").unwrap_or(hash_or_link);

        let table = self.open_or_create_table().await?;

        let existing: Vec<RecordBatch> = table
            .query()
            .only_if(format!("hash = '{}'", hash))
            .limit(1)
            .execute().await
            .map_err(|e| CalendarError::Storage(e.to_string()))?
            .try_collect().await
            .map_err(|e| CalendarError::Storage(e.to_string()))?;

        let current_ref = existing
            .first()
            .and_then(|b| b.column_by_name("ref_count"))
            .and_then(|c| c.as_any().downcast_ref::<UInt32Array>())
            .map(|a| a.value(0))
            .unwrap_or(0);

        if current_ref <= 1 {
            // Last reference (or untracked) — remove row and blob.
            table.delete(&format!("hash = '{}'", hash)).await
                .map_err(|e| CalendarError::Storage(e.to_string()))?;
            self.store.deref(hash).await?;
        } else {
            // Still referenced — decrement count.
            let schema = cas_table_schema();
            let batch  = existing.into_iter().next()
                .ok_or_else(|| CalendarError::Storage("ref read failed".into()))?;
            let updated = increment_ref_count_in_batch(batch, current_ref - 1, schema.clone())
                .map_err(|e| CalendarError::Storage(e.to_string()))?;
            let mut merge = table.merge_insert(&["hash"]);
            merge.when_matched_update_all(None);
            merge.when_not_matched_insert_all();
            merge.execute(Box::new(RecordBatchIterator::new(
                    vec![Ok(updated)], schema,
                )))
                .await
                .map_err(|e| CalendarError::Storage(e.to_string()))?;
        }
        Ok(())
    }
}

fn increment_ref_count_in_batch(
    batch:     RecordBatch,
    new_count: u32,
    schema:    Arc<arrow_schema::Schema>,
) -> Result<RecordBatch, arrow_schema::ArrowError> {
    // Rebuild the batch with the updated ref_count column
    let mut columns: Vec<Arc<dyn arrow_array::Array>> = batch
        .columns()
        .iter()
        .map(|c| Arc::clone(c))
        .collect();
    // ref_count is column index 7
    columns[7] = Arc::new(UInt32Array::from(vec![new_count]));
    RecordBatch::try_new(schema, columns)
}

#[cfg(test)]
mod tests {
    use super::*;
    use tempfile::tempdir;

    #[tokio::test]
    async fn test_put_get_round_trip() {
        let dir  = tempdir().unwrap();
        let cas  = CasStore::new(dir.path(), "did:web:alice.com");
        let data = b"hello przma calendar";

        let hash = cas.put(data).await.unwrap();
        assert_eq!(hash.len(), 64); // BLAKE3 hex = 64 chars

        let retrieved = cas.get(&hash).await.unwrap();
        assert_eq!(retrieved, data);
    }

    #[tokio::test]
    async fn test_idempotent_put() {
        let dir  = tempdir().unwrap();
        let cas  = CasStore::new(dir.path(), "did:web:alice.com");
        let data = b"same content twice";

        let hash1 = cas.put(data).await.unwrap();
        let hash2 = cas.put(data).await.unwrap();
        assert_eq!(hash1, hash2);
    }

    #[tokio::test]
    async fn test_not_found() {
        let dir = tempdir().unwrap();
        let cas = CasStore::new(dir.path(), "did:web:alice.com");
        let err = cas.get("aabbccdd").await;
        assert!(matches!(err, Err(CalendarError::NotFound(_))));
    }

    #[test]
    fn test_hash_id_deterministic() {
        let h1 = hash_id("did:web:alice.com-event-123");
        let h2 = hash_id("did:web:alice.com-event-123");
        assert_eq!(h1, h2);

        let h3 = hash_id("did:web:alice.com-event-124");
        assert_ne!(h1, h3);
    }
}

fn data_types_match(a: &arrow_schema::DataType, b: &arrow_schema::DataType) -> bool {
    use arrow_schema::DataType;
    match (a, b) {
        (DataType::FixedSizeList(fa, sa), DataType::FixedSizeList(fb, sb)) => {
            sa == sb && fa.name() == fb.name() && data_types_match(fa.data_type(), fb.data_type())
        }
        (DataType::List(fa), DataType::List(fb)) => {
            fa.name() == fb.name() && data_types_match(fa.data_type(), fb.data_type())
        }
        (DataType::LargeList(fa), DataType::LargeList(fb)) => {
            fa.name() == fb.name() && data_types_match(fa.data_type(), fb.data_type())
        }
        (DataType::Struct(fa), DataType::Struct(fb)) => {
            if fa.len() != fb.len() {
                return false;
            }
            for (f1, f2) in fa.iter().zip(fb.iter()) {
                if f1.name() != f2.name()
                    || f1.is_nullable() != f2.is_nullable()
                    || !data_types_match(f1.data_type(), f2.data_type())
                {
                    return false;
                }
            }
            true
        }
        (x, y) => x == y,
    }
}

fn schemas_match(a: &arrow_schema::Schema, b: &arrow_schema::Schema) -> bool {
    if a.fields().len() != b.fields().len() {
        return false;
    }
    for (fa, fb) in a.fields().iter().zip(b.fields().iter()) {
        if fa.name() != fb.name()
            || fa.is_nullable() != fb.is_nullable()
            || !data_types_match(fa.data_type(), fb.data_type())
        {
            return false;
        }
    }
    true
}
