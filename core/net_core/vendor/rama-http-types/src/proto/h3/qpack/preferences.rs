//! QPACK encoding preferences that leave peer limits and local budgets intact.

use rama_core::extensions::Extension;

/// Per-connection encoding choices, independent of local resource budgets.
///
/// As a client connection extension these override only the selected choices
/// in the connector's fixed encoder configuration. Peer SETTINGS still limit
/// dynamic compression. Absent fields retain the fixed configuration.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Hash, Extension)]
pub struct EncoderPreferences {
    /// Desired dynamic-table capacity; zero keeps fields statically encoded.
    /// The actual capacity is clamped to the peer's advertised maximum.
    pub target_capacity: Option<u64>,
    /// Permit Huffman encoding when it saves bytes; plain encoding wins ties.
    pub huffman: Option<bool>,
    /// Keep the first field section static/literal, then use the normal dynamic policy.
    pub defer_dynamic_first_section: Option<bool>,
    /// Select the section Base policy; constrained fields can plan fresh insertions.
    pub field_section_base: Option<FieldSectionBase>,
}

/// Base used to encode dynamic references within a field section.
///
/// All choices use the current connection's table without captured table indexes.
/// The coordinate-only choices leave insertion policy intact; per-field planning
/// can insert current entries to preserve explicit reference families.
/// On an HTTP/3 request or response this extension selects its section's Base;
/// absent extensions retain the connection's configured choice.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Hash, Extension)]
pub enum FieldSectionBase {
    /// Entries inserted in this section use post-base references.
    #[default]
    BeforeSection,
    /// All references are relative to the highest referenced insertion count.
    RequiredInsertCount,
    /// Plan current entries around the per-field pre/post-Base requirements.
    /// Existing legal references are reused; missing pre-Base entries are inserted
    /// before missing post-Base entries without changing field order. Conflicting
    /// explicit insertion order or resource limits reject the section atomically.
    /// Automatic fields stay static/literal and do not consume dynamic-reference
    /// credit. Unconstrained dynamic variants require an explicit position here.
    FromFieldPreferences,
}
