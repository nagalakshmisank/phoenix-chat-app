// przma-calendar/src/events.rs
//
// LanceDB read/write operations for CalendarEvent.
// All methods are async and operate on per-DID Lance tables.

use arrow_array::{
    Array, BooleanArray, FixedSizeListArray, Float32Array,
    Int32Array, Int64Array, RecordBatch, StringArray,
};
use arrow_schema::Schema;
use chrono::{DateTime, Utc};
use futures::TryStreamExt;
use lancedb::{
    connect,
    query::{QueryBase, Select},
    table::NewColumnTransform,
    Connection, Table,
};
use std::sync::Arc;

use crate::{
    error::{CalendarError, CalendarResult},
    models::{
        AttendeeStatus, BusyStatus, CalendarEvent, CompanionMode,
        EventCategory, EventStatus, LocationType, Space,
    },
    schema::{calendar_event_schema, table_path, tables},
};

// ─── EVENT STORE ─────────────────────────────────────────────────────────────

pub struct EventStore {
    conn:      Connection,
    base_path: String,
    did:       String,
}

impl EventStore {
    pub async fn new(
        base_path: impl Into<String>,
        did: impl Into<String>,
    ) -> CalendarResult<Self> {
        let base_path = base_path.into();
        let did       = did.into();
        let conn      = connect(&base_path).execute().await?;
        Ok(Self { conn, base_path, did })
    }

    // ── Table paths ──────────────────────────────────────────────────────────

    fn core_table_path(&self) -> String {
        table_path(&self.base_path, &self.did, "calendar", "core", tables::EVENTS)
    }

    fn circle_table_path(&self, circle_did: &str) -> String {
        table_path(
            &self.base_path,
            &self.did,
            "calendar",
            &format!("circles/{}", circle_did),
            tables::EVENTS,
        )
    }

    fn commons_table_path(&self) -> String {
        table_path(&self.base_path, &self.did, "calendar", "commons", tables::EVENTS)
    }

    fn resolve_table_path(&self, space: &Space) -> String {
        match space {
            Space::Core            => self.core_table_path(),
            Space::Circle(c)       => self.circle_table_path(c),
            Space::Commons         => self.commons_table_path(),
        }
    }

    // ── Open or create table ─────────────────────────────────────────────────

    async fn open_or_create_table(&self, path: &str) -> CalendarResult<Table> {
        match self.conn.open_table(path).execute().await {
            Ok(table) => Ok(table),
            Err(_) => {
                let schema = calendar_event_schema();
                let table  = self.conn
                    .create_empty_table(path, schema)
                    .execute()
                    .await?;
                Ok(table)
            }
        }
    }

    // ── CREATE ───────────────────────────────────────────────────────────────

    pub async fn create(&self, event: &CalendarEvent) -> CalendarResult<String> {
        let path  = self.resolve_table_path(&event.space);
        let table = self.open_or_create_table(&path).await?;
        let batch = event_to_record_batch(event)?;
        table.add(vec![batch]).execute().await?;
        tracing::info!(id = %event.id, title = %event.title, "Event created");
        Ok(event.id.clone())
    }

    // ── READ ─────────────────────────────────────────────────────────────────

    pub async fn get(&self, id: &str, space: &Space) -> CalendarResult<CalendarEvent> {
        let path  = self.resolve_table_path(space);
        let table = self.open_or_create_table(&path).await?;

        let batches: Vec<RecordBatch> = table
            .query()
            .filter(format!("id = '{}'", id))
            .limit(1)
            .execute()
            .await?
            .try_collect()
            .await
            .map_err(|e| CalendarError::Arrow(e.to_string()))?;

        batches
            .into_iter()
            .next()
            .and_then(|b| batch_to_events(b).ok())
            .and_then(|mut v| v.pop())
            .ok_or_else(|| CalendarError::NotFound(format!("Event not found: {}", id)))
    }

    // ── LIST ─────────────────────────────────────────────────────────────────

