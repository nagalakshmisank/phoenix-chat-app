// przma-nif/src/lib.rs
//
// Rustler NIF bindings — exposes PRZMA Calendar Rust functions to Elixir.
// All async NIFs use Rustler's tokio integration.

use przma_calendar::{
    analytics::CalendarAnalytics,
    cas::{CasStore, CasTable},
    events::EventStore,
    models::{CalendarEvent, CalendarTask, EventCategory, Space},
    recurrence,
    tasks::TaskStore,
};
use rustler::{Atom, Binary, Encoder, Env, Error as NifError, NifResult, Term};
use serde_json::Value;
use std::collections::HashMap;

mod atoms {
    rustler::atoms! {
        ok,
        error,
        not_found,
        invalid_field,
        permission_denied,
        conflict,
    }
}

mod analytics_nif;
mod circle_nif;
mod federation_nif;
mod intelligence_nif;
mod social_nif;
mod storage_nif;

// ─── RUNTIME ─────────────────────────────────────────────────────────────────

fn runtime() -> &'static tokio::runtime::Runtime {
    static RT: std::sync::OnceLock<tokio::runtime::Runtime> = std::sync::OnceLock::new();
    RT.get_or_init(|| {
        tokio::runtime::Builder::new_multi_thread()
            .worker_threads(4)
            .enable_all()
            .build()
            .expect("Failed to build Tokio runtime")
    })
}

// ─── RESULT HELPER ───────────────────────────────────────────────────────────

fn ok_json<'a>(env: Env<'a>, value: &impl serde::Serialize) -> Term<'a> {
    let json = serde_json::to_string(value).unwrap_or_else(|_| "null".to_string());
    (atoms::ok(), json).encode(env)
}

fn err_atom<'a>(env: Env<'a>, reason: &str) -> Term<'a> {
    (atoms::error(), reason.to_string()).encode(env)
}

// ─── EVENT NIFs ───────────────────────────────────────────────────────────────

/// create_event(base_path, did, event_json) -> {:ok, id} | {:error, reason}
#[rustler::nif(schedule = "DirtyIo")]
fn create_event<'a>(env: Env<'a>, base_path: String, did: String, event_json: String) -> Term<'a> {
    let event: CalendarEvent = match serde_json::from_str(&event_json) {
        Ok(e)  => e,
        Err(e) => return err_atom(env, &format!("Invalid JSON: {}", e)),
    };

    runtime().block_on(async {
        match EventStore::new(&base_path, &did).await {
            Err(e) => return err_atom(env, &e.to_string()),
            Ok(store) => match store.create(&event).await {
                Ok(id)  => ok_json(env, &id),
                Err(e)  => err_atom(env, &e.to_string()),
            }
        }
    })
}

/// get_event(base_path, did, event_id, space) -> {:ok, event_json} | {:error, reason}
#[rustler::nif(schedule = "DirtyIo")]
fn get_event<'a>(
    env: Env<'a>,
    base_path: String,
    did:       String,
    event_id:  String,
    space_str: String,
) -> Term<'a> {
    let space = match Space::try_from(space_str.as_str()) {
        Ok(s)  => s,
        Err(e) => return err_atom(env, &e.to_string()),
    };

    runtime().block_on(async {
        let store = match EventStore::new(&base_path, &did).await {
            Ok(s)  => s,
            Err(e) => return err_atom(env, &e.to_string()),
        };
        match store.get(&event_id, &space).await {
            Ok(event) => ok_json(env, &event),
            Err(e)    => err_atom(env, &e.to_string()),
        }
    })
}

/// list_events(base_path, did, query_json) -> {:ok, events_json} | {:error, reason}
/// query_json: { space, start_micros, end_micros, category, status, limit }
#[rustler::nif(schedule = "DirtyIo")]
fn list_events<'a>(env: Env<'a>, base_path: String, did: String, query_json: String) -> Term<'a> {
    let query: serde_json::Value = match serde_json::from_str(&query_json) {
        Ok(q)  => q,
        Err(e) => return err_atom(env, &format!("Invalid query JSON: {}", e)),
    };

    let space_str = query["space"].as_str().unwrap_or("core");
    let space = match Space::try_from(space_str) {
        Ok(s)  => s,
        Err(e) => return err_atom(env, &e.to_string()),
    };

    let start = query["start_micros"].as_i64()
        .and_then(|ts| chrono::DateTime::from_timestamp_micros(ts));
    let end   = query["end_micros"].as_i64()
        .and_then(|ts| chrono::DateTime::from_timestamp_micros(ts));
    let cat   = query["category"].as_str();
    let stat  = query["status"].as_str();
    let limit = query["limit"].as_u64().unwrap_or(100) as usize;

    runtime().block_on(async {
        let store = match EventStore::new(&base_path, &did).await {
            Ok(s)  => s,
            Err(e) => return err_atom(env, &e.to_string()),
        };
        match store.list(&space, start, end, cat, stat, limit).await {
            Ok(events) => ok_json(env, &events),
            Err(e)     => err_atom(env, &e.to_string()),
        }
    })
}

