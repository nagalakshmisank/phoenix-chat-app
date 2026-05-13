// przma-calendar/src/storage/adapter.rs
//
// Unified storage adapter for all PRZMA deployment modes.
// Abstracts S3-compatible (Cloud SaaS, BYOS), local disk (Home/Local),
// and federation-aware storage behind a single async interface.

use crate::error::{CalendarError, CalendarResult};
use serde::{Deserialize, Serialize};
use std::path::PathBuf;
use tokio::fs;

// ─── STORAGE MODE ────────────────────────────────────────────────────────────

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "snake_case")]
pub enum StorageMode {
    /// Cloud SaaS — PRZMA-managed S3 bucket
    CloudSaas {
        endpoint:   String,
        bucket:     String,
        region:     String,
    },
    /// Bring Your Own Storage — user's S3-compatible bucket
    Byos {
        endpoint:          String,
        bucket:            String,
        region:            String,
        access_key_id:     String,
        secret_access_key: String,
        session_token:     Option<String>,
        path_prefix:       String,    // per-user prefix within bucket
    },
    /// Local disk — home server or local computer
    Local {
        base_path: PathBuf,
    },
    /// Own domain — user-hosted server with own S3 or local disk
    OwnDomain {
        base_path: PathBuf,
        instance_url: String,
    },
}

impl StorageMode {
    pub fn mode_name(&self) -> &'static str {
        match self {
            Self::CloudSaas { .. }  => "cloud_saas",
            Self::Byos { .. }       => "byos",
            Self::Local { .. }      => "local",
            Self::OwnDomain { .. }  => "own_domain",
        }
    }

    pub fn is_local(&self) -> bool {
        matches!(self, Self::Local { .. } | Self::OwnDomain { .. })
    }

    pub fn is_cloud(&self) -> bool {
        matches!(self, Self::CloudSaas { .. } | Self::Byos { .. })
    }

    pub fn base_path(&self) -> Option<&PathBuf> {
        match self {
            Self::Local { base_path }          => Some(base_path),
            Self::OwnDomain { base_path, .. }  => Some(base_path),
            _                                  => None,
        }
    }
}

// ─── STORAGE CREDENTIALS ─────────────────────────────────────────────────────

/// Short-lived S3 credentials for BYOS mode.
/// Rotated every 6 hours by the Phoenix credential manager.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct S3Credentials {
    pub access_key_id:     String,
    pub secret_access_key: String,
    pub session_token:     Option<String>,
    pub expires_at:        i64,    // Unix timestamp seconds
    pub endpoint:          String,
    pub bucket:            String,
    pub region:            String,
    pub path_prefix:       String,
}

impl S3Credentials {
    pub fn is_expired(&self) -> bool {
        let now = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap_or_default()
            .as_secs() as i64;
        self.expires_at <= now + 300  // refresh 5 min early
    }
}

// ─── STORAGE ADAPTER ─────────────────────────────────────────────────────────

/// Unified blob storage interface.
/// Callers do not need to know which storage backend is active.
pub struct StorageAdapter {
    mode: StorageMode,
}

impl StorageAdapter {
    pub fn new(mode: StorageMode) -> Self {
        Self { mode }
    }

    /// Detect mode from environment / config
    pub fn from_env() -> Self {
        let mode = if let Ok(base) = std::env::var("PRZMA_LOCAL_PATH") {
            StorageMode::Local { base_path: PathBuf::from(base) }
        } else {
            StorageMode::CloudSaas {
                endpoint: std::env::var("PRZMA_S3_ENDPOINT")
                    .unwrap_or_else(|_| "https://s3.amazonaws.com".to_string()),
                bucket:   std::env::var("PRZMA_S3_BUCKET")
                    .unwrap_or_else(|_| "przma-vaults".to_string()),
                region:   std::env::var("PRZMA_S3_REGION")
                    .unwrap_or_else(|_| "us-east-1".to_string()),
            }
        };
        Self::new(mode)
    }

