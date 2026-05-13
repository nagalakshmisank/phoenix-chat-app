// przma-calendar/src/federation/activitypub.rs
//
// ActivityPub JSON-LD object serialization for PRZMA Calendar events.
// Produces spec-compliant AS2 / ActivityStreams 2.0 objects.

use crate::models::{CalendarEvent, EventStatus};
use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};

// ─── CONTEXT ─────────────────────────────────────────────────────────────────

const AS2_CONTEXT: &str = "https://www.w3.org/ns/activitystreams";
const SCHEMA_ORG:  &str = "https://schema.org";

// ─── ACTOR DOCUMENT ──────────────────────────────────────────────────────────

/// Build an ActivityPub Actor document for a DID.
/// Served at /ap/actor/{did}
pub fn build_actor(
    did:          &str,
    display_name: &str,
    instance_url: &str,
    public_key_pem: &str,
) -> Value {
    let actor_url   = format!("{}/ap/actor/{}", instance_url, url_encode_did(did));
    let inbox_url   = format!("{}/ap/inbox/{}", instance_url, url_encode_did(did));
    let outbox_url  = format!("{}/ap/outbox/{}", instance_url, url_encode_did(did));
    let key_id      = format!("{}#key-1", actor_url);
    let did_doc_url = did_to_url(did);

    json!({
        "@context": [AS2_CONTEXT, "https://w3id.org/security/v1"],
        "type":     "Person",
        "id":       actor_url,
        "name":     display_name,
        "url":      did_doc_url,
        "alsoKnownAs": did,
        "inbox":    inbox_url,
        "outbox":   outbox_url,
        "publicKey": {
            "id":           key_id,
            "owner":        actor_url,
            "publicKeyPem": public_key_pem,
        },
        "endpoints": {
            "sharedInbox": format!("{}/ap/inbox/shared", instance_url)
        }
    })
}

// ─── EVENT OBJECT ─────────────────────────────────────────────────────────────

/// Build an ActivityPub Event object from a CalendarEvent.
/// Published when a user shares an event to Commons.
pub fn build_event_object(event: &CalendarEvent, instance_url: &str) -> Value {
    let event_url = format!("{}/ap/events/{}", instance_url, &event.id);
    let actor_url = format!("{}/ap/actor/{}", instance_url, url_encode_did(&event.organiser_did));

    let status = match event.status {
        EventStatus::Confirmed => "Confirmed",
        EventStatus::Tentative => "Tentative",
        EventStatus::Cancelled => "Cancelled",
    };

    let location = build_location(event);

    json!({
        "@context": [AS2_CONTEXT, SCHEMA_ORG],
        "type":       "Event",
        "id":         event_url,
        "name":       event.title,
        "content":    event.description,
        "url":        event_url,
        "startTime":  format_dt(event.start_at),
        "endTime":    format_dt(event.end_at),
        "status":     status,
        "location":   location,
        "organizer": {
            "type": "Person",
            "id":   actor_url,
        },
        "attributedTo": actor_url,
        "to":           ["https://www.w3.org/ns/activitystreams#Public"],
        "cc":           [format!("{}/ap/followers/{}", instance_url, url_encode_did(&event.organiser_did))],
        "published":    format_dt(event.created_at),
        "updated":      format_dt(event.updated_at),
        "tag": build_tags(event),
        "attachment": [],
    })
}

// ─── ACTIVITIES ──────────────────────────────────────────────────────────────

/// Wrap an Event object in a Create activity
pub fn build_create_activity(
    event_object: &Value,
    actor_url:    &str,
    activity_id:  &str,
) -> Value {
    json!({
        "@context": AS2_CONTEXT,
        "type":     "Create",
        "id":       activity_id,
        "actor":    actor_url,
        "object":   event_object,
        "to":       ["https://www.w3.org/ns/activitystreams#Public"],
        "published": format_dt(Utc::now()),
    })
}

/// Build an Update activity when an event is modified
pub fn build_update_activity(
    event_object: &Value,
    actor_url:    &str,
    activity_id:  &str,
) -> Value {
    json!({
        "@context": AS2_CONTEXT,
        "type":     "Update",
        "id":       activity_id,
        "actor":    actor_url,
        "object":   event_object,
        "to":       ["https://www.w3.org/ns/activitystreams#Public"],
        "published": format_dt(Utc::now()),
    })
}

/// Build a Delete/Tombstone activity when an event is cancelled/removed from Commons
pub fn build_delete_activity(
    event_url:   &str,
    actor_url:   &str,
    activity_id: &str,
) -> Value {
    json!({
        "@context": AS2_CONTEXT,
        "type":     "Delete",
        "id":       activity_id,
        "actor":    actor_url,
        "object": {
            "type": "Tombstone",
            "id":   event_url,
        },
        "to":       ["https://www.w3.org/ns/activitystreams#Public"],
        "published": format_dt(Utc::now()),
    })
}

/// Build an RSVP Accept activity (attendee accepted event invite)
pub fn build_rsvp_accept(
    event_url:    &str,
    attendee_url: &str,
    activity_id:  &str,
) -> Value {
    json!({
        "@context": AS2_CONTEXT,
        "type":     "Accept",
        "id":       activity_id,
        "actor":    attendee_url,
        "object":   event_url,
        "published": format_dt(Utc::now()),
    })
}

/// Build an RSVP Reject activity (attendee declined)
pub fn build_rsvp_reject(
    event_url:    &str,
    attendee_url: &str,
    activity_id:  &str,
) -> Value {
    json!({
        "@context": AS2_CONTEXT,
        "type":     "Reject",
        "id":       activity_id,
        "actor":    attendee_url,
        "object":   event_url,
        "published": format_dt(Utc::now()),
    })
}

