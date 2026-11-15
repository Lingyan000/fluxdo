use super::{Error, Frame, Head, Kind, StreamId};

use rama_core::bytes::BufMut;
use rama_core::telemetry::tracing;
use rama_utils::octets::unpack_octets_as_u32;
use serde::{Deserialize, Serialize};

const SIZE_INCREMENT_MASK: u32 = 1 << 31;

#[derive(Debug, Copy, Clone, Eq, PartialEq, Serialize, Deserialize)]
pub struct WindowUpdate {
    pub stream_id: StreamId,
    pub size_increment: u32,
}

impl WindowUpdate {
    #[must_use]
    pub fn new(stream_id: StreamId, size_increment: u32) -> Self {
        Self {
            stream_id,
            size_increment,
        }
    }

    /// Builds a `WindowUpdate` frame from a raw frame.
    pub fn load(head: Head, payload: &[u8]) -> Result<Self, Error> {
        debug_assert_eq!(head.kind(), Kind::WindowUpdate);
        if payload.len() != 4 {
            return Err(Error::BadFrameSize);
        }

        // Clear the most significant bit, as that is reserved and MUST be ignored
        // when received.
        let size_increment = unpack_octets_as_u32(payload, 0) & !SIZE_INCREMENT_MASK;

        if size_increment == 0 {
            return Err(Error::InvalidWindowUpdateValue);
        }

        Ok(Self {
            stream_id: head.stream_id(),
            size_increment,
        })
    }

    pub fn encode<B: BufMut>(&self, dst: &mut B) {
        tracing::trace!("encoding WINDOW_UPDATE; id={:?}", self.stream_id);
        let head = Head::new(Kind::WindowUpdate, 0, self.stream_id);
        head.encode(4, dst);
        dst.put_u32(self.size_increment);
    }
}

impl<B> From<WindowUpdate> for Frame<B> {
    fn from(src: WindowUpdate) -> Self {
        Self::WindowUpdate(src)
    }
}
