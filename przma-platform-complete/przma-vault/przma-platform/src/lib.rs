// przma-platform/src/lib.rs

pub mod cas;
pub mod crypto;
pub mod namespace;

use thiserror::Error;

#[derive(Debug, Error)]
pub enum PlatformError {
    #[error("CAS blob not found: {0}")]
    CasNotFound(String),

    #[error("Unknown service namespace: {0}")]
    UnknownService(String),

    #[error("Invalid URI: {0}")]
    InvalidUri(String),

    #[error("Encoding error: {0}")]
    Encoding(String),

    #[error("Serialisation error: {0}")]
    Serde(#[from] serde_json::Error),

    #[error("IO error: {0}")]
    Io(#[from] std::io::Error),

    #[error("Lance error: {0}")]
    Lance(#[from] lancedb::Error),

    #[error("Arrow error: {0}")]
    Arrow(String),
}

pub type PlatformResult<T> = Result<T, PlatformError>;

// Re-exports
pub use cas::{PlatformCas, CasUri, CasEntry};
pub use crypto::VaultCipher;
pub use namespace::{PrzmaUri, ServiceNamespace, Space, UriBuilder};

// Workspace sub-module
pub mod services {
    pub mod schemas;
}