    // ── READ ─────────────────────────────────────────────────────────────────

    pub async fn get(&self, key: &str) -> CalendarResult<Vec<u8>> {
        match &self.mode {
            StorageMode::Local { base_path } |
            StorageMode::OwnDomain { base_path, .. } => {
                local_read(base_path, key).await
            }
            StorageMode::CloudSaas { endpoint, bucket, region } => {
                s3_read(endpoint, bucket, region, key, None).await
            }
            StorageMode::Byos {
                endpoint, bucket, region,
                access_key_id, secret_access_key, session_token, path_prefix
            } => {
                let full_key = format!("{}/{}", path_prefix.trim_end_matches('/'), key);
                s3_read(endpoint, bucket, region, &full_key,
                    Some((access_key_id, secret_access_key, session_token))).await
            }
        }
    }

    // ── WRITE ────────────────────────────────────────────────────────────────

    pub async fn put(&self, key: &str, data: &[u8]) -> CalendarResult<()> {
        match &self.mode {
            StorageMode::Local { base_path } |
            StorageMode::OwnDomain { base_path, .. } => {
                local_write(base_path, key, data).await
            }
            StorageMode::CloudSaas { endpoint, bucket, region } => {
                s3_write(endpoint, bucket, region, key, data, None).await
            }
            StorageMode::Byos {
                endpoint, bucket, region,
                access_key_id, secret_access_key, session_token, path_prefix
            } => {
                let full_key = format!("{}/{}", path_prefix.trim_end_matches('/'), key);
                s3_write(endpoint, bucket, region, &full_key, data,
                    Some((access_key_id, secret_access_key, session_token))).await
            }
        }
    }

    // ── DELETE ───────────────────────────────────────────────────────────────

    pub async fn delete(&self, key: &str) -> CalendarResult<()> {
        match &self.mode {
            StorageMode::Local { base_path } |
            StorageMode::OwnDomain { base_path, .. } => {
                local_delete(base_path, key).await
            }
            StorageMode::CloudSaas { endpoint, bucket, region } => {
                s3_delete(endpoint, bucket, region, key, None).await
            }
            StorageMode::Byos {
                endpoint, bucket, region,
                access_key_id, secret_access_key, session_token, path_prefix
            } => {
                let full_key = format!("{}/{}", path_prefix.trim_end_matches('/'), key);
                s3_delete(endpoint, bucket, region, &full_key,
                    Some((access_key_id, secret_access_key, session_token))).await
            }
        }
    }

    // ── EXISTS ───────────────────────────────────────────────────────────────

    pub async fn exists(&self, key: &str) -> bool {
        self.get(key).await.is_ok()
    }

    // ── MODE INFO ────────────────────────────────────────────────────────────

    pub fn mode_name(&self) -> &'static str {
        self.mode.mode_name()
    }

    pub fn is_local(&self) -> bool {
        self.mode.is_local()
    }
}

// ─── LOCAL DISK OPERATIONS ───────────────────────────────────────────────────

async fn local_read(base_path: &PathBuf, key: &str) -> CalendarResult<Vec<u8>> {
    let path = base_path.join(sanitize_key(key));
    fs::read(&path).await.map_err(|e| {
        if e.kind() == std::io::ErrorKind::NotFound {
            CalendarError::NotFound(format!("Local: {}", key))
        } else {
            CalendarError::Io(e)
        }
    })
}

async fn local_write(base_path: &PathBuf, key: &str, data: &[u8]) -> CalendarResult<()> {
    let path = base_path.join(sanitize_key(key));
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent).await?;
    }
    fs::write(&path, data).await?;
    Ok(())
}

async fn local_delete(base_path: &PathBuf, key: &str) -> CalendarResult<()> {
    let path = base_path.join(sanitize_key(key));
    if path.exists() {
        fs::remove_file(&path).await?;
    }
    Ok(())
}