    pub async fn list(
        &self,
        space:      &Space,
        start:      Option<DateTime<Utc>>,
        end:        Option<DateTime<Utc>>,
        category:   Option<&str>,
        status:     Option<&str>,
        limit:      usize,
    ) -> CalendarResult<Vec<CalendarEvent>> {
        let path  = self.resolve_table_path(space);
        let table = self.open_or_create_table(&path).await?;

        // Build filter string
        let mut filters: Vec<String> = vec![];
        if let Some(s) = start {
            filters.push(format!("start_at >= {}", s.timestamp_micros()));
        }
        if let Some(e) = end {
            filters.push(format!("end_at <= {}", e.timestamp_micros()));
        }
        if let Some(cat) = category {
            filters.push(format!("category = '{}'", cat));
        }
        if let Some(st) = status {
            filters.push(format!("status = '{}'", st));
        }

        let mut query = table.query();
        if !filters.is_empty() {
            query = query.filter(filters.join(" AND "));
        }
        let batches: Vec<RecordBatch> = query
            .limit(limit)
            .execute()
            .await?
            .try_collect()
            .await
            .map_err(|e| CalendarError::Arrow(e.to_string()))?;

        let events: Vec<CalendarEvent> = batches
            .into_iter()
            .flat_map(|b| batch_to_events(b).unwrap_or_default())
            .collect();

        Ok(events)
    }

    // ── LIST BUSY (for free/busy calculation) ────────────────────────────────

    pub async fn list_busy(
        &self,
        start: DateTime<Utc>,
        end:   DateTime<Utc>,
    ) -> CalendarResult<Vec<CalendarEvent>> {
        self.list(
            &Space::Core,
            Some(start),
            Some(end),
            None,
            Some("confirmed"),
            500,
        ).await.map(|events| {
            events.into_iter()
                .filter(|e| e.busy_status == BusyStatus::Busy)
                .collect()
        })
    }

    // ── UPDATE ───────────────────────────────────────────────────────────────

    pub async fn update(&self, event: &CalendarEvent) -> CalendarResult<()> {
        let path  = self.resolve_table_path(&event.space);
        let table = self.open_or_create_table(&path).await?;

        // Delete old record and insert updated — LanceDB v0.9 update pattern
        table.delete(&format!("id = '{}'", event.id)).await?;
        let batch = event_to_record_batch(event)?;
        table.add(vec![batch]).execute().await?;

        tracing::info!(id = %event.id, version = event.version, "Event updated");
        Ok(())
    }

    // ── CANCEL ───────────────────────────────────────────────────────────────

    pub async fn cancel(
        &self,
        id:    &str,
        space: &Space,
    ) -> CalendarResult<CalendarEvent> {
        let mut event = self.get(id, space).await?;
        event.status     = EventStatus::Cancelled;
        event.updated_at = Utc::now();
        event.version   += 1;
        self.update(&event).await?;
        Ok(event)
    }

    // ── VECTOR SEARCH ────────────────────────────────────────────────────────

    pub async fn semantic_search(
        &self,
        space:     &Space,
        embedding: Vec<f32>,
        top_k:     usize,
        filter:    Option<&str>,
    ) -> CalendarResult<Vec<CalendarEvent>> {
        let path  = self.resolve_table_path(space);
        let table = self.open_or_create_table(&path).await?;

        let mut query = table
            .vector_search(embedding)
            .map_err(|e| CalendarError::Lance(e))?
            .limit(top_k);

        if let Some(f) = filter {
            query = query.filter(f);
        }

        let batches: Vec<RecordBatch> = query
            .execute()
            .await?
            .try_collect()
            .await
            .map_err(|e| CalendarError::Arrow(e.to_string()))?;

        Ok(batches.into_iter()
            .flat_map(|b| batch_to_events(b).unwrap_or_default())
            .collect())
    }
}

// ─── SERIALISATION HELPERS ────────────────────────────────────────────────────

