// rust/src/pzdb_nif.rs
//
// Enterprise pzdb:// NIF — production-hardened for 100K users.
//
// Every NIF body is wrapped in catch_unwind — a Rust panic no longer kills BEAM.
// Every write uses merge_insert (no delete+insert anywhere).
// Table handles are cached per table_path — one S3 manifest read per 120s per table.
// OCC retry: 7 attempts, exponential backoff 50ms → 5000ms + jitter.
// json_to_record_batch reads the table schema at runtime — no hardcoded schemas.

use arrow_array::{
    Array, BooleanArray, Float32Array, FixedSizeListArray,
    Int32Array, Int64Array, RecordBatch, StringArray,
};
use arrow_schema::{DataType, Field, Schema};
use futures::TryStreamExt;
use lancedb::{connect, query::QueryBase, Connection, Table};
use serde::{Deserialize, Serialize};
use std::{
    collections::HashMap,
    sync::{Arc, LazyLock, RwLock},
    time::{Duration, Instant},
};
use rustler::{Encoder, Env, Term};
use crate::{atoms, err_atom, ok_json, runtime};

// ─── TABLE CACHE ─────────────────────────────────────────────────────────────
// Caches open Table handles, keyed by "{base_path}:{table_path}".
// Each entry has a 120-second TTL.  On VaultWriter idle-exit, entries expire
// automatically — no manual invalidation required.
//
// Before this cache: every NIF call opened a new connection (1 S3 GET per call).
// After this cache:  one S3 manifest read per DID per 120 seconds.

const CACHE_TTL_SECS: u64 = 120;

struct CachedTable {
    table:     Arc<Table>,
    inserted:  Instant,
}

static TABLE_CACHE: LazyLock<RwLock<HashMap<String, CachedTable>>> =
    LazyLock::new(|| RwLock::new(HashMap::new()));

async fn get_table(base_path: &str, table_path: &str) -> Result<Arc<Table>, String> {
    let key = format!("{}:{}", base_path, table_path);

    // Fast path — read lock
    {
        let cache = TABLE_CACHE.read().map_err(|e| e.to_string())?;
        if let Some(entry) = cache.get(&key) {
            if entry.inserted.elapsed().as_secs() < CACHE_TTL_SECS {
                return Ok(Arc::clone(&entry.table));
            }
        }
    }

    // Slow path — open + insert
    let conn = connect(base_path)
        .execute()
        .await
        .map_err(|e| format!("connect failed: {}", e))?;

    let table = conn
        .open_table(table_path)
        .execute()
        .await
        .map_err(|e| format!("open_table '{}' failed: {}", table_path, e))?;

    let arc = Arc::new(table);
    {
        let mut cache = TABLE_CACHE.write().map_err(|e| e.to_string())?;
        cache.insert(key, CachedTable { table: Arc::clone(&arc), inserted: Instant::now() });
    }
    Ok(arc)
}

/// Remove a table from the cache — called after compaction so next
/// access picks up the freshly optimised table.
pub fn invalidate_table_cache(base_path: &str, table_path: &str) {
    let key = format!("{}:{}", base_path, table_path);
    if let Ok(mut cache) = TABLE_CACHE.write() {
        cache.remove(&key);
    }
}

/// Evict all cache entries older than TTL — called by a periodic Oban job.
pub fn evict_expired_cache_entries() {
    if let Ok(mut cache) = TABLE_CACHE.write() {
        cache.retain(|_, entry| entry.inserted.elapsed().as_secs() < CACHE_TTL_SECS);
    }
}

// ─── OCC RETRY ───────────────────────────────────────────────────────────────

const MAX_RETRIES:    u32  = 7;
const BASE_MS:        u64  = 50;
const MAX_MS:         u64  = 5_000;
const MULTIPLIER:     f64  = 2.0;
const JITTER_MS:      u64  = 50;

