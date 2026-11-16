//! HTTP/3 unidirectional stream types (RFC 9114 §6.2, RFC 9204 §4.2).

use std::fmt;

/// The type of an HTTP/3 unidirectional stream, sent as a variable-length integer at the start of
/// the stream (RFC 9114 §6.2).
///
/// Unknown stream types are preserved rather than rejected so that the abort/skip policy (RFC 9114
/// §6.2, where a recipient of an unknown stream type must not treat it as an error) can be applied
/// by the connection layer. Reserved (`0x1f * N + 0x21`) types are used for greasing.
#[derive(Clone, Copy, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub struct StreamType(u64);

impl StreamType {
    /// The control stream (RFC 9114 §6.2.1).
    pub const CONTROL: Self = Self(0x00);
    /// A push stream (RFC 9114 §6.2.2).
    pub const PUSH: Self = Self(0x01);
    /// The QPACK encoder stream (RFC 9204 §4.2).
    pub const QPACK_ENCODER: Self = Self(0x02);
    /// The QPACK decoder stream (RFC 9204 §4.2).
    pub const QPACK_DECODER: Self = Self(0x03);
    /// First stream type reserved for greasing (RFC 9114 §6.2).
    pub const FIRST_RESERVED: Self = Self(0x21);

    /// Construct a stream type from its raw value.
    #[must_use]
    pub const fn new(value: u64) -> Self {
        Self(value)
    }

    /// The raw stream-type value.
    #[must_use]
    pub const fn value(self) -> u64 {
        self.0
    }

    /// Whether this is a reserved type of the form `0x1f * N + 0x21` (RFC 9114 §6.2).
    #[must_use]
    pub const fn is_reserved(self) -> bool {
        self.0 >= Self::FIRST_RESERVED.0 && (self.0 - Self::FIRST_RESERVED.0).is_multiple_of(0x1f)
    }

    /// A human-readable name for a known stream type, if any.
    #[must_use]
    pub const fn name(self) -> Option<&'static str> {
        Some(match self {
            Self::CONTROL => "CONTROL",
            Self::PUSH => "PUSH",
            Self::QPACK_ENCODER => "QPACK_ENCODER",
            Self::QPACK_DECODER => "QPACK_DECODER",
            _ => return None,
        })
    }
}

impl From<u64> for StreamType {
    fn from(value: u64) -> Self {
        Self(value)
    }
}

impl From<StreamType> for u64 {
    fn from(ty: StreamType) -> Self {
        ty.0
    }
}

impl fmt::Debug for StreamType {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self.name() {
            Some(name) => write!(f, "StreamType::{name}"),
            None if self.is_reserved() => write!(f, "StreamType(0x{:x}, reserved)", self.0),
            None => write!(f, "StreamType(0x{:x})", self.0),
        }
    }
}

impl fmt::Display for StreamType {
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
    fn known_types() {
        assert_eq!(StreamType::CONTROL.value(), 0);
        assert_eq!(StreamType::QPACK_ENCODER.value(), 2);
        assert_eq!(StreamType::QPACK_DECODER.name(), Some("QPACK_DECODER"));
        assert_eq!(StreamType::new(0x99).name(), None);
    }

    #[test]
    fn reserved() {
        assert!(StreamType::new(0x21).is_reserved());
        assert!(StreamType::new(0x1f + 0x21).is_reserved());
        assert!(!StreamType::CONTROL.is_reserved());
    }
}
