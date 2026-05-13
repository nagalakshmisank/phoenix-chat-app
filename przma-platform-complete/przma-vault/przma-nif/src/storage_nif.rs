// przma-nif/src/storage_nif.rs
//
// Rustler NIFs for storage and encryption operations.
// These bridge Rust encryption and storage to the Elixir Phoenix layer.

use przma_calendar::storage::{
    adapter::{StorageAdapter, StorageMode, S3Credentials},
    encryption::{KeyTree, VaultKey},
};
use rustler::{Binary, Encoder, Env, OwnedBinary, Term};
use crate::{atoms, err_atom, ok_json, runtime};

// ─── ENCRYPTION NIFs ─────────────────────────────────────────────────────────

/// derive_namespace_key(master_key_hex, did, namespace) -> {:ok, key_info_json}
/// Returns metadata about the derived key (never the key bytes themselves over NIF)
#[rustler::nif(schedule = "DirtyCpu")]
pub fn derive_namespace_key<'a>(
    env:            Env<'a>,
    master_key_hex: String,
    did:            String,
    namespace:      String,
) -> Term<'a> {
    let master_bytes = match hex_to_bytes(&master_key_hex) {
        Ok(b)  => b,
        Err(e) => return err_atom(env, &e),
    };
    let tree = KeyTree::from_master_key(master_bytes, &did);
    let info = serde_json::json!({
        "key_path": tree.key_path(&namespace),
        "namespace": namespace,
        "did": did,
        "mode": "aes_256_gcm",
    });
    ok_json(env, &info)
}

/// derive_circle_key(master_key_hex, did, circle_did, namespace) -> {:ok, key_info_json}
#[rustler::nif(schedule = "DirtyCpu")]
pub fn derive_circle_key<'a>(
    env:            Env<'a>,
    master_key_hex: String,
    did:            String,
    circle_did:     String,
    namespace:      String,
) -> Term<'a> {
    let master_bytes = match hex_to_bytes(&master_key_hex) {
        Ok(b)  => b,
        Err(e) => return err_atom(env, &e),
    };
    let tree = KeyTree::from_master_key(master_bytes, &did);
    let info = serde_json::json!({
        "key_path": tree.circle_key_path(&circle_did, &namespace),
        "namespace": namespace,
        "circle_did": circle_did,
        "did": did,
        "mode": "aes_256_gcm",
    });
    ok_json(env, &info)
}

/// encrypt_blob(master_key_hex, did, namespace, plaintext, aad) -> {:ok, envelope_hex}
/// Returns encrypted envelope as hex string for storage
#[rustler::nif(schedule = "DirtyCpu")]
pub fn encrypt_blob<'a>(
    env:            Env<'a>,
    master_key_hex: String,
    did:            String,
    namespace:      String,
    plaintext:      Binary,
    aad:            Binary,
) -> Term<'a> {
    let master_bytes = match hex_to_bytes(&master_key_hex) {
        Ok(b)  => b,
        Err(e) => return err_atom(env, &e),
    };
    let tree = KeyTree::from_master_key(master_bytes, &did);
    let key  = tree.namespace_key(&namespace);
    match key.encrypt(plaintext.as_slice(), aad.as_slice()) {
        Ok(blob) => {
            match serde_json::to_string(&blob) {
                Ok(json) => ok_json(env, &json),
                Err(e)   => err_atom(env, &e.to_string()),
            }
        }
        Err(e) => err_atom(env, &e.to_string()),
    }
}

