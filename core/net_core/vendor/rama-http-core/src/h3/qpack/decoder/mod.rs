//! The stateful QPACK decoder (RFC 9204 §2.2): applies encoder-stream instructions to a dynamic
//! table, decodes field sections against it, tracks blocked streams within a budget, and produces
//! the decoder-stream acknowledgements the peer's encoder needs.
//!
//! HTTP semantic validation is deliberately *not* performed here: the decoder emits raw field lines
//! and always advances its compression state, so a message that is later rejected for HTTP reasons
//! cannot desynchronize QPACK (RFC 9204 §2.2, and the sprint's separation requirement).

use std::collections::{BTreeMap, VecDeque};

use rama_core::bytes::{Buf, Bytes, BytesMut};
use rama_http_types::proto::h3::qpack::prefix::int_encoded_len;
use rama_http_types::proto::h3::qpack::{
    DecoderInstruction, EncoderInstruction, FieldLine, HeaderPrefix, PrefixError, static_table,
};
use rama_http_types::proto::h3::{
    VarInt,
    observation::{
        InsertionFieldMatch, ObservationLimits, ObservedEncoderBindings,
        ObservedEncoderInstruction, ObservedFieldRepresentation, ObservedInsertionBinding,
    },
};
use rama_quic::qlog::ConnectionQlogControl;
use rama_utils::octets::{kib, kib_u64};

use super::dynamic_table::{DynamicTable, ENTRY_OVERHEAD, InsertError};
use super::error::QpackError;
use crate::h3::qlog::{
    PeerEventBudget, QPACK_INSTRUCTION_EVENTS,
    qpack::{self as metadata, Instruction},
};

/// A decoded field line (raw bytes; HTTP validation happens elsewhere).
#[derive(Clone, PartialEq, Eq, Debug)]
pub struct FieldPair {
    /// The field name.
    pub name: Bytes,
    /// The field value.
    pub value: Bytes,
    /// Whether intermediaries must preserve the never-index (N) bit when forwarding.
    pub never_index: bool,
}

/// Configuration limits for a [`Decoder`].
#[derive(Clone, Copy, Debug)]
pub struct DecoderConfig {
    /// The maximum dynamic-table capacity to advertise (`SETTINGS_QPACK_MAX_TABLE_CAPACITY`).
    pub max_table_capacity: u64,
    /// The maximum number of streams that may be blocked at once (`SETTINGS_QPACK_BLOCKED_STREAMS`).
    pub max_blocked_streams: u64,
    /// The maximum decoded field-section size, and the bound on any single decoded string.
    pub max_field_section_size: usize,
    /// The maximum number of field lines in one decoded field section: the size accounting
    /// (32 octets per line) under-counts the map entries that many tiny lines produce.
    pub max_field_lines: usize,
    /// Maximum retained field-section payload plus `size_of::<BlockedSection>()` per section.
    /// Collection capacity has bounded constant-factor overhead beyond this accounting.
    pub max_blocked_bytes: usize,
    /// Maximum queued decoder-stream bytes; drain output before retrying `OutputBlocked`.
    /// A zero budget disables output. Small budgets require smaller encoder-stream input batches.
    /// An acknowledgment or cancellation that cannot fit even an empty queue returns
    /// `ResourceLimit`; ten bytes suffice for any valid QUIC stream identifier.
    pub max_decoder_stream_bytes: usize,
}

impl Default for DecoderConfig {
    fn default() -> Self {
        Self {
            max_table_capacity: kib_u64(4),
            max_blocked_streams: 16,
            max_field_section_size: kib(64),
            // Browsers send tens of lines; cookie crumbs (up to ~180 per site) still fit.
            max_field_lines: 512,
            max_blocked_bytes: kib(256),
            max_decoder_stream_bytes: kib(64),
        }
    }
}

struct BlockedSection {
    /// The prefix reconstructed when the section first arrived. It is kept rather than recomputed on
    /// resume: reconstruction (RFC 9204 §4.5.1.1) depends on the insert count at read time, which
    /// grows before the section unblocks, so re-decoding it later would yield a different value.
    prefix: HeaderPrefix,
    /// The field-line bytes (the section after its prefix).
    body: Bytes,
    /// The retained byte size, for the blocked-storage budget.
    size: usize,
}

