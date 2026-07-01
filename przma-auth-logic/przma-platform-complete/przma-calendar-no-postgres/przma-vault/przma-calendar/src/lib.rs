// przma-calendar/src/lib.rs
//
// PRZMA Calendar Service — Rust core data layer.
// Provides Lance-backed storage, BLAKE3 CAS, rrule expansion,
// and DuckDB analytics for all calendar entities.

pub mod analytics_legacy;  // renamed from analytics.rs for backwards compat
pub mod analytics;
pub mod cas;
pub mod circle;
pub mod error;
pub mod events;
pub mod federation;
pub mod intelligence;
pub mod models;
pub mod recurrence;
pub mod schema;
pub mod social;
pub mod storage;

// Re-export primary analytics type
pub use analytics_legacy::CalendarAnalytics;

// Phase 2+ modules (stubs for now)
pub mod tasks;
pub mod availability;
pub mod reminders;
pub mod polls;

// Re-export primary types
pub use models::{
    AttendeeStatus, AvailabilityWindow, BookingLink, BusyStatus,
    CalendarEvent, CalendarTask, CompanionMode, EventCategory,
    EventStatus, FreeBusySlot, LocationType, PollOption,
    SchedulingPoll, Space, TaskPriority, TaskStatus,
};
pub use error::{CalendarError, CalendarResult};
pub use cas::CasStore;
pub use events::EventStore;
pub use analytics::CalendarAnalytics;
