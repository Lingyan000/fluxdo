//! HTTP/3 and QPACK error codes (RFC 9114 §8.1, RFC 9204 §6).

use std::fmt;

/// An HTTP/3 or QPACK error code, as carried by `RESET_STREAM`, `STOP_SENDING`, `GOAWAY` and the
/// QUIC `CONNECTION_CLOSE` application-error space (RFC 9114 §8.1, RFC 9204 §6).
///
/// Unknown and reserved values are preserved rather than rejected: an endpoint treats an
/// unrecognized code the same as [`Code::H3_NO_ERROR`] (RFC 9114 §8.1), and reserved
/// (`0x1f * N + 0x21`) codes exist only so that endpoints do not ossify around a fixed set.
#[derive(Clone, Copy, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub struct Code(u64);

impl Code {
    /// Construct a code from its raw value.
    #[must_use]
    pub const fn new(value: u64) -> Self {
        Self(value)
    }

    /// The raw code value.
    #[must_use]
    pub const fn value(self) -> u64 {
        self.0
    }

    /// Whether this is a reserved code of the form `0x1f * N + 0x21` (RFC 9114 §8.1).
    ///
    /// These are used to exercise requirements that unknown codes be handled gracefully; they have
    /// no other semantics.
    #[must_use]
    pub const fn is_reserved(self) -> bool {
        // 0x1f * N + 0x21  <=>  (code - 0x21) % 0x1f == 0, for code >= 0x21
        self.0 >= 0x21 && (self.0 - 0x21).is_multiple_of(0x1f)
    }

    /// A human-readable name for a known code, if any.
    #[must_use]
    pub const fn name(self) -> Option<&'static str> {
        Some(match self {
            Self::H3_NO_ERROR => "H3_NO_ERROR",
            Self::H3_GENERAL_PROTOCOL_ERROR => "H3_GENERAL_PROTOCOL_ERROR",
            Self::H3_INTERNAL_ERROR => "H3_INTERNAL_ERROR",
            Self::H3_STREAM_CREATION_ERROR => "H3_STREAM_CREATION_ERROR",
            Self::H3_CLOSED_CRITICAL_STREAM => "H3_CLOSED_CRITICAL_STREAM",
            Self::H3_FRAME_UNEXPECTED => "H3_FRAME_UNEXPECTED",
            Self::H3_FRAME_ERROR => "H3_FRAME_ERROR",
            Self::H3_EXCESSIVE_LOAD => "H3_EXCESSIVE_LOAD",
            Self::H3_ID_ERROR => "H3_ID_ERROR",
            Self::H3_SETTINGS_ERROR => "H3_SETTINGS_ERROR",
            Self::H3_MISSING_SETTINGS => "H3_MISSING_SETTINGS",
            Self::H3_REQUEST_REJECTED => "H3_REQUEST_REJECTED",
            Self::H3_REQUEST_CANCELLED => "H3_REQUEST_CANCELLED",
            Self::H3_REQUEST_INCOMPLETE => "H3_REQUEST_INCOMPLETE",
            Self::H3_MESSAGE_ERROR => "H3_MESSAGE_ERROR",
            Self::H3_CONNECT_ERROR => "H3_CONNECT_ERROR",
            Self::H3_VERSION_FALLBACK => "H3_VERSION_FALLBACK",
            Self::H3_DATAGRAM_ERROR => "H3_DATAGRAM_ERROR",
            Self::QPACK_DECOMPRESSION_FAILED => "QPACK_DECOMPRESSION_FAILED",
            Self::QPACK_ENCODER_STREAM_ERROR => "QPACK_ENCODER_STREAM_ERROR",
            Self::QPACK_DECODER_STREAM_ERROR => "QPACK_DECODER_STREAM_ERROR",
            _ => return None,
        })
    }
}

