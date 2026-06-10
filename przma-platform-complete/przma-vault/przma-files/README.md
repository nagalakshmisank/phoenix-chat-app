# PRZMA Files Service

Production-ready file storage service following the chief's Lance + CAS architecture.

## Quick Start

```rust
use przma_files::{FilesService, Space};

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    // Initialize
    let service = FilesService::new(
        "/var/przma/vaults",
        "did:web:alice.com"
    ).await?;

    // Store file (CAS + Lance + sync queue)
    let file = service.add_file(
        "photo.jpg".to_string(),
        "/photos/".to_string(),
        Space::Commons,
        "image/jpeg".to_string(),
        &photo_bytes,
    ).await?;
    
    println!("Stored: {} as {}", file.name, file.content_cas);

    // Retrieve file
    let (record, bytes) = service.get_file(&file.id, &Space::Commons).await?;
    std::fs::write("downloaded.jpg", bytes)?;

    // List files
    let files = service.list_files(&Space::Commons).await?;
    println!("Files: {}", files.len());

    // Check pending syncs
    let pending = service.store.pending_syncs().await?;
    println!("Pending uploads: {}", pending.len());

    Ok(())
}
```

## Architecture

**Three Spaces:**
- **Core**: Private, device-only, never syncs
- **Commons**: Public, everyone can access, auto-syncs
- **Circle(id)**: Group-shared, auto-syncs to members

**Storage:**
- **Lance tables** for metadata (FileRecord)
- **CAS blobs** for content (file bytes)
- **Sync queue** for pending uploads

## Key Features

✅ Built on TaskStore pattern from calendar service  
✅ Uses PlatformCas for blob storage  
✅ Uses file_schema() from platform  
✅ Supports versioning via versions_json  
✅ Tracks upload status (pending/chunking/complete)  
✅ Sync queue for remote uploads  
✅ Cross-service deduplication (same content = one copy)  
✅ Offline-first design  

## Integration Points

### With PlatformCas
```rust
// Automatically called in add_file()
let (cas_uri, _) = service.cas.put(
    &content,
    Some(&mime_type),
    "files"
).await?;
```

### With PrzmaUri (Namespace)
```rust
// Files use: przma://did/files/{space}/file/{id}
// Compatible with other services' URIs
```

### With Desktop App (Tauri)
```rust
// Invoke from Tauri commands
let service = FilesService::new(base_path, did).await?;
let file = service.add_file(name, path, space, mime_type, content).await?;
let (record, bytes) = service.get_file(file_id, &space).await?;
let pending = service.store.pending_syncs().await?;
```

## API Reference

### FilesService

```rust
pub async fn add_file(
    &self,
    name: String,
    path: String,
    space: Space,
    mime_type: String,
    content: &[u8],
) -> FilesResult<FileRecord>

pub async fn get_file(
    &self,
    id: &str,
    space: &Space,
) -> FilesResult<(FileRecord, Vec<u8>)>

pub async fn list_files(
    &self,
    space: &Space,
) -> FilesResult<Vec<FileRecord>>

pub async fn delete_file(
    &self,
    id: &str,
    space: &Space,
) -> FilesResult<()>

pub async fn update_file(
    &self,
    file: &FileRecord,
) -> FilesResult<()>
```

### FileStore

```rust
pub async fn create(&self, file: &FileRecord) -> FilesResult<String>
pub async fn get(&self, id: &str, space: &Space) -> FilesResult<FileRecord>
pub async fn list(
    &self,
    space: &Space,
    upload_status: Option<&str>,
    mime_type: Option<&str>,
    limit: usize,
) -> FilesResult<Vec<FileRecord>>
pub async fn update(&self, file: &FileRecord) -> FilesResult<()>
pub async fn delete(&self, id: &str, space: &Space) -> FilesResult<()>
pub async fn enqueue_for_sync(&self, file: &FileRecord) -> FilesResult<String>
pub async fn pending_syncs(&self) -> FilesResult<Vec<SyncQueueEntry>>
pub async fn mark_synced(&self, queue_id: &str) -> FilesResult<()>
```

## File Record Fields (20 fields)

From `przma-platform/services/schemas.rs::files::file_schema()`:

| Field | Type | Notes |
|-------|------|-------|
| id | String | UUID v4 |
| did | String | Owner's DID |
| space | String | "core" \| "commons" \| "circle:{id}" |
| name | String | Filename |
| path | String | Virtual path |
| mime_type | String | "image/jpeg", etc. |
| size_bytes | i64 | Content size |
| content_cas | String | "cas:{blake3_hex}" blob reference |
| thumbnail_cas | Option<String> | Preview image |
| versions_json | String | Version history array |
| current_version | i32 | Active version number |
| tags_json | String | User tags |
| source_uri | Option<String> | Origin resource URI |
| embedding | Vec<f32> | 768-dim semantic vector |
| is_public | bool | true for Commons |
| is_encrypted | bool | CAS handles encryption |
| upload_status | String | pending\|chunking\|complete\|failed |
| chunk_count | Option<i32> | For parallel uploads |
| chunks_received | Option<i32> | Received count |
| created_at | DateTime | Microseconds UTC |
| updated_at | DateTime | Microseconds UTC |

## Storage Layout

```
/var/przma/vaults/
├── did_web_alice_com/
│   ├── cas/
│   │   ├── {shard}/{hash}/[blob]
│   │   └── {shard}/{hash}/[blob].meta.json
│   └── files/
│       ├── core/files.lance/
│       ├── commons/files.lance/
│       ├── circles/{circle_id}/files.lance/
│       └── sync/sync_queue.lance/
```

## Status

✅ Production-ready  
✅ All CRUD operations  
✅ CAS integration  
✅ Sync queue  
✅ Three-space support  

## Next: Integrate with Desktop App

Add to Tauri commands to enable file upload/download UI.