/// A stateful QPACK decoder for one connection.
pub struct Decoder {
    qlog: Option<ConnectionQlogControl>,
    /// Every decoder instruction answers peer input, so all of them share one budget.
    qlog_budget: PeerEventBudget,
    observation: Option<Box<DecoderObservation>>,
    config: DecoderConfig,
    table: DynamicTable,
    /// Retained, not-yet-complete bytes of the peer's encoder stream.
    encoder_stream: BytesMut,
    /// Queued decoder-stream instructions to send to the peer's encoder.
    decoder_output: BytesMut,
    output_in_flight: usize,
    /// Field sections waiting for the Required Insert Count to be reached, in arrival order per
    /// stream so a stream's sections are still delivered in order.
    blocked: BTreeMap<u64, VecDeque<BlockedSection>>,
    /// Total bytes retained in `blocked`.
    blocked_bytes: usize,
}

#[derive(Debug)]
struct DecoderObservation {
    limits: ObservationLimits,
    instructions: Vec<ObservedEncoderInstruction>,
    initial_insert_count: u64,
    bindings: Option<ObservedEncoderBindings>,
    fields: BTreeMap<u64, Vec<ObservedFieldRepresentation>>,
    field_bytes: usize,
    complete: bool,
}

impl Decoder {
    pub(crate) fn set_qlog(&mut self, control: Option<ConnectionQlogControl>) {
        self.qlog = control;
    }

    fn record_instruction(&self, name: &'static str, instruction: Instruction) {
        let budget = Some(&self.qlog_budget);
        metadata::instruction(self.qlog.as_ref(), budget, name, instruction, || {
            (self.table.insert_count(), self.table.capacity())
        });
    }

    pub(crate) fn observe(&mut self, limits: ObservationLimits) {
        self.observation = Some(Box::new(DecoderObservation {
            limits,
            instructions: Vec::new(),
            initial_insert_count: self.table.insert_count(),
            bindings: None,
            fields: BTreeMap::new(),
            field_bytes: 0,
            complete: true,
        }));
    }

    pub(crate) fn take_field_observation(
        &mut self,
        stream_id: u64,
    ) -> Option<Vec<ObservedFieldRepresentation>> {
        let observation = self.observation.as_mut()?;
        let fields = observation.fields.remove(&stream_id)?;
        observation.field_bytes -= fields.len() * size_of::<ObservedFieldRepresentation>();
        Some(fields)
    }

    pub(crate) fn instruction_observation(&self) -> Option<(&[ObservedEncoderInstruction], bool)> {
        self.observation
            .as_ref()
            .map(|o| (o.instructions.as_slice(), o.complete))
    }

    pub(crate) fn encoder_bindings(&self) -> Option<&ObservedEncoderBindings> {
        self.observation.as_ref()?.bindings.as_ref()
    }

    /// Associate retained insertions with the initial request while both sets of
    /// octets already exist. Later requests cannot replace this boundary.
    pub(crate) fn bind_initial_request(&mut self, stream_id: u64, fields: &[FieldPair]) {
        let Some(capture) = &mut self.observation else {
            return;
        };
        if capture.bindings.is_some() {
            return;
        }
        let used = capture.instructions.len() * size_of::<ObservedEncoderInstruction>();
        let available = capture
            .limits
            .bytes
            .saturating_sub(used.saturating_add(size_of::<ObservedEncoderBindings>()))
            / size_of::<ObservedInsertionBinding>();
        let mut bindings = ObservedEncoderBindings {
            stream_id,
            insertions: Vec::new(),
            complete: capture.complete && fields.len() <= capture.limits.fields,
        };
        let mut insertion_index = capture.initial_insert_count;
        for (instruction_index, instruction) in capture.instructions.iter().enumerate() {
            if matches!(instruction, ObservedEncoderInstruction::Capacity { .. }) {
                continue;
            }
            if bindings.insertions.len() >= available {
                bindings.complete = false;
                break;
            }
            let field = if fields.len() > capture.limits.fields {
                InsertionFieldMatch::Unavailable
            } else if let Some((name, value)) = self.table.get_ref(insertion_index) {
                let mut matches = fields.iter().enumerate().filter(|(_, field)| {
                    field.name.as_ref() == name && field.value.as_ref() == value
                });
                match (matches.next(), matches.next()) {
                    (Some((field_index, _)), None) => InsertionFieldMatch::Unique { field_index },
                    (Some(_), Some(_)) => InsertionFieldMatch::Ambiguous,
                    _ => InsertionFieldMatch::Absent,
                }
            } else {
                InsertionFieldMatch::Evicted
            };
            bindings.insertions.push(ObservedInsertionBinding {
                instruction_index,
                insertion_index,
                field,
            });
            // Successful table insertion already rejected counter overflow.
            insertion_index += 1;
        }
        capture.bindings = Some(bindings);
    }

