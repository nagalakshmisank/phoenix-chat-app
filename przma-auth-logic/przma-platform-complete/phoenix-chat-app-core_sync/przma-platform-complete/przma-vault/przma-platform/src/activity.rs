// przma-platform/src/activity.rs
use arrow_array::{Array, Int64Array, RecordBatch, RecordBatchIterator, StringArray};
use arrow_schema::{DataType, Field, Fields, Schema};
use futures::TryStreamExt;
use lancedb::query::{ExecutableQuery, QueryBase};
use lancedb::{connect, Table};
use serde::{Deserialize, Serialize};
use std::sync::Arc;

use crate::namespace::Space;
use crate::{PlatformError, PlatformResult};

pub mod boxes {
    pub const OUTBOX: &str = "outbox";
    pub const INBOX: &str = "inbox";
}

pub const AS_PUBLIC: &str = "https://www.w3.org/ns/activitystreams#Public";

pub fn activity_schema() -> Arc<Schema> {
    Arc::new(Schema::new(Fields::from(vec![
        Field::new("id",            DataType::Utf8,  false),
        Field::new("owner_did",     DataType::Utf8,  false),
        Field::new("actor",         DataType::Utf8,  false),
        Field::new("activity_type", DataType::Utf8,  false),
        Field::new("space",         DataType::Utf8,  false),
        Field::new("object_id",     DataType::Utf8,  true),
        Field::new("object_cas",    DataType::Utf8,  true),  // "cas:{blake3_hash}"
        Field::new("object_name",   DataType::Utf8,  true),
        Field::new("to_json",       DataType::Utf8,  false),
        Field::new("raw_json",      DataType::Utf8,  false),
        Field::new("status",        DataType::Utf8,  false),  // pending|delivered|read|saved
        Field::new("created_at",    DataType::Int64, false),
        Field::new("saved_file_id", DataType::Utf8,  true),   // NEW — null until Download
    ])))
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Activity {
    pub id: String,
    pub owner_did: String,
    pub actor: String,
    pub activity_type: String,
    pub space: String,
    pub object_id: Option<String>,
    pub object_cas: Option<String>,
    pub object_name: Option<String>,
    pub to: Vec<String>,
    pub raw_json: String,
    pub status: String,
    pub created_at: i64,
    pub saved_file_id: Option<String>,   // NEW
}

impl Activity {
    #[allow(clippy::too_many_arguments)]
    pub fn new(
        actor: impl Into<String>, activity_type: impl Into<String>, space: impl Into<String>,
        object_id: Option<String>, object_cas: Option<String>, object_name: Option<String>,
        to: Vec<String>,
    ) -> Self {
        let mut a = Self {
            id: format!("act-{}", uuid::Uuid::new_v4()),
            owner_did: String::new(),
            actor: actor.into(), activity_type: activity_type.into(), space: space.into(),
            object_id, object_cas, object_name, to,
            raw_json: String::new(), status: "pending".to_string(),
            created_at: chrono::Utc::now().timestamp_micros(),
            saved_file_id: None,
        };
        a.owner_did = a.actor.clone();
        a.raw_json = a.to_activitystreams().to_string();
        a
    }

    pub fn to_activitystreams(&self) -> serde_json::Value {
        serde_json::json!({
            "@context": "https://www.w3.org/ns/activitystreams",
            "type": self.activity_type, "id": self.id, "actor": self.actor, "to": self.to,
            "object": { "id": self.object_id, "name": self.object_name, "url": self.object_cas },
            "published": chrono::DateTime::<chrono::Utc>::from_timestamp_micros(self.created_at)
                .unwrap_or_else(chrono::Utc::now).to_rfc3339(),
        })
    }
}

pub struct ActivityStore { base_path: String }

impl ActivityStore {
    pub fn new(base_path: impl Into<String>) -> Self { Self { base_path: base_path.into() } }

    fn dir_for(&self, did: &str) -> String {
        format!("{}/{}/social", self.base_path, did.replace(':', "_"))
    }

    async fn open(&self, did: &str, box_name: &str) -> PlatformResult<Table> {
        let dir = self.dir_for(did);
        let conn = connect(&dir).execute().await?;
        let expected = activity_schema();
        match conn.open_table(box_name).execute().await {
            Ok(table) => {
                let ok = matches!(table.schema().await, Ok(s) if s.fields().len() == expected.fields().len());
                if ok { Ok(table) } else {
                    let _ = conn.drop_table(box_name).await;
                    Ok(conn.create_empty_table(box_name, expected).execute().await?)
                }
            }
            Err(_) => Ok(conn.create_empty_table(box_name, expected).execute().await?),
        }
    }

    pub async fn append(&self, owner_did: &str, box_name: &str, activity: &Activity) -> PlatformResult<()> {
        let table = self.open(owner_did, box_name).await?;
        let mut row = activity.clone();
        row.owner_did = owner_did.to_string();
        table.delete(&format!("id = '{}'", row.id)).await.ok();
        let batch = activity_to_batch(&row)?;
        let reader = RecordBatchIterator::new(vec![Ok(batch)], activity_schema());
        table.add(reader).execute().await?;
        Ok(())
    }

    pub async fn list(&self, did: &str, box_name: &str, space: &Space) -> PlatformResult<Vec<Activity>> {
        self.query(did, box_name, &format!("space = '{}'", space.as_str())).await
    }

    pub async fn list_pending(&self, did: &str, box_name: &str) -> PlatformResult<Vec<Activity>> {
        self.query(did, box_name, "status = 'pending'").await
    }

    pub async fn get(&self, did: &str, box_name: &str, id: &str) -> PlatformResult<Option<Activity>> {
        let mut v = self.query(did, box_name, &format!("id = '{}'", id)).await?;
        Ok(v.pop())
    }

    pub async fn mark_status(&self, did: &str, box_name: &str, id: &str, status: &str) -> PlatformResult<()> {
        if let Some(mut a) = self.get(did, box_name, id).await? {
            a.status = status.to_string();
            self.append(did, box_name, &a).await?;
        }
        Ok(())
    }

    pub async fn mark_saved(&self, did: &str, box_name: &str, id: &str, saved_file_id: &str) -> PlatformResult<()> {
        if let Some(mut a) = self.get(did, box_name, id).await? {
            a.status = "saved".to_string();
            a.saved_file_id = Some(saved_file_id.to_string());
            self.append(did, box_name, &a).await?;
        }
        Ok(())
    }

    async fn query(&self, did: &str, box_name: &str, predicate: &str) -> PlatformResult<Vec<Activity>> {
        let table = self.open(did, box_name).await?;
        let batches: Vec<RecordBatch> = table.query().only_if(predicate.to_string())
            .execute().await?.try_collect().await?;
        let mut activities = batch_to_activities(batches);
        activities.sort_by_key(|a| a.created_at);
        Ok(activities)
    }
}

fn activity_to_batch(a: &Activity) -> PlatformResult<RecordBatch> {
    let to_json = serde_json::to_string(&a.to).unwrap_or_else(|_| "[]".to_string());
    RecordBatch::try_new(activity_schema(), vec![
        Arc::new(StringArray::from(vec![a.id.as_str()])),
        Arc::new(StringArray::from(vec![a.owner_did.as_str()])),
        Arc::new(StringArray::from(vec![a.actor.as_str()])),
        Arc::new(StringArray::from(vec![a.activity_type.as_str()])),
        Arc::new(StringArray::from(vec![a.space.as_str()])),
        Arc::new(StringArray::from(vec![a.object_id.as_deref()])),
        Arc::new(StringArray::from(vec![a.object_cas.as_deref()])),
        Arc::new(StringArray::from(vec![a.object_name.as_deref()])),
        Arc::new(StringArray::from(vec![to_json.as_str()])),
        Arc::new(StringArray::from(vec![a.raw_json.as_str()])),
        Arc::new(StringArray::from(vec![a.status.as_str()])),
        Arc::new(Int64Array::from(vec![a.created_at])),
        Arc::new(StringArray::from(vec![a.saved_file_id.as_deref()])),
    ]).map_err(|e| PlatformError::Arrow(e.to_string()))
}

fn batch_to_activities(batches: Vec<RecordBatch>) -> Vec<Activity> {
    let mut out = Vec::new();
    for batch in batches {
        let n = batch.num_rows();
        let col_s = |name: &str| -> Option<&StringArray> {
            batch.column_by_name(name)?.as_any().downcast_ref::<StringArray>()
        };
        let col_i = |name: &str| -> Option<&Int64Array> {
            batch.column_by_name(name)?.as_any().downcast_ref::<Int64Array>()
        };
        let (id, owner_did, actor, activity_type, space) =
            (col_s("id"), col_s("owner_did"), col_s("actor"), col_s("activity_type"), col_s("space"));
        let (object_id, object_cas, object_name, to_json, raw_json, status, saved_file_id) =
            (col_s("object_id"), col_s("object_cas"), col_s("object_name"), col_s("to_json"),
             col_s("raw_json"), col_s("status"), col_s("saved_file_id"));
        let created_at = col_i("created_at");

        for i in 0..n {
            let req = |a: Option<&StringArray>| a.map(|x| x.value(i).to_string()).unwrap_or_default();
            let opt = |a: Option<&StringArray>| a.and_then(|x| if x.is_null(i) { None } else { Some(x.value(i).to_string()) });
            let to: Vec<String> = serde_json::from_str(&req(to_json)).unwrap_or_default();
            out.push(Activity {
                id: req(id), owner_did: req(owner_did), actor: req(actor),
                activity_type: req(activity_type), space: req(space),
                object_id: opt(object_id), object_cas: opt(object_cas), object_name: opt(object_name),
                to, raw_json: req(raw_json), status: req(status),
                created_at: created_at.map(|c| c.value(i)).unwrap_or(0),
                saved_file_id: opt(saved_file_id),
            });
        }
    }
    out
}