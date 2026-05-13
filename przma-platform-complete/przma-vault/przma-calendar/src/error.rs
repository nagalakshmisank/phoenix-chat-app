// przma-calendar/src/error.rs

use thiserror::Error;

#[derive(Debug, Error)]
pub enum CalendarError {
    #[error("Lance error: {0}")]
    Lance(#[from] lancedb::Error),

    #[error("Arrow error: {0}")]
    Arrow(String),

    #[error("DuckDB error: {0}")]
    DuckDb(#[from] duckdb::Error),

    #[error("Serialization error: {0}")]
    Serde(#[from] serde_json::Error),

    #[error("Record not found: {0}")]
    NotFound(String),

    #[error("Permission denied: {0}")]
    PermissionDenied(String),

    #[error("Invalid field value: {0}")]
    InvalidField(String),

    #[error("Conflict: {0}")]
    Conflict(String),

    #[error("Recurrence error: {0}")]
    Recurrence(String),

    #[error("CAS error: {0}")]
    Cas(String),

    #[error("IO error: {0}")]
    Io(#[from] std::io::Error),
}

pub type CalendarResult<T> = Result<T, CalendarError>;