    /// Create a decoder with the given limits.
    #[must_use]
    pub fn new(config: DecoderConfig) -> Self {
        Self {
            observation: None,
            qlog: None,
            qlog_budget: PeerEventBudget::new("qpack_instructions", QPACK_INSTRUCTION_EVENTS),
            table: DynamicTable::new(config.max_table_capacity),
            config,
            encoder_stream: BytesMut::new(),
            decoder_output: BytesMut::new(),
            output_in_flight: 0,
            blocked: BTreeMap::new(),
            blocked_bytes: 0,
        }
    }

    /// The decoder's current dynamic-table insert count.
    #[must_use]
    pub fn insert_count(&self) -> u64 {
        self.table.insert_count()
    }

    /// The number of currently blocked streams.
    #[must_use]
    pub fn blocked_stream_count(&self) -> usize {
        self.blocked
            .values()
            .filter(|queue| {
                queue
                    .iter()
                    .any(|section| section.prefix.required_insert_count > self.table.insert_count())
            })
            .count()
    }

    /// Take the queued decoder-stream bytes to send to the peer, leaving the queue empty.
    pub fn take_decoder_stream(&mut self) -> Bytes {
        self.decoder_output.split().freeze()
    }

    pub(crate) fn take_output_for_write(&mut self) -> Bytes {
        let output = self.take_decoder_stream();
        self.output_in_flight += output.len();
        output
    }

    pub(crate) fn output_written(&mut self, bytes: usize) {
        self.output_in_flight -= bytes;
    }

    /// The maximum size a full encoder-stream instruction may occupy before it is rejected as a
    /// resource-exhaustion attempt. Strings are bounded by both the field-section limit and
    /// the current dynamic-table capacity. Huffman codes occupy up to 30 bits per byte, so two strings need
    /// at most eight times that limit plus integer headers.
    fn max_instruction_bytes(&self) -> usize {
        self.max_insert_string_len()
            .saturating_mul(8)
            .saturating_add(64)
    }

    /// No inserted string can exceed the current table capacity minus entry overhead.
    /// Reject impossible inserts before retaining or decoding their literal payloads.
    fn max_insert_string_len(&self) -> usize {
        self.config.max_field_section_size.min(
            usize::try_from(self.table.capacity().saturating_sub(ENTRY_OVERHEAD))
                .unwrap_or(usize::MAX),
        )
    }

    /// Feed bytes received on the peer's encoder stream, applying every complete instruction.
    ///
    /// Retains a trailing partial instruction for the next call (transactional), and emits Insert
    /// Count Increment for entries inserted. Any newly unblocked streams should then be collected
    /// with [`Decoder::resume_blocked`]. `OutputBlocked` consumes no input: drain the decoder
    /// stream and retry. If the queue is already empty, split the input into smaller batches:
    /// reservation bounds the increment by the input byte count. Other errors are fatal connection
    /// errors; do not retry them.
    pub fn feed_encoder_stream(&mut self, input: &[u8]) -> Result<(), QpackError> {
        // Every completed insertion needs at least one newly supplied byte, including completion
        // of a retained instruction. Reserve the resulting upper bound before consuming input.
        if input.is_empty() {
            return Ok(());
        }
        self.reserve_output(int_encoded_len(input.len() as u64, 6))?;
        let mut input = input;
        let mut inserted = 0u64;
        loop {
            if self.encoder_stream.is_empty() {
                match EncoderInstruction::encoded_len(input, self.max_insert_string_len()) {
                    Ok(len) => {
                        let mut cursor = &input[..len];
                        let inst =
                            EncoderInstruction::decode(&mut cursor, self.max_insert_string_len())
                                .map_err(encoder_parse_error)?;
                        if self.apply_encoder_instruction(inst)? {
                            inserted += 1;
                        }
                        input = &input[len..];
                        if input.is_empty() {
                            break;
                        }
                        continue;
                    }
                    Err(PrefixError::UnexpectedEnd) => {}
                    Err(error) => return Err(encoder_parse_error(error)),
                }
            }
            let available = self
                .max_instruction_bytes()
                .saturating_sub(self.encoder_stream.len());
            let append = input.len().min(available);
            self.encoder_stream.extend_from_slice(&input[..append]);
            input = &input[append..];
            loop {
                match EncoderInstruction::encoded_len(
                    &self.encoder_stream,
                    self.max_insert_string_len(),
                ) {
                    Ok(len) => {
                        // Table entries must own compact literals rather than pinning the whole
                        // staging buffer through a tiny Bytes slice.
                        let mut cursor = &self.encoder_stream[..len];
                        let inst =
                            EncoderInstruction::decode(&mut cursor, self.max_insert_string_len())
                                .map_err(encoder_parse_error)?;
                        if self.apply_encoder_instruction(inst)? {
                            inserted += 1;
                        }
                        self.encoder_stream.advance(len);
                    }
                    Err(PrefixError::UnexpectedEnd) => break,
                    Err(error) => return Err(encoder_parse_error(error)),
                }
            }
            if self.encoder_stream.len() >= self.max_instruction_bytes() {
                return Err(QpackError::ResourceLimit(
                    "encoder-stream instruction too large",
                ));
            }
            if input.is_empty() {
                break;
            }
        }
        if inserted > 0 {
            DecoderInstruction::InsertCountIncrement {
                increment: inserted,
            }
            .encode(&mut self.decoder_output);
            self.record_instruction(
                "rama_qpack:instruction_created",
                Instruction::InsertCountIncrement {
                    increment: inserted,
                },
            );
        }
        Ok(())
    }

