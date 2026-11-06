//! 有界 TLS 票据持久化。密钥由宿主系统安全存储提供，文件只含 AES-GCM 密文。
use base64::{Engine as _, engine::general_purpose::STANDARD};
use parking_lot::Mutex;
use rama::error::BoxError;
use rama_crypto::dep::boring::{
    rand::rand_bytes,
    ssl::{SslSession, SslSessionRef},
    symm::{Cipher, decrypt_aead, encrypt_aead},
};
use serde::{Deserialize, Serialize};
use std::{
    collections::VecDeque,
    path::PathBuf,
    sync::{
        Arc, OnceLock, Weak,
        atomic::{AtomicBool, Ordering},
    },
    time::{Duration, SystemTime, UNIX_EPOCH},
};

const MAX_BYTES: usize = 512 * 1024;
const MAX_TICKETS: usize = 128;
const AAD: &[u8] = b"fluxdo TLS tickets v1 TCP platform verifier";
#[derive(Clone, Serialize, Deserialize)]
struct Ticket {
    scope: String,
    expires: u64,
    der: Vec<u8>,
}

pub struct TicketStore {
    path: PathBuf,
    key: [u8; 32],
    tickets: Mutex<VecDeque<Ticket>>,
    dirty: AtomicBool,
    saving: AtomicBool,
    file_lock: Mutex<()>,
}
fn now() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs()
}
impl TicketStore {
    pub fn open(path: PathBuf, key: &str) -> Result<Arc<Self>, BoxError> {
        let key: [u8; 32] = STANDARD
            .decode(key)?
            .try_into()
            .map_err(|_| BoxError::from("invalid ticket key length"))?;
        static STORES: OnceLock<Mutex<Vec<Weak<TicketStore>>>> = OnceLock::new();
        let mut stores = STORES.get_or_init(Default::default).lock();
        stores.retain(|store| store.strong_count() > 0);
        if let Some(store) = stores
            .iter()
            .filter_map(Weak::upgrade)
            .find(|s| s.path == path && s.key == key)
        {
            return Ok(store);
        }
        let mut tickets: VecDeque<Ticket> = std::fs::metadata(&path)
            .ok()
            .filter(|m| m.len() <= (MAX_BYTES + 28) as u64)
            .and_then(|_| std::fs::read(&path).ok())
            .and_then(|bytes| Self::decrypt(&key, &bytes).ok())
            .and_then(|bytes| serde_json::from_slice(&bytes).ok())
            .unwrap_or_default();
        tickets.retain(|ticket| {
            ticket.expires > now() && ticket.der.len() <= 16 * 1024 && ticket.scope.len() == 64
        });
        tickets.truncate(MAX_TICKETS);
        let store = Arc::new(Self {
            path,
            key,
            tickets: Mutex::new(tickets),
            dirty: AtomicBool::new(false),
            saving: AtomicBool::new(false),
            file_lock: Mutex::new(()),
        });
        stores.push(Arc::downgrade(&store));
        Ok(store)
    }
    fn decrypt(key: &[u8; 32], bytes: &[u8]) -> Result<Vec<u8>, BoxError> {
        if bytes.len() < 28 || bytes.len() > MAX_BYTES + 28 {
            return Err("invalid ticket cache length".into());
        }
        Ok(decrypt_aead(
            Cipher::aes_256_gcm(),
            key,
            Some(&bytes[..12]),
            AAD,
            &bytes[28..],
            &bytes[12..28],
        )?)
    }
    pub fn put(self: &Arc<Self>, scope: &str, session: &SslSessionRef) {
        let Ok(der) = session.to_der() else { return };
        if der.len() > 16 * 1024 {
            return;
        }
        let expires = session
            .time()
            .saturating_add(session.timeout() as u64)
            .min(now() + 86400);
        if expires <= now() {
            return;
        }
        let mut tickets = self.tickets.lock();
        tickets.retain(|t| t.expires > now());
        while tickets.iter().filter(|t| t.scope == scope).count() >= 2 {
            if let Some(i) = tickets.iter().position(|t| t.scope == scope) {
                tickets.remove(i);
            }
        }
        tickets.push_back(Ticket {
            scope: scope.to_owned(),
            expires,
            der,
        });
        while tickets.len() > MAX_TICKETS
            || tickets.iter().map(|t| t.der.len()).sum::<usize>() > MAX_BYTES / 5
        {
            tickets.pop_front();
        }
        drop(tickets);
        self.schedule();
    }
    pub fn take(self: &Arc<Self>, scope: &str) -> Option<SslSession> {
        let mut tickets = self.tickets.lock();
        tickets.retain(|t| t.expires > now());
        let i = tickets.iter().position(|t| t.scope == scope)?;
        let ticket = tickets.remove(i)?;
        drop(tickets);
        self.schedule();
        SslSession::from_der(&ticket.der).ok()
    }
    fn schedule(self: &Arc<Self>) {
        self.dirty.store(true, Ordering::Release);
        if self.saving.swap(true, Ordering::AcqRel) {
            return;
        }
        let store = self.clone();
        tokio::spawn(async move {
            loop {
                tokio::time::sleep(Duration::from_secs(1)).await;
                store.dirty.store(false, Ordering::Release);
                let writer = store.clone();
                let result = tokio::task::spawn_blocking(move || writer.flush()).await;
                if !matches!(result, Ok(Ok(()))) {
                    tracing::warn!("TLS session cache write failed; continuing with memory cache");
                }
                store.saving.store(false, Ordering::Release);
                if !store.dirty.load(Ordering::Acquire) || store.saving.swap(true, Ordering::AcqRel)
                {
                    break;
                }
            }
        });
    }
    pub(crate) fn flush(&self) -> Result<(), BoxError> {
        use std::io::Write;
        let _lock = self.file_lock.lock();
        let bytes = serde_json::to_vec(&*self.tickets.lock())?;
        if bytes.len() > MAX_BYTES {
            return Err("ticket budget exceeded".into());
        }
        let mut nonce = [0u8; 12];
        rand_bytes(&mut nonce)?;
        let mut tag = [0u8; 16];
        let cipher = encrypt_aead(
            Cipher::aes_256_gcm(),
            &self.key,
            Some(&nonce),
            AAD,
            &bytes,
            &mut tag,
        )?;
        if let Some(parent) = self.path.parent() {
            std::fs::create_dir_all(parent)?;
        }
        let temporary = self.path.with_extension("tmp");
        let mut options = std::fs::OpenOptions::new();
        options.create(true).truncate(true).write(true);
        #[cfg(unix)]
        {
            use std::os::unix::fs::OpenOptionsExt;
            options.mode(0o600);
        }
        let mut file = options.open(&temporary)?;
        file.write_all(&nonce)?;
        file.write_all(&tag)?;
        file.write_all(&cipher)?;
        file.sync_all()?;
        drop(file);
        std::fs::rename(temporary, &self.path)?;
        Ok(())
    }
}