/// Convert CalendarEvent to Arrow RecordBatch for Lance storage
pub fn event_to_record_batch(event: &CalendarEvent) -> CalendarResult<RecordBatch> {
    let schema = calendar_event_schema();

    // Serialize complex fields as JSON
    let attendees_json = serde_json::to_string(&event.attendees)?;
    let attendee_status_json = serde_json::to_string(&event.attendee_status)?;
    let notes_cas_json = serde_json::to_string(&event.notes_cas)?;
    let attachments_cas_json = serde_json::to_string(&event.attachments_cas)?;

    // Build fixed-size list for embedding
    let embedding_values = Float32Array::from(event.embedding.clone());
    let embedding_field  = arrow_schema::Field::new("item", arrow_schema::DataType::Float32, false);
    let embedding_array  = FixedSizeListArray::try_new(
        Arc::new(embedding_field),
        crate::schema::EMBEDDING_DIM,
        Arc::new(embedding_values),
        None,
    ).map_err(|e| CalendarError::Arrow(e.to_string()))?;

    let batch = RecordBatch::try_new(
        schema.clone(),
        vec![
            // Identity
            Arc::new(StringArray::from(vec![event.id.as_str()])),
            Arc::new(StringArray::from(vec![event.did.as_str()])),
            Arc::new(StringArray::from(vec![event.space.as_str().as_str()])),
            Arc::new(StringArray::from(vec![event.circle_did.as_deref()])),
            // Core
            Arc::new(StringArray::from(vec![event.title.as_str()])),
            Arc::new(StringArray::from(vec![event.description.as_str()])),
            Arc::new(StringArray::from(vec![event.category.as_str()])),
            Arc::new(StringArray::from(vec![event.sub_type.as_str()])),
            Arc::new(StringArray::from(vec![event.location_type.as_str()])),
            Arc::new(StringArray::from(vec![event.location_ref.as_str()])),
            // Time
            Arc::new(Int64Array::from(vec![event.start_at.timestamp_micros()])),
            Arc::new(Int64Array::from(vec![event.end_at.timestamp_micros()])),
            Arc::new(BooleanArray::from(vec![event.all_day])),
            Arc::new(StringArray::from(vec![event.timezone.as_str()])),
            Arc::new(StringArray::from(vec![event.rrule.as_deref()])),
            Arc::new(StringArray::from(vec![event.recurrence_id.as_deref()])),
            Arc::new(BooleanArray::from(vec![event.is_recurring])),
            // Visibility
            Arc::new(StringArray::from(vec![event.visibility.as_str()])),
            Arc::new(StringArray::from(vec![event.status.as_str()])),
            Arc::new(StringArray::from(vec![event.busy_status.as_str()])),
            // Attendees
            Arc::new(StringArray::from(vec![event.organiser_did.as_str()])),
            Arc::new(StringArray::from(vec![attendees_json.as_str()])),
            Arc::new(StringArray::from(vec![attendee_status_json.as_str()])),
            // Companion
            Arc::new(BooleanArray::from(vec![event.has_pre_brief])),
            Arc::new(BooleanArray::from(vec![event.has_reflection])),
            Arc::new(StringArray::from(vec![event.companion_mode.as_str()])),
            Arc::new(StringArray::from(vec![notes_cas_json.as_str()])),
            Arc::new(StringArray::from(vec![attachments_cas_json.as_str()])),
            // Embedding
            Arc::new(embedding_array),
            // Federation
            Arc::new(StringArray::from(vec![event.ap_object_id.as_deref()])),
            Arc::new(StringArray::from(vec![event.ical_uid.as_str()])),
            Arc::new(StringArray::from(vec![event.external_id.as_deref()])),
            // Metadata
            Arc::new(Int64Array::from(vec![event.created_at.timestamp_micros()])),
            Arc::new(Int64Array::from(vec![event.updated_at.timestamp_micros()])),
            Arc::new(Int32Array::from(vec![event.version])),
            Arc::new(StringArray::from(vec![event.created_by.as_str()])),
        ],
    ).map_err(|e| CalendarError::Arrow(e.to_string()))?;

    Ok(batch)
}

