//! 只保存允许跨网络保留的 Alt-Svc 能力；不保存 IP、失败状态或连接。
//! 全文件有界，按出口配置分区，后台合并写入；文件损坏时退回内存学习。
use parking_lot::Mutex;
use serde::{Deserialize, Serialize};
use std::{
    collections::VecDeque,
    io::{Read, Write},
    path::PathBuf,
    sync::{
        Arc, OnceLock, Weak,
        atomic::{AtomicBool, Ordering},
    },
    time::{Duration, SystemTime, UNIX_EPOCH},
};

const MAX_ENTRIES: usize = 64;
const MAX_BYTES: u64 = 64 * 1024;
const MAX_TTL: u64 = 86400;
const WRITE_DELAY: Duration = Duration::from_secs(60);

#[derive(Clone, Serialize, Deserialize)]
pub(super) struct Entry {
    pub port: u16,
    pub expires: u64,
}
#[derive(Clone, Serialize, Deserialize)]
struct Record {
    scope: String,
    origin: String,
    value: Entry,
}
pub(super) struct Store {
    path: PathBuf,
    entries: Mutex<VecDeque<Record>>,
    dirty: AtomicBool,
    saving: AtomicBool,
    file_lock: Mutex<()>,
}
pub(super) fn now() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs()
}
pub(super) fn scope(namespace: &str) -> String {
    rama_crypto::dep::boring::sha::sha256(namespace.as_bytes())
        .iter()
        .map(|b| format!("{b:02x}"))
        .collect()
}
fn valid_origin(origin: &str) -> bool {
    origin.len() <= 512
        && origin
            .parse::<rama::net::uri::Uri>()
            .ok()
            .is_some_and(|uri| {
                uri.scheme_str() == Some("https")
                    && uri.host().is_some()
                    && uri.port_u16().is_some_and(|p| p > 0)
                    && uri.query().is_none()
                    && uri.userinfo().is_none()
                    && uri
                        .path()
                        .is_none_or(|path| matches!(path.to_string().as_str(), "" | "/"))
            })
}
impl Store {
    pub fn open(path: PathBuf) -> Arc<Self> {
        // 重启核心时旧后台写入可能未结束，共享同一路径的存储，避免旧快照覆盖新值。
        static STORES: OnceLock<Mutex<Vec<Weak<Store>>>> = OnceLock::new();
        let mut stores = STORES.get_or_init(Default::default).lock();
        stores.retain(|s| s.strong_count() > 0);
        if let Some(store) = stores
            .iter()
            .filter_map(Weak::upgrade)
            .find(|s| s.path == path)
        {
            return store;
        }
        let mut bytes = Vec::new();
        let mut entries: VecDeque<Record> = std::fs::File::open(&path)
            .ok()
            .and_then(|file| file.take(MAX_BYTES + 1).read_to_end(&mut bytes).ok())
            .filter(|len| *len <= MAX_BYTES as usize)
            .and_then(|_| serde_json::from_slice(&bytes).ok())
            .unwrap_or_default();
        let time = now();
        entries.retain(|r| {
            r.scope.len() == 64
                && valid_origin(&r.origin)
                && r.value.port > 0
                && r.value.expires > time
                && r.value.expires <= time + MAX_TTL
        });
        entries.truncate(MAX_ENTRIES);
        let store = Arc::new(Self {
            path,
            entries: Mutex::new(entries),
            dirty: AtomicBool::new(false),
            saving: AtomicBool::new(false),
            file_lock: Mutex::new(()),
        });
        stores.push(Arc::downgrade(&store));
        store
    }
    pub fn entries(&self, scope: &str) -> Vec<(String, Entry)> {
        self.entries
            .lock()
            .iter()
            .filter(|r| r.scope == scope && r.value.expires > now())
            .map(|r| (r.origin.clone(), r.value.clone()))
            .collect()
    }
    pub fn update(self: &Arc<Self>, scope: &str, origin: &str, value: Option<Entry>) {
        if !valid_origin(origin) {
            return;
        }
        let mut entries = self.entries.lock();
        let old = entries
            .iter()
            .find(|r| r.scope == scope && r.origin == origin);
        if let (Some(old), Some(value)) = (old, &value) {
            // 高频图片响应会反复公告；一分钟内的 TTL 延长不产生额外磁盘工作。
            if old.value.port == value.port
                && value.expires >= old.value.expires
                && value.expires - old.value.expires < WRITE_DELAY.as_secs()
            {
                return;
            }
        } else if old.is_none() && value.is_none() {
            return;
        }
        entries.retain(|r| r.value.expires > now() && !(r.scope == scope && r.origin == origin));
        if let Some(value) = value.filter(|v| v.expires > now() && v.port > 0) {
            entries.push_back(Record {
                scope: scope.to_owned(),
                origin: origin.to_owned(),
                value,
            });
        }
        while entries.len() > MAX_ENTRIES {
            entries.pop_front();
        }
        drop(entries);
        self.schedule();
    }
    fn schedule(self: &Arc<Self>) {
        self.dirty.store(true, Ordering::Release);
        if self.saving.swap(true, Ordering::AcqRel) {
            return;
        }
        let store = self.clone();
        tokio::spawn(async move {
            loop {
                tokio::time::sleep(WRITE_DELAY).await;
                store.dirty.store(false, Ordering::Release);
                let writer = store.clone();
                if !matches!(
                    tokio::task::spawn_blocking(move || writer.flush()).await,
                    Ok(Ok(()))
                ) {
                    tracing::warn!("Alt-Svc cache write failed; continuing with memory cache");
                }
                store.saving.store(false, Ordering::Release);
                if !store.dirty.load(Ordering::Acquire) || store.saving.swap(true, Ordering::AcqRel)
                {
                    break;
                }
            }
        });
    }
    pub(super) fn flush(&self) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
        let _lock = self.file_lock.lock();
        let bytes = serde_json::to_vec(&*self.entries.lock())?;
        if bytes.len() as u64 > MAX_BYTES {
            return Err("Alt-Svc cache exceeds limit".into());
        }
        if let Some(parent) = self.path.parent() {
            std::fs::create_dir_all(parent)?;
        }
        let temporary = self.path.with_extension("altsvc.tmp");
        let mut options = std::fs::OpenOptions::new();
        options.create(true).truncate(true).write(true);
        #[cfg(unix)]
        {
            use std::os::unix::fs::OpenOptionsExt;
            options.mode(0o600);
        }
        let mut file = options.open(&temporary)?;
        file.write_all(&bytes)?;
        file.sync_all()?;
        drop(file);
        std::fs::rename(temporary, &self.path)?;
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn cache_limits_partition_and_rejects_corrupt_or_stale_records() {
        let directory = std::env::temp_dir().join(format!(
            "fluxdo-alt-limits-{}-{}",
            std::process::id(),
            SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        std::fs::create_dir_all(&directory).unwrap();
        let path = directory.join("cache.json");
        let store = Store::open(path.clone());
        let namespace = scope("direct");
        for index in 0..100 {
            store.update(
                &namespace,
                &format!("https://host{index}.test:443"),
                Some(Entry {
                    port: 443,
                    expires: now() + 600,
                }),
            );
        }
        assert_eq!(store.entries(&namespace).len(), MAX_ENTRIES);
        assert!(store.entries(&scope("proxy")).is_empty());
        store.flush().unwrap();
        assert!(std::fs::metadata(&path).unwrap().len() <= MAX_BYTES);
        let stale_path = directory.join("stale.json");
        let mut records = store.entries.lock().clone();
        for record in &mut records {
            record.value.expires = now() - 1;
        }
        std::fs::write(&stale_path, serde_json::to_vec(&records).unwrap()).unwrap();
        assert!(Store::open(stale_path).entries(&namespace).is_empty());
        let corrupt_path = directory.join("corrupt.json");
        std::fs::write(&corrupt_path, vec![b'x'; MAX_BYTES as usize + 1]).unwrap();
        assert!(Store::open(corrupt_path).entries(&namespace).is_empty());
        std::fs::remove_dir_all(directory).unwrap();
    }
}
