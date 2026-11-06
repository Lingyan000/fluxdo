//! Connection lifetime events. Observation does not drive the transport state machine.

use std::{borrow::Cow, net::SocketAddr};

use crate::qlog::event::Initiator;
pub(in crate::proto::connection) use crate::qlog::event::lifecycle::ConnectionState;
use crate::qlog::event::lifecycle::{
    ConnectionClosedTrigger, ConnectionClosedView as ConnectionClosed, LifecycleEventView as Event,
    ReasonView, TransportErrorName, TupleEndpointInfo,
};
use rama_quic_proto::{ConnectionId, frame::Close};

use crate::proto::{
    Instant,
    connection::{Connection, ConnectionError, State},
};

impl TupleEndpointInfo {
    fn new(address: Option<SocketAddr>, cid: ConnectionId) -> Self {
        let (ip_v4, port_v4, ip_v6, port_v6) = match address {
            Some(SocketAddr::V4(address)) => {
                (Some(*address.ip()), Some(address.port()), None, None)
            }
            Some(SocketAddr::V6(address)) => {
                (None, None, Some(*address.ip()), Some(address.port()))
            }
            None => (None, None, None, None),
        };
        Self {
            ip_v4,
            port_v4,
            ip_v6,
            port_v6,
            connection_ids: [cid],
        }
    }
}

impl<'a> ConnectionClosed<'a> {
    fn transport(initiator: Initiator, code: u64, reason: ReasonView<'a>) -> Self {
        let (connection_error, error_code) = transport_error(code);
        Self {
            initiator: Some(initiator),
            trigger: Some(if code == 0 {
                ConnectionClosedTrigger::Unspecified
            } else {
                ConnectionClosedTrigger::Error
            }),
            connection_error: Some(connection_error),
            error_code,
            reason: Some(reason),
            ..Self::default()
        }
    }

    fn close(initiator: Initiator, reason: &'a Close) -> Self {
        match reason {
            Close::Connection(close) => Self::transport(
                initiator,
                close.error_code.into(),
                ReasonView::Bytes(Cow::Borrowed(&close.reason)),
            ),
            Close::Application(close) => Self {
                initiator: Some(initiator),
                trigger: Some(ConnectionClosedTrigger::Application),
                application_error: Some("unknown"),
                error_code: Some(close.error_code.into()),
                reason: Some(ReasonView::Bytes(Cow::Borrowed(&close.reason))),
                ..Self::default()
            },
        }
    }

    fn internal(
        initiator: Initiator,
        trigger: ConnectionClosedTrigger,
        reason: &'static str,
    ) -> Self {
        Self {
            initiator: Some(initiator),
            trigger: Some(trigger),
            reason: Some(ReasonView::Static(reason)),
            ..Self::default()
        }
    }

    fn error(error: &'a ConnectionError) -> Self {
        match error {
            ConnectionError::TransportError(error) => Self::transport(
                Initiator::Local,
                error.code.into(),
                ReasonView::Text(&error.reason),
            ),
            ConnectionError::ConnectionClosed(close) => Self::transport(
                Initiator::Remote,
                close.error_code.into(),
                ReasonView::Bytes(Cow::Borrowed(&close.reason)),
            ),
            ConnectionError::ApplicationClosed(close) => Self {
                initiator: Some(Initiator::Remote),
                trigger: Some(ConnectionClosedTrigger::Application),
                application_error: Some("unknown"),
                error_code: Some(close.error_code.into()),
                reason: Some(ReasonView::Bytes(Cow::Borrowed(&close.reason))),
                ..Self::default()
            },
            ConnectionError::VersionMismatch { .. } => Self::internal(
                Initiator::Local,
                ConnectionClosedTrigger::VersionMismatch,
                "peer doesn't implement any supported version",
            ),
            ConnectionError::Reset => Self::internal(
                Initiator::Remote,
                ConnectionClosedTrigger::StatelessReset,
                "reset by peer",
            ),
            ConnectionError::TimedOut => Self::internal(
                Initiator::Local,
                ConnectionClosedTrigger::IdleTimeout,
                "timed out",
            ),
            ConnectionError::LocallyClosed => Self::internal(
                Initiator::Local,
                ConnectionClosedTrigger::Application,
                "closed",
            ),
            ConnectionError::CidsExhausted => Self::internal(
                Initiator::Local,
                ConnectionClosedTrigger::Error,
                "CIDs exhausted",
            ),
            ConnectionError::EndpointInUse => Self::internal(
                Initiator::Local,
                ConnectionClosedTrigger::Error,
                "endpoint in use",
            ),
        }
    }
}

