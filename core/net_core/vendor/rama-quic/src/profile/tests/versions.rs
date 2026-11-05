//! Decode native UDP first flights rather than checking policy constants.

use super::*;
use crate::tls::{QuicClientConfigProvider, TlsOptions};
use rama_net::tls::ApplicationProtocol;
use rama_quic_proto::version::{ReservedQuicVersion, ReservedVersionGrease};
use rama_tls::client::ServerVerifyMode;

fn verify_literal_versions(provider: &dyn QuicClientConfigProvider) {
    let literal = Version::from_u32(0x1a2a_3a4a);
    let reserved = ReservedQuicVersion::try_from(literal).unwrap();
    let tls = TlsClientConfig::new()
        .with_server_verify(ServerVerifyMode::Disable)
        .with_alpn([ApplicationProtocol::HTTP_3].into_iter().collect());
    for original in [Version::V1, Version::V2] {
        let other = if original == Version::V1 {
            Version::V2
        } else {
            Version::V1
        };
        for first in [true, false] {
            let placement = if first {
                ReservedVersionGrease::FixedFirst(reserved)
            } else {
                ReservedVersionGrease::FixedLast(reserved)
            };
            let policy = ClientVersionPolicy::new(original)
                .unwrap()
                .try_with_supported(vec![other, original])
                .unwrap()
                .try_with_compatible(vec![other, original])
                .unwrap()
                .with_reserved_version_grease(placement);
            let encoded = serde_json::to_vec(&policy).unwrap();
            let policy = serde_json::from_slice::<ClientVersionPolicy>(&encoded).unwrap();
            let profile = QuicProfile::standard().with_versions(policy);
            let config = ClientConfig::try_from_rama_tls_with_provider(
                &tls,
                TlsOptions::default(),
                provider,
            )
            .unwrap();
            let (flight, can_switch, _) = rama_first_flight_with(&profile, config, "localhost");
            let mut expected = if can_switch {
                vec![other, original]
            } else {
                vec![original]
            };
            if first {
                expected.insert(0, literal);
            } else {
                expected.push(literal);
            }
            assert_eq!(flight.version, original);
            assert_eq!(flight.chosen_version, Some(original));
            assert_eq!(
                flight.available_versions, expected,
                "native emission must preserve the literal and real-version order"
            );
        }
    }
}

#[cfg(feature = "boring")]
#[test]
fn boring_emits_literal_reserved_versions_in_v1_and_v2() {
    verify_literal_versions(&crate::tls::BoringTlsProvider);
}

#[cfg(all(feature = "rustls", any(feature = "aws-lc", feature = "ring")))]
#[test]
fn rustls_emits_literal_reserved_versions_in_v1_and_v2() {
    verify_literal_versions(&crate::tls::RustlsTlsProvider::new(
        crate::proto::crypto::rustls::configured_provider(),
    ));
}

#[test]
fn serialized_literal_reserved_choices_cannot_smuggle_usable_versions() {
    let reserved = ReservedQuicVersion::try_from(Version::from_u32(0x1a2a_3a4a)).unwrap();
    let policy = ClientVersionPolicy::new(Version::V1)
        .unwrap()
        .with_reserved_version_grease(ReservedVersionGrease::FixedFirst(reserved));
    let encoded = serde_json::to_value(policy).unwrap();
    for invalid in [
        Version::V1,
        Version::V2,
        Version::from_u32(0),
        Version::from_u32(0x1234),
    ] {
        let mut altered = encoded.clone();
        altered["grease"]["FixedFirst"] = serde_json::to_value(invalid).unwrap();
        assert!(
            serde_json::from_value::<ClientVersionPolicy>(altered).is_err(),
            "usable, negotiation and unassigned versions cannot become reserved literals"
        );
    }
}
