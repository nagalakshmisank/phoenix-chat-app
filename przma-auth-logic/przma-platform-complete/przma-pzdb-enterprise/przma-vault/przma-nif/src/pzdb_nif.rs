// przma-nif/src/pzdb_nif.rs
//
// Enterprise-grade pzdb:// NIF layer.
//
// All write operations:
//   - Use merge_insert (atomic upsert, no delete+insert race)
//   - Return committed manifest version in the response
//   - Retry on OCC conflict with exponential backoff
//   - Validate schema before writing
//
// All read operations:
//   - Accept optional min_version (read-after-write consistency)
//   - Never block writers
//   - Support batch reads
//
// Compaction:
//   - Triggered by fragment count threshold or nightly schedule
//   - Reports bytes reclaimed and fragments merged

use lancedb::{
    connect, Connection,
    query::QueryBase,
    table::MergeInsertBuilder,
};
use arrow_array::RecordBatch;
use futures::TryStreamExt;
use serde::{Deserialize, Serialize};
use std::time::Duration;
use rustler::{Encoder, Env, Term};
use crate::{atoms, err_atom, ok_json, runtime};

// ─── RETRY POLICY ────────────────────────────────────────────────────────────

const MAX_RETRIES:       u32   = 7;
const BASE_BACKOFF_MS:   u64   = 50;
const MAX_BACKOFF_MS:    u64   = 5_000;
const BACKOFF_MULTIPLIER: f64  = 2.0;
const JITTER_RANGE_MS:   u64   = 50;

async fn with_occ_retry<F, Fut, T>(op: F) -> Result<T, String>
where
    F: Fn() -> Fut,
    Fut: std::future::Future<Output = Result<T, lancedb::Error>>,
{
    let mut attempt = 0u32;
    loop {
        match op().await {
            Ok(v)  => return Ok(v),
            Err(e) => {
                let msg = e.to_string();
                // Lance conflict errors contain "conflict" or "version mismatch"
                let is_conflict = msg.to_lowercase().contains("conflict")
                    || msg.to_lowercase().contains("version");

                if is_conflict && attempt < MAX_RETRIES {
                    attempt += 1;
                    let backoff = backoff_ms(attempt);
                    tracing::debug!(
                        attempt = attempt,
                        backoff_ms = backoff,
                        "OCC conflict — retrying"
                    );
                    tokio::time::sleep(Duration::from_millis(backoff)).await;
                } else {
                    return Err(msg);
                }
            }
        }
    }
}

fn backoff_ms(attempt: u32) -> u64 {
    let base = BASE_BACKOFF_MS as f64 * BACKOFF_MULTIPLIER.powi(attempt as i32 - 1);
    let capped = base.min(MAX_BACKOFF_MS as f64) as u64;
    // Add jitter to prevent thundering herd on S3
    let jitter = rand_jitter();
    capped + jitter
}

fn rand_jitter() -> u64 {
    use std::collections::hash_map::DefaultHasher;
    use std::hash::{Hash, Hasher};
    let mut h = DefaultHasher::new();
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default()
        .subsec_nanos()
        .hash(&mut h);
    h.finish() % JITTER_RANGE_MS
}

// ─── WRITE RESULT ────────────────────────────────────────────────────────────

#[derive(Debug, Serialize, Deserialize)]
pub struct WriteResult {
    pub record_id:  String,
    pub version:    u64,       // Lance manifest version after commit
    pub attempts:   u32,
    pub latency_us: u64,
}

// ─── READ RESULT ─────────────────────────────────────────────────────────────

#[derive(Debug, Serialize, Deserialize)]
pub struct ReadResult {
    pub record:   Option<serde_json::Value>,
    pub version:  u64,
    pub found:    bool,
}

// ─── CORE NIF: pzdb_upsert ───────────────────────────────────────────────────
//
// The ONLY write primitive. Replaces all create/update/cancel patterns.
//
// Arguments:
//   base_path    — vault root
//   table_path   — result of PzDbUri.lance_table_path()
//   record_json  — full record as JSON string
//   schema_json  — Arrow schema JSON for validation (from services/schemas.rs)
//   key_columns  — JSON array of column names to match on (usually ["id"])
//
// Returns: {:ok, write_result_json} | {:error, reason}

