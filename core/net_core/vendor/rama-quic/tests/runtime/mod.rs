//! What the runtime tests and the examples both need: an identity, the two configurations that
//! trust it, and one exchange each way.

#![allow(
    dead_code,
    reason = "shared support for several integration test binaries, each using part of it"
)]

use std::{net::SocketAddr, sync::Arc, time::Duration};

use rama_core::extensions::ExtensionsRef as _;
use rama_crypto::pki_types::CertificateDer;
use rama_net::tls::ApplicationProtocol;
use rama_quic::{
    ClientConfig, Connection, Endpoint, NegotiatedTlsParameters, QuicConnectionInfo, ServerConfig,
    TransportConfig, tls::TlsOptions,
};
use rama_tls::{
    client::TlsClientConfig,
    server::{GeneratedServerAuthConfig, ServerAuthData, TlsServerConfig},
};
use rama_utils::{collections::smallvec::smallvec, octets};

/// The protocol both ends negotiate.
const ALPN: &[u8] = b"rama-quic-runtime";
/// The most one read takes, so a peer sending more fails rather than filling memory.
const READ_CAP: usize = octets::mib(1);
/// The name the certificate carries and the client asks for.
pub(crate) const SERVER_NAME: &str = "localhost";

/// One generated identity, and the configurations that present and trust it.
#[derive(Debug)]
pub(crate) struct Identities {
    auth: ServerAuthData,
}

impl Identities {
    #[must_use]
    pub(crate) fn new() -> Self {
        Self {
            auth: ServerAuthData::new_generated(GeneratedServerAuthConfig::default()).unwrap(),
        }
    }

    /// What a server presents.
    #[must_use]
    pub(crate) fn server_config(&self) -> ServerConfig {
        let tls = TlsServerConfig::new()
            .with_alpn(smallvec![alpn()])
            .with_server_auth(self.auth.clone());
        let mut config = ServerConfig::try_from_rama_tls(&tls, TlsOptions::default()).unwrap();
        config.set_transport_config(Arc::new(transport()));
        config
    }

    /// What a client trusts, which is this identity and nothing else.
    #[must_use]
    pub(crate) fn client_config(&self) -> ClientConfig {
        let tls = TlsClientConfig::new()
            .with_alpn(smallvec![alpn()])
            .try_with_server_trust_anchors([self.anchor()])
            .unwrap();
        let mut config = ClientConfig::try_from_rama_tls(&tls, TlsOptions::default()).unwrap();
        config.set_transport_config(Arc::new(transport()));
        config
    }

    #[must_use]
    pub(crate) fn anchor(&self) -> CertificateDer<'static> {
        self.auth.cert_chain.last().unwrap().clone()
    }
}

impl Default for Identities {
    fn default() -> Self {
        Self::new()
    }
}

fn alpn() -> ApplicationProtocol {
    ApplicationProtocol::from(ALPN)
}

fn transport() -> TransportConfig {
    let mut transport = TransportConfig::default();
    transport.set_max_idle_timeout(Duration::from_secs(20).try_into().unwrap());
    transport
}

/// Connect, and check the handshake settled the protocol both ends asked for.
pub(crate) async fn connect(
    client: &Endpoint,
    identities: &Identities,
    addr: SocketAddr,
) -> Connection {
    let connection = client
        .connect_with(identities.client_config(), addr, SERVER_NAME)
        .expect("the attempt starts")
        .await
        .expect("the handshake completes");
    assert_eq!(
        connection
            .extensions()
            .get_ref::<NegotiatedTlsParameters>()
            .expect("the handshake settled something")
            .application_layer_protocol,
        Some(alpn()),
        "the protocol both ends agreed on"
    );
    let info = connection
        .extensions()
        .get_ref::<QuicConnectionInfo>()
        .copied()
        .expect("the handshake published the connection info");
    assert_eq!(info.version, connection.version());
    assert_eq!(info.original_version, connection.original_version());
    assert!(!info.early_data_keys_enabled);
    assert!(info.handshake_mtu > 0);
    connection
}

/// One bidirectional exchange from the opening side, checked on the way back.
pub(crate) async fn exchange(connection: &Connection, payload: &[u8]) {
    let (mut send, mut recv) = connection.open_bi().await.expect("a bi stream");
    send.write_all(payload).await.expect("it is written");
    send.finish().expect("the stream ends");
    let back = recv
        .read_to_end(READ_CAP)
        .await
        .expect("the answer arrives");
    assert_eq!(back, payload, "the answer is what was sent");
}

/// Accept one connection, echo one bidirectional stream on it, and wait for it to end.
pub(crate) async fn serve_one(server: &Endpoint) {
    let connection = server
        .accept()
        .await
        .expect("an attempt arrives")
        .await
        .expect("the handshake completes");
    let (mut send, mut recv) = connection.accept_bi().await.expect("the stream arrives");
    let got = recv.read_to_end(READ_CAP).await.expect("it completes");
    send.write_all(&got).await.expect("the answer is written");
    send.finish().expect("the answer ends");
    connection.closed().await;
}
