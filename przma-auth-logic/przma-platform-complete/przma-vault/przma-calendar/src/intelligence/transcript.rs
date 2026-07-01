// przma-calendar/src/intelligence/transcript.rs
//
// Meeting transcript storage and retrieval.
// Transcripts are stored as CAS blobs with Lance metadata.
// Per-event, per-user — never centralised.

use crate::{
    cas::CasStore,
    error::{CalendarError, CalendarResult},
    models::Space,
    schema::table_path,
};
use arrow_array::{BooleanArray, Int32Array, Int64Array, RecordBatch, StringArray};
use arrow_schema::{DataType, Field, Fields, Schema};
use chrono::{DateTime, Utc};
use futures::TryStreamExt;
use lancedb::{connect, query::QueryBase, Connection};
use serde::{Deserialize, Serialize};
use std::sync::Arc;

// ─── TRANSCRIPT SCHEMA ───────────────────────────────────────────────────────

pub fn transcript_schema() -> Arc<Schema> {
    Arc::new(Schema::new(Fields::from(vec![
        Field::new("id",              DataType::Utf8, false),
        Field::new("event_id",        DataType::Utf8, false),
        Field::new("did",             DataType::Utf8, false),
        Field::new("space",           DataType::Utf8, false),
        Field::new("audio_cas",       DataType::Utf8, true),   // CAS hash of raw audio
        Field::new("text_cas",        DataType::Utf8, false),  // CAS hash of transcript text
        Field::new("language",        DataType::Utf8, false),
        Field::new("status",          DataType::Utf8, false),  // pending|processing|complete|failed
        Field::new("duration_secs",   DataType::Int32, false),
        Field::new("word_count",      DataType::Int32, false),
        Field::new("speaker_count",   DataType::Int32, false),
        Field::new("turns_json",      DataType::Utf8, false),  // JSON array of SpeakerTurn
        Field::new("summary_cas",     DataType::Utf8, true),   // CAS hash of companion summary
        Field::new("action_items_json", DataType::Utf8, false),
        Field::new("is_shared",       DataType::Boolean, false),
        Field::new("shared_with_json",DataType::Utf8, false),
        Field::new("created_at",      DataType::Int64, false),
        Field::new("updated_at",      DataType::Int64, false),
    ])))
}

