// przma-files/src/keymgr.rs
//
// Vault encryption key management, backed by the OS secure store
// (Windows Credential Manager / macOS Keychain / Linux Secret Service via the
// `keyring` crate). The 32-byte key is generated once per DID and persisted in
// the OS keychain — never written next to the encrypted data.

use base64::Engine;
use przma_platform::VaultCipher;

use crate::error::{FilesError, FilesResult};

const KEYRING_SERVICE: &str = "przma-files-vault";

/// Fetch the vault cipher for `did` from the OS keychain, generating and
/// storing a fresh key on first use.
pub fn get_or_create_cipher(did: &str) -> FilesResult<VaultCipher> {
    let entry = keyring::Entry::new(KEYRING_SERVICE, did)
        .map_err(|e| FilesError::Other(format!("keychain init failed: {e}")))?;

    match entry.get_password() {
        Ok(b64) => {
            let bytes = base64::engine::general_purpose::STANDARD
                .decode(b64.as_bytes())
                .map_err(|e| FilesError::Other(format!("vault key decode failed: {e}")))?;
            let key: [u8; 32] = bytes
                .try_into()
                .map_err(|_| FilesError::Other("vault key has wrong length".into()))?;
            Ok(VaultCipher::new(key))
        }
        Err(keyring::Error::NoEntry) => {
            // First run for this DID — mint and persist a key.
            let key = VaultCipher::generate_key();
            let b64 = base64::engine::general_purpose::STANDARD.encode(key);
            entry
                .set_password(&b64)
                .map_err(|e| FilesError::Other(format!("vault key store failed: {e}")))?;
            tracing::info!(did = %did, "Generated new vault encryption key in OS keychain");
            Ok(VaultCipher::new(key))
        }
        Err(e) => Err(FilesError::Other(format!("keychain read failed: {e}"))),
    }
}
