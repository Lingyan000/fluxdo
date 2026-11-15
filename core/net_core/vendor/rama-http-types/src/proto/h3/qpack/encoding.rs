//! Field-section encoding preferences, independent of dynamic-table contents.

use super::static_table;
use crate::{
    HeaderMap,
    proto::h3::{
        PseudoHeader,
        observation::{FieldRepresentation, ObservedFieldRepresentation},
    },
};
use rama_core::extensions::Extension;
use std::collections::BTreeMap;

/// How to encode a field when references are legal under the current peer limits.
///
/// Every variant is best effort: one the encoder cannot honour falls back to its
/// native representation for that field, never failing the section. The before/after-Base
/// variants keep their position only under [`super::FieldSectionBase::FromFieldPreferences`];
/// the coordinate-only section policies keep just their family.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Hash)]
pub enum Representation {
    /// Prefer an exact static or dynamic reference, inserting when permitted.
    #[default]
    Automatic,
    /// Prefer a whole-field dynamic reference, even when an exact static entry exists.
    /// The current table supplies the index; sensitivity, peer limits, initial
    /// deferral and resource budgets may require a literal representation.
    DynamicIndex,
    /// Prefer a whole-field reference below the section Base.
    DynamicIndexBeforeBase,
    /// Prefer a whole-field reference at or above the section Base.
    DynamicIndexAfterBase,
    /// Emit both name and value literally, without automatic insertion.
    LiteralName,
    /// Emit a literal value with this stable static-table name index.
    /// An index naming a different field is ignored in favour of native encoding.
    LiteralStaticName(u64),
    /// Reference a dynamic name, inserting a name-only entry when permitted.
    /// The value stays literal and is not automatically inserted by this representation.
    /// Sensitivity, initial deferral and peer/resource budgets may require a literal name.
    /// Captured dynamic indexes are never reused.
    LiteralDynamicName,
    /// Prefer a dynamic name reference below the section Base.
    LiteralDynamicNameBeforeBase,
    /// Prefer a dynamic name reference at or above the section Base.
    LiteralDynamicNameAfterBase,
}

impl Representation {
    /// Whether this family names a position relative to the section Base.
    #[must_use]
    pub const fn names_base_position(self) -> bool {
        matches!(
            self,
            Self::DynamicIndexBeforeBase
                | Self::DynamicIndexAfterBase
                | Self::LiteralDynamicNameBeforeBase
                | Self::LiteralDynamicNameAfterBase
        )
    }
}

/// Name encoding for an explicit insertion on the encoder stream.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Hash)]
pub enum InsertionNameEncoding {
    /// Use a static name reference when available, otherwise a literal name.
    /// With no explicit Huffman choices, an identical entry already in the table
    /// may instead use Duplicate when it fits the encoder's output reservation.
    #[default]
    Automatic,
    Literal,
    /// A stable static-table index naming the supplied field; another field's index
    /// falls back to [`Self::Automatic`].
    StaticName(u64),
}

/// Which successfully encoded field sections request explicit insertion.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Hash)]
pub enum InsertionScope {
    /// Apply whenever a field carrying these preferences is encoded.
    #[default]
    EverySection,
    /// Apply only in the connection's first successfully encoded field section,
    /// even when that section could not honour it. Subsequent sections, including
    /// trailers, skip the insertion.
    InitialSection,
}

/// Insert the current field independently of its field-section representation.
///
/// Explicit insertions follow field order and use current supplied values. They
/// are preflighted together before encoder state changes; a sensitive field is
/// never inserted, and a batch exceeding peer capacity or output credit is dropped
/// so the section is encoded natively. They never grant a dynamic reference when
/// the initial field section defers such references.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Hash)]
pub struct InsertionPreferences {
    pub scope: InsertionScope,
    pub name_encoding: InsertionNameEncoding,
    /// None follows the connection policy; Some forces this literal coding.
    pub name_huffman: Option<bool>,
    /// None follows the connection policy; Some forces this literal coding.
    pub value_huffman: Option<bool>,
}

