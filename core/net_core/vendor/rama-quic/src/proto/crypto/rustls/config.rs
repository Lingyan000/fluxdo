use std::sync::Arc;

use rama_net::tls::AlpnPolicy;

use rama_tls::{
    ProtocolVersion, TlsSupportedVersions,
    client::{ClientHandshake, TlsClientConfig},
    server::TlsServerConfig,
};
use rama_tls_rustls::{client::RustlsTlsConnectorConfig, server::RustlsTlsAcceptorConfig};

use super::rustls::client::Resumption;
use super::{QuicClientConfig, QuicDynamicServerConfig, QuicServerConfig, rustls};
use crate::proto::ServerCrypto;
pub(crate) use crate::proto::crypto::config::{ClientSessionPolicy, TlsConfigError, TlsOptions};

/// Carry a backend error as the cause, without that conversion being part of this crate's API.
fn invalid_configuration(error: rustls::Error) -> TlsConfigError {
    TlsConfigError::InvalidConfiguration(Box::new(error))
}

impl QuicClientConfig {
    pub(crate) fn from_rama(
        config: &TlsClientConfig,
        provider: Arc<rustls::crypto::CryptoProvider>,
        options: TlsOptions,
    ) -> Result<Self, TlsConfigError> {
        // Initial packets always use AES-128-GCM, independently of the TLS cipher
        // suites an application's native hook chooses to offer.
        let fallback_initial = super::initial_suite_from_provider(&provider);
        let mut pieces = RustlsTlsConnectorConfig::from_extensions(config.as_extensions());
        let store_peer_chain = pieces.store_chain.is_some_and(|store| store.0);
        validate_versions(pieces.versions)?;
        let versions = TlsSupportedVersions(vec![ProtocolVersion::TLSv1_3]);
        pieces.versions = Some(&versions);
        let modify = pieces.modify.take();
        let handshake = pieces.client_handshake.copied().unwrap_or_default();
        let mut native = pieces.try_into_client_config_with_provider(provider)?;
        native.enable_early_data = options.early_data;
        if let Some(modify) = modify {
            native = (modify.0)(native)?;
        }
        if options.client_sessions == ClientSessionPolicy::Fresh
            || handshake == ClientHandshake::Full
        {
            // Apply after the application's hook, including any custom store.
            native.resumption = Resumption::disabled();
        }
        validate_alpn(&native.alpn_protocols, options.alpn)?;
        if native.enable_early_data && !options.early_data {
            return Err(TlsConfigError::EarlyDataNotEnabled);
        }
        // Validate the final hook result through Rustls's actual QUIC constructor.
        // Never consume tickets from the application's resumption cache in a probe.
        let mut probe = native.clone();
        probe.resumption = Resumption::disabled();
        probe.key_log = Arc::new(rustls::NoKeyLog);
        rustls::quic::ClientConnection::new(
            Arc::new(probe),
            rustls::quic::Version::V1,
            rustls::pki_types::ServerName::IpAddress(std::net::Ipv4Addr::LOCALHOST.into()),
            Vec::new(),
        )
        .map_err(invalid_configuration)?;
        let initial = super::initial_suite_from_provider(native.crypto_provider())
            .or(fallback_initial)
            .ok_or(super::NoInitialCipherSuite { specific: false })?;
        let mut config = Self::with_initial(Arc::new(native), initial)?;
        config.alpn_policy = options.alpn;
        config.client_sessions = options.client_sessions;
        config.store_peer_chain = store_peer_chain;
        Ok(config)
    }
}

