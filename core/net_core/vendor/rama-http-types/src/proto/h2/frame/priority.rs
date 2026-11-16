use rama_core::bytes::BufMut;
use serde::{Deserialize, Serialize};
use rama_core::extensions::Extension;

use super::*;

#[derive(Debug, Clone, Eq, PartialEq, Serialize, Deserialize)]
pub struct Priority {
    pub stream_id: StreamId,
    pub dependency: StreamDependency,
}

#[derive(Debug, Clone, Eq, PartialEq, Serialize, Deserialize, Extension)]
pub struct StreamDependency {
    /// The ID of the stream dependency target
    pub dependency_id: StreamId,

    /// The weight for the stream. The value exposed (and set) here is always in
    /// the range [0, 255], instead of [1, 256] (as defined in section 5.3.2.)
    /// so that the value fits into a `u8`.
    pub weight: u8,

    /// True if the stream dependency is exclusive.
    pub is_exclusive: bool,
}

/// 入站流的依赖关系；非根流 ID 只在原连接内有效，不能直接用于另一条连接。
#[derive(Debug, Clone, Extension)]
pub struct ReceivedStreamDependency(pub StreamDependency);

impl Priority {
    /// Create a new priority frame.
    ///
    /// # Parameters
    /// - `stream_id`: The ID of the stream. This can be any valid stream ID, including 0.
    /// - `dependency`: The stream dependency information.
    ///
    /// # Returns
    /// A new `Priority` frame.
    #[must_use]
    pub fn new(stream_id: StreamId, dependency: StreamDependency) -> Self {
        Self {
            stream_id,
            dependency,
        }
    }

    pub fn load(head: Head, payload: &[u8]) -> Result<Self, Error> {
        let dependency = StreamDependency::load(payload)?;

        if dependency.dependency_id == head.stream_id() {
            return Err(Error::InvalidDependencyId);
        }

        Ok(Self {
            stream_id: head.stream_id(),
            dependency,
        })
    }

    #[must_use]
    pub fn head(&self) -> Head {
        Head::new(Kind::Priority, 0, self.stream_id)
    }

    pub fn encode<B: BufMut>(&self, dst: &mut B) {
        let head = self.head();
        head.encode(5, dst);

        // Priority frame payload is exactly 5 bytes
        // Format:
        // +---------------+
        // |E|  Dep ID (31)|
        // +---------------+
        // |   Weight (8)  |
        // +---------------+
        self.dependency.encode(dst);
    }
}

impl<B> From<Priority> for Frame<B> {
    fn from(src: Priority) -> Self {
        Self::Priority(src)
    }
}

// ===== impl StreamDependency =====

impl StreamDependency {
    #[must_use]
    pub fn new(dependency_id: StreamId, weight: u8, is_exclusive: bool) -> Self {
        Self {
            dependency_id,
            weight,
            is_exclusive,
        }
    }

    pub fn load(src: &[u8]) -> Result<Self, Error> {
        if src.len() != 5 {
            return Err(Error::InvalidPayloadLength);
        }

        // Parse the stream ID and exclusive flag
        let (dependency_id, is_exclusive) = StreamId::parse(&src[..4])?;

        // Read the weight
        let weight = src[4];

        Ok(Self::new(dependency_id, weight, is_exclusive))
    }

    pub fn encode<T: BufMut>(&self, dst: &mut T) {
        const STREAM_ID_MASK: u32 = 1 << 31;
        let mut dependency_id = self.dependency_id.into();
        if self.is_exclusive {
            dependency_id |= STREAM_ID_MASK;
        }
        dst.put_u32(dependency_id);
        dst.put_u8(self.weight);
    }
}

mod tests {
    #[test]
    fn test_priority_frame() {
        use crate::proto::h2::frame::{self, Priority, StreamDependency, StreamId};

        let mut dependency_buf = Vec::new();
        let dependency = StreamDependency::new(StreamId::zero(), 201, false);
        dependency.encode(&mut dependency_buf);
        let dependency = StreamDependency::load(&dependency_buf).unwrap();
        assert_eq!(dependency.dependency_id, StreamId::zero());
        assert_eq!(dependency.weight, 201);
        assert!(!dependency.is_exclusive);

        let priority = Priority::new(StreamId::from(3), dependency);
        let mut priority_buf = Vec::new();
        priority.encode(&mut priority_buf);
        let priority = Priority::load(priority.head(), &priority_buf[frame::HEADER_LEN..]).unwrap();
        assert_eq!(priority.stream_id, StreamId::from(3));
        assert_eq!(priority.dependency.dependency_id, StreamId::zero());
        assert_eq!(priority.dependency.weight, 201);
        assert!(!priority.dependency.is_exclusive);
    }

    #[test]
    fn priority_wire_bytes() {
        use crate::proto::h2::frame::{Priority, StreamDependency, StreamId};

        let mut buf = Vec::new();
        Priority::new(
            StreamId::from(1),
            StreamDependency::new(StreamId::zero(), 200, false),
        )
        .encode(&mut buf);
        assert_eq!(buf, [0, 0, 5, 2, 0, 0, 0, 0, 1, 0, 0, 0, 0, 200]);

        let mut buf = Vec::new();
        Priority::new(
            StreamId::from(5),
            StreamDependency::new(StreamId::from(3), 0, true),
        )
        .encode(&mut buf);
        assert_eq!(buf, [0, 0, 5, 2, 0, 0, 0, 0, 5, 0x80, 0, 0, 3, 0]);
    }
}
