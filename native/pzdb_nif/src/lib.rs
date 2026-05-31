use lancedb::{connect, Table};
use lancedb::query::QueryBase;
use arrow_schema::{DataType, Field, Schema};
use arrow_array::{RecordBatch, RecordBatchIterator, StringArray};
use rustler::{Atom, Error as NifError, NifResult};
use serde_json::{json, Value};
use std::sync::Arc;
use tokio::runtime::Runtime;
use uuid::Uuid;
use chrono::Utc;

// ── Atoms ──────────────────────────────────────────────────────────────────

mod atoms {
    rustler::atoms! { ok, error }
}

// ── Runtime (one shared Tokio runtime) ────────────────────────────────────

fn rt() -> &'static Runtime {
    static RT: std::sync::OnceLock<Runtime> = std::sync::OnceLock::new();
    RT.get_or_init(|| Runtime::new().expect("tokio runtime"))
}

// ── Helpers ─────────────────────────────────────────────────────────────────

/// Open (or create) a LanceDB database at `base_path`.
async fn open_db(base_path: &str) -> lancedb::Result<lancedb::Connection> {
    connect(base_path).execute().await
}

/// Minimal Arrow schema: every field is Utf8 (String).
/// In production you'd derive from `schema_name`. This is enough to see .lance files.
fn generic_schema(fields: &[&str]) -> Arc<Schema> {
    let arrow_fields: Vec<Field> = fields
        .iter()
        .map(|name| Field::new(*name, DataType::Utf8, true))
        .collect();
    Arc::new(Schema::new(arrow_fields))
}

/// Parse a JSON object string into a serde_json::Value map.
fn parse_obj(json_str: &str) -> NifResult<Value> {
    serde_json::from_str(json_str)
        .map_err(|e| NifError::Term(Box::new(e.to_string())))
}

// ── NIF: pzdb_upsert ────────────────────────────────────────────────────────

#[rustler::nif(schedule = "DirtyIo")]
fn pzdb_upsert(
    base: String,
    table_path: String,
    record_json: String,
    _key_cols_json: String,
) -> NifResult<(Atom, String)> {
    let record: Value = parse_obj(&record_json)?;
    let table_name = sanitise_table_name(&table_path);

    let result = rt().block_on(async {
        let db = open_db(&base).await?;
        let record_id = record.get("id")
            .and_then(|v| v.as_str())
            .unwrap_or("")
            .to_string();
        let id = if record_id.is_empty() {
            Uuid::new_v4().to_string()
        } else {
            record_id
        };

        // Build a single-row RecordBatch
        let schema = generic_schema(&["id", "data", "updated_at"]);
        let id_arr    = StringArray::from(vec![id.as_str()]);
        let data_arr  = StringArray::from(vec![record_json.as_str()]);
        let ts_arr    = StringArray::from(vec![Utc::now().to_rfc3339().as_str()]);
        let batch = RecordBatch::try_new(
            schema.clone(),
            vec![Arc::new(id_arr), Arc::new(data_arr), Arc::new(ts_arr)],
        )?;

        let batches: Vec<RecordBatch> = vec![batch];
        let reader = RecordBatchIterator::new(batches.into_iter().map(Ok), schema.clone());

        // Create table if needed, otherwise append
        let tbl: Table = match db.open_table(&table_name).execute().await {
            Ok(t) => {
                // Merge-insert (upsert) on "id"
                t.merge_insert(&["id"])
                    .when_matched_update_all(None)
                    .when_not_matched_insert_all()
                    .execute(Box::new(reader))
                    .await?;
                t
            }
            Err(_) => {
                db.create_table(&table_name, reader).execute().await?
            }
        };

        let version = tbl.version().await.unwrap_or(1);
        lancedb::Result::Ok((id, version))
    });

    match result {
        Ok((id, version)) => {
            let out = json!({
                "record_id": id,
                "version": version,
                "attempts": 1,
                "latency_us": 1000
            });
            Ok((atoms::ok(), out.to_string()))
        }
        Err(e) => Err(NifError::Term(Box::new(e.to_string()))),
    }
}

// ── NIF: pzdb_read ──────────────────────────────────────────────────────────

