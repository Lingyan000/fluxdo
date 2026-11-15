//! Optional client control frames following the mandatory SETTINGS frame.

use super::{FrameHeader, FrameType, VarInt};
use rama_core::{
    bytes::{BufMut, Bytes},
    extensions::Extension,
};
use rama_quic_proto::{Dir, Side, StreamId, coding::Codec as _};

/// Additional client control frames; peer and local resource limits still apply.
#[derive(Clone, Debug, PartialEq, Eq, Hash)]
pub enum ClientControlFrame {
    /// An unassigned or reserved type. Known and HTTP/2-only types are refused.
    Ignored {
        frame_type: FrameType,
        payload: Bytes,
    },
    /// RFC 9218 priority field bytes for a client-initiated request stream.
    RequestPriority { request: StreamId, value: Bytes },
}

impl ClientControlFrame {
    fn parts(&self) -> Option<(FrameType, VarInt, Option<VarInt>, &[u8])> {
        let (ty, element, value) = match self {
            Self::Ignored {
                frame_type,
                payload,
            } if frame_type.name().is_none() && !frame_type.is_h2_reserved() => {
                (*frame_type, None, payload.as_ref())
            }
            Self::RequestPriority { request, value }
                if request.initiator() == Side::Client && request.dir() == Dir::Bi =>
            {
                (
                    FrameType::PRIORITY_UPDATE_REQUEST,
                    Some(VarInt::from(*request)),
                    value.as_ref(),
                )
            }
            _ => return None,
        };
        VarInt::from_u64(ty.value()).ok()?;
        let length = value.len().checked_add(element.map_or(0, VarInt::size))?;
        Some((
            ty,
            VarInt::from_u64(u64::try_from(length).ok()?).ok()?,
            element,
            value,
        ))
    }

    /// Encoded size, or `None` for an invalid frame type, target or length.
    pub fn encoded_len(&self) -> Option<usize> {
        let (ty, length, _, _) = self.parts()?;
        VarInt::from_u64(ty.value())
            .ok()?
            .size()
            .checked_add(length.size())?
            .checked_add(usize::try_from(length.into_inner()).ok()?)
    }

    /// Encode one complete frame, leaving the output unchanged on invalid input.
    pub fn encode(&self, output: &mut impl BufMut) -> Option<()> {
        let (ty, length, element, value) = self.parts()?;
        FrameHeader::new(ty, length.into_inner()).encode(output)?;
        if let Some(element) = element {
            element.encode(output);
        }
        output.put_slice(value);
        Some(())
    }
}

/// Ordered optional frames appended after client SETTINGS, within native budgets.
#[derive(Clone, Debug, Default, PartialEq, Eq, Hash, Extension)]
pub struct ClientControlPreferences {
    pub frames: Box<[ClientControlFrame]>,
}
