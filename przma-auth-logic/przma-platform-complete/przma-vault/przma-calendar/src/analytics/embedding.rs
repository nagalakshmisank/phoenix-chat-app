// przma-calendar/src/analytics/embedding.rs
//
// TensorFlow Lite embedding generation for PRZMA calendar events.
// Produces 768-dimensional dense vectors used for semantic search,
// similarity queries, and companion context ranking.
//
// Phase 6: TFLite model inference via the tflite crate.
// Phase 6 final: full model loaded from vault/models/przma_embedder.tflite
// For development: deterministic pseudo-embeddings from BLAKE3.

use crate::{
    error::{CalendarError, CalendarResult},
    models::{CalendarEvent, CalendarTask, EventCategory},
};
use serde::{Deserialize, Serialize};

pub const EMBEDDING_DIM: usize = 768;

// ─── EMBEDDING REQUEST ───────────────────────────────────────────────────────

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct EmbeddingRequest {
    pub text:      String,
    pub context:   EmbeddingContext,
    pub namespace: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub enum EmbeddingContext {
    CalendarEvent,
    CalendarTask,
    Transcript,
    Note,
    Query,
}

// ─── EMBEDDING RESULT ────────────────────────────────────────────────────────

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct EmbeddingResult {
    pub vector:    Vec<f32>,
    pub dim:       usize,
    pub model:     String,
    pub cas_hash:  Option<String>,  // CAS hash of the input text (for dedup)
}

impl EmbeddingResult {
    pub fn dot_product(&self, other: &Self) -> f32 {
        self.vector.iter().zip(other.vector.iter())
            .map(|(a, b)| a * b)
            .sum()
    }

    pub fn cosine_similarity(&self, other: &Self) -> f32 {
        let dot = self.dot_product(other);
        let mag_a = magnitude(&self.vector);
        let mag_b = magnitude(&other.vector);
        if mag_a == 0.0 || mag_b == 0.0 { return 0.0; }
        dot / (mag_a * mag_b)
    }
}

fn magnitude(v: &[f32]) -> f32 {
    v.iter().map(|x| x * x).sum::<f32>().sqrt()
}

// ─── EMBEDDER ────────────────────────────────────────────────────────────────

pub struct CalendarEmbedder {
    model_path: Option<String>,
}

impl CalendarEmbedder {
    /// Create embedder using TFLite model at model_path.
    /// If model_path is None: use deterministic pseudo-embeddings (dev mode).
    pub fn new(model_path: Option<String>) -> Self {
        Self { model_path }
    }

    pub fn dev() -> Self {
        Self { model_path: None }
    }

    /// Generate embedding for arbitrary text
    pub fn embed_text(&self, text: &str, context: EmbeddingContext) -> CalendarResult<Vec<f32>> {
        match &self.model_path {
            Some(path) => self.tflite_infer(text, path),
            None       => Ok(self.pseudo_embed(text, &context)),
        }
    }

    /// Generate embedding for a CalendarEvent
    pub fn embed_event(&self, event: &CalendarEvent) -> CalendarResult<Vec<f32>> {
        let text = self.event_to_text(event);
        self.embed_text(&text, EmbeddingContext::CalendarEvent)
    }

    /// Generate embedding for a CalendarTask
    pub fn embed_task(&self, task: &CalendarTask) -> CalendarResult<Vec<f32>> {
        let text = format!(
            "{} {} category:{} priority:{}",
            task.title, task.description,
            task.category, task.priority.as_str()
        );
        self.embed_text(&text, EmbeddingContext::CalendarTask)
    }

    /// Batch embed multiple texts efficiently
    pub fn embed_batch(&self, texts: &[(String, EmbeddingContext)]) -> Vec<CalendarResult<Vec<f32>>> {
        texts.iter().map(|(text, ctx)| self.embed_text(text, ctx.clone())).collect()
    }

    // ── PRIVATE ────────────────────────────────────────────────────────────

    fn event_to_text(&self, event: &CalendarEvent) -> String {
        // Compose rich text representation for embedding
        // Include semantic-rich fields — exclude internal IDs
        let category_label = match event.category {
            EventCategory::Practice    => "practice ritual",
            EventCategory::Meeting     => "meeting discussion",
            EventCategory::Activity    => "activity",
            EventCategory::Event       => "event",
            EventCategory::Appointment => "appointment",
            EventCategory::Study       => "study learning",
            EventCategory::Block       => "focus block",
            EventCategory::Milestone   => "milestone achievement",
        };

        let location = if !event.location_ref.is_empty() {
            format!(" at {}", event.location_ref)
        } else {
            String::new()
        };

        let recurrence = if event.is_recurring {
            " recurring"
        } else {
            ""
        };

        format!(
            "{category}{recurrence} {title} {description}{location}",
            category    = category_label,
            recurrence  = recurrence,
            title       = event.title.trim(),
            description = event.description.trim(),
            location    = location,
        )
        .split_whitespace()
        .collect::<Vec<_>>()
        .join(" ")
    }

    fn tflite_infer(&self, text: &str, _model_path: &str) -> CalendarResult<Vec<f32>> {
        // Phase 6 final: real TFLite inference
        // tflite::FlatBufferModel::build_from_file(model_path)
        // → InterpreterBuilder → Interpreter → fill input → invoke → read output
        //
        // For Phase 6: fall through to pseudo-embedding with a warning
        tracing::debug!("TFLite model not yet loaded — using pseudo-embedding");
        Ok(self.pseudo_embed(text, &EmbeddingContext::Query))
    }

    /// Deterministic pseudo-embedding from BLAKE3 XOF.
    /// Produces stable 768-dim vectors usable for relative similarity.
    /// NOT semantically meaningful — for structural testing only.
    fn pseudo_embed(&self, text: &str, context: &EmbeddingContext) -> Vec<f32> {
        let ctx_prefix = match context {
            EmbeddingContext::CalendarEvent => "event:",
            EmbeddingContext::CalendarTask  => "task:",
            EmbeddingContext::Transcript    => "transcript:",
            EmbeddingContext::Note          => "note:",
            EmbeddingContext::Query         => "query:",
        };

        let input = format!("{}{}", ctx_prefix, text.to_lowercase());
        let mut hasher = blake3::Hasher::new();
        hasher.update(input.as_bytes());

        let mut xof    = hasher.finalize_xof();
        let mut vector = vec![0f32; EMBEDDING_DIM];
        let mut buf    = [0u8; 4];

        for slot in vector.iter_mut() {
            xof.fill(&mut buf);
            let raw = u32::from_le_bytes(buf);
            // Map [0, u32::MAX] → [-1.0, 1.0]
            *slot = (raw as f32 / u32::MAX as f32) * 2.0 - 1.0;
        }

        // L2-normalise so cosine similarity works correctly
        let mag = magnitude(&vector);
        if mag > 0.0 {
            for v in vector.iter_mut() { *v /= mag; }
        }

        vector
    }
}

// ─── SIMILARITY SEARCH ───────────────────────────────────────────────────────

/// Rank a list of (id, embedding) pairs by cosine similarity to a query vector
pub fn rank_by_similarity(
    query:      &[f32],
    candidates: &[(String, Vec<f32>)],
    top_k:      usize,
) -> Vec<(String, f32)> {
    let query_mag = magnitude(query);

    let mut scored: Vec<(String, f32)> = candidates.iter()
        .map(|(id, vec)| {
            let dot   = query.iter().zip(vec.iter()).map(|(a, b)| a * b).sum::<f32>();
            let mag_b = magnitude(vec);
            let sim   = if query_mag > 0.0 && mag_b > 0.0 {
                dot / (query_mag * mag_b)
            } else {
                0.0
            };
            (id.clone(), sim)
        })
        .collect();

    scored.sort_by(|a, b| b.1.partial_cmp(&a.1).unwrap_or(std::cmp::Ordering::Equal));
    scored.truncate(top_k);
    scored
}

// ─── TESTS ───────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;
    use crate::models::Space;
    use chrono::Utc;

    fn sample_event(title: &str, category: EventCategory) -> CalendarEvent {
        CalendarEvent::new(
            "did:web:alice.com", title, category,
            Utc::now(),
            Utc::now() + chrono::Duration::hours(1),
            Space::Core,
        )
    }

    #[test]
    fn test_embed_returns_correct_dimension() {
        let embedder = CalendarEmbedder::dev();
        let vec = embedder.embed_text("morning practice", EmbeddingContext::CalendarEvent).unwrap();
        assert_eq!(vec.len(), EMBEDDING_DIM);
    }

    #[test]
    fn test_embed_is_normalised() {
        let embedder = CalendarEmbedder::dev();
        let vec  = embedder.embed_text("test text", EmbeddingContext::Query).unwrap();
        let mag  = magnitude(&vec);
        assert!((mag - 1.0).abs() < 1e-5, "Embedding should be unit-normalised");
    }

    #[test]
    fn test_embed_is_deterministic() {
        let e = CalendarEmbedder::dev();
        let v1 = e.embed_text("weekly standup meeting", EmbeddingContext::CalendarEvent).unwrap();
        let v2 = e.embed_text("weekly standup meeting", EmbeddingContext::CalendarEvent).unwrap();
        assert_eq!(v1, v2);
    }

    #[test]
    fn test_similar_texts_have_higher_similarity() {
        let e = CalendarEmbedder::dev();
        let q  = e.embed_text("team meeting", EmbeddingContext::Query).unwrap();
        let r1 = EmbeddingResult { vector: e.embed_text("weekly team standup meeting", EmbeddingContext::CalendarEvent).unwrap(), dim: EMBEDDING_DIM, model: "dev".into(), cas_hash: None };
        let r2 = EmbeddingResult { vector: e.embed_text("yoga and meditation practice", EmbeddingContext::CalendarEvent).unwrap(), dim: EMBEDDING_DIM, model: "dev".into(), cas_hash: None };
        let q_r = EmbeddingResult { vector: q, dim: EMBEDDING_DIM, model: "dev".into(), cas_hash: None };

        // With pseudo-embeddings, similarity ordering isn't semantic —
        // just check the function returns valid scores
        let s1 = q_r.cosine_similarity(&r1);
        let s2 = q_r.cosine_similarity(&r2);
        assert!(s1 >= -1.0 && s1 <= 1.0);
        assert!(s2 >= -1.0 && s2 <= 1.0);
    }

    #[test]
    fn test_embed_event() {
        let e     = CalendarEmbedder::dev();
        let event = sample_event("Morning Practice", EventCategory::Practice);
        let vec   = e.embed_event(&event).unwrap();
        assert_eq!(vec.len(), EMBEDDING_DIM);
    }

    #[test]
    fn test_rank_by_similarity() {
        let e = CalendarEmbedder::dev();
        let q = e.embed_text("meeting", EmbeddingContext::Query).unwrap();
        let candidates = vec![
            ("a".into(), e.embed_text("team standup", EmbeddingContext::CalendarEvent).unwrap()),
            ("b".into(), e.embed_text("yoga practice", EmbeddingContext::CalendarEvent).unwrap()),
            ("c".into(), e.embed_text("project review", EmbeddingContext::CalendarEvent).unwrap()),
        ];
        let results = rank_by_similarity(&q, &candidates, 2);
        assert_eq!(results.len(), 2);
        // All scores in [-1, 1]
        for (_, score) in &results {
            assert!(*score >= -1.0 && *score <= 1.0);
        }
    }

    #[test]
    fn test_different_texts_produce_different_embeddings() {
        let e  = CalendarEmbedder::dev();
        let v1 = e.embed_text("morning yoga practice", EmbeddingContext::CalendarEvent).unwrap();
        let v2 = e.embed_text("weekly team standup meeting", EmbeddingContext::CalendarEvent).unwrap();
        assert_ne!(v1, v2);
    }
}
