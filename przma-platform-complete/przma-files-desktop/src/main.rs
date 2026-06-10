#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

use serde::{Deserialize, Serialize};
use std::path::PathBuf;
use std::sync::{Arc, Mutex};
use tokio::sync::Mutex as AsyncMutex;
use once_cell::sync::Lazy;
use base64::Engine;

// ✅ USE THE PROVEN PLATFORM IMPLEMENTATIONS DIRECTLY!
use przma_files::{FilesService, FileRecord as PlatformFileRecord};
use przma_platform::namespace::Space;

// ─────────────────────────────────────────────────────────────────────────────
// GLOBAL APPLICATION STATE
// ─────────────────────────────────────────────────────────────────────────────

pub static FILES_SERVICE: Lazy<Arc<AsyncMutex<Option<FilesService>>>> = Lazy::new(|| {
    Arc::new(AsyncMutex::new(None))
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

/// Sync pending files to backend
/// ✅ Uses FilesService.sync_to_backend() which:
///    - Uploads blobs to backend CAS
///    - Uploads metadata to backend Lance
///    - Tracks sync queue progress
#[tauri::command]
async fn sync_to_backend(server_url: String) -> Result<serde_json::Value, String> {
    let svc_lock = FILES_SERVICE.lock().await;

    let service = svc_lock
        .as_ref()
        .ok_or("Files service not initialized")?;

    service
        .sync_to_backend(&server_url)
        .await
        .map_err(|e| format!("Sync failed: {}", e))?;

    tracing::info!(server = %server_url, "Sync to backend complete");

    Ok(serde_json::json!({
        "success": true,
        "message": "Sync complete"
    }))
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
            // We're outside the async context here (block_on above has
            // returned), so blocking_lock() is safe.
            let mut svc_lock = FILES_SERVICE.blocking_lock();
            *svc_lock = Some(files_service);

            tracing::info!("✅ PRZMA Files Desktop initialized successfully");
            Ok(())
        })
        .invoke_handler(tauri::generate_handler![
            upload_file,
            list_files,
            delete_file,
            get_file_content,
            get_cas_stats,
            sync_to_backend,
            get_did,
        ])
        .run(tauri::generate_context!())
        .expect("error while running tauri application");
}