/// update_event(base_path, did, event_json) -> {:ok, id} | {:error, reason}
#[rustler::nif(schedule = "DirtyIo")]
fn update_event<'a>(env: Env<'a>, base_path: String, did: String, event_json: String) -> Term<'a> {
    let event: CalendarEvent = match serde_json::from_str(&event_json) {
        Ok(e)  => e,
        Err(e) => return err_atom(env, &format!("Invalid JSON: {}", e)),
    };
    runtime().block_on(async {
        let store = match EventStore::new(&base_path, &did).await {
            Ok(s) => s, Err(e) => return err_atom(env, &e.to_string()),
        };
        match store.update(&event).await {
            Ok(())  => ok_json(env, &event.id),
            Err(e)  => err_atom(env, &e.to_string()),
        }
    })
}

/// cancel_event(base_path, did, event_id, space) -> {:ok, event_json} | {:error, reason}
#[rustler::nif(schedule = "DirtyIo")]
fn cancel_event<'a>(env: Env<'a>, base_path: String, did: String, event_id: String, space_str: String) -> Term<'a> {
    let space = match Space::try_from(space_str.as_str()) {
        Ok(s) => s, Err(e) => return err_atom(env, &e.to_string()),
    };
    runtime().block_on(async {
        let store = match EventStore::new(&base_path, &did).await {
            Ok(s) => s, Err(e) => return err_atom(env, &e.to_string()),
        };
        match store.cancel(&event_id, &space).await {
            Ok(event) => ok_json(env, &event),
            Err(e)    => err_atom(env, &e.to_string()),
        }
    })
}

/// semantic_search_events(base_path, did, space, embedding_json, top_k) -> {:ok, events_json}
#[rustler::nif(schedule = "DirtyCpu")]
fn semantic_search_events<'a>(
    env:            Env<'a>,
    base_path:      String,
    did:            String,
    space_str:      String,
    embedding_json: String,
    top_k:          u32,
) -> Term<'a> {
    let space: Space = match Space::try_from(space_str.as_str()) {
        Ok(s) => s, Err(e) => return err_atom(env, &e.to_string()),
    };
    let embedding: Vec<f32> = match serde_json::from_str(&embedding_json) {
        Ok(e) => e, Err(e) => return err_atom(env, &e.to_string()),
    };
    runtime().block_on(async {
        let store = match EventStore::new(&base_path, &did).await {
            Ok(s) => s, Err(e) => return err_atom(env, &e.to_string()),
        };
        match store.semantic_search(&space, embedding, top_k as usize, None).await {
            Ok(events) => ok_json(env, &events),
            Err(e)     => err_atom(env, &e.to_string()),
        }
    })
}

// ─── TASK NIFs ────────────────────────────────────────────────────────────────

#[rustler::nif(schedule = "DirtyIo")]
fn create_task<'a>(env: Env<'a>, base_path: String, did: String, task_json: String) -> Term<'a> {
    let task: CalendarTask = match serde_json::from_str(&task_json) {
        Ok(t) => t, Err(e) => return err_atom(env, &e.to_string()),
    };
    runtime().block_on(async {
        let store = match TaskStore::new(&base_path, &did).await {
            Ok(s) => s, Err(e) => return err_atom(env, &e.to_string()),
        };
        match store.create(&task).await {
            Ok(id) => ok_json(env, &id),
            Err(e) => err_atom(env, &e.to_string()),
        }
    })
}

