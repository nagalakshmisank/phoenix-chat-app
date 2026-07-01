// przma-calendar/src/storage/encryption.rs
//
// Client-side encryption for PRZMA vault data.
// AES-256-GCM authenticated encryption.
// HKDF key derivation: master key → DID key → namespace key → circle key.
// Data is encrypted on the user's device before any storage write.
// PRZMA infrastructure only ever receives and stores ciphertext.

use crate::error::{CalendarError, CalendarResult};
use serde::{Deserialize, Serialize};

// ─── CONSTANTS ───────────────────────────────────────────────────────────────

const AES_KEY_LEN:   usize = 32;   // AES-256
const NONCE_LEN:     usize = 12;   // GCM standard 96-bit nonce
const TAG_LEN:       usize = 16;   // GCM authentication tag

// ─── ENCRYPTED BLOB ──────────────────────────────────────────────────────────

/// An encrypted payload stored in CAS or Lance.
/// Format: [nonce (12)] + [ciphertext] + [tag (16)]
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct EncryptedBlob {
    pub version:    u8,           // encryption scheme version — always 1 for AES-256-GCM
    pub key_path:   String,       // key derivation path for decryption context
    pub ciphertext: Vec<u8>,      // nonce + ciphertext + tag
    pub aad:        Vec<u8>,      // additional authenticated data (e.g., record ID)
}

impl EncryptedBlob {
    /// Total encrypted size in bytes
    pub fn size(&self) -> usize {
        self.ciphertext.len()
    }

    /// Check that this blob matches an expected key path
    pub fn matches_key_path(&self, path: &str) -> bool {
        self.key_path == path
    }
}

// ─── KEY MATERIAL ─────────────────────────────────────────────────────────────

/// Holds a derived 256-bit encryption key for a specific namespace context
#[derive(Clone)]
pub struct VaultKey {
    pub key_path: String,
    key_bytes:    [u8; AES_KEY_LEN],
}

impl VaultKey {
    fn new(key_path: impl Into<String>, key_bytes: [u8; AES_KEY_LEN]) -> Self {
        Self { key_path: key_path.into(), key_bytes }
    }

    /// Encrypt plaintext bytes → EncryptedBlob
    pub fn encrypt(&self, plaintext: &[u8], aad: &[u8]) -> CalendarResult<EncryptedBlob> {
        let nonce = generate_nonce();
        let ciphertext = aes_gcm_encrypt(&self.key_bytes, &nonce, plaintext, aad)?;
        Ok(EncryptedBlob {
            version:    1,
            key_path:   self.key_path.clone(),
            ciphertext: [nonce.as_slice(), ciphertext.as_slice()].concat(),
            aad:        aad.to_vec(),
        })
    }

    /// Decrypt EncryptedBlob → plaintext bytes
    pub fn decrypt(&self, blob: &EncryptedBlob) -> CalendarResult<Vec<u8>> {
        if blob.ciphertext.len() < NONCE_LEN + TAG_LEN {
            return Err(CalendarError::Cas("Ciphertext too short".to_string()));
        }
        let (nonce_bytes, ciphertext) = blob.ciphertext.split_at(NONCE_LEN);
        let mut nonce = [0u8; NONCE_LEN];
        nonce.copy_from_slice(nonce_bytes);
        aes_gcm_decrypt(&self.key_bytes, &nonce, ciphertext, &blob.aad)
    }

    /// Derive a child key for a sub-context (e.g., circle or specific table)
    pub fn derive_child(&self, context: &str) -> VaultKey {
        let child_path = format!("{}:{}", self.key_path, context);
        let child_key  = hkdf_derive(&self.key_bytes, context.as_bytes());
        VaultKey::new(child_path, child_key)
    }
}

impl std::fmt::Debug for VaultKey {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "VaultKey {{ key_path: {:?}, key_bytes: [REDACTED] }}", self.key_path)
    }
}

// ─── KEY DERIVATION TREE ─────────────────────────────────────────────────────

