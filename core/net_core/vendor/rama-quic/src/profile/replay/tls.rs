//! Prepare a captured QUIC TLS offer for BoringSSL without connection I/O.
//!
//! Wire choices come from the capture. Authentication, credentials and key
//! logging remain caller policy; the transport engine supplies fresh parameters.
//! This module prepares TLS only, not QUIC packet layout or HTTP/3 streams.

use rama_core::{
    error::{BoxError, BoxErrorExt as _},
    telemetry::tracing,
};
use rama_tls::{ExtensionId, client::TlsClientConfig};
use rama_tls_boring::client::{
    BoringTlsConnectorConfig,
    profile::wire::{self, TransportShape},
};
use rama_ua::profile::{
    capture::tls::{TlsCapture, TlsCaptureTransport, TlsCapturedExtensionValue},
    replay::request::{
        LoweredProfileItem, ProfilePreservationDifference, ProfilePreservationReport,
    },
};

use crate::tls::ClientHandshake;

/// Compile wire options; the native connector owns sessions, identity and I/O.
pub(crate) fn compile(
    policy: &TlsClientConfig,
    capture: &TlsCapture,
    report: &mut ProfilePreservationReport,
) -> Result<TlsClientConfig, BoxError> {
    if !matches!(capture.transport, TlsCaptureTransport::Quic) {
        return Err(BoxError::from_static_str(
            "QUIC TLS replay requires a QUIC capture",
        ));
    }
    let parameters_len = capture
        .extensions
        .iter()
        .find_map(
            |extension| match (ExtensionId::from(extension.id), &extension.value) {
                (
                    ExtensionId::QUIC_TRANSPORT_PARAMETERS,
                    TlsCapturedExtensionValue::ConnectionLength(length),
                ) => Some(usize::from(*length)),
                _ => None,
            },
        )
        .ok_or_else(|| BoxError::from_static_str("QUIC TLS capture has no parameter shape"))?;
    let current = BoringTlsConnectorConfig::from_extensions(policy.as_extensions());
    let wire = wire::compile_for_policy(
        TransportShape::Quic { parameters_len },
        capture,
        &current,
        report,
    )?;
    Ok(wire.with_client_handshake(captured_handshake(capture, report)))
}

/// A captured session offer is replayed only when a stored session exists.
fn captured_handshake(
    capture: &TlsCapture,
    report: &mut ProfilePreservationReport,
) -> ClientHandshake {
    if !capture
        .extensions
        .iter()
        .any(|extension| extension.id == u16::from(ExtensionId::PRE_SHARED_KEY))
    {
        return ClientHandshake::Full;
    }
    tracing::debug!("captured QUIC TLS session offer is sent only with a stored session");
    report.push(ProfilePreservationDifference::LoweredProfileItem {
        item: LoweredProfileItem::TlsSessionOfferOptional,
    });
    ClientHandshake::Auto
}

#[cfg(test)]
mod tests {
    use super::*;
    use rama_ua::profile::capture::{
        completeness::ProfileCaptureCompleteness, tls::TlsCapturedExtension,
    };

    #[test]
    fn captured_session_offer_never_requires_a_stored_session() {
        let mut capture = TlsCapture {
            completeness: ProfileCaptureCompleteness::Complete,
            transport: TlsCaptureTransport::Quic,
            protocol_version: 0x0303,
            ciphers: Box::default(),
            compression: Box::default(),
            extensions: Box::default(),
        };
        let mut report = ProfilePreservationReport::default();
        assert_eq!(
            captured_handshake(&capture, &mut report),
            ClientHandshake::Full
        );
        assert!(report.is_exact());
        capture.extensions = vec![TlsCapturedExtension {
            id: u16::from(ExtensionId::PRE_SHARED_KEY),
            value: TlsCapturedExtensionValue::PreSharedKeys {
                identities: vec![32].into(),
                binders: vec![32].into(),
            },
        }]
        .into();
        assert_eq!(
            captured_handshake(&capture, &mut report),
            ClientHandshake::Auto
        );
        assert!(
            report
                .differences
                .contains(&ProfilePreservationDifference::LoweredProfileItem {
                    item: LoweredProfileItem::TlsSessionOfferOptional,
                })
        );
    }
}