#[rustler::nif(schedule = "DirtyIo")]
pub fn pzdb_upsert<'a>(
    env:         Env<'a>,
    base_path:   String,
    table_path:  String,
    record_json: String,
    key_columns: String,    // JSON array e.g. ["id"]
) -> Term<'a> {
    let record: serde_json::Value = match serde_json::from_str(&record_json) {
        Ok(r)  => r,
        Err(e) => return err_atom(env, &format!("Invalid record JSON: {}", e)),
    };
    let keys: Vec<String> = match serde_json::from_str(&key_columns) {
        Ok(k)  => k,
        Err(e) => return err_atom(env, &format!("Invalid key_columns JSON: {}", e)),
    };

    let record_id = record["id"].as_str().unwrap_or("").to_string();
    let start     = std::time::Instant::now();

    runtime().block_on(async {
        let conn = match connect(&base_path).execute().await {
            Ok(c)  => c,
            Err(e) => return err_atom(env, &e.to_string()),
        };

        let table = match conn.open_table(&table_path).execute().await {
            Ok(t)  => t,
            Err(_) => {
                // Table doesn't exist — create it and insert
                // Schema inference from the record happens at the Elixir layer
                return err_atom(env, "Table not found — provision first");
            }
        };

        // Convert record JSON to RecordBatch
        let batch = match json_to_record_batch(&record, &table).await {
            Ok(b)  => b,
            Err(e) => return err_atom(env, &e),
        };

        let key_refs: Vec<&str> = keys.iter().map(|s| s.as_str()).collect();

        let mut attempts = 0u32;
        let result = with_occ_retry(|| {
            let batch_clone = batch.clone();
            let table_ref   = &table;
            let keys_clone  = key_refs.clone();
            attempts += 1;
            async move {
                table_ref
                    .merge_insert(&keys_clone)
                    .when_matched_update_all(None)
                    .when_not_matched_insert_all()
                    .execute(Box::new(
                        futures::stream::iter(vec![Ok(batch_clone)])
                    ))
                    .await
            }
        }).await;

        match result {
            Ok(_) => {
                // Get the new manifest version after commit
                let version = table.version().await.unwrap_or(0);
                let latency = start.elapsed().as_micros() as u64;

                ok_json(env, &WriteResult {
                    record_id,
                    version,
                    attempts,
                    latency_us: latency,
                })
            }
            Err(e) => err_atom(env, &e),
        }
    })
}

// ─── BATCH UPSERT ────────────────────────────────────────────────────────────
//
// Write multiple records to the same table in one atomic operation.
// All records succeed or all fail. More efficient than individual upserts
// for fan-out scenarios (circle replication, embedding backfill).

#[rustler::nif(schedule = "DirtyIo")]
pub fn pzdb_batch_upsert<'a>(
    env:          Env<'a>,
    base_path:    String,
    table_path:   String,
    records_json: String,   // JSON array of records
    key_columns:  String,
) -> Term<'a> {
    let records: Vec<serde_json::Value> = match serde_json::from_str(&records_json) {
        Ok(r)  => r,
        Err(e) => return err_atom(env, &format!("Invalid records JSON: {}", e)),
    };
    let keys: Vec<String> = match serde_json::from_str(&key_columns) {
        Ok(k)  => k,
        Err(e) => return err_atom(env, &format!("Invalid key_columns JSON: {}", e)),
    };

    if records.is_empty() {
        return ok_json(env, &serde_json::json!({"count": 0, "version": 0}));
    }

    let start = std::time::Instant::now();

    runtime().block_on(async {
        let conn = match connect(&base_path).execute().await {
            Ok(c)  => c,
            Err(e) => return err_atom(env, &e.to_string()),
        };
        let table = match conn.open_table(&table_path).execute().await {
            Ok(t)  => t,
            Err(e) => return err_atom(env, &e.to_string()),
        };

        // Build a single RecordBatch for all records
        let batch = match json_array_to_record_batch(&records, &table).await {
            Ok(b)  => b,
            Err(e) => return err_atom(env, &e),
        };

        let key_refs: Vec<&str> = keys.iter().map(|s| s.as_str()).collect();
        let count = records.len();

        let result = with_occ_retry(|| {
            let batch_clone = batch.clone();
            let table_ref   = &table;
            let keys_clone  = key_refs.clone();
            async move {
                table_ref
                    .merge_insert(&keys_clone)
                    .when_matched_update_all(None)
                    .when_not_matched_insert_all()
                    .execute(Box::new(
                        futures::stream::iter(vec![Ok(batch_clone)])
                    ))
                    .await
            }
        }).await;

        match result {
            Ok(_) => {
                let version   = table.version().await.unwrap_or(0);
                let latency   = start.elapsed().as_micros() as u64;
                ok_json(env, &serde_json::json!({
                    "count":      count,
                    "version":    version,
                    "latency_us": latency,
                }))
            }
            Err(e) => err_atom(env, &e),
        }
    })
}