// ─── INVITE ──────────────────────────────────────────────────────────────────

/// Build an Invite activity — DID-targeted event invitation
pub fn build_invite_activity(
    event_object:  &Value,
    actor_url:     &str,
    target_did:    &str,
    instance_url:  &str,
    activity_id:   &str,
) -> Value {
    let target_url = format!("{}/ap/actor/{}", instance_url, url_encode_did(target_did));

    json!({
        "@context": AS2_CONTEXT,
        "type":     "Invite",
        "id":       activity_id,
        "actor":    actor_url,
        "object":   event_object,
        "target":   target_url,
        "to":       [target_url],
        "published": format_dt(Utc::now()),
    })
}

// ─── HELPERS ─────────────────────────────────────────────────────────────────

fn build_location(event: &CalendarEvent) -> Value {
    if event.location_ref.is_empty() {
        return json!(null);
    }
    match event.location_type {
        crate::models::LocationType::Virtual => json!({
            "type": "VirtualLocation",
            "url":  event.location_ref,
        }),
        crate::models::LocationType::Physical => json!({
            "type": "Place",
            "name": event.location_ref,
        }),
        crate::models::LocationType::Hybrid => json!({
            "type": "Place",
            "name": event.location_ref,
        }),
        _ => json!(null),
    }
}

fn build_tags(event: &CalendarEvent) -> Value {
    let tags: Vec<Value> = std::iter::once(json!({
        "type": "Hashtag",
        "name": format!("#{}", event.category.as_str().to_lowercase()),
    })).collect();
    json!(tags)
}

fn format_dt(dt: DateTime<Utc>) -> String {
    dt.format("%Y-%m-%dT%H:%M:%SZ").to_string()
}

fn did_to_url(did: &str) -> String {
    if let Some(domain) = did.strip_prefix("did:web:") {
        format!("https://{}", domain.replace(':', "/"))
    } else {
        did.to_string()
    }
}

fn url_encode_did(did: &str) -> String {
    did.replace(':', "%3A")
}

// ─── INBOUND PARSING ─────────────────────────────────────────────────────────

/// Extract key fields from an inbound ActivityPub Event object
#[derive(Debug, Serialize, Deserialize)]
pub struct InboundEvent {
    pub ap_id:      String,
    pub title:      String,
    pub content:    String,
    pub start_time: Option<String>,
    pub end_time:   Option<String>,
    pub actor_id:   String,
    pub object_type: String,
}

pub fn parse_inbound_activity(body: &Value) -> Option<InboundEvent> {
    let obj = match body.get("object") {
        Some(o) => o,
        None    => body,
    };

    let obj_type = obj.get("type")?.as_str()?.to_string();

    Some(InboundEvent {
        ap_id:       obj.get("id")?.as_str()?.to_string(),
        title:       obj.get("name").or_else(|| obj.get("summary"))
                        .and_then(|v| v.as_str())
                        .unwrap_or("").to_string(),
        content:     obj.get("content").and_then(|v| v.as_str()).unwrap_or("").to_string(),
        start_time:  obj.get("startTime").and_then(|v| v.as_str()).map(|s| s.to_string()),
        end_time:    obj.get("endTime").and_then(|v| v.as_str()).map(|s| s.to_string()),
        actor_id:    body.get("actor").and_then(|v| v.as_str()).unwrap_or("").to_string(),
        object_type: obj_type,
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::models::EventCategory;

    fn sample_event() -> CalendarEvent {
        CalendarEvent::new(
            "did:web:alice.com",
            "Community Practice",
            EventCategory::Practice,
            Utc::now(),
            Utc::now() + chrono::Duration::hours(1),
            crate::models::Space::Commons,
        )
    }

    #[test]
    fn test_build_event_object_has_required_fields() {
        let event = sample_event();
        let obj   = build_event_object(&event, "https://alice.przma.net");
        assert_eq!(obj["type"],  "Event");
        assert_eq!(obj["name"],  "Community Practice");
        assert!(obj["id"].as_str().unwrap().contains("alice.przma.net"));
        assert!(obj["startTime"].is_string());
        assert!(obj["endTime"].is_string());
    }

    #[test]
    fn test_build_create_activity() {
        let event    = sample_event();
        let obj      = build_event_object(&event, "https://alice.przma.net");
        let activity = build_create_activity(
            &obj,
            "https://alice.przma.net/ap/actor/did%3Aweb%3Aalice.com",
            "https://alice.przma.net/ap/activities/001",
        );
        assert_eq!(activity["type"], "Create");
        assert_eq!(activity["object"]["type"], "Event");
    }

    #[test]
    fn test_build_actor() {
        let actor = build_actor(
            "did:web:alice.com",
            "Alice",
            "https://alice.przma.net",
            "-----BEGIN PUBLIC KEY-----\nMFkwEwYH...",
        );
        assert_eq!(actor["type"], "Person");
        assert!(actor["inbox"].as_str().unwrap().contains("inbox"));
        assert!(actor["publicKey"]["publicKeyPem"].is_string());
    }

    #[test]
    fn test_parse_inbound_activity() {
        let body = serde_json::json!({
            "type": "Create",
            "actor": "https://bob.example.com/ap/actor/bob",
            "object": {
                "type": "Event",
                "id":   "https://bob.example.com/ap/events/123",
                "name": "Bob's Party",
                "startTime": "2026-06-01T18:00:00Z",
            }
        });
        let parsed = parse_inbound_activity(&body).unwrap();
        assert_eq!(parsed.title,   "Bob's Party");
        assert_eq!(parsed.ap_id,   "https://bob.example.com/ap/events/123");
        assert_eq!(parsed.object_type, "Event");
    }
}
