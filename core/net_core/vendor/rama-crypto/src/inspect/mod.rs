//! Authenticated encryption layered over any record storage service.
//!
//! Records are encoded as independently authenticated 64 KiB chunks followed by
//! an authenticated terminator. Readers authenticate each chunk before exposing
//! plaintext. Neither direction buffers the whole record. Range reads address
//! plaintext and currently scan/authenticate the preceding chunks. Partial reads
//! authenticate the chunks they expose; detection of a missing terminator or
//! trailing data requires consuming the record to EOF. A preview is not proof of
//! whole-record integrity.
//!
//! Available with both `inspect` and `boring`; enabling inspection does not select
//! a cryptographic backend for the application.

use std::{collections::BTreeMap, fmt, sync::Arc};

use parking_lot::RwLock;
use rama_core::{
    Layer, Service, bytes::Bytes, error::BoxError, futures::async_stream::stream_fn,
    stream::io::StreamReader,
};
use rama_inspect::storage::{
    AppendRecord, Collection, CreateCollection, ListRecords, ReadRecord, Reader, RecordId,
};
use tokio::io::AsyncReadExt;

use crate::dep::boring::{rand::rand_bytes, symm};

const CHUNK: usize = rama_utils::octets::kib(64);
const MAGIC: &[u8; 8] = b"RMINSP\x01\0";

/// Per-instance AES-256-GCM key. Debug output never reveals the key.
#[derive(Clone)]
pub struct EncryptStorageLayer {
    key: Arc<[u8; 32]>,
}

impl fmt::Debug for EncryptStorageLayer {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("EncryptStorageLayer")
            .finish_non_exhaustive()
    }
}

impl EncryptStorageLayer {
    pub fn new(key: [u8; 32]) -> Self {
        Self { key: Arc::new(key) }
    }

    pub fn random() -> Result<Self, BoxError> {
        let mut key = [0; 32];
        rand_bytes(&mut key)?;
        Ok(Self::new(key))
    }
}

impl<S> Layer<S> for EncryptStorageLayer {
    type Service = EncryptStore<S>;

    fn layer(&self, inner: S) -> Self::Service {
        EncryptStore {
            inner,
            key: self.key.clone(),
        }
    }
}

/// Storage service produced by [`EncryptStorageLayer`].
#[derive(Clone)]
pub struct EncryptStore<S> {
    inner: S,
    key: Arc<[u8; 32]>,
}

impl<S: fmt::Debug> fmt::Debug for EncryptStore<S> {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("EncryptStore")
            .field("inner", &self.inner)
            .finish_non_exhaustive()
    }
}

impl<S> Service<CreateCollection> for EncryptStore<S>
where
    S: Service<CreateCollection, Output = Collection, Error = BoxError>,
{
    type Output = Collection;
    type Error = BoxError;

    async fn serve(&self, input: CreateCollection) -> Result<Collection, BoxError> {
        let inner = self.inner.serve(input).await?;
        Ok(Collection::new(EncryptedCollection {
            inner,
            key: self.key.clone(),
            id: input.id,
            records: Arc::new(RwLock::new(BTreeMap::new())),
        }))
    }
}

#[derive(Clone)]
struct EncryptedCollection {
    inner: Collection,
    key: Arc<[u8; 32]>,
    id: u64,
    // Keep the expected stream identity outside the ciphertext. Substituting a
    // different valid record in the same collection must fail authentication.
    records: Arc<RwLock<BTreeMap<RecordId, [u8; 16]>>>,
}

fn aad(collection: u64, stream: &[u8; 16], sequence: u64, end: bool) -> [u8; 41] {
    let mut value = [0; 41];
    value[..8].copy_from_slice(MAGIC);
    value[8..16].copy_from_slice(&collection.to_be_bytes());
    value[16..32].copy_from_slice(stream);
    value[32..40].copy_from_slice(&sequence.to_be_bytes());
    value[40] = u8::from(end);
    value
}

fn invalid(message: &'static str) -> std::io::Error {
    std::io::Error::new(std::io::ErrorKind::InvalidData, message)
}

impl Service<AppendRecord> for EncryptedCollection {
    type Output = RecordId;
    type Error = BoxError;

