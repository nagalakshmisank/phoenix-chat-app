// przma-calendar/src/models.rs
//
// All PRZMA Calendar domain models.
// These map 1-to-1 with the Lance schemas in schema.rs.

use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use std::collections::HashMap;

// ─── ENUMS ───────────────────────────────────────────────────────────────────

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "SCREAMING_SNAKE_CASE")]
pub enum EventCategory {
    Practice,
    Meeting,
    Activity,
    Event,
    Appointment,
    Study,
    Block,
    Milestone,
}

impl EventCategory {
    pub fn as_str(&self) -> &'static str {
        match self {
            Self::Practice    => "PRACTICE",
            Self::Meeting     => "MEETING",
            Self::Activity    => "ACTIVITY",
            Self::Event       => "EVENT",
            Self::Appointment => "APPOINTMENT",
            Self::Study       => "STUDY",
            Self::Block       => "BLOCK",
            Self::Milestone   => "MILESTONE",
        }
    }
}

impl TryFrom<&str> for EventCategory {
    type Error = crate::error::CalendarError;
    fn try_from(s: &str) -> Result<Self, Self::Error> {
        match s {
            "PRACTICE"    => Ok(Self::Practice),
            "MEETING"     => Ok(Self::Meeting),
            "ACTIVITY"    => Ok(Self::Activity),
            "EVENT"       => Ok(Self::Event),
            "APPOINTMENT" => Ok(Self::Appointment),
            "STUDY"       => Ok(Self::Study),
            "BLOCK"       => Ok(Self::Block),
            "MILESTONE"   => Ok(Self::Milestone),
            other => Err(crate::error::CalendarError::InvalidField(
                format!("Unknown event category: {}", other)
            )),
        }
    }
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Space {
    Core,
    Circle(String), // circle DID
    Commons,
}

impl Space {
    pub fn as_str(&self) -> String {
        match self {
            Self::Core          => "core".to_string(),
            Self::Circle(did)   => format!("circle:{}", did),
            Self::Commons       => "commons".to_string(),
        }
    }
}

impl TryFrom<&str> for Space {
    type Error = crate::error::CalendarError;
    fn try_from(s: &str) -> Result<Self, Self::Error> {
        if s == "core"    { return Ok(Self::Core); }
        if s == "commons" { return Ok(Self::Commons); }
        if let Some(did) = s.strip_prefix("circle:") {
            return Ok(Self::Circle(did.to_string()));
        }
        Err(crate::error::CalendarError::InvalidField(
            format!("Unknown space: {}", s)
        ))
    }
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum EventStatus {
    Confirmed,
    Tentative,
    Cancelled,
}

impl EventStatus {
    pub fn as_str(&self) -> &'static str {
        match self {
            Self::Confirmed => "confirmed",
            Self::Tentative => "tentative",
            Self::Cancelled => "cancelled",
        }
    }
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum BusyStatus {
    Busy,
    Free,
    Tentative,
}

impl BusyStatus {
    pub fn as_str(&self) -> &'static str {
        match self {
            Self::Busy      => "busy",
            Self::Free      => "free",
            Self::Tentative => "tentative",
        }
    }
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum TaskStatus {
    Draft,
    Active,
    Blocked,
    Complete,
    Deferred,
    Cancelled,
}

impl TaskStatus {
    pub fn as_str(&self) -> &'static str {
        match self {
            Self::Draft     => "draft",
            Self::Active    => "active",
            Self::Blocked   => "blocked",
            Self::Complete  => "complete",
            Self::Deferred  => "deferred",
            Self::Cancelled => "cancelled",
        }
    }
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum TaskPriority {
    Low,
    Medium,
    High,
    Urgent,
}

impl TaskPriority {
    pub fn as_str(&self) -> &'static str {
        match self {
            Self::Low    => "low",
            Self::Medium => "medium",
            Self::High   => "high",
            Self::Urgent => "urgent",
        }
    }
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum LocationType {
    Physical,
    Virtual,
    Hybrid,
    None,
}

impl LocationType {
    pub fn as_str(&self) -> &'static str {
        match self {
            Self::Physical => "physical",
            Self::Virtual  => "virtual",
            Self::Hybrid   => "hybrid",
            Self::None     => "none",
        }
    }
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum AttendeeStatus {
    Accepted,
    Declined,
    Tentative,
    Pending,
}

impl AttendeeStatus {
    pub fn as_str(&self) -> &'static str {
        match self {
            Self::Accepted  => "accepted",
            Self::Declined  => "declined",
            Self::Tentative => "tentative",
            Self::Pending   => "pending",
        }
    }
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum CompanionMode {
    Silent,
    Personal,
    Scribe,
    Full,
}

impl CompanionMode {
    pub fn as_str(&self) -> &'static str {
        match self {
            Self::Silent   => "silent",
            Self::Personal => "personal",
            Self::Scribe   => "scribe",
            Self::Full     => "full",
        }
    }
}

// ─── CALENDAR EVENT ───────────────────────────────────────────────────────────

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CalendarEvent {
    // Identity
    pub id:             String,
    pub did:            String,
    pub space:          Space,
    pub circle_did:     Option<String>,

    // Core fields
    pub title:          String,
    pub description:    String,
    pub category:       EventCategory,
    pub sub_type:       String,
    pub location_type:  LocationType,
    pub location_ref:   String,

    // Time
    pub start_at:       DateTime<Utc>,
    pub end_at:         DateTime<Utc>,
    pub all_day:        bool,
    pub timezone:       String,
    pub rrule:          Option<String>,
    pub recurrence_id:  Option<String>,  // ISO8601 of overridden instance
    pub is_recurring:   bool,

    // Visibility & governance
    pub visibility:     String,          // private | circle | public
    pub status:         EventStatus,
    pub busy_status:    BusyStatus,

    // Attendees
    pub organiser_did:  String,
    pub attendees:      Vec<String>,
    pub attendee_status: HashMap<String, AttendeeStatus>,

    // Companion & intelligence
    pub has_pre_brief:  bool,
    pub has_reflection: bool,
    pub companion_mode: CompanionMode,
    pub notes_cas:      Vec<String>,
    pub attachments_cas: Vec<String>,

    // Semantic search
    pub embedding:      Vec<f32>,        // 768-dim TFLite embedding

    // Federation
    pub ap_object_id:   Option<String>,
    pub ical_uid:       String,
    pub external_id:    Option<String>,

    // Metadata
    pub created_at:     DateTime<Utc>,
    pub updated_at:     DateTime<Utc>,
    pub version:        i32,
    pub created_by:     String,
}

impl CalendarEvent {
    pub fn new(
        did: impl Into<String>,
        title: impl Into<String>,
        category: EventCategory,
        start_at: DateTime<Utc>,
        end_at: DateTime<Utc>,
        space: Space,
    ) -> Self {
        let now = Utc::now();
        let id = crate::cas::hash_id(&format!("{}{}{}", did.as_ref() as &str, title.as_ref() as &str, now.timestamp_micros()));
        let ical_uid = format!("przma-{}-{}@przma", now.format("%Y%m%d"), &id[..8]);
        let organiser_did = did.into();

        Self {
            id:              id.clone(),
            did:             organiser_did.clone(),
            space,
            circle_did:      None,
            title:           title.into(),
            description:     String::new(),
            category,
            sub_type:        String::new(),
            location_type:   LocationType::None,
            location_ref:    String::new(),
            start_at,
            end_at,
            all_day:         false,
            timezone:        "UTC".to_string(),
            rrule:           None,
            recurrence_id:   None,
            is_recurring:    false,
            visibility:      "private".to_string(),
            status:          EventStatus::Confirmed,
            busy_status:     BusyStatus::Busy,
            organiser_did,
            attendees:       vec![],
            attendee_status: HashMap::new(),
            has_pre_brief:   false,
            has_reflection:  false,
            companion_mode:  CompanionMode::Personal,
            notes_cas:       vec![],
            attachments_cas: vec![],
            embedding:       vec![0.0f32; 768],
            ap_object_id:    None,
            ical_uid,
            external_id:     None,
            created_at:      now,
            updated_at:      now,
            version:         1,
            created_by:      id,
        }
    }
}

// ─── CALENDAR TASK ────────────────────────────────────────────────────────────

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CalendarTask {
    pub id:            String,
    pub did:           String,
    pub space:         Space,
    pub circle_did:    Option<String>,

    pub title:         String,
    pub description:   String,
    pub category:      String,          // personal | circle | community
    pub priority:      TaskPriority,
    pub status:        TaskStatus,

    // Scheduling
    pub due_at:        Option<DateTime<Utc>>,
    pub start_at:      Option<DateTime<Utc>>,
    pub event_id:      Option<String>,
    pub rrule:         Option<String>,

    // Assignment
    pub assigned_to:   Vec<String>,
    pub assigned_by:   String,

    // Progress
    pub progress_pct:  i32,
    pub blocked_reason: Option<String>,
    pub completed_at:  Option<DateTime<Utc>>,
    pub completed_by:  Option<String>,

    pub notes_cas:     Vec<String>,
    pub embedding:     Vec<f32>,

    pub created_at:    DateTime<Utc>,
    pub updated_at:    DateTime<Utc>,
    pub version:       i32,
}

impl CalendarTask {
    pub fn new(
        did: impl Into<String>,
        title: impl Into<String>,
        space: Space,
        assigned_by: impl Into<String>,
    ) -> Self {
        let now = Utc::now();
        let did_str = did.into();
        let title_str = title.into();
        let id = crate::cas::hash_id(&format!("{}{}{}", did_str, title_str, now.timestamp_micros()));

        Self {
            id,
            did: did_str.clone(),
            space,
            circle_did:     None,
            title:          title_str,
            description:    String::new(),
            category:       "personal".to_string(),
            priority:       TaskPriority::Medium,
            status:         TaskStatus::Draft,
            due_at:         None,
            start_at:       None,
            event_id:       None,
            rrule:          None,
            assigned_to:    vec![did_str.clone()],
            assigned_by:    assigned_by.into(),
            progress_pct:   0,
            blocked_reason: None,
            completed_at:   None,
            completed_by:   None,
            notes_cas:      vec![],
            embedding:      vec![0.0f32; 768],
            created_at:     now,
            updated_at:     now,
            version:        1,
        }
    }
}

// ─── AVAILABILITY ─────────────────────────────────────────────────────────────

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AvailabilityWindow {
    pub id:               String,
    pub did:              String,
    pub window_type:      String,       // busy | free | tentative | block
    pub start_at:         DateTime<Utc>,
    pub end_at:           DateTime<Utc>,
    pub rrule:            Option<String>,
    pub timezone:         String,
    pub visibility:       String,       // private | circle | public
    pub show_as:          String,       // busy | free | label
    pub shared_with:      Vec<String>,  // DIDs or circle DIDs
    pub is_bookable:      bool,
    pub booking_link_id:  Option<String>,
    pub min_notice_mins:  i32,
    pub buffer_mins:      i32,
    pub created_at:       DateTime<Utc>,
    pub updated_at:       DateTime<Utc>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct FreeBusySlot {
    pub start_at:  DateTime<Utc>,
    pub end_at:    DateTime<Utc>,
    pub show_as:   String,
    pub label:     String,
}

// ─── BOOKING LINK ─────────────────────────────────────────────────────────────

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct BookingLink {
    pub id:               String,
    pub did:              String,
    pub title:            String,
    pub description:      String,
    pub duration_mins:    i32,
    pub location_type:    LocationType,
    pub location_ref:     String,
    pub availability_rule: String,
    pub questions:        Vec<String>,
    pub confirmation_msg: String,
    pub is_active:        bool,
    pub created_at:       DateTime<Utc>,
    pub updated_at:       DateTime<Utc>,
}

// ─── REMINDER ────────────────────────────────────────────────────────────────

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Reminder {
    pub id:                   String,
    pub did:                  String,
    pub entity_type:          String,   // event | task | activity
    pub entity_id:            String,
    pub trigger_type:         String,   // relative | absolute | location
    pub trigger_mins:         Option<i32>,
    pub trigger_at:           Option<DateTime<Utc>>,
    pub delivery:             Vec<String>,  // push | companion | email | sms
    pub message:              Option<String>,
    pub repeat:               bool,
    pub repeat_interval_mins: Option<i32>,
    pub delivered_at:         Option<DateTime<Utc>>,
    pub dismissed_at:         Option<DateTime<Utc>>,
    pub created_at:           DateTime<Utc>,
}

impl Reminder {
    /// Compute absolute trigger time from event start_at
    pub fn compute_trigger_at(&self, event_start: DateTime<Utc>) -> DateTime<Utc> {
        match self.trigger_type.as_str() {
            "relative" => {
                let mins = self.trigger_mins.unwrap_or(10) as i64;
                event_start - chrono::Duration::minutes(mins)
            }
            "absolute" => self.trigger_at.unwrap_or(event_start),
            _ => event_start,
        }
    }
}

// ─── SCHEDULING POLL ─────────────────────────────────────────────────────────

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PollOption {
    pub id:           String,
    pub label:        String,
    pub start_at:     Option<DateTime<Utc>>,
    pub end_at:       Option<DateTime<Utc>>,
    pub location_ref: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SchedulingPoll {
    pub id:                  String,
    pub circle_did:          String,
    pub created_by:          String,
    pub title:               String,
    pub description:         String,
    pub poll_type:           String,    // date | venue | decision | check_in
    pub options:             Vec<PollOption>,
    pub votes:               HashMap<String, Vec<String>>, // did → [option_ids]
    pub status:              String,    // open | closed | resolved
    pub resolved_option:     Option<String>,
    pub auto_create_event:   bool,
    pub resulting_event_id:  Option<String>,
    pub closes_at:           Option<DateTime<Utc>>,
    pub created_at:          DateTime<Utc>,
    pub updated_at:          DateTime<Utc>,
}

impl SchedulingPoll {
    /// Determine winning option by vote count
    pub fn tally(&self) -> Vec<(String, usize)> {
        let mut counts: HashMap<&str, usize> = HashMap::new();
        for option_votes in self.votes.values() {
            for opt_id in option_votes {
                *counts.entry(opt_id.as_str()).or_insert(0) += 1;
            }
        }
        let mut tally: Vec<(String, usize)> = counts
            .into_iter()
            .map(|(k, v)| (k.to_string(), v))
            .collect();
        tally.sort_by(|a, b| b.1.cmp(&a.1));
        tally
    }

    pub fn winner(&self) -> Option<&str> {
        self.resolved_option.as_deref()
    }
}
