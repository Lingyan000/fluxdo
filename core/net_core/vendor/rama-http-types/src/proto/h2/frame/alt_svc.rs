use super::{Error, Frame, Head, Kind, MAX_MAX_FRAME_SIZE, StreamId};
use rama_core::bytes::{Buf, BufMut, Bytes};

/// An HTTP/2 alternative-service advertisement (RFC 7838 §4).
///
/// Origin and field-value bytes retain their wire representation. Parsing their
/// syntax and checking the connection's authority belong to the receiver.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AltSvc {
    stream_id: StreamId,
    origin: Bytes,
    field_value: Bytes,
}

impl AltSvc {
    /// Create an advertisement for an explicit origin on stream zero, or for
    /// a request's origin on a nonzero stream with an empty `origin`.
    pub fn new(stream_id: StreamId, origin: Bytes, field_value: Bytes) -> Result<Self, Error> {
        if stream_id.is_zero() == origin.is_empty() {
            return Err(Error::InvalidStreamId);
        }
        if origin.len() > usize::from(u16::MAX)
            || field_value.len() > MAX_MAX_FRAME_SIZE as usize - ORIGIN_LENGTH_SIZE - origin.len()
        {
            return Err(Error::InvalidPayloadLength);
        }
        Ok(Self {
            stream_id,
            origin,
            field_value,
        })
    }

    #[must_use]
    pub fn stream_id(&self) -> StreamId {
        self.stream_id
    }

    #[must_use]
    pub fn origin(&self) -> &Bytes {
        &self.origin
    }

    #[must_use]
    pub fn field_value(&self) -> &Bytes {
        &self.field_value
    }

    #[must_use]
    pub fn into_parts(self) -> (StreamId, Bytes, Bytes) {
        (self.stream_id, self.origin, self.field_value)
    }

    #[must_use]
    pub fn payload_len(&self) -> usize {
        ORIGIN_LENGTH_SIZE + self.origin.len() + self.field_value.len()
    }

    /// Decode a payload without copying its origin or field value.
    ///
    /// Invalid origin/stream associations must be ignored by receivers, rather
    /// than promoted to HTTP/2 connection errors (RFC 7838 §4).
    pub fn load(head: Head, mut payload: Bytes) -> Result<Self, Error> {
        debug_assert_eq!(head.kind(), Kind::AltSvc);
        if payload.len() < ORIGIN_LENGTH_SIZE {
            return Err(Error::InvalidPayloadLength);
        }
        let origin_len = usize::from(payload.get_u16());
        if origin_len > payload.len() {
            return Err(Error::InvalidPayloadLength);
        }
        let origin = payload.split_to(origin_len);
        Self::new(head.stream_id(), origin, payload)
    }

    /// Encode the frame header and payload. The connection codec additionally
    /// enforces its peer's negotiated maximum frame size.
    pub fn encode<B: BufMut>(&self, dst: &mut B) {
        Head::new(Kind::AltSvc, 0, self.stream_id).encode(self.payload_len(), dst);
        dst.put_u16(self.origin.len() as u16);
        dst.put_slice(&self.origin);
        dst.put_slice(&self.field_value);
    }
}

const ORIGIN_LENGTH_SIZE: usize = size_of::<u16>();

impl<T> From<AltSvc> for Frame<T> {
    fn from(value: AltSvc) -> Self {
        Self::AltSvc(value)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use rama_core::bytes::BytesMut;

    #[test]
    fn wire_vector_preserves_shared_slices_and_ignores_flags() {
        let wire = Bytes::from_static(
            b"\x00\x00\x1c\x0a\xff\x00\x00\x00\x00\x00\x11https://a.exampleh2=\":443\"",
        );
        let frame = AltSvc::load(Head::parse(&wire).unwrap(), wire.slice(9..)).unwrap();
        assert_eq!(frame.origin(), "https://a.example");
        assert_eq!(frame.field_value(), "h2=\":443\"");
        assert_eq!(frame.origin().as_ptr(), wire[11..].as_ptr());
        assert_eq!(frame.field_value().as_ptr(), wire[28..].as_ptr());
        let mut encoded = BytesMut::new();
        frame.encode(&mut encoded);
        let mut expected = wire.to_vec();
        expected[4] = 0;
        assert_eq!(encoded.as_ref(), expected);
    }

    #[test]
    fn stream_advertisement_roundtrip() {
        let frame = AltSvc::new(
            StreamId::from(1),
            Bytes::new(),
            Bytes::from_static(b"clear"),
        )
        .unwrap();
        let mut wire = BytesMut::new();
        frame.encode(&mut wire);
        assert_eq!(
            &wire[..],
            b"\x00\x00\x07\x0a\x00\x00\x00\x00\x01\x00\x00clear"
        );
        let head = Head::parse(&wire).unwrap();
        assert_eq!(AltSvc::load(head, wire.freeze().slice(9..)).unwrap(), frame);
    }

    #[test]
    fn malformed_payloads_and_associations_are_rejected() {
        for payload in [b"".as_slice(), b"\x00", b"\x00\x01", b"\xff\xffx"] {
            assert_eq!(
                AltSvc::load(
                    Head::new(Kind::AltSvc, 0, StreamId::zero()),
                    Bytes::copy_from_slice(payload)
                ),
                Err(Error::InvalidPayloadLength)
            );
        }
        for (stream, origin) in [
            (StreamId::zero(), Bytes::new()),
            (StreamId::from(1), Bytes::from_static(b"https://a.example")),
        ] {
            assert_eq!(
                AltSvc::new(stream, origin, Bytes::new()),
                Err(Error::InvalidStreamId)
            );
        }
    }

    #[test]
    fn complete_payload_must_fit_the_frame_length_field() {
        let value = Bytes::from(vec![b'a'; MAX_MAX_FRAME_SIZE as usize]);
        AltSvc::new(
            StreamId::from(1),
            Bytes::new(),
            value.slice(..value.len() - ORIGIN_LENGTH_SIZE),
        )
        .unwrap();
        assert_eq!(
            AltSvc::new(
                StreamId::from(1),
                Bytes::new(),
                value.slice(..value.len() - ORIGIN_LENGTH_SIZE + 1),
            ),
            Err(Error::InvalidPayloadLength)
        );
    }

    #[test]
    fn origin_length_bound_is_checked_before_encoding() {
        let origin = Bytes::from(vec![b'a'; usize::from(u16::MAX)]);
        AltSvc::new(StreamId::zero(), origin, Bytes::new()).unwrap();
        let origin = Bytes::from(vec![b'a'; usize::from(u16::MAX) + 1]);
        assert_eq!(
            AltSvc::new(StreamId::zero(), origin, Bytes::new()),
            Err(Error::InvalidPayloadLength)
        );
    }
}