    fn reserve_output(&self, bytes: usize) -> Result<(), QpackError> {
        if bytes
            > self
                .config
                .max_decoder_stream_bytes
                .saturating_sub(self.decoder_output.len())
                .saturating_sub(self.output_in_flight)
        {
            return Err(QpackError::OutputBlocked);
        }
        Ok(())
    }

    fn reserve_instruction(&self, instruction: DecoderInstruction) -> Result<(), QpackError> {
        // A prefixed u64 occupies at most eleven bytes, so measuring it needs no heap allocation.
        let mut encoded = [0; 11];
        let mut dst = &mut encoded[..];
        instruction.encode(&mut dst);
        let len = 11 - dst.len();
        if len > self.config.max_decoder_stream_bytes {
            return Err(QpackError::ResourceLimit(
                "decoder instruction exceeds output budget",
            ));
        }
        self.reserve_output(len)
    }

    /// Apply one encoder-stream instruction. Returns whether it inserted an entry.
    fn apply_encoder_instruction(&mut self, inst: EncoderInstruction) -> Result<bool, QpackError> {
        let instruction_metadata = self.qlog.as_ref().map(|_| Instruction::encoder(&inst));
        let observed = self
            .observation
            .as_ref()
            .map(|_| ObservedEncoderInstruction::from(&inst));
        let result = match inst {
            EncoderInstruction::SetDynamicTableCapacity { capacity } => {
                if !self.table.set_capacity(capacity) {
                    return Err(QpackError::EncoderStreamError(
                        "dynamic table capacity exceeds the advertised maximum",
                    ));
                }
                Ok(false)
            }
            EncoderInstruction::InsertWithNameRef {
                is_static,
                name_index,
                value,
                value_huffman,
            } => {
                let name = if is_static {
                    usize::try_from(name_index)
                        .ok()
                        .and_then(static_table::get)
                        .ok_or(QpackError::EncoderStreamError("bad static name index"))?
                        .0
                        .into()
                } else {
                    // encoder-stream relative index: abs = insert_count - 1 - rel
                    let abs = self.encoder_relative_to_abs(name_index)?;
                    self.table
                        .get(abs)
                        .ok_or(QpackError::EncoderStreamError("bad dynamic name index"))?
                        .0
                };
                self.insert(name, compact_literal(value, value_huffman))
            }
            EncoderInstruction::InsertWithLiteralName {
                name,
                name_huffman,
                value,
                value_huffman,
            } => self.insert(
                compact_literal(name, name_huffman),
                compact_literal(value, value_huffman),
            ),
            EncoderInstruction::Duplicate { index } => {
                let abs = self.encoder_relative_to_abs(index)?;
                let (name, value) = self
                    .table
                    .get(abs)
                    .ok_or(QpackError::EncoderStreamError("bad duplicate index"))?;
                self.insert(name, value)
            }
        };
        if result.is_ok()
            && let Some(instruction) = instruction_metadata
        {
            self.record_instruction("rama_qpack:instruction_parsed", instruction);
        }
        if result.is_ok()
            && let Some(observed) = observed
            && let Some(capture) = &mut self.observation
        {
            let binding_bytes = capture.bindings.as_ref().map_or(0, |bindings| {
                size_of::<ObservedEncoderBindings>()
                    + bindings.insertions.len() * size_of::<ObservedInsertionBinding>()
            });
            let bound = capture.limits.events.min(
                capture.limits.bytes.saturating_sub(binding_bytes)
                    / size_of::<ObservedEncoderInstruction>(),
            );
            if !matches!(observed, ObservedEncoderInstruction::Capacity { .. })
                && let Some(bindings) = &mut capture.bindings
            {
                bindings.complete = false;
            }
            if capture.instructions.len() < bound {
                capture.instructions.push(observed);
            } else {
                capture.complete = false;
            }
        }
        result
    }