// ─── DOMAIN TYPES ────────────────────────────────────────────────────────────

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SpeakerTurn {
    pub speaker_label: String,          // "Speaker 1", "Alice", etc.
    pub speaker_did:   Option<String>,  // resolved DID if known
    pub start_secs:    f32,
    pub end_secs:      f32,
    pub text:          String,
    pub confidence:    f32,             // 0.0–1.0
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Transcript {
    pub id:             String,
    pub event_id:       String,
    pub did:            String,
    pub space:          String,
    pub audio_cas:      Option<String>,
    pub text_cas:       String,
    pub language:       String,
    pub status:         String,
    pub duration_secs:  i32,
    pub word_count:     i32,
    pub speaker_count:  i32,
    pub turns:          Vec<SpeakerTurn>,
    pub summary_cas:    Option<String>,
    pub action_items:   Vec<ExtractedActionItem>,
    pub is_shared:      bool,
    pub shared_with:    Vec<String>,
    pub created_at:     DateTime<Utc>,
    pub updated_at:     DateTime<Utc>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ExtractedActionItem {
    pub text:          String,
    pub assignee_hint: Option<String>,  // name or DID mention in transcript
    pub due_hint:      Option<String>,  // "by Friday", "next week"
    pub confidence:    f32,
    pub start_secs:    f32,             // position in transcript
    pub confirmed:     bool,            // user confirmed as real task
}

// ─── TRANSCRIPT STORE ────────────────────────────────────────────────────────

pub struct TranscriptStore {
    conn:      Connection,
    base_path: String,
    did:       String,
}

impl TranscriptStore {
    pub async fn new(base_path: impl Into<String>, did: impl Into<String>) -> CalendarResult<Self> {
        let base_path = base_path.into();
        let did       = did.into();
        let conn      = connect(&base_path).execute().await?;
        Ok(Self { conn, base_path, did })
    }

    fn path(&self) -> String {
        format!("{}/{}/calendar/core/transcripts", self.base_path, self.did)
    }

    async fn open_or_create(&self) -> CalendarResult<lancedb::Table> {
        let path = self.path();
        match self.conn.open_table(&path).execute().await {
            Ok(t)  => Ok(t),
            Err(_) => Ok(self.conn.create_empty_table(&path, transcript_schema()).execute().await?),
        }
    }

    /// Store a completed transcript.
    /// The text content is stored in CAS; only metadata goes in Lance.
    pub async fn save(&self, transcript: &Transcript) -> CalendarResult<String> {
        let table           = self.open_or_create().await?;
        let turns_json      = serde_json::to_string(&transcript.turns)?;
        let action_json     = serde_json::to_string(&transcript.action_items)?;
        let shared_with_json = serde_json::to_string(&transcript.shared_with)?;

        let batch = RecordBatch::try_new(transcript_schema(), vec![
            Arc::new(StringArray::from(vec![transcript.id.as_str()])),
            Arc::new(StringArray::from(vec![transcript.event_id.as_str()])),
            Arc::new(StringArray::from(vec![transcript.did.as_str()])),
            Arc::new(StringArray::from(vec![transcript.space.as_str()])),
            Arc::new(StringArray::from(vec![transcript.audio_cas.as_deref()])),
            Arc::new(StringArray::from(vec![transcript.text_cas.as_str()])),
            Arc::new(StringArray::from(vec![transcript.language.as_str()])),
            Arc::new(StringArray::from(vec![transcript.status.as_str()])),
            Arc::new(Int32Array::from(vec![transcript.duration_secs])),
            Arc::new(Int32Array::from(vec![transcript.word_count])),
            Arc::new(Int32Array::from(vec![transcript.speaker_count])),
            Arc::new(StringArray::from(vec![turns_json.as_str()])),
            Arc::new(StringArray::from(vec![transcript.summary_cas.as_deref()])),
            Arc::new(StringArray::from(vec![action_json.as_str()])),
            Arc::new(BooleanArray::from(vec![transcript.is_shared])),
            Arc::new(StringArray::from(vec![shared_with_json.as_str()])),
            Arc::new(Int64Array::from(vec![transcript.created_at.timestamp_micros()])),
            Arc::new(Int64Array::from(vec![transcript.updated_at.timestamp_micros()])),
        ]).map_err(|e| CalendarError::Arrow(e.to_string()))?;

        table.add(vec![batch]).execute().await?;
        tracing::info!(id = %transcript.id, event_id = %transcript.event_id, "Transcript saved");
        Ok(transcript.id.clone())
    }

    /// Get transcript for an event
    pub async fn get_for_event(&self, event_id: &str) -> CalendarResult<Option<Transcript>> {
        let table   = self.open_or_create().await?;
        let batches: Vec<RecordBatch> = table.query()
            .filter(format!("event_id = '{}'", event_id))
            .limit(1)
            .execute().await?
            .try_collect().await
            .map_err(|e| CalendarError::Arrow(e.to_string()))?;

        Ok(batches.into_iter().next()
            .and_then(|b| batch_to_transcripts(b).ok())
            .and_then(|mut v| v.pop()))
    }

    /// Store raw audio in CAS and return hash
    pub async fn store_audio(&self, audio_bytes: &[u8]) -> CalendarResult<String> {
        let cas = CasStore::new(&self.base_path, &self.did);
        cas.put(audio_bytes).await
    }

    /// Store transcript text in CAS and return hash
    pub async fn store_text(&self, text: &str) -> CalendarResult<String> {
        let cas = CasStore::new(&self.base_path, &self.did);
        cas.put(text.as_bytes()).await
    }

    /// Retrieve transcript text by CAS hash
    pub async fn get_text(&self, cas_hash: &str) -> CalendarResult<String> {
        let cas   = CasStore::new(&self.base_path, &self.did);
        let bytes = cas.get(cas_hash).await?;
        String::from_utf8(bytes).map_err(|e| CalendarError::Cas(e.to_string()))
    }
}

fn batch_to_transcripts(batch: RecordBatch) -> CalendarResult<Vec<Transcript>> {
    let num_rows = batch.num_rows();
    let mut transcripts = Vec::with_capacity(num_rows);
    macro_rules! strs { ($n:expr) => { batch.column_by_name($n).unwrap()
        .as_any().downcast_ref::<StringArray>().unwrap() }; }
    macro_rules! i64s { ($n:expr) => { batch.column_by_name($n).unwrap()
        .as_any().downcast_ref::<Int64Array>().unwrap() }; }
    macro_rules! i32s { ($n:expr) => { batch.column_by_name($n).unwrap()
        .as_any().downcast_ref::<Int32Array>().unwrap() }; }
    macro_rules! bools { ($n:expr) => { batch.column_by_name($n).unwrap()
        .as_any().downcast_ref::<BooleanArray>().unwrap() }; }

    let ts = |v: i64| DateTime::from_timestamp_micros(v).unwrap_or_default();

    for i in 0..num_rows {
        let turns: Vec<SpeakerTurn>          = serde_json::from_str(strs!("turns_json").value(i)).unwrap_or_default();
        let action_items: Vec<ExtractedActionItem> = serde_json::from_str(strs!("action_items_json").value(i)).unwrap_or_default();
        let shared_with: Vec<String>          = serde_json::from_str(strs!("shared_with_json").value(i)).unwrap_or_default();

        transcripts.push(Transcript {
            id:           strs!("id").value(i).to_string(),
            event_id:     strs!("event_id").value(i).to_string(),
            did:          strs!("did").value(i).to_string(),
            space:        strs!("space").value(i).to_string(),
            audio_cas:    if batch.column_by_name("audio_cas").unwrap().is_null(i) { None }
                          else { Some(strs!("audio_cas").value(i).to_string()) },
            text_cas:     strs!("text_cas").value(i).to_string(),
            language:     strs!("language").value(i).to_string(),
            status:       strs!("status").value(i).to_string(),
            duration_secs: i32s!("duration_secs").value(i),
            word_count:    i32s!("word_count").value(i),
            speaker_count: i32s!("speaker_count").value(i),
            turns,
            summary_cas:  if batch.column_by_name("summary_cas").unwrap().is_null(i) { None }
                          else { Some(strs!("summary_cas").value(i).to_string()) },
            action_items,
            is_shared:    bools!("is_shared").value(i),
            shared_with,
            created_at:   ts(i64s!("created_at").value(i)),
            updated_at:   ts(i64s!("updated_at").value(i)),
        });
    }
    Ok(transcripts)
}

#[cfg(test)]
mod tests {
    use super::*;
    use tempfile::tempdir;

    #[test]
    fn test_speaker_turn_serialization() {
        let turn = SpeakerTurn {
            speaker_label: "Alice".to_string(),
            speaker_did:   Some("did:web:alice.com".to_string()),
            start_secs:    0.0,
            end_secs:      5.2,
            text:          "We should follow up on the proposal.".to_string(),
            confidence:    0.95,
        };
        let json  = serde_json::to_string(&turn).unwrap();
        let back: SpeakerTurn = serde_json::from_str(&json).unwrap();
        assert_eq!(back.text, turn.text);
        assert!((back.confidence - 0.95).abs() < 0.001);
    }

    #[test]
    fn test_extracted_action_item() {
        let item = ExtractedActionItem {
            text:          "Send contract draft".to_string(),
            assignee_hint: Some("Alice".to_string()),
            due_hint:      Some("by Friday".to_string()),
            confidence:    0.87,
            start_secs:    42.5,
            confirmed:     false,
        };
        let json = serde_json::to_string(&item).unwrap();
        let back: ExtractedActionItem = serde_json::from_str(&json).unwrap();
        assert_eq!(back.text, "Send contract draft");
        assert_eq!(back.due_hint, Some("by Friday".to_string()));
    }

    #[tokio::test]
    async fn test_store_and_retrieve_text() {
        let dir   = tempdir().unwrap();
        let store = TranscriptStore::new(dir.path().to_str().unwrap(), "did:web:alice.com")
            .await.unwrap();
        let text  = "Alice: We should follow up on the proposal.\nBob: Agreed.";
        let hash  = store.store_text(text).await.unwrap();
        let back  = store.get_text(&hash).await.unwrap();
        assert_eq!(back, text);
    }
}