    async fn serve(&self, input: AppendRecord) -> Result<RecordId, BoxError> {
        let mut source = input.into_reader();
        let mut identity = [0; 16];
        rand_bytes(&mut identity)?;
        let key = self.key.clone();
        let collection = self.id;
        let stream = stream_fn(move |mut output| async move {
            let mut header = Vec::with_capacity(MAGIC.len() + identity.len());
            header.extend_from_slice(MAGIC);
            header.extend_from_slice(&identity);
            output
                .yield_item(Ok::<_, std::io::Error>(Bytes::from(header)))
                .await;
            let mut buffer = vec![0; CHUNK];
            let mut sequence = 0u64;
            loop {
                let count = match source.read(&mut buffer).await {
                    Ok(count) => count,
                    Err(error) => {
                        output.yield_item(Err(error)).await;
                        return;
                    }
                };
                let result = (|| -> Result<Bytes, std::io::Error> {
                    let mut nonce = [0; 12];
                    rand_bytes(&mut nonce).map_err(std::io::Error::other)?;
                    // Encrypt directly into the published frame, avoiding a second
                    // ciphertext allocation and copy. GCM has no padding.
                    let cipher = symm::Cipher::aes_256_gcm();
                    let mut frame = vec![0; 32 + count + cipher.block_size()];
                    frame[..4].copy_from_slice(&(count as u32).to_be_bytes());
                    frame[4..16].copy_from_slice(&nonce);
                    let mut crypter =
                        symm::Crypter::new(cipher, symm::Mode::Encrypt, key.as_ref(), Some(&nonce))
                            .map_err(std::io::Error::other)?;
                    crypter
                        .aad_update(&aad(collection, &identity, sequence, count == 0))
                        .map_err(std::io::Error::other)?;
                    let written = crypter
                        .update(&buffer[..count], &mut frame[32..])
                        .map_err(std::io::Error::other)?;
                    let tail = crypter
                        .finalize(&mut frame[32 + written..])
                        .map_err(std::io::Error::other)?;
                    crypter
                        .get_tag(&mut frame[16..32])
                        .map_err(std::io::Error::other)?;
                    frame.truncate(32 + written + tail);
                    Ok(Bytes::from(frame))
                })();
                let failed = result.is_err();
                output.yield_item(result).await;
                if failed || count == 0 {
                    return;
                }
                if let Some(next) = sequence.checked_add(1) {
                    sequence = next;
                } else {
                    output
                        .yield_item(Err(invalid("encrypted sequence overflow")))
                        .await;
                    return;
                }
            }
        });
        let id = self
            .inner
            .serve(AppendRecord::new(StreamReader::new(Box::pin(stream))))
            .await?;
        // No await after the inner append publishes its record.
        self.records.write().insert(id, identity);
        Ok(id)
    }
}

impl Service<ReadRecord> for EncryptedCollection {
    type Output = Reader;
    type Error = BoxError;

    async fn serve(&self, input: ReadRecord) -> Result<Reader, BoxError> {
        let expected = self
            .records
            .read()
            .get(&input.id)
            .copied()
            .ok_or_else(|| invalid("encrypted record not found"))?;
        let mut reader = self.inner.read(input.id).await?;
        let key = self.key.clone();
        let collection = self.id;
        let stream = stream_fn(move |mut output| async move {
            let result = async {
                let mut header = [0; 24];
                reader.read_exact(&mut header).await?;
                if &header[..8] != MAGIC || header[8..] != expected {
                    return Err(invalid("encrypted record identity mismatch"));
                }
                let mut sequence = 0u64;
                let mut ciphertext = vec![0; CHUNK];
                loop {
                    let length = reader.read_u32().await? as usize;
                    if length > CHUNK {
                        return Err(invalid("encrypted chunk exceeds limit"));
                    }
                    let mut nonce = [0; 12];
                    let mut tag = [0; 16];
                    reader.read_exact(&mut nonce).await?;
                    reader.read_exact(&mut tag).await?;
                    reader.read_exact(&mut ciphertext[..length]).await?;
                    let plaintext = symm::decrypt_aead(
                        symm::Cipher::aes_256_gcm(),
                        key.as_ref(),
                        Some(&nonce),
                        &aad(collection, &expected, sequence, length == 0),
                        &ciphertext[..length],
                        &tag,
                    )
                    .map_err(std::io::Error::other)?;
                    if length == 0 {
                        let mut trailing = [0];
                        if reader.read(&mut trailing).await? != 0 {
                            return Err(invalid("trailing encrypted record content"));
                        }
                        return Ok::<(), std::io::Error>(());
                    }
                    output.yield_item(Ok(Bytes::from(plaintext))).await;
                    sequence = sequence
                        .checked_add(1)
                        .ok_or_else(|| invalid("encrypted sequence overflow"))?;
                }
            }
            .await;
            if let Err(error) = result {
                output.yield_item(Err(error)).await;
            }
        });
        rama_inspect::storage::range_reader(
            Box::pin(StreamReader::new(Box::pin(stream))),
            input.range,
        )
        .await
    }
}

impl Service<ListRecords> for EncryptedCollection {
    type Output = Vec<RecordId>;
    type Error = BoxError;

    async fn serve(&self, _: ListRecords) -> Result<Vec<RecordId>, BoxError> {
        Ok(self.records.read().keys().copied().collect())
    }
}

#[cfg(test)]
mod tests;