macro_rules! codes {
    ($($(#[$m:meta])* $name:ident = $value:expr;)*) => {
        impl Code {
            $(
                $(#[$m])*
                pub const $name: Self = Self($value);
            )*
        }
    };
}

codes! {
    /// No error (RFC 9114 §8.1). Also used for any unrecognized error code.
    H3_NO_ERROR = 0x0100;
    /// Peer violated protocol requirements without a more specific code.
    H3_GENERAL_PROTOCOL_ERROR = 0x0101;
    /// Internal error.
    H3_INTERNAL_ERROR = 0x0102;
    /// A stream was created that could not be created.
    H3_STREAM_CREATION_ERROR = 0x0103;
    /// A required critical stream was closed.
    H3_CLOSED_CRITICAL_STREAM = 0x0104;
    /// A frame was received on a stream where it is not permitted.
    H3_FRAME_UNEXPECTED = 0x0105;
    /// A frame that fails to satisfy layout requirements.
    H3_FRAME_ERROR = 0x0106;
    /// An endpoint detected that its peer is creating excessive load.
    H3_EXCESSIVE_LOAD = 0x0107;
    /// A stream or push ID was used incorrectly.
    H3_ID_ERROR = 0x0108;
    /// An endpoint detected an error in the SETTINGS frame.
    H3_SETTINGS_ERROR = 0x0109;
    /// No SETTINGS frame was received at the beginning of the control stream.
    H3_MISSING_SETTINGS = 0x010a;
    /// A request was rejected without processing.
    H3_REQUEST_REJECTED = 0x010b;
    /// The request or its response is cancelled.
    H3_REQUEST_CANCELLED = 0x010c;
    /// The client's stream terminated without a complete request.
    H3_REQUEST_INCOMPLETE = 0x010d;
    /// An HTTP message was malformed and cannot be processed.
    H3_MESSAGE_ERROR = 0x010e;
    /// The TCP connection established for a CONNECT request was reset or abnormally closed.
    H3_CONNECT_ERROR = 0x010f;
    /// The requested operation cannot be served over HTTP/3; peer should retry over HTTP/1.1.
    H3_VERSION_FALLBACK = 0x0110;

    /// Datagram or Capsule Protocol parse error (RFC 9297 §5.2).
    H3_DATAGRAM_ERROR = 0x33;

    /// The decoder failed to interpret an encoded field section (RFC 9204 §6).
    QPACK_DECOMPRESSION_FAILED = 0x0200;
    /// Error on the encoder stream (RFC 9204 §6).
    QPACK_ENCODER_STREAM_ERROR = 0x0201;
    /// Error on the decoder stream (RFC 9204 §6).
    QPACK_DECODER_STREAM_ERROR = 0x0202;
}

impl From<u64> for Code {
    fn from(value: u64) -> Self {
        Self(value)
    }
}

impl From<Code> for u64 {
    fn from(code: Code) -> Self {
        code.0
    }
}

impl fmt::Debug for Code {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self.name() {
            Some(name) => write!(f, "Code::{name}"),
            None if self.is_reserved() => write!(f, "Code(0x{:x}, reserved)", self.0),
            None => write!(f, "Code(0x{:x})", self.0),
        }
    }
}

impl fmt::Display for Code {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self.name() {
            Some(name) => f.write_str(name),
            None => write!(f, "0x{:x}", self.0),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn known_codes_have_names() {
        assert_eq!(Code::H3_NO_ERROR.value(), 0x0100);
        assert_eq!(Code::QPACK_DECODER_STREAM_ERROR.value(), 0x0202);
        assert_eq!(Code::H3_SETTINGS_ERROR.name(), Some("H3_SETTINGS_ERROR"));
        assert_eq!(Code::new(0xdead).name(), None);
    }

    #[test]
    fn reserved_detection() {
        // 0x1f*0 + 0x21 = 0x21, 0x1f*1 + 0x21 = 0x40, ...
        assert!(Code::new(0x21).is_reserved());
        assert!(Code::new(0x40).is_reserved());
        assert!(Code::new(0x1f * 7 + 0x21).is_reserved());
        assert!(!Code::new(0x100).is_reserved());
        assert!(!Code::new(0).is_reserved());
    }

    #[test]
    fn round_trip_u64() {
        let c = Code::from(0x0107u64);
        assert_eq!(c, Code::H3_EXCESSIVE_LOAD);
        assert_eq!(u64::from(c), 0x0107);
    }
}