/// The full key derivation tree for a PRZMA user.
///
/// Hierarchy:
///   master_key
///     └── did_key = HKDF(master, did)
///           ├── calendar_key = HKDF(did_key, "calendar")
///           ├── chat_key     = HKDF(did_key, "chat")
///           ├── files_key    = HKDF(did_key, "files")
///           └── circle_key   = HKDF(did_key, circle_did)
///                 └── circle_calendar_key = HKDF(circle_key, "calendar")
pub struct KeyTree {
    master_key: [u8; AES_KEY_LEN],
    did:        String,
}

impl KeyTree {
    /// Initialise from raw master key bytes (from user's secure key store)
    pub fn from_master_key(master_key: [u8; AES_KEY_LEN], did: impl Into<String>) -> Self {
        Self { master_key, did: did.into() }
    }

    /// Derive from a passphrase (dev/demo only — use hardware key store in production)
    pub fn from_passphrase(passphrase: &str, did: &str, salt: &[u8]) -> Self {
        let key = pbkdf2_derive(passphrase.as_bytes(), salt, 600_000);
        Self::from_master_key(key, did)
    }

    /// DID-level key: HKDF(master, did)
    pub fn did_key(&self) -> VaultKey {
        let k = hkdf_derive(&self.master_key, self.did.as_bytes());
        VaultKey::new(format!("did:{}", self.did), k)
    }

    /// Namespace key: HKDF(did_key, namespace)
    pub fn namespace_key(&self, namespace: &str) -> VaultKey {
        self.did_key().derive_child(namespace)
    }

    /// Circle key: HKDF(did_key, circle_did)
    pub fn circle_key(&self, circle_did: &str) -> VaultKey {
        self.did_key().derive_child(circle_did)
    }

    /// Circle namespace key: HKDF(circle_key, namespace)
    pub fn circle_namespace_key(&self, circle_did: &str, namespace: &str) -> VaultKey {
        self.circle_key(circle_did).derive_child(namespace)
    }

    /// Key path string for a given context (for EncryptedBlob.key_path)
    pub fn key_path(&self, namespace: &str) -> String {
        format!("did:{}:ns:{}", self.did, namespace)
    }

    pub fn circle_key_path(&self, circle_did: &str, namespace: &str) -> String {
        format!("did:{}:circle:{}:ns:{}", self.did, circle_did, namespace)
    }
}

// ─── ENCRYPTION PRIMITIVES ───────────────────────────────────────────────────
// Phase 5: real AES-256-GCM via ring or aes-gcm crate.
// For now: ChaCha20 simulation using BLAKE3 XOF as keystream + BLAKE3 MAC as tag.
// This is NOT production-secure — real crypto wired in Phase 5 final.

fn aes_gcm_encrypt(
    key:       &[u8; AES_KEY_LEN],
    nonce:     &[u8; NONCE_LEN],
    plaintext: &[u8],
    aad:       &[u8],
) -> CalendarResult<Vec<u8>> {
    // Phase 5 placeholder: XOR with BLAKE3-derived keystream
    let keystream = blake3_keystream(key, nonce, plaintext.len() + TAG_LEN);
    let mut ciphertext = plaintext.to_vec();
    for (b, k) in ciphertext.iter_mut().zip(keystream.iter()) {
        *b ^= k;
    }
    // Append authentication tag (BLAKE3 MAC over nonce + ciphertext + aad)
    let tag = compute_tag(key, nonce, &ciphertext, aad);
    ciphertext.extend_from_slice(&tag);
    Ok(ciphertext)
}

fn aes_gcm_decrypt(
    key:        &[u8; AES_KEY_LEN],
    nonce:      &[u8; NONCE_LEN],
    ciphertext: &[u8],  // includes tag
    aad:        &[u8],
) -> CalendarResult<Vec<u8>> {
    if ciphertext.len() < TAG_LEN {
        return Err(CalendarError::Cas("Ciphertext too short for tag".to_string()));
    }
    let (ct, tag) = ciphertext.split_at(ciphertext.len() - TAG_LEN);
    // Verify tag
    let expected_tag = compute_tag(key, nonce, ct, aad);
    if !constant_time_eq(tag, &expected_tag) {
        return Err(CalendarError::Cas("Authentication tag mismatch".to_string()));
    }
    // Decrypt
    let keystream = blake3_keystream(key, nonce, ct.len());
    let mut plaintext = ct.to_vec();
    for (b, k) in plaintext.iter_mut().zip(keystream.iter()) {
        *b ^= k;
    }
    Ok(plaintext)
}

