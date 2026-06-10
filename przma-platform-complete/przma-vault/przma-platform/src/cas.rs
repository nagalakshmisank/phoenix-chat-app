// przma-platform/src/cas.rs
//
// Universal Content-Addressable Storage for the PRZMA platform.
//
// A single BLAKE3-keyed CAS per user vault, shared across ALL services.
// Calendar notes, chat attachments, file blobs, vault entries, and agent
// outputs all live in the same CAS. Services reference blobs by hash —
// they never copy data between namespaces.
//
// Physical layout:
//   {base_path}/{did}/cas/{shard_2}/{blake3_hex_64}
//
// The shard prefix (first 2 chars of hash) keeps directory sizes reasonable:
//   0..9 a..f prefix → max 256 shards × millions of blobs per shard
//
// Services write through PlatformCas and reference blobs by hash URI:
//   cas:{blake3_hex_64}
//
// Cross-service reference example:
//   Calendar event notes_cas = ["aabb...cc"]
//   Vault entry body_cas     = ["aabb...cc"]  ← same blob, same hash, stored once

use blake3::Hasher;
use serde::{Deserialize, Serialize};
use std::path::{Path, PathBuf};
use tokio::fs;
use crate::{PlatformError, PlatformResult};

// ─── CAS URI ─────────────────────────────────────────────────────────────────

/// A fully-qualified CAS reference across the PRZMA platform.
/// Format: `cas:{blake3_hex_64}`
#[derive(Debug, Clone, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub struct CasUri(pub String);

impl CasUri {
    pub fn new(hash: &str) -> Self {
        Self(format!("cas:{}", hash))
    }

    pub fn hash(&self) -> &str {
        self.0.strip_prefix("cas:").unwrap_or(&self.0)
    }

    pub fn is_valid(&self) -> bool {
        let h = self.hash();
        h.len() == 64 && h.chars().all(|c| c.is_ascii_hexdigit())
    }
}

impl std::fmt::Display for CasUri {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{}", self.0)
    }
}

// ─── CAS METADATA ────────────────────────────────────────────────────────────

/// Lightweight metadata stored alongside a CAS blob.
/// Lets services reconstruct context without reading the blob content.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CasEntry {
    pub hash:        String,          // BLAKE3 hex — the primary key
    pub size_bytes:  u64,
    pub mime_type:   Option<String>,  // "text/plain", "audio/webm", "application/json", ...
    pub created_at:  i64,             // Unix micros
    pub created_by:  String,          // service namespace that wrote this blob
    pub ref_count:   u32,             // how many service records reference this hash
    pub is_encrypted: bool,           // true if blob is encrypted with vault key
}

// ─── PLATFORM CAS ────────────────────────────────────────────────────────────

pub struct PlatformCas {
    base_path: PathBuf,
    did:       String,
}

impl PlatformCas {
    pub fn new(base_path: impl Into<PathBuf>, did: impl Into<String>) -> Self {
        Self {
            base_path: base_path.into(),
            did:       did.into(),
        }
    }

    fn cas_root(&self) -> PathBuf {
        // Windows doesn't allow colons in filenames (except drive letter).
        // DIDs have colons (did:web:alice.com), so sanitize them.
        let sanitized_did = self.did.replace(':', "_");
        self.base_path.join(&sanitized_did).join("cas")
    }

    fn blob_path(&self, hash: &str) -> PathBuf {
        // Shard by first 2 chars: {cas_root}/{aa}/{aabb...64chars}
        self.cas_root().join(&hash[..2]).join(hash)
    }

    fn meta_path(&self, hash: &str) -> PathBuf {
        self.blob_path(hash).with_extension("meta.json")
    }

    // ── WRITE ────────────────────────────────────────────────────────────────

    /// Write bytes to CAS. Idempotent — calling twice with same content is free.
    /// Returns the BLAKE3 hash and whether the blob was newly written.
    pub async fn put(
        &self,
        data:       &[u8],
        mime_type:  Option<&str>,
        written_by: &str,
    ) -> PlatformResult<(CasUri, bool)> {
        let hash = hash_bytes(data);
        let path = self.blob_path(&hash);
        let new  = !path.exists();

        if new {
            if let Some(parent) = path.parent() {
                fs::create_dir_all(parent).await?;
            }
            // Data is pre-encrypted by the encryption layer before calling put().
            // PlatformCas never sees plaintext directly.
            fs::write(&path, data).await?;

            // Write metadata sidecar
            let meta = CasEntry {
                hash:         hash.clone(),
                size_bytes:   data.len() as u64,
                mime_type:    mime_type.map(|s| s.to_string()),
                created_at:   chrono::Utc::now().timestamp_micros(),
                created_by:   written_by.to_string(),
                ref_count:    1,
                is_encrypted: true,   // platform assumption: all blobs are encrypted
            };
            let meta_json = serde_json::to_vec(&meta)?;
            fs::write(self.meta_path(&hash), meta_json).await?;

            tracing::debug!(hash = %hash, bytes = data.len(), by = written_by, "CAS: wrote blob");
        } else {
            // Blob exists — increment ref count in metadata
            let _: Option<()> = self.incr_ref_count(&hash).await.ok();
        }

        Ok((CasUri::new(&hash), new))
    }

