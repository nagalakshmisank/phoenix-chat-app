// native/przma_pzdb_nif/src/lib.rs
//
// Real LanceDB-backed NIF for PRZMA.PzDb.NIF.
//
// pzdb_provision_table / pzdb_upsert / pzdb_read_many do genuine Lance writes/reads
// against the `files` schema, producing  {dir}/files.lance/  where
//   dir = {root}/{sanitized_did}/files/{space}   (resolved by Namespace in Elixir)
// The other 5 functions stay as stubs ONLY so the module loads — every #[rustler::nif]
// here must match a `def` of the same name+arity in lib/przma/pzdb/nif.ex.
//
// Modeled line-for-line on the proven przma-files/src/store.rs (lancedb 0.9,
// arrow 52.2.0). NOT compiled in the assistant's sandbox — build it in your
// container. If `mix compile` dies inside the `lance` crate with a type-recursion
// overflow, bump lancedb to "0.10" and arrow-* to "53" (the connect/open_table/
// add/query API used here is unchanged across 0.9 -> 0.10).
//
// S3: lancedb reads AWS_ENDPOINT / AWS_DEFAULT_REGION / AWS_ACCESS_KEY_ID /
// AWS_SECRET_ACCESS_KEY from the OS env. Export them before `mix phx.server`.

use std::sync::{Arc, OnceLock};

use rustler::{Error as NifError, NifResult};
use serde_json::{json, Value};
use tokio::runtime::Runtime;

use arrow_array::{
    BooleanArray, FixedSizeListArray, Float32Array, Int32Array, Int64Array,
    RecordBatch, RecordBatchIterator, StringArray,
};
use arrow_schema::{DataType, Field, Fields, Schema};
use futures::TryStreamExt;
use lancedb::connect;
use lancedb::query::{ExecutableQuery, QueryBase};
use lancedb::Table;

const EMBEDDING_DIM: i32 = 768;

// One shared multi-thread runtime for all NIF calls (do NOT build one per call).
fn rt() -> &'static Runtime {
    static RT: OnceLock<Runtime> = OnceLock::new();
    RT.get_or_init(|| {
        tokio::runtime::Builder::new_multi_thread()
            .enable_all()
            .build()
            .expect("tokio runtime")
    })
}

fn err<E: std::fmt::Display>(e: E) -> NifError {
    NifError::Term(Box::new(e.to_string()))
}

fn now_micros() -> u128 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_micros())
        .unwrap_or(0)
}

// Canonical 22-column files schema (identical to schema.rs `local_file_schema`).
fn files_schema() -> Arc<Schema> {
    Arc::new(Schema::new(Fields::from(vec![
        Field::new("id", DataType::Utf8, false),
        Field::new("did", DataType::Utf8, false),
        Field::new("space", DataType::Utf8, false),
        Field::new("name", DataType::Utf8, false),
        Field::new("path", DataType::Utf8, false),
        Field::new("mime_type", DataType::Utf8, false),
        Field::new("size_bytes", DataType::Int64, false),
        Field::new("content_cas", DataType::Utf8, false),
        Field::new("thumbnail_cas", DataType::Utf8, true),
        Field::new("versions_json", DataType::Utf8, false),
        Field::new("current_version", DataType::Int32, false),
        Field::new("tags_json", DataType::Utf8, false),
        Field::new("source_uri", DataType::Utf8, true),
        Field::new(
            "embedding",
            DataType::FixedSizeList(
                Arc::new(Field::new("item", DataType::Float32, false)),
                EMBEDDING_DIM,
            ),
            false,
        ),
        Field::new("is_public", DataType::Boolean, false),
        Field::new("is_encrypted", DataType::Boolean, false),
        Field::new("upload_status", DataType::Utf8, false),
        Field::new("chunk_count", DataType::Int32, true),
        Field::new("chunks_received", DataType::Int32, true),
        Field::new("created_at", DataType::Int64, false),
        Field::new("updated_at", DataType::Int64, false),
        Field::new("synced", DataType::Boolean, false),
    ])))
}

// Insert after files_schema() — additive
fn activity_schema() -> Arc<Schema> {
    Arc::new(Schema::new(Fields::from(vec![
        Field::new("id",            DataType::Utf8,  false),
        Field::new("owner_did",     DataType::Utf8,  false),
        Field::new("actor",         DataType::Utf8,  false),
        Field::new("activity_type", DataType::Utf8,  false),
        Field::new("space",         DataType::Utf8,  false),
        Field::new("object_id",     DataType::Utf8,  true),
        Field::new("object_cas",    DataType::Utf8,  true),
        Field::new("object_name",   DataType::Utf8,  true),
        Field::new("to_json",       DataType::Utf8,  false),
        Field::new("raw_json",      DataType::Utf8,  false),
        Field::new("status",        DataType::Utf8,  false),
        Field::new("created_at",    DataType::Int64, false),
        Field::new("saved_file_id", DataType::Utf8,  true),
    ])))
}

