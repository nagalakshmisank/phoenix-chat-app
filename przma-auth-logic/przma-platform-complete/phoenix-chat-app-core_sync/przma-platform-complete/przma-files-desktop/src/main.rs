#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

mod sync_worker;

use serde::{Deserialize, Serialize};
use std::path::PathBuf;
use std::sync::{Arc, Mutex};
use tokio::sync::Mutex as AsyncMutex;
use once_cell::sync::Lazy;
use base64::Engine;

// ✅ USE THE PROVEN PLATFORM IMPLEMENTATIONS DIRECTLY!
use przma_files::{FilesService, FileRecord as PlatformFileRecord};
use przma_platform::namespace::Space;
use sync_worker::SyncWorker;

// ─────────────────────────────────────────────────────────────────────────────
// GLOBAL APPLICATION STATE
// ─────────────────────────────────────────────────────────────────────────────

pub static FILES_SERVICE: Lazy<Arc<AsyncMutex<Option<FilesService>>>> = Lazy::new(|| {
    Arc::new(AsyncMutex::new(None))
});

pub static SYNC_WORKER: Lazy<Mutex<Option<Arc<SyncWorker>>>> = Lazy::new(|| {
    Mutex::new(None)
});

pub static CURRENT_DID: Lazy<Mutex<String>> = Lazy::new(|| {
    Mutex::new(std::env::var("PRZMA_DID")
        .unwrap_or_else(|_| "did:web:alice.com".to_string()))
});

// ─────────────────────────────────────────────────────────────────────────────
// API RESPONSE TYPES - For Tauri IPC
// ─────────────────────────────────────────────────────────────────────────────

#[derive(Serialize, Deserialize, Clone, Debug)]
pub struct FileResponse {
    pub id: String,
    pub name: String,
    pub path: String,
    pub space: String,
    pub mime_type: String,
    pub size_bytes: i64,
    pub content_cas: String,
    pub przma_uri: String,
    pub is_public: bool,
    pub sync_mode: String,
    pub synced: bool,
    pub created_at: String,
    pub updated_at: String,
}

impl From<PlatformFileRecord> for FileResponse {
    fn from(file: PlatformFileRecord) -> Self {
        Self {
            id: file.id,
            name: file.name,
            path: file.path,
            space: file.space,
            mime_type: file.mime_type,
            size_bytes: file.size_bytes,
            content_cas: file.content_cas,
            przma_uri: file.przma_uri,
            is_public: file.is_public,
            sync_mode: file.sync_mode,
            synced: file.synced,
            created_at: file.created_at.to_rfc3339(),
            updated_at: file.updated_at.to_rfc3339(),
        }
    }
}

#[derive(Serialize, Deserialize)]
pub struct UploadResponse {
    pub success: bool,
    pub file_id: String,
    pub content_cas: String,
    pub space: String,
    pub przma_uri: String,
}

#[derive(Serialize, Deserialize)]
pub struct ListFilesResponse {
    pub files: Vec<FileResponse>,
    pub total_count: usize,
}

#[derive(Serialize, Deserialize)]
pub struct DeleteResponse {
    pub success: bool,
    pub file_id: String,
    pub ref_count_after: u32,
}

#[derive(Serialize, Deserialize)]
pub struct CasStatsResponse {
    pub total_files: usize,
    pub total_unique_blobs: usize,
    pub namespace: String,
    pub space: String,
}

// ─────────────────────────────────────────────────────────────────────────────
// TAURI COMMANDS - IPC Handlers
// ─────────────────────────────────────────────────────────────────────────────

/// Upload a file to the FILES service
/// ✅ Uses FilesService.add_file() which handles:
///    - BLAKE3 hashing + CAS deduplication (ref_count tracking)
///    - Lance metadata storage
///    - Space-based access control
///    - Sync queue for backend
#[tauri::command]
async fn upload_file(
    file_name: String,
    file_path: String,
    space: String,
    mime_type: String,
    content: String,  // Base64-encoded
) -> Result<UploadResponse, String> {
    let svc_lock = FILES_SERVICE.lock().await;

    let service = svc_lock
        .as_ref()
        .ok_or("Files service not initialized")?;

    let space_enum = Space::try_from(space.as_str())
        .map_err(|e| format!("Invalid space: {}", e))?;

    // Shared-space files (Commons/Circle) get pushed to the backend.
    let is_shared = matches!(space_enum, Space::Commons | Space::Circle(_));

    // Decode base64
    let bytes = base64::engine::general_purpose::STANDARD
        .decode(&content)
        .map_err(|e| format!("Base64 decode failed: {}", e))?;

    let file = service
        .add_file(file_name, file_path, space_enum, mime_type, &bytes)
        .await
        .map_err(|e| format!("Upload failed: {}", e))?;

    tracing::info!(
        file_id = %file.id,
        name = %file.name,
        cas = %file.content_cas,
        "File uploaded successfully"
    );

    // Release the service lock before nudging the worker.
    drop(svc_lock);

    // Event-driven sync: wake the worker so shared files upload promptly
    // instead of waiting for the periodic fallback tick.
    if is_shared {
        if let Ok(guard) = SYNC_WORKER.lock() {
            if let Some(worker) = guard.as_ref() {
                worker.trigger();
            }
        }
    }

    Ok(UploadResponse {
        success: true,
        file_id: file.id,
        content_cas: file.content_cas,
        space: file.space,
        przma_uri: file.przma_uri,
    })
}