fn transport_error(code: u64) -> (TransportErrorName, Option<u64>) {
    use TransportErrorName as Name;
    let name = match code {
        0x00 => Name::NoError,
        0x01 => Name::InternalError,
        0x02 => Name::ConnectionRefused,
        0x03 => Name::FlowControlError,
        0x04 => Name::StreamLimitError,
        0x05 => Name::StreamStateError,
        0x06 => Name::FinalSizeError,
        0x07 => Name::FrameEncodingError,
        0x08 => Name::TransportParameterError,
        0x09 => Name::ConnectionIdLimitError,
        0x0a => Name::ProtocolViolation,
        0x0b => Name::InvalidToken,
        0x0c => Name::ApplicationError,
        0x0d => Name::CryptoBufferExceeded,
        0x0e => Name::KeyUpdateError,
        0x0f => Name::AeadLimitReached,
        0x10 => Name::NoViablePath,
        0x100..=0x1ff => Name::Crypto((code - 0x100) as u8),
        _ => return (Name::Unknown, Some(code)),
    };
    (name, None)
}

impl Connection {
    pub(in crate::proto::connection) fn qlog_connection_started(&mut self, now: Instant) {
        self.qlog_sink.emit(self.trace_cid, now, || Event::Started {
            local: TupleEndpointInfo::new(self.path.local, self.handshake_cid),
            remote: TupleEndpointInfo::new(Some(self.path.remote), self.rem_handshake_cid),
        });
        self.qlog_state_updated(now, ConnectionState::Attempted);
    }

    fn qlog_state_updated(&mut self, now: Instant, new: ConnectionState) {
        if !self.qlog_sink.is_enabled() || self.qlog_state == Some(new) {
            return;
        }
        let old = self.qlog_state;
        if self
            .qlog_sink
            .emit(self.trace_cid, now, || Event::StateUpdated { old, new })
        {
            self.qlog_state = Some(new);
        }
    }

    pub(in crate::proto::connection) fn qlog_handshake_started(&mut self, now: Instant) {
        if matches!(self.qlog_state, None | Some(ConnectionState::Attempted)) {
            self.qlog_state_updated(now, ConnectionState::HandshakeStarted);
        }
    }

    pub(in crate::proto::connection) fn qlog_connection_error(
        &mut self,
        now: Instant,
        error: &ConnectionError,
    ) {
        if !self.qlog_sink.is_enabled() || self.qlog_closed {
            return;
        }
        self.qlog_closed = self.qlog_sink.emit(self.trace_cid, now, || {
            Event::Closed(ConnectionClosed::error(error))
        });
    }

    pub(in crate::proto::connection) fn qlog_local_close(&mut self, now: Instant, reason: &Close) {
        if !self.qlog_sink.is_enabled() || self.qlog_closed {
            return;
        }
        self.qlog_closed = self.qlog_sink.emit(self.trace_cid, now, || {
            Event::Closed(ConnectionClosed::close(Initiator::Local, reason))
        });
    }

    pub(in crate::proto::connection) fn qlog_handshake_timeout(&mut self, now: Instant) {
        if !self.qlog_sink.is_enabled() || self.qlog_closed {
            return;
        }
        self.qlog_closed = self.qlog_sink.emit(self.trace_cid, now, || {
            Event::Closed(ConnectionClosed {
                initiator: Some(Initiator::Local),
                trigger: Some(ConnectionClosedTrigger::Error),
                reason: Some(ReasonView::Static("handshake timeout")),
                ..ConnectionClosed::default()
            })
        });
    }

    pub(in crate::proto::connection) fn qlog_discarded(&mut self, now: Instant) {
        self.qlog_state_updated(now, ConnectionState::Closed);
    }

