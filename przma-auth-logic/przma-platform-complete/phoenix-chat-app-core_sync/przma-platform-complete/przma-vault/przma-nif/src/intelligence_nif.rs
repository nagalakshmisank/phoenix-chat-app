// przma-nif/src/intelligence_nif.rs

use przma_calendar::{
    intelligence::{
        action_items::{ActionItemExtractor, deduplicate},
        pre_brief::PreBriefAssembler,
        transcript::{Transcript, TranscriptStore},
    },
    events::EventStore,
    models::Space,
};
use rustler::{Encoder, Env, Term};
use crate::{atoms, err_atom, ok_json, runtime};

/// assemble_pre_brief(base_path, did, event_json) -> {:ok, pre_brief_json}
#[rustler::nif(schedule = "DirtyIo")]
pub fn assemble_pre_brief<'a>(
    env:        Env<'a>,
    base_path:  String,
    did:        String,
    event_json: String,
) -> Term<'a> {
    let event = match serde_json::from_str(&event_json) {
        Ok(e)  => e,
        Err(e) => return err_atom(env, &format!("Invalid JSON: {}", e)),
    };
    runtime().block_on(async {
        let assembler = PreBriefAssembler::new(&base_path, &did);
        match assembler.assemble(&event).await {
            Ok(brief) => ok_json(env, &brief),
            Err(e)    => err_atom(env, &e.to_string()),
        }
    })
}

/// extract_action_items(text) -> {:ok, items_json}
#[rustler::nif(schedule = "DirtyCpu")]
pub fn extract_action_items<'a>(env: Env<'a>, text: String) -> Term<'a> {
    let extractor = ActionItemExtractor::new();
    let items     = extractor.extract_from_text(&text);
    let deduped   = deduplicate(items);
    ok_json(env, &deduped)
}

/// extract_action_items_from_turns(turns_json) -> {:ok, items_json}
#[rustler::nif(schedule = "DirtyCpu")]
pub fn extract_action_items_from_turns<'a>(env: Env<'a>, turns_json: String) -> Term<'a> {
    let turns = match serde_json::from_str(&turns_json) {
        Ok(t)  => t,
        Err(e) => return err_atom(env, &e.to_string()),
    };
    let extractor = ActionItemExtractor::new();
    let items     = extractor.extract_from_turns(&turns);
    let deduped   = deduplicate(items);
    ok_json(env, &deduped)
}

/// save_transcript(base_path, did, transcript_json) -> {:ok, id}
#[rustler::nif(schedule = "DirtyIo")]
pub fn save_transcript<'a>(
    env:             Env<'a>,
    base_path:       String,
    did:             String,
    transcript_json: String,
) -> Term<'a> {
    let transcript: Transcript = match serde_json::from_str(&transcript_json) {
        Ok(t)  => t,
        Err(e) => return err_atom(env, &format!("Invalid JSON: {}", e)),
    };
    runtime().block_on(async {
        let store = match TranscriptStore::new(&base_path, &did).await {
            Ok(s)  => s,
            Err(e) => return err_atom(env, &e.to_string()),
        };
        match store.save(&transcript).await {
            Ok(id)  => ok_json(env, &id),
            Err(e)  => err_atom(env, &e.to_string()),
        }
    })
}

/// get_transcript_for_event(base_path, did, event_id) -> {:ok, transcript_json} | {:error, :not_found}
#[rustler::nif(schedule = "DirtyIo")]
pub fn get_transcript_for_event<'a>(
    env:       Env<'a>,
    base_path: String,
    did:       String,
    event_id:  String,
) -> Term<'a> {
    runtime().block_on(async {
        let store = match TranscriptStore::new(&base_path, &did).await {
            Ok(s)  => s,
            Err(e) => return err_atom(env, &e.to_string()),
        };
        match store.get_for_event(&event_id).await {
            Ok(Some(t)) => ok_json(env, &t),
            Ok(None)    => (atoms::error(), "not_found").encode(env),
            Err(e)      => err_atom(env, &e.to_string()),
        }
    })
}

/// store_transcript_text(base_path, did, text) -> {:ok, cas_hash}
#[rustler::nif(schedule = "DirtyIo")]
pub fn store_transcript_text<'a>(
    env:       Env<'a>,
    base_path: String,
    did:       String,
    text:      String,
) -> Term<'a> {
    runtime().block_on(async {
        let store = match TranscriptStore::new(&base_path, &did).await {
            Ok(s)  => s,
            Err(e) => return err_atom(env, &e.to_string()),
        };
        match store.store_text(&text).await {
            Ok(hash) => ok_json(env, &hash),
            Err(e)   => err_atom(env, &e.to_string()),
        }
    })
}

/// get_transcript_text(base_path, did, cas_hash) -> {:ok, text}
#[rustler::nif(schedule = "DirtyIo")]
pub fn get_transcript_text<'a>(
    env:       Env<'a>,
    base_path: String,
    did:       String,
    cas_hash:  String,
) -> Term<'a> {
    runtime().block_on(async {
        let store = match TranscriptStore::new(&base_path, &did).await {
            Ok(s)  => s,
            Err(e) => return err_atom(env, &e.to_string()),
        };
        match store.get_text(&cas_hash).await {
            Ok(text) => ok_json(env, &text),
            Err(e)   => err_atom(env, &e.to_string()),
        }
    })
}