async fn with_retry<F, Fut, T>(op: F) -> Result<(T, u32), String>
where
    F: Fn() -> Fut,
    Fut: std::future::Future<Output = Result<T, lancedb::Error>>,
{
    let mut attempt = 0u32;
    loop {
        match op().await {
            Ok(v)  => return Ok((v, attempt)),
            Err(e) => {
                let msg = e.to_string().to_lowercase();
                let conflict = msg.contains("conflict") || msg.contains("version");
                if conflict && attempt < MAX_RETRIES {
                    attempt += 1;
                    tokio::time::sleep(Duration::from_millis(backoff_ms(attempt))).await;
                } else {
                    return Err(e.to_string());
                }
            }
        }
    }
}

fn backoff_ms(attempt: u32) -> u64 {
    let base = BASE_MS as f64 * MULTIPLIER.powi(attempt as i32 - 1);
    let cap  = base.min(MAX_MS as f64) as u64;
    cap + jitter()
}

fn jitter() -> u64 {
    use std::collections::hash_map::DefaultHasher;
    use std::hash::{Hash, Hasher};
    let mut h = DefaultHasher::new();
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default()
        .subsec_nanos()
        .hash(&mut h);
    h.finish() % JITTER_MS
}

// ─── WRITE RESULT ────────────────────────────────────────────────────────────

#[derive(Serialize, Deserialize)]
pub struct WriteResult {
    pub record_id:  String,
    pub version:    u64,
    pub attempts:   u32,
    pub latency_us: u64,
}

// ─── GENERIC JSON → RECORD BATCH ─────────────────────────────────────────────
//
// Reads the table's Arrow schema at runtime and converts a JSON object to a
// single-row RecordBatch.  This removes the need for per-table serializers.
//
// Supported Arrow types:
//   Utf8, Int64, Int32, Float32, Float64, Boolean,
//   FixedSizeList<Float32> (embeddings),
//   Large types mapped to their standard equivalents.

fn json_to_batch(
    record: &serde_json::Value,
    schema: &Schema,
) -> Result<RecordBatch, String> {
    let mut columns: Vec<Arc<dyn Array>> = Vec::with_capacity(schema.fields().len());

    for field in schema.fields() {
        let val = record.get(field.name()).unwrap_or(&serde_json::Value::Null);
        let arr = json_val_to_array(val, field.data_type(), field.is_nullable())
            .map_err(|e| format!("field '{}' ({}): {}", field.name(), field.data_type(), e))?;
        columns.push(arr);
    }

    RecordBatch::try_new(Arc::new(schema.clone()), columns).map_err(|e| e.to_string())
}