    /// Write string text to CAS (convenience wrapper for UTF-8 content)
    pub async fn put_text(
        &self,
        text:       &str,
        written_by: &str,
    ) -> PlatformResult<CasUri> {
        let (uri, _) = self.put(text.as_bytes(), Some("text/plain"), written_by).await?;
        Ok(uri)
    }

    /// Write JSON-serializable value to CAS
    pub async fn put_json<T: serde::Serialize>(
        &self,
        value:      &T,
        written_by: &str,
    ) -> PlatformResult<CasUri> {
        let bytes = serde_json::to_vec(value)?;
        let (uri, _) = self.put(&bytes, Some("application/json"), written_by).await?;
        Ok(uri)
    }

    // ── READ ─────────────────────────────────────────────────────────────────

    pub async fn get(&self, uri: &CasUri) -> PlatformResult<Vec<u8>> {
        let path = self.blob_path(uri.hash());
        fs::read(&path).await.map_err(|e| {
            if e.kind() == std::io::ErrorKind::NotFound {
                PlatformError::CasNotFound(uri.to_string())
            } else {
                PlatformError::Io(e)
            }
        })
    }

    pub async fn get_text(&self, uri: &CasUri) -> PlatformResult<String> {
        let bytes = self.get(uri).await?;
        String::from_utf8(bytes).map_err(|e| PlatformError::Encoding(e.to_string()))
    }

    pub async fn get_json<T: serde::de::DeserializeOwned>(&self, uri: &CasUri) -> PlatformResult<T> {
        let bytes = self.get(uri).await?;
        serde_json::from_slice(&bytes).map_err(PlatformError::Serde)
    }

    pub async fn get_meta(&self, uri: &CasUri) -> PlatformResult<CasEntry> {
        let path  = self.meta_path(uri.hash());
        let bytes = fs::read(&path).await.map_err(|_| {
            PlatformError::CasNotFound(format!("meta:{}", uri.hash()))
        })?;
        serde_json::from_slice(&bytes).map_err(PlatformError::Serde)
    }

    pub async fn exists(&self, uri: &CasUri) -> bool {
        self.blob_path(uri.hash()).exists()
    }

    // ── DEREF ────────────────────────────────────────────────────────────────

    /// Decrement ref count. When count reaches 0, blob is eligible for GC.
    /// Actual deletion happens during a scheduled GC pass, not immediately.
    pub async fn deref(&self, uri: &CasUri) -> PlatformResult<u32> {
        let hash = uri.hash();
        let meta = self.get_meta(uri).await;
        if let Ok(mut entry) = meta {
            if entry.ref_count <= 1 {
                // Mark for GC — don't delete immediately (other services may still hold a ref)
                entry.ref_count = 0;
                tracing::debug!(hash = %hash, "CAS: ref_count = 0, eligible for GC");
            } else {
                entry.ref_count -= 1;
            }
            let meta_json = serde_json::to_vec(&entry)?;
            fs::write(self.meta_path(hash), meta_json).await?;
            Ok(entry.ref_count)
        } else {
            // No metadata — blob may have been GC'd already
            Ok(0)
        }
    }

    // ── GC ───────────────────────────────────────────────────────────────────

    /// Delete all blobs with ref_count = 0.
    /// Run nightly or when vault space is constrained.
    pub async fn gc(&self) -> PlatformResult<GcReport> {
        let mut deleted   = 0u64;
        let mut freed     = 0u64;
        let mut errors    = 0u64;
        let cas_root      = self.cas_root();

        if !cas_root.exists() { return Ok(GcReport::default()); }

        let mut shards = fs::read_dir(&cas_root).await?;
        while let Some(shard) = shards.next_entry().await? {
            let mut entries = fs::read_dir(shard.path()).await?;
            while let Some(entry) = entries.next_entry().await? {
                let path = entry.path();
                if path.extension().map(|e| e == "json").unwrap_or(false) {
                    continue; // skip .meta.json sidecars
                }
                let meta_path = path.with_extension("meta.json");
                if let Ok(meta_bytes) = fs::read(&meta_path).await {
                    if let Ok(meta) = serde_json::from_slice::<CasEntry>(&meta_bytes) {
                        if meta.ref_count == 0 {
                            let size = meta.size_bytes;
                            if fs::remove_file(&path).await.is_ok()
                                && fs::remove_file(&meta_path).await.is_ok() {
                                deleted += 1;
                                freed   += size;
                            } else {
                                errors += 1;
                            }
                        }
                    }
                }
            }
        }

        tracing::info!(
            deleted = deleted,
            freed_bytes = freed,
            errors = errors,
            "CAS GC complete"
        );
        Ok(GcReport { deleted_blobs: deleted, freed_bytes: freed, errors })
    }

