// przma-calendar/src/federation/ical.rs
//
// RFC 5545 iCalendar serialization for PRZMA CalendarEvent.
// Used for iCal export, CalDAV bridge, and booking confirmations.

use chrono::{DateTime, Utc};
use crate::models::{CalendarEvent, CalendarTask, EventStatus};

// ─── ICAL BUILDER ────────────────────────────────────────────────────────────

pub struct ICalBuilder {
    lines: Vec<String>,
}

impl ICalBuilder {
    pub fn new(calendar_name: &str, timezone: &str) -> Self {
        let mut b = Self { lines: vec![] };
        b.line("BEGIN:VCALENDAR");
        b.line("VERSION:2.0");
        b.line(&format!("PRODID:-//PRZMA//Calendar//EN"));
        b.line("CALSCALE:GREGORIAN");
        b.line("METHOD:PUBLISH");
        b.prop("X-WR-CALNAME", calendar_name);
        b.prop("X-WR-TIMEZONE", timezone);
        b
    }

    fn line(&mut self, s: &str) { self.lines.push(s.to_string()); }

    fn prop(&mut self, key: &str, value: &str) {
        // Fold long lines at 75 chars per RFC 5545
        let line = format!("{}:{}", key, value);
        self.lines.extend(fold_line(&line));
    }

    fn prop_escaped(&mut self, key: &str, value: &str) {
        self.prop(key, &escape_text(value));
    }

    pub fn add_event(&mut self, event: &CalendarEvent) {
        self.line("BEGIN:VEVENT");
        self.prop("UID", &event.ical_uid);
        self.prop("DTSTAMP", &format_dt(Utc::now()));
        self.prop("DTSTART", &format_dt_tz(&event.start_at, &event.timezone));
        self.prop("DTEND",   &format_dt_tz(&event.end_at,   &event.timezone));
        self.prop_escaped("SUMMARY", &event.title);

        if !event.description.is_empty() {
            self.prop_escaped("DESCRIPTION", &event.description);
        }

        // Status
        let ical_status = match event.status {
            EventStatus::Confirmed => "CONFIRMED",
            EventStatus::Tentative => "TENTATIVE",
            EventStatus::Cancelled => "CANCELLED",
        };
        self.prop("STATUS", ical_status);

        // Organiser
        self.prop("ORGANIZER", &format!("mailto:{}", did_to_email(&event.organiser_did)));

        // Attendees
        for attendee_did in &event.attendees {
            let status = event.attendee_status
                .get(attendee_did)
                .map(|s| s.as_str())
                .unwrap_or("pending");
            let partstat = match status {
                "accepted"  => "ACCEPTED",
                "declined"  => "DECLINED",
                "tentative" => "TENTATIVE",
                _           => "NEEDS-ACTION",
            };
            self.prop("ATTENDEE",
                &format!("PARTSTAT={};CN={}:mailto:{}",
                    partstat, attendee_did, did_to_email(attendee_did)));
        }

        // Location
        if !event.location_ref.is_empty() {
            self.prop_escaped("LOCATION", &event.location_ref);
        }

        // Recurrence
        if let Some(ref rrule) = event.rrule {
            self.prop("RRULE", rrule);
        }
        if let Some(ref rec_id) = event.recurrence_id {
            if let Ok(ts) = rec_id.parse::<i64>() {
                if let Some(dt) = DateTime::from_timestamp_micros(ts) {
                    self.prop("RECURRENCE-ID", &format_dt(dt));
                }
            }
        }

        // Class (visibility mapping)
        let class = match event.visibility.as_str() {
            "private" => "PRIVATE",
            "circle"  => "CONFIDENTIAL",
            "public"  => "PUBLIC",
            _         => "PUBLIC",
        };
        self.prop("CLASS", class);

        // PRZMA-specific extension properties
        self.prop("X-PRZMA-CATEGORY", event.category.as_str());
        self.prop("X-PRZMA-DID",      &event.did);

        // Version / sequence
        self.prop("SEQUENCE", &event.version.to_string());
        self.prop("CREATED",  &format_dt(event.created_at));
        self.prop("LAST-MODIFIED", &format_dt(event.updated_at));

        self.line("END:VEVENT");
    }

