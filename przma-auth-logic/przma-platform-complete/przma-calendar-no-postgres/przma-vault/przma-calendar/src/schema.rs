// przma-calendar/src/schema.rs
//
// Arrow / LanceDB schema definitions for all PRZMA Calendar tables.
// These define the physical column layout stored in Lance format files.

use arrow_schema::{DataType, Field, Fields, Schema};
use std::sync::Arc;

// ─── EMBEDDING DIMENSION ─────────────────────────────────────────────────────
pub const EMBEDDING_DIM: i32 = 768;

// ─── CALENDAR EVENTS ─────────────────────────────────────────────────────────

pub fn calendar_event_schema() -> Arc<Schema> {
    Arc::new(Schema::new(Fields::from(vec![
        // Identity
        Field::new("id",              DataType::Utf8, false),
        Field::new("did",             DataType::Utf8, false),
        Field::new("space",           DataType::Utf8, false),
        Field::new("circle_did",      DataType::Utf8, true),

        // Core fields
        Field::new("title",           DataType::Utf8, false),
        Field::new("description",     DataType::Utf8, false),
        Field::new("category",        DataType::Utf8, false),
        Field::new("sub_type",        DataType::Utf8, false),
        Field::new("location_type",   DataType::Utf8, false),
        Field::new("location_ref",    DataType::Utf8, false),

        // Time — stored as microseconds since epoch (Int64)
        Field::new("start_at",        DataType::Int64, false),
        Field::new("end_at",          DataType::Int64, false),
        Field::new("all_day",         DataType::Boolean, false),
        Field::new("timezone",        DataType::Utf8, false),
        Field::new("rrule",           DataType::Utf8, true),
        Field::new("recurrence_id",   DataType::Utf8, true),
        Field::new("is_recurring",    DataType::Boolean, false),

        // Visibility & governance
        Field::new("visibility",      DataType::Utf8, false),
        Field::new("status",          DataType::Utf8, false),
        Field::new("busy_status",     DataType::Utf8, false),

        // Attendees — stored as JSON strings for simplicity
        Field::new("organiser_did",   DataType::Utf8, false),
        Field::new("attendees_json",  DataType::Utf8, false),
        Field::new("attendee_status_json", DataType::Utf8, false),

        // Companion & intelligence
        Field::new("has_pre_brief",   DataType::Boolean, false),
        Field::new("has_reflection",  DataType::Boolean, false),
        Field::new("companion_mode",  DataType::Utf8, false),
        Field::new("notes_cas_json",  DataType::Utf8, false),
        Field::new("attachments_cas_json", DataType::Utf8, false),

        // Semantic embedding — FixedSizeList<Float32>
        Field::new(
            "embedding",
            DataType::FixedSizeList(
                Arc::new(Field::new("item", DataType::Float32, false)),
                EMBEDDING_DIM,
            ),
            false,
        ),

        // Federation
        Field::new("ap_object_id",    DataType::Utf8, true),
        Field::new("ical_uid",        DataType::Utf8, false),
        Field::new("external_id",     DataType::Utf8, true),

        // Metadata
        Field::new("created_at",      DataType::Int64, false),
        Field::new("updated_at",      DataType::Int64, false),
        Field::new("version",         DataType::Int32, false),
        Field::new("created_by",      DataType::Utf8, false),
    ])))
}

// ─── CALENDAR TASKS ───────────────────────────────────────────────────────────

pub fn calendar_task_schema() -> Arc<Schema> {
    Arc::new(Schema::new(Fields::from(vec![
        Field::new("id",              DataType::Utf8, false),
        Field::new("did",             DataType::Utf8, false),
        Field::new("space",           DataType::Utf8, false),
        Field::new("circle_did",      DataType::Utf8, true),
        Field::new("title",           DataType::Utf8, false),
        Field::new("description",     DataType::Utf8, false),
        Field::new("category",        DataType::Utf8, false),
        Field::new("priority",        DataType::Utf8, false),
        Field::new("status",          DataType::Utf8, false),
        Field::new("due_at",          DataType::Int64, true),
        Field::new("start_at",        DataType::Int64, true),
        Field::new("event_id",        DataType::Utf8, true),
        Field::new("rrule",           DataType::Utf8, true),
        Field::new("assigned_to_json",DataType::Utf8, false),
        Field::new("assigned_by",     DataType::Utf8, false),
        Field::new("progress_pct",    DataType::Int32, false),
        Field::new("blocked_reason",  DataType::Utf8, true),
        Field::new("completed_at",    DataType::Int64, true),
        Field::new("completed_by",    DataType::Utf8, true),
        Field::new("notes_cas_json",  DataType::Utf8, false),
        Field::new(
            "embedding",
            DataType::FixedSizeList(
                Arc::new(Field::new("item", DataType::Float32, false)),
                EMBEDDING_DIM,
            ),
            false,
        ),
        Field::new("created_at",      DataType::Int64, false),
        Field::new("updated_at",      DataType::Int64, false),
        Field::new("version",         DataType::Int32, false),
    ])))
}

