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
            // Lance futures are very deep; give worker threads a big stack.
            .thread_stack_size(16 * 1024 * 1024)
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
        Field::new("user_type",     DataType::Utf8,  false),  // NEW — "person" | "agent"
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
        Field::new("is_private",             DataType::Boolean, false), // NEW — default true
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
            Arc::new(BooleanArray::from(vec![{
                match v.get("is_private").and_then(Value::as_bool) {
                    Some(val) => val,
                    None => true, // default true — matches account_settings_visibility_toggle spec
                }
            }])),
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

fn circle_schema() -> Arc<Schema> {
    Arc::new(Schema::new(Fields::from(vec![
        Field::new("id",                    DataType::Utf8,    false), // = circle_id
        Field::new("owner_did",              DataType::Utf8,    false),
        Field::new("name",                   DataType::Utf8,    false),
        Field::new("visibility",             DataType::Utf8,    false), // NEW — "private" | "public"
        Field::new("member_count",           DataType::Int64,   false),
        Field::new("follower_count",         DataType::Int64,   false), // NEW
        Field::new("invite_code",            DataType::Utf8,    false),
        Field::new("invite_link",            DataType::Utf8,    false),
        Field::new("join_approval_required", DataType::Boolean, false),
        Field::new("max_members",            DataType::Int64,   false),
        Field::new("created_at",             DataType::Int64,   false),
        Field::new("updated_at",             DataType::Int64,   false),
    ])))
}

fn circle_member_schema() -> Arc<Schema> {
    Arc::new(Schema::new(Fields::from(vec![
        Field::new("id",         DataType::Utf8,  false), // "{circle_id}:{member_did}"
        Field::new("circle_id",  DataType::Utf8,  false),
        Field::new("member_did", DataType::Utf8,  false),
        Field::new("owner_did",  DataType::Utf8,  false),
        Field::new("contact_id", DataType::Utf8,  true),  // NEW — nullable (null while pending)
        Field::new("join_method",DataType::Utf8,  true),  // NEW — "direct_add" | "link_approved" | "owner"
        Field::new("role",       DataType::Utf8,  true),  // null while pending
        Field::new("status",     DataType::Utf8,  false), // pending | active | removed
        Field::new("invited_by", DataType::Utf8,  true),
        Field::new("joined_at",  DataType::Int64, false),
        Field::new("updated_at", DataType::Int64, false),
    ])))
}

fn circle_follower_schema() -> Arc<Schema> {
    Arc::new(Schema::new(Fields::from(vec![
        Field::new("id",          DataType::Utf8,  false), // "{circle_id}:{follower_did}"
        Field::new("circle_id",   DataType::Utf8,  false),
        Field::new("follower_did",DataType::Utf8,  false),
        Field::new("contact_id",  DataType::Utf8,  true),  // null until suggestion approved
        Field::new("followed_at", DataType::Int64, false),
    ])))
}

fn json_to_circle_follower_batch(v: &Value) -> NifResult<RecordBatch> {
    let s    = |k: &str| v.get(k).and_then(Value::as_str).unwrap_or("").to_string();
    let so   = |k: &str| v.get(k).and_then(Value::as_str).map(str::to_string);
    let i64v = |k: &str| v.get(k).and_then(Value::as_i64).unwrap_or(0);
    RecordBatch::try_new(
        circle_follower_schema(),
        vec![
            Arc::new(StringArray::from(vec![s("id")])),
            Arc::new(StringArray::from(vec![s("circle_id")])),
            Arc::new(StringArray::from(vec![s("follower_did")])),
            Arc::new(StringArray::from(vec![so("contact_id")])),
            Arc::new(Int64Array::from(vec![i64v("followed_at")])),
        ],
    ).map_err(err)
}

// NEW — directory-scoped table (przma-directory/circles/circle_public_index),
// written by CircleSync.maybe_index_public/5 for every public circle. Not
// specified in IMPLEMENTATION_GUIDE.md §1 despite being referenced in §1.5 —
// row shape here matches exactly what §3.1's maybe_index_public/5 writes.
fn circle_public_index_schema() -> Arc<Schema> {
    Arc::new(Schema::new(Fields::from(vec![
        Field::new("id",         DataType::Utf8,  false), // = circle_id
        Field::new("circle_id",  DataType::Utf8,  false),
        Field::new("owner_did",  DataType::Utf8,  false),
        Field::new("name",       DataType::Utf8,  false),
        Field::new("status",     DataType::Utf8,  false), // active | hidden
        Field::new("created_at", DataType::Int64, false),
    ])))
}

fn json_to_circle_public_index_batch(v: &Value) -> NifResult<RecordBatch> {
    let s    = |k: &str| v.get(k).and_then(Value::as_str).unwrap_or("").to_string();
    let i64v = |k: &str| v.get(k).and_then(Value::as_i64).unwrap_or(0);
    RecordBatch::try_new(
        circle_public_index_schema(),
        vec![
            Arc::new(StringArray::from(vec![s("id")])),
            Arc::new(StringArray::from(vec![s("circle_id")])),
            Arc::new(StringArray::from(vec![s("owner_did")])),
            Arc::new(StringArray::from(vec![s("name")])),
            Arc::new(StringArray::from(vec![s("status")])),
            Arc::new(Int64Array::from(vec![i64v("created_at")])),
        ],
    ).map_err(err)
}

// NEW — person-to-person follow (follow_a_person_flow.png). Written to BOTH
// the follower's and the target's vault (see Follows.follow/2 in
// lib/przma/social/follows.ex) so each side can read their own copy without
// cross-vault reads.
fn person_follow_schema() -> Arc<Schema> {
    Arc::new(Schema::new(Fields::from(vec![
        Field::new("id",           DataType::Utf8,  false), // "{follower_did}:{target_did}"
        Field::new("follower_did", DataType::Utf8,  false),
        Field::new("target_did",   DataType::Utf8,  false),
        Field::new("status",       DataType::Utf8,  false), // active | pending | denied
        Field::new("created_at",   DataType::Int64, false),
        Field::new("updated_at",   DataType::Int64, false),
    ])))
}

fn json_to_person_follow_batch(v: &Value) -> NifResult<RecordBatch> {
    let s    = |k: &str| v.get(k).and_then(Value::as_str).unwrap_or("").to_string();
    let i64v = |k: &str| v.get(k).and_then(Value::as_i64).unwrap_or(0);
    RecordBatch::try_new(
        person_follow_schema(),
        vec![
            Arc::new(StringArray::from(vec![s("id")])),
            Arc::new(StringArray::from(vec![s("follower_did")])),
            Arc::new(StringArray::from(vec![s("target_did")])),
            Arc::new(StringArray::from(vec![s("status")])),
            Arc::new(Int64Array::from(vec![i64v("created_at")])),
            Arc::new(Int64Array::from(vec![i64v("updated_at")])),
        ],
    ).map_err(err)
}