/// The server TLS configuration for QUIC: fixed, or resolved per ClientHello when the
/// common configuration carries a rustls dynamic configuration.
pub(crate) fn server_config_from_rama(
    config: &TlsServerConfig,
    provider: Arc<rustls::crypto::CryptoProvider>,
    options: TlsOptions,
) -> Result<ServerCrypto, TlsConfigError> {
    let pieces = RustlsTlsAcceptorConfig::from_extensions(config.as_extensions());
    let store_peer_chain = pieces.store_client_chain.is_some_and(|store| store.0);
    Ok(match pieces.dynamic {
        Some(dynamic) => ServerCrypto::Resolver(Arc::new(QuicDynamicServerConfig::new(
            dynamic.clone(),
            &provider,
            options,
            store_peer_chain,
        )?)),
        None => ServerCrypto::Fixed(Arc::new(QuicServerConfig::from_rama(
            config, provider, options,
        )?)),
    })
}

impl QuicServerConfig {
    pub(crate) fn from_rama(
        config: &TlsServerConfig,
        provider: Arc<rustls::crypto::CryptoProvider>,
        options: TlsOptions,
    ) -> Result<Self, TlsConfigError> {
        let mut pieces = RustlsTlsAcceptorConfig::from_extensions(config.as_extensions());
        let store_peer_chain = pieces.store_client_chain.is_some_and(|store| store.0);
        if pieces.dynamic.is_some() {
            return Err(TlsConfigError::UnsupportedDynamicConfig);
        }
        validate_versions(pieces.versions)?;
        let versions = TlsSupportedVersions(vec![ProtocolVersion::TLSv1_3]);
        pieces.versions = Some(&versions);
        let modify = pieces.modify.take();
        let mut native = pieces.try_into_server_config_with_provider(provider)?;
        native.max_early_data_size = if options.early_data { u32::MAX } else { 0 };
        if let Some(modify) = modify {
            native = (modify.0)(native)?;
        }
        Self::from_native(native, options, store_peer_chain)
    }

    /// Check a native configuration against QUIC's requirements, then take it.
    pub(super) fn from_native(
        native: rustls::ServerConfig,
        options: TlsOptions,
        store_peer_chain: bool,
    ) -> Result<Self, TlsConfigError> {
        validate_alpn(&native.alpn_protocols, options.alpn)?;
        if native.max_early_data_size != 0 && !options.early_data {
            return Err(TlsConfigError::EarlyDataNotEnabled);
        }
        let native = Arc::new(native);
        rustls::quic::ServerConnection::new(native.clone(), rustls::quic::Version::V1, Vec::new())
            .map_err(invalid_configuration)?;
        let mut config = Self::try_from(native)?;
        config.alpn_policy = options.alpn;
        config.store_peer_chain = store_peer_chain;
        Ok(config)
    }
}

fn validate_versions(versions: Option<&TlsSupportedVersions>) -> Result<(), TlsConfigError> {
    if versions.is_some_and(|v| !v.0.is_empty() && !v.0.contains(&ProtocolVersion::TLSv1_3)) {
        return Err(TlsConfigError::Tls13Required);
    }
    Ok(())
}

fn validate_alpn(protocols: &[Vec<u8>], policy: AlpnPolicy) -> Result<(), TlsConfigError> {
    rama_tls::alpn::validate_alpn(protocols.iter().map(Vec::as_slice), policy).map_err(|error| {
        match error {
            rama_tls::alpn::AlpnError::Required => TlsConfigError::AlpnRequired,
            rama_tls::alpn::AlpnError::Invalid => TlsConfigError::InvalidAlpn,
        }
    })
}

#[cfg(test)]
mod tests {
    use std::{
        assert_matches,
        error::Error as _,
        net::SocketAddr,
        sync::atomic::{AtomicUsize, Ordering},
        time::Duration,
    };

    use super::rustls::{
        NamedGroup,
        client::{ClientSessionStore, Tls12ClientSessionValue, Tls13ClientSessionValue},
        pki_types::ServerName,
    };
    use rama_core::{error::BoxError, rt::Executor};
    use rama_net::tls::{ApplicationProtocol, TlsAlpn};
    use rama_quic_proto::{Side, VarInt, Version, transport_parameters::TransportParameters};
    use rama_tls::{
        client::{ClientAuth, ClientAuthData, TlsServerCertPins},
        keylog::KeyLogSink,
        server::{ClientVerifyMode, GeneratedServerAuthConfig, ServerAuthData},
    };
    use rama_tls_rustls::{
        client::{RustlsClientConfigExt, client_root_certs, self_signed_client_auth},
        server::{DynamicConfigProvider, RustlsServerConfigExt},
    };

