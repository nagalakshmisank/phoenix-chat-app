// przma-calendar/src/analytics/mod.rs
// (replaces existing analytics.rs — moves it under analytics/)

pub mod embedding;
pub mod patterns;

// Re-export the original CalendarAnalytics from analytics.rs (now analytics/calendar.rs)
// For Phase 6: the top-level CalendarAnalytics is re-exported here for backwards compat
pub use super::analytics_legacy::CalendarAnalytics;
