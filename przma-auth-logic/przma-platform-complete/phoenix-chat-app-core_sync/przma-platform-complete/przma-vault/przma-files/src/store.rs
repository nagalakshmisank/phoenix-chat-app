// przma-files/src/store.rs
//
// LanceDB storage implementation for local FileRecords.

use arrow_array::{
    Array, BooleanArray, FixedSizeListArray, Float32Array,
    Int32Array, Int64Array, RecordBatch, RecordBatchIterator, StringArray,
};
use futures::TryStreamExt;
use lancedb::{connect, Table};
use lancedb::query::{ExecutableQuery, QueryBase};
use std::sync::Arc;

use crate::error::{FilesError, FilesResult};
use crate::models::FileRecord;
use crate::schema::local_file_schema;
use przma_platform::namespace::Space;

pub struct FileStore {
    base_path: String,
    did: String,
}

impl FileStore {
    pub async fn new(base_path: impl Into<String>, _did: impl Into<String>) -> FilesResult<Self> {
        let base_path_str = base_path.into();
        let did_str = _did.into();

        Ok(Self {
            base_path: base_path_str,
            did: did_str,
        })
    }

    /// Single Lance table per user. Space is a column on each row, not a
    /// directory — callers filter by `space` in their queries.
    fn resolve_db_path(&self) -> String {
        let sanitized_did = self.did.replace(':', "_");
        format!("{}/{}/files", self.base_path, sanitized_did)
    }

    async fn open_or_create_table(&self) -> FilesResult<Table> {
        let db_path = self.resolve_db_path();
        let conn = connect(&db_path)
            .execute()
            .await
            .map_err(|e| FilesError::Storage(format!("Failed to connect to lancedb at {}: {}", db_path, e)))?;

        let expected = local_file_schema();
        match conn.open_table("files").execute().await {
            Ok(table) => {
                let mismatch = match table.schema().await {
                    Ok(schema) => !schemas_match(&schema, &expected),
                    Err(_) => true,
                };
                if mismatch {
                    tracing::warn!("Schema mismatch for files table at {}, recreating...", db_path);
                    let _ = conn.drop_table("files").await;
                    let table = conn
                        .create_empty_table("files", expected)
                        .execute()
                        .await
                        .map_err(|e| FilesError::Storage(format!("Failed to create files table: {}", e)))?;
                    Ok(table)
                } else {
                    Ok(table)
                }
            }
            Err(_) => {
                let table = conn
                    .create_empty_table("files", expected)
                    .execute()
                    .await
                    .map_err(|e| FilesError::Storage(format!("Failed to create files table: {}", e)))?;
                Ok(table)
            }
        }
    }

    pub async fn create(&self, file: &FileRecord) -> FilesResult<String> {
        let table = self.open_or_create_table().await?;
        let batch = file_record_to_batch(file)?;

        // Delete any existing record with the same ID first (idempotent write)
        let _ = table.delete(&format!("id = '{}'", file.id)).await;

        let schema = local_file_schema();
        let reader = RecordBatchIterator::new(vec![Ok(batch)], schema);
        table.add(reader)
            .execute()
            .await
            .map_err(|e| FilesError::Storage(format!("Insert failed: {}", e)))?;

        Ok(file.id.clone())
    }

    pub async fn get(&self, id: &str, _space: &Space) -> FilesResult<FileRecord> {
        // id is a globally-unique UUID, so we don't need the space to locate it.
        let table = self.open_or_create_table().await?;
        let batches: Vec<RecordBatch> = table
            .query()
            .only_if(format!("id = '{}'", id))
            .limit(1)
            .execute()
            .await
            .map_err(|e| FilesError::Storage(format!("Query failed: {}", e)))?
            .try_collect()
            .await
            .map_err(|e| FilesError::Storage(format!("Stream collection failed: {}", e)))?;

        let mut files = vec![];
        for batch in batches {
            files.extend(batch_to_files(batch)?);
        }

        files.pop().ok_or_else(|| FilesError::NotFound(format!("File not found: {}", id)))
    }

