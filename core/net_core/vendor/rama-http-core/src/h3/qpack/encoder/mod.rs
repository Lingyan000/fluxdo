//! Connection-scoped QPACK encoding, bounded reference tracking and decoder-stream feedback.

use std::{
    borrow::Cow,
    collections::{BTreeMap, VecDeque},
};

use rama_core::{
    bytes::{Bytes, BytesMut},
    telemetry::tracing::debug,
};
use rama_http_types::proto::h3::{
    VarInt,
    qpack::{
        DecoderInstruction, EncoderPreferences, FieldSectionBase, HeaderPrefix, PrefixError,
        encoding::{FieldPreferences, InsertionPreferences, InsertionScope, Representation},
        prefix::{StringEncoder, encode_int, int_encoded_len},
        static_table,
    },
};
use rama_quic::qlog::ConnectionQlogControl;
use rama_utils::octets::{kib, kib_u64};

use super::dynamic_table::{DynamicTable, ENTRY_OVERHEAD};
use super::{FieldPair, QpackError};
use crate::h3::qlog::{
    PeerEventBudget, QPACK_INSTRUCTION_EVENTS,
    qpack::{self as metadata, Instruction},
};

mod boundary;
mod insertion;

// RFC 9000 §2.1: the low bits identify the stream's initiator and direction.
const STREAM_CLASS_MASK: u64 = 0b11;
const STREAM_CLASS_COUNT: usize = (STREAM_CLASS_MASK + 1) as usize;

/// Encoder input preserving the never-index requirement across intermediary hops.
#[derive(Clone, Debug)]
pub struct EncodeField<'a, N, V> {
    /// Field name bytes.
    pub name: N,
    /// Field value bytes.
    pub value: V,
    /// Always emit a literal with N=1; never insert or fully index this field.
    pub never_index: bool,
    /// Borrowed field choices, consumed during encoding and never retained by the connection.
    pub preferences: Option<&'a FieldPreferences>,
}

impl<'a> EncodeField<'a, Cow<'a, [u8]>, &'a [u8]> {
    /// Encode a lowercase name and preserve [`rama_http_types::HeaderValue::is_sensitive`].
    /// Values and already-lowercase names remain borrowed. Mixed-case custom names
    /// are normalized only for the wire, without changing the original header map.
    #[must_use]
    pub fn from_header(
        name: &'a rama_http_types::HeaderName,
        value: &'a rama_http_types::HeaderValue,
    ) -> Self {
        Self {
            name: match name.as_lower_str() {
                Cow::Borrowed(name) => Cow::Borrowed(name.as_bytes()),
                Cow::Owned(name) => Cow::Owned(name.into_bytes()),
            },
            value: value.as_bytes(),
            never_index: value.is_sensitive(),
            preferences: None,
        }
    }
}

impl<'a, N, V> From<(N, V)> for EncodeField<'a, N, V> {
    fn from((name, value): (N, V)) -> Self {
        Self {
            name,
            value,
            never_index: false,
            preferences: None,
        }
    }
}

impl<'a> From<FieldPair> for EncodeField<'a, Bytes, Bytes> {
    fn from(field: FieldPair) -> Self {
        Self {
            name: field.name,
            value: field.value,
            never_index: field.never_index,
            preferences: None,
        }
    }
}

/// Configuration and local resource budgets for an [`Encoder`].
#[derive(Clone, Copy, Debug)]
pub struct EncoderConfig {
    /// The peer's SETTINGS_QPACK_MAX_TABLE_CAPACITY.
    pub max_table_capacity: u64,
    /// The peer's SETTINGS_QPACK_BLOCKED_STREAMS.
    pub max_blocked_streams: u64,
    /// Capacity to use, clamped to the peer maximum.
    pub target_capacity: u64,
    /// Allow Huffman encoding when it reduces a literal's wire size; plain encoding wins ties.
    pub huffman: bool,
    /// Start with a static/literal section, then permit ordinary dynamic compression.
    pub defer_dynamic_first_section: bool,
    /// Coordinate system for dynamic references; table contents remain independent.
    pub field_section_base: FieldSectionBase,
    /// Maximum uncompressed section size, including 32 bytes per field.
    pub max_field_section_size: usize,
    /// Maximum queued encoder-stream bytes. Compression, including preferred references
    /// and insertions, falls back to the native representation when it does not fit.
    pub max_encoder_stream_bytes: usize,
    /// Maximum sections awaiting Section Acknowledgment. Further sections use literals.
    pub max_outstanding_sections: usize,
    /// Maximum outstanding dynamic references, including repeated references within sections.
    pub max_outstanding_references: usize,
}

