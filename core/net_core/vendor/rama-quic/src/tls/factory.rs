use rama_crypto::pki_types::CertificateDer;
use rama_net::address::Host;

use rama_core::extensions::Extensions;
use std::{fmt, sync::Arc};

use crate::{
    ClientConfig, ServerConfig,
    tls::{ClientHandshake, TlsConfigError, TlsOptions},
};
#[cfg(any(
    feature = "boring",
    all(feature = "rustls", any(feature = "aws-lc", feature = "ring"))
))]
use rama_net::client::pool::ReuseKey;
#[cfg(any(
    feature = "boring",
    all(feature = "rustls", any(feature = "aws-lc", feature = "ring"))
))]
use rama_tls::client::TlsPoolId;
use rama_tls::{
    client::{TlsClientConfig, TlsClientConfigProvider},
    server::TlsServerConfig,
};
#[cfg(feature = "boring")]
use {
    crate::proto::crypto::boring as boring_crypto,
    rama_tls_boring::client::BoringTlsConnectorConfig,
};
#[cfg(all(feature = "rustls", any(feature = "aws-lc", feature = "ring")))]
use {
    crate::{profile::capture, proto::crypto::rustls as rustls_crypto},
    rama_quic_proto::{
        Side, Version,
        capture::{CaptureError, InitialKeys, KeyProvider},
        crypto::{HeaderKey, PacketKey},
    },
    rama_tls_rustls::{client::RustlsTlsConnectorConfig, dep::rustls::crypto::CryptoProvider},
};

/// Build QUIC TLS configurations from Rama settings using a fixed provider.
///
/// This is the request-configuration boundary; the lower-level session provider
/// interface remains available through `ClientConfig::new`. Custom providers use
/// this same interface for construction, pool identity and server authentication.
///
/// Built-in providers apply common Rama TLS settings and their own native
/// extensions, ignoring other providers' native settings. Construction,
/// authentication claims and pool identity describe the settings actually applied.
/// Different connectors can therefore use different TLS policies.
pub trait QuicClientConfigProvider: TlsClientConfigProvider {
    /// Optional connector-local backend session state shared by sibling configurations.
    /// These extensions hold cache metadata; they must not replace TLS security settings.
    /// The default retains each native configuration's own session state.
    fn session_defaults(&self) -> Option<Extensions> {
        None
    }

    /// Prepare peer-bound native TLS state without connection I/O.
    /// Prepared configurations bypass ordinary caches because their first native
    /// session belongs to this peer; retries obtain fresh ephemeral state.
    ///
    /// `handshake` controls ticket offers; `options` still controls ticket
    /// retention and early data. Authentication and credentials remain `policy`.
    /// Return `None` if this provider cannot prepare native sessions.
    fn prepare_client_config(
        &self,
        _policy: &TlsClientConfig,
        _options: TlsOptions,
        _peer: Host,
        _handshake: ClientHandshake,
    ) -> Result<Option<ClientConfig>, TlsConfigError> {
        Ok(None)
    }

    /// Apply the final TLS settings and client handshake policy in `options`.
    /// Fresh clients must neither consult nor populate session-ticket stores,
    /// including stores supplied through native configuration hooks.
    fn client_config(
        &self,
        config: &TlsClientConfig,
        options: TlsOptions,
    ) -> Result<ClientConfig, TlsConfigError>;

    /// Whether the peer `leaf` of a connection authenticated under the effective
    /// configuration in `extensions` is also valid for `name`, including any pins
    /// scoped to it. Providers that cannot tell return `false`; a pin scoped to `name`
    /// on an intermediate or root never matches the leaf, so it fails closed.
    fn peer_matches_name(
        &self,
        extensions: &Extensions,
        leaf: &CertificateDer<'_>,
        name: &Host,
    ) -> bool;
}