// CAS metadata index. One row per unique blob hash; ref_count tracks how many
// file records reference the blob (dedup + GC). Persists to cas_meta.lance.
fn cas_meta_schema() -> Arc<Schema> {
    Arc::new(Schema::new(Fields::from(vec![
        Field::new("id",         DataType::Utf8,  false),
        Field::new("hash",       DataType::Utf8,  false),
        Field::new("cas_uri",    DataType::Utf8,  false),
        Field::new("uri",        DataType::Utf8,  true),
        Field::new("uri_type",   DataType::Utf8,  true),
        Field::new("s3_uri",     DataType::Utf8,  true),
        Field::new("space",      DataType::Utf8,  false),
        Field::new("did",        DataType::Utf8,  false),
        Field::new("ref_count",  DataType::Int64, false),
        Field::new("size_bytes", DataType::Int64, false),
        Field::new("created_at", DataType::Int64, false),
        Field::new("updated_at", DataType::Int64, false),
    ])))
}

// One profile row per DID. Folds OTP + password-reset fields into the same
// row (same shape as Postgres `users` did) since there's only ever one
// profile per DID. Persists to auth.lance.
fn auth_schema() -> Arc<Schema> {
    Arc::new(Schema::new(Fields::from(vec![
        Field::new("id",                     DataType::Utf8,    false), // = did
        Field::new("did",                    DataType::Utf8,    false),
        Field::new("nickname",               DataType::Utf8,    false),
        Field::new("email",                  DataType::Utf8,    true),
        Field::new("name",                   DataType::Utf8,    true),
        Field::new("bio",                    DataType::Utf8,    true),
        Field::new("avatar",                 DataType::Utf8,    true),
        Field::new("password_hash",          DataType::Utf8,    false),
        Field::new("is_active",              DataType::Boolean, false),
        Field::new("is_admin",               DataType::Boolean, false),
        Field::new("is_moderator",           DataType::Boolean, false),
        Field::new("is_verified",            DataType::Boolean, false),
        Field::new("otp_code",               DataType::Utf8,    true),
        Field::new("otp_expires_at",         DataType::Int64,   true),
        Field::new("otp_attempts",           DataType::Int32,   false),
        Field::new("reset_token",            DataType::Utf8,    true),
        Field::new("reset_token_expires_at", DataType::Int64,   true),
        Field::new("reset_token_attempts",   DataType::Int32,   false),
        Field::new("created_at",             DataType::Int64,   false),
        Field::new("updated_at",             DataType::Int64,   false),
    ])))
}

// One row per login. Only needed for revoke/logout — never on the read path
// that verifies a request (that's pure Phoenix.Token math). Persists to
// sessions.lance.
fn sessions_schema() -> Arc<Schema> {
    Arc::new(Schema::new(Fields::from(vec![
        Field::new("id",             DataType::Utf8,    false), // session id
        Field::new("did",            DataType::Utf8,    false),
        Field::new("device",         DataType::Utf8,    true),
        Field::new("ip_address",     DataType::Utf8,    true),
        Field::new("user_agent",     DataType::Utf8,    true),
        Field::new("issued_at",      DataType::Int64,   false),
        Field::new("last_active_at", DataType::Int64,   true),
        Field::new("revoked_at",     DataType::Int64,   true),
    ])))
}