    use super::*;
    use crate::{
        driver::Endpoint,
        proto::{
            ClientConfig, ConnectError, ServerConfig,
            crypto::{ClientConfig as _, ServerConfig as _, rustls::configured_provider},
        },
    };

    fn configs() -> (TlsClientConfig, TlsServerConfig) {
        let auth = ServerAuthData::new_generated(GeneratedServerAuthConfig::default()).unwrap();
        let alpn = || {
            [ApplicationProtocol::from(b"rama-quic-test".as_slice())]
                .into_iter()
                .collect()
        };
        let client = TlsClientConfig::new()
            .with_server_cert_pins(TlsServerCertPins::new(auth.cert_chain[0].clone()))
            .with_alpn(alpn())
            .try_with_server_trust_anchors([auth.cert_chain.last().unwrap().clone()])
            .unwrap();
        (
            client,
            TlsServerConfig::new()
                .with_server_auth(auth)
                .with_alpn(alpn()),
        )
    }

    #[test]
    fn explicit_alpn_options_override_common_config() {
        for configured in [AlpnPolicy::Require, AlpnPolicy::OutOfBandAgreement] {
            for explicit in [AlpnPolicy::Require, AlpnPolicy::OutOfBandAgreement] {
                let config = TlsClientConfig::new().with_alpn_policy(configured);
                let result = QuicClientConfig::from_rama(
                    &config,
                    configured_provider(),
                    TlsOptions::default().with_alpn(explicit),
                );
                if explicit == AlpnPolicy::Require {
                    assert!(matches!(result, Err(TlsConfigError::AlpnRequired)));
                } else {
                    result.unwrap();
                }
            }
        }
    }

    #[test]
    fn common_config_requires_alpn_and_tls13() {
        let (client, server) = configs();
        QuicClientConfig::from_rama(&client, configured_provider(), TlsOptions::default()).unwrap();
        QuicServerConfig::from_rama(&server, configured_provider(), TlsOptions::default()).unwrap();
        client.insert(TlsSupportedVersions(vec![ProtocolVersion::TLSv1_2]));
        server.insert(TlsSupportedVersions(vec![ProtocolVersion::TLSv1_2]));
        assert!(matches!(
            QuicClientConfig::from_rama(&client, configured_provider(), TlsOptions::default()),
            Err(TlsConfigError::Tls13Required)
        ));
        assert!(matches!(
            QuicServerConfig::from_rama(&server, configured_provider(), TlsOptions::default()),
            Err(TlsConfigError::Tls13Required)
        ));
        client.insert(TlsSupportedVersions(vec![]));
        server.insert(TlsSupportedVersions(vec![]));
        client.insert(TlsAlpn(Default::default()));
        server.insert(TlsAlpn(Default::default()));
        assert!(matches!(
            QuicClientConfig::from_rama(&client, configured_provider(), TlsOptions::default()),
            Err(TlsConfigError::AlpnRequired)
        ));
        assert!(matches!(
            QuicServerConfig::from_rama(&server, configured_provider(), TlsOptions::default()),
            Err(TlsConfigError::AlpnRequired)
        ));
        let options = TlsOptions {
            alpn: AlpnPolicy::OutOfBandAgreement,
            ..Default::default()
        };
        QuicClientConfig::from_rama(&client, configured_provider(), options).unwrap();
        QuicServerConfig::from_rama(&server, configured_provider(), options).unwrap();
    }

