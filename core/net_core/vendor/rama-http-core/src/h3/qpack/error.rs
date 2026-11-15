//! QPACK protocol errors, implementation limits, and local output backpressure.

use rama_http_types::proto::h3::Code;
use rama_http_types::proto::h3::qpack::PrefixError;
use rama_http_types::proto::h3::qpack::field::InvalidPrefix;

/// Scope of a terminal HTTP/3 error.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum ErrorScope {
    /// Reset the affected request/push stream.
    Stream,
    /// Close the connection.
    Connection,
}

/// A QPACK error with its RFC 9204 §§6/7.4 wire code and scope, or retryable local backpressure.
///
/// The `&'static str` reason is a fixed diagnostic label, not a formatted string, so no allocation
/// happens on the error path.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum QpackError {
    /// Local output backpressure: drain queued instructions and retry without changing the input.
    OutputBlocked,
    /// An individual integer or string exceeds decoding limits (RFC 9204 §7.4).
    /// Reset this stream with QPACK_DECOMPRESSION_FAILED; compression state remains usable.
    FieldSectionLimit(&'static str),
    /// A field section exceeds the local aggregate size or blocked-storage budget.
    /// Reset only its stream with H3_EXCESSIVE_LOAD (RFC 9114 §§4.2.2/8).
    StreamResourceLimit(&'static str),
    /// An outgoing section exceeds the peer's or local field-section limit.
    /// Reject only this message; no compression state was changed (RFC 9114 §4.2.2).
    EncodeFieldSectionLimit(&'static str),
    /// A configured local resource budget was exceeded.
    ResourceLimit(&'static str),
    /// `QPACK_DECOMPRESSION_FAILED` (0x0200): a field section could not be decoded.
    DecompressionFailed(&'static str),
    /// `QPACK_ENCODER_STREAM_ERROR` (0x0201): the peer's encoder stream was invalid.
    EncoderStreamError(&'static str),
    /// `QPACK_DECODER_STREAM_ERROR` (0x0202): the peer's decoder stream was invalid.
    DecoderStreamError(&'static str),
}

impl QpackError {
    /// The wire error code; local output backpressure has no wire error.
    #[must_use]
    pub const fn code(self) -> Option<Code> {
        Some(match self {
            Self::OutputBlocked => return None,
            Self::ResourceLimit(_) | Self::StreamResourceLimit(_) => Code::H3_EXCESSIVE_LOAD,
            Self::EncodeFieldSectionLimit(_) => Code::H3_MESSAGE_ERROR,
            Self::FieldSectionLimit(_) | Self::DecompressionFailed(_) => {
                Code::QPACK_DECOMPRESSION_FAILED
            }
            Self::EncoderStreamError(_) => Code::QPACK_ENCODER_STREAM_ERROR,
            Self::DecoderStreamError(_) => Code::QPACK_DECODER_STREAM_ERROR,
        })
    }

    /// Whether to terminate a stream or connection. `None` means drain output and retry.
    #[must_use]
    pub const fn scope(self) -> Option<ErrorScope> {
        match self {
            Self::OutputBlocked => None,
            Self::FieldSectionLimit(_)
            | Self::EncodeFieldSectionLimit(_)
            | Self::StreamResourceLimit(_) => Some(ErrorScope::Stream),
            _ => Some(ErrorScope::Connection),
        }
    }

    /// The fixed diagnostic reason.
    #[must_use]
    pub const fn reason(self) -> &'static str {
        match self {
            Self::OutputBlocked => "QPACK output queue full",
            Self::ResourceLimit(r)
            | Self::StreamResourceLimit(r)
            | Self::FieldSectionLimit(r)
            | Self::EncodeFieldSectionLimit(r)
            | Self::DecompressionFailed(r)
            | Self::EncoderStreamError(r)
            | Self::DecoderStreamError(r) => r,
        }
    }
}

impl core::fmt::Display for QpackError {
    fn fmt(&self, f: &mut core::fmt::Formatter<'_>) -> core::fmt::Result {
        match self.code() {
            Some(code) => write!(f, "{} ({code})", self.reason()),
            None => f.write_str(self.reason()),
        }
    }
}

impl std::error::Error for QpackError {}

impl From<PrefixError> for QpackError {
    fn from(e: PrefixError) -> Self {
        match e {
            PrefixError::LengthLimitExceeded | PrefixError::IntegerOverflow => {
                Self::FieldSectionLimit("field-section value exceeds implementation limit")
            }
            PrefixError::UnexpectedEnd => Self::DecompressionFailed("truncated field section"),
            PrefixError::InvalidHuffman => Self::DecompressionFailed("malformed field section"),
        }
    }
}

impl From<InvalidPrefix> for QpackError {
    fn from(e: InvalidPrefix) -> Self {
        match e {
            InvalidPrefix::IntegerOverflow => {
                Self::FieldSectionLimit("field-section prefix exceeds implementation limit")
            }
            InvalidPrefix::NeedMore => Self::DecompressionFailed("truncated field section prefix"),
            _ => Self::DecompressionFailed("invalid field section prefix"),
        }
    }
}