impl EncoderConfig {
    /// Override encoding choices without replacing resource or peer limits.
    pub fn apply_preferences(&mut self, preferences: EncoderPreferences) {
        if let Some(capacity) = preferences.target_capacity {
            self.target_capacity = capacity;
        }
        if let Some(huffman) = preferences.huffman {
            self.huffman = huffman;
        }
        if let Some(defer) = preferences.defer_dynamic_first_section {
            self.defer_dynamic_first_section = defer;
        }
        if let Some(base) = preferences.field_section_base {
            self.field_section_base = base;
        }
    }
}

impl Default for EncoderConfig {
    fn default() -> Self {
        Self {
            max_table_capacity: kib_u64(4),
            max_blocked_streams: 16,
            target_capacity: kib_u64(4),
            huffman: true,
            defer_dynamic_first_section: false,
            field_section_base: FieldSectionBase::default(),
            max_field_section_size: kib(64),
            max_encoder_stream_bytes: kib(64),
            max_outstanding_sections: 1024,
            max_outstanding_references: 16_384,
        }
    }
}

// Plans share the already-required preflight allocation with their input fields.
// Absolute references stay protected until the final section Base is chosen.
#[derive(Clone, Copy)]
enum FieldEncoding {
    StaticIndex(u64),
    DynamicIndex(u64),
    LiteralStaticName(u64),
    LiteralDynamicName(u64),
    LiteralName,
}

impl FieldEncoding {
    /// The static or literal representation used without dynamic compression.
    fn native(name: &[u8], value: &[u8], never_index: bool) -> Self {
        if !never_index && let Some(index) = static_table::find(name, value) {
            Self::StaticIndex(index as u64)
        } else if let Some(index) = static_table::find_name(name) {
            Self::LiteralStaticName(index as u64)
        } else {
            Self::LiteralName
        }
    }
}

/// One field with the preferences that remain honourable for its section.
struct Input<'a, N, V> {
    field: EncodeField<'a, N, V>,
    preferences: FieldPreferences,
    encoding: FieldEncoding,
}

fn static_name(index: u64) -> Option<&'static [u8]> {
    usize::try_from(index)
        .ok()
        .and_then(static_table::get)
        .map(|entry| entry.0)
}

/// The same family without a required position relative to the section Base.
fn unconstrained(representation: Representation) -> Representation {
    match representation {
        Representation::DynamicIndexBeforeBase | Representation::DynamicIndexAfterBase => {
            Representation::DynamicIndex
        }
        Representation::LiteralDynamicNameBeforeBase
        | Representation::LiteralDynamicNameAfterBase => Representation::LiteralDynamicName,
        other => other,
    }
}

/// The pre-Base family for a field-Base section, which needs an explicit position.
fn positioned(representation: Representation) -> Representation {
    match representation {
        Representation::DynamicIndex => Representation::DynamicIndexBeforeBase,
        Representation::LiteralDynamicName => Representation::LiteralDynamicNameBeforeBase,
        other => other,
    }
}

struct Section {
    refs: Vec<u64>,
    required_insert_count: u64,
}

