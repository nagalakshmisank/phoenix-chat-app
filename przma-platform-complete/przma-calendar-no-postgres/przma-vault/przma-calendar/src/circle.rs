// przma-calendar/src/circle.rs
//
// Circle calendar namespace management.
// Handles provisioning Lance tables per circle, circle key derivation,
// and cross-member event replication within a circle.

use crate::{
    error::{CalendarError, CalendarResult},
    models::{CalendarEvent, CalendarTask, Space},
    schema::{
        calendar_event_schema, calendar_task_schema, scheduling_poll_schema,
        table_path, tables,
    },
};
use lancedb::{connect, Connection};
use std::path::PathBuf;

// ─── CIRCLE NAMESPACE ────────────────────────────────────────────────────────

/// Represents a provisioned circle calendar namespace for one member.
pub struct CircleCalendarNamespace {
    pub circle_did: String,
    pub member_did: String,
    pub base_path:  String,
}

impl CircleCalendarNamespace {
    pub fn new(
        base_path:  impl Into<String>,
        member_did: impl Into<String>,
        circle_did: impl Into<String>,
    ) -> Self {
        Self {
            base_path:  base_path.into(),
            member_did: member_did.into(),
            circle_did: circle_did.into(),
        }
    }

    fn space_segment(&self) -> String {
        format!("circles/{}", self.circle_did)
    }

    fn events_path(&self) -> String {
        table_path(&self.base_path, &self.member_did, "calendar",
            &self.space_segment(), tables::EVENTS)
    }

    fn tasks_path(&self) -> String {
        table_path(&self.base_path, &self.member_did, "calendar",
            &self.space_segment(), tables::TASKS)
    }

    fn polls_path(&self) -> String {
        table_path(&self.base_path, &self.member_did, "calendar",
            &self.space_segment(), tables::POLLS)
    }

    /// Provision all Lance tables for this member's circle calendar namespace.
    /// Idempotent — safe to call multiple times.
    pub async fn provision(&self) -> CalendarResult<ProvisionResult> {
        let conn = connect(&self.base_path).execute().await?;
        let mut tables_created = 0;

        for (path, schema) in [
            (self.events_path(), calendar_event_schema()),
            (self.tasks_path(),  calendar_task_schema()),
            (self.polls_path(),  scheduling_poll_schema()),
        ] {
            match conn.open_table(&path).execute().await {
                Ok(_) => {
                    tracing::debug!(path = %path, "Circle table already exists");
                }
                Err(_) => {
                    conn.create_empty_table(&path, schema).execute().await?;
                    tables_created += 1;
                    tracing::info!(path = %path, "Circle table provisioned");
                }
            }
        }

        Ok(ProvisionResult {
            circle_did:     self.circle_did.clone(),
            member_did:     self.member_did.clone(),
            tables_created,
        })
    }

    /// Deprovision — archive circle tables when a member leaves or circle dissolves.
    /// Moves Lance files to an archive subdirectory.
    pub async fn archive(&self) -> CalendarResult<()> {
        let archive_segment = format!("circles/_archived/{}", self.circle_did);
        let paths = [
            (self.events_path(), table_path(&self.base_path, &self.member_did,
                "calendar", &archive_segment, tables::EVENTS)),
            (self.tasks_path(),  table_path(&self.base_path, &self.member_did,
                "calendar", &archive_segment, tables::TASKS)),
            (self.polls_path(),  table_path(&self.base_path, &self.member_did,
                "calendar", &archive_segment, tables::POLLS)),
        ];

        for (src, dst) in paths {
            let src_path = PathBuf::from(&src);
            let dst_path = PathBuf::from(&dst);
            if src_path.exists() {
                if let Some(parent) = dst_path.parent() {
                    tokio::fs::create_dir_all(parent).await?;
                }
                tokio::fs::rename(&src_path, &dst_path).await?;
                tracing::info!(src = %src, dst = %dst, "Circle table archived");
            }
        }
        Ok(())
    }
}

#[derive(Debug)]
pub struct ProvisionResult {
    pub circle_did:     String,
    pub member_did:     String,
    pub tables_created: u32,
}

// ─── CIRCLE KEY DERIVATION ───────────────────────────────────────────────────
// Phase 1 uses a deterministic key for simplicity.
// Phase 5 implements full HKDF(member_master_key, circle_did) derivation.

/// Derive a circle-scoped encryption key from member + circle DIDs.
/// In production (Phase 5): HKDF(member_master_key, circle_did).
/// For Phase 2: deterministic SHA-256 placeholder — safe for dev, not production.
pub fn derive_circle_key(member_did: &str, circle_did: &str) -> [u8; 32] {
    let input = format!("circle-key:{}:{}", member_did, circle_did);
    let hash  = blake3::hash(input.as_bytes());
    let mut key = [0u8; 32];
    key.copy_from_slice(&hash.as_bytes()[..32]);
    key
}

