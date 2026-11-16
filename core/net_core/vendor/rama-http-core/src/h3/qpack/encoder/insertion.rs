//! Explicit current-field insertions, planned before mutating compression state.

use super::{Encoder, Input, QpackError, static_name};
use crate::h3::{
    qlog::qpack::Instruction,
    qpack::dynamic_table::{InsertError, entry_size},
};
use rama_core::{bytes::Bytes, telemetry::tracing::debug};
use rama_http_types::proto::h3::qpack::{
    encoding::{InsertionNameEncoding, InsertionPreferences},
    prefix::{StringEncoder, encode_int, int_encoded_len},
    static_table,
};

enum Name<'a> {
    Static(u64),
    Literal(StringEncoder<'a>),
}

pub(super) struct Insertion<'a> {
    name: &'a [u8],
    value: &'a [u8],
    name_wire: Name<'a>,
    value_wire: StringEncoder<'a>,
    allow_duplicate: bool,
}

impl<'a> Insertion<'a> {
    pub(super) fn prepare(
        encoder: &Encoder,
        name: &'a [u8],
        value: &'a [u8],
        preferences: InsertionPreferences,
    ) -> Self {
        let automatic = || static_table::find_name(name).map(|index| index as u64);
        let name_index = match preferences.name_encoding {
            InsertionNameEncoding::Automatic => automatic(),
            InsertionNameEncoding::Literal => None,
            InsertionNameEncoding::StaticName(index) if static_name(index) == Some(name) => {
                Some(index)
            }
            InsertionNameEncoding::StaticName(index) => {
                debug!(
                    index,
                    "QPACK: insertion static name names another field; encoding natively"
                );
                automatic()
            }
        };
        Self {
            name,
            value,
            name_wire: match name_index {
                Some(index) => Name::Static(index),
                None => Name::Literal(encoder.literal_string(name, 5, preferences.name_huffman)),
            },
            value_wire: encoder.literal_string(value, 7, preferences.value_huffman),
            allow_duplicate: preferences.name_encoding == InsertionNameEncoding::Automatic
                && preferences.name_huffman.is_none()
                && preferences.value_huffman.is_none(),
        }
    }

    pub(super) fn matches(&self, name: &[u8], value: Option<&[u8]>) -> bool {
        self.name == name && value.is_none_or(|value| self.value == value)
    }

    fn size(&self) -> u64 {
        entry_size(self.name, self.value)
    }

    fn wire_len(&self) -> Result<usize, QpackError> {
        let name = match &self.name_wire {
            Name::Static(index) => int_encoded_len(*index, 6),
            Name::Literal(name) => name.encoded_len(),
        };
        name.checked_add(self.value_wire.encoded_len())
            .ok_or(QpackError::EncodeFieldSectionLimit(
                "insertion output length overflow",
            ))
    }

    fn apply(self, encoder: &mut Encoder) -> Result<(), InsertError> {
        // Resolve against the live table, after earlier insertions in this batch.
        // Reserving the literal encoding above is conservative: only substitute a
        // Duplicate when it fits that reservation. Explicit wire choices stay literal.
        let duplicate = self
            .allow_duplicate
            .then(|| encoder.table.find(self.name, self.value))
            .flatten()
            .map(|absolute| encoder.table.insert_count() - absolute - 1)
            .filter(|relative| {
                self.wire_len()
                    .is_ok_and(|reserved| int_encoded_len(*relative, 5) <= reserved)
            });
        encoder.table.insert(
            Bytes::copy_from_slice(self.name),
            Bytes::copy_from_slice(self.value),
            Some(encoder.known_received_count),
        )?;
        if let Some(index) = duplicate {
            encode_int(&mut encoder.encoder_output, index, 5, 0);
            encoder.record_instruction(
                "rama_qpack:instruction_created",
                Instruction::Duplicate { index },
            );
            return Ok(());
        }
        let metadata = encoder.qlog.as_ref().map(|_| match &self.name_wire {
            Name::Static(index) => Instruction::InsertNameReference {
                is_static: true,
                index: *index,
            },
            Name::Literal(_) => Instruction::InsertLiteralName,
        });
        match self.name_wire {
            Name::Static(index) => encode_int(&mut encoder.encoder_output, index, 6, 0xc0),
            Name::Literal(name) => name.encode(&mut encoder.encoder_output, 0x40),
        }
        self.value_wire.encode(&mut encoder.encoder_output, 0);
        if let Some(instruction) = metadata {
            encoder.record_instruction("rama_qpack:instruction_created", instruction);
        }
        Ok(())
    }
}

