//! Capsule Protocol wire values (RFC 9297 §3.2), shared by every HTTP version.
//!
//! A capsule is `Type (i), Length (i), Value (..)` on a request's data stream: the bytes after
//! a `101` on HTTP/1.x and the DATA frame payloads of the request stream on HTTP/2 and HTTP/3.
//! Integers use the QUIC variable-length encoding and need not be minimal (RFC 9297 §1.1).

use std::fmt;

use rama_core::bytes::BufMut;
use rama_quic_proto::{VarInt, coding::Codec};

/// A Capsule Type (RFC 9297 §3.2, §5.4).
#[derive(Clone, Copy, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub struct CapsuleType(u64);

impl CapsuleType {
    /// `DATAGRAM` (RFC 9297 §3.5): carries one HTTP Datagram payload.
    pub const DATAGRAM: Self = Self(0x00);

    /// Construct from its raw value, which must fit a variable-length integer.
    pub const fn new(value: u64) -> Result<Self, InvalidCapsule> {
        if value > VarInt::MAX.into_inner() {
            return Err(InvalidCapsule::new());
        }
        Ok(Self(value))
    }

    /// Construct a statically known capsule type.
    ///
    /// # Panics
    ///
    /// Panics if the value exceeds the QUIC variable-length integer range.
    #[must_use]
    pub const fn from_static(value: u64) -> Self {
        assert!(value <= VarInt::MAX.into_inner(), "invalid capsule type");
        Self(value)
    }

    /// The raw value.
    #[must_use]
    pub const fn value(self) -> u64 {
        self.0
    }

    /// Whether this is a reserved greasing type of the form `0x29 * N + 0x17` (RFC 9297 §5.4).
    #[must_use]
    pub const fn is_reserved(self) -> bool {
        self.0 >= 0x17 && (self.0 - 0x17).is_multiple_of(0x29)
    }
}

impl From<VarInt> for CapsuleType {
    fn from(value: VarInt) -> Self {
        Self(value.into_inner())
    }
}

impl fmt::Debug for CapsuleType {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match *self {
            Self::DATAGRAM => f.write_str("CapsuleType::DATAGRAM"),
            _ if self.is_reserved() => write!(f, "CapsuleType(0x{:x}, reserved)", self.0),
            _ => write!(f, "CapsuleType(0x{:x})", self.0),
        }
    }
}

/// The type and value length that precede a Capsule Value.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub struct CapsuleHeader {
    /// The Capsule Type.
    pub ty: CapsuleType,
    /// The Capsule Value length in bytes; zero is legal.
    pub length: VarInt,
}

impl CapsuleHeader {
    /// The largest encoded header: two 8-byte variable-length integers.
    pub const MAX_SIZE: usize = 16;

    /// A header for a value of `length` bytes.
    pub fn new(ty: CapsuleType, length: u64) -> Result<Self, InvalidCapsule> {
        let length = VarInt::from_u64(length).map_err(|_error| InvalidCapsule::new())?;
        Ok(Self { ty, length })
    }

    /// The encoded header length.
    #[must_use]
    pub fn size(&self) -> usize {
        self.ty_varint().size() + self.length.size()
    }

    /// Append the header to `dst`.
    pub fn encode<B: BufMut>(&self, dst: &mut B) {
        self.ty_varint().encode(dst);
        self.length.encode(dst);
    }

    fn ty_varint(&self) -> VarInt {
        // `CapsuleType` is range-checked on construction.
        VarInt::from_u64(self.ty.0).unwrap_or(VarInt::MAX)
    }
}

rama_utils::macros::error::static_str_error! {
    #[doc = "capsule type or length exceeds the variable-length integer range"]
    #[derive(Copy)]
    pub struct InvalidCapsule;
}

#[cfg(test)]
mod tests {
    use super::*;
    use rama_core::bytes::BytesMut;

    #[test]
    fn greasing_types_are_recognized() {
        for n in [0, 1, 2, 1000] {
            assert!(CapsuleType::new(0x29 * n + 0x17).unwrap().is_reserved());
        }
        for value in [0x00, 0x16, 0x18, 0x41] {
            assert!(!CapsuleType::new(value).unwrap().is_reserved());
        }
        assert!(!CapsuleType::DATAGRAM.is_reserved());
    }

    #[test]
    fn range_is_the_varint_range() {
        CapsuleType::new(VarInt::MAX.into_inner()).unwrap();
        CapsuleType::new(VarInt::MAX.into_inner() + 1).unwrap_err();
        CapsuleHeader::new(CapsuleType::DATAGRAM, VarInt::MAX.into_inner()).unwrap();
        CapsuleHeader::new(CapsuleType::DATAGRAM, VarInt::MAX.into_inner() + 1).unwrap_err();
    }

    #[test]
    fn header_encoding_uses_minimal_varints() {
        let mut encoded = BytesMut::new();
        let header = CapsuleHeader::new(CapsuleType::DATAGRAM, 0).unwrap();
        header.encode(&mut encoded);
        assert_eq!(&encoded[..], b"\x00\x00");
        assert_eq!(header.size(), 2);

        let mut encoded = BytesMut::new();
        let header = CapsuleHeader::new(CapsuleType::new(0x4000).unwrap(), 64).unwrap();
        header.encode(&mut encoded);
        assert_eq!(&encoded[..], b"\x80\x00\x40\x00\x40\x40");
        assert_eq!(header.size(), encoded.len());
        assert!(header.size() <= CapsuleHeader::MAX_SIZE);
    }
}