#[derive(Default)]
struct StreamSections {
    queue: VecDeque<Section>,
    blocking: usize,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum InitialSection {
    Unencoded,
    Deferred,
    Complete,
}

/// Stateful encoder for one connection. Dynamic insertion and references, preferred or not,
/// fall back to native representations when they cannot be honoured; invalid/oversized input
/// fails before any state changes.
pub struct Encoder {
    qlog: Option<ConnectionQlogControl>,
    /// Bounds the events of instructions parsed from the peer's decoder stream.
    qlog_budget: PeerEventBudget,
    config: EncoderConfig,
    table: DynamicTable,
    encoder_output: BytesMut,
    known_received_count: u64,
    capacity_initialized: bool,
    initial_section: InitialSection,
    sections: BTreeMap<u64, StreamSections>,
    // Counts sections by (Required Insert Count, stream). Advancing the Known
    // Received Count visits only newly unblocked sections, never unrelated ones.
    blocking_sections: BTreeMap<(u64, u64), usize>,
    section_count: usize,
    reference_count: usize,
    blocking_streams: u64,
    // One high-water mark for each QUIC initiator/direction class. Cancellation
    // abandons the entire stream (RFC 9204 §2.2.2.2), even if it precedes the
    // first encode or races later trailers. Retaining individual cancelled IDs
    // would let peer feedback grow state without bound; instead,
    // older streams conservatively use static/literal representations too.
    cancelled_through: [Option<u64>; STREAM_CLASS_COUNT],
    decoder_partial: [u8; 11],
    decoder_partial_len: usize,
    pending_target_capacity: Option<u64>,
}

impl Encoder {
    pub(crate) fn set_qlog(&mut self, control: Option<ConnectionQlogControl>) {
        self.qlog = control;
    }

    fn record_instruction(&self, name: &'static str, instruction: Instruction) {
        metadata::instruction(self.qlog.as_ref(), None, name, instruction, || {
            (self.table.insert_count(), self.table.capacity())
        });
    }

    fn record_peer_instruction(&self, instruction: Instruction) {
        let budget = Some(&self.qlog_budget);
        let name = "rama_qpack:instruction_parsed";
        metadata::instruction(self.qlog.as_ref(), budget, name, instruction, || {
            (self.table.insert_count(), self.table.capacity())
        });
    }

    /// Create an encoder with the peer settings and local budgets.
    #[must_use]
    pub fn new(mut config: EncoderConfig) -> Self {
        config.max_table_capacity = config.max_table_capacity.min(VarInt::MAX.into_inner());
        config.target_capacity = config.target_capacity.min(config.max_table_capacity);
        Self {
            qlog: None,
            qlog_budget: PeerEventBudget::new("qpack_instructions", QPACK_INSTRUCTION_EVENTS),
            table: DynamicTable::new(config.max_table_capacity),
            config,
            encoder_output: BytesMut::new(),
            known_received_count: 0,
            capacity_initialized: false,
            initial_section: if config.defer_dynamic_first_section {
                InitialSection::Deferred
            } else {
                InitialSection::Unencoded
            },
            sections: BTreeMap::new(),
            blocking_sections: BTreeMap::new(),
            section_count: 0,
            reference_count: 0,
            blocking_streams: 0,
            cancelled_through: [None; STREAM_CLASS_COUNT],
            decoder_partial: [0; 11],
            decoder_partial_len: 0,
            pending_target_capacity: None,
        }
    }

    /// Create a connection encoder before receiving peer SETTINGS.
    ///
    /// Only static and literal representations are used until [`Self::apply_peer_settings`].
    /// The configured target capacity and local budgets are retained for negotiation.
    #[must_use]
    pub fn before_peer_settings(mut config: EncoderConfig) -> Self {
        let target = config.target_capacity;
        config.max_table_capacity = 0;
        config.max_blocked_streams = 0;
        let mut encoder = Self::new(config);
        encoder.pending_target_capacity = Some(target);
        encoder
    }

    /// Apply the first peer SETTINGS without replacing decoder-stream parser state.
    ///
    /// This is valid exactly once on an encoder created with [`Self::before_peer_settings`].
    /// The connection driver must reject subsequent SETTINGS as H3_FRAME_UNEXPECTED.
    pub fn apply_peer_settings(
        &mut self,
        settings: &rama_http_types::proto::h3::Settings,
    ) -> Result<(), QpackError> {
        let target = self
            .pending_target_capacity
            .take()
            .ok_or(QpackError::ResourceLimit(
                "peer settings already configured",
            ))?;
        self.config.max_table_capacity = settings.qpack_max_table_capacity();
        self.config.max_blocked_streams = settings.qpack_blocked_streams();
        self.config.target_capacity = target.min(self.config.max_table_capacity);
        if let Some(limit) = settings.max_field_section_size() {
            self.config.max_field_section_size = self
                .config
                .max_field_section_size
                .min(usize::try_from(limit).unwrap_or(usize::MAX));
        }
        // Before SETTINGS no insertion or dynamic reference was permitted.
        debug_assert_eq!(self.table.insert_count(), 0);
        self.table = DynamicTable::new(self.config.max_table_capacity);
        Ok(())
    }