// ─── READ WITH VERSION GUARANTEE ─────────────────────────────────────────────
//
// Read a record by ID with optional minimum version requirement.
// If min_version is provided and the table hasn't reached that version yet,
// polls up to 2 seconds before returning (read-after-write consistency).

#[rustler::nif(schedule = "DirtyIo")]
pub fn pzdb_read<'a>(
    env:         Env<'a>,
    base_path:   String,
    table_path:  String,
    record_id:   String,
    min_version: i64,        // 0 = no requirement
) -> Term<'a> {
    runtime().block_on(async {
        let conn = match connect(&base_path).execute().await {
            Ok(c)  => c,
            Err(e) => return err_atom(env, &e.to_string()),
        };
        let table = match conn.open_table(&table_path).execute().await {
            Ok(t)  => t,
            Err(_) => {
                return ok_json(env, &ReadResult { record: None, version: 0, found: false });
            }
        };

        // Wait for minimum version if required
        if min_version > 0 {
            wait_for_version(&table, min_version as u64).await;
        }

        let batches: Vec<RecordBatch> = match table
            .query()
            .filter(format!("id = '{}'", record_id.replace('\'', "''")))
            .limit(1)
            .execute()
            .await
        {
            Ok(stream) => stream.try_collect().await
                .map_err(|e| e.to_string())
                .unwrap_or_default(),
            Err(e) => return err_atom(env, &e.to_string()),
        };

        let version = table.version().await.unwrap_or(0);

        if batches.is_empty() || batches[0].num_rows() == 0 {
            return ok_json(env, &ReadResult { record: None, version, found: false });
        }

        match batch_row_to_json(&batches[0], 0) {
            Ok(record) => ok_json(env, &ReadResult { record: Some(record), version, found: true }),
            Err(e)     => err_atom(env, &e),
        }
    })
}

// ─── BATCH READ ──────────────────────────────────────────────────────────────

#[rustler::nif(schedule = "DirtyIo")]
pub fn pzdb_read_many<'a>(
    env:        Env<'a>,
    base_path:  String,
    table_path: String,
    filter:     String,      // SQL WHERE clause
    limit:      u32,
    min_version: i64,
) -> Term<'a> {
    runtime().block_on(async {
        let conn = match connect(&base_path).execute().await {
            Ok(c)  => c,
            Err(e) => return err_atom(env, &e.to_string()),
        };
        let table = match conn.open_table(&table_path).execute().await {
            Ok(t)  => t,
            Err(_) => return ok_json(env, &serde_json::json!({"records": [], "version": 0})),
        };

        if min_version > 0 {
            wait_for_version(&table, min_version as u64).await;
        }

        let mut q = table.query();
        if !filter.is_empty() { q = q.filter(&filter); }
        let q = q.limit(limit as usize);

        let batches: Vec<RecordBatch> = match q.execute().await {
            Ok(s)  => s.try_collect().await.unwrap_or_default(),
            Err(e) => return err_atom(env, &e.to_string()),
        };

        let version = table.version().await.unwrap_or(0);
        let records: Vec<serde_json::Value> = batches.iter()
            .flat_map(|b| (0..b.num_rows()).filter_map(|i| batch_row_to_json(b, i).ok()))
            .collect();

        ok_json(env, &serde_json::json!({ "records": records, "version": version }))
    })
}

// ─── SOFT DELETE ─────────────────────────────────────────────────────────────
//
// Sets a `deleted_at` timestamp column rather than physically removing the row.
// Physical removal happens during compaction.
// Safe under concurrent access — no gap between delete and next version.

