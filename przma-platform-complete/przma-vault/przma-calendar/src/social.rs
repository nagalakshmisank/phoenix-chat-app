// przma-calendar/src/social.rs
//
// Lance-backed social graph — replaces the PostgreSQL dependency for
// circle memberships and ActivityPub follower relationships.
//
// Two tables per user vault:
//   {base_path}/{did}/social/core/memberships.lance
//   {base_path}/{did}/social/core/followers.lance
//
// The Phoenix server has read access to all vaults under base_path,
// so cross-user membership queries work without a shared database.

use arrow_array::{BooleanArray, Int64Array, RecordBatch, StringArray};
use arrow_schema::{DataType, Field, Fields, Schema};
use chrono::{DateTime, Utc};
use futures::TryStreamExt;
use lancedb::{connect, query::QueryBase, Connection};
use serde::{Deserialize, Serialize};
use std::sync::Arc;
use crate::error::{CalendarError, CalendarResult};

// ─── SCHEMAS ─────────────────────────────────────────────────────────────────

pub fn membership_schema() -> Arc<Schema> {
    Arc::new(Schema::new(Fields::from(vec![
        Field::new("did",         DataType::Utf8, false),   // member DID
        Field::new("circle_did",  DataType::Utf8, false),   // circle DID
        Field::new("role",        DataType::Utf8, false),   // steward|guardian|contributor|participant|observer|guest
        Field::new("joined_at",   DataType::Int64, false),
        Field::new("added_by",    DataType::Utf8, true),
        Field::new("is_active",   DataType::Boolean, false),
        Field::new("updated_at",  DataType::Int64, false),
    ])))
}

pub fn follower_schema() -> Arc<Schema> {
    Arc::new(Schema::new(Fields::from(vec![
        Field::new("owner_did",    DataType::Utf8, false),  // whose follower list this is
        Field::new("follower_did", DataType::Utf8, false),  // who is following
        Field::new("inbox_url",    DataType::Utf8, false),  // AP inbox for delivery
        Field::new("is_active",    DataType::Boolean, false),
        Field::new("created_at",   DataType::Int64, false),
    ])))
}

