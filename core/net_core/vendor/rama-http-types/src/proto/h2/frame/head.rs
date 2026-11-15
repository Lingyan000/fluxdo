use super::{Error, StreamId};

use rama_core::bytes::BufMut;

#[derive(Debug, Copy, Clone, PartialEq, Eq)]
pub struct Head {
    kind: Kind,
    flag: u8,
    stream_id: StreamId,
}

#[repr(u8)]
#[derive(Debug, Copy, Clone, PartialEq, Eq)]
pub enum Kind {
    Data = 0,
    Headers = 1,
    Priority = 2,
    Reset = 3,
    Settings = 4,
    PushPromise = 5,
    Ping = 6,
    GoAway = 7,
    WindowUpdate = 8,
    Continuation = 9,
    AltSvc = 10,
    Unknown,
}

// ===== impl Head =====

impl Head {
    #[must_use]
    pub fn new(kind: Kind, flag: u8, stream_id: StreamId) -> Self {
        Self {
            kind,
            flag,
            stream_id,
        }
    }

    /// Parse an HTTP/2 frame header. Returns [`Error::ShortBuffer`] if
    /// `header.len() < HEADER_LEN` (9 bytes).
    pub fn parse(header: &[u8]) -> Result<Self, Error> {
        if header.len() < super::HEADER_LEN {
            return Err(Error::ShortBuffer {
                needed: super::HEADER_LEN,
                got: header.len(),
            });
        }
        let (stream_id, _) = StreamId::parse(&header[5..])?;

        Ok(Self {
            kind: Kind::new(header[3]),
            flag: header[4],
            stream_id,
        })
    }

    #[must_use]
    pub fn stream_id(&self) -> StreamId {
        self.stream_id
    }

    #[must_use]
    pub fn kind(&self) -> Kind {
        self.kind
    }

    #[must_use]
    pub fn flag(&self) -> u8 {
        self.flag
    }

    #[must_use]
    pub fn encode_len(&self) -> usize {
        super::HEADER_LEN
    }

    pub fn encode<T: BufMut>(&self, payload_len: usize, dst: &mut T) {
        debug_assert!(self.encode_len() <= dst.remaining_mut());

        dst.put_uint(payload_len as u64, 3);
        dst.put_u8(self.kind as u8);
        dst.put_u8(self.flag);
        dst.put_u32(self.stream_id.into());
    }
}

// ===== impl Kind =====

impl Kind {
    #[must_use]
    pub fn new(byte: u8) -> Self {
        match byte {
            0 => Self::Data,
            1 => Self::Headers,
            2 => Self::Priority,
            3 => Self::Reset,
            4 => Self::Settings,
            5 => Self::PushPromise,
            6 => Self::Ping,
            7 => Self::GoAway,
            8 => Self::WindowUpdate,
            9 => Self::Continuation,
            10 => Self::AltSvc,
            _ => Self::Unknown,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::assert_matches;

    #[test]
    fn parse_errors_when_buffer_shorter_than_header_len() {
        assert_matches!(
            Head::parse(&[0u8; crate::proto::h2::frame::HEADER_LEN - 1]),
            Err(Error::ShortBuffer { needed, got })
                if needed == crate::proto::h2::frame::HEADER_LEN && got == crate::proto::h2::frame::HEADER_LEN - 1,
        );
    }
}