    pub async fn list(&self, space: &Space) -> FilesResult<Vec<FileRecord>> {
        let table = self.open_or_create_table().await?;
        // Filter to the requested space — single table holds all spaces.
        let batches: Vec<RecordBatch> = table
            .query()
            .only_if(format!("space = '{}'", space.as_str()))
            .execute()
            .await
            .map_err(|e| FilesError::Storage(format!("Query failed: {}", e)))?
            .try_collect()
            .await
            .map_err(|e| FilesError::Storage(format!("Stream collection failed: {}", e)))?;

        let mut files = vec![];
        for batch in batches {
            files.extend(batch_to_files(batch)?);
        }
        Ok(files)
    }

    /// List every file across all spaces for this user (single-table convenience).
    pub async fn list_all(&self) -> FilesResult<Vec<FileRecord>> {
        let table = self.open_or_create_table().await?;
        let batches: Vec<RecordBatch> = table
            .query()
            .execute()
            .await
            .map_err(|e| FilesError::Storage(format!("Query failed: {}", e)))?
            .try_collect()
            .await
            .map_err(|e| FilesError::Storage(format!("Stream collection failed: {}", e)))?;

        let mut files = vec![];
        for batch in batches {
            files.extend(batch_to_files(batch)?);
        }
        Ok(files)
    }

    pub async fn update(&self, file: &FileRecord) -> FilesResult<()> {
        let table = self.open_or_create_table().await?;
        let batch = file_record_to_batch(file)?;

        // Delete old record and insert updated
        table.delete(&format!("id = '{}'", file.id)).await
            .map_err(|e| FilesError::Storage(format!("Update delete failed: {}", e)))?;

        let schema = local_file_schema();
        let reader = RecordBatchIterator::new(vec![Ok(batch)], schema);
        table.add(reader)
            .execute()
            .await
            .map_err(|e| FilesError::Storage(format!("Update failed: {}", e)))?;

        Ok(())
    }

    pub async fn delete(&self, id: &str, _space: &Space) -> FilesResult<()> {
        let table = self.open_or_create_table().await?;
        table.delete(&format!("id = '{}'", id))
            .await
            .map_err(|e| FilesError::Storage(format!("Delete failed: {}", e)))?;
        Ok(())
    }

    pub async fn mark_synced(&self, id: &str, space: &Space) -> FilesResult<()> {
        let mut file = self.get(id, space).await?;
        file.synced = true;
        self.update(&file).await?;
        Ok(())
    }

    /// All unsynced files pending backend sync (Core → object store when online, Commons/Circle → backend when online).
    /// Single-table query, no directory scan. Sync worker respects is_online before actually syncing.
    pub async fn pending_syncs(&self) -> FilesResult<Vec<FileRecord>> {
        let table = self.open_or_create_table().await?;
        let batches: Vec<RecordBatch> = table
            .query()
            .only_if("synced = false")
            .execute()
            .await
            .map_err(|e| FilesError::Storage(format!("Query failed: {}", e)))?
            .try_collect()
            .await
            .map_err(|e| FilesError::Storage(format!("Stream collection failed: {}", e)))?;

        let mut pending = vec![];
        for batch in batches {
            pending.extend(batch_to_files(batch)?);
        }
        Ok(pending)
    }

    /// Compact the files table — merges the small fragment files that every
    /// add/delete/update creates into larger ones. Run periodically to keep
    /// read/write performance from degrading over time.
    pub async fn compact(&self) -> FilesResult<()> {
        let table = self.open_or_create_table().await?;
        table
            .optimize(lancedb::table::OptimizeAction::Compact {
                options: Default::default(),
                remap_options: None,
            })
            .await
            .map_err(|e| FilesError::Storage(format!("Compaction failed: {}", e)))?;
        tracing::debug!("Files table compacted");
        Ok(())
    }
}

// ─── TRANSLATION HELPERS ──────────────────────────────────────────────────────