fn json_val_to_array(
    val:      &serde_json::Value,
    dtype:    &DataType,
    nullable: bool,
) -> Result<Arc<dyn Array>, String> {
    macro_rules! null_or {
        ($expr:expr) => {
            if val.is_null() {
                if nullable { return Ok($expr); }
                else { return Err("NULL on non-nullable field".into()); }
            }
        };
    }

    match dtype {
        // ── String types ───────────────────────────────────────────────────
        DataType::Utf8 | DataType::LargeUtf8 => {
            null_or!(Arc::new(StringArray::from(vec![None::<&str>])));
            let s = match val {
                serde_json::Value::String(s) => s.as_str(),
                serde_json::Value::Number(n) => return Ok(Arc::new(StringArray::from(vec![Some(n.to_string())]))),
                serde_json::Value::Bool(b)   => return Ok(Arc::new(StringArray::from(vec![Some(b.to_string())]))),
                other => return Ok(Arc::new(StringArray::from(vec![Some(other.to_string())]))),
            };
            Ok(Arc::new(StringArray::from(vec![Some(s)])))
        }

        // ── Integer types ─────────────────────────────────────────────────
        DataType::Int64 => {
            null_or!(Arc::new(Int64Array::from(vec![None::<i64>])));
            let n = val.as_i64().ok_or("expected i64")?;
            Ok(Arc::new(Int64Array::from(vec![n])))
        }
        DataType::Int32 => {
            null_or!(Arc::new(Int32Array::from(vec![None::<i32>])));
            let n = val.as_i64().ok_or("expected i32")? as i32;
            Ok(Arc::new(Int32Array::from(vec![n])))
        }

        // ── Float types ───────────────────────────────────────────────────
        DataType::Float32 => {
            null_or!(Arc::new(Float32Array::from(vec![None::<f32>])));
            let f = val.as_f64().ok_or("expected f32")? as f32;
            Ok(Arc::new(Float32Array::from(vec![f])))
        }
        DataType::Float64 => {
            null_or!(Arc::new(arrow_array::Float64Array::from(vec![None::<f64>])));
            let f = val.as_f64().ok_or("expected f64")?;
            Ok(Arc::new(arrow_array::Float64Array::from(vec![f])))
        }

        // ── Boolean ───────────────────────────────────────────────────────
        DataType::Boolean => {
            null_or!(Arc::new(BooleanArray::from(vec![None::<bool>])));
            let b = val.as_bool().ok_or("expected bool")?;
            Ok(Arc::new(BooleanArray::from(vec![b])))
        }

        // ── Embedding (FixedSizeList<Float32>) ────────────────────────────
        DataType::FixedSizeList(item_field, size) => {
            let dim = *size as usize;
            let floats: Vec<f32> = match val {
                serde_json::Value::Array(arr) =>
                    arr.iter().filter_map(|v| v.as_f64().map(|f| f as f32)).collect(),
                _ => vec![],
            };

            // Pad or truncate to exact dimension size
            let mut padded = vec![0.0f32; dim];
            for (i, f) in floats.iter().take(dim).enumerate() { padded[i] = *f; }

            let values_arr = Arc::new(Float32Array::from(padded));
            let fsl = FixedSizeListArray::new(
                Arc::new(Field::new("item", DataType::Float32, false)),
                *size,
                values_arr,
                None,
            );
            Ok(Arc::new(fsl))
        }

        // ── Timestamp ─────────────────────────────────────────────────────
        DataType::Timestamp(_, _) => {
            null_or!(Arc::new(Int64Array::from(vec![None::<i64>])));
            let n = val.as_i64().ok_or("expected timestamp micros")?;
            Ok(Arc::new(Int64Array::from(vec![n])))
        }

        // ── Fallback: encode as JSON string ───────────────────────────────
        _ => {
            let s = match val {
                serde_json::Value::String(s) => Some(s.as_str()),
                serde_json::Value::Null      => None,
                other => return Ok(Arc::new(StringArray::from(vec![Some(other.to_string())]))),
            };
            Ok(Arc::new(StringArray::from(vec![s])))
        }
    }
}

// ─── NIF MACRO ───────────────────────────────────────────────────────────────
// Wraps any Rust panic and returns {:error, "nif_panic"} to Elixir.
// Without this, a Rust panic kills the entire BEAM VM.

macro_rules! safe_nif {
    ($env:expr, $body:block) => {{
        match std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| $body)) {
            Ok(result) => result,
            Err(panic_val) => {
                let msg = if let Some(s) = panic_val.downcast_ref::<&str>() {
                    format!("nif_panic: {}", s)
                } else if let Some(s) = panic_val.downcast_ref::<String>() {
                    format!("nif_panic: {}", s)
                } else {
                    "nif_panic: unknown".to_string()
                };
                err_atom($env, &msg)
            }
        }
    }};
}

// ─── pzdb_upsert ─────────────────────────────────────────────────────────────
//
// The ONLY write primitive for all 27 Lance tables.
// Uses merge_insert: atomic upsert, no delete+insert gap.

