//! Connection lifetime event data.

use super::Initiator;
use rama_quic_proto::ConnectionId;
use rama_utils::str::utf8::{self, DecodeError, REPLACEMENT_CHARACTER};
use serde::{Serialize, Serializer};
use std::{
    borrow::Cow,
    fmt,
    net::{Ipv4Addr, Ipv6Addr},
};

/// Connection lifecycle state observed by the transport.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum ConnectionState {
    /// A connection attempt was created.
    Attempted,

    /// The cryptographic handshake began.
    HandshakeStarted,

    /// The local endpoint completed the cryptographic handshake.
    HandshakeComplete,

    /// The endpoint confirmed that its peer completed the handshake.
    HandshakeConfirmed,

    /// Local closure began; close responses may still be sent.
    Closing,

    /// Closure was received or acknowledged; outgoing packets have stopped.
    Draining,

    /// Connection termination completed.
    Closed,
}

/// Connection start, state transition, and closure observations.
#[derive(Clone, Debug, Serialize)]
#[serde(tag = "name", content = "data")]
pub enum LifecycleEventView<'a> {
    /// A connection began on the reported endpoints.
    #[serde(rename = "quic:connection_started")]
    Started {
        /// Local endpoint address and initial connection ID.
        local: TupleEndpointInfo,

        /// Remote endpoint address and initial connection ID.
        remote: TupleEndpointInfo,
    },

    /// The connection entered a new lifecycle state.
    #[serde(rename = "quic:connection_state_updated")]
    StateUpdated {
        /// Previous lifecycle state, when known.
        #[serde(skip_serializing_if = "Option::is_none")]
        old: Option<ConnectionState>,

        /// Newly entered lifecycle state.
        new: ConnectionState,
    },

    /// Connection closure and its diagnostic details.
    #[serde(rename = "quic:connection_closed")]
    Closed(ConnectionClosedView<'a>),
}

/// Lifecycle event with owned or static backing storage.
pub type LifecycleEvent = LifecycleEventView<'static>;

/// Known endpoint address and initial connection ID. Unknown addresses are omitted.
#[derive(Clone, Copy, Debug, Serialize)]
pub struct TupleEndpointInfo {
    /// IPv4 address, when known and applicable.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub ip_v4: Option<Ipv4Addr>,

    /// UDP port associated with the IPv4 address.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub port_v4: Option<u16>,

    /// IPv6 address, when known and applicable.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub ip_v6: Option<Ipv6Addr>,

    /// UDP port associated with the IPv6 address.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub port_v6: Option<u16>,

    /// Initial connection ID associated with this endpoint.
    #[serde(serialize_with = "super::serialize_cids")]
    pub connection_ids: [ConnectionId; 1],
}

/// QUIC transport error classification, formatted only when serialized.
#[derive(Clone, Copy, Debug)]
pub enum TransportErrorName {
    /// The connection closed without a transport error.
    NoError,

    /// An internal implementation error occurred.
    InternalError,

    /// The server refused the connection.
    ConnectionRefused,

    /// The peer exceeded connection or stream receive credit.
    FlowControlError,

    /// The peer exceeded the permitted stream count.
    StreamLimitError,

    /// A frame referenced a stream in an invalid state.
    StreamStateError,

    /// A stream’s final size was inconsistent with previously received data.
    FinalSizeError,

    /// A frame contained malformed or invalid fields.
    FrameEncodingError,

    /// Transport parameters were malformed, missing, or invalid.
    TransportParameterError,

    /// The peer supplied too many active connection IDs.
    ConnectionIdLimitError,

    /// The peer violated another QUIC protocol requirement.
    ProtocolViolation,

    /// An address-validation token was invalid.
    InvalidToken,

    /// The application requested closure during the handshake.
    ApplicationError,

    /// Buffered cryptographic handshake data exceeded implementation limits.
    CryptoBufferExceeded,

    /// A packet-protection key update violated protocol requirements.
    KeyUpdateError,

    /// Packet-protection usage reached its cryptographic safety limit.
    AeadLimitReached,

    /// No usable network path remained.
    NoViablePath,

    /// TLS alert byte, encoded as a QUIC cryptographic error.
    Crypto(u8),

    /// The transport error code has no recognized classification.
    Unknown,
}

impl fmt::Display for TransportErrorName {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(match self {
            Self::NoError => "no_error",
            Self::InternalError => "internal_error",
            Self::ConnectionRefused => "connection_refused",
            Self::FlowControlError => "flow_control_error",
            Self::StreamLimitError => "stream_limit_error",
            Self::StreamStateError => "stream_state_error",
            Self::FinalSizeError => "final_size_error",
            Self::FrameEncodingError => "frame_encoding_error",
            Self::TransportParameterError => "transport_parameter_error",
            Self::ConnectionIdLimitError => "connection_id_limit_error",
            Self::ProtocolViolation => "protocol_violation",
            Self::InvalidToken => "invalid_token",
            Self::ApplicationError => "application_error",
            Self::CryptoBufferExceeded => "crypto_buffer_exceeded",
            Self::KeyUpdateError => "key_update_error",
            Self::AeadLimitReached => "aead_limit_reached",
            Self::NoViablePath => "no_viable_path",
            Self::Crypto(alert) => {
                return write!(f, "crypto_error_0x{:03x}", 0x100 + u16::from(*alert));
            }
            Self::Unknown => "unknown",
        })
    }
}

impl Serialize for TransportErrorName {
    fn serialize<S: Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
        serializer.collect_str(self)
    }
}