    fn encoder_relative_to_abs(&self, rel: u64) -> Result<u64, QpackError> {
        // abs = insert_count - 1 - rel (RFC 9204 §3.2.5)
        self.table
            .insert_count()
            .checked_sub(1)
            .and_then(|top| top.checked_sub(rel))
            .ok_or(QpackError::EncoderStreamError("dynamic index out of range"))
    }

    /// Existing entries are shared, never copied, so re-inserting a large entry costs no allocation.
    fn insert(&mut self, name: Bytes, value: Bytes) -> Result<bool, QpackError> {
        match self.table.insert(name, value, None) {
            Ok(_) => Ok(true),
            Err(InsertError::TooLarge) => Err(QpackError::EncoderStreamError(
                "inserted entry exceeds table capacity",
            )),
            Err(InsertError::InsertCountOverflow) => {
                Err(QpackError::EncoderStreamError("insert count overflow"))
            }
            // the decoder never withholds eviction, so Blocked cannot occur
            Err(InsertError::Blocked) => Err(QpackError::EncoderStreamError("eviction blocked")),
        }
    }

    /// Decode a complete encoded field section received on stream `stream_id`.
    ///
    /// The full section must be buffered by the caller (the frame layer bounds its length first).
    /// Returns `Ok(Some(fields))` when it decodes immediately, or `Ok(None)` when it is blocked on
    /// the Required Insert Count, in which case it is retained (subject to the blocked budget) and
    /// returned later by [`Decoder::resume_blocked`].
    ///
    /// Immediately decoded literals share the supplied allocation. Queued sections are compacted
    /// to avoid retaining an arbitrarily large backing allocation through a small slice. Retain a
    /// cheap `Bytes` clone until success: `OutputBlocked` leaves state unchanged, so drain and retry.
    /// On `FieldSectionLimit` or `StreamResourceLimit`, queued sections for this stream are released.
    /// The caller must reset
    /// the stream and call [`Decoder::cancel_stream`] (draining and retrying if necessary) to notify
    /// the peer and release its references.
    #[expect(
        clippy::needless_pass_by_value,
        reason = "ownership shares immediately decoded literals with the supplied allocation"
    )]
    pub fn decode_field_section(
        &mut self,
        stream_id: u64,
        encoded: Bytes,
    ) -> Result<Option<Vec<FieldPair>>, QpackError> {
        validate_stream_id(stream_id)?;
        let mut cursor: &[u8] = &encoded;
        let insert_count = self.table.insert_count();
        let prefix = match HeaderPrefix::decode(&mut cursor, self.table.max_entries(), insert_count)
        {
            Ok(prefix) => prefix,
            Err(error) => {
                let error = QpackError::from(error);
                if matches!(error, QpackError::FieldSectionLimit(_)) {
                    self.drop_blocked_stream(stream_id);
                }
                return Err(error);
            }
        };
        let consumed = encoded.len() - cursor.len();
        let body = encoded.slice(consumed..);

        // If earlier sections on this stream are still blocked, this one queues behind them even if
        // its own Required Insert Count is already met, so the stream's sections stay in order.
        let already_blocked = self.blocked.get(&stream_id).is_some_and(|q| !q.is_empty());

        if !already_blocked && prefix.required_insert_count <= insert_count {
            return Ok(Some(self.decode_body(stream_id, &prefix, &body)?));
        }

        // blocked: enforce budgets before retaining
        let already_waiting_for_inserts = self.blocked.get(&stream_id).is_some_and(|queue| {
            queue
                .iter()
                .any(|section| section.prefix.required_insert_count > insert_count)
        });
        if prefix.required_insert_count > insert_count
            && !already_waiting_for_inserts
            && self.blocked_stream_count() as u64 >= self.config.max_blocked_streams
        {
            return Err(QpackError::DecompressionFailed("too many blocked streams"));
        }
        let size = encoded.len().saturating_add(size_of::<BlockedSection>());
        if self.blocked_bytes.saturating_add(size) > self.config.max_blocked_bytes {
            self.drop_blocked_stream(stream_id);
            return Err(QpackError::StreamResourceLimit(
                "blocked field-section storage exceeded",
            ));
        }
        let body = Bytes::copy_from_slice(&body);
        self.blocked_bytes += size;
        self.blocked
            .entry(stream_id)
            .or_default()
            .push_back(BlockedSection { prefix, body, size });
        metadata::section(
            self.qlog.as_ref(),
            "rama_qpack:field_section_blocked",
            stream_id,
            &prefix,
            None,
            Some(self.blocked_bytes),
        );
        Ok(None)
    }

    /// Discard feedback after the connection driver has stopped its writers.
    /// Buffered encoder instructions can still unblock complete received fields;
    /// transport output reservations must no longer prevent their decoding.
    pub(crate) fn discard_output_after_close(&mut self) {
        self.decoder_output.clear();
        self.output_in_flight = 0;
    }

    /// Decode buffered fields after connection close, when feedback can no longer be sent.
    /// Missing inserts remain terminal: do not retain a section that can never resume.
    pub(crate) fn decode_field_section_after_close(
        &mut self,
        stream_id: u64,
        encoded: Bytes,
    ) -> Result<Option<Vec<FieldPair>>, QpackError> {
        self.decoder_output.clear();
        let output_in_flight = std::mem::take(&mut self.output_in_flight);
        self.drop_blocked_stream(stream_id);
        let result = self.decode_field_section(stream_id, encoded);
        // A writer may complete an earlier write after this synchronous decode.
        // Preserve its reservation so that completion cannot underflow accounting.
        self.output_in_flight = output_in_flight;
        if result.as_ref().is_ok_and(Option::is_none) || result.is_err() {
            self.drop_blocked_stream(stream_id);
        }
        self.decoder_output.clear();
        result
    }

    /// Decode and remove blocked sections whose Required Insert Count is now satisfied.
    ///
    /// Each stream's sections are resumed front-first and only while the front is ready, so a
    /// stream's sections are never delivered out of order. A decode failure is reported per stream.
    /// `OutputBlocked` leaves the section queued; drain output before resuming again. A
    /// `FieldSectionLimit` and `StreamResourceLimit` release all queued sections for that stream; reset it and call
    /// [`Decoder::cancel_stream`] to release the peer's references.
    pub fn resume_blocked(&mut self) -> Vec<(u64, Result<Vec<FieldPair>, QpackError>)> {
        let insert_count = self.table.insert_count();
        let mut out = Vec::new();
        let stream_ids: Vec<u64> = self.blocked.keys().copied().collect();
        for stream_id in stream_ids {
            while let Some(section) = self.blocked.get(&stream_id).and_then(|q| q.front()) {
                if section.prefix.required_insert_count > insert_count {
                    break;
                }
                if section.prefix.required_insert_count > 0
                    && let Err(error) =
                        self.reserve_instruction(DecoderInstruction::SectionAcknowledgment {
                            stream_id,
                        })
                {
                    out.push((stream_id, Err(error)));
                    break;
                }
                let Some(section) = self.pop_ready_front(stream_id, insert_count) else {
                    break;
                };
                self.blocked_bytes -= section.size;
                let result = self.decode_body(stream_id, &section.prefix, &section.body);
                if matches!(
                    result,
                    Err(QpackError::FieldSectionLimit(_) | QpackError::StreamResourceLimit(_))
                ) {
                    self.drop_blocked_stream(stream_id);
                }
                out.push((stream_id, result));
            }
        }
        out
    }

    /// Resume at most one ready section without allocating a temporary result list.
    ///
    /// Call within the connection's work budget. `OutputBlocked` retains the section;
    /// drain decoder output before retrying. Ordering within each stream is preserved.
    pub fn resume_next(&mut self) -> Option<(u64, Result<Vec<FieldPair>, QpackError>)> {
        let insert_count = self.table.insert_count();
        let (&stream_id, queue) = self.blocked.iter().find(|(_, queue)| {
            queue
                .front()
                .is_some_and(|s| s.prefix.required_insert_count <= insert_count)
        })?;
        if queue.front()?.prefix.required_insert_count > 0
            && let Err(error) =
                self.reserve_instruction(DecoderInstruction::SectionAcknowledgment { stream_id })
        {
            return Some((stream_id, Err(error)));
        }
        let section = self.pop_ready_front(stream_id, insert_count)?;
        self.blocked_bytes -= section.size;
        let result = self.decode_body(stream_id, &section.prefix, &section.body);
        if matches!(
            result,
            Err(QpackError::FieldSectionLimit(_) | QpackError::StreamResourceLimit(_))
        ) {
            self.drop_blocked_stream(stream_id);
        }
        Some((stream_id, result))
    }

    /// Remove and return the front blocked section of `stream_id` when its Required Insert Count is
    /// satisfied, cleaning up the stream's queue when it empties.
    fn pop_ready_front(&mut self, stream_id: u64, insert_count: u64) -> Option<BlockedSection> {
        let queue = self.blocked.get_mut(&stream_id)?;
        let ready = queue
            .front()
            .is_some_and(|s| s.prefix.required_insert_count <= insert_count);
        if !ready {
            return None;
        }
        let section = queue.pop_front();
        if queue.is_empty() {
            self.blocked.remove(&stream_id);
        }
        if let Some(section) = &section {
            metadata::section(
                self.qlog.as_ref(),
                "rama_qpack:field_section_unblocked",
                stream_id,
                &section.prefix,
                None,
                Some(self.blocked_bytes.saturating_sub(section.size)),
            );
        }
        section
    }

    /// Decode a section's field lines against the current table and acknowledge it if it referenced
    /// the dynamic table (RFC 9204 §4.4.1).
    fn decode_body(
        &mut self,
        stream_id: u64,
        prefix: &HeaderPrefix,
        body: &Bytes,
    ) -> Result<Vec<FieldPair>, QpackError> {
        if prefix.required_insert_count > 0 {
            self.reserve_instruction(DecoderInstruction::SectionAcknowledgment { stream_id })?;
        }
        let fields = if self.observation.is_some() {
            self.decode_lines::<true>(stream_id, body.clone(), prefix)?
        } else {
            self.decode_lines::<false>(stream_id, body.clone(), prefix)?
        };
        if prefix.required_insert_count > 0 {
            DecoderInstruction::SectionAcknowledgment { stream_id }
                .encode(&mut self.decoder_output);
            self.record_instruction(
                "rama_qpack:instruction_created",
                Instruction::SectionAcknowledgment { stream_id },
            );
        }
        metadata::section(
            self.qlog.as_ref(),
            "rama_qpack:field_section_decoded",
            stream_id,
            prefix,
            Some(fields.len()),
            Some(self.blocked_bytes),
        );
        Ok(fields)
    }

    /// Cancel a stream: drop any blocked sections and emit Stream Cancellation (RFC 9204 §4.4.2).
    /// `OutputBlocked` leaves blocked sections intact; drain output and retry.
    pub fn cancel_stream(&mut self, stream_id: u64) -> Result<(), QpackError> {
        validate_stream_id(stream_id)?;
        self.reserve_instruction(DecoderInstruction::StreamCancellation { stream_id })?;
        self.drop_blocked_stream(stream_id);
        DecoderInstruction::StreamCancellation { stream_id }.encode(&mut self.decoder_output);
        self.record_instruction(
            "rama_qpack:instruction_created",
            Instruction::StreamCancellation { stream_id },
        );
        Ok(())
    }

    pub(crate) fn drop_blocked_stream(&mut self, stream_id: u64) {
        self.take_field_observation(stream_id);
        if let Some(queue) = self.blocked.remove(&stream_id) {
            for section in queue {
                self.blocked_bytes -= section.size;
            }
        }
    }

    fn decode_lines<const OBSERVE: bool>(
        &mut self,
        stream_id: u64,
        mut body: Bytes,
        prefix: &HeaderPrefix,
    ) -> Result<Vec<FieldPair>, QpackError> {
        // The disabled specialization has no representation collection or per-field branch.
        let mut observed = Vec::new();
        let bound = if OBSERVE {
            self.take_field_observation(stream_id);
            self.observation.as_ref().and_then(|capture| {
                (capture.fields.len() < capture.limits.pending_fields).then_some(
                    capture.limits.fields.min(
                        capture.limits.bytes.saturating_sub(capture.field_bytes)
                            / size_of::<ObservedFieldRepresentation>(),
                    ),
                )
            })
        } else {
            None
        };
        let mut fields = Vec::new();
        let mut section_size: u64 = 0;
        while body.has_remaining() {
            if fields.len() >= self.config.max_field_lines {
                return Err(QpackError::StreamResourceLimit("too many field lines"));
            }
            let line = FieldLine::decode_bytes(&mut body, self.config.max_field_section_size)?;
            if OBSERVE && bound.is_some_and(|bound| observed.len() < bound) {
                observed.push(ObservedFieldRepresentation::from(&line));
            }
            let pair = self.resolve_line(line, prefix)?;
            // account the uncompressed size (RFC 9114 §4.2.2: name + value + 32).
            section_size =
                section_size.saturating_add(pair.name.len() as u64 + pair.value.len() as u64 + 32);
            if section_size > self.config.max_field_section_size as u64 {
                return Err(QpackError::StreamResourceLimit("field section too large"));
            }
            fields.push(pair);
        }
        if OBSERVE
            && bound.is_some()
            && let Some(capture) = &mut self.observation
        {
            capture.field_bytes += observed.len() * size_of::<ObservedFieldRepresentation>();
            capture.fields.insert(stream_id, observed);
        }
        Ok(fields)
    }

    fn resolve_line(
        &self,
        line: FieldLine,
        prefix: &HeaderPrefix,
    ) -> Result<FieldPair, QpackError> {
        let base = prefix.base;
        let ric = prefix.required_insert_count;
        match line {
            FieldLine::Indexed { is_static, index } => {
                if is_static {
                    let (name, value) = static_get(index)?;
                    Ok(FieldPair {
                        name: name.into(),
                        value: value.into(),
                        never_index: false,
                    })
                } else {
                    let abs = pre_base_abs(base, index)?;
                    let (name, value) = self.dynamic_get(abs, ric)?;
                    Ok(FieldPair {
                        name,
                        value,
                        never_index: false,
                    })
                }
            }
            FieldLine::IndexedPostBase { index } => {
                let abs = post_base_abs(base, index)?;
                let (name, value) = self.dynamic_get(abs, ric)?;
                Ok(FieldPair {
                    name,
                    value,
                    never_index: false,
                })
            }
            FieldLine::LiteralWithNameRef {
                is_static,
                name_index,
                value,
                never_index,
                ..
            } => {
                let name = if is_static {
                    static_get(name_index)?.0.into()
                } else {
                    self.dynamic_get(pre_base_abs(base, name_index)?, ric)?.0
                };
                Ok(FieldPair {
                    name,
                    value,
                    never_index,
                })
            }
            FieldLine::LiteralWithPostBaseNameRef {
                name_index,
                value,
                never_index,
                ..
            } => {
                let name = self.dynamic_get(post_base_abs(base, name_index)?, ric)?.0;
                Ok(FieldPair {
                    name,
                    value,
                    never_index,
                })
            }
            FieldLine::LiteralWithLiteralName {
                name,
                value,
                never_index,
                ..
            } => Ok(FieldPair {
                name,
                value,
                never_index,
            }),
        }
    }

    // RFC 9204 section 2.2.1 requires rejecting an understated RIC but permits
    // accepting an overstated one. Keep that permissive policy: the declared
    // count still passes through normal blocked-stream and byte budgets, and
    // every actual reference must stay below it and resolve to a retained entry.
    fn dynamic_get(&self, abs: u64, ric: u64) -> Result<(Bytes, Bytes), QpackError> {
        if abs >= ric {
            return Err(QpackError::DecompressionFailed(
                "dynamic reference exceeds required insert count",
            ));
        }
        self.table.get(abs).ok_or(QpackError::DecompressionFailed(
            "reference to missing dynamic entry",
        ))
    }
}