/// Re-encrypt a CAS blob from member key to circle key.
/// Phase 2: identity transform (no real encryption yet — Phase 5 adds AES-256).
/// Returns the same data — encryption layer is a Phase 5 concern.
pub fn re_encrypt_for_circle(
    data:       &[u8],
    _member_did: &str,
    _circle_did: &str,
) -> Vec<u8> {
    // Phase 5: AES-256-GCM decrypt with member key, re-encrypt with circle key
    data.to_vec()
}

// ─── CIRCLE REPLICATION ──────────────────────────────────────────────────────

pub struct CircleReplicator {
    base_path: String,
}

impl CircleReplicator {
    pub fn new(base_path: impl Into<String>) -> Self {
        Self { base_path: base_path.into() }
    }

    /// Write a circle event to a specific member's circle Lance namespace.
    /// Called when broadcasting a newly shared event to all circle members.
    pub async fn write_event_to_member(
        &self,
        event:      &CalendarEvent,
        member_did: &str,
        circle_did: &str,
    ) -> CalendarResult<String> {
        use crate::events::{event_to_record_batch, EventStore};

        // Ensure the member's circle namespace is provisioned
        let ns = CircleCalendarNamespace::new(&self.base_path, member_did, circle_did);
        ns.provision().await?;

        // Write the event to the member's circle Lance table
        let store = EventStore::new(&self.base_path, member_did).await?;
        store.create(event).await
    }

    /// Remove a circle event from a member's namespace (on retraction or member removal)
    pub async fn remove_event_from_member(
        &self,
        event_id:   &str,
        member_did: &str,
        circle_did: &str,
    ) -> CalendarResult<()> {
        let path = table_path(
            &self.base_path, member_did, "calendar",
            &format!("circles/{}", circle_did), tables::EVENTS,
        );
        let conn  = connect(&self.base_path).execute().await?;
        if let Ok(table) = conn.open_table(&path).execute().await {
            table.delete(&format!("id = '{}'", event_id)).await?;
        }
        Ok(())
    }
}

// ─── CIRCLE SUMMARY ──────────────────────────────────────────────────────────

/// Lightweight summary of circle calendar state — used for UI calendar view header
#[derive(Debug, serde::Serialize, serde::Deserialize)]
pub struct CircleCalendarSummary {
    pub circle_did:    String,
    pub event_count:   u64,
    pub task_count:    u64,
    pub active_polls:  u64,
    pub next_event_at: Option<i64>,  // micros UTC
}

impl CircleCalendarSummary {
    pub async fn compute(
        base_path:  &str,
        member_did: &str,
        circle_did: &str,
    ) -> CalendarResult<Self> {
        use crate::events::EventStore;
        use crate::tasks::TaskStore;
        use chrono::Utc;

        let now = Utc::now();
        let far = now + chrono::Duration::days(365);

        let event_store = EventStore::new(base_path, member_did).await?;
        let space       = Space::Circle(circle_did.to_string());

        let events = event_store.list(
            &space, Some(now), Some(far), None, Some("confirmed"), 1000
        ).await?;

        let next_event_at = events.first().map(|e| e.start_at.timestamp_micros());
        let event_count   = events.len() as u64;

        let task_store = TaskStore::new(base_path, member_did).await?;
        let tasks      = task_store.list(&space, Some("active"), None, 1000).await?;

        Ok(Self {
            circle_did:   circle_did.to_string(),
            event_count,
            task_count:   tasks.len() as u64,
            active_polls: 0,  // populated by polls store in full impl
            next_event_at,
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use tempfile::tempdir;

    #[tokio::test]
    async fn test_provision_idempotent() {
        let dir       = tempdir().unwrap();
        let base_path = dir.path().to_str().unwrap();
        let ns = CircleCalendarNamespace::new(
            base_path, "did:web:alice.com", "did:web:family.przma.net"
        );

        let r1 = ns.provision().await.unwrap();
        assert_eq!(r1.tables_created, 3);

        let r2 = ns.provision().await.unwrap();
        assert_eq!(r2.tables_created, 0); // idempotent — already exists
    }

    #[test]
    fn test_derive_circle_key_deterministic() {
        let k1 = derive_circle_key("did:web:alice.com", "did:web:family.przma.net");
        let k2 = derive_circle_key("did:web:alice.com", "did:web:family.przma.net");
        assert_eq!(k1, k2);
    }

    #[test]
    fn test_derive_circle_key_unique_per_circle() {
        let k1 = derive_circle_key("did:web:alice.com", "did:web:family.przma.net");
        let k2 = derive_circle_key("did:web:alice.com", "did:web:work.przma.net");
        assert_ne!(k1, k2);
    }
}