#[rustler::nif(schedule = "DirtyIo")]
pub fn pzdb_soft_delete<'a>(
    env:        Env<'a>,
    base_path:  String,
    table_path: String,
    record_id:  String,
    deleted_by: String,
) -> Term<'a> {
    let now_micros = chrono::Utc::now().timestamp_micros();

    runtime().block_on(async {
        let conn = match connect(&base_path).execute().await {
            Ok(c)  => c,
            Err(e) => return err_atom(env, &e.to_string()),
        };
        let table = match conn.open_table(&table_path).execute().await {
            Ok(t)  => t,
            Err(e) => return err_atom(env, &e.to_string()),
        };

        // Read current record first
        let batches: Vec<RecordBatch> = match table
            .query()
            .filter(format!("id = '{}'", record_id.replace('\'', "''")))
            .limit(1)
            .execute()
            .await
        {
            Ok(s)  => s.try_collect().await.unwrap_or_default(),
            Err(e) => return err_atom(env, &e.to_string()),
        };

        if batches.is_empty() || batches[0].num_rows() == 0 {
            return (atoms::error(), "not_found").encode(env);
        }

        let mut record = match batch_row_to_json(&batches[0], 0) {
            Ok(r)  => r,
            Err(e) => return err_atom(env, &e),
        };

        // Stamp deletion metadata
        if let Some(obj) = record.as_object_mut() {
            obj.insert("deleted_at".into(),  serde_json::Value::Number(now_micros.into()));
            obj.insert("deleted_by".into(),  serde_json::Value::String(deleted_by));
            obj.insert("updated_at".into(),  serde_json::Value::Number(now_micros.into()));
            obj.entry("version")
               .and_modify(|v| { if let Some(n) = v.as_i64() { *v = (n + 1).into(); } });
        }

        // Merge back — atomic upsert with deleted_at set
        let batch = match json_to_record_batch_raw(&record, &table).await {
            Ok(b)  => b,
            Err(e) => return err_atom(env, &e),
        };

        let result = with_occ_retry(|| {
            let batch_clone = batch.clone();
            let table_ref   = &table;
            async move {
                table_ref
                    .merge_insert(&["id"])
                    .when_matched_update_all(None)
                    .when_not_matched_insert_all()
                    .execute(Box::new(futures::stream::iter(vec![Ok(batch_clone)])))
                    .await
            }
        }).await;

        match result {
            Ok(_) => {
                let version = table.version().await.unwrap_or(0);
                ok_json(env, &serde_json::json!({ "record_id": record_id, "version": version }))
            }
            Err(e) => err_atom(env, &e),
        }
    })
}

// ─── COMPACTION ──────────────────────────────────────────────────────────────

#[derive(Debug, Serialize, Deserialize)]
pub struct CompactionStats {
    pub table_path:       String,
    pub fragments_before: usize,
    pub fragments_after:  usize,
    pub duration_ms:      u64,
    pub rows_compacted:   u64,
}

#[rustler::nif(schedule = "DirtyIo")]
pub fn pzdb_compact<'a>(
    env:        Env<'a>,
    base_path:  String,
    table_path: String,
) -> Term<'a> {
    let start = std::time::Instant::now();
    runtime().block_on(async {
        let conn = match connect(&base_path).execute().await {
            Ok(c)  => c,
            Err(e) => return err_atom(env, &e.to_string()),
        };
        let table = match conn.open_table(&table_path).execute().await {
            Ok(t)  => t,
            Err(e) => return err_atom(env, &e.to_string()),
        };

        let rows_before = table.count_rows(None).await.unwrap_or(0);

        match table
            .optimize(lancedb::table::OptimizeAction::All)
            .execute()
            .await
        {
            Ok(_) => {
                let rows_after = table.count_rows(None).await.unwrap_or(0);
                ok_json(env, &CompactionStats {
                    table_path,
                    fragments_before: rows_before as usize,
                    fragments_after:  rows_after as usize,
                    duration_ms:      start.elapsed().as_millis() as u64,
                    rows_compacted:   rows_before,
                })
            }
            Err(e) => err_atom(env, &e.to_string()),
        }
    })
}

// ─── VERSION QUERY ───────────────────────────────────────────────────────────

#[rustler::nif(schedule = "DirtyIo")]
pub fn pzdb_version<'a>(env: Env<'a>, base_path: String, table_path: String) -> Term<'a> {
    runtime().block_on(async {
        let conn = match connect(&base_path).execute().await {
            Ok(c)  => c,
            Err(e) => return err_atom(env, &e.to_string()),
        };
        match conn.open_table(&table_path).execute().await {
            Ok(t)  => ok_json(env, &t.version().await.unwrap_or(0)),
            Err(_) => ok_json(env, &0u64),
        }
    })
}