fn circle_invite_schema() -> Arc<Schema> {
    Arc::new(Schema::new(Fields::from(vec![
        Field::new("id",          DataType::Utf8,  false), // = invite_code
        Field::new("invite_code", DataType::Utf8,  false),
        Field::new("circle_id",   DataType::Utf8,  false),
        Field::new("owner_did",   DataType::Utf8,  false),
        Field::new("created_at",  DataType::Int64, false),
    ])))
}

fn circle_pin_schema() -> Arc<Schema> {
    Arc::new(Schema::new(Fields::from(vec![
        Field::new("id",         DataType::Utf8,  false),
        Field::new("circle_id",  DataType::Utf8,  false),
        Field::new("message_id", DataType::Utf8,  false),
        Field::new("pinned_by",  DataType::Utf8,  false),
        Field::new("pinned_at",  DataType::Int64, false),
        Field::new("status",     DataType::Utf8,  true),
    ])))
}

fn json_to_circle_pin_batch(v: &Value) -> NifResult<RecordBatch> {
    let s    = |k: &str| v.get(k).and_then(Value::as_str).unwrap_or("").to_string();
    let so   = |k: &str| v.get(k).and_then(Value::as_str).map(str::to_string);
    let i64v = |k: &str| v.get(k).and_then(Value::as_i64).unwrap_or(0);
    RecordBatch::try_new(
        circle_pin_schema(),
        vec![
            Arc::new(StringArray::from(vec![s("id")])),
            Arc::new(StringArray::from(vec![s("circle_id")])),
            Arc::new(StringArray::from(vec![s("message_id")])),
            Arc::new(StringArray::from(vec![s("pinned_by")])),
            Arc::new(Int64Array::from(vec![i64v("pinned_at")])),
            Arc::new(StringArray::from(vec![so("status")])),
        ],
    ).map_err(err)
}

fn json_to_circle_batch(v: &Value) -> NifResult<RecordBatch> {
    let s    = |k: &str| v.get(k).and_then(Value::as_str).unwrap_or("").to_string();
    let b    = |k: &str| v.get(k).and_then(Value::as_bool).unwrap_or(false);
    let i64v = |k: &str| v.get(k).and_then(Value::as_i64).unwrap_or(0);
    RecordBatch::try_new(
        circle_schema(),
        vec![
            Arc::new(StringArray::from(vec![s("id")])),
            Arc::new(StringArray::from(vec![s("owner_did")])),
            Arc::new(StringArray::from(vec![s("name")])),
            Arc::new(StringArray::from(vec![{
                let vis = s("visibility");
                if vis.is_empty() { "private".to_string() } else { vis }
            }])),
            Arc::new(Int64Array::from(vec![i64v("member_count")])),
            Arc::new(Int64Array::from(vec![i64v("follower_count")])),
            Arc::new(StringArray::from(vec![s("invite_code")])),
            Arc::new(StringArray::from(vec![s("invite_link")])),
            Arc::new(BooleanArray::from(vec![b("join_approval_required")])),
            Arc::new(Int64Array::from(vec![i64v("max_members")])),
            Arc::new(Int64Array::from(vec![i64v("created_at")])),
            Arc::new(Int64Array::from(vec![i64v("updated_at")])),
        ],
    ).map_err(err)
}

fn json_to_circle_member_batch(v: &Value) -> NifResult<RecordBatch> {
    let s    = |k: &str| v.get(k).and_then(Value::as_str).unwrap_or("").to_string();
    let so   = |k: &str| v.get(k).and_then(Value::as_str).map(str::to_string);
    let i64v = |k: &str| v.get(k).and_then(Value::as_i64).unwrap_or(0);
    RecordBatch::try_new(
        circle_member_schema(),
        vec![
            Arc::new(StringArray::from(vec![s("id")])),
            Arc::new(StringArray::from(vec![s("circle_id")])),
            Arc::new(StringArray::from(vec![s("member_did")])),
            Arc::new(StringArray::from(vec![s("owner_did")])),
            Arc::new(StringArray::from(vec![so("contact_id")])),
            Arc::new(StringArray::from(vec![so("join_method")])),
            Arc::new(StringArray::from(vec![so("role")])),
            Arc::new(StringArray::from(vec![s("status")])),
            Arc::new(StringArray::from(vec![so("invited_by")])),
            Arc::new(Int64Array::from(vec![i64v("joined_at")])),
            Arc::new(Int64Array::from(vec![i64v("updated_at")])),
        ],
    ).map_err(err)
}

fn contact_schema() -> Arc<Schema> {
    Arc::new(Schema::new(Fields::from(vec![
        Field::new("id",                    DataType::Utf8,    false),
        Field::new("owner_did",             DataType::Utf8,    false),
        Field::new("entity_type",           DataType::Utf8,    false), // person | company | agent
        Field::new("contact_ref",           DataType::Utf8,    false),
        Field::new("contact_ref_type",      DataType::Utf8,    false), // did | agent_id
        Field::new("contact_type_id",       DataType::Utf8,    true),  // null = unclassified
        Field::new("is_emergency_contact",  DataType::Boolean, false),
        Field::new("company_name",          DataType::Utf8,    true),
        Field::new("source",                DataType::Utf8,    false), // manual|lookup|agent|invite|follow
        Field::new("status",                DataType::Utf8,    false), // active|pending|removed
        Field::new("created_at",            DataType::Int64,   false),
        Field::new("updated_at",            DataType::Int64,   false),
    ])))
}

fn contact_type_schema() -> Arc<Schema> {
    Arc::new(Schema::new(Fields::from(vec![
        Field::new("id",          DataType::Utf8,    false),
        Field::new("owner_did",   DataType::Utf8,    true),  // null = built-in system type
        Field::new("name",        DataType::Utf8,    false),
        Field::new("description", DataType::Utf8,    true),
        Field::new("is_system",   DataType::Boolean,  false),
    ])))
}

