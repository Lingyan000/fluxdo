//! An AWS-LC Rama run must reject native configs built with Quinn's independent Ring provider.

#![cfg(feature = "rustls-aws-lc")]

use interop_common::{
    backend,
    identity::{anchor_of, server_identity},
};
use std::sync::Arc;

#[test]
fn rama_aws_lc_rejects_native_ring_configs() {
    let identity = server_identity();
    let provider = Arc::new(rustls::crypto::ring::default_provider());
    let mut roots = rustls::RootCertStore::empty();
    roots
        .add(anchor_of(&identity))
        .expect("test identity is trusted");
    let client = rustls::ClientConfig::builder_with_provider(provider.clone())
        .with_protocol_versions(&[&rustls::version::TLS13])
        .expect("Ring supports TLS 1.3")
        .with_root_certificates(roots)
        .with_no_client_auth();
    let server = rustls::ServerConfig::builder_with_provider(provider)
        .with_protocol_versions(&[&rustls::version::TLS13])
        .expect("Ring supports TLS 1.3")
        .with_no_client_auth()
        .with_single_cert(identity.cert_chain, identity.private_key)
        .expect("Ring accepts the identity");
    let client_error =
        backend::verify_client(client).expect_err("Rama must reject the Ring client provider");
    let server_error =
        backend::verify_server(server).expect_err("Rama must reject the Ring server provider");
    for error in [client_error, server_error] {
        assert_eq!(
            error.to_string(),
            "Rama interop did not select the requested Rustls crypto provider"
        );
    }
}
