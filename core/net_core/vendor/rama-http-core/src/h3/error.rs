//! HTTP/3 errors retain the protocol code and its connection/stream scope.

use rama_http_types::proto::h3::Code;
use rama_quic_proto::ConnectionError as QuicConnectionError;
use rama_quic_proto::TransportErrorCode;

use super::frame::FrameError;
use super::qpack::{ErrorScope, QpackError};

/// A terminal HTTP/3 protocol error.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Error {
    code: Code,
    scope: ErrorScope,
    reason: &'static str,
    source: Source,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Source {
    Local,
    Remote,
    PeerStop,
    /// The peer reset its send direction of the stream (RESET_STREAM).
    PeerReset,
    /// The connection closed or failed underneath the stream.
    ConnectionLost,
    /// This endpoint closed the connection underneath the stream.
    LocalConnectionLost,
    EarlyDataRejected,
}

impl Error {
    /// Construct a connection error.
    #[must_use]
    pub const fn connection(code: Code, reason: &'static str) -> Self {
        Self {
            code,
            scope: ErrorScope::Connection,
            reason,
            source: Source::Local,
        }
    }

    pub(crate) const fn early_data_rejected() -> Self {
        Self {
            code: Code::H3_REQUEST_CANCELLED,
            scope: ErrorScope::Connection,
            reason: "TLS rejected the early HTTP/3 attempt",
            source: Source::EarlyDataRejected,
        }
    }

    /// The server rejected this connection's TLS early data, which retired the connection.
    ///
    /// Its requests were not processed, so they can be resent on a new connection.
    #[must_use]
    pub const fn is_early_data_rejected(self) -> bool {
        matches!(self.source, Source::EarlyDataRejected)
    }

    /// Construct an error affecting one request or push stream.
    #[must_use]
    pub const fn stream(code: Code, reason: &'static str) -> Self {
        Self {
            code,
            scope: ErrorScope::Stream,
            reason,
            source: Source::Local,
        }
    }

    pub(crate) fn peer_stopped(code: Code) -> Self {
        Self {
            code,
            scope: ErrorScope::Stream,
            reason: "peer stopped sending",
            source: Source::PeerStop,
        }
    }

    pub(crate) const fn is_peer_stop(self) -> bool {
        matches!(self.source, Source::PeerStop)
    }

    pub(crate) fn peer_reset(code: Code) -> Self {
        Self {
            code,
            scope: ErrorScope::Stream,
            reason: "peer reset stream",
            source: Source::PeerReset,
        }
    }

    /// The peer reset its send direction; our own send direction is unaffected.
    pub(crate) const fn is_peer_reset(self) -> bool {
        matches!(self.source, Source::PeerReset)
    }

    /// Connection closure or failure, by either endpoint, also after conversion into a
    /// stream error.
    pub(crate) const fn is_connection_loss(self) -> bool {
        matches!(
            self.source,
            Source::ConnectionLost | Source::LocalConnectionLost
        )
    }

    pub(crate) fn is_clean_close(self) -> bool {
        self.scope == ErrorScope::Connection && self.code() == Code::H3_NO_ERROR
    }

    pub(crate) fn from_transport(error: &QuicConnectionError) -> Self {
        let mapped = match error {
            QuicConnectionError::ApplicationClosed(close) => Self::connection(
                Code::new(close.error_code.into_inner()),
                "peer closed HTTP/3 connection",
            ),
            // RFC 9000 section 20.1: transport NO_ERROR is a graceful close,
            // just like HTTP/3's application-level H3_NO_ERROR.
            QuicConnectionError::ConnectionClosed(close)
                if close.error_code == TransportErrorCode::NO_ERROR =>
            {
                Self::connection(Code::H3_NO_ERROR, "peer closed QUIC connection")
            }
            QuicConnectionError::LocallyClosed => {
                Self::connection(Code::H3_NO_ERROR, "local connection closed")
            }
            // HTTP/3 defines no timeout application code. Retain a terminal
            // local error, with an explicit transport cause rather than claiming
            // the peer violated HTTP/3. This code was not received from the peer.
            QuicConnectionError::TimedOut => {
                Self::connection(Code::H3_GENERAL_PROTOCOL_ERROR, "QUIC connection timed out")
            }
            _ => Self::connection(Code::H3_GENERAL_PROTOCOL_ERROR, "QUIC connection failed"),
        };
        // No wildcard: each new cause must say whether this side lost the connection.
        let source = match error {
            QuicConnectionError::LocallyClosed
            | QuicConnectionError::CidsExhausted
            | QuicConnectionError::EndpointInUse => Source::LocalConnectionLost,
            QuicConnectionError::VersionMismatch { .. }
            | QuicConnectionError::TransportError(_)
            | QuicConnectionError::ConnectionClosed(_)
            | QuicConnectionError::ApplicationClosed(_)
            | QuicConnectionError::Reset
            | QuicConnectionError::TimedOut => Source::ConnectionLost,
        };
        Self { source, ..mapped }
    }

