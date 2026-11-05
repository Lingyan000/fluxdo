//! Bounded reuse of native QUIC TLS configurations and their session state.

use std::{collections::VecDeque, fmt, sync::Arc};

use parking_lot::Mutex;
use rama_core::{error::BoxError, extensions::Extensions};
use rama_net::{address::Host, tls::AlpnPolicy};
use rama_tls::client::{TlsClientConfig, TlsPoolId, TlsServerName};

use super::{
    ClientHandshake, ClientSessionPolicy, QuicClientConfigProvider, TlsConfigError, TlsOptions,
};
use crate::ClientConfig;

// Keep native override configurations bounded alongside the protected default context.
const MAX_CACHED_OVERRIDES: usize = 64;

/// Reuse native TLS configuration and session state when opening QUIC connections.
///
/// A cache belongs to one provider and fixed QUIC TLS defaults. An explicit
/// [`AlpnPolicy`] in the common TLS configuration overrides the ALPN default.
/// Clones share its
/// state: one protected default entry and up to 64 recently used override entries.
/// Shared custom components retain session state. Request policies explicitly
/// marked non-reusable bypass caching. Failed builds are never retained. Providers
/// must identify changed defaults, or keep them fixed for the cache's lifetime.
///
/// This does not pool connections or apply request overrides. Supply the final
/// TLS configuration to [`Self::client_config`], then customize transport settings
/// on the returned [`ClientConfig`] as needed; each result is an independent clone
/// sharing the native TLS configuration and its session state. Providers can also
/// share a bounded, policy-keyed ticket store across sibling native configurations.
/// Fresh client policies still cache native configurations, but skip provider
/// ticket defaults and require the provider to disable ticket storage and offers.
#[derive(Clone)]
pub struct ClientConfigCache {
    provider: Arc<dyn QuicClientConfigProvider>,
    options: TlsOptions,
    configs: Arc<Mutex<Configs>>,
}

impl fmt::Debug for ClientConfigCache {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("ClientConfigCache")
            .field("provider", &self.provider)
            .field("options", &self.options)
            .finish_non_exhaustive()
    }
}

impl ClientConfigCache {
    fn effective_options(&self, config: &TlsClientConfig) -> TlsOptions {
        config
            .as_extensions()
            .get_ref::<AlpnPolicy>()
            .map_or(self.options, |policy| self.options.with_alpn(*policy))
    }

    /// Bind cached configurations to one provider and its QUIC TLS options.
    pub fn new(provider: Arc<dyn QuicClientConfigProvider>, options: TlsOptions) -> Self {
        let session_defaults = match options.client_sessions {
            ClientSessionPolicy::Reuse => provider.session_defaults(),
            ClientSessionPolicy::Fresh => None,
        };
        Self {
            provider,
            options,
            configs: Arc::new(Mutex::new(Configs {
                session_defaults,
                ..Configs::default()
            })),
        }
    }

    /// The provider used both to classify policies and to construct configurations.
    pub fn provider(&self) -> &Arc<dyn QuicClientConfigProvider> {
        &self.provider
    }

    /// Prepare a peer-bound handshake with this connector's ticket domain and
    /// options. Prepared state bypasses the ordinary configuration cache; only
    /// backend session metadata is shared.
    pub fn prepare_client_config(
        &self,
        config: &TlsClientConfig,
        peer: Host,
        handshake: ClientHandshake,
    ) -> Result<Option<ClientConfig>, TlsConfigError> {
        let defaults = self.configs.lock().session_defaults.clone();
        let scoped;
        let config = if let Some(defaults) = defaults {
            scoped = config.clone();
            scoped.as_extensions().extend(&defaults);
            &scoped
        } else {
            config
        };
        self.provider
            .prepare_client_config(config, self.effective_options(config), peer, handshake)
    }