    /// Called at packet processing boundaries, before application polling can consume the error.
    pub(in crate::proto::connection) fn qlog_observe_state(&mut self, now: Instant) {
        if !self.qlog_sink.is_enabled() {
            return;
        }
        if !self.qlog_closed
            && let Some(error) = &self.error
        {
            self.qlog_closed = self.qlog_sink.emit(self.trace_cid, now, || {
                Event::Closed(ConnectionClosed::error(error))
            });
        }
        match self.state {
            State::Handshake(_) => {}
            State::Established => {
                if matches!(
                    self.qlog_state,
                    None | Some(ConnectionState::Attempted | ConnectionState::HandshakeStarted)
                ) {
                    self.qlog_state_updated(now, ConnectionState::HandshakeComplete);
                }
                if self.handshake_confirmed() {
                    self.qlog_state_updated(now, ConnectionState::HandshakeConfirmed);
                }
            }
            State::Closed(_) => self.qlog_state_updated(now, ConnectionState::Closing),
            State::Draining => self.qlog_state_updated(now, ConnectionState::Draining),
            State::Drained => self.qlog_discarded(now),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    use rama_core::bytes::Bytes;
    use rama_quic_proto::{TransportError, TransportErrorCode, VarInt, coding::Codec, frame};
    use serde_json::json;

    fn peer_close(code: TransportErrorCode) -> frame::ConnectionClose {
        frame::ConnectionClose {
            error_code: code,
            frame_type: None,
            reason: Bytes::from_static(b"closure reason"),
        }
    }

    #[test]
    fn transport_closes_serialize_standard_error_names() {
        // These are the QUIC error names in the serialized event contract, not Rust's
        // Display descriptions or Debug names. NO_ERROR does not imply an error trigger.
        for (code, name, trigger) in [
            (TransportErrorCode::NO_ERROR, "no_error", "unspecified"),
            (
                TransportErrorCode::INTERNAL_ERROR,
                "internal_error",
                "error",
            ),
            (
                TransportErrorCode::CONNECTION_REFUSED,
                "connection_refused",
                "error",
            ),
            (
                TransportErrorCode::FLOW_CONTROL_ERROR,
                "flow_control_error",
                "error",
            ),
            (
                TransportErrorCode::STREAM_LIMIT_ERROR,
                "stream_limit_error",
                "error",
            ),
            (
                TransportErrorCode::STREAM_STATE_ERROR,
                "stream_state_error",
                "error",
            ),
            (
                TransportErrorCode::FINAL_SIZE_ERROR,
                "final_size_error",
                "error",
            ),
            (
                TransportErrorCode::FRAME_ENCODING_ERROR,
                "frame_encoding_error",
                "error",
            ),
            (
                TransportErrorCode::TRANSPORT_PARAMETER_ERROR,
                "transport_parameter_error",
                "error",
            ),
            (
                TransportErrorCode::CONNECTION_ID_LIMIT_ERROR,
                "connection_id_limit_error",
                "error",
            ),
            (
                TransportErrorCode::PROTOCOL_VIOLATION,
                "protocol_violation",
                "error",
            ),
            (TransportErrorCode::INVALID_TOKEN, "invalid_token", "error"),
            (
                TransportErrorCode::APPLICATION_ERROR,
                "application_error",
                "error",
            ),
            (
                TransportErrorCode::CRYPTO_BUFFER_EXCEEDED,
                "crypto_buffer_exceeded",
                "error",
            ),
            (
                TransportErrorCode::KEY_UPDATE_ERROR,
                "key_update_error",
                "error",
            ),
            (
                TransportErrorCode::AEAD_LIMIT_REACHED,
                "aead_limit_reached",
                "error",
            ),
            (
                TransportErrorCode::NO_VIABLE_PATH,
                "no_viable_path",
                "error",
            ),
        ] {
            let local = Close::Connection(peer_close(code));
            let remote = ConnectionError::ConnectionClosed(peer_close(code));
            let internal =
                ConnectionError::TransportError(TransportError::new(code, "closure reason"));
            for (initiator, event) in [
                (
                    "local",
                    Event::Closed(ConnectionClosed::close(Initiator::Local, &local)),
                ),
                ("remote", Event::Closed(ConnectionClosed::error(&remote))),
                ("local", Event::Closed(ConnectionClosed::error(&internal))),
            ] {
                assert_eq!(
                    serde_json::to_value(event).unwrap(),
                    json!({
                        "name": "quic:connection_closed",
                        "data": {
                            "initiator": initiator,
                            "trigger": trigger,
                            "connection_error": name,
                            "reason": "closure reason"
                        }
                    }),
                    "transport code {code:?}, initiator {initiator}"
                );
            }
        }
    }

    #[test]
    fn unknown_transport_codes_remain_numeric() {
        // Exercise boundaries around assigned and TLS error ranges, plus the largest wire
        // code. A future/unknown error must retain its exact value, rather than a TLS name.
        for raw in [0x11, 0xff, 0x200, VarInt::MAX.into_inner()] {
            let mut encoded = Vec::new();
            VarInt::from_u64(raw).unwrap().encode(&mut encoded);
            let code = TransportErrorCode::decode(&mut encoded.as_slice()).unwrap();
            let local = Close::Connection(peer_close(code));
            let remote = ConnectionError::ConnectionClosed(peer_close(code));
            for (initiator, event) in [
                (
                    "local",
                    Event::Closed(ConnectionClosed::close(Initiator::Local, &local)),
                ),
                ("remote", Event::Closed(ConnectionClosed::error(&remote))),
            ] {
                assert_eq!(
                    serde_json::to_value(event).unwrap(),
                    json!({
                        "name": "quic:connection_closed",
                        "data": {
                            "initiator": initiator,
                            "trigger": "error",
                            "connection_error": "unknown",
                            "error_code": raw,
                            "reason": "closure reason"
                        }
                    })
                );
            }
        }
    }

    #[test]
    fn tls_alerts_serialize_as_zero_padded_crypto_error_names() {
        for (alert, name) in [
            (0x00, "crypto_error_0x100"),
            (0x0a, "crypto_error_0x10a"),
            (0x2a, "crypto_error_0x12a"),
            (0xff, "crypto_error_0x1ff"),
        ] {
            let error =
                ConnectionError::ConnectionClosed(peer_close(TransportErrorCode::crypto(alert)));
            assert_eq!(
                serde_json::to_value(Event::Closed(ConnectionClosed::error(&error))).unwrap(),
                json!({
                    "name": "quic:connection_closed",
                    "data": {
                        "initiator": "remote",
                        "trigger": "error",
                        "connection_error": name,
                        "reason": "closure reason"
                    }
                })
            );
        }
    }

    #[test]
    fn internal_close_causes_have_specific_triggers_without_fabricated_wire_codes() {
        for (error, initiator, trigger, reason) in [
            (
                ConnectionError::VersionMismatch { offered: vec![] },
                "local",
                "version_mismatch",
                "peer doesn't implement any supported version",
            ),
            (
                ConnectionError::LocallyClosed,
                "local",
                "application",
                "closed",
            ),
            (
                ConnectionError::Reset,
                "remote",
                "stateless_reset",
                "reset by peer",
            ),
            (
                ConnectionError::TimedOut,
                "local",
                "idle_timeout",
                "timed out",
            ),
            (
                ConnectionError::CidsExhausted,
                "local",
                "error",
                "CIDs exhausted",
            ),
            (
                ConnectionError::EndpointInUse,
                "local",
                "error",
                "endpoint in use",
            ),
        ] {
            assert_eq!(
                serde_json::to_value(Event::Closed(ConnectionClosed::error(&error))).unwrap(),
                json!({
                    "name": "quic:connection_closed",
                    "data": { "initiator": initiator, "trigger": trigger, "reason": reason }
                })
            );
        }
    }

    #[test]
    fn application_closes_preserve_large_codes_and_render_non_utf8_reasons_as_text() {
        let close = frame::ApplicationClose {
            error_code: VarInt::MAX,
            reason: Bytes::from_static(b"reason: \xff"),
        };
        let local = Close::Application(close.clone());
        let remote = ConnectionError::ApplicationClosed(close);
        for (initiator, event) in [
            (
                "local",
                Event::Closed(ConnectionClosed::close(Initiator::Local, &local)),
            ),
            ("remote", Event::Closed(ConnectionClosed::error(&remote))),
        ] {
            assert_eq!(
                serde_json::to_value(event).unwrap(),
                json!({
                    "name": "quic:connection_closed",
                    "data": {
                        "initiator": initiator,
                        "trigger": "application",
                        "application_error": "unknown",
                        "error_code": 4_611_686_018_427_387_903_u64,
                        "reason": "reason: \u{fffd}"
                    }
                })
            );
        }
    }
}