/// Upload a file by streaming it from disk — the efficient ingest path.
/// ✅ No base64 inflation, no full-file buffering in the webview or Rust.
///    Hashes + (optionally) encrypts while streaming into CAS.
#[tauri::command]
async fn upload_file_from_path(
    file_name: String,
    file_path: String,
    space: String,
    mime_type: String,
    src_path: String,
) -> Result<UploadResponse, String> {
    let svc_lock = FILES_SERVICE.lock().await;

    let service = svc_lock
        .as_ref()
        .ok_or("Files service not initialized")?;

    let space_enum = Space::try_from(space.as_str())
        .map_err(|e| format!("Invalid space: {}", e))?;

    let is_shared = matches!(space_enum, Space::Commons | Space::Circle(_));

    let mime = if mime_type.is_empty() {
        "application/octet-stream".to_string()
    } else {
        mime_type
    };

    let file = service
        .add_file_from_path(
            file_name,
            file_path,
            space_enum,
            mime,
            std::path::Path::new(&src_path),
        )
        .await
        .map_err(|e| format!("Upload failed: {}", e))?;

    tracing::info!(
        file_id = %file.id,
        name = %file.name,
        cas = %file.content_cas,
        "File streamed from disk successfully"
    );

    drop(svc_lock);

    if is_shared {
        if let Ok(guard) = SYNC_WORKER.lock() {
            if let Some(worker) = guard.as_ref() {
                worker.trigger();
            }
        }
    }

    Ok(UploadResponse {
        success: true,
        file_id: file.id,
        content_cas: file.content_cas,
        space: file.space,
        przma_uri: file.przma_uri,
    })
}

/// List all files in a given space
/// ✅ Uses FilesService.list_files() which queries Lance directly
#[tauri::command]
async fn list_files(space: String) -> Result<ListFilesResponse, String> {
    let svc_lock = FILES_SERVICE.lock().await;

    let service = svc_lock
        .as_ref()
        .ok_or("Files service not initialized")?;

    let space_enum = Space::try_from(space.as_str())
        .map_err(|e| format!("Invalid space: {}", e))?;

    let files = service
        .list_files(&space_enum)
        .await
        .map_err(|e| format!("List failed: {}", e))?;

    let count = files.len();
    let responses: Vec<FileResponse> = files.into_iter().map(|f| f.into()).collect();

    tracing::info!(count = count, space = %space, "Listed files");

    Ok(ListFilesResponse {
        files: responses,
        total_count: count,
    })
}

/// Delete a file from the FILES service
/// ✅ Uses FilesService.delete_file() which:
///    - Removes file record from Lance
///    - Decrements CAS ref_count
///    - Auto-deletes blob when ref_count = 0
///    - Maintains deduplication integrity
#[tauri::command]
async fn delete_file(file_id: String, space: String) -> Result<DeleteResponse, String> {
    let svc_lock = FILES_SERVICE.lock().await;

    let service = svc_lock
        .as_ref()
        .ok_or("Files service not initialized")?;

    let space_enum = Space::try_from(space.as_str())
        .map_err(|e| format!("Invalid space: {}", e))?;

    service
        .delete_file(&file_id, &space_enum)
        .await
        .map_err(|e| format!("Delete failed: {}", e))?;

    tracing::info!(file_id = %file_id, space = %space, "File deleted");

    Ok(DeleteResponse {
        success: true,
        file_id,
        ref_count_after: 0,
    })
}

/// Get file content from CAS
/// ✅ Uses FilesService.get_file() which retrieves blob from CAS
#[tauri::command]
async fn get_file_content(file_id: String, space: String) -> Result<Vec<u8>, String> {
    let svc_lock = FILES_SERVICE.lock().await;

    let service = svc_lock
        .as_ref()
        .ok_or("Files service not initialized")?;

    let space_enum = Space::try_from(space.as_str())
        .map_err(|e| format!("Invalid space: {}", e))?;

    let (_file, content) = service
        .get_file(&file_id, &space_enum)
        .await
        .map_err(|e| format!("Get file failed: {}", e))?;

    Ok(content)
}

