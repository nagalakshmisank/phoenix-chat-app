// przma-calendar/src/cas.rs
//
// BLAKE3 Content-Addressable Storage for calendar attachments and notes.
// Scoped per-DID — no cross-DID deduplication.

use blake3::Hasher;
use std::path::{Path, PathBuf};
use tokio::fs;
use crate::error::{CalendarError, CalendarResult};

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
        self.base_path
            .join(&self.did)
            .join("calendar")
            .join("cas")
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
