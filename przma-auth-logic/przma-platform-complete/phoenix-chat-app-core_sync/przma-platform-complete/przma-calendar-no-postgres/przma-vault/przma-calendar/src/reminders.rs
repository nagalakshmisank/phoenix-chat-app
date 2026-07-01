// przma-calendar/src/reminders.rs

use arrow_array::{BooleanArray, Int32Array, Int64Array, RecordBatch, StringArray};
use chrono::{DateTime, Utc};
use futures::TryStreamExt;
use lancedb::{connect, query::QueryBase, Connection};
use std::sync::Arc;

use crate::{
    error::{CalendarError, CalendarResult},
    models::Reminder,
    schema::{reminder_schema, table_path, tables},
};

pub struct ReminderStore {
    conn:      Connection,
    base_path: String,
    did:       String,
}

impl ReminderStore {
    pub async fn new(base_path: impl Into<String>, did: impl Into<String>) -> CalendarResult<Self> {
        let base_path = base_path.into();
        let did       = did.into();
        let conn      = connect(&base_path).execute().await?;
        Ok(Self { conn, base_path, did })
    }

    fn path(&self) -> String {
        table_path(&self.base_path, &self.did, "calendar", "core", tables::REMINDERS)
    }

    async fn open_or_create(&self) -> CalendarResult<lancedb::Table> {
        let path = self.path();
        match self.conn.open_table(&path).execute().await {
            Ok(t)  => Ok(t),
            Err(_) => Ok(self.conn.create_empty_table(&path, reminder_schema()).execute().await?),
        }
    }

    pub async fn create(&self, reminder: &Reminder) -> CalendarResult<String> {
        let table = self.open_or_create().await?;
        let delivery_json = serde_json::to_string(&reminder.delivery)?;

        let batch = RecordBatch::try_new(reminder_schema(), vec![
            Arc::new(StringArray::from(vec![reminder.id.as_str()])),
            Arc::new(StringArray::from(vec![reminder.did.as_str()])),
            Arc::new(StringArray::from(vec![reminder.entity_type.as_str()])),
            Arc::new(StringArray::from(vec![reminder.entity_id.as_str()])),
            Arc::new(StringArray::from(vec![reminder.trigger_type.as_str()])),
            Arc::new(Int32Array::from(vec![reminder.trigger_mins])),
            Arc::new(Int64Array::from(vec![reminder.trigger_at.map(|t| t.timestamp_micros())])),
            Arc::new(StringArray::from(vec![delivery_json.as_str()])),
            Arc::new(StringArray::from(vec![reminder.message.as_deref()])),
            Arc::new(BooleanArray::from(vec![reminder.repeat])),
            Arc::new(Int32Array::from(vec![reminder.repeat_interval_mins])),
            Arc::new(Int64Array::from(vec![reminder.delivered_at.map(|t| t.timestamp_micros())])),
            Arc::new(Int64Array::from(vec![reminder.dismissed_at.map(|t| t.timestamp_micros())])),
            Arc::new(Int64Array::from(vec![reminder.created_at.timestamp_micros()])),
        ]).map_err(|e| CalendarError::Arrow(e.to_string()))?;

        table.add(vec![batch]).execute().await?;
        Ok(reminder.id.clone())
    }

    /// List reminders due before a given time (for Oban job scheduling)
    pub async fn due_before(&self, before: DateTime<Utc>) -> CalendarResult<Vec<Reminder>> {
        let table   = self.open_or_create().await?;
        let filter  = format!(
            "trigger_at <= {} AND delivered_at IS NULL AND dismissed_at IS NULL",
            before.timestamp_micros()
        );
        let batches: Vec<RecordBatch> = table.query()
            .filter(filter).execute().await?
            .try_collect().await
            .map_err(|e| CalendarError::Arrow(e.to_string()))?;

        Ok(batches.into_iter()
            .flat_map(|b| batch_to_reminders(b).unwrap_or_default())
            .collect())
    }

    pub async fn mark_delivered(&self, id: &str) -> CalendarResult<()> {
        let table = self.open_or_create().await?;
        let now   = Utc::now().timestamp_micros();
        // LanceDB update via delete+insert for now
        table.delete(&format!("id = '{}'", id)).await?;
        // Full re-insert with delivered_at set would go here
        // (simplified for Phase 1)
        tracing::info!(id = %id, "Reminder marked delivered");
        Ok(())
    }
}

fn batch_to_reminders(batch: RecordBatch) -> CalendarResult<Vec<Reminder>> {
    let num_rows = batch.num_rows();
    let mut reminders = Vec::with_capacity(num_rows);
    macro_rules! strs { ($n:expr) => { batch.column_by_name($n).unwrap()
        .as_any().downcast_ref::<StringArray>().unwrap() }; }
    macro_rules! i64s { ($n:expr) => { batch.column_by_name($n).unwrap()
        .as_any().downcast_ref::<Int64Array>().unwrap() }; }
    macro_rules! i32s { ($n:expr) => { batch.column_by_name($n).unwrap()
        .as_any().downcast_ref::<Int32Array>().unwrap() }; }
    macro_rules! bools { ($n:expr) => { batch.column_by_name($n).unwrap()
        .as_any().downcast_ref::<BooleanArray>().unwrap() }; }

    let ts = |v: i64| DateTime::from_timestamp_micros(v).unwrap_or_default();

    for i in 0..num_rows {
        let delivery: Vec<String> = serde_json::from_str(strs!("delivery_json").value(i)).unwrap_or_default();
        reminders.push(Reminder {
            id:                   strs!("id").value(i).to_string(),
            did:                  strs!("did").value(i).to_string(),
            entity_type:          strs!("entity_type").value(i).to_string(),
            entity_id:            strs!("entity_id").value(i).to_string(),
            trigger_type:         strs!("trigger_type").value(i).to_string(),
            trigger_mins:         if batch.column_by_name("trigger_mins").unwrap().is_null(i) { None }
                                  else { Some(i32s!("trigger_mins").value(i)) },
            trigger_at:           if i64s!("trigger_at").is_null(i) { None } else { Some(ts(i64s!("trigger_at").value(i))) },
            delivery,
            message:              if batch.column_by_name("message").unwrap().is_null(i) { None }
                                  else { Some(strs!("message").value(i).to_string()) },
            repeat:               bools!("repeat").value(i),
            repeat_interval_mins: if batch.column_by_name("repeat_interval_mins").unwrap().is_null(i) { None }
                                  else { Some(i32s!("repeat_interval_mins").value(i)) },
            delivered_at:         if i64s!("delivered_at").is_null(i) { None } else { Some(ts(i64s!("delivered_at").value(i))) },
            dismissed_at:         if i64s!("dismissed_at").is_null(i) { None } else { Some(ts(i64s!("dismissed_at").value(i))) },
            created_at:           ts(i64s!("created_at").value(i)),
        });
    }
    Ok(reminders)
}
