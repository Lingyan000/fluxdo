//! Bounded HTTP/3 observation values, independent of the connection driver.

use super::qpack::{EncoderInstruction, FieldLine};
use crate::proto::h2::PseudoHeaderOrder;
use rama_core::extensions::Extension;
use rama_utils::octets;
use serde::Serialize;
use std::sync::{Arc, OnceLock};

#[derive(Debug, Clone, Copy)]
pub struct ObservationLimits {
    /// Retained bytes per component: connection recorder, QPACK instructions, pending
    /// fields, and each live snapshot. Collection capacity adds bounded overhead.
    /// Request field metadata and its priority share a separate `bytes` allowance.
    pub bytes: usize,
    pub events: usize,
    pub fields: usize,
    pub streams: usize,
    /// Maximum live connection snapshots, including the pinned first request.
    pub retained_snapshots: usize,
    /// Maximum decoded request heads awaiting delivery.
    pub pending_fields: usize,
}

impl Default for ObservationLimits {
    fn default() -> Self {
        Self {
            bytes: octets::kib(64),
            events: 256,
            fields: 256,
            streams: 32,
            retained_snapshots: 8,
            pending_fields: 8,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
pub enum FieldRepresentation {
    StaticIndex,
    DynamicIndex,
    DynamicPostBaseIndex,
    LiteralStaticName,
    LiteralDynamicName,
    LiteralPostBaseName,
    LiteralName,
}

#[derive(Debug, Clone, Copy, Serialize)]
pub struct ObservedFieldRepresentation {
    pub representation: FieldRepresentation,
    pub index: Option<u64>,
    pub name_huffman: bool,
    pub value_huffman: bool,
    pub never_index: bool,
}

impl From<&FieldLine> for ObservedFieldRepresentation {
    fn from(line: &FieldLine) -> Self {
        let (representation, index, name_huffman, value_huffman, never_index) = match line {
            FieldLine::Indexed { is_static, index } => (
                if *is_static {
                    FieldRepresentation::StaticIndex
                } else {
                    FieldRepresentation::DynamicIndex
                },
                Some(*index),
                false,
                false,
                false,
            ),
            FieldLine::IndexedPostBase { index } => (
                FieldRepresentation::DynamicPostBaseIndex,
                Some(*index),
                false,
                false,
                false,
            ),
            FieldLine::LiteralWithNameRef {
                is_static,
                name_index,
                value_huffman,
                never_index,
                ..
            } => (
                if *is_static {
                    FieldRepresentation::LiteralStaticName
                } else {
                    FieldRepresentation::LiteralDynamicName
                },
                Some(*name_index),
                false,
                *value_huffman,
                *never_index,
            ),
            FieldLine::LiteralWithPostBaseNameRef {
                name_index,
                value_huffman,
                never_index,
                ..
            } => (
                FieldRepresentation::LiteralPostBaseName,
                Some(*name_index),
                false,
                *value_huffman,
                *never_index,
            ),
            FieldLine::LiteralWithLiteralName {
                name_huffman,
                value_huffman,
                never_index,
                ..
            } => (
                FieldRepresentation::LiteralName,
                None,
                *name_huffman,
                *value_huffman,
                *never_index,
            ),
        };
        Self {
            representation,
            index,
            name_huffman,
            value_huffman,
            never_index,
        }
    }
}

#[derive(Debug, Clone, Serialize)]
pub enum ObservedEncoderInstruction {
    Capacity {
        capacity: u64,
    },
    InsertNameReference {
        is_static: bool,
        index: u64,
        value_bytes: usize,
        value_huffman: bool,
    },
    InsertLiteral {
        name_bytes: usize,
        value_bytes: usize,
        name_huffman: bool,
        value_huffman: bool,
    },
    Duplicate {
        index: u64,
    },
}

impl From<&EncoderInstruction> for ObservedEncoderInstruction {
    fn from(value: &EncoderInstruction) -> Self {
        match value {
            EncoderInstruction::SetDynamicTableCapacity { capacity } => Self::Capacity {
                capacity: *capacity,
            },
            EncoderInstruction::InsertWithNameRef {
                is_static,
                name_index,
                value,
                value_huffman,
            } => Self::InsertNameReference {
                is_static: *is_static,
                index: *name_index,
                value_bytes: value.len(),
                value_huffman: *value_huffman,
            },
            EncoderInstruction::InsertWithLiteralName {
                name,
                value,
                name_huffman,
                value_huffman,
            } => Self::InsertLiteral {
                name_bytes: name.len(),
                value_bytes: value.len(),
                name_huffman: *name_huffman,
                value_huffman: *value_huffman,
            },
            EncoderInstruction::Duplicate { index } => Self::Duplicate { index: *index },
        }
    }
}

/// An exact name/value match against the initial request's decoded fields.
///
/// Positions describe protocol evidence only; they do not authorize replaying a
/// sensitive value. No field names, values or hashes are retained here.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
pub enum InsertionFieldMatch {
    /// Exactly one field in the initial request has these name/value octets.
    Unique { field_index: usize },
    /// No field in that request has these name/value octets.
    Absent,
    /// Multiple fields match; selecting one would be a guess.
    Ambiguous,
    /// The inserted entry was evicted before the request was decoded.
    Evicted,
    /// The observation budget did not permit inspecting the complete request.
    Unavailable,
}

#[derive(Debug, Clone, Copy, Serialize)]
pub struct ObservedInsertionBinding {
    /// Position in the connection's observed encoder instruction sequence.
    pub instruction_index: usize,
    /// QPACK absolute insertion index, never reused within this connection.
    pub insertion_index: u64,
    pub field: InsertionFieldMatch,
}

/// Associations from the first decoded request head, before HTTP validation.
///
/// The containing snapshot identifies the connection and peer encoder direction;
/// `stream_id` identifies its initial request field section, not its trailers.
#[derive(Debug, Clone, Serialize)]
pub struct ObservedEncoderBindings {
    pub stream_id: u64,
    pub insertions: Vec<ObservedInsertionBinding>,
    /// False when instruction/field/byte limits prevent a complete association.
    /// Individual absent, ambiguous and evicted matches remain explicit.
    pub complete: bool,
}

#[derive(Debug, Clone, Serialize)]
pub struct ObservedSetting {
    pub id: u64,
    pub value: u64,
    pub grease: bool,
}

#[derive(Debug, Clone, Serialize)]
pub struct ObservedUniStream {
    pub sequence: u64,
    pub stream_id: u64,
    pub stream_type: u64,
    pub grease: bool,
}

#[derive(Debug, Clone, Serialize)]
pub struct ObservedControlFrame {
    pub sequence: u64,
    pub frame_type: u64,
    pub length: u64,
    pub element_id: Option<u64>,
    /// Priority field bytes after the element ID, or a complete bounded
    /// reserved-frame payload. Other unassigned bodies are not retained.
    pub value: Box<[u8]>,
}

#[derive(Debug, Clone, Copy, Default, Serialize)]
pub struct ObservationCompleteness {
    pub settings: bool,
    pub local_settings: bool,
    pub streams: bool,
    pub control: bool,
    pub qpack: bool,
    pub fields: bool,
    pub snapshot: bool,
}

#[derive(Debug, Clone, Default, Serialize)]
pub struct H3ObservationSnapshot {
    pub revision: u64,
    /// Receipt is retained even when the SETTINGS values exceed the capture budget.
    pub settings_received: bool,
    pub settings: Option<Vec<ObservedSetting>>,
    pub local_settings: Vec<ObservedSetting>,
    pub streams: Vec<ObservedUniStream>,
    pub control: Vec<ObservedControlFrame>,
    pub encoder_instructions: Vec<ObservedEncoderInstruction>,
    /// None before an initial request head, or when its metadata cannot fit.
    pub encoder_bindings: Option<ObservedEncoderBindings>,
    pub completeness: ObservationCompleteness,
    pub connection_error: Option<u64>,
}

/// Immutable connection and field-representation data at request-head delivery.
#[derive(Debug, Clone)]
pub struct H3RequestObservation {
    /// The request stream that owns these field representations.
    pub stream_id: u64,
    pub connection: Arc<H3ObservationSnapshot>,
    /// Published after the first head, peer SETTINGS, the available CONTROL
    /// chunk, and currently ready peer unidirectional type classification.
    /// QPACK instructions stay fixed at the first decoded head. Stream/control
    /// events describe native processing/publication, not packet chronology;
    /// optional streams never require waiting for future bytes. The boundary
    /// is independent of which request an optional collector selects. Pending
    /// or unavailable observations never imply a complete connection prefix.
    pub first_request: Arc<OnceLock<Arc<H3ObservationSnapshot>>>,
    pub fields: Vec<ObservedFieldRepresentation>,
    pub fields_complete: bool,
    pub priority: Option<Box<[u8]>>,
}
impl Extension for H3RequestObservation {}

/// SETTINGS availability, separate from the reason a consumer stopped waiting.
#[derive(Debug, Clone, Copy, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum SettingsStatus {
    Pending,
    Received,
    Incomplete,
    TimedOut,
    Closed,
    Unavailable,
}

impl SettingsStatus {
    #[must_use]
    pub fn for_snapshot(self, snapshot: &H3ObservationSnapshot) -> Self {
        if !snapshot.completeness.snapshot {
            Self::Unavailable
        } else if snapshot.completeness.settings {
            Self::Received
        } else if snapshot.settings_received || matches!(self, Self::Received) {
            Self::Incomplete
        } else {
            self
        }
    }
}

impl core::fmt::Display for SettingsStatus {
    fn fmt(&self, f: &mut core::fmt::Formatter<'_>) -> core::fmt::Result {
        f.write_str(match self {
            Self::Pending => "pending",
            Self::Received => "received",
            Self::Incomplete => "incomplete",
            Self::TimedOut => "timed_out",
            Self::Closed => "closed",
            Self::Unavailable => "unavailable",
        })
    }
}

/// Additive echo/fingerprint view. Missing SETTINGS remain `null`, with an explicit status.
#[derive(Debug, Serialize)]
pub struct H3ObservationView<'a> {
    pub request_stream_id: u64,
    pub connection_revision: u64,
    pub request_revision: u64,
    pub settings_status: SettingsStatus,
    pub settings: &'a Option<Vec<ObservedSetting>>,
    pub local_settings: &'a [ObservedSetting],
    pub streams: &'a [ObservedUniStream],
    pub control: &'a [ObservedControlFrame],
    pub qpack: &'a [ObservedEncoderInstruction],
    pub priorities: &'a Option<Box<[u8]>>,
    pub pseudo_headers: Option<&'a PseudoHeaderOrder>,
    pub request_fields: &'a [ObservedFieldRepresentation],
    pub completeness: ObservationCompleteness,
}

impl H3RequestObservation {
    #[must_use]
    pub fn view<'a>(
        &'a self,
        connection: &'a H3ObservationSnapshot,
        settings_status: SettingsStatus,
        pseudo_headers: Option<&'a PseudoHeaderOrder>,
    ) -> H3ObservationView<'a> {
        let mut completeness = connection.completeness;
        completeness.fields = self.fields_complete;
        H3ObservationView {
            request_stream_id: self.stream_id,
            connection_revision: connection.revision,
            request_revision: self.connection.revision,
            settings_status: settings_status.for_snapshot(connection),
            settings: &connection.settings,
            local_settings: &connection.local_settings,
            streams: &connection.streams,
            control: &connection.control,
            qpack: &connection.encoder_instructions,
            priorities: &self.priority,
            pseudo_headers,
            request_fields: &self.fields,
            completeness,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn observation_settings_status_reflects_retained_completeness() {
        let mut snapshot = H3ObservationSnapshot::default();
        assert!(matches!(
            SettingsStatus::Received.for_snapshot(&snapshot),
            SettingsStatus::Unavailable
        ));
        snapshot.completeness.snapshot = true;
        assert!(matches!(
            SettingsStatus::Received.for_snapshot(&snapshot),
            SettingsStatus::Incomplete
        ));
        assert!(matches!(
            SettingsStatus::Pending.for_snapshot(&snapshot),
            SettingsStatus::Pending
        ));
        snapshot.settings_received = true;
        assert!(matches!(
            SettingsStatus::Pending.for_snapshot(&snapshot),
            SettingsStatus::Incomplete
        ));
        snapshot.completeness.settings = true;
        for status in [
            SettingsStatus::Pending,
            SettingsStatus::Received,
            SettingsStatus::TimedOut,
            SettingsStatus::Closed,
        ] {
            assert!(matches!(
                status.for_snapshot(&snapshot),
                SettingsStatus::Received
            ));
        }
    }
}
