// przma-nif/src/analytics_nif.rs
//
// Phase 6 analytics NIFs — embedding generation and pattern analysis.

use przma_calendar::{
    analytics::{
        embedding::{CalendarEmbedder, EmbeddingContext, rank_by_similarity},
        patterns::PatternAnalyser,
    },
    events::EventStore,
    tasks::TaskStore,
    models::Space,
};
use rustler::{Encoder, Env, Term};
use crate::{atoms, err_atom, ok_json, runtime};

// ─── EMBEDDING NIFs ──────────────────────────────────────────────────────────

/// embed_text(text, context) -> {:ok, vector_json}
/// context: "event" | "task" | "transcript" | "note" | "query"
#[rustler::nif(schedule = "DirtyCpu")]
pub fn embed_text<'a>(env: Env<'a>, text: String, context: String) -> Term<'a> {
    let ctx = match context.as_str() {
        "event"      => EmbeddingContext::CalendarEvent,
        "task"       => EmbeddingContext::CalendarTask,
        "transcript" => EmbeddingContext::Transcript,
        "note"       => EmbeddingContext::Note,
        _            => EmbeddingContext::Query,
    };
    let embedder = CalendarEmbedder::dev(); // Phase 6 final: load model path from config
    match embedder.embed_text(&text, ctx) {
        Ok(vec)  => ok_json(env, &vec),
        Err(e)   => err_atom(env, &e.to_string()),
    }
}

/// embed_event(base_path, did, event_id, space) -> {:ok, vector_json}
#[rustler::nif(schedule = "DirtyIo")]
pub fn embed_event<'a>(
    env:       Env<'a>,
    base_path: String,
    did:       String,
    event_id:  String,
    space_str: String,
) -> Term<'a> {
    let space = match przma_calendar::models::Space::try_from(space_str.as_str()) {
        Ok(s)  => s,
        Err(e) => return err_atom(env, &e.to_string()),
    };
    runtime().block_on(async {
        let store    = match EventStore::new(&base_path, &did).await {
            Ok(s)  => s,
            Err(e) => return err_atom(env, &e.to_string()),
        };
        let event    = match store.get(&event_id, &space).await {
            Ok(e)  => e,
            Err(e) => return err_atom(env, &e.to_string()),
        };
        let embedder = CalendarEmbedder::dev();
        match embedder.embed_event(&event) {
            Ok(vec)  => ok_json(env, &vec),
            Err(e)   => err_atom(env, &e.to_string()),
        }
    })
}

/// embed_and_update_event(base_path, did, event_id, space)
/// Computes embedding and writes it back to the event record in Lance.
#[rustler::nif(schedule = "DirtyIo")]
pub fn embed_and_update_event<'a>(
    env:       Env<'a>,
    base_path: String,
    did:       String,
    event_id:  String,
    space_str: String,
) -> Term<'a> {
    let space = match przma_calendar::models::Space::try_from(space_str.as_str()) {
        Ok(s)  => s,
        Err(e) => return err_atom(env, &e.to_string()),
    };
    runtime().block_on(async {
        let store    = match EventStore::new(&base_path, &did).await {
            Ok(s)  => s,
            Err(e) => return err_atom(env, &e.to_string()),
        };
        let mut event = match store.get(&event_id, &space).await {
            Ok(e)  => e,
            Err(e) => return err_atom(env, &e.to_string()),
        };
        let embedder = CalendarEmbedder::dev();
        match embedder.embed_event(&event) {
            Ok(vec) => {
                event.embedding = vec;
                event.version  += 1;
                event.updated_at = chrono::Utc::now();
                match store.update(&event).await {
                    Ok(())  => ok_json(env, &event.id),
                    Err(e)  => err_atom(env, &e.to_string()),
                }
            }
            Err(e) => err_atom(env, &e.to_string()),
        }
    })
}

/// rank_events_by_similarity(candidates_json, query_vector_json, top_k)
/// candidates_json: [{"id": "...", "embedding": [...]}]
#[rustler::nif(schedule = "DirtyCpu")]
pub fn rank_events_by_similarity<'a>(
    env:               Env<'a>,
    candidates_json:   String,
    query_vector_json: String,
    top_k:             u32,
) -> Term<'a> {
    let candidates: Vec<serde_json::Value> = match serde_json::from_str(&candidates_json) {
        Ok(c)  => c,
        Err(e) => return err_atom(env, &e.to_string()),
    };
    let query: Vec<f32> = match serde_json::from_str(&query_vector_json) {
        Ok(q)  => q,
        Err(e) => return err_atom(env, &e.to_string()),
    };

    let pairs: Vec<(String, Vec<f32>)> = candidates.iter()
        .filter_map(|c| {
            let id  = c["id"].as_str()?.to_string();
            let emb: Vec<f32> = serde_json::from_value(c["embedding"].clone()).ok()?;
            Some((id, emb))
        })
        .collect();

    let ranked = rank_by_similarity(&query, &pairs, top_k as usize);
    ok_json(env, &ranked)
}

// ─── PATTERN ANALYTICS NIFs ──────────────────────────────────────────────────

/// time_distribution(base_path, did, start_micros, end_micros) -> {:ok, json}
#[rustler::nif(schedule = "DirtyCpu")]
pub fn time_distribution<'a>(
    env:          Env<'a>,
    base_path:    String,
    did:          String,
    start_micros: i64,
    end_micros:   i64,
) -> Term<'a> {
    let analyser = PatternAnalyser::new(&base_path, &did);
    match analyser.time_distribution(start_micros, end_micros) {
        Ok(dist) => ok_json(env, &dist),
        Err(e)   => err_atom(env, &e.to_string()),
    }
}

/// practice_adherence(base_path, did, title, start_micros, end_micros) -> {:ok, json}
#[rustler::nif(schedule = "DirtyCpu")]
pub fn practice_adherence<'a>(
    env:          Env<'a>,
    base_path:    String,
    did:          String,
    title:        String,
    start_micros: i64,
    end_micros:   i64,
) -> Term<'a> {
    let analyser = PatternAnalyser::new(&base_path, &did);
    match analyser.practice_adherence(&title, start_micros, end_micros) {
        Ok(adherence) => ok_json(env, &adherence),
        Err(e)        => err_atom(env, &e.to_string()),
    }
}

/// meeting_patterns(base_path, did, start_micros, end_micros) -> {:ok, json}
#[rustler::nif(schedule = "DirtyCpu")]
pub fn meeting_patterns<'a>(
    env:          Env<'a>,
    base_path:    String,
    did:          String,
    start_micros: i64,
    end_micros:   i64,
) -> Term<'a> {
    let analyser = PatternAnalyser::new(&base_path, &did);
    match analyser.meeting_patterns(start_micros, end_micros) {
        Ok(patterns) => ok_json(env, &patterns),
        Err(e)       => err_atom(env, &e.to_string()),
    }
}

/// generate_insights(base_path, did, start_micros, end_micros) -> {:ok, insights_json}
#[rustler::nif(schedule = "DirtyCpu")]
pub fn generate_insights<'a>(
    env:          Env<'a>,
    base_path:    String,
    did:          String,
    start_micros: i64,
    end_micros:   i64,
) -> Term<'a> {
    let analyser = PatternAnalyser::new(&base_path, &did);
    match analyser.generate_insights(start_micros, end_micros) {
        Ok(insights) => ok_json(env, &insights),
        Err(e)       => err_atom(env, &e.to_string()),
    }
}