/// A diagnostic reason in its original text or wire-byte representation.
/// Invalid UTF-8 is replaced only during serialization, without allocating rendered text.
#[derive(Clone, Debug)]
pub enum ReasonView<'a> {
    /// Static text retained without allocation.
    Static(&'static str),

    /// UTF-8 text borrowed from the observation source.
    Text(&'a str),

    /// Independently owned UTF-8 text.
    Owned(Box<str>),

    /// Original wire bytes; invalid UTF-8 becomes replacement characters during serialization.
    Bytes(Cow<'a, [u8]>),
}

/// Diagnostic reason with owned or static backing storage.
pub type Reason = ReasonView<'static>;

impl ReasonView<'_> {
    /// Retain this reason, copying borrowed storage and moving existing owned storage.
    pub fn into_owned(self) -> Reason {
        match self {
            Self::Static(value) => ReasonView::Static(value),
            Self::Text(value) => ReasonView::Owned(value.into()),
            Self::Owned(value) => ReasonView::Owned(value),
            Self::Bytes(value) => ReasonView::Bytes(Cow::Owned(value.into_owned())),
        }
    }

    /// Conservative heap bytes needed when retaining this value, including existing spare capacity.
    pub fn owned_heap_size(&self) -> usize {
        match self {
            Self::Text(value) => value.len(),
            Self::Bytes(Cow::Borrowed(value)) => value.len(),
            Self::Static(_) | Self::Owned(_) | Self::Bytes(Cow::Owned(_)) => self.heap_size(),
        }
    }

    /// Retained heap bytes, including spare capacity; excludes borrowed data and allocator metadata.
    pub fn heap_size(&self) -> usize {
        match self {
            Self::Owned(value) => value.len(),
            Self::Bytes(Cow::Owned(value)) => value.capacity(),
            Self::Static(_) | Self::Text(_) | Self::Bytes(Cow::Borrowed(_)) => 0,
        }
    }
}

impl Serialize for ReasonView<'_> {
    #[expect(
        clippy::match_same_arms,
        reason = "static and borrowed text bindings have different lifetimes and cannot share an or-pattern"
    )]
    fn serialize<S: Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
        match self {
            Self::Static(value) => serializer.serialize_str(value),
            Self::Text(value) => serializer.serialize_str(value),
            Self::Owned(value) => serializer.serialize_str(value),
            Self::Bytes(value) => serializer.collect_str(&LossyUtf8(value)),
        }
    }
}

struct LossyUtf8<'a>(&'a [u8]);

impl fmt::Display for LossyUtf8<'_> {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        let mut remaining = self.0;
        loop {
            match utf8::decode(remaining) {
                Ok(valid) => return f.write_str(valid),
                Err(DecodeError::Invalid {
                    valid_prefix,
                    remaining_input,
                    ..
                }) => {
                    f.write_str(valid_prefix)?;
                    f.write_str(REPLACEMENT_CHARACTER)?;
                    remaining = remaining_input;
                }
                Err(DecodeError::Incomplete { valid_prefix, .. }) => {
                    f.write_str(valid_prefix)?;
                    return f.write_str(REPLACEMENT_CHARACTER);
                }
            }
        }
    }
}

/// Cause of connection closure.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum ConnectionClosedTrigger {
    /// The idle timeout expired.
    IdleTimeout,

    /// The application requested closure.
    Application,

    /// An error caused closure.
    Error,

    /// The peers share no supported version.
    VersionMismatch,

    /// The peer sent a stateless reset.
    StatelessReset,

    /// The connection was aborted.
    Aborted,

    /// The closure cause could not be determined.
    Unspecified,
}

/// Connection closure classification, wire error code, and borrowed diagnostic reason.
#[derive(Default, Clone, Debug, Serialize)]
pub struct ConnectionClosedView<'a> {
    /// Endpoint initiating closure: local or remote.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub initiator: Option<Initiator>,

    /// Qlog closure cause, such as application, error, or timeout.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub trigger: Option<ConnectionClosedTrigger>,

    /// Named transport error classification, when applicable.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub connection_error: Option<TransportErrorName>,

    /// Application error classification, or unknown when only its numeric code is available.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub application_error: Option<&'static str>,

    /// Numeric wire error code when the named classification is insufficient.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub error_code: Option<u64>,

    /// Diagnostic text supplied by the implementation or peer.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub reason: Option<ReasonView<'a>>,
}

/// Connection closure details with owned or static backing storage.
pub type ConnectionClosed = ConnectionClosedView<'static>;

impl LifecycleEventView<'_> {
    /// Retain this event, copying borrowed storage and moving existing owned storage.
    pub fn into_owned(self) -> LifecycleEvent {
        match self {
            Self::Started { local, remote } => LifecycleEventView::Started { local, remote },
            Self::StateUpdated { old, new } => LifecycleEventView::StateUpdated { old, new },
            Self::Closed(value) => LifecycleEventView::Closed(ConnectionClosedView {
                initiator: value.initiator,
                trigger: value.trigger,
                connection_error: value.connection_error,
                application_error: value.application_error,
                error_code: value.error_code,
                reason: value.reason.map(ReasonView::into_owned),
            }),
        }
    }

    /// Conservative heap bytes needed when retaining this value, including existing spare capacity.
    pub fn owned_heap_size(&self) -> usize {
        match self {
            Self::Closed(value) => value.reason.as_ref().map_or(0, ReasonView::owned_heap_size),
            Self::Started { .. } | Self::StateUpdated { .. } => 0,
        }
    }

    /// Retained heap bytes, including spare capacity; excludes borrowed data and allocator metadata.
    pub fn heap_size(&self) -> usize {
        match self {
            Self::Closed(value) => value.reason.as_ref().map_or(0, ReasonView::heap_size),
            Self::Started { .. } | Self::StateUpdated { .. } => 0,
        }
    }
}
