// przma-calendar/src/availability.rs

use arrow_array::{BooleanArray, Int32Array, Int64Array, RecordBatch, StringArray};
use chrono::{DateTime, Utc};
use futures::TryStreamExt;
use lancedb::{connect, query::QueryBase, Connection};
use std::sync::Arc;

use crate::{
    error::{CalendarError, CalendarResult},
    models::{AvailabilityWindow, BookingLink, FreeBusySlot, LocationType},
    schema::{availability_window_schema, booking_link_schema, table_path, tables},
};

pub struct AvailabilityStore {
    conn:      Connection,
    base_path: String,
    did:       String,
}

impl AvailabilityStore {
    pub async fn new(base_path: impl Into<String>, did: impl Into<String>) -> CalendarResult<Self> {
        let base_path = base_path.into();
        let did       = did.into();
        let conn      = connect(&base_path).execute().await?;
        Ok(Self { conn, base_path, did })
    }

    fn avail_path(&self) -> String {
        table_path(&self.base_path, &self.did, "calendar", "core", tables::AVAILABILITY)
    }

    fn booking_path(&self) -> String {
        table_path(&self.base_path, &self.did, "calendar", "core", tables::BOOKING_LINKS)
    }

    async fn open_or_create_avail(&self) -> CalendarResult<lancedb::Table> {
        let path = self.avail_path();
        match self.conn.open_table(&path).execute().await {
            Ok(t)  => Ok(t),
            Err(_) => Ok(self.conn.create_empty_table(&path, availability_window_schema()).execute().await?),
        }
    }

    async fn open_or_create_booking(&self) -> CalendarResult<lancedb::Table> {
        let path = self.booking_path();
        match self.conn.open_table(&path).execute().await {
            Ok(t)  => Ok(t),
            Err(_) => Ok(self.conn.create_empty_table(&path, booking_link_schema()).execute().await?),
        }
    }

    // ── AVAILABILITY WINDOWS ──────────────────────────────────────────────────

    pub async fn set_windows(&self, windows: &[AvailabilityWindow]) -> CalendarResult<()> {
        if windows.is_empty() { return Ok(()); }
        let table = self.open_or_create_avail().await?;
        for win in windows {
            // Upsert: delete if exists, then insert
            table.delete(&format!("id = '{}'", win.id)).await.ok();
            let batch = window_to_batch(win)?;
            table.add(vec![batch]).execute().await?;
        }
        Ok(())
    }

    pub async fn list_windows(
        &self,
        start: DateTime<Utc>,
        end:   DateTime<Utc>,
    ) -> CalendarResult<Vec<AvailabilityWindow>> {
        let table = self.open_or_create_avail().await?;
        let filter = format!(
            "start_at >= {} AND end_at <= {}",
            start.timestamp_micros(), end.timestamp_micros()
        );
        let batches: Vec<RecordBatch> = table.query()
            .filter(filter).execute().await?
            .try_collect().await
            .map_err(|e| CalendarError::Arrow(e.to_string()))?;
        Ok(batches.into_iter().flat_map(|b| batch_to_windows(b).unwrap_or_default()).collect())
    }

    /// Compute free/busy slots — show_as only, never event details
    pub async fn freebusy(
        &self,
        start: DateTime<Utc>,
        end:   DateTime<Utc>,
    ) -> CalendarResult<Vec<FreeBusySlot>> {
        let windows = self.list_windows(start, end).await?;
        let mut slots: Vec<FreeBusySlot> = windows.iter()
            .filter(|w| w.visibility != "private")
            .map(|w| FreeBusySlot {
                start_at: w.start_at,
                end_at:   w.end_at,
                show_as:  w.show_as.clone(),
                label:    w.show_as.clone(),
            })
            .collect();
        slots.sort_by_key(|s| s.start_at);
        Ok(slots)
    }

    // ── BOOKING LINKS ─────────────────────────────────────────────────────────

    pub async fn create_booking_link(&self, link: &BookingLink) -> CalendarResult<String> {
        let table = self.open_or_create_booking().await?;
        let batch = booking_link_to_batch(link)?;
        table.add(vec![batch]).execute().await?;
        Ok(link.id.clone())
    }

    pub async fn get_booking_link(&self, id: &str) -> CalendarResult<BookingLink> {
        let table   = self.open_or_create_booking().await?;
        let batches: Vec<RecordBatch> = table.query()
            .filter(format!("id = '{}'", id)).limit(1)
            .execute().await?
            .try_collect().await
            .map_err(|e| CalendarError::Arrow(e.to_string()))?;
        batches.into_iter().next()
            .and_then(|b| batch_to_booking_links(b).ok())
            .and_then(|mut v| v.pop())
            .ok_or_else(|| CalendarError::NotFound(format!("BookingLink not found: {}", id)))
    }