fn profile_schema() -> Arc<Schema> {
    // ADDED — not in the original file. "profile" wasn't a
    // recognized table name anywhere in schema_for/pzdb_upsert, so it
    // was silently falling through to files_schema() (22 columns,
    // built for file records) and producing a near-empty, wrong-shape
    // row. `id` is set equal to `did` on the Elixir side (one profile
    // row per user) so pzdb_upsert's delete-by-id upsert logic works.
    Arc::new(Schema::new(Fields::from(vec![
        Field::new("id",         DataType::Utf8,  false),
        Field::new("did",        DataType::Utf8,  false),
        Field::new("gid",        DataType::Utf8,  false), // tenant_uuid
        Field::new("email",      DataType::Utf8,  true),
        Field::new("nickname",   DataType::Utf8,  true),
        Field::new("created_at", DataType::Int64, false),
        Field::new("updated_at", DataType::Int64, true),
    ])))
}

fn json_to_profile_batch(v: &Value) -> NifResult<RecordBatch> {
    let s  = |k: &str| v.get(k).and_then(Value::as_str).unwrap_or("").to_string();
    let so = |k: &str| v.get(k).and_then(Value::as_str).map(str::to_string);
    let i64v = |k: &str| v.get(k).and_then(Value::as_i64).unwrap_or(0);
    let i64o = |k: &str| v.get(k).and_then(Value::as_i64);
    RecordBatch::try_new(
        profile_schema(),
        vec![
            Arc::new(StringArray::from(vec![s("id")])),
            Arc::new(StringArray::from(vec![s("did")])),
            Arc::new(StringArray::from(vec![s("gid")])),
            Arc::new(StringArray::from(vec![so("email")])),
            Arc::new(StringArray::from(vec![so("nickname")])),
            Arc::new(Int64Array::from(vec![i64v("created_at")])),
            Arc::new(Int64Array::from(vec![i64o("updated_at")])),
        ],
    ).map_err(err)
}

fn space_meta_schema() -> Arc<Schema> {
    // ADDED — for SpaceProvisioner's empty-space marker rows
    // ("public"/"professional" at registration time, table "_meta").
    // Same unrecognized-table problem as profile above.
    Arc::new(Schema::new(Fields::from(vec![
        Field::new("id",         DataType::Utf8,  false),
        Field::new("did",        DataType::Utf8,  false),
        Field::new("space",      DataType::Utf8,  false),
        Field::new("created_at", DataType::Int64, false),
    ])))
}

fn json_to_space_meta_batch(v: &Value) -> NifResult<RecordBatch> {
    let s = |k: &str| v.get(k).and_then(Value::as_str).unwrap_or("").to_string();
    let i64v = |k: &str| v.get(k).and_then(Value::as_i64).unwrap_or(0);
    RecordBatch::try_new(
        space_meta_schema(),
        vec![
            Arc::new(StringArray::from(vec![s("id")])),
            Arc::new(StringArray::from(vec![s("did")])),
            Arc::new(StringArray::from(vec![s("space")])),
            Arc::new(Int64Array::from(vec![i64v("created_at")])),
        ],
    ).map_err(err)
}

fn contact_suggestion_schema() -> Arc<Schema> {
    Arc::new(Schema::new(Fields::from(vec![
        Field::new("id",                    DataType::Utf8,  false),
        Field::new("owner_did",             DataType::Utf8,  false),
        Field::new("suggested_contact_ref", DataType::Utf8,  false),
        Field::new("entity_type",           DataType::Utf8,  false),
        Field::new("source",                DataType::Utf8,  false),
        Field::new("status",                DataType::Utf8,  false), // pending|approved|dismissed
        Field::new("created_at",            DataType::Int64, false),
    ])))
}

fn json_to_contact_batch(v: &Value) -> NifResult<RecordBatch> {
    let s    = |k: &str| v.get(k).and_then(Value::as_str).unwrap_or("").to_string();
    let so   = |k: &str| v.get(k).and_then(Value::as_str).map(str::to_string);
    let b    = |k: &str| v.get(k).and_then(Value::as_bool).unwrap_or(false);
    let i64v = |k: &str| v.get(k).and_then(Value::as_i64).unwrap_or(0);
    RecordBatch::try_new(
        contact_schema(),
        vec![
            Arc::new(StringArray::from(vec![s("id")])),
            Arc::new(StringArray::from(vec![s("owner_did")])),
            Arc::new(StringArray::from(vec![s("entity_type")])),
            Arc::new(StringArray::from(vec![s("contact_ref")])),
            Arc::new(StringArray::from(vec![s("contact_ref_type")])),
            Arc::new(StringArray::from(vec![so("contact_type_id")])),
            Arc::new(BooleanArray::from(vec![b("is_emergency_contact")])),
            Arc::new(StringArray::from(vec![so("company_name")])),
            Arc::new(StringArray::from(vec![s("source")])),
            Arc::new(StringArray::from(vec![s("status")])),
            Arc::new(Int64Array::from(vec![i64v("created_at")])),
            Arc::new(Int64Array::from(vec![i64v("updated_at")])),
        ],
    ).map_err(err)
}

fn json_to_contact_type_batch(v: &Value) -> NifResult<RecordBatch> {
    let s  = |k: &str| v.get(k).and_then(Value::as_str).unwrap_or("").to_string();
    let so = |k: &str| v.get(k).and_then(Value::as_str).map(str::to_string);
    let b  = |k: &str| v.get(k).and_then(Value::as_bool).unwrap_or(false);
    RecordBatch::try_new(
        contact_type_schema(),
        vec![
            Arc::new(StringArray::from(vec![s("id")])),
            Arc::new(StringArray::from(vec![so("owner_did")])),
            Arc::new(StringArray::from(vec![s("name")])),
            Arc::new(StringArray::from(vec![so("description")])),
            Arc::new(BooleanArray::from(vec![b("is_system")])),
        ],
    ).map_err(err)
}

fn json_to_contact_suggestion_batch(v: &Value) -> NifResult<RecordBatch> {
    let s    = |k: &str| v.get(k).and_then(Value::as_str).unwrap_or("").to_string();
    let i64v = |k: &str| v.get(k).and_then(Value::as_i64).unwrap_or(0);
    RecordBatch::try_new(
        contact_suggestion_schema(),
        vec![
            Arc::new(StringArray::from(vec![s("id")])),
            Arc::new(StringArray::from(vec![s("owner_did")])),
            Arc::new(StringArray::from(vec![s("suggested_contact_ref")])),
            Arc::new(StringArray::from(vec![s("entity_type")])),
            Arc::new(StringArray::from(vec![s("source")])),
            Arc::new(StringArray::from(vec![s("status")])),
            Arc::new(Int64Array::from(vec![i64v("created_at")])),
        ],
    ).map_err(err)
}

