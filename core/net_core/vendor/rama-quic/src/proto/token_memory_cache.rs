//! Storing tokens sent from servers in NEW_TOKEN frames and using them in subsequent connections

use std::{
    collections::VecDeque,
    num::{NonZeroU32, NonZeroUsize},
    sync::Arc,
};

use lru_slab::LruSlab;
use rama_core::telemetry::tracing::trace;

use ahash::{HashMap, HashMapExt as _};
use parking_lot::Mutex;

use crate::proto::token::{StoredToken, TokenStore, bounded_token};
use rama_quic_proto::Version;

/// `TokenStore` implementation that stores up to `N` tokens per server name for up to a
/// limited number of server names, in-memory
#[derive(Debug)]
pub struct TokenMemoryCache(Mutex<State>);

impl TokenMemoryCache {
    /// Construct empty
    pub(crate) fn new(max_server_names: u32, max_tokens_per_server: usize) -> Self {
        Self(Mutex::new(State::new(
            max_server_names,
            max_tokens_per_server,
        )))
    }
}

impl TokenStore for TokenMemoryCache {
    fn insert(&self, server_name: &str, version: Version, token: StoredToken) {
        trace!(%server_name, %version, "storing token");
        self.0.lock().store(server_name, version, token)
    }

    fn take(&self, server_name: &str, version: Version) -> Option<StoredToken> {
        let token = self.0.lock().take(server_name, version);
        trace!(%server_name, %version, found=%token.is_some(), "taking token");
        token
    }
}

/// Defaults to a maximum of 256 servers and 2 tokens per server
impl Default for TokenMemoryCache {
    fn default() -> Self {
        Self::new(256, 2)
    }
}

/// Lockable inner state of `TokenMemoryCache`
#[derive(Debug)]
struct State {
    /// `None` disables the cache: a zero server or token limit stores nothing.
    limits: Option<Limits>,
    // map from server name and version to index in lru
    lookup: HashMap<(Arc<str>, Version), u32>,
    lru: LruSlab<CacheEntry>,
}

/// Non-zero capacity of an enabled cache.
#[derive(Debug, Clone, Copy)]
struct Limits {
    server_names: NonZeroU32,
    tokens_per_server: NonZeroUsize,
}

impl State {
    fn new(max_server_names: u32, max_tokens_per_server: usize) -> Self {
        Self {
            limits: NonZeroU32::new(max_server_names)
                .zip(NonZeroUsize::new(max_tokens_per_server))
                .map(|(server_names, tokens_per_server)| Limits {
                    server_names,
                    tokens_per_server,
                }),
            lookup: HashMap::new(),
            lru: LruSlab::default(),
        }
    }

    fn store(&mut self, server_name: &str, version: Version, mut token: StoredToken) {
        let Some(limits) = self.limits else {
            return;
        };
        let Some(bytes) = bounded_token(&token.token) else {
            return;
        };
        token.token = bytes;
        if let Some(&slot) = self.lookup.get(&(Arc::from(server_name), version)) {
            // known server: the entry becomes most recent and takes the newest token
            self.lru
                .get_mut(slot)
                .tokens
                .push_newest(token, limits.tokens_per_server);
            return;
        }
        // new server: make room first, then insert into both the slab and the lookup together
        if self.lru.len() >= limits.server_names.get()
            && let Some(oldest) = self.lru.lru()
        {
            self.remove_entry(oldest);
        }
        let server_name = Arc::<str>::from(server_name);
        let slot = self.lru.insert(CacheEntry {
            server_name: server_name.clone(),
            version,
            tokens: Tokens::single(token),
        });
        self.lookup.insert((server_name, version), slot);
    }

    fn take(&mut self, server_name: &str, version: Version) -> Option<StoredToken> {
        let slot = *self.lookup.get(&(Arc::from(server_name), version))?;
        // `get_mut` marks the entry most recently used
        match self.lru.get_mut(slot).tokens.pop_oldest() {
            Some(token) => Some(token),
            // the last token leaves with its entry
            None => Some(self.remove_entry(slot).tokens.into_last()),
        }
    }

    /// Remove an entry from the slab and the lookup as one operation.
    fn remove_entry(&mut self, slot: u32) -> CacheEntry {
        let entry = self.lru.remove(slot);
        let removed = self
            .lookup
            .remove(&(entry.server_name.clone(), entry.version));
        debug_assert_eq!(removed, Some(slot));
        entry
    }
}

/// Cache entry within `TokenMemoryCache`'s LRU slab
#[derive(Debug)]
struct CacheEntry {
    server_name: Arc<str>,
    version: Version,
    tokens: Tokens,
}

/// The tokens of one server, oldest first; structurally never empty.
#[derive(Debug)]
struct Tokens {
    oldest: StoredToken,
    newer: VecDeque<StoredToken>,
}

impl Tokens {
    fn single(token: StoredToken) -> Self {
        Self {
            oldest: token,
            newer: VecDeque::new(),
        }
    }