    /// Build or reuse the final TLS configuration, classified by this cache's provider.
    ///
    /// `overrides` contains request settings before connector defaults are applied.
    /// It selects the protected default slot or bounded override cache and makes
    /// explicitly non-reusable request policies bypass caching even if masked later.
    /// The key combines the request identity with the effective configuration
    /// identity, including final application requirements such as ALPN. Defaults
    /// are checked on each call; any defaults omitted from the identity must remain
    /// fixed. Provider classification must cover every relevant setting.
    ///
    /// Provider code runs outside the cache lock. Concurrent equivalent builds
    /// may do redundant work, but converge on the same retained configuration.
    pub fn client_config(
        &self,
        config: &TlsClientConfig,
        overrides: &Extensions,
    ) -> Result<ClientConfig, TlsConfigError> {
        if config
            .as_extensions()
            .get_ref::<ClientHandshake>()
            .is_some_and(|mode| *mode != ClientHandshake::Auto)
        {
            let peer = config
                .as_extensions()
                .get_ref::<TlsServerName>()
                .ok_or_else(|| {
                    TlsConfigError::InvalidConfiguration(BoxError::from(
                        "an explicit QUIC handshake policy requires a destination",
                    ))
                })?;
            return self.client_config_for_peer(config, overrides, &peer.0);
        }
        self.cached_client_config(config, overrides)
    }

    /// Build native TLS for `peer`, applying any explicit handshake-offer policy.
    /// The configured provider and ticket domain remain authoritative. A provider
    /// without that capability returns an error instead of silently ignoring it.
    /// Peer-bound prepared sessions bypass the ordinary configuration cache.
    pub fn client_config_for_peer(
        &self,
        config: &TlsClientConfig,
        overrides: &Extensions,
        peer: &Host,
    ) -> Result<ClientConfig, TlsConfigError> {
        if let Some(handshake) = config
            .as_extensions()
            .get_ref::<ClientHandshake>()
            .filter(|mode| **mode != ClientHandshake::Auto)
        {
            return self
                .prepare_client_config(config, peer.clone(), *handshake)?
                .ok_or_else(|| {
                    TlsConfigError::InvalidConfiguration(BoxError::from(
                        "TLS provider does not support the requested QUIC handshake policy",
                    ))
                });
        }
        self.cached_client_config(config, overrides)
    }

    fn cached_client_config(
        &self,
        config: &TlsClientConfig,
        overrides: &Extensions,
    ) -> Result<ClientConfig, TlsConfigError> {
        let request_policy = self.provider.pool_id(overrides);
        let effective_policy = self.provider.pool_id(config.as_extensions());
        if request_policy.as_ref().is_some_and(|id| !id.is_reusable()) {
            return self
                .provider
                .client_config(config, self.effective_options(config));
        }

        // An opaque default is scoped to this cache, not shared across connectors.
        // Keep comparable request overrides distinct even if the effective ID is opaque.
        let is_default = request_policy.is_none();
        let policy = (request_policy, effective_policy);
        let session_defaults = {
            let mut configs = self.configs.lock();
            if let Some(config) = configs.get(&policy, is_default) {
                return Ok(config);
            }
            configs.session_defaults.clone()
        };
        let scoped;
        let config = if let Some(defaults) = session_defaults {
            scoped = config.clone();
            scoped.as_extensions().extend(&defaults);
            &scoped
        } else {
            config
        };
        let config = self
            .provider
            .client_config(config, self.effective_options(config))?;
        let mut configs = self.configs.lock();
        if let Some(existing) = configs.get(&policy, is_default) {
            return Ok(existing);
        }
        configs.insert(policy, is_default, config.clone());
        Ok(config)
    }
}

type Policy = (Option<TlsPoolId>, Option<TlsPoolId>);

struct Entry {
    policy: Policy,
    config: ClientConfig,
}

#[derive(Default)]
struct Configs {
    session_defaults: Option<Extensions>,
    default: Option<Entry>,
    overrides: VecDeque<Entry>,
}

impl Configs {
    fn get(&mut self, policy: &Policy, is_default: bool) -> Option<ClientConfig> {
        if is_default {
            return self
                .default
                .as_ref()
                .filter(|entry| &entry.policy == policy)
                .map(|entry| entry.config.clone());
        }
        let index = self
            .overrides
            .iter()
            .position(|entry| &entry.policy == policy)?;
        let entry = self.overrides.remove(index)?;
        let config = entry.config.clone();
        self.overrides.push_front(entry);
        Some(config)
    }