/// Get CAS statistics
/// ✅ Shows deduplication effectiveness
#[tauri::command]
async fn get_cas_stats(space: String) -> Result<CasStatsResponse, String> {
    let svc_lock = FILES_SERVICE.lock().await;

    let service = svc_lock
        .as_ref()
        .ok_or("Files service not initialized")?;

    let did = CURRENT_DID
        .lock()
        .map_err(|e| format!("Lock failed: {}", e))?
        .clone();

    let space_enum = Space::try_from(space.as_str())
        .map_err(|e| format!("Invalid space: {}", e))?;

    let files = service
        .list_files(&space_enum)
        .await
        .map_err(|e| format!("Stats failed: {}", e))?;

    // Count unique blobs (CAS refs)
    let unique_blobs = files
        .iter()
        .map(|f| &f.content_cas)
        .collect::<std::collections::HashSet<_>>()
        .len();

    Ok(CasStatsResponse {
        total_files: files.len(),
        total_unique_blobs: unique_blobs,
        namespace: did,
        space,
    })
}

/// Get sync status - check how many files are pending sync
#[tauri::command]
async fn get_sync_status() -> Result<serde_json::Value, String> {
    let svc_lock = FILES_SERVICE.lock().await;

    let service = svc_lock
        .as_ref()
        .ok_or("Files service not initialized")?;

    let pending = service
        .get_pending_syncs()
        .await
        .map_err(|e| format!("Query failed: {}", e))?;

    Ok(serde_json::json!({
        "pending_count": pending.len(),
        "pending": pending.iter().map(|p| serde_json::json!({
            "file_id": p.file_id,
            "file_name": p.file_name,
            "space": p.space,
            "status": p.status,
            "retry_count": p.retry_count,
            "error": p.error_msg,
        })).collect::<Vec<_>>(),
    }))
}

/// Set online status (called when window online/offline event fires)
#[tauri::command]
fn set_online_status(online: bool) -> Result<(), String> {
    let worker_lock = SYNC_WORKER
        .lock()
        .map_err(|e| format!("Lock failed: {}", e))?;

    if let Some(worker) = worker_lock.as_ref() {
        worker.set_online(online);
        tracing::info!(online = online, "Network status updated");
    }

    Ok(())
}

/// Return the current user's DID (for the UI header).
#[tauri::command]
fn get_did() -> String {
    CURRENT_DID
        .lock()
        .map(|d| d.clone())
        .unwrap_or_default()
}

// ─────────────────────────────────────────────────────────────────────────────
// APPLICATION INITIALIZATION
// ─────────────────────────────────────────────────────────────────────────────

fn main() {
    // Initialize tracing for logs
    tracing_subscriber::fmt()
        .with_max_level(tracing::Level::DEBUG)
        .init();

    // Get base path for local storage
    let base_path = dirs::config_dir()
        .map(|p| p.join("przma-files-desktop"))
        .unwrap_or_else(|| PathBuf::from("./przma-files-desktop"));

    // Get user DID (already initialized in CURRENT_DID)
    let did = CURRENT_DID
        .lock()
        .expect("Failed to read DID")
        .clone();

    // Build and run Tauri application with async setup
    tauri::Builder::default()
        .plugin(tauri_plugin_dialog::init())
        .setup(move |_app| {
            // Initialize FilesService with proven platform implementation
            tracing::info!(
                did = %did,
                base_path = %base_path.display(),
                "🚀 Initializing PRZMA Files Desktop"
            );

            // Use a blocking task to initialize async service
            let rt = tokio::runtime::Runtime::new()
                .map_err(|e| tauri::Error::Io(std::io::Error::new(
                    std::io::ErrorKind::Other,
                    e.to_string(),
                )))?;

            let files_service = rt.block_on(async {
                FilesService::new(base_path.to_str().unwrap(), &did)
                    .await
                    .map_err(|e| {
                        let msg = format!("Failed to initialize FilesService: {}", e);
                        tracing::error!("{}", msg);
                        tauri::Error::Io(std::io::Error::new(
                            std::io::ErrorKind::Other,
                            msg,
                        ))
                    })
            })?;

            // Store the initialized service in global state.
            let rt_service = tokio::runtime::Handle::current();
            rt_service.block_on(async {
                let mut svc_lock = FILES_SERVICE.lock().await;
                *svc_lock = Some(files_service);
            });

            // ─── Initialize sync worker ───────────────────────────────────
            // Create SyncWorker and spawn background sync task
            let backend_url = std::env::var("PRZMA_BACKEND_URL")
                .unwrap_or_else(|_| "http://localhost:4000".to_string());

            let worker = Arc::new(SyncWorker::new(
                FILES_SERVICE.clone(),
                backend_url.clone(),
            ));

            // Spawn background sync task
            worker.start();

            // Store worker reference for online/offline events
            let mut worker_lock = SYNC_WORKER.lock()
                .map_err(|e| tauri::Error::Io(std::io::Error::new(
                    std::io::ErrorKind::Other,
                    e.to_string(),
                )))?;
            *worker_lock = Some(worker);

            tracing::info!(
                backend_url = %backend_url,
                "✅ PRZMA Files Desktop initialized successfully"
            );
            Ok(())
        })
        .invoke_handler(tauri::generate_handler![
            upload_file,
            upload_file_from_path,
            list_files,
            delete_file,
            get_file_content,
            get_cas_stats,
            get_sync_status,
            set_online_status,
            get_did,
        ])
        .run(tauri::generate_context!())
        .expect("error while running tauri application");
}