/// Build server configurations without requiring client-policy support.
pub trait QuicServerConfigProvider: fmt::Debug + Send + Sync {
    fn server_config(
        &self,
        config: &TlsServerConfig,
        options: TlsOptions,
    ) -> Result<ServerConfig, TlsConfigError>;
}

/// Select the feature-default configuration provider once when constructing a connector.
/// Rustls with an enabled cryptographic implementation is preferred, then BoringSSL.
pub fn default_tls_provider() -> Result<Arc<dyn QuicClientConfigProvider>, TlsConfigError> {
    #[cfg(all(feature = "rustls", any(feature = "aws-lc", feature = "ring")))]
    {
        Ok(Arc::new(RustlsTlsProvider::new(
            rustls_crypto::configured_provider(),
        )))
    }
    #[cfg(all(
        feature = "boring",
        not(all(feature = "rustls", any(feature = "aws-lc", feature = "ring")))
    ))]
    {
        Ok(Arc::new(BoringTlsProvider))
    }
    #[cfg(not(any(
        feature = "boring",
        all(feature = "rustls", any(feature = "aws-lc", feature = "ring"))
    )))]
    {
        Err(TlsConfigError::BackendUnavailable)
    }
}

/// Rustls QUIC configuration factory with an explicitly supplied cryptographic provider.
///
/// The adapter still requires the `ring` or `aws-lc` feature for its packet crypto.
/// Supplying a provider here does not install or use Rustls's process-wide default.
#[cfg(all(feature = "rustls", any(feature = "aws-lc", feature = "ring")))]
#[derive(Debug, Clone)]
pub struct RustlsTlsProvider {
    crypto: Arc<CryptoProvider>,
}

#[cfg(all(feature = "rustls", any(feature = "aws-lc", feature = "ring")))]
impl RustlsTlsProvider {
    /// Select Rustls's native cryptographic provider for this adapter.
    ///
    /// This backend-specific constructor intentionally accepts the Rustls type
    /// re-exported by `rama_tls_rustls::dep::rustls`. Backend-neutral callers use
    /// [`default_tls_provider`] or [`QuicClientConfigProvider`] instead.
    pub fn new(crypto: Arc<CryptoProvider>) -> Self {
        Self { crypto }
    }
}

#[cfg(all(feature = "rustls", any(feature = "aws-lc", feature = "ring")))]
impl TlsClientConfigProvider for RustlsTlsProvider {
    fn pool_id(&self, extensions: &Extensions) -> Option<TlsPoolId> {
        RustlsTlsConnectorConfig::from_extensions(extensions).pool_id()
    }

    fn pool_classifier(&self) -> ReuseKey {
        ReuseKey::of::<RustlsTlsConnectorConfig>()
    }

    fn authenticates_server(&self, extensions: &Extensions) -> bool {
        RustlsTlsConnectorConfig::from_extensions(extensions).authenticates_server()
    }
}

#[cfg(all(feature = "rustls", any(feature = "aws-lc", feature = "ring")))]
impl QuicClientConfigProvider for RustlsTlsProvider {
    fn client_config(
        &self,
        config: &TlsClientConfig,
        options: TlsOptions,
    ) -> Result<ClientConfig, TlsConfigError> {
        Ok(ClientConfig::new(Arc::new(
            rustls_crypto::QuicClientConfig::from_rama(config, self.crypto.clone(), options)?,
        )))
    }

    fn peer_matches_name(
        &self,
        extensions: &Extensions,
        leaf: &CertificateDer<'_>,
        name: &Host,
    ) -> bool {
        RustlsTlsConnectorConfig::from_extensions(extensions).peer_matches_name(leaf, name)
    }
}

#[cfg(all(feature = "rustls", any(feature = "aws-lc", feature = "ring")))]
impl QuicServerConfigProvider for RustlsTlsProvider {
    fn server_config(
        &self,
        config: &TlsServerConfig,
        options: TlsOptions,
    ) -> Result<ServerConfig, TlsConfigError> {
        Ok(ServerConfig::with_random_token_key(
            rustls_crypto::server_config_from_rama(config, self.crypto.clone(), options)?,
        ))
    }
}