fn file_record_to_batch(file: &FileRecord) -> FilesResult<RecordBatch> {
    let schema = local_file_schema();

    let mut embedding = file.embedding.clone();
    if embedding.len() != crate::schema::EMBEDDING_DIM as usize {
        embedding.resize(crate::schema::EMBEDDING_DIM as usize, 0.0);
    }
    let embedding_values = Float32Array::from(embedding);
    let embedding_field  = arrow_schema::Field::new("item", arrow_schema::DataType::Float32, false);
    let embedding_array  = FixedSizeListArray::try_new(
        Arc::new(embedding_field),
        crate::schema::EMBEDDING_DIM,
        Arc::new(embedding_values),
        None,
    ).map_err(|e| FilesError::Storage(format!("Failed to build embedding array: {}", e)))?;

    let batch = RecordBatch::try_new(
        schema.clone(),
        vec![
            Arc::new(StringArray::from(vec![file.id.as_str()])),
            Arc::new(StringArray::from(vec![file.did.as_str()])),
            Arc::new(StringArray::from(vec![file.space.as_str()])),
            Arc::new(StringArray::from(vec![file.name.as_str()])),
            Arc::new(StringArray::from(vec![file.path.as_str()])),
            Arc::new(StringArray::from(vec![file.mime_type.as_str()])),
            Arc::new(Int64Array::from(vec![file.size_bytes])),
            Arc::new(StringArray::from(vec![file.content_cas.as_str()])),
            Arc::new(StringArray::from(vec![file.thumbnail_cas.as_deref()])),
            Arc::new(StringArray::from(vec![file.versions_json.as_str()])),
            Arc::new(Int32Array::from(vec![file.current_version])),
            Arc::new(StringArray::from(vec![file.tags_json.as_str()])),
            Arc::new(StringArray::from(vec![file.source_uri.as_deref()])),
            Arc::new(embedding_array),
            Arc::new(BooleanArray::from(vec![file.is_public])),
            Arc::new(BooleanArray::from(vec![file.is_encrypted])),
            Arc::new(StringArray::from(vec![file.upload_status.as_str()])),
            Arc::new(Int32Array::from(vec![file.chunk_count])),
            Arc::new(Int32Array::from(vec![file.chunks_received])),
            Arc::new(Int64Array::from(vec![file.created_at.timestamp_micros()])),
            Arc::new(Int64Array::from(vec![file.updated_at.timestamp_micros()])),
            Arc::new(BooleanArray::from(vec![file.synced])),
        ],
    ).map_err(|e| FilesError::Storage(format!("Arrow batch creation failed: {}", e)))?;

    Ok(batch)
}