#[rustler::nif(schedule = "DirtyIo")]
pub fn pzdb_upsert<'a>(
    env:         Env<'a>,
    base_path:   String,
    table_path:  String,
    record_json: String,
    key_columns: String,  // JSON array, e.g. ["id"]
) -> Term<'a> {
    safe_nif!(env, {
        let record: serde_json::Value = match serde_json::from_str(&record_json) {
            Ok(r)  => r,
            Err(e) => return err_atom(env, &format!("invalid record JSON: {}", e)),
        };
        let keys: Vec<String> = match serde_json::from_str(&key_columns) {
            Ok(k)  => k,
            Err(e) => return err_atom(env, &format!("invalid key_columns JSON: {}", e)),
        };
        let record_id = record["id"].as_str().unwrap_or("").to_string();
        let start     = Instant::now();

        runtime().block_on(async {
            let table = match get_table(&base_path, &table_path).await {
                Ok(t)  => t,
                Err(e) => return err_atom(env, &e),
            };

            // Read schema from the cached table
            let schema = match table.schema().await {
                Ok(s)  => s,
                Err(e) => return err_atom(env, &format!("schema read failed: {}", e)),
            };

            let batch = match json_to_batch(&record, &schema) {
                Ok(b)  => b,
                Err(e) => return err_atom(env, &format!("serialise failed: {}", e)),
            };

            let key_refs: Vec<&str> = keys.iter().map(|s| s.as_str()).collect();

            let result = with_retry(|| {
                let b  = batch.clone();
                let t  = Arc::clone(&table);
                let ks = key_refs.clone();
                async move {
                    t.merge_insert(&ks)
                        .when_matched_update_all(None)
                        .when_not_matched_insert_all()
                        .execute(Box::new(futures::stream::iter(vec![Ok(b)])))
                        .await
                }
            }).await;

            match result {
                Ok((_, attempts)) => {
                    let version   = table.version().await.unwrap_or(0);
                    let latency   = start.elapsed().as_micros() as u64;
                    ok_json(env, &WriteResult { record_id, version, attempts, latency_us: latency })
                }
                Err(e) => err_atom(env, &e),
            }
        })
    })
}

// ─── pzdb_batch_upsert ───────────────────────────────────────────────────────

#[rustler::nif(schedule = "DirtyIo")]
pub fn pzdb_batch_upsert<'a>(
    env:          Env<'a>,
    base_path:    String,
    table_path:   String,
    records_json: String,
    key_columns:  String,
) -> Term<'a> {
    safe_nif!(env, {
        let records: Vec<serde_json::Value> = match serde_json::from_str(&records_json) {
            Ok(r)  => r,
            Err(e) => return err_atom(env, &format!("invalid records JSON: {}", e)),
        };
        let keys: Vec<String> = match serde_json::from_str(&key_columns) {
            Ok(k)  => k,
            Err(e) => return err_atom(env, &format!("invalid key_columns: {}", e)),
        };
        if records.is_empty() {
            return ok_json(env, &serde_json::json!({"count": 0, "version": 0}));
        }
        let start = Instant::now();

        runtime().block_on(async {
            let table = match get_table(&base_path, &table_path).await {
                Ok(t)  => t,
                Err(e) => return err_atom(env, &e),
            };
            let schema = match table.schema().await {
                Ok(s)  => s,
                Err(e) => return err_atom(env, &e.to_string()),
            };

            // Build a combined RecordBatch from all records
            let mut col_builders: Vec<Vec<serde_json::Value>> =
                vec![vec![]; schema.fields().len()];

            for record in &records {
                for (i, field) in schema.fields().iter().enumerate() {
                    col_builders[i].push(
                        record.get(field.name()).cloned().unwrap_or(serde_json::Value::Null)
                    );
                }
            }

            // Build arrays per column
            let mut columns: Vec<Arc<dyn Array>> = Vec::new();
            for (i, field) in schema.fields().iter().enumerate() {
                let arr = build_column_array(&col_builders[i], field.data_type())
                    .map_err(|e| format!("column '{}': {}", field.name(), e));
                match arr {
                    Ok(a)  => columns.push(a),
                    Err(e) => return err_atom(env, &e),
                }
            }

            let batch = match RecordBatch::try_new(Arc::new(schema.as_ref().clone()), columns) {
                Ok(b)  => b,
                Err(e) => return err_atom(env, &e.to_string()),
            };

            let count     = records.len();
            let key_refs: Vec<&str> = keys.iter().map(|s| s.as_str()).collect();

            let result = with_retry(|| {
                let b  = batch.clone();
                let t  = Arc::clone(&table);
                let ks = key_refs.clone();
                async move {
                    t.merge_insert(&ks)
                        .when_matched_update_all(None)
                        .when_not_matched_insert_all()
                        .execute(Box::new(futures::stream::iter(vec![Ok(b)])))
                        .await
                }
            }).await;

            match result {
                Ok((_, _)) => {
                    let version = table.version().await.unwrap_or(0);
                    ok_json(env, &serde_json::json!({
                        "count":      count,
                        "version":    version,
                        "latency_us": start.elapsed().as_micros() as u64,
                    }))
                }
                Err(e) => err_atom(env, &e),
            }
        })
    })
}

