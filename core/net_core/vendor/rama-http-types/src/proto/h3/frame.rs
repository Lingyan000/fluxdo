//! HTTP/3 frame types and frame headers (RFC 9114 §7.2).

use std::fmt;

use rama_core::bytes::BufMut;
use rama_quic_proto::{VarInt, coding::Codec};

/// The type of an HTTP/3 frame, sent as a variable-length integer (RFC 9114 §7.2).
///
/// Unknown frame types are preserved: a recipient of an unknown frame type on a stream that allows
/// it "MUST ignore" the frame (RFC 9114 §9). The frame types that HTTP/2 assigned but HTTP/3 does
/// not reuse are recognized separately via [`FrameType::is_h2_reserved`] because receiving them is a
/// connection error of type `H3_FRAME_UNEXPECTED` (RFC 9114 §7.2.8).
#[derive(Clone, Copy, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub struct FrameType(u64);

impl FrameType {
    /// `DATA` (RFC 9114 §7.2.1).
    pub const DATA: Self = Self(0x00);
    /// `HEADERS` (RFC 9114 §7.2.2).
    pub const HEADERS: Self = Self(0x01);
    /// `CANCEL_PUSH` (RFC 9114 §7.2.3).
    pub const CANCEL_PUSH: Self = Self(0x03);
    /// `SETTINGS` (RFC 9114 §7.2.4).
    pub const SETTINGS: Self = Self(0x04);
    /// `PUSH_PROMISE` (RFC 9114 §7.2.5).
    pub const PUSH_PROMISE: Self = Self(0x05);
    /// `GOAWAY` (RFC 9114 §7.2.6).
    pub const GOAWAY: Self = Self(0x07);
    /// `MAX_PUSH_ID` (RFC 9114 §7.2.7).
    pub const MAX_PUSH_ID: Self = Self(0x0d);

    /// Request PRIORITY_UPDATE (RFC 9218 §7.2).
    pub const PRIORITY_UPDATE_REQUEST: Self = Self(0xf0700);
    /// Push PRIORITY_UPDATE (RFC 9218 §7.2).
    pub const PRIORITY_UPDATE_PUSH: Self = Self(0xf0701);
    /// First frame type reserved for greasing (RFC 9114 §7.2.8).
    pub const FIRST_RESERVED: Self = Self(0x21);

    /// Construct a frame type from its raw value.
    #[must_use]
    pub const fn new(value: u64) -> Self {
        Self(value)
    }

    /// The raw frame-type value.
    #[must_use]
    pub const fn value(self) -> u64 {
        self.0
    }

    /// Whether this is a reserved type of the form `0x1f * N + 0x21` (RFC 9114 §7.2.8) used for
    /// greasing.
    #[must_use]
    pub const fn is_reserved(self) -> bool {
        self.0 >= Self::FIRST_RESERVED.0 && (self.0 - Self::FIRST_RESERVED.0).is_multiple_of(0x1f)
    }

    /// Whether this is either PRIORITY_UPDATE frame type from RFC 9218.
    #[must_use]
    pub const fn is_priority_update(self) -> bool {
        matches!(
            self,
            Self::PRIORITY_UPDATE_REQUEST | Self::PRIORITY_UPDATE_PUSH
        )
    }

    /// Whether the frame payload starts with a push, stream, or element identifier.
    #[must_use]
    pub const fn carries_element_id(self) -> bool {
        matches!(self, Self::CANCEL_PUSH | Self::GOAWAY | Self::MAX_PUSH_ID)
            || self.is_priority_update()
    }

    /// Whether this frame type was assigned by HTTP/2 and has no HTTP/3 counterpart, so its receipt
    /// is a connection error of type `H3_FRAME_UNEXPECTED` (RFC 9114 §7.2.8): `PRIORITY` (0x02),
    /// `PING` (0x06), `WINDOW_UPDATE` (0x08), `CONTINUATION` (0x09).
    #[must_use]
    pub const fn is_h2_reserved(self) -> bool {
        matches!(self.0, 0x02 | 0x06 | 0x08 | 0x09)
    }