fn sanitize_key(key: &str) -> String {
    key.replace("..", "__")
       .replace('\\', "/")
       .trim_start_matches('/')
       .to_string()
}

// ─── S3 OPERATIONS ───────────────────────────────────────────────────────────
// Phase 5: real AWS SigV4 signing via aws-sdk-rust or rusoto.
// For Phase 5 implementation: HTTP-based S3 API with presigned URLs
// generated by the Phoenix credential manager.

type OptCreds<'a> = Option<(&'a str, &'a str, &'a Option<String>)>;

async fn s3_read(
    endpoint: &str,
    bucket:   &str,
    region:   &str,
    key:      &str,
    creds:    OptCreds<'_>,
) -> CalendarResult<Vec<u8>> {
    // Phase 5: real S3 GET with SigV4
    // Placeholder: return error indicating S3 not yet connected
    Err(CalendarError::Cas(format!(
        "S3 read not yet connected: {}/{}/{}", endpoint, bucket, key
    )))
}

async fn s3_write(
    endpoint: &str,
    bucket:   &str,
    region:   &str,
    key:      &str,
    data:     &[u8],
    creds:    OptCreds<'_>,
) -> CalendarResult<()> {
    // Phase 5: real S3 PUT with SigV4
    Err(CalendarError::Cas(format!(
        "S3 write not yet connected: {}/{}/{}", endpoint, bucket, key
    )))
}

async fn s3_delete(
    endpoint: &str,
    bucket:   &str,
    region:   &str,
    key:      &str,
    creds:    OptCreds<'_>,
) -> CalendarResult<()> {
    Err(CalendarError::Cas(format!(
        "S3 delete not yet connected: {}/{}/{}", endpoint, bucket, key
    )))
}

// ─── TESTS ───────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;
    use tempfile::tempdir;

    #[tokio::test]
    async fn test_local_write_read_delete() {
        let dir  = tempdir().unwrap();
        let mode = StorageMode::Local { base_path: dir.path().to_path_buf() };
        let s    = StorageAdapter::new(mode);

        let data = b"hello przma storage";
        s.put("did:web:alice/calendar/test.bin", data).await.unwrap();
        let back = s.get("did:web:alice/calendar/test.bin").await.unwrap();
        assert_eq!(back, data);

        s.delete("did:web:alice/calendar/test.bin").await.unwrap();
        assert!(!s.exists("did:web:alice/calendar/test.bin").await);
    }

    #[tokio::test]
    async fn test_local_creates_nested_dirs() {
        let dir  = tempdir().unwrap();
        let mode = StorageMode::Local { base_path: dir.path().to_path_buf() };
        let s    = StorageAdapter::new(mode);
        s.put("deep/nested/dir/file.bin", b"data").await.unwrap();
        assert!(s.exists("deep/nested/dir/file.bin").await);
    }

    #[test]
    fn test_sanitize_key_prevents_traversal() {
        let k = sanitize_key("../../etc/passwd");
        assert!(!k.contains(".."));
    }

    #[test]
    fn test_mode_names() {
        let local = StorageMode::Local { base_path: PathBuf::from("/tmp") };
        assert_eq!(local.mode_name(), "local");
        assert!(local.is_local());
        assert!(!local.is_cloud());
    }

    #[test]
    fn test_credentials_expiry() {
        let now = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_secs() as i64;

        let expired = S3Credentials {
            expires_at: now - 100,
            access_key_id: "".to_string(),
            secret_access_key: "".to_string(),
            session_token: None,
            endpoint: "".to_string(),
            bucket: "".to_string(),
            region: "".to_string(),
            path_prefix: "".to_string(),
        };
        assert!(expired.is_expired());

        let fresh = S3Credentials { expires_at: now + 3600, ..expired };
        assert!(!fresh.is_expired());
    }
}
