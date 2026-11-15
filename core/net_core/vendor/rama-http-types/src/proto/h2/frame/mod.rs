use crate::proto::h2::hpack::DecoderError;
use rama_core::bytes::Bytes;
use std::fmt;

mod alt_svc;
mod data;
mod early_frame;
mod go_away;
mod head;
mod headers;
mod ping;
mod priority;
mod reason;
mod reset;
mod setting;
mod settings;
mod stream_id;
mod util;
mod window_update;

pub use self::alt_svc::AltSvc;
pub use self::data::Data;
pub use self::early_frame::{EarlyFrame, EarlyFrameCapture, EarlyFrameStreamContext};
pub use self::go_away::GoAway;
pub use self::head::{Head, Kind};
pub use self::headers::{
    Continuation, Headers, Pseudo, PushPromise, PushPromiseHeaderError, parse_u64,
};
pub use self::ping::Ping;
pub use self::priority::{Priority, StreamDependency};
pub use self::reason::Reason;
pub use self::reset::Reset;
pub use self::setting::{Setting, SettingId, SettingOrder, SettingsConfig};
pub use self::settings::{Settings, SettingsObservation};
pub use self::stream_id::{StreamId, StreamIdOverflow};
pub use self::window_update::WindowUpdate;

// Re-export some constants

pub use self::settings::{
    DEFAULT_INITIAL_WINDOW_SIZE, DEFAULT_MAX_FRAME_SIZE, DEFAULT_SETTINGS_HEADER_TABLE_SIZE,
    MAX_MAX_FRAME_SIZE,
};

pub type FrameSize = u32;

pub const HEADER_LEN: usize = 9;

#[derive(Eq, PartialEq)]
pub enum Frame<T = Bytes> {
    AltSvc(AltSvc),
    Data(Data<T>),
    Headers(Headers),
    Priority(Priority),
    PushPromise(PushPromise),
    Settings(Settings),
    Ping(Ping),
    GoAway(GoAway),
    WindowUpdate(WindowUpdate),
    Reset(Reset),
}

impl<T> Frame<T> {
    pub fn map<F, U>(self, f: F) -> Frame<U>
    where
        F: FnOnce(T) -> U,
    {
        match self {
            Self::AltSvc(frame) => frame.into(),
            Self::Data(frame) => frame.map(f).into(),
            Self::Headers(frame) => frame.into(),
            Self::Priority(frame) => frame.into(),
            Self::PushPromise(frame) => frame.into(),
            Self::Settings(frame) => frame.into(),
            Self::Ping(frame) => frame.into(),
            Self::GoAway(frame) => frame.into(),
            Self::WindowUpdate(frame) => frame.into(),
            Self::Reset(frame) => frame.into(),
        }
    }
}

impl<T> fmt::Debug for Frame<T> {
    fn fmt(&self, fmt: &mut fmt::Formatter) -> fmt::Result {
        match *self {
            Self::AltSvc(ref frame) => fmt::Debug::fmt(frame, fmt),
            Self::Data(ref frame) => fmt::Debug::fmt(frame, fmt),
            Self::Headers(ref frame) => fmt::Debug::fmt(frame, fmt),
            Self::Priority(ref frame) => fmt::Debug::fmt(frame, fmt),
            Self::PushPromise(ref frame) => fmt::Debug::fmt(frame, fmt),
            Self::Settings(ref frame) => fmt::Debug::fmt(frame, fmt),
            Self::Ping(ref frame) => fmt::Debug::fmt(frame, fmt),
            Self::GoAway(ref frame) => fmt::Debug::fmt(frame, fmt),
            Self::WindowUpdate(ref frame) => fmt::Debug::fmt(frame, fmt),
            Self::Reset(ref frame) => fmt::Debug::fmt(frame, fmt),
        }
    }
}

/// Errors that can occur during parsing an HTTP/2 frame.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Error {
    /// A length value other than 8 was set on a PING message.
    BadFrameSize,

    /// The padding length was larger than the frame-header-specified
    /// length of the payload.
    TooMuchPadding,

    /// An invalid setting value was provided
    InvalidSettingValue,

    /// A SETTINGS_INITIAL_WINDOW_SIZE value above 2^31-1 was received.
    ///
    /// RFC 9113 §6.5.2 specifies that this MUST be treated as a
    /// `FLOW_CONTROL_ERROR`, distinct from a generic `PROTOCOL_ERROR`.
    InvalidInitialWindowSize,

    /// An invalid window update value
    InvalidWindowUpdateValue,

    /// The payload length specified by the frame header was not the
    /// value necessary for the specific frame type.
    InvalidPayloadLength,

    /// Received a payload with an ACK settings frame
    InvalidPayloadAckSettings,

    /// An invalid stream identifier was provided.
    ///
    /// This is returned if a SETTINGS, PING or GOAWAY frame is received with a
    /// stream identifier other than zero.
    InvalidStreamId,

    /// A request or response is malformed.
    MalformedMessage,

    /// The decoded header list was too large to continue processing.
    HeaderListWayTooLarge,

    /// An invalid stream dependency ID was provided
    ///
    /// This is returned if a HEADERS or PRIORITY frame is received with an
    /// invalid stream identifier.
    InvalidDependencyId,

    /// Failed to perform HPACK decoding
    Hpack(DecoderError),

    /// The input buffer was too short to parse the requested frame piece.
    ///
    /// Returned by `Head::parse`, `StreamId::parse`, and `Setting::load`
    /// when their byte slice is shorter than the format mandates.
    ShortBuffer {
        /// Minimum number of bytes the parser needed.
        needed: usize,
        /// Number of bytes actually available.
        got: usize,
    },

    /// A raw stream id had the reserved most-significant bit set.
    ///
    /// RFC 9113 §5.1.1 reserves the high bit of the stream id and
    /// requires receivers to ignore it on the wire; senders MUST NOT
    /// set it. Returned by `StreamId::try_from(u32)`.
    ReservedStreamIdBit,
}

impl fmt::Display for Error {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::BadFrameSize => f.write_str("bad frame size"),
            Self::TooMuchPadding => f.write_str("padding longer than the frame payload"),
            Self::InvalidSettingValue => f.write_str("invalid setting value"),
            Self::InvalidInitialWindowSize => f.write_str("invalid initial window size"),
            Self::InvalidWindowUpdateValue => f.write_str("invalid window update value"),
            Self::InvalidPayloadLength => f.write_str("invalid frame payload length"),
            Self::InvalidPayloadAckSettings => f.write_str("unexpected payload on settings ack"),
            Self::InvalidStreamId => f.write_str("invalid stream identifier"),
            Self::MalformedMessage => f.write_str("malformed message"),
            Self::HeaderListWayTooLarge => f.write_str("header list way too large"),
            Self::InvalidDependencyId => f.write_str("invalid stream dependency identifier"),
            Self::Hpack(err) => write!(f, "hpack decoding failed: {err}"),
            Self::ShortBuffer { needed, got } => {
                write!(f, "short buffer: needed {needed} bytes, got {got}")
            }
            Self::ReservedStreamIdBit => f.write_str("reserved bit set on stream identifier"),
        }
    }
}

impl std::error::Error for Error {
    fn source(&self) -> Option<&(dyn std::error::Error + 'static)> {
        match self {
            Self::Hpack(err) => Some(err),
            _ => None,
        }
    }
}