fn json_to_auth_batch(v: &Value) -> NifResult<RecordBatch> {
    let s    = |k: &str| v.get(k).and_then(Value::as_str).unwrap_or("").to_string();
    let so   = |k: &str| v.get(k).and_then(Value::as_str).map(str::to_string);
    let b    = |k: &str| v.get(k).and_then(Value::as_bool).unwrap_or(false);
    let i64o = |k: &str| v.get(k).and_then(Value::as_i64);
    let i64v = |k: &str| v.get(k).and_then(Value::as_i64).unwrap_or(0);
    let i32v = |k: &str| v.get(k).and_then(Value::as_i64).map(|n| n as i32).unwrap_or(0);

    RecordBatch::try_new(
        auth_schema(),
        vec![
            Arc::new(StringArray::from(vec![s("id")])),
            Arc::new(StringArray::from(vec![s("did")])),
            Arc::new(StringArray::from(vec![s("nickname")])),
            Arc::new(StringArray::from(vec![so("email")])),
            Arc::new(StringArray::from(vec![so("name")])),
            Arc::new(StringArray::from(vec![so("bio")])),
            Arc::new(StringArray::from(vec![so("avatar")])),
            Arc::new(StringArray::from(vec![s("password_hash")])),
            Arc::new(BooleanArray::from(vec![b("is_active")])),
            Arc::new(BooleanArray::from(vec![b("is_admin")])),
            Arc::new(BooleanArray::from(vec![b("is_moderator")])),
            Arc::new(BooleanArray::from(vec![b("is_verified")])),
            Arc::new(StringArray::from(vec![so("otp_code")])),
            Arc::new(Int64Array::from(vec![i64o("otp_expires_at")])),
            Arc::new(Int32Array::from(vec![i32v("otp_attempts")])),
            Arc::new(StringArray::from(vec![so("reset_token")])),
            Arc::new(Int64Array::from(vec![i64o("reset_token_expires_at")])),
            Arc::new(Int32Array::from(vec![i32v("reset_token_attempts")])),
            Arc::new(Int64Array::from(vec![i64v("created_at")])),
            Arc::new(Int64Array::from(vec![i64v("updated_at")])),
        ],
    )
    .map_err(err)
}

fn json_to_sessions_batch(v: &Value) -> NifResult<RecordBatch> {
    let s    = |k: &str| v.get(k).and_then(Value::as_str).unwrap_or("").to_string();
    let so   = |k: &str| v.get(k).and_then(Value::as_str).map(str::to_string);
    let i64o = |k: &str| v.get(k).and_then(Value::as_i64);
    let i64v = |k: &str| v.get(k).and_then(Value::as_i64).unwrap_or(0);

    RecordBatch::try_new(
        sessions_schema(),
        vec![
            Arc::new(StringArray::from(vec![s("id")])),
            Arc::new(StringArray::from(vec![s("did")])),
            Arc::new(StringArray::from(vec![so("device")])),
            Arc::new(StringArray::from(vec![so("ip_address")])),
            Arc::new(StringArray::from(vec![so("user_agent")])),
            Arc::new(Int64Array::from(vec![i64v("issued_at")])),
            Arc::new(Int64Array::from(vec![i64o("last_active_at")])),
            Arc::new(Int64Array::from(vec![i64o("revoked_at")])),
        ],
    )
    .map_err(err)
}

fn json_to_cas_meta_batch(v: &Value) -> NifResult<RecordBatch> {
    let s    = |k: &str| v.get(k).and_then(Value::as_str).unwrap_or("").to_string();
    let so   = |k: &str| v.get(k).and_then(Value::as_str).map(str::to_string);
    let i64v = |k: &str| v.get(k).and_then(Value::as_i64).unwrap_or(0);
    RecordBatch::try_new(
        cas_meta_schema(),
        vec![
            Arc::new(StringArray::from(vec![s("id")])),
            Arc::new(StringArray::from(vec![s("hash")])),
            Arc::new(StringArray::from(vec![s("cas_uri")])),
            Arc::new(StringArray::from(vec![so("uri")])),
            Arc::new(StringArray::from(vec![so("uri_type")])),
            Arc::new(StringArray::from(vec![so("s3_uri")])),
            Arc::new(StringArray::from(vec![s("space")])),
            Arc::new(StringArray::from(vec![s("did")])),
            Arc::new(Int64Array::from(vec![i64v("ref_count")])),
            Arc::new(Int64Array::from(vec![i64v("size_bytes")])),
            Arc::new(Int64Array::from(vec![i64v("created_at")])),
            Arc::new(Int64Array::from(vec![i64v("updated_at")])),
        ],
    )
    .map_err(err)
}

fn schema_for(table: &str) -> Arc<Schema> {
    match table {
        "outbox" | "inbox" => activity_schema(),
        "cas_meta" => cas_meta_schema(),
        "auth" => auth_schema(),
        "sessions" => sessions_schema(),
        _ => files_schema(),   // existing, untouched
    }
}