/// Choices for one field; peer limits and the caller's sensitivity still apply.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Hash)]
pub struct FieldPreferences {
    pub representation: Representation,
    /// Request a fresh encoder-stream insertion of this field, even when its
    /// field line stays literal. Never-index or insufficient resources skip it.
    pub insertion: Option<InsertionPreferences>,
    /// Force Huffman (`true`) or plain (`false`) field names; `None` uses connection policy.
    pub name_huffman: Option<bool>,
    /// Force Huffman (`true`) or plain (`false`) literal values; `None` uses connection policy.
    /// Encoder-stream instructions continue to use the connection's Huffman policy.
    pub value_huffman: Option<bool>,
    /// Strengthen never-index; this cannot clear sensitivity supplied by the caller.
    pub never_index: bool,
}

impl FieldPreferences {
    /// Turn valid wire metadata into preferences for a fresh table.
    /// Static indexes are stable; dynamic indexes describe another table and are discarded.
    /// Dynamic families keep their Base side under [`super::FieldSectionBase::FromFieldPreferences`]
    /// so the native encoder can place current entries on the requested side of its Base.
    pub fn from_observed(field: &ObservedFieldRepresentation) -> Option<Self> {
        let index = field.index;
        let mut result = Self {
            never_index: field.never_index,
            ..Self::default()
        };
        match field.representation {
            FieldRepresentation::StaticIndex => {
                static_table::get(usize::try_from(index?).ok()?)?;
                if field.name_huffman || field.value_huffman || field.never_index {
                    return None;
                }
            }
            FieldRepresentation::DynamicIndex | FieldRepresentation::DynamicPostBaseIndex => {
                if index? >= 1 << 62
                    || field.name_huffman
                    || field.value_huffman
                    || field.never_index
                {
                    return None;
                }
                result.representation = match field.representation {
                    FieldRepresentation::DynamicIndex => Representation::DynamicIndexBeforeBase,
                    _ => Representation::DynamicIndexAfterBase,
                };
            }
            FieldRepresentation::LiteralStaticName => {
                static_table::get(usize::try_from(index?).ok()?)?;
                if field.name_huffman {
                    return None;
                }
                result.representation = Representation::LiteralStaticName(index?);
                result.value_huffman = Some(field.value_huffman);
            }
            FieldRepresentation::LiteralDynamicName | FieldRepresentation::LiteralPostBaseName => {
                if index? >= 1 << 62 || field.name_huffman {
                    return None;
                }
                result.representation = match field.representation {
                    FieldRepresentation::LiteralDynamicName => {
                        Representation::LiteralDynamicNameBeforeBase
                    }
                    _ => Representation::LiteralDynamicNameAfterBase,
                };
                result.value_huffman = Some(field.value_huffman);
            }
            FieldRepresentation::LiteralName => {
                if index.is_some() {
                    return None;
                }
                result.representation = Representation::LiteralName;
                result.name_huffman = Some(field.name_huffman);
                result.value_huffman = Some(field.value_huffman);
            }
        }
        Some(result)
    }
}

/// Optional request/response head-field preferences consumed by the HTTP/3 encoder.
///
/// Regular fields match by name and occurrence, preserving duplicate-field choices.
/// Pseudo-fields use their protocol names. Missing preferences retain native policy.
/// No header values or connection-specific table indexes are stored here.
/// Trailers retain the encoder's connection policy.
#[derive(Clone, Debug, Default, Extension)]
#[extension(tags(http))]
pub struct HeaderPreferences {
    pub headers: HeaderMap<FieldPreferences>,
    pub pseudo_headers: BTreeMap<PseudoHeader, FieldPreferences>,
}

impl HeaderPreferences {
    /// Whether encoding is worth waiting for peer SETTINGS and the encoder stream:
    /// explicit insertions and positioned dynamic families cannot be honoured
    /// before them. Whatever still does not fit falls back to native encoding.
    #[must_use]
    pub fn requires_encoder_stream(&self) -> bool {
        self.headers
            .values()
            .chain(self.pseudo_headers.values())
            .any(|preferences| {
                preferences.insertion.is_some() || preferences.representation.names_base_position()
            })
    }

    /// Whether any field requests an explicit encoder-stream insertion.
    #[must_use]
    pub fn has_insertions(&self) -> bool {
        self.headers
            .values()
            .chain(self.pseudo_headers.values())
            .any(|preferences| preferences.insertion.is_some())
    }
}