fn hkdf_derive(input_key: &[u8], info: &[u8]) -> [u8; AES_KEY_LEN] {
    // HKDF-like derivation using BLAKE3 keyed hash
    let mut hasher = blake3::Hasher::new_derive_key(
        std::str::from_utf8(info).unwrap_or("przma-key-derivation")
    );
    hasher.update(input_key);
    let mut out = [0u8; AES_KEY_LEN];
    hasher.finalize_xof().fill(&mut out);
    out
}

fn pbkdf2_derive(password: &[u8], salt: &[u8], _iterations: u32) -> [u8; AES_KEY_LEN] {
    // Simplified for Phase 5 — real PBKDF2 with SHA-256 in production
    let mut hasher = blake3::Hasher::new_keyed(&{
        let mut k = [0u8; 32];
        k[..salt.len().min(32)].copy_from_slice(&salt[..salt.len().min(32)]);
        k
    });
    hasher.update(password);
    let mut out = [0u8; AES_KEY_LEN];
    hasher.finalize_xof().fill(&mut out);
    out
}

fn blake3_keystream(key: &[u8; AES_KEY_LEN], nonce: &[u8; NONCE_LEN], len: usize) -> Vec<u8> {
    let mut input = Vec::with_capacity(AES_KEY_LEN + NONCE_LEN);
    input.extend_from_slice(key);
    input.extend_from_slice(nonce);
    let mut out = vec![0u8; len];
    blake3::Hasher::new().update(&input).finalize_xof().fill(&mut out);
    out
}

fn compute_tag(key: &[u8; AES_KEY_LEN], nonce: &[u8], ct: &[u8], aad: &[u8]) -> [u8; TAG_LEN] {
    let mut hasher = blake3::Hasher::new_keyed(key);
    hasher.update(nonce);
    hasher.update(aad);
    hasher.update(ct);
    let mut tag = [0u8; TAG_LEN];
    hasher.finalize_xof().fill(&mut tag);
    tag
}

fn generate_nonce() -> [u8; NONCE_LEN] {
    // Phase 5: use OS CSPRNG via getrandom crate
    let mut nonce = [0u8; NONCE_LEN];
    let ts = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default()
        .as_nanos();
    let hash = blake3::hash(&ts.to_le_bytes());
    nonce.copy_from_slice(&hash.as_bytes()[..NONCE_LEN]);
    nonce
}

fn constant_time_eq(a: &[u8], b: &[u8]) -> bool {
    if a.len() != b.len() { return false; }
    a.iter().zip(b.iter()).fold(0u8, |acc, (x, y)| acc | (x ^ y)) == 0
}

// ─── ENCRYPTED CAS STORE ─────────────────────────────────────────────────────

/// Wraps CasStore with transparent client-side encryption.
/// Callers work with plaintext — encryption/decryption is automatic.
pub struct EncryptedCasStore {
    inner: crate::cas::CasStore,
    key:   VaultKey,
}

impl EncryptedCasStore {
    pub fn new(
        base_path:  impl Into<std::path::PathBuf>,
        did:        impl Into<String>,
        vault_key:  VaultKey,
    ) -> Self {
        Self {
            inner: crate::cas::CasStore::new(base_path, did),
            key:   vault_key,
        }
    }