/// Convert Arrow RecordBatch back to Vec<CalendarEvent>
pub fn batch_to_events(batch: RecordBatch) -> CalendarResult<Vec<CalendarEvent>> {
    let num_rows = batch.num_rows();
    let mut events = Vec::with_capacity(num_rows);

    let col = |name: &str| -> &dyn Array {
        batch.column_by_name(name).expect(&format!("Column {} missing", name))
    };

    let strings = |name: &str| -> Vec<Option<&str>> {
        col(name).as_any().downcast_ref::<StringArray>()
            .expect("Expected StringArray")
            .iter().collect()
    };

    let ids         = strings("id");
    let dids        = strings("did");
    let spaces      = strings("space");
    let circle_dids = strings("circle_did");
    let titles      = strings("title");
    let descriptions= strings("description");
    let categories  = strings("category");
    let sub_types   = strings("sub_type");
    let loc_types   = strings("location_type");
    let loc_refs    = strings("location_ref");
    let timezones   = strings("timezone");
    let rrules      = strings("rrule");
    let rec_ids     = strings("recurrence_id");
    let visibilities= strings("visibility");
    let statuses    = strings("status");
    let busy_stats  = strings("busy_status");
    let org_dids    = strings("organiser_did");
    let attendees_j = strings("attendees_json");
    let att_stat_j  = strings("attendee_status_json");
    let comp_modes  = strings("companion_mode");
    let notes_j     = strings("notes_cas_json");
    let attach_j    = strings("attachments_cas_json");
    let ap_ids      = strings("ap_object_id");
    let ical_uids   = strings("ical_uid");
    let ext_ids     = strings("external_id");
    let created_bys = strings("created_by");

    let start_ats   = col("start_at").as_any().downcast_ref::<Int64Array>().unwrap();
    let end_ats     = col("end_at").as_any().downcast_ref::<Int64Array>().unwrap();
    let all_days    = col("all_day").as_any().downcast_ref::<BooleanArray>().unwrap();
    let is_recs     = col("is_recurring").as_any().downcast_ref::<BooleanArray>().unwrap();
    let has_prebs   = col("has_pre_brief").as_any().downcast_ref::<BooleanArray>().unwrap();
    let has_refs    = col("has_reflection").as_any().downcast_ref::<BooleanArray>().unwrap();
    let versions    = col("version").as_any().downcast_ref::<Int32Array>().unwrap();
    let created_ats = col("created_at").as_any().downcast_ref::<Int64Array>().unwrap();
    let updated_ats = col("updated_at").as_any().downcast_ref::<Int64Array>().unwrap();

    for i in 0..num_rows {
        let ts_to_utc = |ts: i64| -> DateTime<Utc> {
            DateTime::from_timestamp_micros(ts).unwrap_or_default()
        };

        let space = Space::try_from(spaces[i].unwrap_or("core"))?;
        let attendees: Vec<String> = serde_json::from_str(attendees_j[i].unwrap_or("[]")).unwrap_or_default();
        let attendee_status: std::collections::HashMap<String, AttendeeStatus> =
            serde_json::from_str(att_stat_j[i].unwrap_or("{}")).unwrap_or_default();
        let notes_cas: Vec<String> = serde_json::from_str(notes_j[i].unwrap_or("[]")).unwrap_or_default();
        let attachments_cas: Vec<String> = serde_json::from_str(attach_j[i].unwrap_or("[]")).unwrap_or_default();

        events.push(CalendarEvent {
            id:             ids[i].unwrap_or("").to_string(),
            did:            dids[i].unwrap_or("").to_string(),
            space,
            circle_did:     circle_dids[i].map(|s| s.to_string()),
            title:          titles[i].unwrap_or("").to_string(),
            description:    descriptions[i].unwrap_or("").to_string(),
            category:       EventCategory::try_from(categories[i].unwrap_or("EVENT"))
                                .unwrap_or(EventCategory::Event),
            sub_type:       sub_types[i].unwrap_or("").to_string(),
            location_type:  match loc_types[i].unwrap_or("none") {
                "physical" => LocationType::Physical,
                "virtual"  => LocationType::Virtual,
                "hybrid"   => LocationType::Hybrid,
                _          => LocationType::None,
            },
            location_ref:   loc_refs[i].unwrap_or("").to_string(),
            start_at:       ts_to_utc(start_ats.value(i)),
            end_at:         ts_to_utc(end_ats.value(i)),
            all_day:        all_days.value(i),
            timezone:       timezones[i].unwrap_or("UTC").to_string(),
            rrule:          rrules[i].map(|s| s.to_string()),
            recurrence_id:  rec_ids[i].map(|s| s.to_string()),
            is_recurring:   is_recs.value(i),
            visibility:     visibilities[i].unwrap_or("private").to_string(),
            status:         match statuses[i].unwrap_or("confirmed") {
                "tentative" => EventStatus::Tentative,
                "cancelled" => EventStatus::Cancelled,
                _           => EventStatus::Confirmed,
            },
            busy_status:    match busy_stats[i].unwrap_or("busy") {
                "free"      => BusyStatus::Free,
                "tentative" => BusyStatus::Tentative,
                _           => BusyStatus::Busy,
            },
            organiser_did:  org_dids[i].unwrap_or("").to_string(),
            attendees,
            attendee_status,
            has_pre_brief:  has_prebs.value(i),
            has_reflection: has_refs.value(i),
            companion_mode: match comp_modes[i].unwrap_or("personal") {
                "silent"   => CompanionMode::Silent,
                "scribe"   => CompanionMode::Scribe,
                "full"     => CompanionMode::Full,
                _          => CompanionMode::Personal,
            },
            notes_cas,
            attachments_cas,
            embedding:      vec![0.0f32; crate::schema::EMBEDDING_DIM as usize],
            ap_object_id:   ap_ids[i].map(|s| s.to_string()),
            ical_uid:       ical_uids[i].unwrap_or("").to_string(),
            external_id:    ext_ids[i].map(|s| s.to_string()),
            created_at:     ts_to_utc(created_ats.value(i)),
            updated_at:     ts_to_utc(updated_ats.value(i)),
            version:        versions.value(i),
            created_by:     created_bys[i].unwrap_or("").to_string(),
        });
    }

    Ok(events)
}