    /// Number of insertions acknowledged by the peer.
    #[must_use]
    pub fn known_received_count(&self) -> u64 {
        self.known_received_count
    }
    /// Number of dynamic entries inserted over the connection lifetime.
    #[must_use]
    pub fn insert_count(&self) -> u64 {
        self.table.insert_count()
    }
    /// Number of sections awaiting acknowledgment.
    #[must_use]
    pub fn tracked_section_count(&self) -> usize {
        self.section_count
    }
    /// Number of outstanding references retained for acknowledgment/cancellation.
    #[must_use]
    pub fn tracked_reference_count(&self) -> usize {
        self.reference_count
    }
    /// Number of queued encoder-stream bytes.
    #[must_use]
    pub fn encoder_stream_len(&self) -> usize {
        self.encoder_output.len()
    }
    /// Take queued encoder-stream bytes in order.
    pub fn take_encoder_stream(&mut self) -> Bytes {
        self.encoder_output.split().freeze()
    }

    fn is_stream_blocking(&self, stream_id: u64) -> bool {
        self.sections
            .get(&stream_id)
            .is_some_and(|sections| sections.blocking > 0)
    }

    fn advance_known_received_count(&mut self, count: u64) {
        self.known_received_count = self.known_received_count.max(count);
        while self
            .blocking_sections
            .first_key_value()
            .is_some_and(|((required, _), _)| *required <= self.known_received_count)
        {
            let Some(((_, stream_id), count)) = self.blocking_sections.pop_first() else {
                break;
            };
            if let Some(sections) = self.sections.get_mut(&stream_id) {
                sections.blocking -= count;
                if sections.blocking == 0 {
                    self.blocking_streams -= 1;
                }
            }
        }
    }

    fn remove_blocking_section(&mut self, stream_id: u64, required: u64) {
        if required <= self.known_received_count {
            return;
        }
        let key = (required, stream_id);
        if let Some(count) = self.blocking_sections.get_mut(&key) {
            *count -= 1;
            if *count == 0 {
                self.blocking_sections.remove(&key);
            }
        }
    }

    /// Bound newly generated instructions by credit atomically reserved by the transport.
    /// Existing synchronous users retain their configured output budget.
    pub(crate) fn encode_with_credit<'a, I, F, N, V>(
        &mut self,
        stream_id: u64,
        fields: I,
        credit: usize,
        base: Option<FieldSectionBase>,
    ) -> Result<Bytes, QpackError>
    where
        I: IntoIterator<Item = F>,
        F: Into<EncodeField<'a, N, V>>,
        N: AsRef<[u8]>,
        V: AsRef<[u8]>,
    {
        let configured = self.config.max_encoder_stream_bytes;
        self.config.max_encoder_stream_bytes = configured.min(credit);
        let result = self.encode_with_base(
            stream_id,
            fields,
            base.unwrap_or(self.config.field_section_base),
        );
        self.config.max_encoder_stream_bytes = configured;
        result
    }

    fn active_insertion(&self, preferences: &FieldPreferences) -> Option<InsertionPreferences> {
        preferences.insertion.filter(|insertion| {
            insertion.scope == InsertionScope::EverySection
                || self.initial_section != InitialSection::Complete
        })
    }

    fn output_fits(&self, additional: usize) -> bool {
        additional
            <= self
                .config
                .max_encoder_stream_bytes
                .saturating_sub(self.encoder_output.len())
    }

    fn ensure_capacity(&mut self) {
        if self.initial_section != InitialSection::Deferred
            && !self.capacity_initialized
            && self.config.target_capacity > 0
            && self.output_fits(int_encoded_len(self.config.target_capacity, 5))
        {
            self.capacity_initialized = true;
            let ok = self.table.set_capacity(self.config.target_capacity);
            debug_assert!(ok);
            encode_int(
                &mut self.encoder_output,
                self.config.target_capacity,
                5,
                0x20,
            );
            self.record_instruction(
                "rama_qpack:instruction_created",
                Instruction::SetCapacity {
                    capacity: self.config.target_capacity,
                },
            );
        }
    }

