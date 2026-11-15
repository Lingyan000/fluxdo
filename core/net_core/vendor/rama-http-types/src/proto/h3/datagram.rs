//! HTTP/3 datagram association (RFC 9297 §2.1).

use std::fmt;

use rama_core::bytes::{BufMut, Bytes};
use rama_quic_proto::{Dir, MAX_STREAM_COUNT, Side, StreamId, VarInt, coding::Codec};

/// The Quarter Stream ID prefix of an HTTP/3 datagram (RFC 9297 §2.1).
///
/// It names the client-initiated bidirectional request stream the datagram belongs to, divided by
/// four. Values above `2^60 - 1` cannot name a legal stream and are rejected on construction.
#[derive(Clone, Copy, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub struct QuarterStreamId(u64);

impl QuarterStreamId {
    /// The largest legal value, `2^60 - 1` (RFC 9297 §2.1).
    pub const MAX: Self = Self(MAX_STREAM_COUNT - 1);

    /// Construct from its raw value.
    pub const fn new(value: u64) -> Result<Self, InvalidQuarterStreamId> {
        if value > Self::MAX.0 {
            return Err(InvalidQuarterStreamId::new());
        }
        Ok(Self(value))
    }

    /// The Quarter Stream ID of a request stream, which must be client-initiated bidirectional.
    pub fn from_request_stream(stream: StreamId) -> Result<Self, InvalidQuarterStreamId> {
        if stream.initiator() != Side::Client || stream.dir() != Dir::Bi {
            return Err(InvalidQuarterStreamId::new());
        }
        // Stream indices are always below 2^60, so this cannot fail.
        Self::new(stream.index())
    }

    /// The raw value.
    #[must_use]
    pub const fn value(self) -> u64 {
        self.0
    }

    /// The associated request stream.
    #[must_use]
    pub fn request_stream(self) -> StreamId {
        StreamId::new(Side::Client, Dir::Bi, self.0)
    }

    /// Encoded length of this prefix.
    #[must_use]
    pub fn size(self) -> usize {
        self.varint().size()
    }

    /// Append the prefix to `dst`.
    pub fn encode<B: BufMut>(self, dst: &mut B) {
        self.varint().encode(dst);
    }

    /// Split a received QUIC DATAGRAM payload into its Quarter Stream ID and HTTP datagram
    /// payload. The payload shares `datagram`'s storage.
    ///
    /// Both a truncated prefix and a value above [`Self::MAX`] are connection errors of type
    /// `H3_DATAGRAM_ERROR`.
    pub fn split_datagram(mut datagram: Bytes) -> Result<(Self, Bytes), InvalidQuarterStreamId> {
        let value =
            VarInt::decode(&mut datagram).map_err(|_error| InvalidQuarterStreamId::new())?;
        Ok((Self::new(value.into_inner())?, datagram))
    }

    fn varint(self) -> VarInt {
        // `MAX` is below the varint bound.
        VarInt::from_u64(self.0).unwrap_or(VarInt::MAX)
    }
}

impl fmt::Debug for QuarterStreamId {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "QuarterStreamId({})", self.0)
    }
}

rama_utils::macros::error::static_str_error! {
    #[doc = "invalid HTTP/3 datagram Quarter Stream ID"]
    #[derive(Copy)]
    pub struct InvalidQuarterStreamId;
}

#[cfg(test)]
mod tests {
    use super::*;
    use rama_core::bytes::BytesMut;

    #[test]
    fn bounds_follow_the_largest_legal_stream() {
        assert_eq!(QuarterStreamId::MAX.value(), (1 << 60) - 1);
        QuarterStreamId::new(1 << 60).unwrap_err();
        let max = QuarterStreamId::MAX.request_stream();
        assert_eq!(u64::from(VarInt::from(max)), (1 << 62) - 4);
        assert_eq!(
            QuarterStreamId::from_request_stream(max).unwrap(),
            QuarterStreamId::MAX
        );
    }

    #[test]
    fn only_client_bidirectional_streams_carry_datagrams() {
        for (side, dir, valid) in [
            (Side::Client, Dir::Bi, true),
            (Side::Server, Dir::Bi, false),
            (Side::Client, Dir::Uni, false),
            (Side::Server, Dir::Uni, false),
        ] {
            let stream = StreamId::new(side, dir, 7);
            assert_eq!(
                QuarterStreamId::from_request_stream(stream).is_ok(),
                valid,
                "{stream}"
            );
        }
        let id =
            QuarterStreamId::from_request_stream(StreamId::new(Side::Client, Dir::Bi, 7)).unwrap();
        assert_eq!(u64::from(VarInt::from(id.request_stream())), 28);
    }

    #[test]
    fn split_shares_storage_and_accepts_non_minimal_prefixes() {
        let datagram = Bytes::from_static(b"\x40\x05payload");
        let start = datagram.as_ptr();
        let (id, payload) = QuarterStreamId::split_datagram(datagram).unwrap();
        assert_eq!(id.value(), 5);
        assert_eq!(&payload[..], b"payload");
        assert_eq!(payload.as_ptr(), start.wrapping_add(2));

        let (id, payload) = QuarterStreamId::split_datagram(Bytes::from_static(b"\x00")).unwrap();
        assert_eq!(id.value(), 0);
        assert!(payload.is_empty());
    }

    #[test]
    fn truncated_and_oversized_prefixes_are_rejected() {
        QuarterStreamId::split_datagram(Bytes::new()).unwrap_err();
        QuarterStreamId::split_datagram(Bytes::from_static(b"\x80\x00\x01")).unwrap_err();
        // 2^60 encoded as an 8-byte varint.
        let mut oversized = BytesMut::new();
        VarInt::from_u64(1 << 60).unwrap().encode(&mut oversized);
        QuarterStreamId::split_datagram(oversized.freeze()).unwrap_err();
    }

    #[test]
    fn encoding_round_trips() {
        for value in [0, 63, 64, 16383, 16384, QuarterStreamId::MAX.value()] {
            let id = QuarterStreamId::new(value).unwrap();
            let mut encoded = BytesMut::new();
            id.encode(&mut encoded);
            assert_eq!(encoded.len(), id.size());
            encoded.extend_from_slice(b"x");
            let (decoded, payload) = QuarterStreamId::split_datagram(encoded.freeze()).unwrap();
            assert_eq!(decoded, id);
            assert_eq!(&payload[..], b"x");
        }
    }
}