    pub fn add_task(&mut self, task: &CalendarTask) {
        self.line("BEGIN:VTODO");
        self.prop("UID",     &format!("przma-task-{}", task.id));
        self.prop("DTSTAMP", &format_dt(Utc::now()));
        self.prop_escaped("SUMMARY", &task.title);

        if !task.description.is_empty() {
            self.prop_escaped("DESCRIPTION", &task.description);
        }

        if let Some(due) = task.due_at {
            self.prop("DUE", &format_dt(due));
        }

        let percent = task.progress_pct.clamp(0, 100);
        self.prop("PERCENT-COMPLETE", &percent.to_string());

        let ical_status = match task.status {
            crate::models::TaskStatus::Draft     => "NEEDS-ACTION",
            crate::models::TaskStatus::Active    => "IN-PROCESS",
            crate::models::TaskStatus::Blocked   => "IN-PROCESS",
            crate::models::TaskStatus::Complete  => "COMPLETED",
            crate::models::TaskStatus::Deferred  => "NEEDS-ACTION",
            crate::models::TaskStatus::Cancelled => "CANCELLED",
        };
        self.prop("STATUS", ical_status);

        let ical_priority = match task.priority {
            crate::models::TaskPriority::Low    => "9",
            crate::models::TaskPriority::Medium => "5",
            crate::models::TaskPriority::High   => "2",
            crate::models::TaskPriority::Urgent => "1",
        };
        self.prop("PRIORITY", ical_priority);

        if let Some(completed) = task.completed_at {
            self.prop("COMPLETED", &format_dt(completed));
        }

        self.prop("SEQUENCE", &task.version.to_string());
        self.prop("CREATED",  &format_dt(task.created_at));
        self.prop("LAST-MODIFIED", &format_dt(task.updated_at));

        self.line("END:VTODO");
    }

    pub fn finish(mut self) -> String {
        self.line("END:VCALENDAR");
        self.lines.join("\r\n") + "\r\n"
    }
}

// ─── PARSE iCAL ──────────────────────────────────────────────────────────────

/// Parse a single VEVENT block from iCal text into a partial event map.
/// Returns key-value pairs for the Phoenix layer to hydrate into a CalendarEvent.
pub fn parse_vevent(ical: &str) -> Vec<(String, String)> {
    let mut in_vevent = false;
    let mut props     = vec![];
    let mut prev_line = String::new();

    for raw_line in ical.lines() {
        // Handle folded lines (RFC 5545: continuation with leading space/tab)
        let line = if raw_line.starts_with(' ') || raw_line.starts_with('\t') {
            prev_line.push_str(raw_line.trim_start());
            continue;
        } else {
            if !prev_line.is_empty() && in_vevent {
                parse_prop(&prev_line).map(|(k, v)| props.push((k, v)));
            }
            prev_line = raw_line.to_string();
            raw_line
        };

        match line.trim() {
            "BEGIN:VEVENT" => { in_vevent = true; }
            "END:VEVENT"   => {
                if !prev_line.is_empty() {
                    parse_prop(&prev_line).map(|(k, v)| props.push((k, v)));
                }
                in_vevent = false;
            }
            _ => {}
        }
    }
    props
}

fn parse_prop(line: &str) -> Option<(String, String)> {
    // Handle params: DTSTART;TZID=America/Chicago:20260511T090000
    let (key_part, value) = line.split_once(':')?;
    let key = key_part.split(';').next()?.to_uppercase();
    Some((key, value.to_string()))
}

// ─── HELPERS ─────────────────────────────────────────────────────────────────

fn format_dt(dt: DateTime<Utc>) -> String {
    dt.format("%Y%m%dT%H%M%SZ").to_string()
}

fn format_dt_tz(dt: &DateTime<Utc>, tz: &str) -> String {
    if tz == "UTC" || tz.is_empty() {
        format_dt(*dt)
    } else {
        // Simplified: include TZID param
        format!("TZID={}:{}", tz, dt.format("%Y%m%dT%H%M%S"))
    }
}