pub(super) struct Plan<'a> {
    initialize_capacity: Option<u64>,
    insertions: Vec<Insertion<'a>>,
}

impl<'a> Plan<'a> {
    pub(super) fn prepare<'preferences, N, V>(
        encoder: &Encoder,
        input: &'a [Input<'preferences, N, V>],
        count: usize,
    ) -> Result<Self, QpackError>
    where
        N: AsRef<[u8]>,
        V: AsRef<[u8]>,
    {
        let mut insertions = Vec::with_capacity(count);
        for Input {
            field, preferences, ..
        } in input
        {
            // Preflight already dropped insertions of never-index fields.
            if let Some(preferences) = encoder.active_insertion(preferences) {
                insertions.push(Insertion::prepare(
                    encoder,
                    field.name.as_ref(),
                    field.value.as_ref(),
                    preferences,
                ));
            }
        }
        Self::prepare_batch(encoder, insertions, encoder.known_received_count)
    }

    /// Validate a borrowed insertion batch without changing table or output state.
    /// `protected` also prevents evicting entries selected by the current section
    /// before its references have been committed.
    pub(super) fn prepare_batch(
        encoder: &Encoder,
        insertions: Vec<Insertion<'a>>,
        protected: u64,
    ) -> Result<Self, QpackError> {
        if insertions.is_empty() {
            return Ok(Self {
                initialize_capacity: None,
                insertions,
            });
        }
        let capacity = if encoder.capacity_initialized {
            encoder.table.capacity()
        } else {
            encoder.config.target_capacity
        };
        let initialize_capacity = (!encoder.capacity_initialized).then_some(capacity);
        let mut wire_bytes = initialize_capacity.map_or(0, |capacity| int_encoded_len(capacity, 5));
        let mut entry_bytes = 0u64;
        for insertion in &insertions {
            wire_bytes = wire_bytes.checked_add(insertion.wire_len()?).ok_or(
                QpackError::EncodeFieldSectionLimit("insertion output length overflow"),
            )?;
            entry_bytes = entry_bytes.checked_add(insertion.size()).ok_or(
                QpackError::EncodeFieldSectionLimit("insertion table size overflow"),
            )?;
        }
        let count = u64::try_from(insertions.len())
            .map_err(|_error| QpackError::EncodeFieldSectionLimit("insertion count overflow"))?;
        encoder
            .table
            .can_insert_batch(capacity, count, entry_bytes, protected)
            .map_err(|_error| {
                QpackError::StreamResourceLimit(
                    "explicit insertions exceed table capacity or references",
                )
            })?;
        if !encoder.output_fits(wire_bytes) {
            return Err(QpackError::OutputBlocked);
        }
        Ok(Self {
            initialize_capacity,
            insertions,
        })
    }

    pub(super) fn apply(self, encoder: &mut Encoder) -> Result<(), QpackError> {
        if let Some(capacity) = self.initialize_capacity {
            if !encoder.table.set_capacity(capacity) {
                return Err(QpackError::ResourceLimit(
                    "insertion capacity exceeds peer maximum",
                ));
            }
            encoder.capacity_initialized = true;
            encode_int(&mut encoder.encoder_output, capacity, 5, 0x20);
            encoder.record_instruction(
                "rama_qpack:instruction_created",
                Instruction::SetCapacity { capacity },
            );
        }
        for insertion in self.insertions {
            // Only protocol table entries own copies. The plan borrows the current
            // fields and releases those borrows before ordinary field encoding.
            insertion.apply(encoder).map_err(|_error| {
                QpackError::ResourceLimit("insertion plan no longer fits the table")
            })?;
        }
        Ok(())
    }
}

/// Opportunistic compression uses the same literal planning and table commit as
/// explicit insertions, retaining its existing allocation-free rejection path.
pub(super) fn try_insert(encoder: &mut Encoder, name: &[u8], value: &[u8]) -> bool {
    if encoder
        .table
        .can_insert(entry_size(name, value), Some(encoder.known_received_count))
        .is_err()
    {
        return false;
    }
    let insertion = Insertion::prepare(encoder, name, value, InsertionPreferences::default());
    let Ok(length) = insertion.wire_len() else {
        return false;
    };
    encoder.output_fits(length) && insertion.apply(encoder).is_ok()
}
