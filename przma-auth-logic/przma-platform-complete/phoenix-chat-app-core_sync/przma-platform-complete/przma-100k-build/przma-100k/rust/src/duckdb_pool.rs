// rust/src/duckdb_pool.rs
//
// DuckDB connection pool — 20 pre-warmed in-memory DuckDB connections,
// each with the lance extension loaded at startup.
//
// Before: every analytics NIF call opened a new DuckDB connection (~150ms, ~150MB RAM).
// After:  one pool of 20 connections shared across all analytics requests (~0ms cold start).
//
// Routing: each DID consistently routes to the same connection via hash.
// This keeps query patterns coherent and avoids cross-connection contention
// (DuckDB allows one writer and many readers per connection).

use duckdb::{Connection, Result as DuckResult};
use std::sync::{Arc, LazyLock, Mutex};

const POOL_SIZE: usize = 20;

struct Pool {
    conns: Vec<Arc<Mutex<Connection>>>,
}

impl Pool {
    fn new() -> DuckResult<Self> {
        let mut conns = Vec::with_capacity(POOL_SIZE);
        for _ in 0..POOL_SIZE {
            let conn = Connection::open_in_memory()?;
            // Load lance extension once per connection at pool init
            // This is the expensive step — we pay it once, not per query
            conn.execute_batch("INSTALL lance; LOAD lance;")?;
            conns.push(Arc::new(Mutex::new(conn)));
        }
        Ok(Pool { conns })
    }

    fn get_for_did(&self, did: &str) -> Arc<Mutex<Connection>> {
        // Consistent routing: same DID always goes to the same connection.
        // This prevents two threads from holding the same connection's lock simultaneously
        // for the same DID (since DID writes are serialised by WriterPool).
        let idx = did_to_idx(did, POOL_SIZE);
        Arc::clone(&self.conns[idx])
    }

    fn get_round_robin(&self, call_count: u64) -> Arc<Mutex<Connection>> {
        let idx = (call_count as usize) % POOL_SIZE;
        Arc::clone(&self.conns[idx])
    }
}

static POOL: LazyLock<Result<Pool, String>> = LazyLock::new(|| {
    Pool::new().map_err(|e| e.to_string())
});

fn did_to_idx(did: &str, size: usize) -> usize {
    did.bytes().fold(0usize, |acc, b| acc.wrapping_add(b as usize)) % size
}

/// Execute a DuckDB query using the connection assigned to this DID.
/// Returns the result rows as a JSON array of arrays.
pub fn query_for_did(did: &str, sql: &str) -> Result<Vec<Vec<serde_json::Value>>, String> {
    let pool = POOL.as_ref().map_err(|e| e.clone())?;
    let conn_arc = pool.get_for_did(did);
    let conn = conn_arc.lock().map_err(|e| e.to_string())?;
    execute_query(&conn, sql)
}

/// Execute a DuckDB query on any available connection (for non-DID-scoped queries).
pub fn query_any(sql: &str) -> Result<Vec<Vec<serde_json::Value>>, String> {
    static COUNTER: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);
    let count = COUNTER.fetch_add(1, std::sync::atomic::Ordering::Relaxed);

    let pool = POOL.as_ref().map_err(|e| e.clone())?;
    let conn_arc = pool.get_round_robin(count);
    let conn = conn_arc.lock().map_err(|e| e.to_string())?;
    execute_query(&conn, sql)
}

fn execute_query(conn: &Connection, sql: &str) -> Result<Vec<Vec<serde_json::Value>>, String> {
    let mut stmt = conn.prepare(sql).map_err(|e| e.to_string())?;

    let column_count = stmt.column_count();
    let mut rows_result = stmt.query([]).map_err(|e| e.to_string())?;
    let mut rows = Vec::new();

    while let Some(row) = rows_result.next().map_err(|e| e.to_string())? {
        let mut row_vals = Vec::with_capacity(column_count);
        for i in 0..column_count {
            let val: serde_json::Value = match row.get_ref(i).map_err(|e| e.to_string())? {
                duckdb::types::ValueRef::Null => serde_json::Value::Null,
                duckdb::types::ValueRef::Boolean(b) => serde_json::Value::Bool(b),
                duckdb::types::ValueRef::TinyInt(n)  => serde_json::json!(n),
                duckdb::types::ValueRef::SmallInt(n) => serde_json::json!(n),
                duckdb::types::ValueRef::Int(n)      => serde_json::json!(n),
                duckdb::types::ValueRef::BigInt(n)   => serde_json::json!(n),
                duckdb::types::ValueRef::Float(f)    => serde_json::json!(f),
                duckdb::types::ValueRef::Double(f)   => serde_json::json!(f),
                duckdb::types::ValueRef::Text(s)     => serde_json::Value::String(
                    std::str::from_utf8(s).unwrap_or("").to_string()
                ),
                _ => serde_json::Value::Null,
            };
            row_vals.push(val);
        }
        rows.push(row_vals);
    }
    Ok(rows)
}

/// Pool health check — verifies all connections are alive
pub fn health_check() -> Result<usize, String> {
    let pool = POOL.as_ref().map_err(|e| e.clone())?;
    let alive = pool.conns.iter().filter(|c| {
        c.lock().map(|conn| conn.execute_batch("SELECT 1").is_ok()).unwrap_or(false)
    }).count();
    Ok(alive)
}

// ─── NIF WRAPPERS ─────────────────────────────────────────────────────────────

use rustler::{Encoder, Env, Term};
use crate::{atoms, err_atom, ok_json};

#[rustler::nif(schedule = "DirtyCpu")]
pub fn duckdb_query_for_did<'a>(env: Env<'a>, did: String, sql: String) -> Term<'a> {
    match std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
        query_for_did(&did, &sql)
    })) {
        Ok(Ok(rows))  => ok_json(env, &rows),
        Ok(Err(e))    => err_atom(env, &e),
        Err(_)        => err_atom(env, "duckdb_pool_panic"),
    }
}

#[rustler::nif(schedule = "DirtyCpu")]
pub fn duckdb_pool_health<'a>(env: Env<'a>) -> Term<'a> {
    match health_check() {
        Ok(n)  => ok_json(env, &serde_json::json!({"alive": n, "total": POOL_SIZE})),
        Err(e) => err_atom(env, &e),
    }
}