    pub async fn list_booking_links(&self) -> CalendarResult<Vec<BookingLink>> {
        let table   = self.open_or_create_booking().await?;
        let batches: Vec<RecordBatch> = table.query()
            .filter("is_active = true").execute().await?
            .try_collect().await
            .map_err(|e| CalendarError::Arrow(e.to_string()))?;
        Ok(batches.into_iter().flat_map(|b| batch_to_booking_links(b).unwrap_or_default()).collect())
    }

    /// Get available slots for a booking link within a date range
    pub async fn available_slots(
        &self,
        link_id: &str,
        start:   DateTime<Utc>,
        end:     DateTime<Utc>,
    ) -> CalendarResult<Vec<FreeBusySlot>> {
        let link   = self.get_booking_link(link_id).await?;
        let busy   = self.freebusy(start, end).await?;
        let dur    = chrono::Duration::minutes(link.duration_mins as i64);
        let buf    = chrono::Duration::minutes(link.buffer_mins as i64);
        let notice = chrono::Duration::minutes(link.min_notice_mins as i64);
        let now    = Utc::now();

        let mut slots   = vec![];
        let mut current = start;

        while current + dur <= end {
            // Skip if before minimum notice window
            if current < now + notice {
                current = current + chrono::Duration::minutes(30);
                continue;
            }
            // Check overlap with busy windows
            let slot_end    = current + dur;
            let has_overlap = busy.iter().any(|b| {
                current < b.end_at + buf && slot_end + buf > b.start_at
            });
            if !has_overlap {
                slots.push(FreeBusySlot {
                    start_at: current,
                    end_at:   slot_end,
                    show_as:  "free".to_string(),
                    label:    "Available".to_string(),
                });
            }
            current = current + chrono::Duration::minutes(30);
        }
        Ok(slots)
    }
}

// Serialisation helpers omitted for brevity — follow same pattern as events.rs
fn window_to_batch(w: &AvailabilityWindow) -> CalendarResult<RecordBatch> {
    use arrow_array::{BooleanArray, Int32Array, Int64Array, StringArray};
    let shared_json = serde_json::to_string(&w.shared_with)?;
    RecordBatch::try_new(crate::schema::availability_window_schema(), vec![
        Arc::new(StringArray::from(vec![w.id.as_str()])),
        Arc::new(StringArray::from(vec![w.did.as_str()])),
        Arc::new(StringArray::from(vec![w.window_type.as_str()])),
        Arc::new(Int64Array::from(vec![w.start_at.timestamp_micros()])),
        Arc::new(Int64Array::from(vec![w.end_at.timestamp_micros()])),
        Arc::new(StringArray::from(vec![w.rrule.as_deref()])),
        Arc::new(StringArray::from(vec![w.timezone.as_str()])),
        Arc::new(StringArray::from(vec![w.visibility.as_str()])),
        Arc::new(StringArray::from(vec![w.show_as.as_str()])),
        Arc::new(StringArray::from(vec![shared_json.as_str()])),
        Arc::new(BooleanArray::from(vec![w.is_bookable])),
        Arc::new(StringArray::from(vec![w.booking_link_id.as_deref()])),
        Arc::new(Int32Array::from(vec![w.min_notice_mins])),
        Arc::new(Int32Array::from(vec![w.buffer_mins])),
        Arc::new(Int64Array::from(vec![w.created_at.timestamp_micros()])),
        Arc::new(Int64Array::from(vec![w.updated_at.timestamp_micros()])),
    ]).map_err(|e| CalendarError::Arrow(e.to_string()))
}