/// Huffman output keeps the spare capacity it was decoded into, which table entries must not;
/// plain literals from [`EncoderInstruction::decode`] are already exact copies.
fn compact_literal(bytes: Bytes, huffman: bool) -> Bytes {
    if huffman {
        Bytes::copy_from_slice(&bytes)
    } else {
        bytes
    }
}

fn static_get(index: u64) -> Result<(&'static [u8], &'static [u8]), QpackError> {
    static_table::get(usize_index(index)?)
        .ok_or(QpackError::DecompressionFailed("static index out of range"))
}

/// Absolute index for a Base-relative dynamic reference (RFC 9204 §3.2.4): `Base - Index - 1`.
fn pre_base_abs(base: u64, index: u64) -> Result<u64, QpackError> {
    base.checked_sub(index)
        .and_then(|v| v.checked_sub(1))
        .ok_or(QpackError::DecompressionFailed(
            "dynamic index out of range",
        ))
}

/// Absolute index for a post-Base dynamic reference (RFC 9204 §3.2.6): `Base + Index`.
fn post_base_abs(base: u64, index: u64) -> Result<u64, QpackError> {
    base.checked_add(index)
        .ok_or(QpackError::DecompressionFailed("post-base index overflow"))
}

fn usize_index(index: u64) -> Result<usize, QpackError> {
    match usize::try_from(index) {
        Ok(i) => Ok(i),
        Err(_) => Err(QpackError::DecompressionFailed("index out of range")),
    }
}

fn encoder_parse_error(error: PrefixError) -> QpackError {
    match error {
        PrefixError::LengthLimitExceeded => {
            QpackError::EncoderStreamError("encoder-stream string too large")
        }
        _ => QpackError::EncoderStreamError("malformed encoder-stream instruction"),
    }
}

fn validate_stream_id(stream_id: u64) -> Result<(), QpackError> {
    VarInt::from_u64(stream_id)
        .map(|_| ())
        .map_err(|_error| QpackError::ResourceLimit("stream ID exceeds QUIC integer range"))
}

#[cfg(test)]
mod tests;