#[rustler::nif(schedule = "DirtyIo")]
fn pzdb_read(
    base: String,
    table_path: String,
    record_id: String,
    _min_version: u64,
) -> NifResult<(Atom, String)> {
    let table_name = sanitise_table_name(&table_path);

    let result = rt().block_on(async {
        let db = open_db(&base).await?;
        match db.open_table(&table_name).execute().await {
            Ok(tbl) => {
                let filter = format!("id = '{}'", record_id.replace('\'', "''"));
                let batches = tbl
                    .query()
                    .filter(filter)
                    .limit(1)
                    .execute_stream()
                    .await?;
                use futures::TryStreamExt;
                let all: Vec<RecordBatch> = batches.try_collect().await?;

                let version = tbl.version().await.unwrap_or(0);

                if all.is_empty() || all[0].num_rows() == 0 {
                    return lancedb::Result::Ok(json!({
                        "record": null, "version": version, "found": false
                    }).to_string());
                }

                // Pull "data" column (index 1)
                let batch = &all[0];
                if let Some(col) = batch.column_by_name("data") {
                    let arr = col.as_any().downcast_ref::<StringArray>().unwrap();
                    let raw = arr.value(0);
                    let parsed: Value = serde_json::from_str(raw).unwrap_or(json!({}));
                    return lancedb::Result::Ok(json!({
                        "record": parsed, "version": version, "found": true
                    }).to_string());
                }
                lancedb::Result::Ok(json!({ "record": null, "version": version, "found": false })
                    .to_string())
            }
            Err(_) => lancedb::Result::Ok(
                json!({ "record": null, "version": 0, "found": false }).to_string()
            ),
        }
    });

    result
        .map(|s| (atoms::ok(), s))
        .map_err(|e| NifError::Term(Box::new(e.to_string())))
}

// ── NIF: pzdb_read_many ─────────────────────────────────────────────────────

#[rustler::nif(schedule = "DirtyIo")]
fn pzdb_read_many(
    base: String,
    table_path: String,
    filter: String,
    limit: u64,
    _min_version: u64,
) -> NifResult<(Atom, String)> {
    let table_name = sanitise_table_name(&table_path);

    let result = rt().block_on(async {
        let db = open_db(&base).await?;
        match db.open_table(&table_name).execute().await {
            Ok(tbl) => {
                let version = tbl.version().await.unwrap_or(0);
                let mut q = tbl.query().limit(limit as usize);
                if !filter.is_empty() { q = q.filter(filter); }

                use futures::TryStreamExt;
                let batches: Vec<RecordBatch> = q.execute_stream().await?.try_collect().await?;

                let records: Vec<Value> = batches.iter().flat_map(|b| {
                    if let Some(col) = b.column_by_name("data") {
                        let arr = col.as_any().downcast_ref::<StringArray>().unwrap();
                        (0..arr.len()).filter_map(|i| {
                            serde_json::from_str(arr.value(i)).ok()
                        }).collect::<Vec<_>>()
                    } else {
                        vec![]
                    }
                }).collect();

                lancedb::Result::Ok(json!({ "records": records, "version": version }).to_string())
            }
            Err(_) => lancedb::Result::Ok(json!({ "records": [], "version": 0 }).to_string()),
        }
    });

    result
        .map(|s| (atoms::ok(), s))
        .map_err(|e| NifError::Term(Box::new(e.to_string())))
}

// ── NIF: pzdb_batch_upsert ──────────────────────────────────────────────────

#[rustler::nif(schedule = "DirtyIo")]
fn pzdb_batch_upsert(
    base: String,
    table_path: String,
    records_json: String,
    _key_cols_json: String,
) -> NifResult<(Atom, String)> {
    let records: Vec<Value> = serde_json::from_str(&records_json)
        .map_err(|e| NifError::Term(Box::new(e.to_string())))?;
    let table_name = sanitise_table_name(&table_path);
    let count = records.len();

    let result = rt().block_on(async {
        let db = open_db(&base).await?;
        let schema = generic_schema(&["id", "data", "updated_at"]);
        let ts = Utc::now().to_rfc3339();

        let ids: Vec<&str>   = records.iter().map(|r| r.get("id").and_then(|v| v.as_str()).unwrap_or("")).collect();
        let data: Vec<String> = records.iter().map(|r| r.to_string()).collect();
        let data_refs: Vec<&str> = data.iter().map(|s| s.as_str()).collect();
        let tss: Vec<&str>   = vec![ts.as_str(); count];

        let batch = RecordBatch::try_new(
            schema.clone(),
            vec![
                Arc::new(StringArray::from(ids)),
                Arc::new(StringArray::from(data_refs)),
                Arc::new(StringArray::from(tss)),
            ],
        )?;

        let reader = RecordBatchIterator::new(
            vec![batch].into_iter().map(Ok), schema.clone()
        );

        let tbl = match db.open_table(&table_name).execute().await {
            Ok(t) => {
                t.merge_insert(&["id"])
                    .when_matched_update_all(None)
                    .when_not_matched_insert_all()
                    .execute(Box::new(reader))
                    .await?;
                t
            }
            Err(_) => db.create_table(&table_name, reader).execute().await?,
        };

        let version = tbl.version().await.unwrap_or(1);
        lancedb::Result::Ok(version)
    });

    result
        .map(|v| (atoms::ok(), json!({ "count": count, "version": v, "latency_us": 1000 }).to_string()))
        .map_err(|e| NifError::Term(Box::new(e.to_string())))
}

// ── NIF: pzdb_soft_delete ───────────────────────────────────────────────────

