// przma-calendar/src/intelligence/pre_brief.rs
//
// Pre-meeting brief context assembly.
// Queries the user's Lance vault to surface relevant context
// for each attendee before a meeting begins.

use crate::{
    error::{CalendarError, CalendarResult},
    events::EventStore,
    models::{CalendarEvent, EventCategory, Space},
    tasks::TaskStore,
};
use chrono::{DateTime, Duration, Utc};
use serde::{Deserialize, Serialize};

// ─── DOMAIN TYPES ────────────────────────────────────────────────────────────

#[derive(Debug, Serialize, Deserialize)]
pub struct PreBrief {
    pub event_id:         String,
    pub assembled_at:     DateTime<Utc>,
    pub attendee_context: Vec<AttendeeContext>,
    pub relevant_items:   Vec<RelevantItem>,
    pub open_action_items: Vec<PreviousAction>,
    pub suggested_agenda: Vec<String>,
    pub meeting_load:     MeetingLoadStats,
}

#[derive(Debug, Serialize, Deserialize)]
pub struct AttendeeContext {
    pub did:                    String,
    pub last_interaction_at:    Option<DateTime<Utc>>,
    pub last_interaction_summary: Option<String>,
    pub open_tasks:             Vec<String>,
    pub recent_shared_events:   u32,
    pub relationship_strength:  f32,  // 0.0–1.0 based on interaction frequency
}

#[derive(Debug, Serialize, Deserialize)]
pub struct RelevantItem {
    pub item_type:  String,    // "note" | "task" | "event" | "transcript"
    pub cas_hash:   Option<String>,
    pub summary:    String,
    pub relevance:  f32,
    pub created_at: DateTime<Utc>,
}

#[derive(Debug, Serialize, Deserialize)]
pub struct PreviousAction {
    pub task_id:    String,
    pub title:      String,
    pub due_at:     Option<DateTime<Utc>>,
    pub status:     String,
    pub event_id:   Option<String>,
}

#[derive(Debug, Default, Serialize, Deserialize)]
pub struct MeetingLoadStats {
    pub meetings_today:     u32,
    pub total_meeting_mins: i64,
    pub back_to_back:       bool,
    pub prev_meeting_end:   Option<DateTime<Utc>>,
    pub next_meeting_start: Option<DateTime<Utc>>,
}

// ─── PRE-BRIEF ASSEMBLER ─────────────────────────────────────────────────────

pub struct PreBriefAssembler {
    base_path: String,
    did:       String,
}

impl PreBriefAssembler {
    pub fn new(base_path: impl Into<String>, did: impl Into<String>) -> Self {
        Self { base_path: base_path.into(), did: did.into() }
    }

    /// Assemble a complete pre-brief for an event.
    /// Queries: past events with attendees, open tasks, meeting load today.
    pub async fn assemble(
        &self,
        event: &CalendarEvent,
    ) -> CalendarResult<PreBrief> {
        let event_store = EventStore::new(&self.base_path, &self.did).await?;
        let task_store  = TaskStore::new(&self.base_path, &self.did).await?;

        let attendee_context = self.build_attendee_context(
            &event.attendees,
            &event_store,
            &task_store,
        ).await?;

        let open_action_items = self.find_open_action_items(
            &event.attendees,
            &task_store,
        ).await?;

        let meeting_load = self.compute_meeting_load(
            event.start_at,
            &event_store,
        ).await?;

        let suggested_agenda = self.suggest_agenda(
            &open_action_items,
            &attendee_context,
        );

        Ok(PreBrief {
            event_id:          event.id.clone(),
            assembled_at:      Utc::now(),
            attendee_context,
            relevant_items:    vec![],  // Phase 6: Arc Engine surfaces vault items
            open_action_items,
            suggested_agenda,
            meeting_load,
        })
    }

    async fn build_attendee_context(
        &self,
        attendees:   &[String],
        event_store: &EventStore,
        task_store:  &TaskStore,
    ) -> CalendarResult<Vec<AttendeeContext>> {
        let mut contexts = vec![];
        let lookback     = Utc::now() - Duration::days(90);
        let now          = Utc::now();

        for attendee_did in attendees {
            if attendee_did == &self.did { continue; }

            // Find past shared events with this attendee
            let past_events = event_store
                .list(&Space::Core, Some(lookback), Some(now), None, Some("confirmed"), 100)
                .await?
                .into_iter()
                .filter(|e| e.attendees.contains(attendee_did))
                .collect::<Vec<_>>();

            let last_event = past_events.first();
            let recent_count = past_events.len() as u32;

            // Compute relationship strength from interaction frequency
            let relationship_strength = compute_relationship_strength(recent_count, 90.0);

            // Find open tasks assigned to or involving this attendee
            let open_tasks = task_store
                .list(&Space::Core, Some("active"), None, 100)
                .await?
                .into_iter()
                .filter(|t| t.assigned_to.contains(attendee_did))
                .map(|t| t.title)
                .collect::<Vec<_>>();

            contexts.push(AttendeeContext {
                did:                      attendee_did.clone(),
                last_interaction_at:      last_event.map(|e| e.start_at),
                last_interaction_summary: last_event.map(|e| format!("{} — {}", e.category.as_str(), e.title)),
                open_tasks,
                recent_shared_events:     recent_count,
                relationship_strength,
            });
        }
        Ok(contexts)
    }