// ─── pzdb_read ───────────────────────────────────────────────────────────────

#[rustler::nif(schedule = "DirtyIo")]
pub fn pzdb_read<'a>(
    env:         Env<'a>,
    base_path:   String,
    table_path:  String,
    record_id:   String,
    min_version: i64,
) -> Term<'a> {
    safe_nif!(env, {
        runtime().block_on(async {
            let table = match get_table(&base_path, &table_path).await {
                Ok(t)  => t,
                Err(_) => {
                    return ok_json(env, &serde_json::json!({"record": null, "version": 0, "found": false}));
                }
            };

            if min_version > 0 {
                wait_for_version(&table, min_version as u64).await;
            }

            let safe_id = record_id.replace('\'', "''");
            let batches: Vec<RecordBatch> = match table
                .query()
                .filter(format!("id = '{}'", safe_id))
                .limit(1)
                .execute()
                .await
            {
                Ok(s)  => s.try_collect().await.unwrap_or_default(),
                Err(e) => return err_atom(env, &e.to_string()),
            };

            let version = table.version().await.unwrap_or(0);

            if batches.is_empty() || batches[0].num_rows() == 0 {
                return ok_json(env, &serde_json::json!({"record": null, "version": version, "found": false}));
            }

            match batch_row_to_json(&batches[0], 0) {
                Ok(rec) => ok_json(env, &serde_json::json!({"record": rec, "version": version, "found": true})),
                Err(e)  => err_atom(env, &e),
            }
        })
    })
}

// ─── pzdb_read_many ──────────────────────────────────────────────────────────

#[rustler::nif(schedule = "DirtyIo")]
pub fn pzdb_read_many<'a>(
    env:         Env<'a>,
    base_path:   String,
    table_path:  String,
    filter:      String,
    limit:       u32,
    min_version: i64,
) -> Term<'a> {
    safe_nif!(env, {
        runtime().block_on(async {
            let table = match get_table(&base_path, &table_path).await {
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

            ok_json(env, &serde_json::json!({"records": records, "version": version}))
        })
    })
}

// ─── pzdb_soft_delete ────────────────────────────────────────────────────────

#[rustler::nif(schedule = "DirtyIo")]
pub fn pzdb_soft_delete<'a>(
    env:        Env<'a>,
    base_path:  String,
    table_path: String,
    record_id:  String,
    deleted_by: String,
) -> Term<'a> {
    safe_nif!(env, {
        let now = chrono::Utc::now().timestamp_micros();
        runtime().block_on(async {
            let table  = match get_table(&base_path, &table_path).await {
                Ok(t)  => t,
                Err(e) => return err_atom(env, &e),
            };
            let schema = match table.schema().await {
                Ok(s)  => s,
                Err(e) => return err_atom(env, &e.to_string()),
            };

            let safe_id = record_id.replace('\'', "''");
            let batches: Vec<RecordBatch> = match table
                .query()
                .filter(format!("id = '{}'", safe_id))
                .limit(1)
                .execute().await
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

            if let Some(obj) = record.as_object_mut() {
                obj.insert("deleted_at".into(),  serde_json::json!(now));
                obj.insert("deleted_by".into(),  serde_json::json!(deleted_by));
                obj.insert("updated_at".into(),  serde_json::json!(now));
                obj.entry("version")
                   .and_modify(|v| { if let Some(n) = v.as_i64() { *v = (n+1).into() } });
            }

            let batch = match json_to_batch(&record, &schema) {
                Ok(b)  => b,
                Err(e) => return err_atom(env, &e),
            };

            let result = with_retry(|| {
                let b = batch.clone();
                let t = Arc::clone(&table);
                async move {
                    t.merge_insert(&["id"])
                        .when_matched_update_all(None)
                        .when_not_matched_insert_all()
                        .execute(Box::new(futures::stream::iter(vec![Ok(b)])))
                        .await
                }
            }).await;

            match result {
                Ok(_)  => {
                    let version = table.version().await.unwrap_or(0);
                    ok_json(env, &serde_json::json!({"record_id": record_id, "version": version}))
                }
                Err(e) => err_atom(env, &e),
            }
        })
    })
}

