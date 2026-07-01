// przma-nif/src/circle_nif.rs
//
// Circle-specific NIF functions — add these to the main lib.rs init! block.
// Included via mod circle_nif in lib.rs.

use przma_calendar::circle::{
    CircleCalendarNamespace, CircleCalendarSummary, CircleReplicator,
};
use rustler::{Env, NifResult, Term};

use crate::{atoms, err_atom, ok_json, runtime};

/// provision_circle_namespace(base_path, member_did, circle_did)
/// -> {:ok, %{tables_created: n}} | {:error, reason}
#[rustler::nif(schedule = "DirtyIo")]
pub fn provision_circle_namespace<'a>(
    env:        Env<'a>,
    base_path:  String,
    member_did: String,
    circle_did: String,
) -> Term<'a> {
    runtime().block_on(async {
        let ns     = CircleCalendarNamespace::new(&base_path, &member_did, &circle_did);
        match ns.provision().await {
            Ok(result) => ok_json(env, &serde_json::json!({
                "circle_did":     result.circle_did,
                "member_did":     result.member_did,
                "tables_created": result.tables_created,
            })),
            Err(e) => err_atom(env, &e.to_string()),
        }
    })
}

/// archive_circle_namespace(base_path, member_did, circle_did)
/// -> :ok | {:error, reason}
#[rustler::nif(schedule = "DirtyIo")]
pub fn archive_circle_namespace<'a>(
    env:        Env<'a>,
    base_path:  String,
    member_did: String,
    circle_did: String,
) -> Term<'a> {
    runtime().block_on(async {
        let ns = CircleCalendarNamespace::new(&base_path, &member_did, &circle_did);
        match ns.archive().await {
            Ok(())  => atoms::ok().encode(env),
            Err(e)  => err_atom(env, &e.to_string()),
        }
    })
}

/// replicate_event_to_member(base_path, event_json, member_did, circle_did)
/// -> {:ok, event_id} | {:error, reason}
#[rustler::nif(schedule = "DirtyIo")]
pub fn replicate_event_to_member<'a>(
    env:        Env<'a>,
    base_path:  String,
    event_json: String,
    member_did: String,
    circle_did: String,
) -> Term<'a> {
    let event = match serde_json::from_str(&event_json) {
        Ok(e)  => e,
        Err(e) => return err_atom(env, &format!("Invalid JSON: {}", e)),
    };
    runtime().block_on(async {
        let replicator = CircleReplicator::new(&base_path);
        match replicator.write_event_to_member(&event, &member_did, &circle_did).await {
            Ok(id)  => ok_json(env, &id),
            Err(e)  => err_atom(env, &e.to_string()),
        }
    })
}

/// remove_event_from_member(base_path, event_id, member_did, circle_did)
/// -> :ok | {:error, reason}
#[rustler::nif(schedule = "DirtyIo")]
pub fn remove_event_from_member<'a>(
    env:        Env<'a>,
    base_path:  String,
    event_id:   String,
    member_did: String,
    circle_did: String,
) -> Term<'a> {
    runtime().block_on(async {
        let replicator = CircleReplicator::new(&base_path);
        match replicator.remove_event_from_member(&event_id, &member_did, &circle_did).await {
            Ok(())  => atoms::ok().encode(env),
            Err(e)  => err_atom(env, &e.to_string()),
        }
    })
}

/// circle_calendar_summary(base_path, member_did, circle_did)
/// -> {:ok, summary_json} | {:error, reason}
#[rustler::nif(schedule = "DirtyIo")]
pub fn circle_calendar_summary<'a>(
    env:        Env<'a>,
    base_path:  String,
    member_did: String,
    circle_did: String,
) -> Term<'a> {
    runtime().block_on(async {
        match CircleCalendarSummary::compute(&base_path, &member_did, &circle_did).await {
            Ok(summary) => ok_json(env, &summary),
            Err(e)      => err_atom(env, &e.to_string()),
        }
    })
}