/// decrypt_blob(master_key_hex, did, namespace, envelope_json) -> {:ok, plaintext_binary}
#[rustler::nif(schedule = "DirtyCpu")]
pub fn decrypt_blob<'a>(
    env:            Env<'a>,
    master_key_hex: String,
    did:            String,
    namespace:      String,
    envelope_json:  String,
) -> Term<'a> {
    let master_bytes = match hex_to_bytes(&master_key_hex) {
        Ok(b)  => b,
        Err(e) => return err_atom(env, &e),
    };
    let blob: przma_calendar::storage::encryption::EncryptedBlob =
        match serde_json::from_str(&envelope_json) {
            Ok(b)  => b,
            Err(e) => return err_atom(env, &format!("Invalid envelope: {}", e)),
        };
    let tree = KeyTree::from_master_key(master_bytes, &did);
    let key  = tree.namespace_key(&namespace);
    match key.decrypt(&blob) {
        Ok(plaintext) => {
            let mut bin = OwnedBinary::new(plaintext.len()).unwrap();
            bin.as_mut_slice().copy_from_slice(&plaintext);
            (atoms::ok(), bin.release(env)).encode(env)
        }
        Err(e) => err_atom(env, &e.to_string()),
    }
}

// ─── STORAGE ADAPTER NIFs ─────────────────────────────────────────────────────

/// detect_storage_mode() -> {:ok, mode_json}
/// Reads environment to detect which deployment mode is active
#[rustler::nif]
pub fn detect_storage_mode<'a>(env: Env<'a>) -> Term<'a> {
    let adapter = StorageAdapter::from_env();
    let info    = serde_json::json!({
        "mode":     adapter.mode_name(),
        "is_local": adapter.is_local(),
    });
    ok_json(env, &info)
}

/// local_storage_put(base_path, key, data_binary) -> :ok | {:error, reason}
#[rustler::nif(schedule = "DirtyIo")]
pub fn local_storage_put<'a>(
    env:       Env<'a>,
    base_path: String,
    key:       String,
    data:      Binary,
) -> Term<'a> {
    let mode    = StorageMode::Local { base_path: std::path::PathBuf::from(&base_path) };
    let adapter = StorageAdapter::new(mode);
    let bytes   = data.as_slice().to_vec();
    runtime().block_on(async {
        match adapter.put(&key, &bytes).await {
            Ok(())  => atoms::ok().encode(env),
            Err(e)  => err_atom(env, &e.to_string()),
        }
    })
}

/// local_storage_get(base_path, key) -> {:ok, binary} | {:error, reason}
#[rustler::nif(schedule = "DirtyIo")]
pub fn local_storage_get<'a>(
    env:       Env<'a>,
    base_path: String,
    key:       String,
) -> Term<'a> {
    let mode    = StorageMode::Local { base_path: std::path::PathBuf::from(&base_path) };
    let adapter = StorageAdapter::new(mode);
    runtime().block_on(async {
        match adapter.get(&key).await {
            Ok(data) => {
                let mut bin = OwnedBinary::new(data.len()).unwrap();
                bin.as_mut_slice().copy_from_slice(&data);
                (atoms::ok(), bin.release(env)).encode(env)
            }
            Err(e) => err_atom(env, &e.to_string()),
        }
    })
}

/// validate_byos_credentials(creds_json) -> {:ok, %{valid: bool, expires_in_secs: n}}
#[rustler::nif(schedule = "DirtyIo")]
pub fn validate_byos_credentials<'a>(env: Env<'a>, creds_json: String) -> Term<'a> {
    let creds: S3Credentials = match serde_json::from_str(&creds_json) {
        Ok(c)  => c,
        Err(e) => return err_atom(env, &e.to_string()),
    };
    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs() as i64;
    let result = serde_json::json!({
        "valid":            !creds.is_expired(),
        "expires_in_secs":  (creds.expires_at - now).max(0),
        "mode":             "byos",
    });
    ok_json(env, &result)
}

// ─── HELPERS ─────────────────────────────────────────────────────────────────

fn hex_to_bytes(hex: &str) -> Result<[u8; 32], String> {
    if hex.len() != 64 {
        return Err(format!("Expected 64-char hex string, got {}", hex.len()));
    }
    let bytes = (0..32)
        .map(|i| u8::from_str_radix(&hex[i*2..i*2+2], 16))
        .collect::<Result<Vec<u8>, _>>()
        .map_err(|e| e.to_string())?;
    let mut arr = [0u8; 32];
    arr.copy_from_slice(&bytes);
    Ok(arr)
}