fn json_to_circle_invite_batch(v: &Value) -> NifResult<RecordBatch> {
    let s    = |k: &str| v.get(k).and_then(Value::as_str).unwrap_or("").to_string();
    let i64v = |k: &str| v.get(k).and_then(Value::as_i64).unwrap_or(0);
    RecordBatch::try_new(
        circle_invite_schema(),
        vec![
            Arc::new(StringArray::from(vec![s("id")])),
            Arc::new(StringArray::from(vec![s("invite_code")])),
            Arc::new(StringArray::from(vec![s("circle_id")])),
            Arc::new(StringArray::from(vec![s("owner_did")])),
            Arc::new(Int64Array::from(vec![i64v("created_at")])),
        ],
    ).map_err(err)
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
        "circles"            => circle_schema(),          // ← add
        "circle_members"     => circle_member_schema(),    // ← add
        "circle_invites"     => circle_invite_schema(),
        "circle_pins"        => circle_pin_schema(),
        "circle_followers"     => circle_follower_schema(),     // NEW
        "circle_public_index"  => circle_public_index_schema(), // NEW — see §4 of guide
        "person_follows"       => person_follow_schema(),       // NEW — person-to-person follow
        "contacts"              => contact_schema(),            // NEW
        "contact_types"         => contact_type_schema(),       // NEW
        "contact_suggestions"   => contact_suggestion_schema(), // NEW
        "profile"                => profile_schema(),           // ADDED — see profile_schema() above
        "_meta"                  => space_meta_schema(),        // ADDED — see space_meta_schema() above
        _ => files_schema(),   // existing, untouched
    }
}