    #[test]
    fn modify_hooks_cannot_bypass_quic_requirements() {
        let (client, server) = configs();
        let client = client.with_modify_rustls_config(|mut native| {
            native.alpn_protocols = vec![vec![]];
            Ok(native)
        });
        assert!(matches!(
            QuicClientConfig::from_rama(&client, configured_provider(), TlsOptions::default()),
            Err(TlsConfigError::InvalidAlpn)
        ));
        let client = client.with_modify_rustls_config(|mut native| {
            native.enable_early_data = true;
            Ok(native)
        });
        assert!(matches!(
            QuicClientConfig::from_rama(&client, configured_provider(), TlsOptions::default()),
            Err(TlsConfigError::EarlyDataNotEnabled)
        ));
        let client = client.with_modify_rustls_config(|native| {
            Ok(
                rustls::ClientConfig::builder_with_provider(native.crypto_provider().clone())
                    .with_protocol_versions(&[&rustls::version::TLS12])?
                    .with_root_certificates(client_root_certs())
                    .with_no_client_auth(),
            )
        });
        let options = TlsOptions {
            alpn: AlpnPolicy::OutOfBandAgreement,
            ..Default::default()
        };
        let error = QuicClientConfig::from_rama(&client, configured_provider(), options)
            .err()
            .unwrap();
        assert_matches!(error, TlsConfigError::InvalidConfiguration(_));
        assert!(
            error
                .source()
                .unwrap()
                .downcast_ref::<rustls::Error>()
                .is_some()
        );

        let server = server.with_modify_rustls_config(|mut native| {
            native.max_early_data_size = 17;
            Ok(native)
        });
        let options = TlsOptions {
            early_data: true,
            ..Default::default()
        };
        assert!(matches!(
            QuicServerConfig::from_rama(&server, configured_provider(), options),
            Err(TlsConfigError::InvalidConfiguration(_))
        ));
        let server = server.with_modify_rustls_config(|native| {
            Ok(
                rustls::ServerConfig::builder_with_provider(native.crypto_provider().clone())
                    .with_protocol_versions(&[&rustls::version::TLS12])?
                    .with_no_client_auth()
                    .with_cert_resolver(native.cert_resolver),
            )
        });
        let options = TlsOptions {
            alpn: AlpnPolicy::OutOfBandAgreement,
            ..Default::default()
        };
        assert!(matches!(
            QuicServerConfig::from_rama(&server, configured_provider(), options),
            Err(TlsConfigError::InvalidConfiguration(_))
        ));
    }

    #[test]
    fn initial_cipher_and_alpn_wire_lengths_are_validated() {
        let (client, server) = configs();
        let mut provider = (*configured_provider()).clone();
        provider
            .cipher_suites
            .retain(|suite| suite.suite() != rustls::CipherSuite::TLS13_AES_128_GCM_SHA256);
        let provider = Arc::new(provider);
        assert!(matches!(
            QuicClientConfig::from_rama(&client, provider.clone(), TlsOptions::default()),
            Err(TlsConfigError::NoInitialCipherSuite(_))
        ));
        assert!(matches!(
            QuicServerConfig::from_rama(&server, provider, TlsOptions::default()),
            Err(TlsConfigError::NoInitialCipherSuite(_))
        ));
        for protocols in [vec![vec![]], vec![vec![0; 256]], vec![vec![0; 255]; 256]] {
            assert_matches!(
                validate_alpn(&protocols, AlpnPolicy::OutOfBandAgreement),
                Err(TlsConfigError::InvalidAlpn),
            );
        }
        validate_alpn(&vec![vec![0; 255]; 255], AlpnPolicy::Require).unwrap();
    }

    struct Dynamic;
    impl DynamicConfigProvider for Dynamic {
        async fn get_config(
            &self,
            _: rustls::server::ClientHello<'_>,
        ) -> Result<Arc<rustls::ServerConfig>, BoxError> {
            panic!("resolution happens only for an accepted ClientHello");
        }
    }

    #[test]
    fn dynamic_config_resolves_per_client_hello() {
        let config = TlsServerConfig::new().with_dynamic_config(Arc::new(Dynamic));
        assert!(matches!(
            QuicServerConfig::from_rama(&config, configured_provider(), TlsOptions::default()),
            Err(TlsConfigError::UnsupportedDynamicConfig)
        ));
        let resolving =
            server_config_from_rama(&config, configured_provider(), TlsOptions::default()).unwrap();
        assert!(matches!(resolving, ServerCrypto::Resolver(_)));
    }