#[cfg(all(feature = "rustls", any(feature = "aws-lc", feature = "ring")))]
impl KeyProvider for RustlsTlsProvider {
    type Header = Box<dyn HeaderKey>;
    type Packet = Box<dyn PacketKey>;

    fn initial_keys(
        &self,
        version: Version,
        dcid: &[u8],
        side: Side,
    ) -> Result<InitialKeys<Self::Header, Self::Packet>, CaptureError> {
        let dcid = capture::connection_id(dcid)?;
        version
            .wire()
            .ok_or(CaptureError::UnknownVersion(version))?;
        let suite = rustls_crypto::initial_suite_from_provider(&self.crypto)
            .ok_or(CaptureError::Undecryptable)?;
        let keys = rustls_crypto::server_initial_keys(version, &dcid, &suite)
            .map_err(|_error| CaptureError::Undecryptable)?;
        capture::receiving_keys(keys, side)
    }
}

/// BoringSSL QUIC configuration factory.
#[cfg(feature = "boring")]
#[derive(Debug, Clone, Copy, Default)]
pub struct BoringTlsProvider;

#[cfg(feature = "boring")]
impl BoringTlsProvider {
    /// Prepare the first native TLS session for `peer` without sending packets.
    ///
    /// The first dial consumes the prepared SSL object; address retries create
    /// fresh sibling sessions. All use full handshakes, without reading or
    /// retaining tickets. This configuration belongs to `peer` and must not be
    /// shared through a cache that omits that identity.
    pub fn prepare_fresh_client_config(
        &self,
        config: &TlsClientConfig,
        peer: Host,
    ) -> Result<ClientConfig, TlsConfigError> {
        Ok(ClientConfig::new(Arc::new(
            boring_crypto::QuicClientConfig::prepare_fresh(config, peer)?,
        )))
    }
}

#[cfg(feature = "boring")]
impl TlsClientConfigProvider for BoringTlsProvider {
    fn pool_id(&self, extensions: &Extensions) -> Option<TlsPoolId> {
        BoringTlsConnectorConfig::from_extensions(extensions).pool_id()
    }

    fn pool_classifier(&self) -> ReuseKey {
        ReuseKey::of::<BoringTlsConnectorConfig>()
    }

    fn authenticates_server(&self, extensions: &Extensions) -> bool {
        BoringTlsConnectorConfig::from_extensions(extensions).authenticates_server()
    }
}

#[cfg(feature = "boring")]
impl QuicClientConfigProvider for BoringTlsProvider {
    fn prepare_client_config(
        &self,
        policy: &TlsClientConfig,
        options: TlsOptions,
        peer: Host,
        handshake: ClientHandshake,
    ) -> Result<Option<ClientConfig>, TlsConfigError> {
        boring_crypto::QuicClientConfig::prepare_client(policy, options, peer, handshake)
            .map(|config| Some(ClientConfig::new(Arc::new(config))))
    }

    fn session_defaults(&self) -> Option<Extensions> {
        Some(boring_crypto::SharedClientSessions::defaults())
    }

    fn client_config(
        &self,
        config: &TlsClientConfig,
        options: TlsOptions,
    ) -> Result<ClientConfig, TlsConfigError> {
        Ok(ClientConfig::new(Arc::new(
            boring_crypto::QuicClientConfig::from_rama(config, options)?,
        )))
    }

    fn peer_matches_name(
        &self,
        extensions: &Extensions,
        leaf: &CertificateDer<'_>,
        name: &Host,
    ) -> bool {
        BoringTlsConnectorConfig::from_extensions(extensions).peer_matches_name(leaf, name)
    }
}

