use rustler::{Atom, Error as NifError, NifResult};
use tokio::runtime::Runtime;

mod atoms {
    rustler::atoms! { ok, error }
}

fn rt() -> Runtime {
    Runtime::new().expect("tokio runtime")
}

#[rustler::nif(schedule = "DirtyIo")]
fn pzdb_upsert(
    base_path: String,
    table_path: String,
    record_json: String,
    _merge_keys: Vec<String>,
) -> NifResult<String> {
    rt().block_on(async move {
        let record: serde_json::Value = serde_json::from_str(&record_json)
            .map_err(|e| NifError::Term(Box::new(e.to_string())))?;
        Ok(serde_json::json!({"status": "ok", "table": table_path, "record": record}).to_string())
    })
}

#[rustler::nif(schedule = "DirtyIo")]
fn pzdb_batch_upsert(
    base_path: String,
    table_path: String,
    records_json: String,
    _merge_keys: Vec<String>,
) -> NifResult<String> {
    rt().block_on(async move {
        let records: Vec<serde_json::Value> = serde_json::from_str(&records_json)
            .map_err(|e| NifError::Term(Box::new(e.to_string())))?;
        Ok(serde_json::json!({"status": "ok", "count": records.len()}).to_string())
    })
}

#[rustler::nif(schedule = "DirtyIo")]
fn pzdb_query(
    base_path: String,
    table_path: String,
    filter_json: String,
) -> NifResult<String> {
    rt().block_on(async move {
        Ok(serde_json::json!({"status": "ok", "rows": []}).to_string())
    })
}

#[rustler::nif(schedule = "DirtyIo")]
fn pzdb_read_many(
    base_path: String,
    table_path: String,
    filter_json: String,
    limit: u64,
    offset: u64,
) -> NifResult<String> {
    rt().block_on(async move {
        Ok(serde_json::json!({"status": "ok", "rows": [], "total": 0}).to_string())
    })
}

#[rustler::nif(schedule = "DirtyIo")]
fn pzdb_provision_table(
    base_path: String,
    table_path: String,
    schema_name: String,
) -> NifResult<String> {
    rt().block_on(async move {
        Ok(serde_json::json!({"status": "ok", "table": table_path, "schema": schema_name}).to_string())
    })
}

#[rustler::nif(schedule = "DirtyIo")]
fn pzdb_delete(
    base_path: String,
    table_path: String,
    filter_json: String,
) -> NifResult<String> {
    rt().block_on(async move {
        Ok(serde_json::json!({"status": "ok"}).to_string())
    })
}

#[rustler::nif(schedule = "DirtyIo")]
fn cas_put(
    base_path: String,
    did: String,
    data: Vec<u8>,
    mime_type: String,
    written_by: String,
) -> NifResult<String> {
    let hash = blake3::hash(&data).to_hex().to_string();
    Ok(serde_json::json!({"hash": hash, "status": "ok"}).to_string())
}

#[rustler::nif(schedule = "DirtyIo")]
fn cas_get(
    base_path: String,
    did: String,
    hash: String,
) -> NifResult<Vec<u8>> {
    Ok(vec![])
}

rustler::init!(
    "Elixir.PRZMA.PzDb.NIF",
    [pzdb_upsert, pzdb_batch_upsert, pzdb_query, pzdb_read_many, pzdb_provision_table, pzdb_delete, cas_put, cas_get]
);
