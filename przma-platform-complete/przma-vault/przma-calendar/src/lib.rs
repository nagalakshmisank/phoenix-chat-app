// przma-calendar/src/lib.rs
//
// PRZMA Calendar Service — Rust core data layer.
// Provides Lance-backed storage, BLAKE3 CAS, rrule expansion,
// and DuckDB analytics for all calendar entities.

// ─── ACTIVE MODULES ──────────────────────────────────────────────────────────
// Only the content-addressable storage path is currently consumed by the
// PRZMA desktop app (via przma-files → CasTable). These three modules form a
// self-contained, compiling unit: cas depends only on error + schema.
pub mod cas;
pub mod error;
pub mod schema;

pub use error::{CalendarError, CalendarResult};
pub use cas::CasStore;
pub use cas::CasTable;

// ─── PHASE 2+ MODULES (temporarily disabled) ─────────────────────────────────
// These modules carry pre-existing compilation errors (rrule::Tz FromStr,
// regex capture inference, BookingLink field drift, impl-Into-String as_ref)
// that are unrelated to the desktop files app. They are gated off until the
// calendar service is brought back up independently. Re-enable module-by-module
// once each is fixed.
//
// pub mod analytics_legacy;
// pub mod analytics;
// pub mod circle;
// pub mod events;
// pub mod federation;
// pub mod intelligence;
// pub mod models;
// pub mod recurrence;
// pub mod social;
// pub mod storage;
// pub mod tasks;
// pub mod availability;
// pub mod reminders;
// pub mod polls;