    /// Encode ordered fields for a HEADERS/PUSH_PROMISE payload. Tuples represent ordinary fields;
    /// [`EncodeField`] or decoded [`FieldPair`] values preserve sensitivity.
    ///
    /// Input size and stream ID are validated before any connection state changes. A tracking or
    /// encoder-output budget prevents dynamic compression rather than failing the section.
    ///
    /// After stream cancellation, this stream and older IDs in the same QUIC stream class use
    /// static/literal representations. Later IDs can still use dynamic compression. This bounded
    /// bookkeeping leaves previously outstanding references on other streams intact.
    pub fn encode<'a, I, F, N, V>(&mut self, stream_id: u64, fields: I) -> Result<Bytes, QpackError>
    where
        I: IntoIterator<Item = F>,
        F: Into<EncodeField<'a, N, V>>,
        N: AsRef<[u8]>,
        V: AsRef<[u8]>,
    {
        self.encode_with_base(stream_id, fields, self.config.field_section_base)
    }

    /// Encode with a section-local Base policy.
    ///
    /// [`FieldSectionBase::FromFieldPreferences`] plans positioned dynamic reference
    /// families and current-field insertions before changing connection state.
    /// A preference that cannot be honoured, under any policy, falls back to the
    /// native representation of that field; the section itself never fails for it.
    pub fn encode_with_base<'a, I, F, N, V>(
        &mut self,
        stream_id: u64,
        fields: I,
        base_policy: FieldSectionBase,
    ) -> Result<Bytes, QpackError>
    where
        I: IntoIterator<Item = F>,
        F: Into<EncodeField<'a, N, V>>,
        N: AsRef<[u8]>,
        V: AsRef<[u8]>,
    {
        if VarInt::from_u64(stream_id).is_err() {
            return Err(QpackError::ResourceLimit(
                "stream ID exceeds QUIC integer range",
            ));
        }
        // Retain the caller's original values, without allocating per-literal copies. This bounded
        // preflight makes input rejection transactional even for one-shot iterators.
        let mut input = Vec::new();
        let mut size = 0usize;
        let mut explicit_insertions = 0usize;
        let field_base = base_policy == FieldSectionBase::FromFieldPreferences;
        for field in fields {
            let mut field = field.into();
            let mut preferences = field.preferences.copied().unwrap_or_default();
            if let Representation::LiteralStaticName(index) = preferences.representation
                && static_name(index) != Some(field.name.as_ref())
            {
                debug!(
                    index,
                    "QPACK: static name preference names another field; encoding natively"
                );
                preferences.representation = Representation::Automatic;
            }
            preferences.representation = if field_base {
                positioned(preferences.representation)
            } else {
                if preferences.representation.names_base_position() {
                    debug!(
                        representation = ?preferences.representation,
                        "QPACK: positioned reference needs the field Base policy; position dropped"
                    );
                }
                unconstrained(preferences.representation)
            };
            field.never_index |= preferences.never_index;
            if field.never_index && preferences.insertion.take().is_some() {
                debug!("QPACK: never-index field is not explicitly inserted");
            }
            explicit_insertions += usize::from(self.active_insertion(&preferences).is_some());
            size = size
                .checked_add(field.name.as_ref().len())
                .and_then(|n| n.checked_add(field.value.as_ref().len()))
                .and_then(|n| n.checked_add(ENTRY_OVERHEAD as usize))
                .filter(|n| *n <= self.config.max_field_section_size)
                .ok_or(QpackError::EncodeFieldSectionLimit(
                    "field section too large",
                ))?;
            input.push(Input {
                field,
                preferences,
                encoding: FieldEncoding::LiteralName,
            });
        }
        let was_blocking = self.is_stream_blocking(stream_id);
        let mut refs = Vec::new();
        let mut ric = 0;
        let base = if field_base {
            let (encodings, base) =
                boundary::Plan::prepare(self, stream_id, &input)?.apply(self)?;
            for (Input { encoding, .. }, planned) in input.iter_mut().zip(encodings) {
                *encoding = planned;
                if let FieldEncoding::DynamicIndex(abs) | FieldEncoding::LiteralDynamicName(abs) =
                    planned
                {
                    self.reference(abs, &mut refs, &mut ric);
                }
            }
            base
        } else {
            let previous_base = self.table.insert_count();
            if explicit_insertions == 0 {
                self.ensure_capacity();
            } else {
                match insertion::Plan::prepare(self, &input, explicit_insertions) {
                    Ok(plan) => plan.apply(self)?,
                    Err(error) => {
                        debug!(%error, "QPACK: explicit insertions do not fit; encoding natively");
                        self.ensure_capacity();
                    }
                }
            }
            let may_block = was_blocking || self.blocking_streams < self.config.max_blocked_streams;
            let cancelled_through =
                self.cancelled_through[(stream_id & STREAM_CLASS_MASK) as usize];
            let may_track = self.initial_section != InitialSection::Deferred
                && self.section_count < self.config.max_outstanding_sections
                && cancelled_through.is_none_or(|cancelled| stream_id > cancelled);
            for Input {
                field,
                preferences,
                encoding,
            } in &mut input
            {
                let name = field.name.as_ref();
                let value = field.value.as_ref();
                let can_track =
                    may_track && self.reference_count < self.config.max_outstanding_references;
                let referenceable =
                    |abs: u64| can_track && (abs < self.known_received_count || may_block);
                let preference = preferences.representation;
                if !field.never_index
                    && matches!(
                        preference,
                        Representation::Automatic | Representation::DynamicIndex
                    )
                {
                    if preference == Representation::Automatic
                        && let Some(index) = static_table::find(name, value)
                    {
                        *encoding = FieldEncoding::StaticIndex(index as u64);
                        continue;
                    }
                    if let Some(abs) = self
                        .table
                        .find(name, value)
                        .filter(|abs| referenceable(*abs))
                    {
                        self.reference(abs, &mut refs, &mut ric);
                        *encoding = FieldEncoding::DynamicIndex(abs);
                        continue;
                    }
                    if can_track && may_block && insertion::try_insert(self, name, value) {
                        let abs = self.table.insert_count() - 1;
                        self.reference(abs, &mut refs, &mut ric);
                        *encoding = FieldEncoding::DynamicIndex(abs);
                        continue;
                    }
                }
                match preference {
                    Representation::LiteralName => continue,
                    Representation::LiteralStaticName(index) => {
                        *encoding = FieldEncoding::LiteralStaticName(index);
                        continue;
                    }
                    // Positioned families were made unconstrained during preflight.
                    Representation::Automatic
                    | Representation::DynamicIndex
                    | Representation::DynamicIndexBeforeBase
                    | Representation::DynamicIndexAfterBase => {
                        if let Some(index) = static_table::find_name(name) {
                            *encoding = FieldEncoding::LiteralStaticName(index as u64);
                            continue;
                        }
                    }
                    Representation::LiteralDynamicName
                    | Representation::LiteralDynamicNameBeforeBase
                    | Representation::LiteralDynamicNameAfterBase => (),
                }
                let name_index = self
                    .table
                    .find_name(name)
                    .filter(|abs| can_track && (*abs < self.known_received_count || may_block));
                // A literal value need not inherit a previous connection's table contents.
                // Insert only an empty placeholder, retaining all normal reference/output budgets.
                let name_index = name_index.or_else(|| {
                    (preference == Representation::LiteralDynamicName
                        && !field.never_index
                        && can_track
                        && may_block
                        && insertion::try_insert(self, name, b""))
                    .then(|| self.table.insert_count() - 1)
                });
                if let Some(abs) = name_index {
                    self.reference(abs, &mut refs, &mut ric);
                    *encoding = FieldEncoding::LiteralDynamicName(abs);
                }
            }
            match base_policy {
                FieldSectionBase::BeforeSection => previous_base,
                FieldSectionBase::RequiredInsertCount => ric,
                FieldSectionBase::FromFieldPreferences => {
                    return Err(QpackError::EncodeFieldSectionLimit(
                        "dynamic Base policy mismatch",
                    ));
                }
            }
        };
        let field_count = input.len();
        // Reserve prefix headroom to avoid moving the body after its final RIC is known.
        const PREFIX_HEADROOM: usize = 22;
        let mut out = BytesMut::with_capacity(PREFIX_HEADROOM + size.min(kib(1)));
        out.resize(PREFIX_HEADROOM, 0);
        for Input {
            field,
            preferences,
            encoding,
        } in input
        {
            match encoding {
                FieldEncoding::StaticIndex(index) => {
                    encode_int(&mut out, index, 6, 0xc0);
                    continue;
                }
                FieldEncoding::DynamicIndex(abs) => {
                    encode_dynamic_index(&mut out, abs, base);
                    continue;
                }
                FieldEncoding::LiteralStaticName(index) => {
                    encode_int(
                        &mut out,
                        index,
                        4,
                        0x50 | if field.never_index { 0x20 } else { 0 },
                    );
                }
                FieldEncoding::LiteralDynamicName(abs) => {
                    if abs < base {
                        encode_int(
                            &mut out,
                            base - abs - 1,
                            4,
                            0x40 | if field.never_index { 0x20 } else { 0 },
                        );
                    } else {
                        encode_int(
                            &mut out,
                            abs - base,
                            3,
                            if field.never_index { 0x08 } else { 0 },
                        );
                    }
                }
                FieldEncoding::LiteralName => {
                    self.literal_string(field.name.as_ref(), 3, preferences.name_huffman)
                        .encode(&mut out, 0x20 | if field.never_index { 0x10 } else { 0 });
                }
            }
            self.literal_string(field.value.as_ref(), 7, preferences.value_huffman)
                .encode(&mut out, 0);
        }
        let mut prefix = [0u8; PREFIX_HEADROOM];
        let mut cursor = &mut prefix[..];
        // A referenced entry fits the table, so the table holds at least one entry.
        let section_prefix = HeaderPrefix::new(ric, if ric == 0 { 0 } else { base });
        section_prefix
            .encode(&mut cursor, self.table.max_entries())
            .map_err(|_invalid| QpackError::ResourceLimit("dynamic table holds no entry"))?;
        let prefix_len = PREFIX_HEADROOM - cursor.len();
        out[PREFIX_HEADROOM - prefix_len..PREFIX_HEADROOM].copy_from_slice(&prefix[..prefix_len]);
        if ric > 0 {
            let sections = self.sections.entry(stream_id).or_default();
            sections.queue.push_back(Section {
                refs,
                required_insert_count: ric,
            });
            self.section_count += 1;
            if ric > self.known_received_count {
                *self.blocking_sections.entry((ric, stream_id)).or_default() += 1;
                sections.blocking += 1;
                if !was_blocking {
                    self.blocking_streams += 1;
                }
            }
        }
        self.initial_section = InitialSection::Complete;
        metadata::section(
            self.qlog.as_ref(),
            "rama_qpack:field_section_created",
            stream_id,
            &section_prefix,
            Some(field_count),
            None,
        );
        Ok(out.freeze().slice(PREFIX_HEADROOM - prefix_len..))
    }

    fn reference(&mut self, abs: u64, refs: &mut Vec<u64>, ric: &mut u64) {
        refs.push(abs);
        // RFC 9204 §2.1.4 and Appendix C erratum 8410: a count, not an index.
        *ric = (*ric).max(abs + 1);
        self.table.add_ref(abs);
        self.reference_count += 1;
    }

    fn literal_string<'a>(
        &self,
        data: &'a [u8],
        prefix_bits: u8,
        huffman: Option<bool>,
    ) -> StringEncoder<'a> {
        match huffman {
            Some(true) => StringEncoder::new_huffman(data, prefix_bits),
            Some(false) => StringEncoder::new(data, prefix_bits, false),
            None => StringEncoder::new(data, prefix_bits, self.config.huffman),
        }
    }

    /// Apply one decoded feedback instruction (RFC 9204 §4.4).
    pub fn on_decoder_instruction(&mut self, inst: DecoderInstruction) -> Result<(), QpackError> {
        match inst {
            DecoderInstruction::InsertCountIncrement { increment } => {
                if increment == 0 {
                    return Err(QpackError::DecoderStreamError(
                        "zero insert count increment",
                    ));
                }
                let new = self
                    .known_received_count
                    .checked_add(increment)
                    .filter(|v| *v <= self.table.insert_count())
                    .ok_or(QpackError::DecoderStreamError(
                        "insert count increment exceeds inserts",
                    ))?;
                self.advance_known_received_count(new);
            }
            DecoderInstruction::SectionAcknowledgment { stream_id } => {
                let sections =
                    self.sections
                        .get_mut(&stream_id)
                        .ok_or(QpackError::DecoderStreamError(
                            "acknowledgment for unknown section",
                        ))?;
                let section = sections
                    .queue
                    .pop_front()
                    .ok_or(QpackError::DecoderStreamError(
                        "acknowledgment for unknown section",
                    ))?;
                let required = section.required_insert_count;
                if required > self.known_received_count {
                    sections.blocking -= 1;
                    if sections.blocking == 0 {
                        self.blocking_streams -= 1;
                    }
                }
                if sections.queue.is_empty() {
                    self.sections.remove(&stream_id);
                }
                self.remove_blocking_section(stream_id, required);
                self.advance_known_received_count(required);
                self.release_section(section);
            }
            DecoderInstruction::StreamCancellation { stream_id } => {
                if VarInt::from_u64(stream_id).is_err() {
                    return Err(QpackError::DecoderStreamError(
                        "stream ID exceeds QUIC integer range",
                    ));
                }
                let cancelled =
                    &mut self.cancelled_through[(stream_id & STREAM_CLASS_MASK) as usize];
                *cancelled = Some(cancelled.map_or(stream_id, |previous| previous.max(stream_id)));
                if let Some(sections) = self.sections.remove(&stream_id) {
                    if sections.blocking > 0 {
                        self.blocking_streams -= 1;
                    }
                    for section in sections.queue {
                        self.remove_blocking_section(stream_id, section.required_insert_count);
                        self.release_section(section);
                    }
                }
            }
        }
        self.record_peer_instruction(Instruction::decoder(inst));
        Ok(())
    }

    fn release_section(&mut self, section: Section) {
        self.section_count -= 1;
        self.reference_count -= section.refs.len();
        for abs in section.refs {
            self.table.release_ref(abs);
        }
    }

    /// Process arbitrarily fragmented decoder-stream bytes, retaining at most eleven bytes of
    /// one incomplete instruction. Complete instructions before a malformed one remain applied.
    pub fn feed_decoder_stream(&mut self, mut input: &[u8]) -> Result<(), QpackError> {
        while !input.is_empty() {
            if self.decoder_partial_len > 0 {
                if self.decoder_partial_len == self.decoder_partial.len() {
                    return Err(QpackError::DecoderStreamError(
                        "decoder-stream integer overflow",
                    ));
                }
                self.decoder_partial[self.decoder_partial_len] = input[0];
                self.decoder_partial_len += 1;
                input = &input[1..];
                let mut cursor = &self.decoder_partial[..self.decoder_partial_len];
                match DecoderInstruction::decode(&mut cursor) {
                    Ok(inst) => {
                        self.decoder_partial_len = 0;
                        self.on_decoder_instruction(inst)?;
                    }
                    Err(PrefixError::UnexpectedEnd) => {}
                    Err(_) => {
                        return Err(QpackError::DecoderStreamError(
                            "malformed decoder-stream instruction",
                        ));
                    }
                }
            } else {
                let mut cursor = input;
                match DecoderInstruction::decode(&mut cursor) {
                    Ok(inst) => {
                        input = cursor;
                        self.on_decoder_instruction(inst)?;
                    }
                    Err(PrefixError::UnexpectedEnd) => {
                        if input.len() > self.decoder_partial.len() {
                            return Err(QpackError::DecoderStreamError(
                                "decoder-stream integer overflow",
                            ));
                        }
                        self.decoder_partial[..input.len()].copy_from_slice(input);
                        self.decoder_partial_len = input.len();
                        break;
                    }
                    Err(_) => {
                        return Err(QpackError::DecoderStreamError(
                            "malformed decoder-stream instruction",
                        ));
                    }
                }
            }
        }
        Ok(())
    }

    /// Whether feedback ends on an instruction boundary. The connection driver handles critical
    /// stream closure; this reports a partial instruction for diagnostics and incremental tests.
    #[must_use]
    pub fn is_at_decoder_instruction_boundary(&self) -> bool {
        self.decoder_partial_len == 0
    }
}

fn encode_dynamic_index(out: &mut BytesMut, abs: u64, base: u64) {
    if abs < base {
        encode_int(out, base - abs - 1, 6, 0x80);
    } else {
        encode_int(out, abs - base, 4, 0x10);
    }
}

#[cfg(test)]
mod tests;