    /// A human-readable name for a known frame type, if any.
    #[must_use]
    pub const fn name(self) -> Option<&'static str> {
        Some(match self {
            Self::DATA => "DATA",
            Self::HEADERS => "HEADERS",
            Self::CANCEL_PUSH => "CANCEL_PUSH",
            Self::SETTINGS => "SETTINGS",
            Self::PUSH_PROMISE => "PUSH_PROMISE",
            Self::GOAWAY => "GOAWAY",
            Self::MAX_PUSH_ID => "MAX_PUSH_ID",
            Self::PRIORITY_UPDATE_REQUEST => "PRIORITY_UPDATE_REQUEST",
            Self::PRIORITY_UPDATE_PUSH => "PRIORITY_UPDATE_PUSH",
            _ => return None,
        })
    }
}

impl From<u64> for FrameType {
    fn from(value: u64) -> Self {
        Self(value)
    }
}

impl From<FrameType> for u64 {
    fn from(ty: FrameType) -> Self {
        ty.0
    }
}

impl fmt::Debug for FrameType {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self.name() {
            Some(name) => write!(f, "FrameType::{name}"),
            None if self.is_reserved() => write!(f, "FrameType(0x{:x}, reserved)", self.0),
            None => write!(f, "FrameType(0x{:x})", self.0),
        }
    }
}

impl fmt::Display for FrameType {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self.name() {
            Some(name) => f.write_str(name),
            None => write!(f, "0x{:x}", self.0),
        }
    }
}

/// The header of an HTTP/3 frame: a type followed by the byte length of its payload (RFC 9114
/// §7.1). It carries no payload; the payload is decoded by the layer that owns the frame body.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub struct FrameHeader {
    /// The frame type.
    pub ty: FrameType,
    /// The payload length in bytes.
    pub len: u64,
}

impl FrameHeader {
    /// Construct a frame header.
    #[must_use]
    pub const fn new(ty: FrameType, len: u64) -> Self {
        Self { ty, len }
    }

    /// The number of bytes this header occupies once encoded.
    ///
    /// Returns `None` if either the type or the length is not a valid variable-length integer.
    #[must_use]
    pub fn wire_len(&self) -> Option<usize> {
        let ty = VarInt::from_u64(self.ty.0).ok()?;
        let len = VarInt::from_u64(self.len).ok()?;
        Some(ty.size() + len.size())
    }

    /// Encode this header into `dst`.
    ///
    /// Returns `None` without writing anything if the type or length exceeds the variable-length
    /// integer range.
    pub fn encode<B: BufMut>(&self, dst: &mut B) -> Option<()> {
        let ty = VarInt::from_u64(self.ty.0).ok()?;
        let len = VarInt::from_u64(self.len).ok()?;
        ty.encode(dst);
        len.encode(dst);
        Some(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use rama_core::bytes::BytesMut;

    #[test]
    fn known_frame_types() {
        assert_eq!(FrameType::SETTINGS.value(), 0x04);
        assert_eq!(FrameType::MAX_PUSH_ID.name(), Some("MAX_PUSH_ID"));
        assert_eq!(FrameType::new(0x1234).name(), None);
    }

    #[test]
    fn h2_reserved_frames() {
        for raw in [0x02u64, 0x06, 0x08, 0x09] {
            assert!(FrameType::new(raw).is_h2_reserved(), "0x{raw:x}");
        }
        assert!(!FrameType::DATA.is_h2_reserved());
        assert!(!FrameType::HEADERS.is_h2_reserved());
    }

    #[test]
    fn reserved_grease() {
        assert!(FrameType::new(0x21).is_reserved());
        assert!(!FrameType::SETTINGS.is_reserved());
    }

    #[test]
    fn frame_header_round_trip() {
        let hdr = FrameHeader::new(FrameType::HEADERS, 11);
        let mut buf = BytesMut::new();
        hdr.encode(&mut buf).unwrap();
        assert_eq!(buf.len(), hdr.wire_len().unwrap());
        // HEADERS type = 0x01 (1 byte), len 11 (1 byte)
        assert_eq!(&buf[..], &[0x01, 0x0b]);
    }
}