    // ── HELPERS ──────────────────────────────────────────────────────────────

    async fn incr_ref_count(&self, hash: &str) -> PlatformResult<()> {
        let uri = CasUri::new(hash);
        if let Ok(mut entry) = self.get_meta(&uri).await {
            entry.ref_count += 1;
            let meta_json = serde_json::to_vec(&entry)?;
            fs::write(self.meta_path(hash), meta_json).await?;
        }
        Ok(())
    }
}

#[derive(Debug, Default)]
pub struct GcReport {
    pub deleted_blobs: u64,
    pub freed_bytes:   u64,
    pub errors:        u64,
}

// ─── HASHING ─────────────────────────────────────────────────────────────────

pub fn hash_bytes(data: &[u8]) -> String {
    blake3::hash(data).to_hex().to_string()
}

pub fn hash_str(s: &str) -> String {
    hash_bytes(s.as_bytes())
}

// ─── TESTS ───────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;
    use tempfile::tempdir;

    async fn cas() -> (PlatformCas, tempfile::TempDir) {
        let dir = tempdir().unwrap();
        let cas = PlatformCas::new(dir.path(), "did:web:alice.com");
        (cas, dir)
    }

    #[tokio::test]
    async fn test_put_get_round_trip() {
        let (cas, _dir) = cas().await;
        let (uri, is_new) = cas.put(b"hello platform", Some("text/plain"), "vault").await.unwrap();
        assert!(uri.is_valid());
        assert!(is_new);
        let back = cas.get(&uri).await.unwrap();
        assert_eq!(back, b"hello platform");
    }

    #[tokio::test]
    async fn test_idempotent_put() {
        let (cas, _dir) = cas().await;
        let (u1, new1) = cas.put(b"same content", None, "calendar").await.unwrap();
        let (u2, new2) = cas.put(b"same content", None, "chat").await.unwrap();
        assert_eq!(u1, u2);    // same hash
        assert!(new1);         // first write
        assert!(!new2);        // already existed
    }

    #[tokio::test]
    async fn test_put_text_and_get_text() {
        let (cas, _dir) = cas().await;
        let uri  = cas.put_text("reflection entry", "vault").await.unwrap();
        let back = cas.get_text(&uri).await.unwrap();
        assert_eq!(back, "reflection entry");
    }

    #[tokio::test]
    async fn test_get_meta() {
        let (cas, _dir) = cas().await;
        let (uri, _) = cas.put(b"data", Some("application/json"), "files").await.unwrap();
        let meta = cas.get_meta(&uri).await.unwrap();
        assert_eq!(meta.mime_type, Some("application/json".to_string()));
        assert_eq!(meta.created_by, "files");
        assert_eq!(meta.size_bytes, 4);
    }

    #[tokio::test]
    async fn test_exists_and_not_exists() {
        let (cas, _dir) = cas().await;
        let uri = CasUri::new("0000000000000000000000000000000000000000000000000000000000000000");
        assert!(!cas.exists(&uri).await);
        let (written_uri, _) = cas.put(b"exists", None, "test").await.unwrap();
        assert!(cas.exists(&written_uri).await);
    }

    #[tokio::test]
    async fn test_deref_decrements() {
        let (cas, _dir) = cas().await;
        let (uri, _) = cas.put(b"deref test", None, "calendar").await.unwrap();
        let count = cas.deref(&uri).await.unwrap();
        assert_eq!(count, 0);
    }

    #[tokio::test]
    async fn test_put_json_and_get_json() {
        let (cas, _dir) = cas().await;
        let value = serde_json::json!({"key": "value", "num": 42});
        let uri   = cas.put_json(&value, "metadata").await.unwrap();
        let back: serde_json::Value = cas.get_json(&uri).await.unwrap();
        assert_eq!(back["key"], "value");
    }

    #[test]
    fn test_cas_uri_validation() {
        assert!(CasUri::new(&"a".repeat(64)).is_valid());
        assert!(!CasUri::new("short").is_valid());
        assert!(!CasUri::new(&"z".repeat(64)).is_valid()); // z not hex
    }
}
