// przma-platform/src/namespace.rs
//
// PRZMA namespace URI scheme: przma://{did}/{service}/{space}/{type}/{id}
//
// All platform resources are addressable by a stable URI.
// Services use these URIs to reference each other's data without copying it.
//
// URI components:
//   did      — the user's DID (did:web:alice.com)
//   service  — one of: vault|calendar|chat|files|metadata|ai|agents|creative|companion
//   space    — core | circle:{circle_did} | commons
//   type     — the resource type within the service (event|entry|message|file|...)
//   id       — opaque resource identifier (BLAKE3 hash or UUID)
//
// Examples:
//   przma://did:web:alice.com/calendar/core/event/abc123
//   przma://did:web:alice.com/vault/core/entry/xyz789
//   przma://did:web:alice.com/chat/circle:did:web:family.przma.net/message/msg001
//   przma://did:web:alice.com/files/core/document/doc456
//   przma://did:web:alice.com/companion/core/memory/mem789
//   przma://did:web:alice.com/creative/core/project/proj111

use serde::{Deserialize, Serialize};
use std::fmt;
use crate::error::{PlatformError, PlatformResult};

// ─── SERVICE REGISTRY ────────────────────────────────────────────────────────

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ServiceNamespace {
    Vault,
    Calendar,
    Chat,
    Files,
    Metadata,
    Ai,
    Agents,
    Creative,
    Companion,
}

impl ServiceNamespace {
    pub fn as_str(&self) -> &'static str {
        match self {
            Self::Vault     => "vault",
            Self::Calendar  => "calendar",
            Self::Chat      => "chat",
            Self::Files     => "files",
            Self::Metadata  => "metadata",
            Self::Ai        => "ai",
            Self::Agents    => "agents",
            Self::Creative  => "creative",
            Self::Companion => "companion",
        }
    }

    /// Lance base directory for this service within a user's vault
    pub fn lance_dir(&self) -> &'static str {
        self.as_str()
    }

    /// Whether this service is available offline without any server
    pub fn offline_capable(&self) -> bool {
        matches!(self, Self::Vault | Self::Calendar | Self::Files | Self::Creative | Self::Companion)
    }

    /// Whether this service requires circle governance
    pub fn is_social(&self) -> bool {
        matches!(self, Self::Chat | Self::Calendar | Self::Creative)
    }
}

impl TryFrom<&str> for ServiceNamespace {
    type Error = PlatformError;
    fn try_from(s: &str) -> Result<Self, Self::Error> {
        match s {
            "vault"     => Ok(Self::Vault),
            "calendar"  => Ok(Self::Calendar),
            "chat"      => Ok(Self::Chat),
            "files"     => Ok(Self::Files),
            "metadata"  => Ok(Self::Metadata),
            "ai"        => Ok(Self::Ai),
            "agents"    => Ok(Self::Agents),
            "creative"  => Ok(Self::Creative),
            "companion" => Ok(Self::Companion),
            other => Err(PlatformError::UnknownService(other.to_string())),
        }
    }
}

// ─── SPACE ───────────────────────────────────────────────────────────────────

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub enum Space {
    Core,
    Circle(String),  // circle DID
    Commons,
}

impl Space {
    pub fn as_str(&self) -> String {
        match self {
            Self::Core        => "core".to_string(),
            Self::Circle(did) => format!("circle:{}", did),
            Self::Commons     => "commons".to_string(),
        }
    }
}

impl TryFrom<&str> for Space {
    type Error = PlatformError;
    fn try_from(s: &str) -> Result<Self, Self::Error> {
        match s {
            "core"    => Ok(Self::Core),
            "commons" => Ok(Self::Commons),
            other if other.starts_with("circle:") =>
                Ok(Self::Circle(other[7..].to_string())),
            other =>
                Err(PlatformError::InvalidUri(format!("Unknown space: {}", other))),
        }
    }
}

// ─── PLATFORM URI ────────────────────────────────────────────────────────────

/// A fully-qualified PRZMA resource URI.
/// All service resources are addressable by one of these.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct PrzmaUri {
    pub did:       String,
    pub service:   ServiceNamespace,
    pub space:     Space,
    pub res_type:  String,   // "event", "entry", "message", "file", "memory", ...
    pub id:        String,
}

impl PrzmaUri {
    pub fn new(
        did:      impl Into<String>,
        service:  ServiceNamespace,
        space:    Space,
        res_type: impl Into<String>,
        id:       impl Into<String>,
    ) -> Self {
        Self {
            did:      did.into(),
            service,
            space,
            res_type: res_type.into(),
            id:       id.into(),
        }
    }

    /// Parse a przma:// URI string
    pub fn parse(uri: &str) -> PlatformResult<Self> {
        let stripped = uri.strip_prefix("przma://")
            .ok_or_else(|| PlatformError::InvalidUri(format!("Missing przma:// prefix: {}", uri)))?;

        let parts: Vec<&str> = stripped.splitn(5, '/').collect();
        if parts.len() < 5 {
            return Err(PlatformError::InvalidUri(
                format!("URI needs 5 components (did/service/space/type/id): {}", uri)
            ));
        }

        Ok(Self {
            did:      parts[0].to_string(),
            service:  ServiceNamespace::try_from(parts[1])?,
            space:    Space::try_from(parts[2])?,
            res_type: parts[3].to_string(),
            id:       parts[4].to_string(),
        })
    }

