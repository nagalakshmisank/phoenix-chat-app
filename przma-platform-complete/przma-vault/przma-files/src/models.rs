use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};

// ✅ IMPORT from official namespace.rs instead of redefining!
use przma_platform::namespace::{Space, UriBuilder};

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum SyncMode {
    Private,  // Core: Encrypted, owner-only
    Public,   // Commons: Unencrypted, everyone
    Shared,   // Circle: Group-encrypted
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct FileRecord {
    pub id: String,
    pub did: String,
    pub space: String,
    pub przma_uri: String,  // NEW: "przma://did/files/space/file/id"
    pub name: String,
    pub path: String,
    pub mime_type: String,
    pub size_bytes: i64,
    pub content_cas: String,
    pub thumbnail_cas: Option<String>,
    pub versions_json: String,
    pub current_version: i32,
    pub tags_json: String,
    pub source_uri: Option<String>,
    pub embedding: Vec<f32>,
    pub is_public: bool,
    pub is_encrypted: bool,
    pub sync_mode: String,  // NEW: "private|public|shared"
    pub upload_status: String,
    pub chunk_count: Option<i32>,
    pub chunks_received: Option<i32>,
    pub synced: bool,  // NEW: Track sync status locally
    pub created_at: DateTime<Utc>,
    pub updated_at: DateTime<Utc>,
}

impl FileRecord {
    pub fn new(
        did: String,
        space: Space,
        name: String,
        path: String,
        mime_type: String,
        size_bytes: i64,
        content_cas: String,
    ) -> Self {
        let id = uuid::Uuid::new_v4().to_string();
        let now = Utc::now();

        // ✅ Let namespace.rs own the (service, res_type) mapping for files.
        // Generate: przma://did/files/{space}/file/{id}
        let przma_uri = UriBuilder::file(&did, &id, space.clone()).to_string();

        let version = serde_json::json!([{
            "version": 1,
            "cas": content_cas.clone(),
            "changed_at": now.timestamp_micros(),
            "size": size_bytes,
        }]);

        // ✅ Determine sync mode from official Space enum
        let sync_mode = get_sync_mode(&space);

        Self {
            id,
            did,
            space: space.as_str(),
            przma_uri,
            name,
            path,
            mime_type,
            size_bytes,
            content_cas,
            thumbnail_cas: None,
            versions_json: version.to_string(),
            current_version: 1,
            tags_json: "[]".to_string(),
            source_uri: None,
            embedding: vec![0.0; 768],
            is_public: matches!(space, Space::Commons),
            is_encrypted: false,
            sync_mode: format!("{:?}", sync_mode).to_lowercase(),
            upload_status: "complete".to_string(),
            chunk_count: None,
            chunks_received: None,
            synced: false,
            created_at: now,
            updated_at: now,
        }
    }
}

// ✅ Helper function to determine sync mode from official Space enum
fn get_sync_mode(space: &Space) -> SyncMode {
    match space {
        Space::Core => SyncMode::Private,      // Encrypted on backend
        Space::Commons => SyncMode::Public,    // Public on backend
        Space::Circle(_) => SyncMode::Shared,  // Group-encrypted on backend
    }
}