#[rustler::nif(schedule = "DirtyIo")]
fn complete_task<'a>(env: Env<'a>, base_path: String, did: String, task_id: String, space_str: String, completed_by: String) -> Term<'a> {
    let space = match Space::try_from(space_str.as_str()) {
        Ok(s) => s, Err(e) => return err_atom(env, &e.to_string()),
    };
    runtime().block_on(async {
        let store = match TaskStore::new(&base_path, &did).await {
            Ok(s) => s, Err(e) => return err_atom(env, &e.to_string()),
        };
        match store.complete(&task_id, &space, &completed_by).await {
            Ok(task) => ok_json(env, &task),
            Err(e)   => err_atom(env, &e.to_string()),
        }
    })
}

// ─── CAS NIFs ─────────────────────────────────────────────────────────────────

/// cas_put(base_path, did, data_binary) -> {:ok, blake3_hash} | {:error, reason}
#[rustler::nif(schedule = "DirtyIo")]
fn cas_put<'a>(env: Env<'a>, base_path: String, did: String, data: Binary) -> Term<'a> {
    let bytes = data.as_slice().to_vec();
    runtime().block_on(async {
        let store = CasStore::new(&base_path, &did);
        match store.put(&bytes).await {
            Ok(hash) => ok_json(env, &hash),
            Err(e)   => err_atom(env, &e.to_string()),
        }
    })
}

/// cas_get(base_path, did, hash) -> {:ok, data_binary} | {:error, reason}
#[rustler::nif(schedule = "DirtyIo")]
fn cas_get<'a>(env: Env<'a>, base_path: String, did: String, hash: String) -> Term<'a> {
    runtime().block_on(async {
        let store = CasStore::new(&base_path, &did);
        match store.get(&hash).await {
            Ok(data) => {
                let mut bin = rustler::OwnedBinary::new(data.len()).unwrap();
                bin.as_mut_slice().copy_from_slice(&data);
                (atoms::ok(), bin.release(env)).encode(env)
            }
            Err(e) => err_atom(env, &e.to_string()),
        }
    })
}

// ─── CAS TABLE NIFs ───────────────────────────────────────────────────────────

/// cas_table_put(base_path, did, data, file_name, mime_type, written_by)
/// -> {:ok, "cas:{hash}"} | {:error, reason}
#[rustler::nif(schedule = "DirtyIo")]
fn cas_table_put<'a>(
    env:        Env<'a>,
    base_path:  String,
    did:        String,
    data:       Binary,
    file_name:  String,
    mime_type:  String,
    written_by: String,
) -> Term<'a> {
    let bytes = data.as_slice().to_vec();
    let fname = if file_name.is_empty() { None } else { Some(file_name.as_str()) };
    let mtype = if mime_type.is_empty()  { None } else { Some(mime_type.as_str()) };
    runtime().block_on(async move {
        match CasTable::open(&base_path, &did).await {
            Err(e)    => err_atom(env, &e.to_string()),
            Ok(table) => match table.put(&bytes, fname, mtype, &written_by).await {
                Ok(link) => ok_json(env, &link),
                Err(e)   => err_atom(env, &e.to_string()),
            },
        }
    })
}

/// cas_table_get_link(base_path, did, hash) -> {:ok, link} | {:error, "not_found"}
#[rustler::nif(schedule = "DirtyIo")]
fn cas_table_get_link<'a>(
    env:       Env<'a>,
    base_path: String,
    did:       String,
    hash:      String,
) -> Term<'a> {
    runtime().block_on(async move {
        match CasTable::open(&base_path, &did).await {
            Err(e)    => err_atom(env, &e.to_string()),
            Ok(table) => match table.get_link(&hash).await {
                Ok(Some(link)) => ok_json(env, &link),
                Ok(None)       => err_atom(env, "not_found"),
                Err(e)         => err_atom(env, &e.to_string()),
            },
        }
    })
}

// ─── RECURRENCE NIFs ──────────────────────────────────────────────────────────

/// expand_rrule(rrule_str, dtstart_micros, tz, range_start_micros, range_end_micros, max)
/// -> {:ok, [micros]} | {:error, reason}
#[rustler::nif(schedule = "DirtyCpu")]
fn expand_rrule<'a>(
    env:               Env<'a>,
    rrule_str:         String,
    dtstart_micros:    i64,
    tz:                String,
    range_start_micros: i64,
    range_end_micros:   i64,
    max:               u32,
) -> Term<'a> {
    let ts = |us: i64| chrono::DateTime::from_timestamp_micros(us).unwrap_or_default();
    match recurrence::expand(
        &rrule_str,
        ts(dtstart_micros),
        &tz,
        ts(range_start_micros),
        ts(range_end_micros),
        max as usize,
    ) {
        Ok(instances) => {
            let micros: Vec<i64> = instances.iter().map(|dt| dt.timestamp_micros()).collect();
            ok_json(env, &micros)
        }
        Err(e) => err_atom(env, &e.to_string()),
    }
}