    /// Build the Lance table path for this resource
    pub fn lance_table_path(&self, base_path: &str) -> String {
        format!(
            "{}/{}/{}/{}/{}",
            base_path,
            self.did,
            self.service.lance_dir(),
            self.space.as_str(),
            self.res_type_to_table(),
        )
    }

    fn res_type_to_table(&self) -> String {
        // Pluralise the resource type for the Lance table name
        format!("{}s", self.res_type)
    }

    /// Whether this URI belongs to the same user as another
    pub fn same_user(&self, other: &Self) -> bool {
        self.did == other.did
    }

    /// Check if this is a cross-DID reference (shared resource)
    pub fn is_cross_did(&self, my_did: &str) -> bool {
        self.did != my_did
    }
}

impl fmt::Display for PrzmaUri {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(
            f, "przma://{}/{}/{}/{}/{}",
            self.did,
            self.service.as_str(),
            self.space.as_str(),
            self.res_type,
            self.id
        )
    }
}

// ─── URI BUILDER ─────────────────────────────────────────────────────────────

pub struct UriBuilder;

impl UriBuilder {
    pub fn vault_entry(did: &str, id: &str) -> PrzmaUri {
        PrzmaUri::new(did, ServiceNamespace::Vault, Space::Core, "entry", id)
    }

    pub fn calendar_event(did: &str, id: &str, space: Space) -> PrzmaUri {
        PrzmaUri::new(did, ServiceNamespace::Calendar, space, "event", id)
    }

    pub fn chat_message(did: &str, id: &str, space: Space) -> PrzmaUri {
        PrzmaUri::new(did, ServiceNamespace::Chat, space, "message", id)
    }

    pub fn file(did: &str, id: &str) -> PrzmaUri {
        PrzmaUri::new(did, ServiceNamespace::Files, Space::Core, "file", id)
    }

    pub fn companion_memory(did: &str, id: &str) -> PrzmaUri {
        PrzmaUri::new(did, ServiceNamespace::Companion, Space::Core, "memory", id)
    }

    pub fn agent_session(did: &str, id: &str) -> PrzmaUri {
        PrzmaUri::new(did, ServiceNamespace::Agents, Space::Core, "session", id)
    }

    pub fn creative_project(did: &str, id: &str, space: Space) -> PrzmaUri {
        PrzmaUri::new(did, ServiceNamespace::Creative, space, "project", id)
    }
}

// ─── TESTS ───────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_roundtrip_parse_display() {
        let uri = PrzmaUri::new(
            "did:web:alice.com",
            ServiceNamespace::Calendar,
            Space::Core,
            "event",
            "abc123",
        );
        let s    = uri.to_string();
        let back = PrzmaUri::parse(&s).unwrap();
        assert_eq!(back.did,     "did:web:alice.com");
        assert_eq!(back.service, ServiceNamespace::Calendar);
        assert_eq!(back.space,   Space::Core);
        assert_eq!(back.id,      "abc123");
    }

    #[test]
    fn test_parse_circle_space() {
        let s   = "przma://did:web:alice.com/chat/circle:did:web:family.przma.net/message/m1";
        let uri = PrzmaUri::parse(s).unwrap();
        assert_eq!(uri.service, ServiceNamespace::Chat);
        assert_eq!(uri.space,   Space::Circle("did:web:family.przma.net".into()));
    }

    #[test]
    fn test_lance_table_path() {
        let uri  = UriBuilder::vault_entry("did:web:alice.com", "entry1");
        let path = uri.lance_table_path("/var/przma/vaults");
        assert_eq!(path, "/var/przma/vaults/did:web:alice.com/vault/core/entrys");
    }

    #[test]
    fn test_unknown_service_fails() {
        let r = PrzmaUri::parse("przma://did:web:alice.com/unknown/core/thing/id1");
        assert!(r.is_err());
    }

    #[test]
    fn test_too_few_components_fails() {
        let r = PrzmaUri::parse("przma://did:web:alice.com/calendar/core");
        assert!(r.is_err());
    }

    #[test]
    fn test_builder_shortcuts() {
        let uri = UriBuilder::calendar_event("did:web:bob.com", "evt1", Space::Core);
        assert_eq!(uri.service, ServiceNamespace::Calendar);
        assert_eq!(uri.id, "evt1");

        let uri = UriBuilder::companion_memory("did:web:bob.com", "mem1");
        assert_eq!(uri.service, ServiceNamespace::Companion);
    }

    #[test]
    fn test_cross_did_detection() {
        let uri = UriBuilder::file("did:web:alice.com", "f1");
        assert!(!uri.is_cross_did("did:web:alice.com"));
        assert!(uri.is_cross_did("did:web:bob.com"));
    }

    #[test]
    fn test_offline_capability() {
        assert!(ServiceNamespace::Vault.offline_capable());
        assert!(ServiceNamespace::Calendar.offline_capable());
        assert!(!ServiceNamespace::Ai.offline_capable());
        assert!(!ServiceNamespace::Agents.offline_capable());
    }
}