fn json_to_activity_batch(v: &Value) -> NifResult<RecordBatch> {
    let s  = |k: &str| v.get(k).and_then(Value::as_str).unwrap_or("").to_string();
    let so = |k: &str| v.get(k).and_then(Value::as_str).map(str::to_string);
    let i64v = |k: &str| v.get(k).and_then(Value::as_i64).unwrap_or(0);
    let user_type = v.get("user_type")
        .and_then(Value::as_str)
        .filter(|s| *s == "person" || *s == "agent")
        .ok_or_else(|| err("user_type is required and must be \"person\" or \"agent\""))?
        .to_string();
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
            Arc::new(StringArray::from(vec![user_type])),
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
            "circles"          => json_to_circle_batch(&v)?,          // ← add
            "circle_members"   => json_to_circle_member_batch(&v)?,   // ← add
            "circle_invites"   => json_to_circle_invite_batch(&v)?,
            "circle_pins" => json_to_circle_pin_batch(&v)?,
            "circle_followers"      => json_to_circle_follower_batch(&v)?,       // NEW
            "circle_public_index"   => json_to_circle_public_index_batch(&v)?,   // NEW
            "person_follows"        => json_to_person_follow_batch(&v)?,         // NEW
            "contacts"               => json_to_contact_batch(&v)?,             // NEW
            "contact_types"          => json_to_contact_type_batch(&v)?,        // NEW
            "contact_suggestions"    => json_to_contact_suggestion_batch(&v)?,   // NEW
            "profile"                 => json_to_profile_batch(&v)?,            // ADDED
            "_meta"                   => json_to_space_meta_batch(&v)?,         // ADDED
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

// ── DOC STORE (LanceDB replacement for CouchDB) ─────────────────────────────
//
// Used by Przma.Vault.LanceDocAdapter for every {namespace, table} listed in
// config :przma, :doc_store_tables (profile, files index, cas_meta, chat,
// circle, social …). These tables do NOT use the typed schemas above: every
// doc table has the SAME 11-column schema, and the free-form document fields
// travel as one JSON string in `doc_json`. That keeps CouchDB's flexibility
// (services can add fields without a Rust change) while the envelope columns
// (id, did, namespace, …) stay real, filterable Lance columns.
//
// Location is the same rule as every other pzdb table (built in Elixir):
//   {base}/{did}/{namespace}/{space}/{table}.lance
//
// Writes are serialised per user by Przma.Storage.DocWriter (Elixir), because
// Lance on S3 has no safe multi-writer commit. Do not call these NIFs from
// anywhere else.

use lancedb::table::{CompactionOptions, Duration as LanceDuration, OptimizeAction};

// Doc NIFs run their work ON a tokio worker thread (16 MB stack, see rt()),
// not on the BEAM dirty-scheduler thread that called the NIF: that thread's
// stack is small and Lance's deep futures overflow it (segfault), especially
// in debug builds. Errors travel as String because NifError is not Send.
type DocResult<T> = Result<T, String>;

fn derr<E: std::fmt::Display>(e: E) -> String {
    e.to_string()
}

fn run_doc<F>(fut: F) -> NifResult<String>
where
    F: std::future::Future<Output = DocResult<String>> + Send + 'static,
{
    match rt().block_on(rt().spawn(fut)) {
        Ok(Ok(json)) => Ok(json),
        Ok(Err(e)) => Err(err(e)),
        Err(join_error) => Err(err(format!("doc task failed: {}", join_error))),
    }
}

const DOC_SCHEMA_MARKER: &str = "doc_json";

fn doc_schema() -> Arc<Schema> {
    Arc::new(Schema::new(Fields::from(vec![
        Field::new("id",         DataType::Utf8,  false), // record id (single-doc tables: the did)
        Field::new("did",        DataType::Utf8,  false), // owner
        Field::new("gid",        DataType::Utf8,  true),  // tenant uuid
        Field::new("namespace",  DataType::Utf8,  false),
        Field::new("space",      DataType::Utf8,  false),
        Field::new("table_name", DataType::Utf8,  false),
        Field::new("pzdb_uri",   DataType::Utf8,  true),
        Field::new("doc_ver",    DataType::Int64, false), // replaces CouchDB _rev
        Field::new("created_at", DataType::Int64, false), // microseconds
        Field::new("updated_at", DataType::Int64, false), // microseconds
        Field::new("doc_json",   DataType::Utf8,  false), // all other fields, JSON object
    ])))
}

fn json_to_doc_batch(rows: &[Value]) -> DocResult<RecordBatch> {
    fn s(v: &Value, k: &str) -> String {
        v.get(k).and_then(Value::as_str).unwrap_or("").to_string()
    }
    fn so(v: &Value, k: &str) -> Option<String> {
        v.get(k).and_then(Value::as_str).map(str::to_string)
    }
    fn i(v: &Value, k: &str) -> i64 {
        v.get(k).and_then(Value::as_i64).unwrap_or(0)
    }
    fn doc(v: &Value) -> String {
        match v.get("doc_json") {
            Some(Value::String(js)) => js.clone(),
            Some(other) => other.to_string(),
            None => "{}".to_string(),
        }
    }

    for r in rows {
        if s(r, "id").is_empty() {
            return Err("doc row without id".to_string());
        }
    }

    let col = |f: fn(&Value, &str) -> String, k: &str| -> Arc<StringArray> {
        Arc::new(StringArray::from(rows.iter().map(|r| f(r, k)).collect::<Vec<_>>()))
    };
    let colo = |k: &str| -> Arc<StringArray> {
        Arc::new(StringArray::from(rows.iter().map(|r| so(r, k)).collect::<Vec<_>>()))
    };
    let coli = |k: &str| -> Arc<Int64Array> {
        Arc::new(Int64Array::from(rows.iter().map(|r| i(r, k)).collect::<Vec<_>>()))
    };

    RecordBatch::try_new(
        doc_schema(),
        vec![
            col(s, "id"),
            col(s, "did"),
            colo("gid"),
            col(s, "namespace"),
            col(s, "space"),
            col(s, "table_name"),
            colo("pzdb_uri"),
            coli("doc_ver"),
            coli("created_at"),
            coli("updated_at"),
            Arc::new(StringArray::from(rows.iter().map(doc).collect::<Vec<_>>())),
        ],
    )
    .map_err(derr)
}

// Opens {dir}/{table}.lance. Missing table: created (create = true) or None.
// An existing table WITHOUT the doc schema (e.g. an old profile.lance written
// with profile_schema) is reported as "schema_mismatch", never overwritten.
async fn open_doc_table(dir: &str, table: &str, create: bool) -> DocResult<Option<Table>> {
    let conn = connect(dir).execute().await.map_err(derr)?;
    let t = match conn.open_table(table).execute().await {
        Ok(t) => t,
        Err(lancedb::Error::TableNotFound { .. }) if create => conn
            .create_empty_table(table, doc_schema())
            .execute()
            .await
            .map_err(derr)?,
        Err(lancedb::Error::TableNotFound { .. }) => return Ok(None),
        Err(e) => return Err(derr(e)),
    };

    let schema = t.schema().await.map_err(derr)?;
    if schema.field_with_name(DOC_SCHEMA_MARKER).is_err() {
        return Err(format!(
            "schema_mismatch: {}/{}.lance exists but is not a doc-store table",
            dir, table
        ));
    }
    Ok(Some(t))
}

/// Upsert rows (JSON array) by `id` in ONE commit (merge_insert).
#[rustler::nif(schedule = "DirtyIo")]
fn pzdb_doc_upsert(base_path: String, table_path: String, rows_json: String) -> NifResult<String> {
    run_doc(async move {
        let rows: Vec<Value> = serde_json::from_str(&rows_json).map_err(derr)?;
        if rows.is_empty() {
            return Ok(json!({"status": "ok", "count": 0}).to_string());
        }
        let table = open_doc_table(&base_path, &table_path, true)
            .await?
            .ok_or_else(|| "table could not be created".to_string())?;

        let batch = json_to_doc_batch(&rows)?;
        let count = batch.num_rows();
        let reader = RecordBatchIterator::new(vec![Ok(batch)], doc_schema());

        // Empty table: plain append. Otherwise: real upsert on `id`.
        if table.count_rows(None).await.map_err(derr)? == 0 {
            table.add(reader).execute().await.map_err(derr)?;
        } else {
            let mut builder = table.merge_insert(&["id"]);
            builder.when_matched_update_all(None).when_not_matched_insert_all();
            builder.execute(Box::new(reader)).await.map_err(derr)?;
        }

        let version = table.version().await.map_err(derr)?;
        Ok(json!({"status": "ok", "count": count, "version": version}).to_string())
    })
}

/// Rows matching an SQL filter ("" = all), at most `limit`. Missing table => [].
/// Rows come back UNORDERED — the Elixir side sorts by id.
#[rustler::nif(schedule = "DirtyIo")]
fn pzdb_doc_query(base_path: String, table_path: String, filter: String, limit: u64) -> NifResult<String> {
    run_doc(async move {
        let table = match open_doc_table(&base_path, &table_path, false).await? {
            Some(t) => t,
            None => return Ok(json!({"status": "ok", "records": [], "total": 0}).to_string()),
        };

        let mut q = table.query().limit(limit as usize);
        if !filter.trim().is_empty() {
            q = q.only_if(filter);
        }
        let batches: Vec<RecordBatch> =
            q.execute().await.map_err(derr)?.try_collect().await.map_err(derr)?;

        let records = batches_to_json(&batches);
        let total = records.len();
        Ok(json!({"status": "ok", "records": records, "total": total}).to_string())
    })
}

/// Compacts small files and prunes versions older than `keep_hours`.
/// Run through DocWriter so it never overlaps a write to the same table.
#[rustler::nif(schedule = "DirtyIo")]
fn pzdb_doc_optimize(base_path: String, table_path: String, keep_hours: u64) -> NifResult<String> {
    run_doc(async move {
        let table = match open_doc_table(&base_path, &table_path, false).await? {
            Some(t) => t,
            None => return Ok(json!({"status": "ok", "skipped": "no_table"}).to_string()),
        };

        let compaction = table
            .optimize(OptimizeAction::Compact {
                options: CompactionOptions::default(),
                remap_options: None,
            })
            .await
            .map_err(derr)?
            .compaction;

        let older_than = LanceDuration::try_hours(keep_hours as i64)
            .ok_or_else(|| "invalid keep_hours".to_string())?;
        let prune = table
            .optimize(OptimizeAction::Prune {
                older_than: Some(older_than),
                delete_unverified: Some(false),
                error_if_tagged_old_versions: Some(false),
            })
            .await
            .map_err(derr)?
            .prune;

        let version = table.version().await.map_err(derr)?;
        Ok(json!({
            "status": "ok",
            "version": version,
            "fragments_removed": compaction.as_ref().map(|c| c.fragments_removed).unwrap_or(0),
            "fragments_added":   compaction.as_ref().map(|c| c.fragments_added).unwrap_or(0),
            "files_removed":     compaction.as_ref().map(|c| c.files_removed).unwrap_or(0),
            "files_added":       compaction.as_ref().map(|c| c.files_added).unwrap_or(0),
            "old_versions":      prune.as_ref().map(|p| p.old_versions).unwrap_or(0),
            "bytes_removed":     prune.as_ref().map(|p| p.bytes_removed).unwrap_or(0),
        })
        .to_string())
    })
}

/// Row count + current version of one doc table (for tests and monitoring).
#[rustler::nif(schedule = "DirtyIo")]
fn pzdb_doc_stats(base_path: String, table_path: String) -> NifResult<String> {
    run_doc(async move {
        match open_doc_table(&base_path, &table_path, false).await? {
            None => Ok(json!({"status": "ok", "exists": false, "rows": 0, "version": 0}).to_string()),
            Some(t) => {
                let rows = t.count_rows(None).await.map_err(derr)?;
                let version = t.version().await.map_err(derr)?;
                Ok(json!({"status": "ok", "exists": true, "rows": rows, "version": version}).to_string())
            }
        }
    })
}

// ── VECTOR SEARCH (embeddings + similarity search) ─────────────────────────
//
// Used by Przma.Search (lib/przma/search/search.ex). One vector table per user
// and space, at the same S3 tree as every other pzdb table:
//
//     {base}/{did}/search/{space}/chunks.lance
//
// Every row is one piece ("chunk") of a file, message or document:
//     id, did, space, source_type, source_id, title, chunk_index, text,
//     created_at, vector[dim]
//
// The embedding model runs HERE, inside the NIF (model2vec-rs, pure Rust, no
// Python / ONNX / API key). Default model: minishlab/potion-base-8M (256 dims).
// Change it with the env var PRZMA_EMBED_MODEL: a HuggingFace repo id, or a
// local folder holding config.json, tokenizer.json and model.safetensors.
// The model is loaded once (first use) and shared by all calls.
//
// Writes must go through Przma.Storage.DocWriter (one writer per user), the
// same rule as the doc tables: Lance on S3 has no safe multi-writer commit.

use lancedb::index::vector::IvfPqIndexBuilder;
use lancedb::index::Index;
use lancedb::query::Select;
use lancedb::DistanceType;
use model2vec_rs::model::StaticModel;
use std::sync::Mutex;

const VEC_MARKER: &str = "vector";
const VEC_MAX_TOKENS: usize = 512;
const VEC_BATCH: usize = 256;

// Columns returned by searches (everything except the vector itself).
const VEC_OUT_COLUMNS: [&str; 9] = [
    "id", "did", "space", "source_type", "source_id", "title", "chunk_index", "text", "created_at",
];

static EMBEDDER: Mutex<Option<(String, Arc<StaticModel>)>> = Mutex::new(None);

fn embed_model_name() -> String {
    std::env::var("PRZMA_EMBED_MODEL").unwrap_or_else(|_| "minishlab/potion-base-8M".to_string())
}

// Loads the model on first use (downloads it from HuggingFace once, or reads a
// local folder), then returns the shared copy.
fn embedder() -> DocResult<(String, Arc<StaticModel>)> {
    let mut guard = EMBEDDER.lock().map_err(|_| "embedding model lock poisoned".to_string())?;
    if let Some((name, model)) = guard.as_ref() {
        return Ok((name.clone(), model.clone()));
    }
    let name = embed_model_name();
    let model = StaticModel::from_pretrained(&name, None, Some(true), None)
        .map_err(|e| format!("embedding model load failed ({}): {}", name, e))?;
    let model = Arc::new(model);
    *guard = Some((name.clone(), model.clone()));
    Ok((name, model))
}

// Text -> vectors, on a blocking thread (CPU work must not stall tokio).
async fn embed_texts(texts: Vec<String>) -> DocResult<Vec<Vec<f32>>> {
    tokio::task::spawn_blocking(move || {
        let (_, model) = embedder()?;
        if texts.is_empty() {
            return Ok(Vec::new());
        }
        let vectors = model.encode_with_args(&texts, Some(VEC_MAX_TOKENS), VEC_BATCH);
        if vectors.len() != texts.len() {
            return Err(format!("model returned {} vectors for {} texts", vectors.len(), texts.len()));
        }
        Ok(vectors)
    })
    .await
    .map_err(derr)?
}

fn ms_since(t: std::time::Instant) -> u128 {
    t.elapsed().as_millis()
}

fn vec_schema(dim: i32) -> Arc<Schema> {
    Arc::new(Schema::new(Fields::from(vec![
        Field::new("id",          DataType::Utf8,  false), // "<source_id>#<chunk_index>"
        Field::new("did",         DataType::Utf8,  false), // owner
        Field::new("space",       DataType::Utf8,  false), // private | personal | public
        Field::new("source_type", DataType::Utf8,  false), // file | chat | doc | …
        Field::new("source_id",   DataType::Utf8,  false), // file_id / message id / doc id
        Field::new("title",       DataType::Utf8,  true),  // file name, chat name …
        Field::new("chunk_index", DataType::Int32, false),
        Field::new("text",        DataType::Utf8,  false), // the piece of text itself
        Field::new("created_at",  DataType::Int64, false), // microseconds
        Field::new(
            VEC_MARKER,
            DataType::FixedSizeList(Arc::new(Field::new("item", DataType::Float32, true)), dim),
            false,
        ),
    ])))
}

fn table_dim(schema: &Schema) -> Option<i32> {
    match schema.field_with_name(VEC_MARKER).ok()?.data_type() {
        DataType::FixedSizeList(_, n) => Some(*n),
        _ => None,
    }
}

// Opens {dir}/{table}.lance. Missing: created with `create_dim` dims, or None.
// A table built with another model (other dims) is refused, never mixed.
async fn open_vec_table(dir: &str, table: &str, create_dim: Option<i32>) -> DocResult<Option<Table>> {
    let conn = connect(dir).execute().await.map_err(derr)?;
    let t = match conn.open_table(table).execute().await {
        Ok(t) => t,
        Err(lancedb::Error::TableNotFound { .. }) => match create_dim {
            Some(dim) => conn
                .create_empty_table(table, vec_schema(dim))
                .execute()
                .await
                .map_err(derr)?,
            None => return Ok(None),
        },
        Err(e) => return Err(derr(e)),
    };

    let schema = t.schema().await.map_err(derr)?;
    match (table_dim(&schema), create_dim) {
        (None, _) => Err(format!("schema_mismatch: {}/{}.lance is not a vector table", dir, table)),
        (Some(have), Some(want)) if have != want => Err(format!(
            "dimension_mismatch: table has {} dims, model gives {} (model changed? delete and re-index)",
            have, want
        )),
        _ => Ok(Some(t)),
    }
}

fn json_to_vec_batch(rows: &[Value], vectors: &[Vec<f32>], dim: i32) -> DocResult<RecordBatch> {
    let s = |v: &Value, k: &str| v.get(k).and_then(Value::as_str).unwrap_or("").to_string();
    let so = |v: &Value, k: &str| v.get(k).and_then(Value::as_str).map(str::to_string);
    let i64v = |v: &Value, k: &str| v.get(k).and_then(Value::as_i64).unwrap_or(0);

    let mut flat: Vec<f32> = Vec::with_capacity(rows.len() * dim as usize);
    for v in vectors {
        if v.len() != dim as usize {
            return Err(format!("vector has {} dims, expected {}", v.len(), dim));
        }
        flat.extend_from_slice(v);
    }
    let vector_col = FixedSizeListArray::try_new(
        Arc::new(Field::new("item", DataType::Float32, true)),
        dim,
        Arc::new(Float32Array::from(flat)),
        None,
    )
    .map_err(derr)?;

    let col = |k: &str| -> Arc<StringArray> {
        Arc::new(StringArray::from(rows.iter().map(|r| s(r, k)).collect::<Vec<_>>()))
    };

    RecordBatch::try_new(
        vec_schema(dim),
        vec![
            col("id"),
            col("did"),
            col("space"),
            col("source_type"),
            col("source_id"),
            Arc::new(StringArray::from(rows.iter().map(|r| so(r, "title")).collect::<Vec<_>>())),
            Arc::new(Int32Array::from(
                rows.iter().map(|r| i64v(r, "chunk_index") as i32).collect::<Vec<_>>(),
            )),
            col("text"),
            Arc::new(Int64Array::from(rows.iter().map(|r| i64v(r, "created_at")).collect::<Vec<_>>())),
            Arc::new(vector_col),
        ],
    )
    .map_err(derr)
}

fn out_columns() -> Select {
    Select::Columns(VEC_OUT_COLUMNS.iter().map(|c| c.to_string()).collect())
}

/// Loads the embedding model now and reports its name and size.
#[rustler::nif(schedule = "DirtyIo")]
fn pzdb_vec_model_info() -> NifResult<String> {
    run_doc(async move {
        let started = std::time::Instant::now();
        let vectors = embed_texts(vec!["hello".to_string()]).await?;
        let (name, _) = embedder()?;
        Ok(json!({
            "status": "ok",
            "model": name,
            "dim": vectors.first().map(|v| v.len()).unwrap_or(0),
            "load_ms": ms_since(started),
        })
        .to_string())
    })
}

/// Embeds texts (JSON array of strings). Returns timing, and the vectors
/// themselves only when `include_vectors` is true (tests / debugging).
#[rustler::nif(schedule = "DirtyIo")]
fn pzdb_vec_embed(texts_json: String, include_vectors: bool) -> NifResult<String> {
    run_doc(async move {
        let texts: Vec<String> = serde_json::from_str(&texts_json).map_err(derr)?;
        let count = texts.len();
        let started = std::time::Instant::now();
        let vectors = embed_texts(texts).await?;
        let ms = ms_since(started);
        let mut out = json!({
            "status": "ok",
            "count": count,
            "dim": vectors.first().map(|v| v.len()).unwrap_or(0),
            "embed_ms": ms,
        });
        if include_vectors {
            out["vectors"] = json!(vectors);
        }
        Ok(out.to_string())
    })
}

/// Embeds the `text` of each row (JSON array) and upserts the rows by `id`
/// in ONE commit. Creates the table on first use.
#[rustler::nif(schedule = "DirtyIo")]
fn pzdb_vec_upsert(base_path: String, table_path: String, rows_json: String) -> NifResult<String> {
    run_doc(async move {
        let rows: Vec<Value> = serde_json::from_str(&rows_json).map_err(derr)?;
        if rows.is_empty() {
            return Ok(json!({"status": "ok", "count": 0}).to_string());
        }
        for r in &rows {
            let id = r.get("id").and_then(Value::as_str).unwrap_or("");
            let text = r.get("text").and_then(Value::as_str).unwrap_or("");
            if id.is_empty() || text.trim().is_empty() {
                return Err("every row needs a non-empty id and text".to_string());
            }
        }

        let texts: Vec<String> = rows
            .iter()
            .map(|r| r.get("text").and_then(Value::as_str).unwrap_or("").to_string())
            .collect();
        let t_embed = std::time::Instant::now();
        let vectors = embed_texts(texts).await?;
        let embed_ms = ms_since(t_embed);
        let dim = vectors.first().map(|v| v.len()).unwrap_or(0) as i32;

        let t_write = std::time::Instant::now();
        let table = open_vec_table(&base_path, &table_path, Some(dim))
            .await?
            .ok_or_else(|| "vector table could not be created".to_string())?;
        let batch = json_to_vec_batch(&rows, &vectors, dim)?;
        let count = batch.num_rows();
        let reader = RecordBatchIterator::new(vec![Ok(batch)], vec_schema(dim));

        if table.count_rows(None).await.map_err(derr)? == 0 {
            table.add(reader).execute().await.map_err(derr)?;
        } else {
            let mut builder = table.merge_insert(&["id"]);
            builder.when_matched_update_all(None).when_not_matched_insert_all();
            builder.execute(Box::new(reader)).await.map_err(derr)?;
        }
        let version = table.version().await.map_err(derr)?;

        Ok(json!({
            "status": "ok",
            "count": count,
            "dim": dim,
            "version": version,
            "embed_ms": embed_ms,
            "write_ms": ms_since(t_write),
        })
        .to_string())
    })
}

/// Similarity search: embeds `query_text`, returns the `limit` closest rows
/// (cosine). `filter` is an optional SQL filter ("" = none); `nprobes` only
/// matters once an index exists (0 = default). Missing table => [].
#[rustler::nif(schedule = "DirtyIo")]
fn pzdb_vec_search(
    base_path: String,
    table_path: String,
    query_text: String,
    limit: u64,
    filter: String,
    nprobes: u64,
) -> NifResult<String> {
    run_doc(async move {
        let table = match open_vec_table(&base_path, &table_path, None).await? {
            Some(t) => t,
            None => return Ok(json!({"status": "ok", "records": [], "total": 0}).to_string()),
        };

        let t_embed = std::time::Instant::now();
        let mut vectors = embed_texts(vec![query_text]).await?;
        let query_vector = vectors.pop().ok_or_else(|| "query embedding failed".to_string())?;
        let embed_ms = ms_since(t_embed);

        let t_search = std::time::Instant::now();
        let mut q = table
            .query()
            .nearest_to(query_vector)
            .map_err(derr)?
            .distance_type(DistanceType::Cosine)
            .limit(limit as usize)
            .select(out_columns());
        if nprobes > 0 {
            // Index search: look in `nprobes` partitions, then re-check the best
            // limit x 10 candidates with their exact vectors (better recall).
            q = q.nprobes(nprobes as usize).refine_factor(10);
        }
        if !filter.trim().is_empty() {
            q = q.only_if(filter);
        }
        let batches: Vec<RecordBatch> =
            q.execute().await.map_err(derr)?.try_collect().await.map_err(derr)?;
        let records = batches_to_json(&batches);

        Ok(json!({
            "status": "ok",
            "records": records,
            "total": records.len(),
            "embed_ms": embed_ms,
            "search_ms": ms_since(t_search),
        })
        .to_string())
    })
}

/// Plain filtered read (no vectors), e.g. keyword search with
/// "lower(text) LIKE '%biryani%'". Missing table => [].
#[rustler::nif(schedule = "DirtyIo")]
fn pzdb_vec_query(base_path: String, table_path: String, filter: String, limit: u64) -> NifResult<String> {
    run_doc(async move {
        let table = match open_vec_table(&base_path, &table_path, None).await? {
            Some(t) => t,
            None => return Ok(json!({"status": "ok", "records": [], "total": 0}).to_string()),
        };
        let started = std::time::Instant::now();
        let mut q = table.query().limit(limit as usize).select(out_columns());
        if !filter.trim().is_empty() {
            q = q.only_if(filter);
        }
        let batches: Vec<RecordBatch> =
            q.execute().await.map_err(derr)?.try_collect().await.map_err(derr)?;
        let records = batches_to_json(&batches);
        Ok(json!({
            "status": "ok",
            "records": records,
            "total": records.len(),
            "search_ms": ms_since(started),
        })
        .to_string())
    })
}

/// Deletes rows matching an SQL filter, e.g. "source_id = 'f_9k2m'"
/// (re-index or file deleted). Missing table => ok.
#[rustler::nif(schedule = "DirtyIo")]
fn pzdb_vec_delete(base_path: String, table_path: String, filter: String) -> NifResult<String> {
    run_doc(async move {
        if filter.trim().is_empty() {
            return Err("delete needs a filter".to_string());
        }
        match open_vec_table(&base_path, &table_path, None).await? {
            None => Ok(json!({"status": "ok", "skipped": "no_table"}).to_string()),
            Some(t) => {
                let before = t.count_rows(None).await.map_err(derr)?;
                t.delete(&filter).await.map_err(derr)?;
                let after = t.count_rows(None).await.map_err(derr)?;
                Ok(json!({"status": "ok", "deleted": before.saturating_sub(after)}).to_string())
            }
        }
    })
}

/// Builds (or rebuilds) the IVF-PQ vector index for fast search on big tables.
/// 0 = let LanceDB choose. num_sub_vectors must divide the vector size.
/// Needs at least 256 rows (PQ training).
#[rustler::nif(schedule = "DirtyIo")]
fn pzdb_vec_index(
    base_path: String,
    table_path: String,
    num_partitions: u32,
    num_sub_vectors: u32,
) -> NifResult<String> {
    run_doc(async move {
        let table = open_vec_table(&base_path, &table_path, None)
            .await?
            .ok_or_else(|| "no_table".to_string())?;
        let rows = table.count_rows(None).await.map_err(derr)?;
        if rows < 256 {
            return Err(format!("index needs at least 256 rows, table has {}", rows));
        }

        let mut builder = IvfPqIndexBuilder::default().distance_type(DistanceType::Cosine);
        if num_partitions > 0 {
            builder = builder.num_partitions(num_partitions);
        }
        if num_sub_vectors > 0 {
            builder = builder.num_sub_vectors(num_sub_vectors);
        }

        let started = std::time::Instant::now();
        table
            .create_index(&[VEC_MARKER], Index::IvfPq(builder))
            .execute()
            .await
            .map_err(derr)?;

        Ok(json!({
            "status": "ok",
            "rows": rows,
            "index_ms": ms_since(started),
            "version": table.version().await.map_err(derr)?,
        })
        .to_string())
    })
}

/// Compacts small files and prunes old versions of a vector table
/// (LanceCompactor calls this for search tables). Keeps the vector index.
#[rustler::nif(schedule = "DirtyIo")]
fn pzdb_vec_optimize(base_path: String, table_path: String, keep_hours: u64) -> NifResult<String> {
    run_doc(async move {
        let table = match open_vec_table(&base_path, &table_path, None).await? {
            Some(t) => t,
            None => return Ok(json!({"status": "ok", "skipped": "no_table"}).to_string()),
        };
        let compaction = table
            .optimize(OptimizeAction::Compact { options: CompactionOptions::default(), remap_options: None })
            .await
            .map_err(derr)?
            .compaction;
        let older_than = LanceDuration::try_hours(keep_hours as i64).ok_or_else(|| "invalid keep_hours".to_string())?;
        let prune = table
            .optimize(OptimizeAction::Prune {
                older_than: Some(older_than),
                delete_unverified: Some(false),
                error_if_tagged_old_versions: Some(false),
            })
            .await
            .map_err(derr)?
            .prune;
        Ok(json!({
            "status": "ok",
            "version": table.version().await.map_err(derr)?,
            "fragments_removed": compaction.as_ref().map(|c| c.fragments_removed).unwrap_or(0),
            "fragments_added":   compaction.as_ref().map(|c| c.fragments_added).unwrap_or(0),
            "old_versions":      prune.as_ref().map(|p| p.old_versions).unwrap_or(0),
            "bytes_removed":     prune.as_ref().map(|p| p.bytes_removed).unwrap_or(0),
        })
        .to_string())
    })
}

/// Row count, version, vector size and index names of one vector table.
#[rustler::nif(schedule = "DirtyIo")]
fn pzdb_vec_stats(base_path: String, table_path: String) -> NifResult<String> {
    run_doc(async move {
        match open_vec_table(&base_path, &table_path, None).await? {
            None => Ok(json!({"status": "ok", "exists": false, "rows": 0}).to_string()),
            Some(t) => {
                let schema = t.schema().await.map_err(derr)?;
                let indices: Vec<String> = t
                    .list_indices()
                    .await
                    .map_err(derr)?
                    .into_iter()
                    .map(|i| format!("{} ({})", i.name, i.columns.join(",")))
                    .collect();
                Ok(json!({
                    "status": "ok",
                    "exists": true,
                    "rows": t.count_rows(None).await.map_err(derr)?,
                    "version": t.version().await.map_err(derr)?,
                    "dim": table_dim(&schema),
                    "indices": indices,
                })
                .to_string())
            }
        }
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