    fn len(&self) -> usize {
        1 + self.newer.len()
    }

    /// Append the newest token, evicting the oldest when `max` tokens are already held.
    fn push_newest(&mut self, token: StoredToken, max: NonZeroUsize) {
        if self.len() >= max.get() {
            if let Some(next) = self.newer.pop_front() {
                self.oldest = next
            } else {
                self.oldest = token;
                return;
            }
        }
        self.newer.push_back(token);
    }

    /// Take the oldest token while at least one remains; `None` means the last token can only
    /// leave together with its owner via [`into_last`](Self::into_last).
    fn pop_oldest(&mut self) -> Option<StoredToken> {
        let next = self.newer.pop_front()?;
        Some(std::mem::replace(&mut self.oldest, next))
    }

    /// Consume the last token.
    fn into_last(self) -> StoredToken {
        debug_assert!(self.newer.is_empty(), "into_last on a multi-token entry");
        self.oldest
    }
}

#[cfg(test)]
mod tests {
    use std::collections::VecDeque;

    use super::*;
    use rama_core::bytes::Bytes;
    use rand::prelude::*;
    use rand_pcg::Pcg32;

    fn stored(token: Bytes) -> StoredToken {
        StoredToken::new(token, crate::proto::UNIX_EPOCH)
    }

    #[test]
    fn token_bytes_are_bounded_without_evicting_usable_entries() {
        let cache = TokenMemoryCache::new(1, 1);
        let maximum = usize::from(crate::proto::MAX_UDP_PAYLOAD);
        let accepted = vec![7; maximum];
        cache.insert("kept", Version::V1, stored(accepted.clone().into()));
        cache.insert("rejected", Version::V1, stored(vec![8; maximum + 1].into()));
        assert!(cache.take("rejected", Version::V1).is_none());
        assert_eq!(cache.take("kept", Version::V1).unwrap().token(), &accepted);
    }

    #[test]
    fn retained_tokens_do_not_pin_received_datagrams() {
        let cache = TokenMemoryCache::new(1, 1);
        let datagram = Bytes::from(vec![9; 65527]);
        let slice = datagram.slice(100..108);
        let pointer = slice.as_ptr();
        let token = stored(slice).with_peer_greasing_quic_bit(true);
        cache.insert("host", Version::V2, token);
        let token = cache.take("host", Version::V2).unwrap();
        assert_ne!(token.token().as_ptr(), pointer);
        assert_eq!(token.token().as_ref(), &[9; 8]);
        assert!(token.peer_greases_quic_bit());
        assert_eq!(token.received(), crate::proto::UNIX_EPOCH);
        assert_eq!(datagram.len(), 65527);
    }

    fn new_rng() -> impl Rng {
        Pcg32::new(0xdeadbeefdeadbeef, 0xdeadbeefdeadbeef)
    }

    /// Reference model: a list ordered least to most recently used, each server with its tokens
    /// oldest first. Store and take both make a server most recent.
    fn run_model(max_servers: usize, max_tokens: usize, names: u32, steps: usize) {
        let mut rng = new_rng();
        for _ in 0..10 {
            let mut model: Vec<(u32, VecDeque<Bytes>)> = Vec::new();
            let cache = TokenMemoryCache::new(max_servers as u32, max_tokens);
            let mut evicted_servers = 0;
            let mut evicted_tokens = 0;

            for i in 0..steps {
                let server_name = rng.random::<u32>() % names;
                if rng.random_bool(0.666) {
                    let token = Bytes::from(vec![(i % 251) as u8, (i / 251) as u8]);
                    if let Some(j) = model.iter().position(|(s, _)| *s == server_name) {
                        let (_, mut queue) = model.remove(j);
                        queue.push_back(token.clone());
                        if queue.len() > max_tokens {
                            queue.pop_front();
                            evicted_tokens += 1;
                        }
                        model.push((server_name, queue));
                    } else {
                        model.push((server_name, VecDeque::from([token.clone()])));
                        if model.len() > max_servers {
                            model.remove(0);
                            evicted_servers += 1;
                        }
                    }
                    cache.insert(&server_name.to_string(), Version::V1, stored(token));
                } else {
                    let expecting = model.iter().position(|(s, _)| *s == server_name).map(|j| {
                        let (_, mut queue) = model.remove(j);
                        let token = queue.pop_front().unwrap();
                        if !queue.is_empty() {
                            model.push((server_name, queue));
                        }
                        token
                    });
                    assert_eq!(
                        cache
                            .take(&server_name.to_string(), Version::V1)
                            .map(|stored| stored.token),
                        expecting,
                        "servers {max_servers} tokens {max_tokens} step {i}"
                    );
                }
                let state = cache.0.lock();
                assert_eq!(state.lru.len() as usize, model.len());
                assert_eq!(state.lookup.len(), model.len());
                assert!(state.lru.len() as usize <= max_servers);
                for (name, queue) in &model {
                    let slot = state.lookup[&(Arc::from(name.to_string().as_str()), Version::V1)];
                    assert_eq!(state.lru.peek(slot).tokens.len(), queue.len());
                }
            }
            if names as usize > max_servers {
                assert!(evicted_servers > 0, "trace must cross the server limit");
            }
            assert!(evicted_tokens > 0, "trace must cross the token limit");
        }
    }

