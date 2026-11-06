//! Compile and exercise the provider interface as an external consumer, including without
//! any built-in TLS or packet-crypto feature.

use std::{
    assert_matches,
    sync::{
        Arc,
        atomic::{AtomicUsize, Ordering},
    },
    task::Context,
};

use rama_core::error::BoxError;
use rama_quic::{
    ClientConfig, ConnectError, Endpoint, NegotiatedTlsParameters, ServerConfig,
    tls::provider::{
        AeadKey, ClientConfig as ClientProvider, ExportKeyingMaterialError, HandshakeEvent,
        HandshakeTokenKey, InitialKeysError, InitialServerConfig, KeyPair, Keys,
        ServerConfig as ServerProvider, Session, UnsupportedVersion,
    },
};
use rama_quic_proto::{
    ConnectionId, Side, TransportError, TransportErrorCode, Version,
    crypto::{CryptoError, HeaderKey, PacketKey},
    packet::SpaceId as EncryptionLevel,
    transport_parameters::TransportParameters,
};

struct Provider(Arc<AtomicUsize>);
struct TestSession;
struct TokenKey;

impl ClientProvider for Provider {
    #[expect(
        clippy::unwrap_used,
        reason = "test fixture validates transport parameters"
    )]
    fn start_session(
        self: Arc<Self>,
        _: Version,
        _: &str,
        params: &TransportParameters,
    ) -> Result<Box<dyn Session>, ConnectError> {
        self.0.fetch_add(1, Ordering::Relaxed);
        let mut extension = Vec::new();
        params.write(&mut extension);
        TransportParameters::read(Side::Server, &mut extension.as_slice()).unwrap();
        Ok(Box::new(TestSession))
    }
    fn supports_version_switch(&self) -> bool {
        false
    }
    fn resumable_version(&self, _: &str) -> Option<Version> {
        None
    }
}

impl InitialServerConfig for Provider {
    fn initial_keys(&self, _: Version, _: &ConnectionId) -> Result<Keys, InitialKeysError> {
        Err(InitialKeysError::Crypto(BoxError::from(
            std::io::Error::other("custom Initial failure"),
        )))
    }
    fn retry_tag(&self, _: Version, _: &ConnectionId, _: &[u8]) -> Result<[u8; 16], CryptoError> {
        Err(CryptoError::new())
    }
}

impl ServerProvider for Provider {
    fn start_session(
        self: Arc<Self>,
        _: Version,
        _: &TransportParameters,
    ) -> Result<Box<dyn Session>, TransportError> {
        Ok(Box::new(TestSession))
    }
    fn supports_compatible_negotiation(&self) -> bool {
        false
    }
    fn start_negotiated_session(
        self: Arc<Self>,
        _: Version,
        _: Version,
        _: &TransportParameters,
    ) -> Result<Box<dyn Session>, TransportError> {
        Ok(Box::new(TestSession))
    }
}

impl Session for TestSession {
    fn initial_keys(&self, _: Version, _: &ConnectionId, _: Side) -> Result<Keys, TransportError> {
        Err(
            TransportError::new(TransportErrorCode::INTERNAL_ERROR, "custom Initial failure")
                .with_cause(std::io::Error::other("custom provider cause")),
        )
    }
    fn switch_version(&mut self, _: Version) -> Result<(), UnsupportedVersion> {
        Err(UnsupportedVersion)
    }
    fn handshake_summary(&self) -> Option<NegotiatedTlsParameters> {
        None
    }
    fn negotiated_alpn(&self) -> Option<&[u8]> {
        None
    }
    fn early_crypto(&self) -> Option<(Box<dyn HeaderKey>, Box<dyn PacketKey>)> {
        None
    }
    fn early_data_accepted(&self) -> Option<bool> {
        None
    }
    fn is_handshaking(&self) -> bool {
        true
    }
    fn poll_pending_callbacks(
        &mut self,
        _: &mut Context<'_>,
    ) -> Result<Option<bool>, TransportError> {
        Ok(None)
    }
    fn cancel_pending_callbacks(&mut self) {}
    fn read_handshake(&mut self, _: EncryptionLevel, _: &[u8]) -> Result<bool, TransportError> {
        Err(TransportError::new(
            TransportErrorCode::crypto(42),
            "custom peer certificate failure",
        ))
    }
    fn transport_parameters(&self) -> Result<Option<TransportParameters>, TransportError> {
        Ok(None)
    }
    fn poll_handshake(&mut self) -> Result<Option<HandshakeEvent>, TransportError> {
        Ok(None)
    }
    fn next_1rtt_keys(&mut self) -> Result<Option<KeyPair<Box<dyn PacketKey>>>, TransportError> {
        Ok(None)
    }
    fn is_valid_retry(&self, _: &ConnectionId, _: &[u8], _: &[u8]) -> bool {
        false
    }
    fn export_keying_material(
        &self,
        _: &mut [u8],
        _: &[u8],
        _: &[u8],
    ) -> Result<(), ExportKeyingMaterialError> {
        Err(ExportKeyingMaterialError::new())
    }
}

impl HandshakeTokenKey for TokenKey {
    fn aead_from_hkdf(&self, _: &[u8]) -> Result<Box<dyn AeadKey>, CryptoError> {
        Err(CryptoError::new())
    }
}

#[tokio::test]
async fn external_provider_runs_without_a_builtin_backend() {
    let started = Arc::new(AtomicUsize::new(0));
    let provider = Arc::new(Provider(started.clone()));
    let server = ServerConfig::new(provider.clone(), Arc::new(TokenKey));
    let endpoint = Endpoint::bind_server(
        rama_core::rt::Executor::new(),
        server,
        "127.0.0.1:0".parse::<std::net::SocketAddr>().unwrap(),
    )
    .await
    .unwrap();
    let result = endpoint.connect_with(
        ClientConfig::new(provider),
        endpoint.local_addr().unwrap(),
        "localhost",
    );
    let error = result.expect_err("the custom session fails Initial key derivation");
    assert_matches!(error, ConnectError::Crypto(_));
    assert!(error.to_string().contains("custom Initial failure"));
    let ConnectError::Crypto(transport_error) = &error else {
        panic!("custom Initial failure must retain its transport error")
    };
    assert!(
        transport_error
            .cause()
            .is_some_and(|cause| cause.downcast_ref::<std::io::Error>().is_some())
    );
    assert_eq!(started.load(Ordering::Relaxed), 1);
    assert_eq!(endpoint.open_connections(), 0);
    endpoint.shutdown().await;
}

#[test]
fn external_provider_can_report_tls_alerts() {
    let error = TestSession
        .read_handshake(EncryptionLevel::Initial, &[])
        .unwrap_err();
    assert_eq!(error.code().as_u64(), 0x12a);
    assert_eq!(error.code().tls_alert(), Some(42));
}
