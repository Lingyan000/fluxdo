//! Failure classification of QUIC connection attempts and address races.

use rama_core::error::{BoxError, BoxErrorExt as _, error_chain};
use rama_net::{
    address::SocketAddress,
    client::{
        ConnectionAttempt, ConnectionError,
        ConnectionErrorDomain::{Application, Local, Transport},
        ConnectionErrorKind::{
            Authentication, InvalidInput, Protocol, Rejected, Timeout, Unavailable,
        },
    },
};
use rama_quic_proto::{TransportError, TransportErrorCode, frame::ApplicationClose};

use crate::{
    ConnectError as QuicConnectError, ConnectionError as QuicConnectionError,
    client::{ConnectFailures, TLS_NO_APPLICATION_PROTOCOL, classify_connect_error},
};

#[test]
fn address_race_preserves_authentication_failure_in_any_order() {
    let authentication = QuicConnectionError::TransportError(TransportErrorCode::crypto(42).into());
    let protocol =
        QuicConnectionError::TransportError(TransportErrorCode::PROTOCOL_VIOLATION.into());
    for errors in [
        vec![authentication.clone(), QuicConnectionError::TimedOut],
        vec![
            authentication.clone(),
            QuicConnectionError::TimedOut,
            protocol.clone(),
            QuicConnectionError::Reset,
        ],
        vec![
            protocol,
            QuicConnectionError::Reset,
            authentication.clone(),
            QuicConnectionError::TimedOut,
        ],
    ] {
        let failures = ConnectFailures::default();
        let attempt = ConnectionAttempt::default();
        for error in errors {
            drop(failures.record(error.into(), &attempt));
        }
        // The final race result may only expose its last timed-out address.
        let error = failures.finish(QuicConnectionError::TimedOut.into());
        assert_eq!(attempt.failure_kind(), Some(Authentication));
        assert_eq!(error.domain(), Application);
        assert_eq!(error.kind(), Authentication);
        assert!(
            error_chain(error.get_ref()).any(|cause| {
                cause.downcast_ref::<QuicConnectionError>() == Some(&authentication)
            })
        );
    }
}

#[test]
fn unsupported_address_family_does_not_poison_the_address_race() {
    let failures = ConnectFailures::default();
    let attempt = ConnectionAttempt::default();
    let ipv6 = QuicConnectError::InvalidRemoteAddress(SocketAddress::local_ipv6(443).into());
    drop(failures.record(ipv6.into(), &attempt));
    let timeout = failures.record(QuicConnectionError::TimedOut.into(), &attempt);
    let error = failures.finish(timeout);
    assert!(!attempt.failed());
    assert_eq!((error.domain(), error.kind()), (Transport, Timeout));
    for address in [
        SocketAddress::local_ipv4(0),
        SocketAddress::default_ipv6(443),
    ] {
        assert_eq!(
            classify_connect_error(&QuicConnectError::InvalidRemoteAddress(address.into())),
            (Local, InvalidInput)
        );
    }
}

#[test]
fn quic_establishment_failures_preserve_their_domain() {
    let cases = [
        (QuicConnectionError::Reset, Transport, Unavailable),
        (QuicConnectionError::TimedOut, Transport, Timeout),
        (QuicConnectionError::CidsExhausted, Local, Unavailable),
        (QuicConnectionError::EndpointInUse, Local, Unavailable),
        (QuicConnectionError::LocallyClosed, Local, Unavailable),
        (
            QuicConnectionError::TransportError(TransportErrorCode::CONNECTION_REFUSED.into()),
            Transport,
            Unavailable,
        ),
        (
            QuicConnectionError::ConnectionClosed(
                TransportError::from(TransportErrorCode::CONNECTION_REFUSED).into(),
            ),
            Transport,
            Unavailable,
        ),
        (
            QuicConnectionError::TransportError(TransportErrorCode::PROTOCOL_VIOLATION.into()),
            Application,
            Protocol,
        ),
        (
            QuicConnectionError::TransportError(TransportErrorCode::crypto(42).into()),
            Application,
            Authentication,
        ),
        (
            QuicConnectionError::TransportError(
                TransportErrorCode::crypto(TLS_NO_APPLICATION_PROTOCOL).into(),
            ),
            Application,
            Protocol,
        ),
        (
            QuicConnectionError::ApplicationClosed(ApplicationClose {
                error_code: 0u32.into(),
                reason: Default::default(),
            }),
            Application,
            Rejected,
        ),
    ];
    for (error, domain, kind) in cases {
        assert_eq!(classify_connect_error(&error), (domain, kind), "{error}");
    }
    let alpn = ConnectionError::application(BoxError::from_static_str("wrong ALPN"), Protocol);
    assert_eq!(classify_connect_error(&alpn), (Application, Protocol));
    for error in [
        QuicConnectError::CidsExhausted,
        QuicConnectError::EndpointInUse,
    ] {
        assert_eq!(classify_connect_error(&error), (Local, Unavailable));
    }
}
