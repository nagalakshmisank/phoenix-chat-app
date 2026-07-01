// przma-nif/src/federation_nif.rs
//
// Rustler NIFs for federation — iCal export and ActivityPub serialization.

use przma_calendar::{
    events::EventStore,
    federation::{
        activitypub,
        ical,
    },
    models::Space,
    tasks::TaskStore,
};
use rustler::{Encoder, Env, Term};

use crate::{atoms, err_atom, ok_json, runtime};

/// export_ical(base_path, did, query_json, calendar_name) -> {:ok, ical_string}
/// query_json: { space, start_micros, end_micros, include_tasks }
#[rustler::nif(schedule = "DirtyCpu")]
pub fn export_ical<'a>(
    env:           Env<'a>,
    base_path:     String,
    did:           String,
    query_json:    String,
    calendar_name: String,
) -> Term<'a> {
    let query: serde_json::Value = match serde_json::from_str(&query_json) {
        Ok(q)  => q,
        Err(e) => return err_atom(env, &e.to_string()),
    };

    let space_str     = query["space"].as_str().unwrap_or("core");
    let space         = match Space::try_from(space_str) {
        Ok(s)  => s,
        Err(e) => return err_atom(env, &e.to_string()),
    };
    let start         = query["start_micros"].as_i64()
        .and_then(|ts| chrono::DateTime::from_timestamp_micros(ts));
    let end           = query["end_micros"].as_i64()
        .and_then(|ts| chrono::DateTime::from_timestamp_micros(ts));
    let include_tasks = query["include_tasks"].as_bool().unwrap_or(true);
    let timezone      = query["timezone"].as_str().unwrap_or("UTC");

    runtime().block_on(async move {
        let event_store = match EventStore::new(&base_path, &did).await {
            Ok(s)  => s,
            Err(e) => return err_atom(env, &e.to_string()),
        };

        let events = match event_store.list(&space, start, end, None, Some("confirmed"), 1000).await {
            Ok(e)  => e,
            Err(e) => return err_atom(env, &e.to_string()),
        };

        let tasks = if include_tasks {
            let task_store = match TaskStore::new(&base_path, &did).await {
                Ok(s)  => s,
                Err(e) => return err_atom(env, &e.to_string()),
            };
            task_store.list(&space, None, None, 500).await.unwrap_or_default()
        } else {
            vec![]
        };

        let ical_str = ical::export_events(&events, &tasks, &calendar_name, timezone);
        ok_json(env, &ical_str)
    })
}

/// parse_ical_event(ical_string) -> {:ok, props_json} | {:error, reason}
/// Returns list of {key, value} pairs from first VEVENT block
#[rustler::nif(schedule = "DirtyCpu")]
pub fn parse_ical_event<'a>(env: Env<'a>, ical_str: String) -> Term<'a> {
    let props = ical::parse_vevent(&ical_str);
    let map: std::collections::HashMap<String, String> = props.into_iter().collect();
    ok_json(env, &map)
}

/// build_ap_event_object(event_json, instance_url) -> {:ok, json_string}
#[rustler::nif(schedule = "DirtyCpu")]
pub fn build_ap_event_object<'a>(
    env:          Env<'a>,
    event_json:   String,
    instance_url: String,
) -> Term<'a> {
    let event = match serde_json::from_str(&event_json) {
        Ok(e)  => e,
        Err(e) => return err_atom(env, &format!("Invalid JSON: {}", e)),
    };
    let obj = activitypub::build_event_object(&event, &instance_url);
    ok_json(env, &obj)
}

/// build_ap_actor(did, display_name, instance_url, public_key_pem) -> {:ok, json_string}
#[rustler::nif(schedule = "DirtyCpu")]
pub fn build_ap_actor<'a>(
    env:            Env<'a>,
    did:            String,
    display_name:   String,
    instance_url:   String,
    public_key_pem: String,
) -> Term<'a> {
    let actor = activitypub::build_actor(&did, &display_name, &instance_url, &public_key_pem);
    ok_json(env, &actor)
}

/// build_ap_create_activity(event_object_json, actor_url, activity_id) -> {:ok, json_string}
#[rustler::nif(schedule = "DirtyCpu")]
pub fn build_ap_create_activity<'a>(
    env:              Env<'a>,
    event_object_json: String,
    actor_url:         String,
    activity_id:       String,
) -> Term<'a> {
    let obj = match serde_json::from_str(&event_object_json) {
        Ok(o)  => o,
        Err(e) => return err_atom(env, &e.to_string()),
    };
    let activity = activitypub::build_create_activity(&obj, &actor_url, &activity_id);
    ok_json(env, &activity)
}

/// parse_ap_activity(json_string) -> {:ok, inbound_event_json} | {:error, reason}
#[rustler::nif(schedule = "DirtyCpu")]
pub fn parse_ap_activity<'a>(env: Env<'a>, json_str: String) -> Term<'a> {
    let body: serde_json::Value = match serde_json::from_str(&json_str) {
        Ok(b)  => b,
        Err(e) => return err_atom(env, &e.to_string()),
    };
    match activitypub::parse_inbound_activity(&body) {
        Some(ev) => ok_json(env, &ev),
        None     => err_atom(env, "Could not parse ActivityPub activity"),
    }
}
