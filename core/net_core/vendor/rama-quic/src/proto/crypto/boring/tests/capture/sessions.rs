//! Captured native TLS shape checks, with real ephemeral keys and current policy.

use super::parameters::ParameterExpectation;
use super::{fixture::*, *};

use rama_net::address::Host;
use rama_quic_proto::{
    capture::{CaptureLimits, transport_parameters_from_hello},
    transport_parameters::TransportParameterId,
};
use rama_tls::CipherSuite;
use rama_tls_boring::client::BoringClientConfigExt as _;
use rama_ua::profile::{
    capture::{
        completeness::ProfileCaptureCompleteness,
        order::{OrderCaptureLimits, OrderNamespace, OrderedProtocolCapture},
    },
    replay::request::{
        LoweredProfileItem, ProfilePreservationDifference, ProfilePreservationReport,
    },
};

use crate::profile::replay::tls;

#[test]
fn captured_quic_tls_preparation_authenticates_with_fresh_native_sessions() {
    for version in [Version::V1, Version::V2] {
        let (policy, server) = policy();
        let source = reference(&policy, version);
        let prepared = prepare_tls(
            &policy,
            TlsOptions::default(),
            &Host::try_from("localhost").unwrap(),
            &source,
        )
        .unwrap()
        .crypto;
        let server = BoringTlsProvider
            .server_config(&server, TlsOptions::default())
            .unwrap()
            .crypto
            .into_fixed();
        for _ in 0..2 {
            let mut c = prepared
                .clone()
                .start_session(version, "localhost", &params(Side::Client))
                .unwrap();
            let mut s = server
                .clone()
                .start_session(version, &params(Side::Server))
                .unwrap();
            check_session(&mut *c, &mut *s, false);
        }
    }
}

#[test]
fn wire_comparison_detects_native_tls_overrides() {
    let (policy, _) = policy();
    let source = reference(&policy, Version::V1);
    policy
        .as_extensions()
        .insert(HandshakeInitializer(Arc::new(|ssl| {
            ssl.set_alpn_protos(b"\x05other")?;
            Ok(())
        })));
    let prepared = prepare_tls(
        &policy,
        TlsOptions::default(),
        &Host::try_from("localhost").unwrap(),
        &source,
    )
    .unwrap()
    .crypto;
    assert_ne!(first_capture(prepared, Version::V1), source);
}

#[test]
fn captured_parameter_length_cannot_replace_current_connection_parameters() {
    let (policy, _) = policy();
    let source = reference(&policy, Version::V1);
    let prepared = prepare_tls(
        &policy,
        TlsOptions::default(),
        &Host::try_from("localhost").unwrap(),
        &source,
    )
    .unwrap()
    .crypto;
    let mut actual = params(Side::Client);
    actual.initial_src_cid = Some(ConnectionId::new(&[1, 2]));
    let hello = first_hello(prepared, Version::V1, &actual);
    let emitted = transport_parameters_from_hello(&hello, &CaptureLimits::default()).unwrap();
    let cid = emitted
        .iter()
        .find(|parameter| parameter.id == TransportParameterId::InitialSourceConnectionId)
        .unwrap();
    assert_eq!(cid.value, [1, 2]);
    assert_ne!(capture(&hello), source);
}

#[test]
fn captured_wire_choices_never_override_explicit_cipher_policy() {
    let (mut policy, _) = policy();
    let source = reference(&policy, Version::V1);
    policy.set_cipher_suites(vec![CipherSuite::TLS13_AES_128_GCM_SHA256]);
    let mut report = ProfilePreservationReport::default();
    tls::compile(&policy, &source, &mut report).unwrap();
    assert_eq!(
        report.differences.as_ref(),
        [ProfilePreservationDifference::LoweredProfileItem {
            item: LoweredProfileItem::CallerTlsCipherSuites
        }]
    );
    prepare_tls(
        &policy,
        TlsOptions::default(),
        &Host::try_from("localhost").unwrap(),
        &source,
    )
    .unwrap();
}

#[test]
fn a_real_resumed_capture_without_a_current_ticket_offers_a_full_handshake() {
    let (policy, server) = policy();
    let client = BoringTlsProvider
        .client_config(&policy, TlsOptions::default())
        .unwrap()
        .crypto;
    let server = BoringTlsProvider
        .server_config(&server, TlsOptions::default())
        .unwrap()
        .crypto
        .into_fixed();
    let mut c = client
        .clone()
        .start_session(Version::V1, "localhost", &params(Side::Client))
        .unwrap();
    let mut s = server
        .start_session(Version::V1, &params(Side::Server))
        .unwrap();
    check_session(&mut *c, &mut *s, false);
    let resumed = first_capture(client, Version::V1);
    assert!(
        resumed
            .extensions
            .iter()
            .any(|extension| extension.id == u16::from(ExtensionId::PRE_SHARED_KEY))
    );
    let _session = prepare_tls(
        &policy,
        TlsOptions::default(),
        &Host::try_from("localhost").unwrap(),
        &resumed,
    )
    .unwrap()
    .crypto
    .start_session(Version::V1, "localhost", &params(Side::Client))
    .unwrap();
}

fn checked_parameters(
    parameters: &TransportParameters,
    version: Version,
) -> (Arc<dyn crypto::ClientConfig>, ParameterExpectation) {
    let (policy, _) = policy();
    let client = BoringTlsProvider
        .client_config(&policy, TlsOptions::default())
        .unwrap();
    let hello = first_hello(client.crypto, version, parameters);
    let raw = transport_parameters_from_hello(&hello, &CaptureLimits::default()).unwrap();
    let expected = OrderedProtocolCapture::capture(
        ProfileCaptureCompleteness::Complete,
        OrderNamespace::QuicParameter,
        raw.iter()
            .map(|field| (u64::from(field.id), field.value.as_slice())),
        OrderCaptureLimits::default(),
    )
    .unwrap();
    let client = prepare_tls(
        &policy,
        TlsOptions::default(),
        &Host::try_from("localhost").unwrap(),
        &capture(&hello),
    )
    .unwrap()
    .crypto;
    (client, ParameterExpectation::try_from(expected).unwrap())
}

#[test]
fn emitted_parameter_literals_are_compared_even_when_the_body_length_matches() {
    for version in [Version::V1, Version::V2] {
        let mut current = params(Side::Client);
        current.extra.push((
            u64::from(TransportParameterId::GoogleConnectionOptions),
            vec![1, 2, 3, 4],
        ));
        let (prepared, expected) = checked_parameters(&current, version);
        expected
            .validate(&first_hello(prepared.clone(), version, &current))
            .unwrap();
        current.extra[0].1[0] = 5;
        let actual = first_hello(prepared, version, &current);
        expected.validate(&actual).unwrap_err();
    }
}

#[test]
fn emitted_parameter_binding_lengths_are_compared_independently_of_body_length() {
    for version in [Version::V1, Version::V2] {
        let mut current = params(Side::Client);
        current
            .extra
            .push((u64::from(TransportParameterId::DebuggingSni), vec![1, 2]));
        let (prepared, expected) = checked_parameters(&current, version);
        expected
            .validate(&first_hello(prepared.clone(), version, &current))
            .unwrap();
        current.initial_src_cid = Some(ConnectionId::new(&[7, 8]));
        current.extra[0].1.truncate(1);
        let actual = first_hello(prepared, version, &current);
        expected.validate(&actual).unwrap_err();
    }
}