// ─── DOMAIN TYPES ────────────────────────────────────────────────────────────

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CircleMembership {
    pub did:        String,
    pub circle_did: String,
    pub role:       String,
    pub joined_at:  DateTime<Utc>,
    pub added_by:   Option<String>,
    pub is_active:  bool,
    pub updated_at: DateTime<Utc>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Follower {
    pub owner_did:    String,
    pub follower_did: String,
    pub inbox_url:    String,
    pub is_active:    bool,
    pub created_at:   DateTime<Utc>,
}

// ─── MEMBERSHIP STORE ────────────────────────────────────────────────────────

pub struct MembershipStore {
    conn:      Connection,
    base_path: String,
}

impl MembershipStore {
    pub async fn new(base_path: impl Into<String>) -> CalendarResult<Self> {
        let base_path = base_path.into();
        let conn      = connect(&base_path).execute().await?;
        Ok(Self { conn, base_path })
    }

    fn path_for(&self, did: &str) -> String {
        format!("{}/{}/social/core/memberships", self.base_path, did)
    }

    async fn open_or_create(&self, did: &str) -> CalendarResult<lancedb::Table> {
        let path = self.path_for(did);
        match self.conn.open_table(&path).execute().await {
            Ok(t)  => Ok(t),
            Err(_) => Ok(self.conn.create_empty_table(&path, membership_schema()).execute().await?),
        }
    }

    // ── INSERT ───────────────────────────────────────────────────────────────

    pub async fn insert(&self, m: &CircleMembership) -> CalendarResult<()> {
        // Upsert: delete existing record for this (did, circle_did) pair first
        let table = self.open_or_create(&m.did).await?;
        table.delete(&format!("did = '{}' AND circle_did = '{}'", m.did, m.circle_did))
             .await.ok();

        let batch = membership_to_batch(m)?;
        table.add(vec![batch]).execute().await?;
        Ok(())
    }

    // ── GET ROLE ─────────────────────────────────────────────────────────────

    /// Get the role of `did` in `circle_did`. Returns None if not a member.
    pub async fn get_role(&self, did: &str, circle_did: &str) -> CalendarResult<Option<String>> {
        let table   = self.open_or_create(did).await?;
        let batches: Vec<RecordBatch> = table.query()
            .filter(format!(
                "did = '{}' AND circle_did = '{}' AND is_active = true",
                did, circle_did
            ))
            .limit(1)
            .execute().await?
            .try_collect().await
            .map_err(|e| CalendarError::Arrow(e.to_string()))?;

        Ok(batches.into_iter()
            .next()
            .and_then(|b| batch_to_memberships(b).ok())
            .and_then(|mut v| v.pop())
            .map(|m| m.role))
    }

    // ── LIST CIRCLES FOR DID ─────────────────────────────────────────────────

    pub async fn list_circles_for(&self, did: &str) -> CalendarResult<Vec<CircleMembership>> {
        let table   = self.open_or_create(did).await?;
        let batches: Vec<RecordBatch> = table.query()
            .filter(format!("did = '{}' AND is_active = true", did))
            .execute().await?
            .try_collect().await
            .map_err(|e| CalendarError::Arrow(e.to_string()))?;

        Ok(batches.into_iter()
            .flat_map(|b| batch_to_memberships(b).unwrap_or_default())
            .collect())
    }

    // ── LIST MEMBERS OF A CIRCLE ─────────────────────────────────────────────
    //
    // This requires reading each potential member's vault.
    // In practice the server maintains a small ETS index of {circle_did → [dids]}
    // that is rebuilt from Lance on startup. See PRZMA.Social.CircleIndex.
    // The Lance store is the source of truth; ETS is a read-cache.
    //
    // For small circles (< 50 members) a direct scan of known vault dirs is fine.
    // For large circles, the circle steward's vault holds a members_json column.

    pub async fn list_members(
        &self,
        circle_did:   &str,
        member_dids:  &[String],   // provided by CircleIndex
    ) -> CalendarResult<Vec<CircleMembership>> {
        let mut members = vec![];
        for did in member_dids {
            if let Ok(Some(role)) = self.get_role(did, circle_did).await {
                members.push(CircleMembership {
                    did:        did.clone(),
                    circle_did: circle_did.to_string(),
                    role,
                    joined_at:  Utc::now(),   // loaded lazily — full record in vault
                    added_by:   None,
                    is_active:  true,
                    updated_at: Utc::now(),
                });
            }
        }
        Ok(members)
    }

    // ── DEACTIVATE ───────────────────────────────────────────────────────────

    pub async fn deactivate(&self, did: &str, circle_did: &str) -> CalendarResult<()> {
        let table = self.open_or_create(did).await?;
        table.delete(&format!(
            "did = '{}' AND circle_did = '{}'", did, circle_did
        )).await?;

        let now = Utc::now();
        let record = CircleMembership {
            did:        did.to_string(),
            circle_did: circle_did.to_string(),
            role:       "removed".to_string(),
            joined_at:  now,
            added_by:   None,
            is_active:  false,
            updated_at: now,
        };
        let batch = membership_to_batch(&record)?;
        table.add(vec![batch]).execute().await?;
        Ok(())
    }

    // ── UPDATE ROLE ──────────────────────────────────────────────────────────

    pub async fn update_role(&self, did: &str, circle_did: &str, new_role: &str) -> CalendarResult<()> {
        let existing = self.get_role(did, circle_did).await?;
        if existing.is_none() {
            return Err(CalendarError::NotFound(format!("{} not in circle {}", did, circle_did)));
        }
        let record = CircleMembership {
            did:        did.to_string(),
            circle_did: circle_did.to_string(),
            role:       new_role.to_string(),
            joined_at:  Utc::now(),
            added_by:   None,
            is_active:  true,
            updated_at: Utc::now(),
        };
        self.insert(&record).await
    }
}

// ─── FOLLOWER STORE ──────────────────────────────────────────────────────────

pub struct FollowerStore {
    conn:      Connection,
    base_path: String,
}

impl FollowerStore {
    pub async fn new(base_path: impl Into<String>) -> CalendarResult<Self> {
        let base_path = base_path.into();
        let conn      = connect(&base_path).execute().await?;
        Ok(Self { conn, base_path })
    }

    fn path_for(&self, owner_did: &str) -> String {
        format!("{}/{}/social/core/followers", self.base_path, owner_did)
    }

    async fn open_or_create(&self, owner_did: &str) -> CalendarResult<lancedb::Table> {
        let path = self.path_for(owner_did);
        match self.conn.open_table(&path).execute().await {
            Ok(t)  => Ok(t),
            Err(_) => Ok(self.conn.create_empty_table(&path, follower_schema()).execute().await?),
        }
    }

    pub async fn insert(&self, follower: &Follower) -> CalendarResult<()> {
        let table = self.open_or_create(&follower.owner_did).await?;
        // Upsert
        table.delete(&format!(
            "owner_did = '{}' AND follower_did = '{}'",
            follower.owner_did, follower.follower_did
        )).await.ok();
        let batch = follower_to_batch(follower)?;
        table.add(vec![batch]).execute().await?;
        Ok(())
    }

    pub async fn list(&self, owner_did: &str) -> CalendarResult<Vec<Follower>> {
        let table   = self.open_or_create(owner_did).await?;
        let batches: Vec<RecordBatch> = table.query()
            .filter(format!("owner_did = '{}' AND is_active = true", owner_did))
            .execute().await?
            .try_collect().await
            .map_err(|e| CalendarError::Arrow(e.to_string()))?;

        Ok(batches.into_iter()
            .flat_map(|b| batch_to_followers(b).unwrap_or_default())
            .collect())
    }

    pub async fn remove(&self, owner_did: &str, follower_did: &str) -> CalendarResult<()> {
        let table = self.open_or_create(owner_did).await?;
        table.delete(&format!(
            "owner_did = '{}' AND follower_did = '{}'",
            owner_did, follower_did
        )).await?;
        Ok(())
    }

    pub async fn follower_count(&self, owner_did: &str) -> CalendarResult<usize> {
        Ok(self.list(owner_did).await?.len())
    }
}

// ─── SERIALISATION ───────────────────────────────────────────────────────────

fn membership_to_batch(m: &CircleMembership) -> CalendarResult<RecordBatch> {
    RecordBatch::try_new(membership_schema(), vec![
        Arc::new(StringArray::from(vec![m.did.as_str()])),
        Arc::new(StringArray::from(vec![m.circle_did.as_str()])),
        Arc::new(StringArray::from(vec![m.role.as_str()])),
        Arc::new(Int64Array::from(vec![m.joined_at.timestamp_micros()])),
        Arc::new(StringArray::from(vec![m.added_by.as_deref()])),
        Arc::new(BooleanArray::from(vec![m.is_active])),
        Arc::new(Int64Array::from(vec![m.updated_at.timestamp_micros()])),
    ]).map_err(|e| CalendarError::Arrow(e.to_string()))
}

fn batch_to_memberships(batch: RecordBatch) -> CalendarResult<Vec<CircleMembership>> {
    let n = batch.num_rows();
    let mut out = Vec::with_capacity(n);
    macro_rules! strs  { ($k:expr) => { batch.column_by_name($k).unwrap().as_any().downcast_ref::<StringArray>().unwrap() }; }
    macro_rules! i64s  { ($k:expr) => { batch.column_by_name($k).unwrap().as_any().downcast_ref::<Int64Array>().unwrap() }; }
    macro_rules! bools { ($k:expr) => { batch.column_by_name($k).unwrap().as_any().downcast_ref::<BooleanArray>().unwrap() }; }
    let ts = |v: i64| chrono::DateTime::from_timestamp_micros(v).unwrap_or_default();
    for i in 0..n {
        out.push(CircleMembership {
            did:        strs!("did").value(i).to_string(),
            circle_did: strs!("circle_did").value(i).to_string(),
            role:       strs!("role").value(i).to_string(),
            joined_at:  ts(i64s!("joined_at").value(i)),
            added_by:   if batch.column_by_name("added_by").unwrap().is_null(i) { None }
                        else { Some(strs!("added_by").value(i).to_string()) },
            is_active:  bools!("is_active").value(i),
            updated_at: ts(i64s!("updated_at").value(i)),
        });
    }
    Ok(out)
}

fn follower_to_batch(f: &Follower) -> CalendarResult<RecordBatch> {
    RecordBatch::try_new(follower_schema(), vec![
        Arc::new(StringArray::from(vec![f.owner_did.as_str()])),
        Arc::new(StringArray::from(vec![f.follower_did.as_str()])),
        Arc::new(StringArray::from(vec![f.inbox_url.as_str()])),
        Arc::new(BooleanArray::from(vec![f.is_active])),
        Arc::new(Int64Array::from(vec![f.created_at.timestamp_micros()])),
    ]).map_err(|e| CalendarError::Arrow(e.to_string()))
}

fn batch_to_followers(batch: RecordBatch) -> CalendarResult<Vec<Follower>> {
    let n = batch.num_rows();
    let mut out = Vec::with_capacity(n);
    macro_rules! strs  { ($k:expr) => { batch.column_by_name($k).unwrap().as_any().downcast_ref::<StringArray>().unwrap() }; }
    macro_rules! i64s  { ($k:expr) => { batch.column_by_name($k).unwrap().as_any().downcast_ref::<Int64Array>().unwrap() }; }
    macro_rules! bools { ($k:expr) => { batch.column_by_name($k).unwrap().as_any().downcast_ref::<BooleanArray>().unwrap() }; }
    let ts = |v: i64| chrono::DateTime::from_timestamp_micros(v).unwrap_or_default();
    for i in 0..n {
        out.push(Follower {
            owner_did:    strs!("owner_did").value(i).to_string(),
            follower_did: strs!("follower_did").value(i).to_string(),
            inbox_url:    strs!("inbox_url").value(i).to_string(),
            is_active:    bools!("is_active").value(i),
            created_at:   ts(i64s!("created_at").value(i)),
        });
    }
    Ok(out)
}

#[cfg(test)]
mod tests {
    use super::*;
    use tempfile::tempdir;

    #[tokio::test]
    async fn test_membership_insert_and_get_role() {
        let dir   = tempdir().unwrap();
        let store = MembershipStore::new(dir.path().to_str().unwrap()).await.unwrap();

        let m = CircleMembership {
            did:        "did:web:alice.com".to_string(),
            circle_did: "did:web:family.przma.net".to_string(),
            role:       "steward".to_string(),
            joined_at:  Utc::now(),
            added_by:   None,
            is_active:  true,
            updated_at: Utc::now(),
        };
        store.insert(&m).await.unwrap();

        let role = store.get_role("did:web:alice.com", "did:web:family.przma.net")
            .await.unwrap();
        assert_eq!(role, Some("steward".to_string()));
    }

    #[tokio::test]
    async fn test_non_member_returns_none() {
        let dir   = tempdir().unwrap();
        let store = MembershipStore::new(dir.path().to_str().unwrap()).await.unwrap();
        let role  = store.get_role("did:web:alice.com", "did:web:work.przma.net").await.unwrap();
        assert_eq!(role, None);
    }

    #[tokio::test]
    async fn test_update_role() {
        let dir   = tempdir().unwrap();
        let store = MembershipStore::new(dir.path().to_str().unwrap()).await.unwrap();

        store.insert(&CircleMembership {
            did: "did:web:alice.com".into(), circle_did: "did:web:c1.przma.net".into(),
            role: "participant".into(), joined_at: Utc::now(), added_by: None,
            is_active: true, updated_at: Utc::now(),
        }).await.unwrap();

        store.update_role("did:web:alice.com", "did:web:c1.przma.net", "guardian").await.unwrap();
        let role = store.get_role("did:web:alice.com", "did:web:c1.przma.net").await.unwrap();
        assert_eq!(role, Some("guardian".to_string()));
    }

    #[tokio::test]
    async fn test_deactivate_hides_membership() {
        let dir   = tempdir().unwrap();
        let store = MembershipStore::new(dir.path().to_str().unwrap()).await.unwrap();

        store.insert(&CircleMembership {
            did: "did:web:bob.com".into(), circle_did: "did:web:c1.przma.net".into(),
            role: "participant".into(), joined_at: Utc::now(), added_by: None,
            is_active: true, updated_at: Utc::now(),
        }).await.unwrap();

        store.deactivate("did:web:bob.com", "did:web:c1.przma.net").await.unwrap();
        let role = store.get_role("did:web:bob.com", "did:web:c1.przma.net").await.unwrap();
        assert_eq!(role, None);  // is_active = false → filtered out
    }

    #[tokio::test]
    async fn test_follower_insert_and_list() {
        let dir   = tempdir().unwrap();
        let store = FollowerStore::new(dir.path().to_str().unwrap()).await.unwrap();

        let f = Follower {
            owner_did:    "did:web:alice.com".to_string(),
            follower_did: "did:web:bob.com".to_string(),
            inbox_url:    "https://bob.przma.net/ap/inbox/did%3Aweb%3Abob.com".to_string(),
            is_active:    true,
            created_at:   Utc::now(),
        };
        store.insert(&f).await.unwrap();

        let followers = store.list("did:web:alice.com").await.unwrap();
        assert_eq!(followers.len(), 1);
        assert_eq!(followers[0].follower_did, "did:web:bob.com");
    }
}