    async fn find_open_action_items(
        &self,
        attendees:  &[String],
        task_store: &TaskStore,
    ) -> CalendarResult<Vec<PreviousAction>> {
        let all_active = task_store
            .list(&Space::Core, Some("active"), None, 200)
            .await?;

        let items = all_active
            .into_iter()
            .filter(|t| {
                // Include tasks assigned to any attendee or related to a meeting
                attendees.iter().any(|a| t.assigned_to.contains(a))
                    || t.event_id.is_some()
            })
            .map(|t| PreviousAction {
                task_id:  t.id,
                title:    t.title,
                due_at:   t.due_at,
                status:   t.status.as_str().to_string(),
                event_id: t.event_id,
            })
            .collect();

        Ok(items)
    }

    async fn compute_meeting_load(
        &self,
        meeting_start: DateTime<Utc>,
        event_store:   &EventStore,
    ) -> CalendarResult<MeetingLoadStats> {
        let day_start = meeting_start
            .date_naive()
            .and_hms_opt(0, 0, 0)
            .unwrap()
            .and_utc();
        let day_end   = day_start + Duration::days(1);

        let today_meetings = event_store
            .list(&Space::Core, Some(day_start), Some(day_end),
                  Some("MEETING"), Some("confirmed"), 50)
            .await?;

        let total_mins: i64 = today_meetings.iter()
            .map(|e| (e.end_at - e.start_at).num_minutes())
            .sum();

        // Check for back-to-back meetings
        let prev_meeting = today_meetings.iter()
            .filter(|e| e.end_at <= meeting_start)
            .last();

        let next_meeting = today_meetings.iter()
            .find(|e| e.start_at > meeting_start);

        let back_to_back = prev_meeting
            .map(|e| (meeting_start - e.end_at).num_minutes() < 5)
            .unwrap_or(false);

        Ok(MeetingLoadStats {
            meetings_today:     today_meetings.len() as u32,
            total_meeting_mins: total_mins,
            back_to_back,
            prev_meeting_end:   prev_meeting.map(|e| e.end_at),
            next_meeting_start: next_meeting.map(|e| e.start_at),
        })
    }

    fn suggest_agenda(
        &self,
        open_actions:     &[PreviousAction],
        attendee_context: &[AttendeeContext],
    ) -> Vec<String> {
        let mut suggestions = vec![];

        // Overdue items first
        let now = Utc::now();
        for action in open_actions.iter().filter(|a| {
            a.due_at.map(|d| d < now).unwrap_or(false) && a.status == "active"
        }) {
            suggestions.push(format!("[Overdue] {}", action.title));
        }

        // Open tasks involving attendees
        for ctx in attendee_context {
            for task in ctx.open_tasks.iter().take(2) {
                suggestions.push(format!("Follow up: {}", task));
            }
        }

        // Fallback if nothing found
        if suggestions.is_empty() {
            suggestions.push("Review action items from last meeting".to_string());
            suggestions.push("Discuss agenda and next steps".to_string());
        }

        suggestions.truncate(8);
        suggestions
    }
}

fn compute_relationship_strength(interactions_90d: u32, period_days: f32) -> f32 {
    // Sigmoid-like decay: 4 interactions/month = ~1.0 strength
    let rate = interactions_90d as f32 / (period_days / 30.0);
    1.0 / (1.0 + (-rate + 2.0).exp())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_relationship_strength_scaling() {
        // Zero interactions = low strength
        assert!(compute_relationship_strength(0, 90.0) < 0.3);
        // 12 interactions in 90 days (~4/month) = high strength
        assert!(compute_relationship_strength(12, 90.0) > 0.7);
    }

    #[test]
    fn test_suggest_agenda_fallback() {
        let assembler = PreBriefAssembler::new("/tmp", "did:web:alice.com");
        let agenda    = assembler.suggest_agenda(&[], &[]);
        assert!(!agenda.is_empty());
        assert!(agenda[0].contains("action items") || agenda[0].contains("agenda"));
    }
}