    #[test]
    fn both_roles_reject_a_completed_handshake_without_required_alpn() {
        for strict_side in [Side::Client, Side::Server] {
            let (client, server) = configs();
            client.insert(TlsAlpn(Default::default()));
            server.insert(TlsAlpn(Default::default()));
            let options = TlsOptions {
                alpn: AlpnPolicy::OutOfBandAgreement,
                ..Default::default()
            };
            let mut client =
                QuicClientConfig::from_rama(&client, configured_provider(), options).unwrap();
            let mut server =
                QuicServerConfig::from_rama(&server, configured_provider(), options).unwrap();
            // Exercise the session guard against a peer completing TLS without ALPN.
            match strict_side {
                Side::Client => client.alpn_policy = AlpnPolicy::Require,
                Side::Server => server.alpn_policy = AlpnPolicy::Require,
            }
            let params = TransportParameters::default();
            let mut client = Arc::new(client)
                .start_session(Version::V1, "localhost", &params)
                .unwrap();
            let mut server = Arc::new(server)
                .start_session(Version::V1, &params)
                .unwrap();
            let mut rejected = None;
            'handshake: for _ in 0..16 {
                for side in [Side::Server, Side::Client] {
                    let (sender, receiver) = match side {
                        Side::Server => (&mut client, &mut server),
                        Side::Client => (&mut server, &mut client),
                    };
                    while let Some(event) = sender.poll_handshake().unwrap() {
                        if let crate::proto::crypto::HandshakeEvent::Data(level, bytes) = event
                            && let Err(error) = receiver.read_handshake(level, &bytes)
                        {
                            rejected = Some((side, error));
                            break 'handshake;
                        }
                    }
                }
            }
            let (side, error) = rejected.expect("missing ALPN was accepted");
            assert_eq!(side, strict_side);
            assert_eq!(u64::from(error.code), 0x0178);
        }
    }

    #[derive(Debug, Default)]
    struct SessionStore {
        reads: AtomicUsize,
    }

    impl ClientSessionStore for SessionStore {
        fn set_kx_hint(&self, _: ServerName<'static>, _: NamedGroup) {}
        fn kx_hint(&self, _: &ServerName<'_>) -> Option<NamedGroup> {
            self.reads.fetch_add(1, Ordering::Relaxed);
            None
        }
        fn set_tls12_session(&self, _: ServerName<'static>, _: Tls12ClientSessionValue) {}
        fn tls12_session(&self, _: &ServerName<'_>) -> Option<Tls12ClientSessionValue> {
            self.reads.fetch_add(1, Ordering::Relaxed);
            None
        }
        fn remove_tls12_session(&self, _: &ServerName<'static>) {}
        fn insert_tls13_ticket(&self, _: ServerName<'static>, _: Tls13ClientSessionValue) {}
        fn take_tls13_ticket(&self, _: &ServerName<'static>) -> Option<Tls13ClientSessionValue> {
            self.reads.fetch_add(1, Ordering::Relaxed);
            None
        }
    }

    #[test]
    fn validation_does_not_consume_application_session_tickets() {
        let (client, _) = configs();
        let store = Arc::new(SessionStore::default());
        let captured = store.clone();
        let client = client.with_modify_rustls_config(move |mut native| {
            native.resumption = Resumption::store(captured.clone());
            Ok(native)
        });
        let client =
            QuicClientConfig::from_rama(&client, configured_provider(), TlsOptions::default())
                .unwrap();
        assert_eq!(store.reads.load(Ordering::Relaxed), 0);
        Arc::new(client)
            .start_session(Version::V1, "localhost", &TransportParameters::default())
            .unwrap();
        assert!(store.reads.load(Ordering::Relaxed) > 0);
    }

    #[test]
    fn full_offers_ignore_stores_installed_by_native_hooks() {
        for (retention, mode) in [
            (ClientSessionPolicy::Fresh, ClientHandshake::Auto),
            (ClientSessionPolicy::Reuse, ClientHandshake::Full),
        ] {
            let (client, _) = configs();
            let store = Arc::new(SessionStore::default());
            let captured = store.clone();
            let client = client
                .with_client_handshake(mode)
                .with_modify_rustls_config(move |mut native| {
                    native.resumption = Resumption::store(captured.clone());
                    Ok(native)
                });
            let client = Arc::new(
                QuicClientConfig::from_rama(
                    &client,
                    configured_provider(),
                    TlsOptions::default().with_client_sessions(retention),
                )
                .unwrap(),
            );
            for version in [Version::V1, Version::V2] {
                for _ in 0..3 {
                    let mut session = client
                        .clone()
                        .start_session(version, "localhost", &TransportParameters::default())
                        .unwrap();
                    assert!(session.poll_handshake().unwrap().is_some());
                }
            }
            assert_eq!(store.reads.load(Ordering::Relaxed), 0);
        }
    }

    #[test]
    fn invalid_native_sessions_return_errors_instead_of_panicking() {
        let (client, server) = configs();
        let mut client =
            QuicClientConfig::from_rama(&client, configured_provider(), TlsOptions::default())
                .unwrap();
        let mut server =
            QuicServerConfig::from_rama(&server, configured_provider(), TlsOptions::default())
                .unwrap();
        client.inner = Arc::new(
            rustls::ClientConfig::builder_with_provider(configured_provider())
                .with_protocol_versions(&[&rustls::version::TLS12])
                .unwrap()
                .with_root_certificates(client_root_certs())
                .with_no_client_auth(),
        );
        Arc::make_mut(&mut server.inner).max_early_data_size = 23;
        let params = TransportParameters::default();
        assert!(matches!(
            Arc::new(client).start_session(Version::V1, "localhost", &params),
            Err(ConnectError::Crypto(_))
        ));
        let error = Arc::new(server)
            .start_session(Version::V1, &params)
            .err()
            .unwrap();
        assert!(
            error
                .source()
                .unwrap()
                .downcast_ref::<rustls::Error>()
                .is_some()
        );
    }

    #[tokio::test]
    async fn chacha_only_hook_preserves_initial_encryption_and_negotiates_chacha() {
        use rama_core::extensions::ExtensionsRef as _;
        tokio::time::timeout(Duration::from_secs(5), async {
            let (mut client_tls, server_tls) = configs();
            let policy = client_tls.clone();
            client_tls.set_modify_rustls_config(move |_| {
                let mut provider = (*configured_provider()).clone();
                provider.cipher_suites.retain(|suite| {
                    suite.suite() == rustls::CipherSuite::TLS13_CHACHA20_POLY1305_SHA256
                });
                RustlsTlsConnectorConfig::from_extensions(policy.as_extensions())
                    .try_into_client_config_with_provider(Arc::new(provider))
            });
            let client_config = ClientConfig::new(Arc::new(
                QuicClientConfig::from_rama(
                    &client_tls,
                    configured_provider(),
                    TlsOptions::default(),
                )
                .unwrap(),
            ));
            let server_config = ServerConfig::with_crypto(Arc::new(
                QuicServerConfig::from_rama(
                    &server_tls,
                    configured_provider(),
                    TlsOptions::default(),
                )
                .unwrap(),
            ));
            let server = Endpoint::bind_server(
                Executor::new(),
                server_config,
                "127.0.0.1:0".parse::<SocketAddr>().unwrap(),
            )
            .await
            .unwrap();
            let client = Endpoint::bind_client(
                Executor::new(),
                "127.0.0.1:0".parse::<SocketAddr>().unwrap(),
            )
            .await
            .unwrap();
            let connecting = client
                .connect_with(client_config, server.local_addr().unwrap(), "localhost")
                .unwrap();
            let (outgoing, incoming) =
                tokio::join!(connecting, async { server.accept().await.unwrap().await });
            let outgoing = outgoing.unwrap();
            let incoming = incoming.unwrap();
            for connection in [&outgoing, &incoming] {
                assert_eq!(
                    connection
                        .extensions()
                        .get_ref::<crate::NegotiatedTlsParameters>()
                        .unwrap()
                        .algorithms
                        .cipher_suite,
                    Some(rama_tls::CipherSuite::TLS13_CHACHA20_POLY1305_SHA256)
                );
            }
            let mut send = outgoing.open_uni().await.unwrap();
            send.write_all(b"ChaCha with AES Initial").await.unwrap();
            send.finish().unwrap();
            assert_eq!(
                incoming
                    .accept_uni()
                    .await
                    .unwrap()
                    .read_to_end(64)
                    .await
                    .unwrap(),
                b"ChaCha with AES Initial"
            );
            outgoing.close(0u32, b"done");
            client.wait_idle().await;
            server.wait_idle().await;
        })
        .await
        .unwrap();
    }

    #[test]
    fn hook_can_supply_initial_cipher_missing_from_outer_provider() {
        let (client, _) = configs();
        let policy = client.clone();
        let client = client.with_modify_rustls_config(move |_| {
            RustlsTlsConnectorConfig::from_extensions(policy.as_extensions())
                .try_into_client_config_with_provider(configured_provider())
        });
        let mut outer = (*configured_provider()).clone();
        outer
            .cipher_suites
            .retain(|suite| suite.suite() != rustls::CipherSuite::TLS13_AES_128_GCM_SHA256);
        QuicClientConfig::from_rama(&client, Arc::new(outer), TlsOptions::default()).unwrap();
    }

    #[tokio::test]
    async fn early_server_handle_reports_failed_client_authentication() {
        tokio::time::timeout(Duration::from_secs(5), async {
            let (client_tls, server_tls) = configs();
            let (chain, _) = self_signed_client_auth().unwrap();
            let server_tls = server_tls.with_client_verify(ClientVerifyMode::ClientAuth(chain));
            let client_config = ClientConfig::new(Arc::new(
                QuicClientConfig::from_rama(
                    &client_tls,
                    configured_provider(),
                    TlsOptions::default(),
                )
                .unwrap(),
            ));
            let server_config = ServerConfig::with_crypto(Arc::new(
                QuicServerConfig::from_rama(
                    &server_tls,
                    configured_provider(),
                    TlsOptions::default(),
                )
                .unwrap(),
            ));
            let server = Endpoint::bind_server(
                Executor::new(),
                server_config,
                "127.0.0.1:0".parse::<SocketAddr>().unwrap(),
            )
            .await
            .unwrap();
            let client = Endpoint::bind_client(
                Executor::new(),
                "127.0.0.1:0".parse::<SocketAddr>().unwrap(),
            )
            .await
            .unwrap();
            let connecting = client
                .connect_with(client_config, server.local_addr().unwrap(), "localhost")
                .unwrap();
            let (_, (connection, error)) = tokio::join!(connecting, async {
                let incoming = server.accept().await.unwrap().accept().unwrap();
                let (connection, established) = incoming.into_0rtt().unwrap();
                let error = established.await.unwrap_err();
                (connection, error)
            });
            assert_matches!(error, crate::ConnectionError::TransportError(_));
            assert!(
                error
                    .source()
                    .unwrap()
                    .source()
                    .unwrap()
                    .downcast_ref::<rustls::Error>()
                    .is_some()
            );
            assert!(connection.close_reason().is_some());
            client.wait_idle().await;
            server.wait_idle().await;
        })
        .await
        .unwrap();
    }

    #[derive(Debug, Default)]
    struct KeyLogCount(AtomicUsize);

    impl KeyLogSink for KeyLogCount {
        fn write_line(&self, line: &str) {
            assert!(line.ends_with('\n'));
            self.0.fetch_add(1, Ordering::Relaxed);
        }
    }

    #[tokio::test]
    async fn authenticated_common_tls_over_quic_streams() {
        tokio::time::timeout(Duration::from_secs(5), async {
            for policy in [AlpnPolicy::Require, AlpnPolicy::OutOfBandAgreement] {
                let (client_tls, server_tls) = configs();
                let (chain, key) = self_signed_client_auth().unwrap();
                let client_tls = client_tls.with_client_auth(ClientAuth::Single(ClientAuthData {
                    cert_chain: chain.clone(),
                    private_key: key,
                }));
                let server_tls = server_tls.with_client_verify(ClientVerifyMode::ClientAuth(chain));
                let client_log = Arc::new(KeyLogCount::default());
                let server_log = Arc::new(KeyLogCount::default());
                let client_tls =
                    client_tls.with_keylog(rama_tls::KeyLogIntent::Custom(client_log.clone()));
                let server_tls =
                    server_tls.with_keylog(rama_tls::KeyLogIntent::Custom(server_log.clone()));

                // Select the trusted certificate by SNI, replacing an unrelated base
                // identity so success proves the resolver was actually used.
                let auth = RustlsTlsAcceptorConfig::from_extensions(server_tls.as_extensions())
                    .server_auth
                    .unwrap()
                    .0
                    .clone();
                let cert = rustls::sign::CertifiedKey::from_der(
                    auth.cert_chain,
                    auth.private_key,
                    &configured_provider(),
                )
                .unwrap();
                let mut resolver = rustls::server::ResolvesServerCertUsingSni::new();
                resolver.add("localhost", cert).unwrap();
                let resolver = Arc::new(resolver);
                let server_tls = server_tls
                    .try_with_generated_server_auth(GeneratedServerAuthConfig::default())
                    .unwrap()
                    .with_modify_rustls_config(move |mut native| {
                        native.cert_resolver = resolver.clone();
                        Ok(native)
                    });
                if policy == AlpnPolicy::OutOfBandAgreement {
                    client_tls.insert(TlsAlpn(Default::default()));
                    server_tls.insert(TlsAlpn(Default::default()));
                }
                let options = TlsOptions {
                    alpn: policy,
                    ..Default::default()
                };
                let client_config = ClientConfig::new(Arc::new(
                    QuicClientConfig::from_rama(&client_tls, configured_provider(), options)
                        .unwrap(),
                ));
                let server_config = ServerConfig::with_crypto(Arc::new(
                    QuicServerConfig::from_rama(&server_tls, configured_provider(), options)
                        .unwrap(),
                ));
                let server = Endpoint::bind_server(
                    Executor::new(),
                    server_config,
                    "127.0.0.1:0".parse::<SocketAddr>().unwrap(),
                )
                .await
                .unwrap();
                let client = Endpoint::bind_client(
                    Executor::new(),
                    "127.0.0.1:0".parse::<SocketAddr>().unwrap(),
                )
                .await
                .unwrap();
                let connecting = client
                    .connect_with(client_config, server.local_addr().unwrap(), "localhost")
                    .unwrap();
                let (client_conn, server_conn) =
                    tokio::join!(connecting, async { server.accept().await.unwrap().await });
                let client_conn = client_conn.unwrap();
                let server_conn = server_conn.unwrap();
                assert!(client_log.0.load(Ordering::Relaxed) > 0);
                assert!(server_log.0.load(Ordering::Relaxed) > 0);
                let mut send = client_conn.open_uni().await.unwrap();
                send.write_all(b"common TLS over QUIC").await.unwrap();
                send.finish().unwrap();
                let mut receive = server_conn.accept_uni().await.unwrap();
                assert_eq!(
                    receive.read_to_end(64).await.unwrap(),
                    b"common TLS over QUIC"
                );
                client_conn.close(VarInt::from_u32(0), b"done");
                client.wait_idle().await;
                server.wait_idle().await;
            }
        })
        .await
        .unwrap();
    }
}
