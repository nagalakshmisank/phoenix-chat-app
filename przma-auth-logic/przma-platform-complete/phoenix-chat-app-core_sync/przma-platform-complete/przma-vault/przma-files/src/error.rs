use std::fmt;

#[derive(Debug)]
pub enum FilesError {
    NotFound(String),
    Storage(String),
    Arrow(String),
    Serialization(String),
    InvalidSpace(String),
    Other(String),
}

impl fmt::Display for FilesError {
    fn fmt(&self, f: &mut fmt::Formatter) -> fmt::Result {
        match self {
            FilesError::NotFound(msg) => write!(f, "Not found: {}", msg),
            FilesError::Storage(msg) => write!(f, "Storage error: {}", msg),
            FilesError::Arrow(msg) => write!(f, "Arrow error: {}", msg),
            FilesError::Serialization(msg) => write!(f, "Serialization error: {}", msg),
            FilesError::InvalidSpace(msg) => write!(f, "Invalid space: {}", msg),
            FilesError::Other(msg) => write!(f, "Error: {}", msg),
        }
    }
}

impl std::error::Error for FilesError {}

pub type FilesResult<T> = Result<T, FilesError>;

impl From<lancedb::Error> for FilesError {
    fn from(e: lancedb::Error) -> Self {
        FilesError::Storage(e.to_string())
    }
}

impl From<serde_json::Error> for FilesError {
    fn from(e: serde_json::Error) -> Self {
        FilesError::Serialization(e.to_string())
    }
}

impl From<tokio::io::Error> for FilesError {
    fn from(e: tokio::io::Error) -> Self {
        FilesError::Other(e.to_string())
    }
}
