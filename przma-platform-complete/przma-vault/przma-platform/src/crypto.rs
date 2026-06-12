// przma-platform/src/crypto.rs
//
// At-rest encryption for private CAS blobs.
//
// Uses XChaCha20-Poly1305 in the STREAM construction (chunked AEAD) so large
// files are encrypted/decrypted incrementally — never fully buffered in memory.
//
// On-disk encrypted blob layout:
//   [ MAGIC (8 bytes) ][ stream nonce prefix (19 bytes) ][ AEAD chunks... ]
//
// Each plaintext chunk is CHUNK_SIZE bytes; each ciphertext chunk is
// CHUNK_SIZE + 16 (Poly1305 tag). The final chunk is tagged as "last".
//
// The key is 32 bytes, supplied by the caller (e.g. from the OS keychain).

use chacha20poly1305::aead::stream::{DecryptorBE32, EncryptorBE32};
use chacha20poly1305::{KeyInit, XChaCha20Poly1305};
use rand::RngCore;
use tokio::io::{AsyncRead, AsyncReadExt, AsyncWrite, AsyncWriteExt};

use crate::{PlatformError, PlatformResult};

/// Identifies an encrypted blob on disk. Plaintext blobs never carry this.
pub const ENC_MAGIC: &[u8; 8] = b"PRZMAE01";

/// Plaintext chunk size (64 KiB). Ciphertext chunk = this + 16 (tag).
const CHUNK_SIZE: usize = 64 * 1024;
const TAG_SIZE: usize = 16;
/// XChaCha20Poly1305 nonce is 24 bytes; STREAM BE32 reserves 5, leaving a
/// 19-byte per-stream random prefix.
const NONCE_PREFIX_LEN: usize = 19;

/// A vault encryption key + AEAD primitive.
#[derive(Clone)]
pub struct VaultCipher {
    key: [u8; 32],
}

impl VaultCipher {
    pub fn new(key: [u8; 32]) -> Self {
        Self { key }
    }

    /// Generate a fresh random 32-byte key (e.g. on first run).
    pub fn generate_key() -> [u8; 32] {
        let mut key = [0u8; 32];
        rand::rngs::OsRng.fill_bytes(&mut key);
        key
    }

    fn aead(&self) -> XChaCha20Poly1305 {
        XChaCha20Poly1305::new(self.key.as_ref().into())
    }

    /// Stream-encrypt `reader` → `writer`. Returns the BLAKE3 hash of the
    /// *plaintext* (so dedup keys on content, not ciphertext) and total
    /// plaintext bytes read.
    pub async fn encrypt_stream<R, W>(
        &self,
        mut reader: R,
        mut writer: W,
    ) -> PlatformResult<(String, u64)>
    where
        R: AsyncRead + Unpin,
        W: AsyncWrite + Unpin,
    {
        // Random per-stream nonce prefix.
        let mut prefix = [0u8; NONCE_PREFIX_LEN];
        rand::rngs::OsRng.fill_bytes(&mut prefix);

        writer.write_all(ENC_MAGIC).await?;
        writer.write_all(&prefix).await?;

        let mut enc = EncryptorBE32::from_aead(self.aead(), prefix.as_ref().into());
        let mut hasher = blake3::Hasher::new();
        let mut total: u64 = 0;

        // Read one chunk ahead so we know which chunk is the last.
        let mut current = read_chunk(&mut reader, CHUNK_SIZE).await?;
        loop {
            let next = read_chunk(&mut reader, CHUNK_SIZE).await?;
            hasher.update(&current);
            total += current.len() as u64;

            if next.is_empty() {
                // `current` is the final chunk (may be empty for empty files).
                let ct = enc
                    .encrypt_last(current.as_slice())
                    .map_err(|e| PlatformError::Encoding(format!("encrypt_last: {e}")))?;
                writer.write_all(&ct).await?;
                break;
            } else {
                let ct = enc
                    .encrypt_next(current.as_slice())
                    .map_err(|e| PlatformError::Encoding(format!("encrypt_next: {e}")))?;
                writer.write_all(&ct).await?;
                current = next;
            }
        }

        writer.flush().await?;
        Ok((hasher.finalize().to_hex().to_string(), total))
    }