    /// Encrypt and store plaintext. Returns BLAKE3 hash of plaintext (for dedup).
    pub async fn put(&self, plaintext: &[u8]) -> CalendarResult<String> {
        let blob     = self.key.encrypt(plaintext, b"")?;
        let envelope = serde_json::to_vec(&blob)
            .map_err(|e| CalendarError::Serde(e))?;
        // Store the encrypted envelope; hash is of plaintext for stable CAS IDs
        let hash = crate::cas::hash_bytes(plaintext);
        self.inner.put(&envelope).await?;
        Ok(hash)
    }

    /// Retrieve and decrypt.
    pub async fn get(&self, hash: &str) -> CalendarResult<Vec<u8>> {
        let envelope = self.inner.get(hash).await?;
        let blob: EncryptedBlob = serde_json::from_slice(&envelope)
            .map_err(|e| CalendarError::Serde(e))?;
        self.key.decrypt(&blob)
    }
}

// ─── TESTS ───────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;

    fn test_key() -> VaultKey {
        let tree = KeyTree::from_passphrase("test-password", "did:web:alice.com", b"salt1234");
        tree.namespace_key("calendar")
    }

    #[test]
    fn test_encrypt_decrypt_round_trip() {
        let key       = test_key();
        let plaintext = b"PRZMA calendar event data — sovereign";
        let aad       = b"event-id-123";
        let blob      = key.encrypt(plaintext, aad).unwrap();
        let recovered = key.decrypt(&blob).unwrap();
        assert_eq!(recovered, plaintext);
    }

    #[test]
    fn test_aad_prevents_tampering() {
        let key       = test_key();
        let plaintext = b"sensitive data";
        let blob      = key.encrypt(plaintext, b"correct-aad").unwrap();
        // Attempt to decrypt with wrong AAD
        let wrong_blob = EncryptedBlob { aad: b"wrong-aad".to_vec(), ..blob };
        assert!(key.decrypt(&wrong_blob).is_err());
    }

    #[test]
    fn test_key_derivation_is_deterministic() {
        let tree1 = KeyTree::from_passphrase("pass", "did:web:alice.com", b"salt");
        let tree2 = KeyTree::from_passphrase("pass", "did:web:alice.com", b"salt");
        let k1    = tree1.namespace_key("calendar");
        let k2    = tree2.namespace_key("calendar");
        // Same inputs → same key
        assert_eq!(k1.key_bytes, k2.key_bytes);
    }

    #[test]
    fn test_different_namespaces_produce_different_keys() {
        let tree = KeyTree::from_passphrase("pass", "did:web:alice.com", b"salt");
        let cal  = tree.namespace_key("calendar");
        let chat = tree.namespace_key("chat");
        assert_ne!(cal.key_bytes, chat.key_bytes);
    }

    #[test]
    fn test_circle_key_differs_from_personal() {
        let tree     = KeyTree::from_passphrase("pass", "did:web:alice.com", b"salt");
        let personal = tree.namespace_key("calendar");
        let circle   = tree.circle_namespace_key("did:web:family.przma.net", "calendar");
        assert_ne!(personal.key_bytes, circle.key_bytes);
    }

    #[test]
    fn test_different_dids_produce_different_keys() {
        let tree1 = KeyTree::from_passphrase("pass", "did:web:alice.com", b"salt");
        let tree2 = KeyTree::from_passphrase("pass", "did:web:bob.com",   b"salt");
        let k1    = tree1.namespace_key("calendar");
        let k2    = tree2.namespace_key("calendar");
        assert_ne!(k1.key_bytes, k2.key_bytes);
    }

    #[test]
    fn test_constant_time_eq() {
        assert!(constant_time_eq(b"abc", b"abc"));
        assert!(!constant_time_eq(b"abc", b"abd"));
        assert!(!constant_time_eq(b"abc", b"abcd"));
    }

    #[test]
    fn test_key_path_format() {
        let tree = KeyTree::from_passphrase("p", "did:web:alice.com", b"s");
        assert_eq!(tree.key_path("calendar"), "did:did:web:alice.com:ns:calendar");
        assert_eq!(
            tree.circle_key_path("did:web:family.przma.net", "calendar"),
            "did:did:web:alice.com:circle:did:web:family.przma.net:ns:calendar"
        );
    }
}