// ─── AVAILABILITY WINDOWS ─────────────────────────────────────────────────────

pub fn availability_window_schema() -> Arc<Schema> {
    Arc::new(Schema::new(Fields::from(vec![
        Field::new("id",              DataType::Utf8, false),
        Field::new("did",             DataType::Utf8, false),
        Field::new("window_type",     DataType::Utf8, false),
        Field::new("start_at",        DataType::Int64, false),
        Field::new("end_at",          DataType::Int64, false),
        Field::new("rrule",           DataType::Utf8, true),
        Field::new("timezone",        DataType::Utf8, false),
        Field::new("visibility",      DataType::Utf8, false),
        Field::new("show_as",         DataType::Utf8, false),
        Field::new("shared_with_json",DataType::Utf8, false),
        Field::new("is_bookable",     DataType::Boolean, false),
        Field::new("booking_link_id", DataType::Utf8, true),
        Field::new("min_notice_mins", DataType::Int32, false),
        Field::new("buffer_mins",     DataType::Int32, false),
        Field::new("created_at",      DataType::Int64, false),
        Field::new("updated_at",      DataType::Int64, false),
    ])))
}

// ─── BOOKING LINKS ────────────────────────────────────────────────────────────

pub fn booking_link_schema() -> Arc<Schema> {
    Arc::new(Schema::new(Fields::from(vec![
        Field::new("id",              DataType::Utf8, false),
        Field::new("did",             DataType::Utf8, false),
        Field::new("title",           DataType::Utf8, false),
        Field::new("description",     DataType::Utf8, false),
        Field::new("duration_mins",   DataType::Int32, false),
        Field::new("location_type",   DataType::Utf8, false),
        Field::new("location_ref",    DataType::Utf8, false),
        Field::new("availability_rule", DataType::Utf8, false),
        Field::new("questions_json",  DataType::Utf8, false),
        Field::new("confirmation_msg",DataType::Utf8, false),
        Field::new("is_active",       DataType::Boolean, false),
        Field::new("created_at",      DataType::Int64, false),
        Field::new("updated_at",      DataType::Int64, false),
    ])))
}

// ─── REMINDERS ────────────────────────────────────────────────────────────────

pub fn reminder_schema() -> Arc<Schema> {
    Arc::new(Schema::new(Fields::from(vec![
        Field::new("id",                   DataType::Utf8, false),
        Field::new("did",                  DataType::Utf8, false),
        Field::new("entity_type",          DataType::Utf8, false),
        Field::new("entity_id",            DataType::Utf8, false),
        Field::new("trigger_type",         DataType::Utf8, false),
        Field::new("trigger_mins",         DataType::Int32, true),
        Field::new("trigger_at",           DataType::Int64, true),
        Field::new("delivery_json",        DataType::Utf8, false),
        Field::new("message",              DataType::Utf8, true),
        Field::new("repeat",               DataType::Boolean, false),
        Field::new("repeat_interval_mins", DataType::Int32, true),
        Field::new("delivered_at",         DataType::Int64, true),
        Field::new("dismissed_at",         DataType::Int64, true),
        Field::new("created_at",           DataType::Int64, false),
    ])))
}

// ─── SCHEDULING POLLS ─────────────────────────────────────────────────────────

pub fn scheduling_poll_schema() -> Arc<Schema> {
    Arc::new(Schema::new(Fields::from(vec![
        Field::new("id",                 DataType::Utf8, false),
        Field::new("circle_did",         DataType::Utf8, false),
        Field::new("created_by",         DataType::Utf8, false),
        Field::new("title",              DataType::Utf8, false),
        Field::new("description",        DataType::Utf8, false),
        Field::new("poll_type",          DataType::Utf8, false),
        Field::new("options_json",       DataType::Utf8, false),
        Field::new("votes_json",         DataType::Utf8, false),
        Field::new("status",             DataType::Utf8, false),
        Field::new("resolved_option",    DataType::Utf8, true),
        Field::new("auto_create_event",  DataType::Boolean, false),
        Field::new("resulting_event_id", DataType::Utf8, true),
        Field::new("closes_at",          DataType::Int64, true),
        Field::new("created_at",         DataType::Int64, false),
        Field::new("updated_at",         DataType::Int64, false),
    ])))
}

// ─── TABLE NAMES ─────────────────────────────────────────────────────────────

/// Compute table path for a given namespace and space
pub fn table_path(
    base_path: &str,
    did: &str,
    namespace: &str,
    space_segment: &str,
    table: &str,
) -> String {
    format!("{}/{}/{}/{}/{}", base_path, did, namespace, space_segment, table)
}

pub mod tables {
    pub const EVENTS:       &str = "events";
    pub const TASKS:        &str = "tasks";
    pub const AVAILABILITY: &str = "availability";
    pub const BOOKING_LINKS:&str = "booking_links";
    pub const REMINDERS:    &str = "reminders";
    pub const POLLS:        &str = "polls";
}
