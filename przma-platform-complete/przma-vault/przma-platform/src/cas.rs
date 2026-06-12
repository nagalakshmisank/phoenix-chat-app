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
//   {base_path}/{did}/cas/{shard_2}/{blake3_hex_64}   ← raw blobs (sharded)
//   {base_path}/{did}/cas/cas_table/                  ← Lance metadata table
//
// Blob bytes live on disk (sharded by the first 2 hex chars of the hash).
// Per-blob metadata (size, mime, ref_count, …) lives in a Lance table — NOT
// in `.meta.json` sidecars. ref_count is updated atomically with Lance
// `merge_insert`, and a blob is deleted immediately when its ref_count hits 0.
//
// Services write through PlatformCas and reference blobs by hash URI:
//   cas:{blake3_hex_64}

use serde::{Deserialize, Serialize};
use std::io::Cursor;
use std::path::{Path, PathBuf};
use std::sync::Arc;
use tokio::fs;
use tokio::io::{AsyncReadExt, AsyncWriteExt};

use arrow_array::{
    Array, BooleanArray, Int64Array, RecordBatch, RecordBatchIterator,
    StringArray, UInt32Array, UInt64Array,
};
use arrow_schema::{DataType, Field, Fields, Schema};
use futures::TryStreamExt;
use lancedb::query::{ExecutableQuery, QueryBase};
use lancedb::{connect, Table};

use crate::crypto::{VaultCipher, ENC_MAGIC};
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

/// Per-blob metadata, stored as a row in the `cas_table` Lance table.
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

/// Arrow schema for the CAS metadata table (Lance-backed, no `.json` sidecars).
fn cas_table_schema() -> Arc<Schema> {
    Arc::new(Schema::new(Fields::from(vec![
        Field::new("hash",         DataType::Utf8,   false),
        Field::new("did",          DataType::Utf8,   false),
        Field::new("mime_type",    DataType::Utf8,   true),
        Field::new("size_bytes",   DataType::UInt64, false),
        Field::new("created_at",   DataType::Int64,  false),
        Field::new("created_by",   DataType::Utf8,   false),
        Field::new("ref_count",    DataType::UInt32, false),
        Field::new("is_encrypted", DataType::Boolean, false),
    ])))
}

const CAS_TABLE: &str = "cas_table";

// ─── PLATFORM CAS ────────────────────────────────────────────────────────────

pub struct PlatformCas {
    base_path: PathBuf,
    did:       String,
    cipher:    Option<VaultCipher>,
}

impl PlatformCas {
    pub fn new(base_path: impl Into<PathBuf>, did: impl Into<String>) -> Self {
        Self {
            base_path: base_path.into(),
            did:       did.into(),
            cipher:    None,
        }
    }