    /// Stream-decrypt `reader` (in the format written by `encrypt_stream`) →
    /// `writer`.
    pub async fn decrypt_stream<R, W>(
        &self,
        mut reader: R,
        mut writer: W,
    ) -> PlatformResult<()>
    where
        R: AsyncRead + Unpin,
        W: AsyncWrite + Unpin,
    {
        let mut magic = [0u8; ENC_MAGIC.len()];
        reader.read_exact(&mut magic).await?;
        if &magic != ENC_MAGIC {
            return Err(PlatformError::Encoding("not an encrypted blob".into()));
        }

        let mut prefix = [0u8; NONCE_PREFIX_LEN];
        reader.read_exact(&mut prefix).await?;

        let mut dec = DecryptorBE32::from_aead(self.aead(), prefix.as_ref().into());
        let enc_chunk = CHUNK_SIZE + TAG_SIZE;

        let mut current = read_chunk(&mut reader, enc_chunk).await?;
        loop {
            let next = read_chunk(&mut reader, enc_chunk).await?;
            if next.is_empty() {
                let pt = dec
                    .decrypt_last(current.as_slice())
                    .map_err(|e| PlatformError::Encoding(format!("decrypt_last: {e}")))?;
                writer.write_all(&pt).await?;
                break;
            } else {
                let pt = dec
                    .decrypt_next(current.as_slice())
                    .map_err(|e| PlatformError::Encoding(format!("decrypt_next: {e}")))?;
                writer.write_all(&pt).await?;
                current = next;
            }
        }

        writer.flush().await?;
        Ok(())
    }
}

/// Read exactly `n` bytes (or until EOF — short read at end is fine).
async fn read_chunk<R: AsyncRead + Unpin>(reader: &mut R, n: usize) -> PlatformResult<Vec<u8>> {
    let mut buf = vec![0u8; n];
    let mut filled = 0;
    while filled < n {
        let got = reader.read(&mut buf[filled..]).await?;
        if got == 0 {
            break;
        }
        filled += got;
    }
    buf.truncate(filled);
    Ok(buf)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Cursor;

    async fn round_trip(plaintext: &[u8]) {
        let cipher = VaultCipher::new(VaultCipher::generate_key());

        let mut encrypted = Vec::new();
        let (hash, total) = cipher
            .encrypt_stream(Cursor::new(plaintext.to_vec()), &mut encrypted)
            .await
            .unwrap();

        assert_eq!(total, plaintext.len() as u64);
        assert_eq!(hash, blake3::hash(plaintext).to_hex().to_string());
        assert!(encrypted.starts_with(ENC_MAGIC));
        // Ciphertext must differ from plaintext (unless empty).
        if !plaintext.is_empty() {
            assert_ne!(&encrypted[27..], plaintext);
        }

        let mut decrypted = Vec::new();
        cipher
            .decrypt_stream(Cursor::new(encrypted), &mut decrypted)
            .await
            .unwrap();

        assert_eq!(decrypted, plaintext);
    }

    #[tokio::test]
    async fn test_round_trip_small() {
        round_trip(b"hello private vault").await;
    }

    #[tokio::test]
    async fn test_round_trip_empty() {
        round_trip(b"").await;
    }

    #[tokio::test]
    async fn test_round_trip_multi_chunk() {
        // 200 KiB → spans several 64 KiB chunks incl. a partial final chunk.
        let data: Vec<u8> = (0..200 * 1024).map(|i| (i % 251) as u8).collect();
        round_trip(&data).await;
    }

    #[tokio::test]
    async fn test_wrong_key_fails() {
        let c1 = VaultCipher::new(VaultCipher::generate_key());
        let c2 = VaultCipher::new(VaultCipher::generate_key());

        let mut enc = Vec::new();
        c1.encrypt_stream(Cursor::new(b"secret".to_vec()), &mut enc).await.unwrap();

        let mut out = Vec::new();
        assert!(c2.decrypt_stream(Cursor::new(enc), &mut out).await.is_err());
    }
}
