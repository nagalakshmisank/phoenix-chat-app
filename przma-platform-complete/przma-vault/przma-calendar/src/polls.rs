// przma-calendar/src/polls.rs

use arrow_array::{Array, BooleanArray, Int64Array, RecordBatch, StringArray};
use futures::TryStreamExt;
use lancedb::{connect, query::{ExecutableQuery, QueryBase}, Connection};
use std::sync::Arc;

use crate::{
    error::{CalendarError, CalendarResult},
    models::{PollOption, SchedulingPoll},
    schema::{scheduling_poll_schema, table_path, tables},
};

pub struct PollStore {
    conn:      Connection,
    base_path: String,
}

impl PollStore {
    pub async fn new(base_path: impl Into<String>) -> CalendarResult<Self> {
        let base_path = base_path.into();
        let conn      = lancedb::connect(&base_path).execute().await?;
        Ok(Self { conn, base_path })
    }

    fn path(&self, circle_did: &str) -> String {
        table_path(&self.base_path, circle_did, "calendar", "circles", tables::POLLS)
    }

    async fn open_or_create(&self, circle_did: &str) -> CalendarResult<lancedb::Table> {
        let path = self.path(circle_did);
        match self.conn.open_table(&path).execute().await {
            Ok(t)  => Ok(t),
            Err(_) => Ok(self.conn.create_empty_table(&path, scheduling_poll_schema()).execute().await?),
        }
    }

    pub async fn create(&self, poll: &SchedulingPoll) -> CalendarResult<String> {
        let table       = self.open_or_create(&poll.circle_did).await?;
        let options_json = serde_json::to_string(&poll.options)?;
        let votes_json   = serde_json::to_string(&poll.votes)?;

        let batch = RecordBatch::try_new(scheduling_poll_schema(), vec![
            Arc::new(StringArray::from(vec![poll.id.as_str()])),
            Arc::new(StringArray::from(vec![poll.circle_did.as_str()])),
            Arc::new(StringArray::from(vec![poll.created_by.as_str()])),
            Arc::new(StringArray::from(vec![poll.title.as_str()])),
            Arc::new(StringArray::from(vec![poll.description.as_str()])),
            Arc::new(StringArray::from(vec![poll.poll_type.as_str()])),
            Arc::new(StringArray::from(vec![options_json.as_str()])),
            Arc::new(StringArray::from(vec![votes_json.as_str()])),
            Arc::new(StringArray::from(vec![poll.status.as_str()])),
            Arc::new(StringArray::from(vec![poll.resolved_option.as_deref()])),
            Arc::new(BooleanArray::from(vec![poll.auto_create_event])),
            Arc::new(StringArray::from(vec![poll.resulting_event_id.as_deref()])),
            Arc::new(Int64Array::from(vec![poll.closes_at.map(|t| t.timestamp_micros())])),
            Arc::new(Int64Array::from(vec![poll.created_at.timestamp_micros()])),
            Arc::new(Int64Array::from(vec![poll.updated_at.timestamp_micros()])),
        ]).map_err(|e| CalendarError::Arrow(e.to_string()))?;

        table.add(vec![batch]).execute().await?;
        Ok(poll.id.clone())
    }

    pub async fn get(&self, id: &str, circle_did: &str) -> CalendarResult<SchedulingPoll> {
        let table   = self.open_or_create(circle_did).await?;
        let batches: Vec<RecordBatch> = table.query()
            .filter(format!("id = '{}'", id)).limit(1)
            .execute().await?
            .try_collect().await
            .map_err(|e| CalendarError::Arrow(e.to_string()))?;
        batches.into_iter().next()
            .and_then(|b| batch_to_polls(b).ok())
            .and_then(|mut v| v.pop())
            .ok_or_else(|| CalendarError::NotFound(format!("Poll: {}", id)))
    }

    pub async fn vote(
        &self,
        poll_id:    &str,
        circle_did: &str,
        voter_did:  &str,
        option_ids: Vec<String>,
    ) -> CalendarResult<SchedulingPoll> {
        let mut poll = self.get(poll_id, circle_did).await?;
        if poll.status != "open" {
            return Err(CalendarError::Conflict("Poll is not open for voting".to_string()));
        }
        poll.votes.insert(voter_did.to_string(), option_ids);
        poll.updated_at = chrono::Utc::now();
        // Delete+reinsert
        let table = self.open_or_create(circle_did).await?;
        table.delete(&format!("id = '{}'", poll_id)).await?;
        self.create(&poll).await?;
        Ok(poll)
    }

    pub async fn resolve(
        &self,
        poll_id:        &str,
        circle_did:     &str,
        winning_option: &str,
    ) -> CalendarResult<SchedulingPoll> {
        let mut poll          = self.get(poll_id, circle_did).await?;
        poll.status           = "resolved".to_string();
        poll.resolved_option  = Some(winning_option.to_string());
        poll.updated_at       = chrono::Utc::now();
        let table = self.open_or_create(circle_did).await?;
        table.delete(&format!("id = '{}'", poll_id)).await?;
        self.create(&poll).await?;
        Ok(poll)
    }
}

fn batch_to_polls(batch: RecordBatch) -> CalendarResult<Vec<SchedulingPoll>> {
    let num_rows = batch.num_rows();
    let mut polls = Vec::with_capacity(num_rows);
    macro_rules! strs { ($n:expr) => { batch.column_by_name($n).unwrap()
        .as_any().downcast_ref::<StringArray>().unwrap() }; }
    macro_rules! i64s { ($n:expr) => { batch.column_by_name($n).unwrap()
        .as_any().downcast_ref::<Int64Array>().unwrap() }; }
    macro_rules! bools { ($n:expr) => { batch.column_by_name($n).unwrap()
        .as_any().downcast_ref::<BooleanArray>().unwrap() }; }

    let ts = |v: i64| chrono::DateTime::from_timestamp_micros(v).unwrap_or_default();

    for i in 0..num_rows {
        let options: Vec<PollOption> = serde_json::from_str(strs!("options_json").value(i)).unwrap_or_default();
        let votes: std::collections::HashMap<String, Vec<String>> =
            serde_json::from_str(strs!("votes_json").value(i)).unwrap_or_default();

        polls.push(SchedulingPoll {
            id:                 strs!("id").value(i).to_string(),
            circle_did:         strs!("circle_did").value(i).to_string(),
            created_by:         strs!("created_by").value(i).to_string(),
            title:              strs!("title").value(i).to_string(),
            description:        strs!("description").value(i).to_string(),
            poll_type:          strs!("poll_type").value(i).to_string(),
            options,
            votes,
            status:             strs!("status").value(i).to_string(),
            resolved_option:    if batch.column_by_name("resolved_option").unwrap().is_null(i) { None }
                                else { Some(strs!("resolved_option").value(i).to_string()) },
            auto_create_event:  bools!("auto_create_event").value(i),
            resulting_event_id: if batch.column_by_name("resulting_event_id").unwrap().is_null(i) { None }
                                else { Some(strs!("resulting_event_id").value(i).to_string()) },
            closes_at:          if i64s!("closes_at").is_null(i) { None } else { Some(ts(i64s!("closes_at").value(i))) },
            created_at:         ts(i64s!("created_at").value(i)),
            updated_at:         ts(i64s!("updated_at").value(i)),
        });
    }
    Ok(polls)
}