    #[test]
    fn model_wide_cache() {
        run_model(20, 2, 10, 200);
    }

    #[test]
    fn model_small_caches_cross_both_limits() {
        run_model(2, 1, 4, 300);
        run_model(2, 2, 3, 300);
        run_model(3, 2, 5, 300);
        run_model(1, 1, 3, 200);
        run_model(1, 3, 2, 200);
    }

    #[test]
    fn take_refreshes_recency_and_slots_are_reused() {
        let cache = TokenMemoryCache::new(2, 2);
        cache.insert("a", Version::V1, stored(Bytes::from_static(b"a1")));
        cache.insert("a", Version::V1, stored(Bytes::from_static(b"a2")));
        cache.insert("b", Version::V1, stored(Bytes::from_static(b"b1")));
        // taking from `a` makes it most recent, so a third server evicts `b`
        assert_eq!(
            cache.take("a", Version::V1).map(|stored| stored.token),
            Some(Bytes::from_static(b"a1"))
        );
        cache.insert("c", Version::V1, stored(Bytes::from_static(b"c1")));
        assert_eq!(
            cache.take("b", Version::V1).map(|stored| stored.token),
            None
        );
        assert_eq!(
            cache.take("a", Version::V1).map(|stored| stored.token),
            Some(Bytes::from_static(b"a2"))
        );
        assert_eq!(
            cache.take("a", Version::V1).map(|stored| stored.token),
            None,
            "the last token leaves with its entry"
        );
        let slots: Vec<u32> = cache.0.lock().lookup.values().copied().collect();
        assert_eq!(slots.len(), 1);
        // reinserting `a` reuses a freed slot and the cache keeps working at the limit
        cache.insert("a", Version::V1, stored(Bytes::from_static(b"a3")));
        assert!(cache.0.lock().lru.len() == 2);
        assert_eq!(
            cache.take("c", Version::V1).map(|stored| stored.token),
            Some(Bytes::from_static(b"c1"))
        );
        assert_eq!(
            cache.take("a", Version::V1).map(|stored| stored.token),
            Some(Bytes::from_static(b"a3"))
        );
        assert!(cache.0.lock().lru.is_empty());
        assert!(cache.0.lock().lookup.is_empty());
    }

    /// RFC 9369 §5: a token belongs to the version of the connection that issued it.
    #[test]
    fn tokens_are_scoped_by_version() {
        let cache = TokenMemoryCache::new(4, 2);
        cache.insert("a", Version::V1, stored(Bytes::from_static(b"one")));
        cache.insert("a", Version::V2, stored(Bytes::from_static(b"two")));
        assert_eq!(
            cache.take("a", Version::V2).map(|stored| stored.token),
            Some(Bytes::from_static(b"two"))
        );
        assert_eq!(
            cache.take("a", Version::V2).map(|stored| stored.token),
            None
        );
        assert_eq!(
            cache.take("a", Version::V1).map(|stored| stored.token),
            Some(Bytes::from_static(b"one"))
        );
        assert_eq!(
            cache.take("a", Version::V1).map(|stored| stored.token),
            None
        );
    }

    #[test]
    fn single_token_limit_keeps_the_newest() {
        let cache = TokenMemoryCache::new(4, 1);
        cache.insert("a", Version::V1, stored(Bytes::from_static(b"old")));
        cache.insert("a", Version::V1, stored(Bytes::from_static(b"new")));
        assert_eq!(
            cache.take("a", Version::V1).map(|stored| stored.token),
            Some(Bytes::from_static(b"new"))
        );
        assert_eq!(
            cache.take("a", Version::V1).map(|stored| stored.token),
            None
        );
    }

    #[test]
    fn zero_max_server_names() {
        // test that this edge case doesn't panic
        let cache = TokenMemoryCache::new(0, 2);
        for i in 0..10 {
            cache.insert(&i.to_string(), Version::V1, stored(Bytes::from(vec![i])));
            for j in 0..10 {
                assert!(cache.take(&j.to_string(), Version::V1).is_none());
            }
        }
    }

    #[test]
    fn zero_queue_length() {
        // test that this edge case doesn't panic
        let cache = TokenMemoryCache::new(256, 0);
        for i in 0..10 {
            cache.insert(&i.to_string(), Version::V1, stored(Bytes::from(vec![i])));
            for j in 0..10 {
                assert!(cache.take(&j.to_string(), Version::V1).is_none());
            }
        }
    }
}