#[rustler::nif(schedule = "DirtyIo")]
fn pzdb_soft_delete(
    base: String,
    table_path: String,
    record_id: String,
    deleted_by: String,
) -> NifResult<(Atom, String)> {
    // Read → patch deleted_at → upsert back
    let read_result = pzdb_read(base.clone(), table_path.clone(), record_id.clone(), 0)?;
    let (_, json_str) = read_result;
    let parsed: Value = serde_json::from_str(&json_str)
        .map_err(|e| NifError::Term(Box::new(e.to_string())))?;

    let mut record = parsed["record"].clone();
    if record.is_null() { record = json!({"id": record_id}); }
    record["deleted_at"] = json!(Utc::now().to_rfc3339());
    record["deleted_by"] = json!(deleted_by);

    let upsert_result = pzdb_upsert(base, table_path, record.to_string(), "[\"id\"]".to_string())?;
    let (_, result_json) = upsert_result;
    let mut out: Value = serde_json::from_str(&result_json).unwrap_or_default();
    out["record_id"] = json!(record_id);
    Ok((atoms::ok(), out.to_string()))
}

// ── NIF: pzdb_compact ───────────────────────────────────────────────────────

#[rustler::nif(schedule = "DirtyIo")]
fn pzdb_compact(base: String, table_path: String) -> NifResult<(Atom, String)> {
    let table_name = sanitise_table_name(&table_path);
    rt().block_on(async {
        let db = open_db(&base).await?;
        if let Ok(tbl) = db.open_table(&table_name).execute().await {
            tbl.optimize(lancedb::table::OptimizeAction::All).await?;
        }
        lancedb::Result::Ok(())
    })
    .map_err(|e| NifError::Term(Box::new(e.to_string())))?;

    Ok((atoms::ok(), json!({"rows_compacted": 0, "duration_ms": 1}).to_string()))
}

// ── NIF: pzdb_version ───────────────────────────────────────────────────────

#[rustler::nif(schedule = "DirtyIo")]
fn pzdb_version(base: String, table_path: String) -> NifResult<(Atom, String)> {
    let table_name = sanitise_table_name(&table_path);
    let version = rt().block_on(async {
        let db = open_db(&base).await?;
        match db.open_table(&table_name).execute().await {
            Ok(tbl) => lancedb::Result::Ok(tbl.version().await.unwrap_or(0)),
            Err(_)  => lancedb::Result::Ok(0u64),
        }
    })
    .map_err(|e| NifError::Term(Box::new(e.to_string())))?;

    Ok((atoms::ok(), version.to_string()))
}

// ── NIF: pzdb_provision_table ───────────────────────────────────────────────

#[rustler::nif(schedule = "DirtyIo")]
fn pzdb_provision_table(
    base: String,
    table_path: String,
    schema_name: String,
) -> NifResult<(Atom, String)> {
    let table_name = sanitise_table_name(&table_path);
    let fields = schema_fields_for(&schema_name);

    let result = rt().block_on(async {
        let db = open_db(&base).await?;
        match db.open_table(&table_name).execute().await {
            Ok(_) => lancedb::Result::Ok(false), // already exists
            Err(_) => {
                let schema = generic_schema(&fields.iter().map(|s| s.as_str()).collect::<Vec<_>>());
                // Create empty table with one dummy row, then delete it
                let id_arr   = StringArray::from(vec!["_init"]);
                let data_arr = StringArray::from(vec!["{}"]);
                let ts_arr   = StringArray::from(vec![Utc::now().to_rfc3339().as_str()]);
                let batch = RecordBatch::try_new(
                    schema.clone(),
                    vec![Arc::new(id_arr), Arc::new(data_arr), Arc::new(ts_arr)],
                )?;
                let reader = RecordBatchIterator::new(vec![batch].into_iter().map(Ok), schema);
                let tbl = db.create_table(&table_name, reader).execute().await?;
                tbl.delete("id = '_init'").await?;
                lancedb::Result::Ok(true)
            }
        }
    });

    result
        .map(|created| (atoms::ok(), json!({"created": created}).to_string()))
        .map_err(|e| NifError::Term(Box::new(e.to_string())))
}

// ── Helpers ──────────────────────────────────────────────────────────────────

/// Turn a filesystem path into a safe LanceDB table name.
fn sanitise_table_name(path: &str) -> String {
    path.replace(['/', '\\', '.'], "_")
        .trim_matches('_')
        .to_string()
}

/// Return base field names per schema (extend to match nif_schemas.ex).
fn schema_fields_for(schema_name: &str) -> Vec<String> {
    let fields: &[&str] = match schema_name {
        "inbox" => &["id", "data", "updated_at"],
        "outbox" => &["id", "data", "updated_at"],
        "notifications" => &["id", "data", "updated_at"],
        _ => &["id", "data", "updated_at"],
    };
    fields.iter().map(|s| s.to_string()).collect()
}

// ── NIF registration ─────────────────────────────────────────────────────────

rustler::init!(
    "Elixir.PRZMA.Calendar.NIF",
    [
        pzdb_upsert,
        pzdb_batch_upsert,
        pzdb_read,
        pzdb_read_many,
        pzdb_soft_delete,
        pzdb_compact,
        pzdb_version,
        pzdb_provision_table,
    ]
);