#[cfg(feature = "boring")]
impl QuicServerConfigProvider for BoringTlsProvider {
    fn server_config(
        &self,
        config: &TlsServerConfig,
        options: TlsOptions,
    ) -> Result<ServerConfig, TlsConfigError> {
        Ok(ServerConfig::with_random_token_key(
            boring_crypto::server_config_from_rama(config, options)?,
        ))
    }
}

impl ClientConfig {
    /// Build through the explicitly injected provider, independently of enabled defaults.
    pub fn try_from_rama_tls_with_provider(
        config: &TlsClientConfig,
        options: TlsOptions,
        provider: &dyn QuicClientConfigProvider,
    ) -> Result<Self, TlsConfigError> {
        provider.client_config(config, options)
    }
}
impl ServerConfig {
    /// Build through the explicitly injected provider, independently of enabled defaults.
    pub fn try_from_rama_tls_with_provider(
        config: &TlsServerConfig,
        options: TlsOptions,
        provider: &dyn QuicServerConfigProvider,
    ) -> Result<Self, TlsConfigError> {
        provider.server_config(config, options)
    }
}

/// Select the feature-default server configuration provider.
pub fn default_server_tls_provider() -> Result<Arc<dyn QuicServerConfigProvider>, TlsConfigError> {
    #[cfg(all(feature = "rustls", any(feature = "aws-lc", feature = "ring")))]
    {
        Ok(Arc::new(RustlsTlsProvider::new(
            rustls_crypto::configured_provider(),
        )))
    }
    #[cfg(all(
        feature = "boring",
        not(all(feature = "rustls", any(feature = "aws-lc", feature = "ring")))
    ))]
    {
        Ok(Arc::new(BoringTlsProvider))
    }
    #[cfg(not(any(
        feature = "boring",
        all(feature = "rustls", any(feature = "aws-lc", feature = "ring"))
    )))]
    {
        Err(TlsConfigError::BackendUnavailable)
    }
}

#[cfg(all(
    test,
    feature = "boring",
    feature = "rustls",
    any(feature = "aws-lc", feature = "ring")
))]
mod tests {
    use std::{
        assert_matches,
        sync::atomic::{AtomicUsize, Ordering},
    };

    use rama_core::error::{BoxError, BoxErrorExt as _};
    use rama_net::tls::ApplicationProtocol;
    use rama_tls_boring::client::BoringGrease;
    use rama_tls_rustls::client::ModifyRustlsClientConfig;

    use super::*;
    use crate::tls::ClientConfigCache;

    #[test]
    fn native_settings_affect_only_the_selected_provider() {
        let rustls = RustlsTlsProvider::new(rustls_crypto::configured_provider());
        let boring = BoringTlsProvider;
        let config =
            TlsClientConfig::new().with_alpn([ApplicationProtocol::HTTP_3].into_iter().collect());
        let extensions = config.as_extensions();
        let baseline = rustls.pool_id(extensions);
        assert_eq!(baseline, boring.pool_id(extensions));

        extensions.insert(BoringGrease(true));
        assert_eq!(baseline, rustls.pool_id(extensions));
        let boring_policy = boring.pool_id(extensions);
        assert_ne!(baseline, boring_policy);
        assert!(rustls.authenticates_server(extensions));
        assert!(boring.authenticates_server(extensions));
        rustls
            .client_config(&config, TlsOptions::default())
            .unwrap();
        boring
            .client_config(&config, TlsOptions::default())
            .unwrap();

        // Both native configurations may coexist. Only Rustls executes this hook.
        extensions.insert(ModifyRustlsClientConfig::new(|_| {
            Err(BoxError::from_static_str("custom rustls hook"))
        }));
        assert_ne!(baseline, rustls.pool_id(extensions));
        assert_eq!(boring_policy, boring.pool_id(extensions));
        assert!(!rustls.authenticates_server(extensions));
        assert!(boring.authenticates_server(extensions));
        assert_matches!(
            rustls.client_config(&config, TlsOptions::default()),
            Err(TlsConfigError::InvalidConfiguration(_)),
        );
        boring
            .client_config(&config, TlsOptions::default())
            .unwrap();
    }