fn escape_text(s: &str) -> String {
    s.replace('\\', "\\\\")
     .replace(';',  "\\;")
     .replace(',',  "\\,")
     .replace('\n', "\\n")
}

/// Fold a long iCal property line at 75 octets per RFC 5545 §3.1
fn fold_line(line: &str) -> Vec<String> {
    if line.len() <= 75 {
        return vec![line.to_string()];
    }
    let mut result = vec![];
    let mut remaining = line;
    let mut first = true;
    while !remaining.is_empty() {
        let max = if first { 75 } else { 74 };
        let split_at = remaining.char_indices()
            .take(max)
            .last()
            .map(|(i, c)| i + c.len_utf8())
            .unwrap_or(remaining.len());
        let (chunk, rest) = remaining.split_at(split_at.min(remaining.len()));
        if first {
            result.push(chunk.to_string());
            first = false;
        } else {
            result.push(format!(" {}", chunk));
        }
        remaining = rest;
    }
    result
}

/// Convert a DID to a synthetic email for CalDAV interop
fn did_to_email(did: &str) -> String {
    let clean = did.replace("did:web:", "").replace(':', ".");
    format!("{}@przma.calendar", clean)
}

// ─── EXPORT FUNCTION ─────────────────────────────────────────────────────────

/// Export a list of CalendarEvents to an iCal string
pub fn export_events(
    events:        &[CalendarEvent],
    tasks:         &[CalendarTask],
    calendar_name: &str,
    timezone:      &str,
) -> String {
    let mut builder = ICalBuilder::new(calendar_name, timezone);
    for event in events { builder.add_event(event); }
    for task  in tasks  { builder.add_task(task); }
    builder.finish()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::models::EventCategory;
    use chrono::Utc;

    fn sample_event() -> CalendarEvent {
        let mut e = CalendarEvent::new(
            "did:web:alice.com",
            "Team Standup",
            EventCategory::Meeting,
            Utc::now(),
            Utc::now() + chrono::Duration::hours(1),
            crate::models::Space::Core,
        );
        e.timezone   = "America/Chicago".to_string();
        e.description = "Weekly sync".to_string();
        e
    }

    #[test]
    fn test_export_produces_valid_ical() {
        let event  = sample_event();
        let output = export_events(&[event], &[], "Alice's Calendar", "America/Chicago");
        assert!(output.contains("BEGIN:VCALENDAR"));
        assert!(output.contains("BEGIN:VEVENT"));
        assert!(output.contains("SUMMARY:Team Standup"));
        assert!(output.contains("END:VEVENT"));
        assert!(output.contains("END:VCALENDAR"));
    }

    #[test]
    fn test_export_includes_rrule() {
        let mut event = sample_event();
        event.rrule       = Some("FREQ=WEEKLY;BYDAY=MO".to_string());
        event.is_recurring = true;
        let output = export_events(&[event], &[], "Calendar", "UTC");
        assert!(output.contains("RRULE:FREQ=WEEKLY;BYDAY=MO"));
    }

    #[test]
    fn test_fold_long_line() {
        let long = "X-CUSTOM-PROP:".to_owned() + &"A".repeat(100);
        let folded = fold_line(&long);
        assert!(folded.len() > 1);
        assert!(folded[0].len() <= 75);
        assert!(folded[1].starts_with(' '));
    }

    #[test]
    fn test_escape_text() {
        assert_eq!(escape_text("a;b,c\nd"), "a\\;b\\,c\\nd");
    }

    #[test]
    fn test_parse_vevent_basic() {
        let ical = "BEGIN:VCALENDAR\r\nBEGIN:VEVENT\r\nSUMMARY:Hello\r\nUID:test-123\r\nEND:VEVENT\r\nEND:VCALENDAR";
        let props = parse_vevent(ical);
        let map: std::collections::HashMap<_, _> = props.into_iter().collect();
        assert_eq!(map.get("SUMMARY"), Some(&"Hello".to_string()));
        assert_eq!(map.get("UID"),     Some(&"test-123".to_string()));
    }
}