    fn insert(&mut self, policy: Policy, is_default: bool, config: ClientConfig) {
        let entry = Entry { policy, config };
        if is_default {
            self.default = Some(entry);
        } else {
            if self.overrides.len() == MAX_CACHED_OVERRIDES {
                self.overrides.pop_back();
            }
            self.overrides.push_front(entry);
        }
    }
}

#[cfg(test)]
mod tests {
    use std::{
        sync::{
            Barrier, Weak,
            atomic::{AtomicBool, AtomicUsize, Ordering},
        },
        thread,
    };

    use rama_core::extensions::Extension;
    use rama_crypto::pki_types::CertificateDer;
    use rama_net::{address::Host, client::pool::ReuseKey, tls::TlsAlpn};
    use rama_quic_proto::{Version, transport_parameters::TransportParameters};
    use rama_tls::{
        KeyLogIntent, TlsKeyLog,
        client::{TlsClientConfigProvider, TlsServerName},
        keylog::NoopKeyLogSink,
    };

    use super::*;
    use crate::{
        ConnectError, TransportConfig,
        tls::provider::{ClientConfig as CryptoClientConfig, Session},
    };

    struct TestCrypto;

    impl CryptoClientConfig for TestCrypto {
        fn start_session(
            self: Arc<Self>,
            _: Version,
            _: &str,
            _: &TransportParameters,
        ) -> Result<Box<dyn Session>, ConnectError> {
            Err(ConnectError::EndpointStopping)
        }

        fn supports_version_switch(&self) -> bool {
            false
        }

        fn resumable_version(&self, _: &str) -> Option<Version> {
            None
        }
    }

    #[derive(Debug, Extension)]
    struct OpaquePolicy;

    #[derive(Default)]
    struct TestProvider {
        calls: AtomicUsize,
        defaults_calls: AtomicUsize,
        fail_next: AtomicBool,
        alpn_policies: Mutex<Vec<AlpnPolicy>>,
        rendezvous: Option<Barrier>,
        cache: Mutex<Weak<Mutex<Configs>>>,
    }

