//! Rama's QPACK events: instruction classes, indices and counts, never names or values.

use rama_http_types::proto::h3::qpack::{DecoderInstruction, EncoderInstruction, HeaderPrefix};
use rama_quic::qlog::{ConnectionQlogControl, EventSchema};
use serde::Serialize;

use super::PeerEventBudget;

/// Peer-triggered QPACK instruction events recorded per connection before the rest are suppressed.
pub(in crate::h3) const QPACK_INSTRUCTION_EVENTS: u32 = 4096;

/// Explicit private QPACK schema, to register alongside HTTP/3 and QUIC schemas.
pub const EVENT_SCHEMA_QPACK: EventSchema =
    EventSchema::new("https://ramaproxy.org/qlog/rama-qpack-1", "rama_qpack");

#[derive(Clone, Copy, Serialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub(in crate::h3) enum Instruction {
    SetCapacity { capacity: u64 },
    InsertNameReference { is_static: bool, index: u64 },
    InsertLiteralName,
    Duplicate { index: u64 },
    SectionAcknowledgment { stream_id: u64 },
    StreamCancellation { stream_id: u64 },
    InsertCountIncrement { increment: u64 },
}

impl Instruction {
    pub(in crate::h3) fn encoder(instruction: &EncoderInstruction) -> Self {
        match instruction {
            EncoderInstruction::SetDynamicTableCapacity { capacity } => Self::SetCapacity {
                capacity: *capacity,
            },
            EncoderInstruction::InsertWithNameRef {
                is_static,
                name_index,
                ..
            } => Self::InsertNameReference {
                is_static: *is_static,
                index: *name_index,
            },
            EncoderInstruction::InsertWithLiteralName { .. } => Self::InsertLiteralName,
            EncoderInstruction::Duplicate { index } => Self::Duplicate { index: *index },
        }
    }
    pub(in crate::h3) fn decoder(instruction: DecoderInstruction) -> Self {
        match instruction {
            DecoderInstruction::SectionAcknowledgment { stream_id } => {
                Self::SectionAcknowledgment { stream_id }
            }
            DecoderInstruction::StreamCancellation { stream_id } => {
                Self::StreamCancellation { stream_id }
            }
            DecoderInstruction::InsertCountIncrement { increment } => {
                Self::InsertCountIncrement { increment }
            }
        }
    }
}

#[derive(Serialize)]
struct InstructionRecord {
    instruction: Instruction,
    insert_count: u64,
    table_capacity: u64,
}

/// Record one instruction; a peer-triggered one is admitted by that peer's `budget`.
pub(in crate::h3) fn instruction(
    control: Option<&ConnectionQlogControl>,
    budget: Option<&PeerEventBudget>,
    name: &'static str,
    instruction: Instruction,
    state: impl FnOnce() -> (u64, u64),
) {
    if let Some(control) = control
        && budget.is_none_or(|budget| budget.admit(control))
    {
        control.emit_named(&EVENT_SCHEMA_QPACK, name, || {
            let (insert_count, table_capacity) = state();
            InstructionRecord {
                instruction,
                insert_count,
                table_capacity,
            }
        });
    }
}

#[derive(Serialize)]
struct SectionRecord {
    stream_id: u64,
    required_insert_count: u64,
    base: u64,
    #[serde(skip_serializing_if = "Option::is_none")]
    field_count: Option<usize>,
    #[serde(skip_serializing_if = "Option::is_none")]
    blocked_bytes: Option<usize>,
}

pub(in crate::h3) fn section(
    control: Option<&ConnectionQlogControl>,
    name: &'static str,
    stream_id: u64,
    prefix: &HeaderPrefix,
    field_count: Option<usize>,
    blocked_bytes: Option<usize>,
) {
    if let Some(control) = control {
        control.emit_named(&EVENT_SCHEMA_QPACK, name, || SectionRecord {
            stream_id,
            required_insert_count: prefix.required_insert_count,
            base: prefix.base,
            field_count,
            blocked_bytes,
        });
    }
}