// ─── ANALYTICS NIFs ───────────────────────────────────────────────────────────

/// calendar_analytics(base_path, did, query_type, params_json) -> {:ok, json} | {:error, reason}
#[rustler::nif(schedule = "DirtyCpu")]
fn calendar_analytics<'a>(
    env:         Env<'a>,
    base_path:   String,
    did:         String,
    query_type:  String,
    params_json: String,
) -> Term<'a> {
    let params: serde_json::Value = match serde_json::from_str(&params_json) {
        Ok(p) => p, Err(e) => return err_atom(env, &e.to_string()),
    };
    let analytics = CalendarAnalytics::new(&base_path, &did);

    let start = params["start_micros"].as_i64().unwrap_or(0);
    let end   = params["end_micros"].as_i64().unwrap_or(i64::MAX);

    match query_type.as_str() {
        "event_count_by_category" => {
            match analytics.event_count_by_category(start, end) {
                Ok(result) => ok_json(env, &result),
                Err(e)     => err_atom(env, &e.to_string()),
            }
        }
        "busy_minutes_by_day" => {
            match analytics.busy_minutes_by_day(start, end) {
                Ok(result) => ok_json(env, &result),
                Err(e)     => err_atom(env, &e.to_string()),
            }
        }
        "task_completion_stats" => {
            match analytics.task_completion_stats(start, end) {
                Ok(result) => ok_json(env, &result),
                Err(e)     => err_atom(env, &e.to_string()),
            }
        }
        "practice_streak" => {
            let title = params["title"].as_str().unwrap_or("");
            match analytics.practice_streak(title) {
                Ok(result) => ok_json(env, &result),
                Err(e)     => err_atom(env, &e.to_string()),
            }
        }
        "meeting_load_by_week" => {
            match analytics.meeting_load_by_week(start, end) {
                Ok(result) => ok_json(env, &result),
                Err(e)     => err_atom(env, &e.to_string()),
            }
        }
        other => err_atom(env, &format!("Unknown query type: {}", other)),
    }
}

// ─── NIF REGISTRATION ────────────────────────────────────────────────────────

rustler::init!("Elixir.PRZMA.Calendar.NIF", [
    create_event, get_event, list_events, update_event, cancel_event,
    semantic_search_events, create_task, complete_task,
    cas_put, cas_get, expand_rrule, calendar_analytics,
    circle_nif::provision_circle_namespace, circle_nif::archive_circle_namespace,
    circle_nif::replicate_event_to_member, circle_nif::remove_event_from_member,
    circle_nif::circle_calendar_summary,
    federation_nif::export_ical, federation_nif::parse_ical_event,
    federation_nif::build_ap_event_object, federation_nif::build_ap_actor,
    federation_nif::build_ap_create_activity, federation_nif::parse_ap_activity,
    intelligence_nif::assemble_pre_brief, intelligence_nif::extract_action_items,
    intelligence_nif::extract_action_items_from_turns, intelligence_nif::save_transcript,
    intelligence_nif::get_transcript_for_event, intelligence_nif::store_transcript_text,
    intelligence_nif::get_transcript_text,
    storage_nif::derive_namespace_key, storage_nif::derive_circle_key,
    storage_nif::encrypt_blob, storage_nif::decrypt_blob,
    storage_nif::detect_storage_mode, storage_nif::local_storage_put,
    storage_nif::local_storage_get, storage_nif::validate_byos_credentials,
    analytics_nif::embed_text, analytics_nif::embed_event,
    analytics_nif::embed_and_update_event, analytics_nif::rank_events_by_similarity,
    analytics_nif::time_distribution, analytics_nif::practice_adherence,
    analytics_nif::meeting_patterns, analytics_nif::generate_insights,
    social_nif::social_insert_membership, social_nif::social_get_role,
    social_nif::social_deactivate_membership, social_nif::social_update_role,
    social_nif::social_list_circles_for, social_nif::social_insert_follower,
    social_nif::social_list_followers, social_nif::social_remove_follower,
    cas_table_put,
    cas_table_get_link,
]);