    /// Attribute a locally detected error to received peer data, keeping a more
    /// specific transport origin.
    pub(crate) const fn remote(mut self) -> Self {
        if matches!(self.source, Source::Local) {
            self.source = Source::Remote;
        }
        self
    }

    /// Convert closure into an incomplete message while preserving who closed it.
    /// A graceful peer close is neutral by itself, but not when it truncates a
    /// response; application-initiated shutdown must remain locally attributed.
    pub(crate) const fn incomplete(self, reason: &'static str) -> Self {
        Self {
            code: Code::H3_REQUEST_INCOMPLETE,
            scope: ErrorScope::Stream,
            reason,
            source: self.source,
        }
    }

    /// Whether received protocol data or a transport failure caused this error.
    ///
    /// Local application failures and graceful connection closure are excluded.
    /// This classification does not grant permission to retry a request.
    #[must_use]
    pub fn is_remote_failure(self) -> bool {
        !(matches!(
            self.source,
            Source::Local | Source::LocalConnectionLost | Source::EarlyDataRejected
        ) || self.is_clean_close()
            || (self.scope == ErrorScope::Stream
                && matches!(self.code(), Code::H3_REQUEST_REJECTED | Code::H3_NO_ERROR)))
    }

    /// The effective HTTP/3 application error code.
    ///
    /// Unknown and reserved wire values are equivalent to `H3_NO_ERROR`
    /// (RFC 9114 section 8). [`Self::raw_code`] retains their diagnostic value.
    ///
    /// Transport failures use a local classification when no application code
    /// was received; a closed transport cannot deliver it to the peer.
    #[must_use]
    pub const fn code(self) -> Code {
        if self.code.name().is_some() {
            self.code
        } else {
            Code::H3_NO_ERROR
        }
    }

    /// The original application code, including unknown and reserved values.
    #[must_use]
    pub const fn raw_code(self) -> Code {
        self.code
    }

    /// Whether the connection or the affected stream must be terminated.
    #[must_use]
    pub const fn scope(self) -> ErrorScope {
        self.scope
    }

    /// Whether the peer explicitly rejected this request without processing it.
    #[must_use]
    pub fn is_rejected(self) -> bool {
        self.scope == ErrorScope::Stream && self.code == Code::H3_REQUEST_REJECTED
    }

    /// Map a terminal compression error, preserving local output backpressure as `None`.
    #[must_use]
    pub fn from_qpack(error: QpackError) -> Option<Self> {
        Some(Self {
            code: error.code()?,
            scope: error.scope()?,
            reason: error.reason(),
            source: Source::Local,
        })
    }

    /// Map a frame error; rejected local input is backpressure, not a peer error.
    #[must_use]
    pub fn from_frame(error: &FrameError) -> Option<Self> {
        let (code, reason) = match error {
            FrameError::InputBufferFull => return None,
            FrameError::UnexpectedH2Frame(_) => {
                (Code::H3_FRAME_UNEXPECTED, "HTTP/2 frame on H3 stream")
            }
            FrameError::FrameTooLarge { .. } | FrameError::TooManySettings => {
                (Code::H3_EXCESSIVE_LOAD, "frame exceeds local budget")
            }
            FrameError::Malformed(_) => (Code::H3_FRAME_ERROR, "malformed frame"),
            FrameError::Settings(_) => (Code::H3_SETTINGS_ERROR, "invalid settings"),
        };
        Some(Self::connection(code, reason))
    }
}

impl std::fmt::Display for Error {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{} ({}, {:?})", self.reason, self.code, self.scope)
    }
}

