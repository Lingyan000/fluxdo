//! TLS fixtures shared by the transport and driver suites.

#![expect(
    clippy::unwrap_used,
    reason = "shared test fixtures fail immediately on invalid setup"
)]

use crate::{ClientConfig, ServerConfig, tls::TlsOptions};
use rama_quic_proto::TransportErrorCode;
use rama_tls::{
    client::TlsClientConfig,
    server::{LeafCertRequest, ServerAuthData, TlsServerConfig},
};

pub(crate) fn identity() -> ServerAuthData {
    ServerAuthData::new_self_signed_leaf(LeafCertRequest::default()).unwrap()
}

pub(crate) fn options() -> TlsOptions {
    TlsOptions::default().with_early_data(true)
}

pub(crate) fn client(identity: &ServerAuthData) -> ClientConfig {
    let tls = TlsClientConfig::new()
        .with_alpn([b"rama-quic-test".as_slice().into()].into_iter().collect())
        .try_with_server_trust_anchors([identity.cert_chain.last().unwrap().clone()])
        .unwrap();
    ClientConfig::try_from_rama_tls(&tls, options()).unwrap()
}

pub(crate) fn server(identity: &ServerAuthData) -> ServerConfig {
    let tls = TlsServerConfig::new()
        .with_alpn([b"rama-quic-test".as_slice().into()].into_iter().collect())
        .with_server_auth(identity.clone());
    ServerConfig::try_from_rama_tls(&tls, options()).unwrap()
}

pub(crate) fn untrusted_identity() -> ServerAuthData {
    let mut request = LeafCertRequest::default();
    request.config.subject.organisation_name = Some("Rama test issuer".into());
    ServerAuthData::new_self_signed_leaf(request).unwrap()
}

pub(crate) fn untrusted_certificate_error() -> TransportErrorCode {
    // TLS unknown_ca alert, independent of the provider's native error type.
    TransportErrorCode::crypto(48)
}