// ─── pzdb_compact ────────────────────────────────────────────────────────────

#[rustler::nif(schedule = "DirtyIo")]
pub fn pzdb_compact<'a>(
    env:        Env<'a>,
    base_path:  String,
    table_path: String,
) -> Term<'a> {
    safe_nif!(env, {
        let start = Instant::now();
        runtime().block_on(async {
            // Invalidate cache before compaction so we get the fresh table
            invalidate_table_cache(&base_path, &table_path);

            let table = match get_table(&base_path, &table_path).await {
                Ok(t)  => t,
                Err(e) => return err_atom(env, &e),
            };
            let rows_before = table.count_rows(None).await.unwrap_or(0);

            match table.optimize(lancedb::table::OptimizeAction::All).execute().await {
                Ok(_) => {
                    // Invalidate cache again — fresh manifest after compaction
                    invalidate_table_cache(&base_path, &table_path);
                    let rows_after = table.count_rows(None).await.unwrap_or(0);
                    ok_json(env, &serde_json::json!({
                        "table_path":       table_path,
                        "rows_before":      rows_before,
                        "rows_after":       rows_after,
                        "duration_ms":      start.elapsed().as_millis() as u64,
                    }))
                }
                Err(e) => err_atom(env, &e.to_string()),
            }
        })
    })
}

// ─── pzdb_version ────────────────────────────────────────────────────────────

#[rustler::nif(schedule = "DirtyIo")]
pub fn pzdb_version<'a>(env: Env<'a>, base_path: String, table_path: String) -> Term<'a> {
    safe_nif!(env, {
        runtime().block_on(async {
            match get_table(&base_path, &table_path).await {
                Ok(t)  => ok_json(env, &t.version().await.unwrap_or(0)),
                Err(_) => ok_json(env, &0u64),
            }
        })
    })
}

// ─── pzdb_provision_table ────────────────────────────────────────────────────

#[rustler::nif(schedule = "DirtyIo")]
pub fn pzdb_provision_table<'a>(
    env:         Env<'a>,
    base_path:   String,
    table_path:  String,
    schema_name: String,
) -> Term<'a> {
    safe_nif!(env, {
        runtime().block_on(async {
            match get_table(&base_path, &table_path).await {
                Ok(_) => ok_json(env, &serde_json::json!({"created": false, "path": table_path})),
                Err(_) => {
                    let conn = match connect(&base_path).execute().await {
                        Ok(c)  => c,
                        Err(e) => return err_atom(env, &e.to_string()),
                    };
                    let schema = match schema_for(&schema_name) {
                        Some(s) => s,
                        None    => return err_atom(env, &format!("unknown schema: {}", schema_name)),
                    };
                    match conn.create_empty_table(&table_path, schema).execute().await {
                        Ok(_)  => ok_json(env, &serde_json::json!({"created": true, "path": table_path})),
                        Err(e) => err_atom(env, &e.to_string()),
                    }
                }
            }
        })
    })
}

// ─── pzdb_cache_evict ────────────────────────────────────────────────────────

#[rustler::nif]
pub fn pzdb_cache_evict<'a>(env: Env<'a>) -> Term<'a> {
    safe_nif!(env, {
        evict_expired_cache_entries();
        atoms::ok().encode(env)
    })
}

// ─── pzdb_cache_invalidate ───────────────────────────────────────────────────

#[rustler::nif]
pub fn pzdb_cache_invalidate<'a>(env: Env<'a>, base_path: String, table_path: String) -> Term<'a> {
    safe_nif!(env, {
        invalidate_table_cache(&base_path, &table_path);
        atoms::ok().encode(env)
    })
}

// ─── HELPERS ─────────────────────────────────────────────────────────────────

async fn wait_for_version(table: &Table, min_v: u64) {
    let deadline = tokio::time::Instant::now() + Duration::from_secs(2);
    loop {
        let cur = table.version().await.unwrap_or(0);
        if cur >= min_v || tokio::time::Instant::now() >= deadline { break; }
        tokio::time::sleep(Duration::from_millis(20)).await;
    }
}