impl std::error::Error for Error {}

#[cfg(test)]
mod tests {
    use super::*;
    use rama_quic_proto::{
        VarInt,
        frame::{ApplicationClose, ConnectionClose},
    };

    #[test]
    fn incomplete_messages_preserve_peer_or_local_close_provenance() {
        let local = Error::from_transport(&QuicConnectionError::LocallyClosed);
        assert!(!local.incomplete("missing FIN").is_remote_failure());
        for code in [Code::H3_NO_ERROR, Code::new(0x21), Code::new(0xdead)] {
            let peer =
                Error::from_transport(&QuicConnectionError::ApplicationClosed(ApplicationClose {
                    error_code: VarInt::from_u64(code.value()).unwrap(),
                    reason: Default::default(),
                }));
            assert!(!peer.is_remote_failure());
            assert!(peer.incomplete("missing FIN").is_remote_failure());
            assert_eq!(
                peer.incomplete("missing FIN").code(),
                Code::H3_REQUEST_INCOMPLETE
            );
        }
    }

    #[test]
    fn unknown_codes_preserve_diagnostics_without_inventing_failure_semantics() {
        for value in [0, 0x21, 0x40, 0xdead] {
            let error = Error::connection(Code::new(value), "peer close").remote();
            assert!(error.is_clean_close());
            assert!(!error.is_remote_failure());
            assert_eq!(error.code(), Code::H3_NO_ERROR);
            assert_eq!(error.raw_code().value(), value);
        }
    }

    #[test]
    fn request_rejection_requires_stream_scope() {
        assert!(Error::stream(Code::H3_REQUEST_REJECTED, "rejected").is_rejected());
        assert!(!Error::connection(Code::H3_REQUEST_REJECTED, "peer close").is_rejected());
    }

    #[test]
    fn remote_failure_provenance_does_not_classify_local_application_errors() {
        assert!(
            !Error::stream(Code::H3_MESSAGE_ERROR, "invalid application request")
                .is_remote_failure()
        );
        assert!(
            !Error::stream(Code::H3_INTERNAL_ERROR, "application body failed").is_remote_failure()
        );
        assert!(!Error::from_transport(&QuicConnectionError::LocallyClosed).is_remote_failure());
        assert!(!Error::from_transport(&QuicConnectionError::CidsExhausted).is_remote_failure());
        assert!(!Error::from_transport(&QuicConnectionError::EndpointInUse).is_remote_failure());
        assert!(Error::peer_stopped(Code::H3_REQUEST_CANCELLED).is_remote_failure());
        assert!(Error::from_transport(&QuicConnectionError::Reset).is_remote_failure());
        assert!(
            Error::stream(Code::H3_FRAME_ERROR, "malformed peer frame")
                .remote()
                .is_remote_failure()
        );
    }

    #[test]
    fn peer_rejection_is_not_an_endpoint_failure() {
        for code in [Code::H3_REQUEST_REJECTED, Code::H3_NO_ERROR] {
            assert!(
                !Error::stream(code, "peer reset")
                    .remote()
                    .is_remote_failure()
            );
            assert!(!Error::peer_stopped(code).is_remote_failure());
        }
        assert!(
            Error::connection(Code::H3_REQUEST_REJECTED, "peer close")
                .remote()
                .is_remote_failure()
        );
    }

    #[test]
    fn transport_close_distinguishes_success_from_transport_failure() {
        for (code, clean) in [
            (TransportErrorCode::NO_ERROR, true),
            (TransportErrorCode::INTERNAL_ERROR, false),
        ] {
            let error =
                Error::from_transport(&QuicConnectionError::ConnectionClosed(ConnectionClose {
                    error_code: code,
                    frame_type: None,
                    reason: Default::default(),
                }));
            assert_eq!(error.is_clean_close(), clean);
            assert_eq!(error.is_remote_failure(), !clean);
            assert!(error.incomplete("missing FIN").is_remote_failure());
        }
    }

    #[test]
    fn transport_timeout_remains_terminal_with_specific_cause() {
        let error = Error::from_transport(&QuicConnectionError::TimedOut);
        assert!(!error.is_clean_close());
        assert_eq!(error.scope(), ErrorScope::Connection);
        assert!(error.to_string().contains("timed out"));
    }
}
