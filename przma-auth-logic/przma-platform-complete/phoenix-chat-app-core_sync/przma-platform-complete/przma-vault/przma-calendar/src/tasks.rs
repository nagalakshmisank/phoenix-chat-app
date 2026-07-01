// przma-calendar/src/tasks.rs

use arrow_array::{
    Array, BooleanArray, FixedSizeListArray, Float32Array,
    Int32Array, Int64Array, RecordBatch, StringArray,
};
use chrono::{DateTime, Utc};
use futures::TryStreamExt;
use lancedb::{connect, query::{ExecutableQuery, QueryBase}, Connection};
use std::sync::Arc;

use crate::{
    error::{CalendarError, CalendarResult},
    models::{CalendarTask, Space, TaskPriority, TaskStatus},
    schema::{calendar_task_schema, table_path, tables},
};

pub struct TaskStore {
    conn:      Connection,
    base_path: String,
    did:       String,
}

impl TaskStore {
    pub async fn new(base_path: impl Into<String>, did: impl Into<String>) -> CalendarResult<Self> {
        let base_path = base_path.into();
        let did       = did.into();
        let conn      = connect(&base_path).execute().await?;
        Ok(Self { conn, base_path, did })
    }

    fn table_path_for(&self, space: &Space) -> String {
        match space {
            Space::Core        => table_path(&self.base_path, &self.did, "calendar", "core", tables::TASKS),
            Space::Circle(c)   => table_path(&self.base_path, &self.did, "calendar", &format!("circles/{}", c), tables::TASKS),
            Space::Commons     => table_path(&self.base_path, &self.did, "calendar", "commons", tables::TASKS),
        }
    }

    async fn open_or_create(&self, path: &str) -> CalendarResult<lancedb::Table> {
        match self.conn.open_table(path).execute().await {
            Ok(t)  => Ok(t),
            Err(_) => Ok(self.conn.create_empty_table(path, calendar_task_schema()).execute().await?),
        }
    }

    pub async fn create(&self, task: &CalendarTask) -> CalendarResult<String> {
        let path  = self.table_path_for(&task.space);
        let table = self.open_or_create(&path).await?;
        let batch = task_to_record_batch(task)?;
        table.add(vec![batch]).execute().await?;
        Ok(task.id.clone())
    }

    pub async fn get(&self, id: &str, space: &Space) -> CalendarResult<CalendarTask> {
        let path    = self.table_path_for(space);
        let table   = self.open_or_create(&path).await?;
        let batches: Vec<RecordBatch> = table.query()
            .filter(format!("id = '{}'", id)).limit(1)
            .execute().await?.try_collect().await
            .map_err(|e| CalendarError::Arrow(e.to_string()))?;
        batches.into_iter().next()
            .and_then(|b| batch_to_tasks(b).ok())
            .and_then(|mut v| v.pop())
            .ok_or_else(|| CalendarError::NotFound(format!("Task not found: {}", id)))
    }

    pub async fn list(
        &self, space: &Space, status: Option<&str>,
        assigned_to: Option<&str>, limit: usize,
    ) -> CalendarResult<Vec<CalendarTask>> {
        let path  = self.table_path_for(space);
        let table = self.open_or_create(&path).await?;
        let mut filters = vec![];
        if let Some(s) = status        { filters.push(format!("status = '{}'", s)); }
        if let Some(a) = assigned_to   { filters.push(format!("assigned_by = '{}'", a)); }
        let mut q = table.query();
        if !filters.is_empty() { q = q.filter(filters.join(" AND ")); }
        let batches: Vec<RecordBatch> = q.limit(limit).execute().await?
            .try_collect().await.map_err(|e| CalendarError::Arrow(e.to_string()))?;
        Ok(batches.into_iter().flat_map(|b| batch_to_tasks(b).unwrap_or_default()).collect())
    }

    pub async fn update(&self, task: &CalendarTask) -> CalendarResult<()> {
        let path  = self.table_path_for(&task.space);
        let table = self.open_or_create(&path).await?;
        table.delete(&format!("id = '{}'", task.id)).await?;
        let batch = task_to_record_batch(task)?;
        table.add(vec![batch]).execute().await?;
        Ok(())
    }

    pub async fn complete(&self, id: &str, space: &Space, completed_by: &str) -> CalendarResult<CalendarTask> {
        let mut task      = self.get(id, space).await?;
        task.status       = TaskStatus::Complete;
        task.completed_at = Some(Utc::now());
        task.completed_by = Some(completed_by.to_string());
        task.progress_pct = 100;
        task.updated_at   = Utc::now();
        task.version     += 1;
        self.update(&task).await?;
        Ok(task)
    }
}