fn batch_row_to_json(batch: &RecordBatch, row: usize) -> Result<serde_json::Value, String> {
    let mut map = serde_json::Map::new();
    for (i, field) in batch.schema().fields().iter().enumerate() {
        let col = batch.column(i);
        let val = if col.is_null(row) {
            serde_json::Value::Null
        } else if let Some(a) = col.as_any().downcast_ref::<StringArray>() {
            serde_json::Value::String(a.value(row).to_string())
        } else if let Some(a) = col.as_any().downcast_ref::<Int64Array>() {
            serde_json::Value::Number(a.value(row).into())
        } else if let Some(a) = col.as_any().downcast_ref::<Int32Array>() {
            serde_json::Value::Number(a.value(row).into())
        } else if let Some(a) = col.as_any().downcast_ref::<Float32Array>() {
            serde_json::json!(a.value(row))
        } else if let Some(a) = col.as_any().downcast_ref::<BooleanArray>() {
            serde_json::Value::Bool(a.value(row))
        } else if let Some(a) = col.as_any().downcast_ref::<FixedSizeListArray>() {
            let vals = a.value(row);
            if let Some(fa) = vals.as_any().downcast_ref::<Float32Array>() {
                let floats: Vec<f64> = (0..fa.len()).map(|i| fa.value(i) as f64).collect();
                serde_json::to_value(floats).unwrap_or(serde_json::Value::Null)
            } else {
                serde_json::Value::Null
            }
        } else {
            serde_json::Value::Null
        };
        map.insert(field.name().clone(), val);
    }
    Ok(serde_json::Value::Object(map))
}

/// Build a single Arrow array from a column of JSON values (for batch writes)
fn build_column_array(
    values: &[serde_json::Value],
    dtype:  &DataType,
) -> Result<Arc<dyn Array>, String> {
    match dtype {
        DataType::Utf8 | DataType::LargeUtf8 => {
            let strs: Vec<Option<String>> = values.iter().map(|v| {
                match v {
                    serde_json::Value::String(s) => Some(s.clone()),
                    serde_json::Value::Null      => None,
                    other                        => Some(other.to_string()),
                }
            }).collect();
            Ok(Arc::new(StringArray::from(strs.iter().map(|s| s.as_deref()).collect::<Vec<_>>())))
        }
        DataType::Int64 => {
            let ns: Vec<Option<i64>> = values.iter()
                .map(|v| v.as_i64()).collect();
            Ok(Arc::new(Int64Array::from(ns)))
        }
        DataType::Int32 => {
            let ns: Vec<Option<i32>> = values.iter()
                .map(|v| v.as_i64().map(|n| n as i32)).collect();
            Ok(Arc::new(Int32Array::from(ns)))
        }
        DataType::Float32 => {
            let fs: Vec<Option<f32>> = values.iter()
                .map(|v| v.as_f64().map(|f| f as f32)).collect();
            Ok(Arc::new(Float32Array::from(fs)))
        }
        DataType::Boolean => {
            let bs: Vec<Option<bool>> = values.iter()
                .map(|v| v.as_bool()).collect();
            Ok(Arc::new(BooleanArray::from(bs)))
        }
        DataType::FixedSizeList(_, size) => {
            let dim = *size as usize;
            let mut all_floats: Vec<f32> = Vec::with_capacity(values.len() * dim);
            for v in values {
                let floats: Vec<f32> = match v {
                    serde_json::Value::Array(arr) =>
                        arr.iter().filter_map(|x| x.as_f64().map(|f| f as f32)).collect(),
                    _ => vec![],
                };
                let mut padded = vec![0.0f32; dim];
                for (i, f) in floats.iter().take(dim).enumerate() { padded[i] = *f; }
                all_floats.extend(padded);
            }
            let values_arr = Arc::new(Float32Array::from(all_floats));
            Ok(Arc::new(FixedSizeListArray::new(
                Arc::new(Field::new("item", DataType::Float32, false)),
                *size,
                values_arr,
                None,
            )))
        }
        _ => build_column_array(values, &DataType::Utf8),
    }
}

fn schema_for(name: &str) -> Option<Arc<Schema>> {
    // Import schemas from service crates as they are built
    // For now, return None — tables must be provisioned via their service initializers
    None
}