fn batch_to_windows(batch: RecordBatch) -> CalendarResult<Vec<AvailabilityWindow>> {
    let num_rows = batch.num_rows();
    let mut windows = Vec::with_capacity(num_rows);
    macro_rules! strs  { ($n:expr) => { batch.column_by_name($n).unwrap().as_any().downcast_ref::<arrow_array::StringArray>().unwrap() }; }
    macro_rules! i64s  { ($n:expr) => { batch.column_by_name($n).unwrap().as_any().downcast_ref::<arrow_array::Int64Array>().unwrap() }; }
    macro_rules! i32s  { ($n:expr) => { batch.column_by_name($n).unwrap().as_any().downcast_ref::<arrow_array::Int32Array>().unwrap() }; }
    macro_rules! bools { ($n:expr) => { batch.column_by_name($n).unwrap().as_any().downcast_ref::<arrow_array::BooleanArray>().unwrap() }; }
    let ts = |v: i64| chrono::DateTime::from_timestamp_micros(v).unwrap_or_default();
    for i in 0..num_rows {
        let shared_with: Vec<String> = serde_json::from_str(strs!("shared_with_json").value(i)).unwrap_or_default();
        windows.push(AvailabilityWindow {
            id:               strs!("id").value(i).to_string(),
            did:              strs!("did").value(i).to_string(),
            window_type:      strs!("window_type").value(i).to_string(),
            start_at:         ts(i64s!("start_at").value(i)),
            end_at:           ts(i64s!("end_at").value(i)),
            rrule:            if batch.column_by_name("rrule").unwrap().is_null(i) { None } else { Some(strs!("rrule").value(i).to_string()) },
            timezone:         strs!("timezone").value(i).to_string(),
            visibility:       strs!("visibility").value(i).to_string(),
            show_as:          strs!("show_as").value(i).to_string(),
            shared_with,
            is_bookable:      bools!("is_bookable").value(i),
            booking_link_id:  if batch.column_by_name("booking_link_id").unwrap().is_null(i) { None } else { Some(strs!("booking_link_id").value(i).to_string()) },
            min_notice_mins:  i32s!("min_notice_mins").value(i),
            buffer_mins:      i32s!("buffer_mins").value(i),
            created_at:       ts(i64s!("created_at").value(i)),
            updated_at:       ts(i64s!("updated_at").value(i)),
        });
    }
    Ok(windows)
}

fn booking_link_to_batch(l: &BookingLink) -> CalendarResult<RecordBatch> {
    use arrow_array::{BooleanArray, Int32Array, Int64Array, StringArray};
    let questions_json = serde_json::to_string(&l.questions)?;
    RecordBatch::try_new(crate::schema::booking_link_schema(), vec![
        Arc::new(StringArray::from(vec![l.id.as_str()])),
        Arc::new(StringArray::from(vec![l.did.as_str()])),
        Arc::new(StringArray::from(vec![l.title.as_str()])),
        Arc::new(StringArray::from(vec![l.description.as_str()])),
        Arc::new(Int32Array::from(vec![l.duration_mins])),
        Arc::new(StringArray::from(vec![l.location_type.as_str()])),
        Arc::new(StringArray::from(vec![l.location_ref.as_str()])),
        Arc::new(StringArray::from(vec![l.availability_rule.as_str()])),
        Arc::new(StringArray::from(vec![questions_json.as_str()])),
        Arc::new(StringArray::from(vec![l.confirmation_msg.as_str()])),
        Arc::new(BooleanArray::from(vec![l.is_active])),
        Arc::new(Int64Array::from(vec![l.created_at.timestamp_micros()])),
        Arc::new(Int64Array::from(vec![l.updated_at.timestamp_micros()])),
    ]).map_err(|e| CalendarError::Arrow(e.to_string()))
}

fn batch_to_booking_links(batch: RecordBatch) -> CalendarResult<Vec<BookingLink>> {
    let num_rows = batch.num_rows();
    let mut links = Vec::with_capacity(num_rows);
    macro_rules! strs  { ($n:expr) => { batch.column_by_name($n).unwrap().as_any().downcast_ref::<arrow_array::StringArray>().unwrap() }; }
    macro_rules! i64s  { ($n:expr) => { batch.column_by_name($n).unwrap().as_any().downcast_ref::<arrow_array::Int64Array>().unwrap() }; }
    macro_rules! i32s  { ($n:expr) => { batch.column_by_name($n).unwrap().as_any().downcast_ref::<arrow_array::Int32Array>().unwrap() }; }
    macro_rules! bools { ($n:expr) => { batch.column_by_name($n).unwrap().as_any().downcast_ref::<arrow_array::BooleanArray>().unwrap() }; }
    let ts = |v: i64| chrono::DateTime::from_timestamp_micros(v).unwrap_or_default();
    for i in 0..num_rows {
        let questions: Vec<String> = serde_json::from_str(strs!("questions_json").value(i)).unwrap_or_default();
        let loc_type = match strs!("location_type").value(i) {
            "physical" => LocationType::Physical,
            "virtual"  => LocationType::Virtual,
            "hybrid"   => LocationType::Hybrid,
            _          => LocationType::None,
        };
        links.push(BookingLink {
            id:               strs!("id").value(i).to_string(),
            did:              strs!("did").value(i).to_string(),
            title:            strs!("title").value(i).to_string(),
            description:      strs!("description").value(i).to_string(),
            duration_mins:    i32s!("duration_mins").value(i),
            location_type:    loc_type,
            location_ref:     strs!("location_ref").value(i).to_string(),
            availability_rule: strs!("availability_rule").value(i).to_string(),
            questions,
            confirmation_msg: strs!("confirmation_msg").value(i).to_string(),
            is_active:        bools!("is_active").value(i),
            created_at:       ts(i64s!("created_at").value(i)),
            updated_at:       ts(i64s!("updated_at").value(i)),
        });
    }
    Ok(links)
}