    /// Attach a vault cipher so blobs written with `encrypt = true` are stored
    /// encrypted at rest (and transparently decrypted on read).
    pub fn with_cipher(mut self, cipher: VaultCipher) -> Self {
        self.cipher = Some(cipher);
        self
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

    /// Public on-disk path to a blob, for callers that want to stream it
    /// directly from disk (e.g. the sync worker) instead of loading it into
    /// memory via `get()`. Returns the path whether or not the blob exists.
    pub fn blob_file_path(&self, uri: &CasUri) -> PathBuf {
        self.blob_path(uri.hash())
    }

    /// Lance dataset directory for the CAS metadata table.
    fn table_path(&self) -> String {
        self.cas_root().join(CAS_TABLE).to_string_lossy().to_string()
    }

    /// Open the CAS metadata table, creating it if absent. lancedb 0.9 may not
    /// persist an empty table created on a different connection, so every
    /// accessor must be able to (re)create it.
    async fn open_table(&self) -> PlatformResult<Table> {
        let conn = connect(&self.table_path()).execute().await?;
        let expected = cas_table_schema();
        match conn.open_table(CAS_TABLE).execute().await {
            Ok(table) => {
                let ok = matches!(table.schema().await, Ok(s) if s.fields().len() == expected.fields().len());
                if ok {
                    Ok(table)
                } else {
                    let _ = conn.drop_table(CAS_TABLE).await;
                    Ok(conn.create_empty_table(CAS_TABLE, expected).execute().await?)
                }
            }
            Err(_) => Ok(conn.create_empty_table(CAS_TABLE, expected).execute().await?),
        }
    }

    /// Read the current ref_count for a hash (0 if no row exists).
    async fn read_ref_count(&self, table: &Table, hash: &str) -> PlatformResult<u32> {
        let batches: Vec<RecordBatch> = table
            .query()
            .only_if(format!("hash = '{}'", hash))
            .limit(1)
            .execute().await?
            .try_collect().await?;

        Ok(batches
            .first()
            .and_then(|b| b.column_by_name("ref_count"))
            .and_then(|c| c.as_any().downcast_ref::<UInt32Array>())
            .filter(|a| !a.is_empty())
            .map(|a| a.value(0))
            .unwrap_or(0))
    }

    /// Build a one-row metadata batch.
    fn meta_batch(&self, entry: &CasEntry) -> PlatformResult<RecordBatch> {
        let schema = cas_table_schema();
        RecordBatch::try_new(schema, vec![
            Arc::new(StringArray::from(vec![entry.hash.as_str()])),
            Arc::new(StringArray::from(vec![self.did.as_str()])),
            Arc::new(StringArray::from(vec![entry.mime_type.as_deref()])),
            Arc::new(UInt64Array::from(vec![entry.size_bytes])),
            Arc::new(Int64Array::from(vec![entry.created_at])),
            Arc::new(StringArray::from(vec![entry.created_by.as_str()])),
            Arc::new(UInt32Array::from(vec![entry.ref_count])),
            Arc::new(BooleanArray::from(vec![entry.is_encrypted])),
        ]).map_err(|e| PlatformError::Arrow(e.to_string()))
    }

    /// Upsert a metadata row keyed on `hash` (atomic single-row update).
    async fn upsert_meta(&self, table: &Table, entry: &CasEntry) -> PlatformResult<()> {
        let schema = cas_table_schema();
        let batch  = self.meta_batch(entry)?;
        let mut merge = table.merge_insert(&["hash"]);
        merge.when_matched_update_all(None);
        merge.when_not_matched_insert_all();
        merge
            .execute(Box::new(RecordBatchIterator::new(vec![Ok(batch)], schema)))
            .await?;
        Ok(())
    }

    // ── WRITE ────────────────────────────────────────────────────────────────

    /// Write bytes to CAS. Idempotent — calling twice with same content just
    /// increments ref_count. The hash is always of the *plaintext*, so dedup
    /// works regardless of encryption. If `encrypt` is true (and a cipher is
    /// attached) the bytes are stored encrypted at rest.
    /// Returns the BLAKE3 hash URI and whether the blob was newly written.
    pub async fn put(
        &self,
        data:       &[u8],
        mime_type:  Option<&str>,
        written_by: &str,
        encrypt:    bool,
    ) -> PlatformResult<(CasUri, bool)> {
        let hash  = hash_bytes(data);
        let table = self.open_table().await?;

        let current = self.read_ref_count(&table, &hash).await?;
        if current > 0 {
            // Blob already tracked — bump ref_count only.
            let entry = self.load_entry(&table, &hash).await?.map(|mut e| {
                e.ref_count = current + 1;
                e
            });
            if let Some(entry) = entry {
                self.upsert_meta(&table, &entry).await?;
            }
            return Ok((CasUri::new(&hash), false));
        }

        // New blob — write bytes to disk (sharded).
        let path = self.blob_path(&hash);
        let do_encrypt = encrypt && self.cipher.is_some();
        if !path.exists() {
            if let Some(parent) = path.parent() {
                fs::create_dir_all(parent).await?;
            }
            if do_encrypt {
                let cipher = self.cipher.as_ref().unwrap();
                let mut f = fs::File::create(&path).await?;
                cipher.encrypt_stream(Cursor::new(data.to_vec()), &mut f).await?;
                f.flush().await?;
            } else {
                fs::write(&path, data).await?;
            }
            tracing::debug!(hash = %hash, bytes = data.len(), by = written_by, encrypted = do_encrypt, "CAS: wrote blob");
        }

        let entry = CasEntry {
            hash:         hash.clone(),
            size_bytes:   data.len() as u64,
            mime_type:    mime_type.map(|s| s.to_string()),
            created_at:   chrono::Utc::now().timestamp_micros(),
            created_by:   written_by.to_string(),
            ref_count:    1,
            is_encrypted: do_encrypt,
        };
        self.upsert_meta(&table, &entry).await?;

        Ok((CasUri::new(&hash), true))
    }

    /// Stream a file from disk into CAS without ever buffering it in memory.
    /// Hashes the plaintext while reading, writing (encrypted or raw) to a temp
    /// file, then atomically renames it to its content-addressed location.
    /// This is the efficient ingest path for large uploads.
    pub async fn put_from_path(
        &self,
        src:        &Path,
        mime_type:  Option<&str>,
        written_by: &str,
        encrypt:    bool,
    ) -> PlatformResult<(CasUri, bool)> {
        let do_encrypt = encrypt && self.cipher.is_some();

        // Write to a temp file in the CAS root (same filesystem → atomic rename).
        let cas_root = self.cas_root();
        fs::create_dir_all(&cas_root).await?;
        let temp = cas_root.join(format!(".tmp-{}", uuid::Uuid::new_v4()));

        let mut reader = fs::File::open(src).await?;

        let (hash, size) = if do_encrypt {
            let cipher = self.cipher.as_ref().unwrap();
            let mut tmpf = fs::File::create(&temp).await?;
            let result = cipher.encrypt_stream(&mut reader, &mut tmpf).await;
            tmpf.flush().await.ok();
            match result {
                Ok(v) => v,
                Err(e) => { let _ = fs::remove_file(&temp).await; return Err(e); }
            }
        } else {
            // Stream-copy while hashing the plaintext.
            let mut tmpf = fs::File::create(&temp).await?;
            let mut hasher = blake3::Hasher::new();
            let mut total: u64 = 0;
            let mut buf = vec![0u8; 64 * 1024];
            loop {
                let n = match reader.read(&mut buf).await {
                    Ok(n) => n,
                    Err(e) => { let _ = fs::remove_file(&temp).await; return Err(PlatformError::Io(e)); }
                };
                if n == 0 { break; }
                hasher.update(&buf[..n]);
                if let Err(e) = tmpf.write_all(&buf[..n]).await {
                    let _ = fs::remove_file(&temp).await;
                    return Err(PlatformError::Io(e));
                }
                total += n as u64;
            }
            tmpf.flush().await.ok();
            (hasher.finalize().to_hex().to_string(), total)
        };

        let table = self.open_table().await?;
        let current = self.read_ref_count(&table, &hash).await?;
        if current > 0 {
            // Already stored — discard temp, bump ref_count.
            let _ = fs::remove_file(&temp).await;
            if let Some(mut entry) = self.load_entry(&table, &hash).await? {
                entry.ref_count = current + 1;
                self.upsert_meta(&table, &entry).await?;
            }
            return Ok((CasUri::new(&hash), false));
        }

        // Move temp into its content-addressed location.
        let dest = self.blob_path(&hash);
        if dest.exists() {
            let _ = fs::remove_file(&temp).await;
        } else {
            if let Some(parent) = dest.parent() {
                fs::create_dir_all(parent).await?;
            }
            fs::rename(&temp, &dest).await?;
        }

        let entry = CasEntry {
            hash:         hash.clone(),
            size_bytes:   size,
            mime_type:    mime_type.map(|s| s.to_string()),
            created_at:   chrono::Utc::now().timestamp_micros(),
            created_by:   written_by.to_string(),
            ref_count:    1,
            is_encrypted: do_encrypt,
        };
        self.upsert_meta(&table, &entry).await?;

        tracing::debug!(hash = %hash, bytes = size, by = written_by, encrypted = do_encrypt, "CAS: streamed blob from disk");
        Ok((CasUri::new(&hash), true))
    }

    /// Write string text to CAS (convenience wrapper for UTF-8 content)
    pub async fn put_text(
        &self,
        text:       &str,
        written_by: &str,
    ) -> PlatformResult<CasUri> {
        let (uri, _) = self.put(text.as_bytes(), Some("text/plain"), written_by, false).await?;
        Ok(uri)
    }

    /// Write JSON-serializable value to CAS
    pub async fn put_json<T: serde::Serialize>(
        &self,
        value:      &T,
        written_by: &str,
    ) -> PlatformResult<CasUri> {
        let bytes = serde_json::to_vec(value)?;
        let (uri, _) = self.put(&bytes, Some("application/json"), written_by, false).await?;
        Ok(uri)
    }

    // ── READ ─────────────────────────────────────────────────────────────────

    pub async fn get(&self, uri: &CasUri) -> PlatformResult<Vec<u8>> {
        let path = self.blob_path(uri.hash());
        let raw = fs::read(&path).await.map_err(|e| {
            if e.kind() == std::io::ErrorKind::NotFound {
                PlatformError::CasNotFound(uri.to_string())
            } else {
                PlatformError::Io(e)
            }
        })?;

        // Encrypted blobs carry a magic header — decrypt transparently.
        if raw.len() >= ENC_MAGIC.len() && &raw[..ENC_MAGIC.len()] == ENC_MAGIC {
            let cipher = self.cipher.as_ref().ok_or_else(|| {
                PlatformError::Encoding(format!("encrypted blob but no vault key: {}", uri))
            })?;
            let mut out = Vec::new();
            cipher.decrypt_stream(Cursor::new(raw), &mut out).await?;
            Ok(out)
        } else {
            Ok(raw)
        }
    }

    /// Like `get`, but verifies the decrypted content hashes back to the URI —
    /// detects on-disk corruption or tampering. Slower (re-hashes on read).
    pub async fn get_verified(&self, uri: &CasUri) -> PlatformResult<Vec<u8>> {
        let data = self.get(uri).await?;
        let actual = hash_bytes(&data);
        if actual != uri.hash() {
            return Err(PlatformError::Encoding(format!(
                "integrity check failed for {}: content hashes to {}",
                uri, actual
            )));
        }
        Ok(data)
    }

    pub async fn get_text(&self, uri: &CasUri) -> PlatformResult<String> {
        let bytes = self.get(uri).await?;
        String::from_utf8(bytes).map_err(|e| PlatformError::Encoding(e.to_string()))
    }

    pub async fn get_json<T: serde::de::DeserializeOwned>(&self, uri: &CasUri) -> PlatformResult<T> {
        let bytes = self.get(uri).await?;
        serde_json::from_slice(&bytes).map_err(PlatformError::Serde)
    }

    /// Load the full metadata row for a hash, if present.
    async fn load_entry(&self, table: &Table, hash: &str) -> PlatformResult<Option<CasEntry>> {
        let batches: Vec<RecordBatch> = table
            .query()
            .only_if(format!("hash = '{}'", hash))
            .limit(1)
            .execute().await?
            .try_collect().await?;

        for batch in batches {
            if batch.num_rows() == 0 { continue; }
            let s   = |n: &str| batch.column_by_name(n).and_then(|c| c.as_any().downcast_ref::<StringArray>());
            let hash_col = match s("hash") { Some(a) if !a.is_empty() => a.value(0).to_string(), _ => continue };
            let mime = s("mime_type").filter(|a| a.is_valid(0)).map(|a| a.value(0).to_string());
            let created_by = s("created_by").map(|a| a.value(0).to_string()).unwrap_or_default();
            let size_bytes = batch.column_by_name("size_bytes")
                .and_then(|c| c.as_any().downcast_ref::<UInt64Array>())
                .map(|a| a.value(0)).unwrap_or(0);
            let created_at = batch.column_by_name("created_at")
                .and_then(|c| c.as_any().downcast_ref::<Int64Array>())
                .map(|a| a.value(0)).unwrap_or(0);
            let ref_count = batch.column_by_name("ref_count")
                .and_then(|c| c.as_any().downcast_ref::<UInt32Array>())
                .map(|a| a.value(0)).unwrap_or(0);
            let is_encrypted = batch.column_by_name("is_encrypted")
                .and_then(|c| c.as_any().downcast_ref::<BooleanArray>())
                .map(|a| a.value(0)).unwrap_or(false);

            return Ok(Some(CasEntry {
                hash: hash_col,
                size_bytes,
                mime_type: mime,
                created_at,
                created_by,
                ref_count,
                is_encrypted,
            }));
        }
        Ok(None)
    }

    pub async fn get_meta(&self, uri: &CasUri) -> PlatformResult<CasEntry> {
        let table = self.open_table().await?;
        self.load_entry(&table, uri.hash())
            .await?
            .ok_or_else(|| PlatformError::CasNotFound(format!("meta:{}", uri.hash())))
    }

    pub async fn exists(&self, uri: &CasUri) -> bool {
        self.blob_path(uri.hash()).exists()
    }

    // ── DEREF ──────────────────────────────────────────────────────────────────

    /// Decrement ref count. When it reaches 0 the blob and its metadata row are
    /// deleted immediately. Returns the ref_count after the operation.
    pub async fn deref(&self, uri: &CasUri) -> PlatformResult<u32> {
        let hash  = uri.hash();
        let table = self.open_table().await?;

        let current = self.read_ref_count(&table, hash).await?;
        if current <= 1 {
            // Last reference (or untracked) — remove row and blob now.
            table.delete(&format!("hash = '{}'", hash)).await?;
            let path = self.blob_path(hash);
            if path.exists() {
                fs::remove_file(&path).await?;
            }
            tracing::debug!(hash = %hash, "CAS: ref_count = 0, blob deleted");
            Ok(0)
        } else {
            // Still referenced — decrement.
            if let Some(mut entry) = self.load_entry(&table, hash).await? {
                entry.ref_count = current - 1;
                self.upsert_meta(&table, &entry).await?;
            }
            Ok(current - 1)
        }
    }

    // ── GC ───────────────────────────────────────────────────────────────────

    /// Delete orphaned blobs — bytes on disk that have no row in the metadata
    /// table. With immediate deref-delete this is normally a no-op, but it
    /// cleans up after interrupted writes or external tampering.
    pub async fn gc(&self) -> PlatformResult<GcReport> {
        let mut report = GcReport::default();
        let cas_root = self.cas_root();
        if !cas_root.exists() {
            return Ok(report);
        }

        // Collect all known hashes from the Lance table.
        let table = self.open_table().await?;
        let batches: Vec<RecordBatch> = table.query().execute().await?.try_collect().await?;
        let mut known = std::collections::HashSet::new();
        for batch in &batches {
            if let Some(col) = batch.column_by_name("hash").and_then(|c| c.as_any().downcast_ref::<StringArray>()) {
                for i in 0..col.len() {
                    known.insert(col.value(i).to_string());
                }
            }
        }

        let mut shards = fs::read_dir(&cas_root).await?;
        while let Some(shard) = shards.next_entry().await? {
            let path = shard.path();
            // Skip the metadata table directory; only walk 2-char shard dirs.
            if !path.is_dir() { continue; }
            let name = shard.file_name();
            if name.to_str().map(|n| n.len() != 2).unwrap_or(true) { continue; }

            let mut entries = fs::read_dir(&path).await?;
            while let Some(entry) = entries.next_entry().await? {
                let blob = entry.path();
                let hash = match blob.file_name().and_then(|n| n.to_str()) {
                    Some(h) => h.to_string(),
                    None => continue,
                };
                if !known.contains(&hash) {
                    if let Ok(meta) = fs::metadata(&blob).await {
                        if fs::remove_file(&blob).await.is_ok() {
                            report.deleted_blobs += 1;
                            report.freed_bytes += meta.len();
                        } else {
                            report.errors += 1;
                        }
                    }
                }
            }
        }

        tracing::info!(
            deleted = report.deleted_blobs,
            freed_bytes = report.freed_bytes,
            errors = report.errors,
            "CAS GC complete"
        );
        Ok(report)
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

    async fn cas_encrypted() -> (PlatformCas, tempfile::TempDir) {
        let dir = tempdir().unwrap();
        let cas = PlatformCas::new(dir.path(), "did:web:alice.com")
            .with_cipher(VaultCipher::new(VaultCipher::generate_key()));
        (cas, dir)
    }

    #[tokio::test]
    async fn test_put_get_round_trip() {
        let (cas, _dir) = cas().await;
        let (uri, is_new) = cas.put(b"hello platform", Some("text/plain"), "vault", false).await.unwrap();
        assert!(uri.is_valid());
        assert!(is_new);
        let back = cas.get(&uri).await.unwrap();
        assert_eq!(back, b"hello platform");
    }

    #[tokio::test]
    async fn test_idempotent_put() {
        let (cas, _dir) = cas().await;
        let (u1, new1) = cas.put(b"same content", None, "calendar", false).await.unwrap();
        let (u2, new2) = cas.put(b"same content", None, "chat", false).await.unwrap();
        assert_eq!(u1, u2);    // same hash
        assert!(new1);         // first write
        assert!(!new2);        // already existed
    }

    #[tokio::test]
    async fn test_encrypted_put_get_round_trip() {
        let (cas, _dir) = cas_encrypted().await;
        let plaintext = b"top secret private note";
        let (uri, is_new) = cas.put(plaintext, Some("text/plain"), "vault", true).await.unwrap();
        assert!(is_new);
        // Hash is of plaintext (dedup on content).
        assert_eq!(uri.hash(), hash_bytes(plaintext));
        // On-disk bytes are ciphertext (start with the encryption magic).
        let raw = std::fs::read(cas.blob_file_path(&uri)).unwrap();
        assert!(raw.starts_with(ENC_MAGIC));
        assert_ne!(raw, plaintext);
        // get() transparently decrypts.
        let back = cas.get(&uri).await.unwrap();
        assert_eq!(back, plaintext);
        // get_verified() passes integrity check.
        let verified = cas.get_verified(&uri).await.unwrap();
        assert_eq!(verified, plaintext);
    }

    #[tokio::test]
    async fn test_put_from_path_plaintext() {
        let (cas, dir) = cas().await;
        let src = dir.path().join("upload.bin");
        let data: Vec<u8> = (0..150 * 1024).map(|i| (i % 253) as u8).collect();
        std::fs::write(&src, &data).unwrap();

        let (uri, is_new) = cas.put_from_path(&src, Some("application/octet-stream"), "files", false).await.unwrap();
        assert!(is_new);
        assert_eq!(uri.hash(), hash_bytes(&data));
        let back = cas.get(&uri).await.unwrap();
        assert_eq!(back, data);
        let meta = cas.get_meta(&uri).await.unwrap();
        assert_eq!(meta.size_bytes, data.len() as u64);
    }

    #[tokio::test]
    async fn test_put_from_path_encrypted() {
        let (cas, dir) = cas_encrypted().await;
        let src = dir.path().join("private.bin");
        let data: Vec<u8> = (0..130 * 1024).map(|i| (i % 250) as u8).collect();
        std::fs::write(&src, &data).unwrap();

        let (uri, _) = cas.put_from_path(&src, None, "vault", true).await.unwrap();
        assert_eq!(uri.hash(), hash_bytes(&data));
        let raw = std::fs::read(cas.blob_file_path(&uri)).unwrap();
        assert!(raw.starts_with(ENC_MAGIC));
        let back = cas.get(&uri).await.unwrap();
        assert_eq!(back, data);
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
        let (uri, _) = cas.put(b"data", Some("application/json"), "files", false).await.unwrap();
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
        let (written_uri, _) = cas.put(b"exists", None, "test", false).await.unwrap();
        assert!(cas.exists(&written_uri).await);
    }

    #[tokio::test]
    async fn test_deref_decrements() {
        let (cas, _dir) = cas().await;
        let (uri, _) = cas.put(b"deref test", None, "calendar", false).await.unwrap();
        let count = cas.deref(&uri).await.unwrap();
        assert_eq!(count, 0);
        // Blob removed immediately on last deref.
        assert!(!cas.exists(&uri).await);
    }

    #[tokio::test]
    async fn test_refcount_dedup() {
        let (cas, _dir) = cas().await;
        let (uri, _) = cas.put(b"shared blob", None, "files", false).await.unwrap();
        let _ = cas.put(b"shared blob", None, "calendar", false).await.unwrap(); // ref_count = 2
        // First deref: still referenced, blob stays.
        let c1 = cas.deref(&uri).await.unwrap();
        assert_eq!(c1, 1);
        assert!(cas.exists(&uri).await);
        // Second deref: last reference, blob deleted.
        let c2 = cas.deref(&uri).await.unwrap();
        assert_eq!(c2, 0);
        assert!(!cas.exists(&uri).await);
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