fn batch_to_files(batch: RecordBatch) -> FilesResult<Vec<FileRecord>> {
    let num_rows = batch.num_rows();
    let mut files = Vec::with_capacity(num_rows);

    let col = |name: &str| -> Option<&dyn Array> {
        batch.column_by_name(name).map(|v| &**v)
    };

    let strings = |name: &str| -> Vec<Option<&str>> {
        col(name)
            .map(|c| {
                c.as_any()
                    .downcast_ref::<StringArray>()
                    .expect("Expected StringArray")
                    .iter()
                    .collect()
            })
            .unwrap_or_else(|| vec![None; num_rows])
    };

    let i64s = |name: &str| -> Vec<Option<i64>> {
        col(name)
            .map(|c| {
                c.as_any()
                    .downcast_ref::<Int64Array>()
                    .expect("Expected Int64Array")
                    .iter()
                    .collect()
            })
            .unwrap_or_else(|| vec![None; num_rows])
    };

    let i32s = |name: &str| -> Vec<Option<i32>> {
        col(name)
            .map(|c| {
                c.as_any()
                    .downcast_ref::<Int32Array>()
                    .expect("Expected Int32Array")
                    .iter()
                    .collect()
            })
            .unwrap_or_else(|| vec![None; num_rows])
    };

    let bools = |name: &str| -> Vec<Option<bool>> {
        col(name)
            .map(|c| {
                c.as_any()
                    .downcast_ref::<BooleanArray>()
                    .expect("Expected BooleanArray")
                    .iter()
                    .collect()
            })
            .unwrap_or_else(|| vec![None; num_rows])
    };

    let embeddings = col("embedding")
        .map(|c| {
            c.as_any()
                .downcast_ref::<FixedSizeListArray>()
                .expect("Expected FixedSizeListArray")
        });

    let ids = strings("id");
    let dids = strings("did");
    let spaces = strings("space");
    let names = strings("name");
    let paths = strings("path");
    let mime_types = strings("mime_type");
    let sizes = i64s("size_bytes");
    let content_cases = strings("content_cas");
    let thumbnail_cases = strings("thumbnail_cas");
    let versions_jsons = strings("versions_json");
    let current_versions = i32s("current_version");
    let tags_jsons = strings("tags_json");
    let source_uris = strings("source_uri");
    let is_publics = bools("is_public");
    let is_encrypteds = bools("is_encrypted");
    let upload_statuses = strings("upload_status");
    let chunk_counts = i32s("chunk_count");
    let chunks_receiveds = i32s("chunks_received");
    let created_ats = i64s("created_at");
    let updated_ats = i64s("updated_at");
    let synceds = bools("synced");

    for i in 0..num_rows {
        let id = ids[i].unwrap_or("").to_string();
        let did = dids[i].unwrap_or("").to_string();
        let space_str = spaces[i].unwrap_or("core").to_string();
        let name = names[i].unwrap_or("").to_string();
        let path = paths[i].unwrap_or("").to_string();
        let mime_type = mime_types[i].unwrap_or("").to_string();
        let size_bytes = sizes[i].unwrap_or(0);
        let content_cas = content_cases[i].unwrap_or("").to_string();
        let thumbnail_cas = thumbnail_cases[i].map(|s| s.to_string());
        let versions_json = versions_jsons[i].unwrap_or("[]").to_string();
        let current_version = current_versions[i].unwrap_or(1);
        let tags_json = tags_jsons[i].unwrap_or("[]").to_string();
        let source_uri = source_uris[i].map(|s| s.to_string());

        let mut embedding = vec![0.0f32; 768];
        if let Some(ref embs) = embeddings {
            let val_array = embs.value(i);
            let float_arr = val_array
                .as_any()
                .downcast_ref::<Float32Array>()
                .expect("Expected Float32Array inside embedding FixedSizeList");
            for j in 0..std::cmp::min(float_arr.len(), 768) {
                embedding[j] = float_arr.value(j);
            }
        }

        let is_public = is_publics[i].unwrap_or(false);
        let is_encrypted = is_encrypteds[i].unwrap_or(false);
        let upload_status = upload_statuses[i].unwrap_or("complete").to_string();
        let chunk_count = chunk_counts[i];
        let chunks_received = chunks_receiveds[i];
        let created_at = created_ats[i].unwrap_or(0);
        let updated_at = updated_ats[i].unwrap_or(0);
        let synced = synceds[i].unwrap_or(false);

        let przma_uri = format!("przma://{}/files/{}/file/{}", did, space_str, id);

        let sync_mode = match space_str.as_str() {
            "commons" => "public".to_string(),
            s if s.starts_with("circle:") => "shared".to_string(),
            _ => "private".to_string(),
        };

        files.push(FileRecord {
            id,
            did,
            space: space_str,
            przma_uri,
            name,
            path,
            mime_type,
            size_bytes,
            content_cas,
            thumbnail_cas,
            versions_json,
            current_version,
            tags_json,
            source_uri,
            embedding,
            is_public,
            is_encrypted,
            sync_mode,
            upload_status,
            chunk_count,
            chunks_received,
            synced,
            created_at: chrono::DateTime::<chrono::Utc>::from_timestamp_micros(created_at)
                .unwrap_or_else(chrono::Utc::now),
            updated_at: chrono::DateTime::<chrono::Utc>::from_timestamp_micros(updated_at)
                .unwrap_or_else(chrono::Utc::now),
        });
    }

    Ok(files)
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
