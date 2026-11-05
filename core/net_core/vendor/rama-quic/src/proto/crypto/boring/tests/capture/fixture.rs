//! Native TLS offers with stable optional layout and real authentication.

use super::*;
use crate::{ClientConfig, profile::replay::tls};
use rama_core::error::BoxError;
use rama_crypto::dep::boring::ssl::Padding;
use rama_net::address::Host;
use rama_tls::client::ClientHello;
use rama_tls_boring::client::BoringClientConfigExt as _;
use rama_ua::profile::{
    capture::{
        completeness::ProfileCaptureCompleteness,
        tls::{TlsCapture, TlsCaptureLimits, TlsCaptureTransport},
    },
    replay::request::ProfilePreservationReport,
};

pub(super) fn reference(policy: &TlsClientConfig, version: Version) -> TlsCapture {
    let client = BoringTlsProvider
        .client_config(policy, TlsOptions::default())
        .unwrap();
    first_capture(client.crypto, version)
}

pub(super) fn first_capture(client: Arc<dyn crypto::ClientConfig>, version: Version) -> TlsCapture {
    capture(&first_hello(client, version, &params(Side::Client)))
}

pub(super) fn first_hello(
    client: Arc<dyn crypto::ClientConfig>,
    version: Version,
    parameters: &TransportParameters,
) -> ClientHello {
    let mut session = client
        .start_session(version, "localhost", parameters)
        .unwrap();
    let mut bytes = Vec::new();
    while let Some(event) = session.poll_handshake().unwrap() {
        let HandshakeEvent::Data(_, data) = event else {
            panic!("unexpected first-flight keys");
        };
        bytes.extend_from_slice(&data);
    }
    let ClientHelloHandshakePrefix::Complete(hello) = parse_client_hello_message_prefix(&bytes)
    else {
        panic!("native ClientHello incomplete");
    };
    hello
}

pub(super) fn capture(hello: &ClientHello) -> TlsCapture {
    TlsCapture::capture(
        ProfileCaptureCompleteness::Complete,
        TlsCaptureTransport::Quic,
        hello,
        TlsCaptureLimits::default(),
    )
    .unwrap()
}

pub(super) fn policy() -> (TlsClientConfig, TlsServerConfig) {
    let (mut client, server) = configs();
    // The test controls only optional layout choices; authentication stays real.
    client.set_client_hello_padding(Padding::Off);
    client.set_grease(false);
    client.set_permute_extensions(false);
    (client, server)
}

/// Prepare through the UA adapter and the actual configured native provider.
pub(super) fn prepare_tls(
    policy: &TlsClientConfig,
    options: TlsOptions,
    peer: &Host,
    capture: &TlsCapture,
) -> Result<ClientConfig, BoxError> {
    let cache = ClientConfigCache::new(Arc::new(BoringTlsProvider), options);
    prepare_with_cache(&cache, policy, peer, capture)
}

/// Compile ordinary options, then let the native cache own peer-bound sessions.
pub(super) fn prepare_with_cache(
    cache: &ClientConfigCache,
    policy: &TlsClientConfig,
    peer: &Host,
    capture: &TlsCapture,
) -> Result<ClientConfig, BoxError> {
    let wire = tls::compile(policy, capture, &mut ProfilePreservationReport::default())?;
    let effective = policy.clone().with_overrides(wire.as_extensions());
    Ok(cache.client_config_for_peer(&effective, effective.as_extensions(), peer)?)
}