fn json_to_activity_batch(v: &Value) -> NifResult<RecordBatch> {
    let s  = |k: &str| v.get(k).and_then(Value::as_str).unwrap_or("").to_string();
    let so = |k: &str| v.get(k).and_then(Value::as_str).map(str::to_string);
    let i64v = |k: &str| v.get(k).and_then(Value::as_i64).unwrap_or(0);
    RecordBatch::try_new(
        activity_schema(),
        vec![
            Arc::new(StringArray::from(vec![s("id")])),
            Arc::new(StringArray::from(vec![s("owner_did")])),
            Arc::new(StringArray::from(vec![s("actor")])),
            Arc::new(StringArray::from(vec![s("activity_type")])),
            Arc::new(StringArray::from(vec![s("space")])),
            Arc::new(StringArray::from(vec![so("object_id")])),
            Arc::new(StringArray::from(vec![so("object_cas")])),
            Arc::new(StringArray::from(vec![so("object_name")])),
            Arc::new(StringArray::from(vec![s("to_json")])),
            Arc::new(StringArray::from(vec![s("raw_json")])),
            Arc::new(StringArray::from(vec![s("status")])),
            Arc::new(Int64Array::from(vec![i64v("created_at")])),
            Arc::new(StringArray::from(vec![so("saved_file_id")])),
        ],
    ).map_err(err)
}

async fn open_or_create(dir: &str, table: &str) -> NifResult<Table> {
    let conn = connect(dir).execute().await.map_err(err)?;
    match conn.open_table(table).execute().await {
        Ok(t) => Ok(t),
        Err(_) => conn
            .create_empty_table(table, schema_for(table))
            .execute()
            .await
            .map_err(err),
    }
}

// Build a single-row RecordBatch from the JSON the Elixir side sends.
// (PzDb.backfill guarantees all non-nullable fields are present.)
fn json_to_files_batch(v: &Value) -> NifResult<RecordBatch> {
    let s = |k: &str| v.get(k).and_then(Value::as_str).unwrap_or("").to_string();
    let so = |k: &str| v.get(k).and_then(Value::as_str).map(|x| x.to_string());
    let i64v = |k: &str| v.get(k).and_then(Value::as_i64).unwrap_or(0);
    let i32d = |k: &str, d: i32| v.get(k).and_then(Value::as_i64).map(|n| n as i32).unwrap_or(d);
    let i32o = |k: &str| v.get(k).and_then(Value::as_i64).map(|n| n as i32);
    let b = |k: &str| v.get(k).and_then(Value::as_bool).unwrap_or(false);

    let mut emb: Vec<f32> = v
        .get("embedding")
        .and_then(Value::as_array)
        .map(|a| a.iter().map(|n| n.as_f64().unwrap_or(0.0) as f32).collect())
        .unwrap_or_default();
    emb.resize(EMBEDDING_DIM as usize, 0.0);
    let emb_array = FixedSizeListArray::try_new(
        Arc::new(Field::new("item", DataType::Float32, false)),
        EMBEDDING_DIM,
        Arc::new(Float32Array::from(emb)),
        None,
    )
    .map_err(err)?;

    RecordBatch::try_new(
        files_schema(),
        vec![
            Arc::new(StringArray::from(vec![s("id")])),
            Arc::new(StringArray::from(vec![s("did")])),
            Arc::new(StringArray::from(vec![s("space")])),
            Arc::new(StringArray::from(vec![s("name")])),
            Arc::new(StringArray::from(vec![s("path")])),
            Arc::new(StringArray::from(vec![s("mime_type")])),
            Arc::new(Int64Array::from(vec![i64v("size_bytes")])),
            Arc::new(StringArray::from(vec![s("content_cas")])),
            Arc::new(StringArray::from(vec![so("thumbnail_cas")])),
            Arc::new(StringArray::from(vec![s("versions_json")])),
            Arc::new(Int32Array::from(vec![i32d("current_version", 1)])),
            Arc::new(StringArray::from(vec![s("tags_json")])),
            Arc::new(StringArray::from(vec![so("source_uri")])),
            Arc::new(emb_array),
            Arc::new(BooleanArray::from(vec![b("is_public")])),
            Arc::new(BooleanArray::from(vec![b("is_encrypted")])),
            Arc::new(StringArray::from(vec![s("upload_status")])),
            Arc::new(Int32Array::from(vec![i32o("chunk_count")])),
            Arc::new(Int32Array::from(vec![i32o("chunks_received")])),
            Arc::new(Int64Array::from(vec![i64v("created_at")])),
            Arc::new(Int64Array::from(vec![i64v("updated_at")])),
            Arc::new(BooleanArray::from(vec![b("synced")])),
        ],
    )
    .map_err(err)
}