fn task_to_record_batch(task: &CalendarTask) -> CalendarResult<RecordBatch> {
    let schema           = calendar_task_schema();
    let assigned_to_json = serde_json::to_string(&task.assigned_to)?;
    let notes_cas_json   = serde_json::to_string(&task.notes_cas)?;
    let emb              = Float32Array::from(task.embedding.clone());
    let emb_field        = arrow_schema::Field::new("item", arrow_schema::DataType::Float32, false);
    let embedding        = FixedSizeListArray::try_new(Arc::new(emb_field), crate::schema::EMBEDDING_DIM, Arc::new(emb), None)
        .map_err(|e| CalendarError::Arrow(e.to_string()))?;

    RecordBatch::try_new(schema, vec![
        Arc::new(StringArray::from(vec![task.id.as_str()])),
        Arc::new(StringArray::from(vec![task.did.as_str()])),
        Arc::new(StringArray::from(vec![task.space.as_str().as_str()])),
        Arc::new(StringArray::from(vec![task.circle_did.as_deref()])),
        Arc::new(StringArray::from(vec![task.title.as_str()])),
        Arc::new(StringArray::from(vec![task.description.as_str()])),
        Arc::new(StringArray::from(vec![task.category.as_str()])),
        Arc::new(StringArray::from(vec![task.priority.as_str()])),
        Arc::new(StringArray::from(vec![task.status.as_str()])),
        Arc::new(Int64Array::from(vec![task.due_at.map(|t| t.timestamp_micros())])),
        Arc::new(Int64Array::from(vec![task.start_at.map(|t| t.timestamp_micros())])),
        Arc::new(StringArray::from(vec![task.event_id.as_deref()])),
        Arc::new(StringArray::from(vec![task.rrule.as_deref()])),
        Arc::new(StringArray::from(vec![assigned_to_json.as_str()])),
        Arc::new(StringArray::from(vec![task.assigned_by.as_str()])),
        Arc::new(Int32Array::from(vec![task.progress_pct])),
        Arc::new(StringArray::from(vec![task.blocked_reason.as_deref()])),
        Arc::new(Int64Array::from(vec![task.completed_at.map(|t| t.timestamp_micros())])),
        Arc::new(StringArray::from(vec![task.completed_by.as_deref()])),
        Arc::new(StringArray::from(vec![notes_cas_json.as_str()])),
        Arc::new(embedding),
        Arc::new(Int64Array::from(vec![task.created_at.timestamp_micros()])),
        Arc::new(Int64Array::from(vec![task.updated_at.timestamp_micros()])),
        Arc::new(Int32Array::from(vec![task.version])),
    ]).map_err(|e| CalendarError::Arrow(e.to_string()))
}

fn batch_to_tasks(batch: RecordBatch) -> CalendarResult<Vec<CalendarTask>> {
    let num_rows = batch.num_rows();
    let mut tasks = Vec::with_capacity(num_rows);
    macro_rules! strs { ($n:expr) => { batch.column_by_name($n).unwrap()
        .as_any().downcast_ref::<StringArray>().unwrap() }; }
    macro_rules! i64s { ($n:expr) => { batch.column_by_name($n).unwrap()
        .as_any().downcast_ref::<Int64Array>().unwrap() }; }
    macro_rules! i32s { ($n:expr) => { batch.column_by_name($n).unwrap()
        .as_any().downcast_ref::<Int32Array>().unwrap() }; }

    let ts = |v: i64| DateTime::from_timestamp_micros(v).unwrap_or_default();

    for i in 0..num_rows {
        let assigned_to: Vec<String> = serde_json::from_str(
            strs!("assigned_to_json").value(i)).unwrap_or_default();
        let notes_cas: Vec<String>  = serde_json::from_str(
            strs!("notes_cas_json").value(i)).unwrap_or_default();

        let space_str = strs!("space").value(i);
        let space     = Space::try_from(space_str).unwrap_or(Space::Core);

        tasks.push(CalendarTask {
            id:             strs!("id").value(i).to_string(),
            did:            strs!("did").value(i).to_string(),
            space,
            circle_did:     if batch.column_by_name("circle_did").unwrap().is_null(i) { None }
                            else { Some(strs!("circle_did").value(i).to_string()) },
            title:          strs!("title").value(i).to_string(),
            description:    strs!("description").value(i).to_string(),
            category:       strs!("category").value(i).to_string(),
            priority:       match strs!("priority").value(i) {
                "low"    => TaskPriority::Low,
                "high"   => TaskPriority::High,
                "urgent" => TaskPriority::Urgent,
                _        => TaskPriority::Medium,
            },
            status: match strs!("status").value(i) {
                "active"    => TaskStatus::Active,
                "blocked"   => TaskStatus::Blocked,
                "complete"  => TaskStatus::Complete,
                "deferred"  => TaskStatus::Deferred,
                "cancelled" => TaskStatus::Cancelled,
                _           => TaskStatus::Draft,
            },
            due_at:         if i64s!("due_at").is_null(i) { None } else { Some(ts(i64s!("due_at").value(i))) },
            start_at:       if i64s!("start_at").is_null(i) { None } else { Some(ts(i64s!("start_at").value(i))) },
            event_id:       if batch.column_by_name("event_id").unwrap().is_null(i) { None }
                            else { Some(strs!("event_id").value(i).to_string()) },
            rrule:          if batch.column_by_name("rrule").unwrap().is_null(i) { None }
                            else { Some(strs!("rrule").value(i).to_string()) },
            assigned_to,
            assigned_by:    strs!("assigned_by").value(i).to_string(),
            progress_pct:   i32s!("progress_pct").value(i),
            blocked_reason: if batch.column_by_name("blocked_reason").unwrap().is_null(i) { None }
                            else { Some(strs!("blocked_reason").value(i).to_string()) },
            completed_at:   if i64s!("completed_at").is_null(i) { None } else { Some(ts(i64s!("completed_at").value(i))) },
            completed_by:   if batch.column_by_name("completed_by").unwrap().is_null(i) { None }
                            else { Some(strs!("completed_by").value(i).to_string()) },
            notes_cas,
            embedding:      vec![0.0f32; crate::schema::EMBEDDING_DIM as usize],
            created_at:     ts(i64s!("created_at").value(i)),
            updated_at:     ts(i64s!("updated_at").value(i)),
            version:        i32s!("version").value(i),
        });
    }
    Ok(tasks)
}
