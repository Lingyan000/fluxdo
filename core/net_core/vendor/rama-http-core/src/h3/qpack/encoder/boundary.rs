//! Transactional insertion planning for explicitly positioned dynamic references.
//!
//! Only the opt-in field-Base policy enters this path. Entries borrow current
//! fields until commit; the ordinary encoder keeps its original allocation path.
//! A field whose positioned reference cannot be planned uses its native encoding.

use super::insertion::{self, Insertion};
use super::{Encoder, FieldEncoding, InitialSection, Input, QpackError, STREAM_CLASS_MASK};
use rama_core::telemetry::tracing::debug;
use rama_http_types::proto::h3::qpack::encoding::{InsertionPreferences, Representation};

fn after_base(representation: Representation) -> bool {
    matches!(
        representation,
        Representation::DynamicIndexAfterBase | Representation::LiteralDynamicNameAfterBase
    )
}

fn name_only(representation: Representation) -> bool {
    matches!(
        representation,
        Representation::LiteralDynamicName
            | Representation::LiteralDynamicNameBeforeBase
            | Representation::LiteralDynamicNameAfterBase
    )
}

pub(super) struct Plan<'a> {
    insertions: insertion::Plan<'a>,
    encodings: Vec<FieldEncoding>,
    base: u64,
}

impl<'a> Plan<'a> {
    pub(super) fn prepare<'preferences, N: AsRef<[u8]>, V: AsRef<[u8]>>(
        encoder: &Encoder,
        stream_id: u64,
        input: &'a [Input<'preferences, N, V>],
    ) -> Result<Self, QpackError> {
        Self::prepare_with(encoder, stream_id, input, true).or_else(|error| {
            debug!(%error, "QPACK: field Base insertions do not fit; referencing existing entries only");
            Self::prepare_with(encoder, stream_id, input, false)
        })
    }

    fn prepare_with<'preferences, N: AsRef<[u8]>, V: AsRef<[u8]>>(
        encoder: &Encoder,
        stream_id: u64,
        input: &'a [Input<'preferences, N, V>],
        insert: bool,
    ) -> Result<Self, QpackError> {
        let mut insertions = Vec::new();
        let mut encodings = vec![FieldEncoding::LiteralName; input.len()];
        let mut base = 0;
        let was_blocking = encoder.is_stream_blocking(stream_id);
        let may_block =
            was_blocking || encoder.blocking_streams < encoder.config.max_blocked_streams;
        let cancelled = encoder.cancelled_through[(stream_id & STREAM_CLASS_MASK) as usize]
            .is_some_and(|cancelled| stream_id <= cancelled);
        let may_track = encoder.initial_section != InitialSection::Deferred
            && encoder.section_count < encoder.config.max_outstanding_sections
            && !cancelled;
        let start = encoder.table.insert_count();

        // Explicit insertions keep their supplied order, including initial-section
        // Bootstrap insertions. Referencing them later must respect the same Base.
        if insert {
            for Input {
                field, preferences, ..
            } in input
            {
                if let Some(preferences) = encoder.active_insertion(preferences) {
                    insertions.push(Insertion::prepare(
                        encoder,
                        field.name.as_ref(),
                        field.value.as_ref(),
                        preferences,
                    ));
                }
            }
        }

        let mut references = 0usize;
        let mut protected = encoder.known_received_count;
        // Pre-Base references establish a lower bound. Post-Base references are
        // resolved afterward, independently of their emitted header positions.
        for post in [false, true] {
            for (ordinal, input) in input.iter().enumerate() {
                let Input {
                    field, preferences, ..
                } = input;
                let representation = preferences.representation;
                if after_base(representation) != post {
                    continue;
                }
                let name = field.name.as_ref();
                let value = field.value.as_ref();
                let native = FieldEncoding::native(name, value, field.never_index);
                if !post {
                    match representation {
                        Representation::LiteralName => continue,
                        Representation::LiteralStaticName(index) => {
                            encodings[ordinal] = FieldEncoding::LiteralStaticName(index);
                            continue;
                        }
                        Representation::Automatic => {
                            encodings[ordinal] = native;
                            continue;
                        }
                        _ => (),
                    }
                }
                let fallback = |reason: &'static str| {
                    debug!(
                        ?representation,
                        reason, "QPACK: positioned reference unavailable; encoding natively"
                    );
                    native
                };
                if field.never_index || !may_track {
                    encodings[ordinal] = fallback("not trackable");
                    continue;
                }
                let Some(counted) = references.checked_add(1).filter(|count| {
                    *count
                        <= encoder
                            .config
                            .max_outstanding_references
                            .saturating_sub(encoder.reference_count)
                }) else {
                    encodings[ordinal] = fallback("reference budget");
                    continue;
                };
                let only_name = name_only(representation);
                let wanted = (!only_name).then_some(value);
                let planned = insertions
                    .iter()
                    .enumerate()
                    .rev()
                    .find(|(_, insertion)| insertion.matches(name, wanted))
                    .map(|(index, _)| {
                        start
                            .checked_add(index as u64)
                            .ok_or(QpackError::EncodeFieldSectionLimit(
                                "field Base insertion count overflow",
                            ))
                    })
                    .transpose()?
                    .filter(|abs| {
                        (*abs < encoder.known_received_count || may_block)
                            && (!post || *abs >= base)
                    });
                let existing = if only_name {
                    encoder.table.find_name(name)
                } else {
                    encoder.table.find(name, value)
                }
                .filter(|abs| {
                    (*abs < encoder.known_received_count || may_block) && (!post || *abs >= base)
                });
                let abs = if let Some(abs) = planned.or(existing) {
                    if abs < start {
                        protected = protected.min(abs);
                    }
                    abs
                } else {
                    if !insert {
                        encodings[ordinal] = fallback("no insertions");
                        continue;
                    }
                    // A caller's explicitly ordered insertion is not duplicated to
                    // evade an incompatible post-Base position.
                    if post && encoder.active_insertion(preferences).is_some() {
                        encodings[ordinal] = fallback("explicit insertion order");
                        continue;
                    }
                    if !may_block {
                        encodings[ordinal] = fallback("blocked-stream credit");
                        continue;
                    }
                    let abs = start.checked_add(insertions.len() as u64).ok_or(
                        QpackError::EncodeFieldSectionLimit("field Base insertion count overflow"),
                    )?;
                    insertions.push(Insertion::prepare(
                        encoder,
                        name,
                        if only_name { b"" } else { value },
                        InsertionPreferences::default(),
                    ));
                    abs
                };
                references = counted;
                if !post {
                    base = base.max(
                        abs.checked_add(1)
                            .ok_or(QpackError::EncodeFieldSectionLimit("field Base overflow"))?,
                    );
                }
                encodings[ordinal] = if only_name {
                    FieldEncoding::LiteralDynamicName(abs)
                } else {
                    FieldEncoding::DynamicIndex(abs)
                };
            }
        }

        Ok(Self {
            insertions: insertion::Plan::prepare_batch(encoder, insertions, protected)?,
            encodings,
            base,
        })
    }

    pub(super) fn apply(
        self,
        encoder: &mut Encoder,
    ) -> Result<(Vec<FieldEncoding>, u64), QpackError> {
        self.insertions.apply(encoder)?;
        Ok((self.encodings, self.base))
    }
}