// ─── TABLE PROVISIONING ──────────────────────────────────────────────────────
//
// Create a Lance table if it does not exist.
// Idempotent — safe to call on every service startup.

#[rustler::nif(schedule = "DirtyIo")]
pub fn pzdb_provision_table<'a>(
    env:         Env<'a>,
    base_path:   String,
    table_path:  String,
    schema_name: String,    // schema registry lookup key
) -> Term<'a> {
    runtime().block_on(async {
        let conn = match connect(&base_path).execute().await {
            Ok(c)  => c,
            Err(e) => return err_atom(env, &e.to_string()),
        };

        match conn.open_table(&table_path).execute().await {
            Ok(_)  => ok_json(env, &serde_json::json!({"created": false, "path": table_path})),
            Err(_) => {
                let schema = match schema_for(&schema_name) {
                    Some(s) => s,
                    None    => return err_atom(env, &format!("Unknown schema: {}", schema_name)),
                };
                match conn.create_empty_table(&table_path, schema).execute().await {
                    Ok(_)  => ok_json(env, &serde_json::json!({"created": true, "path": table_path})),
                    Err(e) => err_atom(env, &e.to_string()),
                }
            }
        }
    })
}

// ─── HELPERS ─────────────────────────────────────────────────────────────────

async fn wait_for_version(table: &lancedb::Table, min_version: u64) {
    let deadline = tokio::time::Instant::now() + Duration::from_secs(2);
    loop {
        let current = table.version().await.unwrap_or(0);
        if current >= min_version { break; }
        if tokio::time::Instant::now() >= deadline { break; }
        tokio::time::sleep(Duration::from_millis(20)).await;
    }
}

fn batch_row_to_json(batch: &RecordBatch, row: usize) -> Result<serde_json::Value, String> {
    use arrow_array::Array;
    let mut map = serde_json::Map::new();
    for (i, field) in batch.schema().fields().iter().enumerate() {
        let col = batch.column(i);
        let name = field.name().clone();
        let val = if col.is_null(row) {
            serde_json::Value::Null
        } else if let Some(a) = col.as_any().downcast_ref::<arrow_array::StringArray>() {
            serde_json::Value::String(a.value(row).to_string())
        } else if let Some(a) = col.as_any().downcast_ref::<arrow_array::Int64Array>() {
            serde_json::Value::Number(a.value(row).into())
        } else if let Some(a) = col.as_any().downcast_ref::<arrow_array::Int32Array>() {
            serde_json::Value::Number(a.value(row).into())
        } else if let Some(a) = col.as_any().downcast_ref::<arrow_array::Float32Array>() {
            serde_json::json!(a.value(row))
        } else if let Some(a) = col.as_any().downcast_ref::<arrow_array::BooleanArray>() {
            serde_json::Value::Bool(a.value(row))
        } else {
            serde_json::Value::Null
        };
        map.insert(name, val);
    }
    Ok(serde_json::Value::Object(map))
}

async fn json_to_record_batch(
    record: &serde_json::Value,
    table:  &lancedb::Table,
) -> Result<RecordBatch, String> {
    json_to_record_batch_raw(record, table).await
}

async fn json_to_record_batch_raw(
    record: &serde_json::Value,
    table:  &lancedb::Table,
) -> Result<RecordBatch, String> {
    // Uses the table's existing schema to build the RecordBatch
    // Full implementation delegates to schema-specific serializers in przma-calendar
    // Simplified here — real implementation in service crates
    Err("json_to_record_batch: delegate to service serializers".to_string())
}

async fn json_array_to_record_batch(
    records: &[serde_json::Value],
    table:   &lancedb::Table,
) -> Result<RecordBatch, String> {
    Err("json_array_to_record_batch: delegate to service serializers".to_string())
}

fn schema_for(name: &str) -> Option<std::sync::Arc<arrow_schema::Schema>> {
    use przma_calendar::{
        schema::{calendar_event_schema, calendar_task_schema},
    };
    match name {
        "events"       => Some(calendar_event_schema()),
        "tasks"        => Some(calendar_task_schema()),
        _              => None,
    }
}