    #[test]
    fn config_caches_reuse_foreign_changes_and_apply_own_changes() {
        let rustls = ClientConfigCache::new(
            Arc::new(RustlsTlsProvider::new(rustls_crypto::configured_provider())),
            TlsOptions::default(),
        );
        let boring = ClientConfigCache::new(Arc::new(BoringTlsProvider), TlsOptions::default());
        let config =
            TlsClientConfig::new().with_alpn([ApplicationProtocol::HTTP_3].into_iter().collect());
        let request = Extensions::new();
        let baseline_rustls = rustls.client_config(&config, &request).unwrap();
        let baseline_boring = boring.client_config(&config, &request).unwrap();

        request.insert(BoringGrease(true));
        let effective = config.clone().with_overrides(&request);
        let retained_rustls = rustls.client_config(&effective, &request).unwrap();
        let changed_boring = boring.client_config(&effective, &request).unwrap();
        assert!(Arc::ptr_eq(
            &baseline_rustls.crypto,
            &retained_rustls.crypto
        ));
        assert!(!Arc::ptr_eq(
            &baseline_boring.crypto,
            &changed_boring.crypto
        ));

        let calls = Arc::new(AtomicUsize::new(0));
        request.insert(ModifyRustlsClientConfig::new({
            let calls = calls.clone();
            move |config| {
                calls.fetch_add(1, Ordering::SeqCst);
                Ok(config)
            }
        }));
        let effective = config.clone().with_overrides(&request);
        let changed_rustls = rustls.client_config(&effective, &request).unwrap();
        assert!(!Arc::ptr_eq(
            &baseline_rustls.crypto,
            &changed_rustls.crypto
        ));
        let retained_boring = boring.client_config(&effective, &request).unwrap();
        assert!(Arc::ptr_eq(&changed_boring.crypto, &retained_boring.crypto));

        request.insert(BoringGrease(false));
        let effective = config.clone().with_overrides(&request);
        let retained_rustls = rustls.client_config(&effective, &request).unwrap();
        assert!(Arc::ptr_eq(&changed_rustls.crypto, &retained_rustls.crypto));
        assert_eq!(calls.load(Ordering::SeqCst), 1);
        let replaced_boring = boring.client_config(&effective, &request).unwrap();
        assert!(!Arc::ptr_eq(
            &changed_boring.crypto,
            &replaced_boring.crypto
        ));

        request.insert(ModifyRustlsClientConfig::new(|_| {
            Err(BoxError::from_static_str("replacement rejects this policy"))
        }));
        let effective = config.with_overrides(&request);
        assert_matches!(
            rustls.client_config(&effective, &request),
            Err(TlsConfigError::InvalidConfiguration(_)),
        );
        let retained_boring = boring.client_config(&effective, &request).unwrap();
        assert!(Arc::ptr_eq(
            &replaced_boring.crypto,
            &retained_boring.crypto
        ));
    }
}

/// Real ECH for peer-bound BoringSSL clients (FluxDO patch).
/// Rebuild native config when this changes; generic ClientConfigCache omits ECH.
#[cfg(feature = "boring")]
#[derive(Clone, Debug, rama_core::extensions::Extension)]
#[extension(tags(tls))]
pub struct BoringEchConfigList(pub Vec<u8>);

/// Per-handshake observation: 0 pending, 1 not accepted, 2 accepted.
/// Supply a new observer for every peer-bound client configuration.
#[cfg(feature = "boring")]
#[derive(Clone, Debug, rama_core::extensions::Extension)]
#[extension(tags(tls))]
pub struct BoringEchObservation(pub Arc<std::sync::atomic::AtomicU8>);