fn batches_to_json(batches: &[RecordBatch]) -> Vec<Value> {
    let mut buf = Vec::new();
    {
        let mut writer = arrow_json::ArrayWriter::new(&mut buf);
        for batch in batches {
            let _ = writer.write(batch);
        }
        let _ = writer.finish();
    }
    serde_json::from_slice::<Vec<Value>>(&buf).unwrap_or_default()
}

// Escape single quotes for the SQL-ish filter LanceDB uses.
fn sql_quote(s: &str) -> String {
    s.replace('\'', "''")
}

// ── REAL NIFs ────────────────────────────────────────────────────────────────

#[rustler::nif(schedule = "DirtyIo")]
fn pzdb_provision_table(
    base_path: String,
    table_path: String,
    _schema_name: String,
) -> NifResult<String> {
    rt().block_on(async move {
        let _ = open_or_create(&base_path, &table_path).await?;
        Ok(json!({"status": "ok", "table": table_path}).to_string())
    })
}

#[rustler::nif(schedule = "DirtyIo")]
fn pzdb_upsert(
    base_path: String,
    table_path: String,
    record_json: String,
    _merge_keys: String, // caller passes "id" (a plain string, not a list)
) -> NifResult<String> {
    rt().block_on(async move {
        let v: Value = serde_json::from_str(&record_json).map_err(err)?;
        let table = open_or_create(&base_path, &table_path).await?;

        let id = v.get("id").and_then(Value::as_str).unwrap_or("");
        // idempotent upsert: remove any existing row with this id, then add
        let _ = table.delete(&format!("id = '{}'", sql_quote(id))).await;

        let batch = match table_path.as_str() {
            "outbox" | "inbox" => json_to_activity_batch(&v)?,
            "cas_meta"         => json_to_cas_meta_batch(&v)?,
            "auth"             => json_to_auth_batch(&v)?,
            "sessions"         => json_to_sessions_batch(&v)?,
            _                  => json_to_files_batch(&v)?,
            
        };
        let reader = RecordBatchIterator::new(vec![Ok(batch)], schema_for(&table_path));
        table.add(reader).execute().await.map_err(err)?;

        Ok(json!({"status": "ok", "id": id, "version": now_micros()}).to_string())
    })
}

#[rustler::nif(schedule = "DirtyIo")]
fn pzdb_read_many(
    base_path: String,
    table_path: String,
    filter: String,
    limit: u64,
    _offset: u64,
) -> NifResult<String> {
    rt().block_on(async move {
        let conn = connect(&base_path).execute().await.map_err(err)?;
        // Missing table => empty result (not an error).
        let table = match conn.open_table(&table_path).execute().await {
            Ok(t) => t,
            Err(_) => return Ok(json!({"status": "ok", "records": [], "total": 0}).to_string()),
        };

        let mut q = table.query().limit(limit as usize);
        if !filter.trim().is_empty() {
            q = q.only_if(filter);
        }
        let batches: Vec<RecordBatch> =
            q.execute().await.map_err(err)?.try_collect().await.map_err(err)?;

        let records = batches_to_json(&batches);
        let total = records.len();
        Ok(json!({"status": "ok", "records": records, "total": total}).to_string())
    })
}

// ── STUBS (present only to satisfy the nif.ex contract; not on the upload path) ─

#[rustler::nif(schedule = "DirtyIo")]
fn pzdb_batch_upsert(
    _base_path: String,
    _table_path: String,
    records_json: String,
    _merge_keys: String,
) -> NifResult<String> {
    let records: Vec<Value> = serde_json::from_str(&records_json).map_err(err)?;
    Ok(json!({"status": "ok", "count": records.len()}).to_string())
}

#[rustler::nif(schedule = "DirtyIo")]
fn pzdb_read(_base_path: String, _table_path: String, _record_id: String) -> NifResult<String> {
    Ok(json!({"status": "ok", "record": null}).to_string())
}

#[rustler::nif(schedule = "DirtyIo")]
fn pzdb_soft_delete(
    _base_path: String,
    _table_path: String,
    _record_id: String,
    _deleted_by: String,
) -> NifResult<String> {
    Ok(json!({"status": "ok"}).to_string())
}

#[rustler::nif(schedule = "DirtyIo")]
fn pzdb_version(_base_path: String, _table_path: String) -> NifResult<String> {
    Ok(json!({"status": "ok", "version": 1}).to_string())
}

#[rustler::nif(schedule = "DirtyIo")]
fn pzdb_cache_invalidate(_base_path: String, _table_path: String) -> NifResult<String> {
    Ok(json!({"status": "ok"}).to_string())
}

rustler::init!("Elixir.PRZMA.PzDb.NIF");
