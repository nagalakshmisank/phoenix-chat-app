use arrow_schema::Schema;
use std::sync::Arc;

pub const EMBEDDING_DIM: i32 = 768;

/// Files-service file schema — the canonical 21-field platform schema.
/// `przma_uri` and `sync_mode` are derived from (did, space, id) at read time
/// via namespace.rs; sync state lives in the sync_queue table — so none of
/// them are persisted here.
pub fn file_schema() -> Arc<Schema> {
    przma_platform::services::schemas::files::file_schema()
}

pub fn local_file_schema() -> Arc<Schema> {
    use arrow_schema::{DataType, Field, Fields};

    Arc::new(Schema::new(Fields::from(vec![
        Field::new("id",              DataType::Utf8, false),
        Field::new("did",             DataType::Utf8, false),
        Field::new("space",           DataType::Utf8, false),
        Field::new("name",            DataType::Utf8, false),
        Field::new("path",            DataType::Utf8, false),
        Field::new("mime_type",       DataType::Utf8, false),
        Field::new("size_bytes",      DataType::Int64, false),
        Field::new("content_cas",     DataType::Utf8, false),
        Field::new("thumbnail_cas",   DataType::Utf8, true),
        Field::new("versions_json",   DataType::Utf8, false),
        Field::new("current_version", DataType::Int32, false),
        Field::new("tags_json",       DataType::Utf8, false),
        Field::new("source_uri",      DataType::Utf8, true),
        Field::new(
            "embedding",
            DataType::FixedSizeList(
                Arc::new(Field::new("item", DataType::Float32, false)),
                EMBEDDING_DIM,
            ),
            false,
        ),
        Field::new("is_public",       DataType::Boolean, false),
        Field::new("is_encrypted",    DataType::Boolean, false),
        Field::new("upload_status",   DataType::Utf8, false),
        Field::new("chunk_count",     DataType::Int32, true),
        Field::new("chunks_received", DataType::Int32, true),
        Field::new("created_at",      DataType::Int64, false),
        Field::new("updated_at",      DataType::Int64, false),
        Field::new("synced",          DataType::Boolean, false),
    ])))
}

pub fn sync_queue_schema() -> Arc<Schema> {
    use arrow_schema::{DataType, Field, Fields};

    Arc::new(Schema::new(Fields::from(vec![
        Field::new("id", DataType::Utf8, false),
        Field::new("did", DataType::Utf8, false),
        Field::new("file_id", DataType::Utf8, false),
        Field::new("file_name", DataType::Utf8, false),
        Field::new("przma_uri", DataType::Utf8, false),
        Field::new("space", DataType::Utf8, false),
        Field::new("sync_mode", DataType::Utf8, false),
        Field::new("mime_type", DataType::Utf8, false),
        Field::new("file_size", DataType::Int64, false),
        Field::new("content_cas", DataType::Utf8, false),
        Field::new("status", DataType::Utf8, false),
        Field::new("enqueued_at", DataType::Int64, false),
        Field::new("synced_at", DataType::Int64, true),
        Field::new("retry_count", DataType::Int32, false),
        Field::new("error_msg", DataType::Utf8, true),
    ])))
}

pub mod tables {
    pub const FILES: &str = "files";
    pub const SYNC_QUEUE: &str = "sync_queue";
}