    impl fmt::Debug for TestProvider {
        fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
            f.debug_struct("TestProvider").finish_non_exhaustive()
        }
    }

    impl TlsClientConfigProvider for TestProvider {
        fn pool_id(&self, extensions: &Extensions) -> Option<TlsPoolId> {
            if extensions.contains::<OpaquePolicy>() {
                return Some(TlsPoolId::non_reusable());
            }
            TlsPoolId::builder()
                .maybe_with_server_name(extensions.get_ref::<TlsServerName>())
                .maybe_with_alpn(extensions.get_ref::<TlsAlpn>())
                .maybe_with_alpn_policy(extensions.get_ref::<AlpnPolicy>())
                .maybe_with_keylog(extensions.get_ref::<TlsKeyLog>())
                .build()
        }

        fn pool_classifier(&self) -> ReuseKey {
            ReuseKey::of::<Self>()
        }

        fn authenticates_server(&self, _: &Extensions) -> bool {
            true
        }
    }

    impl QuicClientConfigProvider for TestProvider {
        fn peer_matches_name(&self, _: &Extensions, _: &CertificateDer<'_>, _: &Host) -> bool {
            false
        }

        fn session_defaults(&self) -> Option<Extensions> {
            self.defaults_calls.fetch_add(1, Ordering::Relaxed);
            None
        }

        fn client_config(
            &self,
            _: &TlsClientConfig,
            options: TlsOptions,
        ) -> Result<ClientConfig, TlsConfigError> {
            self.alpn_policies.lock().push(options.alpn);
            self.calls.fetch_add(1, Ordering::Relaxed);
            if self.fail_next.swap(false, Ordering::Relaxed) {
                return Err(TlsConfigError::BackendUnavailable);
            }
            let cache = self.cache.lock().upgrade();
            if let Some(cache) = cache {
                assert!(
                    cache.try_lock().is_some(),
                    "provider must run outside the cache lock"
                );
            }
            if let Some(barrier) = &self.rendezvous {
                barrier.wait();
            }
            Ok(ClientConfig::new(Arc::new(TestCrypto)))
        }
    }

    fn named(index: usize) -> TlsClientConfig {
        TlsClientConfig::new()
            .with_server_name(Host::try_from(format!("host-{index}.example")).unwrap())
    }

    #[test]
    fn alpn_policy_overrides_reach_provider_and_partition_cached_configs() {
        let provider = Arc::new(TestProvider::default());
        let cache = ClientConfigCache::new(
            provider.clone(),
            TlsOptions::default().with_alpn(AlpnPolicy::OutOfBandAgreement),
        );
        for policy in [
            None,
            Some(AlpnPolicy::Require),
            Some(AlpnPolicy::OutOfBandAgreement),
            None,
            Some(AlpnPolicy::Require),
        ] {
            let mut config = TlsClientConfig::new();
            if let Some(policy) = policy {
                config.set_alpn_policy(policy);
            }
            cache
                .client_config(&config, config.as_extensions())
                .unwrap();
        }
        assert_eq!(provider.calls.load(Ordering::Relaxed), 3);
        assert_eq!(
            *provider.alpn_policies.lock(),
            [
                AlpnPolicy::OutOfBandAgreement,
                AlpnPolicy::Require,
                AlpnPolicy::OutOfBandAgreement
            ]
        );
    }

    #[test]
    fn fresh_cache_skips_provider_session_defaults() {
        let provider = Arc::new(TestProvider::default());
        let _ordinary = ClientConfigCache::new(provider.clone(), TlsOptions::default());
        assert_eq!(provider.defaults_calls.load(Ordering::Relaxed), 1);
        for _ in 0..8 {
            let _fresh = ClientConfigCache::new(
                provider.clone(),
                TlsOptions::default().with_client_sessions(ClientSessionPolicy::Fresh),
            );
        }
        assert_eq!(provider.defaults_calls.load(Ordering::Relaxed), 1);
    }

    #[test]
    fn overrides_are_lru_bounded_and_cannot_evict_default_session_state() {
        let provider = Arc::new(TestProvider::default());
        let cache = ClientConfigCache::new(provider, TlsOptions::default());
        let defaults = TlsClientConfig::new();
        let default = cache
            .client_config(&defaults, defaults.as_extensions())
            .unwrap();
        let config = named(0);
        let oldest = cache
            .client_config(&config, config.as_extensions())
            .unwrap();
        let mut next_oldest = None;
        for index in 1..MAX_CACHED_OVERRIDES {
            let config = named(index);
            let native = cache
                .client_config(&config, config.as_extensions())
                .unwrap();
            if index == 1 {
                next_oldest = Some(native);
            }
        }
        // Refresh the oldest entry; the next oldest must be evicted instead.
        let config = named(0);
        let retained = cache
            .client_config(&config, config.as_extensions())
            .unwrap();
        assert!(Arc::ptr_eq(&oldest.crypto, &retained.crypto));
        let config = named(MAX_CACHED_OVERRIDES);
        cache
            .client_config(&config, config.as_extensions())
            .unwrap();
        assert_eq!(cache.configs.lock().overrides.len(), MAX_CACHED_OVERRIDES);
        let retained = cache
            .client_config(&defaults, defaults.as_extensions())
            .unwrap();
        assert!(Arc::ptr_eq(&default.crypto, &retained.crypto));
        let config = named(1);
        let rebuilt = cache
            .client_config(&config, config.as_extensions())
            .unwrap();
        assert!(!Arc::ptr_eq(&next_oldest.unwrap().crypto, &rebuilt.crypto));
    }

    #[test]
    fn comparable_defaults_invalidate_and_opaque_requests_bypass_the_cache() {
        let cache =
            ClientConfigCache::new(Arc::new(TestProvider::default()), TlsOptions::default());
        let overrides = Extensions::new();
        let config = named(0);
        let original = cache.client_config(&config, &overrides).unwrap();
        config
            .as_extensions()
            .insert(TlsServerName(Host::from_static("changed.example")));
        let changed = cache.client_config(&config, &overrides).unwrap();
        assert!(!Arc::ptr_eq(&original.crypto, &changed.crypto));

        // Even an opaque request override masked by final settings cannot share state.
        overrides.insert(OpaquePolicy);
        let first = cache.client_config(&config, &overrides).unwrap();
        let second = cache.client_config(&config, &overrides).unwrap();
        assert!(!Arc::ptr_eq(&first.crypto, &second.crypto));
    }

    #[test]
    fn fixed_opaque_defaults_retain_sessions_without_merging_request_policies() {
        let provider = Arc::new(TestProvider::default());
        let cache = ClientConfigCache::new(provider.clone(), TlsOptions::default());
        let config = TlsClientConfig::new();
        config.as_extensions().insert(OpaquePolicy);
        let original = cache.client_config(&config, &Extensions::new()).unwrap();
        let repeated = cache.client_config(&config, &Extensions::new()).unwrap();
        assert!(Arc::ptr_eq(&original.crypto, &repeated.crypto));
        let overrides = named(0);
        let effective = config.clone().with_overrides(overrides.as_extensions());
        let changed = cache
            .client_config(&effective, overrides.as_extensions())
            .unwrap();
        let repeated = cache
            .client_config(&effective, overrides.as_extensions())
            .unwrap();
        assert!(Arc::ptr_eq(&changed.crypto, &repeated.crypto));
        assert!(!Arc::ptr_eq(&original.crypto, &changed.crypto));
        let defaults = cache.client_config(&config, &Extensions::new()).unwrap();
        assert!(Arc::ptr_eq(&original.crypto, &defaults.crypto));
        assert_eq!(provider.calls.load(Ordering::Relaxed), 2);
    }

    #[test]
    fn shared_components_retain_session_state_and_replacements_invalidate_it() {
        let cache =
            ClientConfigCache::new(Arc::new(TestProvider::default()), TlsOptions::default());
        let sink = Arc::new(NoopKeyLogSink);
        let config = TlsClientConfig::new().with_keylog(KeyLogIntent::Custom(sink.clone()));
        let first = cache
            .client_config(&config, config.as_extensions())
            .unwrap();
        let clone = TlsClientConfig::new().with_keylog(KeyLogIntent::Custom(sink));
        let repeated = cache.client_config(&clone, clone.as_extensions()).unwrap();
        assert!(Arc::ptr_eq(&first.crypto, &repeated.crypto));
        let changed =
            TlsClientConfig::new().with_keylog(KeyLogIntent::Custom(Arc::new(NoopKeyLogSink)));
        let replacement = cache
            .client_config(&changed, changed.as_extensions())
            .unwrap();
        assert!(!Arc::ptr_eq(&first.crypto, &replacement.crypto));

        // Effective connector defaults must also notice a replaced component.
        let defaults = Extensions::new();
        let first = cache.client_config(&config, &defaults).unwrap();
        let replacement = cache.client_config(&changed, &defaults).unwrap();
        assert!(!Arc::ptr_eq(&first.crypto, &replacement.crypto));
    }

    #[test]
    fn failed_builds_are_retried_and_transport_customization_stays_local() {
        let provider = Arc::new(TestProvider::default());
        provider.fail_next.store(true, Ordering::Relaxed);
        let cache = ClientConfigCache::new(provider.clone(), TlsOptions::default());
        let tls = TlsClientConfig::new();
        cache.client_config(&tls, tls.as_extensions()).unwrap_err();
        let mut first = cache.client_config(&tls, tls.as_extensions()).unwrap();
        let transport = Arc::new(TransportConfig::default());
        first.set_transport_config(transport.clone());
        let second = cache.client_config(&tls, tls.as_extensions()).unwrap();
        assert_eq!(provider.calls.load(Ordering::Relaxed), 2);
        assert!(Arc::ptr_eq(&first.crypto, &second.crypto));
        assert!(!Arc::ptr_eq(&second.transport, &transport));
    }

    #[test]
    fn providers_and_tls_options_have_independent_session_state() {
        let provider = Arc::new(TestProvider::default());
        let ordinary = ClientConfigCache::new(provider.clone(), TlsOptions::default());
        let early = ClientConfigCache::new(provider, TlsOptions::default().with_early_data(true));
        let other =
            ClientConfigCache::new(Arc::new(TestProvider::default()), TlsOptions::default());
        let tls = TlsClientConfig::new();
        let ordinary = ordinary.client_config(&tls, tls.as_extensions()).unwrap();
        for cache in [early, other] {
            let config = cache.client_config(&tls, tls.as_extensions()).unwrap();
            assert!(!Arc::ptr_eq(&ordinary.crypto, &config.crypto));
        }
    }

    #[test]
    fn provider_runs_without_holding_the_cache_lock() {
        let provider = Arc::new(TestProvider::default());
        let cache = ClientConfigCache::new(provider.clone(), TlsOptions::default());
        *provider.cache.lock() = Arc::downgrade(&cache.configs);
        let tls = TlsClientConfig::new();
        cache.client_config(&tls, tls.as_extensions()).unwrap();
        assert_eq!(provider.calls.load(Ordering::Relaxed), 1);
    }

    #[test]
    fn concurrent_builds_converge() {
        let provider = Arc::new(TestProvider {
            rendezvous: Some(Barrier::new(2)),
            ..Default::default()
        });
        let cache = ClientConfigCache::new(provider.clone(), TlsOptions::default());
        // A try_lock in either provider call could observe the other caller's
        // cache lookup. Check lock ownership separately, without competing threads.
        let clone = cache.clone();
        let tls = TlsClientConfig::new();
        let (first, second) = thread::scope(|scope| {
            let first = scope.spawn(|| cache.client_config(&tls, tls.as_extensions()).unwrap());
            let second = scope.spawn(|| clone.client_config(&tls, tls.as_extensions()).unwrap());
            (first.join().unwrap(), second.join().unwrap())
        });
        assert_eq!(provider.calls.load(Ordering::Relaxed), 2);
        assert!(Arc::ptr_eq(&first.crypto, &second.crypto));
    }

    #[test]
    fn automatic_handshake_policy_uses_the_ordinary_configuration_cache() {
        let provider = Arc::new(TestProvider::default());
        let cache = ClientConfigCache::new(provider.clone(), TlsOptions::default());
        let config = TlsClientConfig::new().with_client_handshake(ClientHandshake::Auto);
        let first = cache
            .client_config(&config, config.as_extensions())
            .unwrap();
        let second = cache
            .client_config_for_peer(
                &config,
                config.as_extensions(),
                &Host::from_static("localhost"),
            )
            .unwrap();
        assert!(Arc::ptr_eq(&first.crypto, &second.crypto));
        assert_eq!(provider.calls.load(Ordering::Relaxed), 1);
    }

    #[test]
    fn native_handshake_policy_cannot_fall_back_to_an_ordinary_client() {
        let provider = Arc::new(TestProvider::default());
        let cache = ClientConfigCache::new(provider.clone(), TlsOptions::default());
        let peer = Host::try_from("localhost").unwrap();
        for handshake in [ClientHandshake::Full, ClientHandshake::Resumed] {
            let config = named(0);
            config.as_extensions().insert(handshake);
            cache
                .client_config_for_peer(&config, config.as_extensions(), &peer)
                .unwrap_err();
            cache
                .client_config(&config, config.as_extensions())
                .unwrap_err();

            let unnamed = TlsClientConfig::new();
            unnamed.as_extensions().insert(handshake);
            cache
                .client_config(&unnamed, unnamed.as_extensions())
                .unwrap_err();
        }
        assert_eq!(provider.calls.load(Ordering::Relaxed), 0);
        assert!(cache.configs.lock().default.is_none());
        assert!(cache.configs.lock().overrides.is_empty());
    }
}