pub fn scope(
    namespace: &str,
    host: &str,
    port: u16,
    hello: Option<&rama::tls::client::ClientHello>,
    ech: Option<&[u8]>,
) -> String {
    let bytes = serde_json::to_vec(&("TCP-platform-v1", namespace, host, port, hello, ech))
        .unwrap_or_default();
    rama_crypto::dep::boring::sha::sha256(&bytes)
        .iter()
        .map(|b| format!("{b:02x}"))
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn authenticated_cache_rejects_tampering_and_wrong_key() {
        let key = [7; 32];
        let nonce = [3; 12];
        let mut tag = [0; 16];
        let cipher = encrypt_aead(
            Cipher::aes_256_gcm(),
            &key,
            Some(&nonce),
            AAD,
            b"[]",
            &mut tag,
        )
        .unwrap();
        let mut bytes = [nonce.as_slice(), tag.as_slice(), cipher.as_slice()].concat();
        assert_eq!(TicketStore::decrypt(&key, &bytes).unwrap(), b"[]");
        assert!(TicketStore::decrypt(&[8; 32], &bytes).is_err());
        *bytes.last_mut().unwrap() ^= 1;
        assert!(TicketStore::decrypt(&key, &bytes).is_err());
    }
    #[test]
    fn ticket_scope_separates_policy_port_ech_and_origin() {
        let base = scope("doh-a", "a.test", 443, None, None);
        for other in [
            scope("doh-b", "a.test", 443, None, None),
            scope("doh-a", "b.test", 443, None, None),
            scope("doh-a", "a.test", 8443, None, None),
            scope("doh-a", "a.test", 443, None, Some(&[1])),
        ] {
            assert_ne!(base, other);
        }
    }
}