#[cfg(test)]
mod tests {
    use super::*;
    use tempfile::tempdir;

    async fn make_store() -> (EventStore, tempfile::TempDir) {
        let dir   = tempdir().unwrap();
        let store = EventStore::new(dir.path().to_str().unwrap(), "did:web:alice.com")
            .await.unwrap();
        (store, dir)
    }

    #[tokio::test]
    async fn test_create_and_get() {
        let (store, _dir) = make_store().await;
        let event = CalendarEvent::new(
            "did:web:alice.com",
            "Morning Practice",
            EventCategory::Practice,
            Utc::now(),
            Utc::now() + chrono::Duration::minutes(30),
            Space::Core,
        );
        let id = event.id.clone();
        store.create(&event).await.unwrap();

        let fetched = store.get(&id, &Space::Core).await.unwrap();
        assert_eq!(fetched.title, "Morning Practice");
        assert_eq!(fetched.category, EventCategory::Practice);
    }

    #[tokio::test]
    async fn test_list_by_date_range() {
        let (store, _dir) = make_store().await;
        let now = Utc::now();

        for i in 0..3 {
            let event = CalendarEvent::new(
                "did:web:alice.com",
                format!("Event {}", i),
                EventCategory::Meeting,
                now + chrono::Duration::days(i),
                now + chrono::Duration::days(i) + chrono::Duration::hours(1),
                Space::Core,
            );
            store.create(&event).await.unwrap();
        }

        let events = store.list(
            &Space::Core,
            Some(now - chrono::Duration::hours(1)),
            Some(now + chrono::Duration::days(4)),
            None, None, 10,
        ).await.unwrap();

        assert_eq!(events.len(), 3);
    }

    #[tokio::test]
    async fn test_cancel_event() {
        let (store, _dir) = make_store().await;
        let event = CalendarEvent::new(
            "did:web:alice.com", "Team Meeting", EventCategory::Meeting,
            Utc::now(), Utc::now() + chrono::Duration::hours(1), Space::Core,
        );
        let id = event.id.clone();
        store.create(&event).await.unwrap();
        let cancelled = store.cancel(&id, &Space::Core).await.unwrap();
        assert_eq!(cancelled.status, EventStatus::Cancelled);
    }
}
