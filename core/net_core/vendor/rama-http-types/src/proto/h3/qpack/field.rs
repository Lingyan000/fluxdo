//! QPACK encoded-field-section prefix and field-line representations (RFC 9204 §4.5).
//!
//! These are structural: a decoded [`FieldLine`] carries table indices, not resolved entries, and
//! the [`HeaderPrefix`] carries the reconstructed Required Insert Count and Base. Resolving indices
//! against the dynamic table is the connection-scoped decoder's job (in `rama-http-core`).

use rama_core::bytes::{Buf, BufMut, Bytes};

use super::prefix::{
    PrefixError, decode_int, decode_string_shared, encode_int, encode_string, string_payload,
};

/// The encoded-field-section prefix (RFC 9204 §4.5.1): the Required Insert Count and Base.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub struct HeaderPrefix {
    /// The Required Insert Count (RFC 9204 §4.5.1.1): the dynamic-table insert count the decoder
    /// must have reached before this section can be decoded.
    pub required_insert_count: u64,
    /// The Base (RFC 9204 §4.5.1.2): the reference point for relative and post-Base indices.
    pub base: u64,
}

impl HeaderPrefix {
    /// Construct a prefix.
    #[must_use]
    pub const fn new(required_insert_count: u64, base: u64) -> Self {
        Self {
            required_insert_count,
            base,
        }
    }

    /// Encode this prefix (RFC 9204 §4.5.1.1, §4.5.1.2). `max_entries` is `floor(capacity / 32)`.
    ///
    /// A Required Insert Count names dynamic entries, so it cannot be encoded for a table that
    /// holds none.
    pub fn encode<B: BufMut>(&self, dst: &mut B, max_entries: u64) -> Result<(), InvalidPrefix> {
        let ric = self.required_insert_count;
        let encoded_insert_count = if ric == 0 {
            0
        } else {
            let full_range = max_entries
                .checked_mul(2)
                .filter(|&range| range > 0)
                .ok_or(InvalidPrefix::InvalidRequiredInsertCount)?;
            (ric % full_range) + 1
        };
        encode_int(dst, encoded_insert_count, 8, 0);

        if self.base >= ric {
            // S = 0
            encode_int(dst, self.base - ric, 7, 0);
        } else {
            // S = 1
            encode_int(dst, ric - self.base - 1, 7, 0x80);
        }
        Ok(())
    }

    /// Decode a prefix, reconstructing the Required Insert Count against the decoder's current
    /// `total_inserts` and `max_entries` (RFC 9204 §4.5.1.1, §4.5.1.2).
    pub fn decode(
        src: &mut &[u8],
        max_entries: u64,
        total_inserts: u64,
    ) -> Result<Self, InvalidPrefix> {
        let encoded_insert_count = decode_int(src, 8)?;
        let required_insert_count =
            reconstruct_required_insert_count(encoded_insert_count, total_inserts, max_entries)?;

        let s_bit = *src.first().ok_or(InvalidPrefix::NeedMore)? & 0x80 != 0;
        let delta_base = decode_int(src, 7)?;
        let base = if s_bit {
            // Base = RIC - DeltaBase - 1, which must be non-negative.
            if delta_base >= required_insert_count {
                return Err(InvalidPrefix::NegativeBase);
            }
            required_insert_count - delta_base - 1
        } else {
            required_insert_count
                .checked_add(delta_base)
                .ok_or(InvalidPrefix::IntegerOverflow)?
        };

        Ok(Self {
            required_insert_count,
            base,
        })
    }
}

/// Reconstruct the Required Insert Count (RFC 9204 §4.5.1.1), including every mandatory validity
/// check. Neqo and nghttp3 implement exactly this; the dormant Hyperium h3 version omits the
/// `EncInsertCount > FullRange` and post-reconstruction `RIC == 0` checks and is not used here.
fn reconstruct_required_insert_count(
    encoded_insert_count: u64,
    total_inserts: u64,
    max_entries: u64,
) -> Result<u64, InvalidPrefix> {
    if encoded_insert_count == 0 {
        return Ok(0);
    }
    let full_range = 2u64
        .checked_mul(max_entries)
        .ok_or(InvalidPrefix::IntegerOverflow)?;
    if encoded_insert_count > full_range {
        // implies max_entries == 0 (dynamic table disabled) or a bogus value
        return Err(InvalidPrefix::EncodedInsertCountTooLarge);
    }
    let max_value = total_inserts
        .checked_add(max_entries)
        .ok_or(InvalidPrefix::IntegerOverflow)?;
    let max_wrapped = (max_value / full_range) * full_range;
    let mut required = max_wrapped
        .checked_add(encoded_insert_count)
        .ok_or(InvalidPrefix::IntegerOverflow)?
        - 1;
    if required > max_value {
        if required <= full_range {
            return Err(InvalidPrefix::InvalidRequiredInsertCount);
        }
        required -= full_range;
    }
    if required == 0 {
        return Err(InvalidPrefix::InvalidRequiredInsertCount);
    }
    Ok(required)
}

/// An error decoding an encoded-field-section prefix.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum InvalidPrefix {
    /// More bytes are needed to decode the prefix.
    NeedMore,
    /// The encoded Required Insert Count exceeded `2 * MaxEntries`.
    EncodedInsertCountTooLarge,
    /// The reconstructed Required Insert Count was invalid (0, or out of the wrap window).
    InvalidRequiredInsertCount,
    /// The Base would be negative (`S=1` with `DeltaBase >= RIC`).
    NegativeBase,
    /// An integer in the prefix overflowed.
    IntegerOverflow,
}

impl From<PrefixError> for InvalidPrefix {
    fn from(e: PrefixError) -> Self {
        match e {
            PrefixError::UnexpectedEnd => Self::NeedMore,
            _ => Self::IntegerOverflow,
        }
    }
}

impl core::fmt::Display for InvalidPrefix {
    fn fmt(&self, f: &mut core::fmt::Formatter<'_>) -> core::fmt::Result {
        f.write_str(match self {
            Self::NeedMore => "incomplete QPACK field section prefix",
            Self::EncodedInsertCountTooLarge => "QPACK encoded insert count too large",
            Self::InvalidRequiredInsertCount => "invalid QPACK required insert count",
            Self::NegativeBase => "negative QPACK base",
            Self::IntegerOverflow => "QPACK prefix integer overflow",
        })
    }
}

impl std::error::Error for InvalidPrefix {}

/// A single field-line representation within an encoded field section (RFC 9204 §4.5.2–§4.5.6).
///
/// Indices are unresolved: dynamic references are relative to the section's Base (or post-Base), as
/// on the wire. `huffman` flags record whether a string was Huffman-encoded so the representation
/// can be re-emitted faithfully; they do not affect equality of the decoded value.
#[derive(Clone, PartialEq, Eq, Debug)]
pub enum FieldLine {
    /// Indexed field line (RFC 9204 §4.5.2): a full entry by index.
    Indexed {
        /// Whether the index is into the static table (`T=1`) or dynamic table (`T=0`).
        is_static: bool,
        /// The static index, or the relative dynamic index (relative to Base).
        index: u64,
    },
    /// Indexed field line with post-Base index (RFC 9204 §4.5.3): a dynamic entry at or after Base.
    IndexedPostBase {
        /// The post-Base index.
        index: u64,
    },
    /// Literal field line with a name reference (RFC 9204 §4.5.4).
    LiteralWithNameRef {
        /// Whether an intermediary must forward this line as a literal (`N` bit).
        never_index: bool,
        /// Whether the name index is static (`T=1`) or dynamic (`T=0`, relative to Base).
        is_static: bool,
        /// The name's static index, or relative dynamic index.
        name_index: u64,
        /// The literal value.
        value: Bytes,
        /// Whether the value was Huffman-encoded on the wire.
        value_huffman: bool,
    },
    /// Literal field line with a post-Base name reference (RFC 9204 §4.5.5).
    LiteralWithPostBaseNameRef {
        /// Whether an intermediary must forward this line as a literal (`N` bit).
        never_index: bool,
        /// The name's post-Base index.
        name_index: u64,
        /// The literal value.
        value: Bytes,
        /// Whether the value was Huffman-encoded on the wire.
        value_huffman: bool,
    },
    /// Literal field line with a literal name (RFC 9204 §4.5.6).
    LiteralWithLiteralName {
        /// Whether an intermediary must forward this line as a literal (`N` bit).
        never_index: bool,
        /// The literal name.
        name: Bytes,
        /// Whether the name was Huffman-encoded on the wire.
        name_huffman: bool,
        /// The literal value.
        value: Bytes,
        /// Whether the value was Huffman-encoded on the wire.
        value_huffman: bool,
    },
}

impl FieldLine {
    /// Encode this representation into `dst`.
    pub fn encode<B: BufMut>(&self, dst: &mut B) {
        match self {
            Self::Indexed { is_static, index } => {
                let flags = 0x80 | if *is_static { 0x40 } else { 0 };
                encode_int(dst, *index, 6, flags);
            }
            Self::IndexedPostBase { index } => {
                encode_int(dst, *index, 4, 0x10);
            }
            Self::LiteralWithNameRef {
                never_index,
                is_static,
                name_index,
                value,
                value_huffman,
            } => {
                let mut flags = 0x40;
                if *never_index {
                    flags |= 0x20;
                }
                if *is_static {
                    flags |= 0x10;
                }
                encode_int(dst, *name_index, 4, flags);
                encode_string(dst, value, 7, 0, *value_huffman);
            }
            Self::LiteralWithPostBaseNameRef {
                never_index,
                name_index,
                value,
                value_huffman,
            } => {
                let flags = if *never_index { 0x08 } else { 0 };
                encode_int(dst, *name_index, 3, flags);
                encode_string(dst, value, 7, 0, *value_huffman);
            }
            Self::LiteralWithLiteralName {
                never_index,
                name,
                name_huffman,
                value,
                value_huffman,
            } => {
                let flags = 0x20 | if *never_index { 0x10 } else { 0 };
                encode_string(dst, name, 3, flags, *name_huffman);
                encode_string(dst, value, 7, 0, *value_huffman);
            }
        }
    }

    /// Decode one field-line representation, bounding each decoded string by `max_string_len`.
    pub fn decode(src: &mut &[u8], max_string_len: usize) -> Result<Self, PrefixError> {
        Self::encoded_len(src, max_string_len)?;
        let mut cursor = *src;
        let result = Self::decode_shared(&mut cursor, max_string_len, None)?;
        *src = cursor;
        Ok(result)
    }

    /// Decode from owned bytes, slicing plain literals without copying their payloads.
    /// Leaves the cursor unchanged on error.
    pub fn decode_bytes(src: &mut Bytes, max_string_len: usize) -> Result<Self, PrefixError> {
        Self::encoded_len(src, max_string_len)?;
        let mut cursor = src.as_ref();
        let result = Self::decode_shared(&mut cursor, max_string_len, Some(src))?;
        let consumed = src.len() - cursor.len();
        src.advance(consumed);
        Ok(result)
    }

    /// Probe the complete field-line length without decoding or allocating strings.
    /// Incomplete bodies return `UnexpectedEnd`; impossible string lengths fail early.
    pub fn encoded_len(src: &[u8], max_string_len: usize) -> Result<usize, PrefixError> {
        let mut cursor = src;
        let first = *cursor.first().ok_or(PrefixError::UnexpectedEnd)?;
        if first & 0x80 != 0 {
            decode_int(&mut cursor, 6)?;
        } else if first & 0x40 != 0 {
            decode_int(&mut cursor, 4)?;
            string_payload(&mut cursor, 7, max_string_len)?;
        } else if first & 0x20 != 0 {
            string_payload(&mut cursor, 3, max_string_len)?;
            string_payload(&mut cursor, 7, max_string_len)?;
        } else if first & 0x10 != 0 {
            decode_int(&mut cursor, 4)?;
        } else {
            decode_int(&mut cursor, 3)?;
            string_payload(&mut cursor, 7, max_string_len)?;
        }
        Ok(src.len() - cursor.len())
    }

    fn decode_shared(
        src: &mut &[u8],
        max_string_len: usize,
        backing: Option<&Bytes>,
    ) -> Result<Self, PrefixError> {
        let first = *src.first().ok_or(PrefixError::UnexpectedEnd)?;
        if first & 0x80 != 0 {
            // 1 T index(6+) : Indexed
            let is_static = first & 0x40 != 0;
            let index = decode_int(src, 6)?;
            Ok(Self::Indexed { is_static, index })
        } else if first & 0x40 != 0 {
            // 01 N T index(4+) value : Literal with Name Reference
            let never_index = first & 0x20 != 0;
            let is_static = first & 0x10 != 0;
            let name_index = decode_int(src, 4)?;
            let value = decode_string_shared(src, 7, max_string_len, backing)?;
            Ok(Self::LiteralWithNameRef {
                never_index,
                is_static,
                name_index,
                value: value.value,
                value_huffman: value.huffman,
            })
        } else if first & 0x20 != 0 {
            // 001 N H namelen(3+) name value : Literal with Literal Name
            let never_index = first & 0x10 != 0;
            let name = decode_string_shared(src, 3, max_string_len, backing)?;
            let value = decode_string_shared(src, 7, max_string_len, backing)?;
            Ok(Self::LiteralWithLiteralName {
                never_index,
                name: name.value,
                name_huffman: name.huffman,
                value: value.value,
                value_huffman: value.huffman,
            })
        } else if first & 0x10 != 0 {
            // 0001 index(4+) : Indexed with Post-Base
            let index = decode_int(src, 4)?;
            Ok(Self::IndexedPostBase { index })
        } else {
            // 0000 N index(3+) value : Literal with Post-Base Name Reference
            let never_index = first & 0x08 != 0;
            let name_index = decode_int(src, 3)?;
            let value = decode_string_shared(src, 7, max_string_len, backing)?;
            Ok(Self::LiteralWithPostBaseNameRef {
                never_index,
                name_index,
                value: value.value,
                value_huffman: value.huffman,
            })
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use rama_core::bytes::BytesMut;

    // RFC 9204 Appendix B parameters: capacity 220 -> MaxEntries 6.
    const MAX_ENTRIES: u64 = 6;

    fn prefix_decode(hex: &[u8], total_inserts: u64) -> HeaderPrefix {
        let mut cursor = hex;
        HeaderPrefix::decode(&mut cursor, MAX_ENTRIES, total_inserts).unwrap()
    }

    #[test]
    fn incomplete_field_value_does_not_decode_completed_huffman_name() {
        // Literal name with invalid Huffman padding. Do not decode that name on
        // each partial-value retry: only inspect its envelope until complete.
        let mut bytes = Bytes::from_static(&[0x29, 0x00, 0x02, b'a', b'b']);
        for split in 0..bytes.len() {
            let mut cursor = &bytes[..split];
            assert_eq!(
                FieldLine::decode(&mut cursor, 16),
                Err(PrefixError::UnexpectedEnd)
            );
            assert_eq!(cursor, &bytes[..split]);
            let mut cursor = bytes.slice(..split);
            assert_eq!(
                FieldLine::decode_bytes(&mut cursor, 16),
                Err(PrefixError::UnexpectedEnd)
            );
            assert_eq!(cursor, bytes.slice(..split));
        }
        assert_eq!(FieldLine::encoded_len(&bytes, 16), Ok(bytes.len()));
        assert_eq!(
            FieldLine::decode(&mut &bytes[..], 16),
            Err(PrefixError::InvalidHuffman)
        );
        assert_eq!(
            FieldLine::decode_bytes(&mut bytes, 16),
            Err(PrefixError::InvalidHuffman)
        );
    }

    #[test]
    fn literal_fields_slice_owned_bytes_and_preserve_error_cursor() {
        let line = FieldLine::LiteralWithLiteralName {
            never_index: true,
            name: Bytes::from_static(b"custom"),
            name_huffman: false,
            value: Bytes::from_static(b"value"),
            value_huffman: false,
        };
        let mut out = BytesMut::new();
        line.encode(&mut out);
        let bytes = out.freeze();
        for split in 0..bytes.len() {
            let mut cursor = bytes.slice(..split);
            assert_eq!(
                FieldLine::decode_bytes(&mut cursor, 128),
                Err(PrefixError::UnexpectedEnd)
            );
            assert_eq!(cursor, bytes.slice(..split));
        }
        let mut cursor = bytes.clone();
        let decoded = FieldLine::decode_bytes(&mut cursor, 128).unwrap();
        assert_eq!(decoded, line);
        match decoded {
            FieldLine::LiteralWithLiteralName { name, value, .. } => {
                assert_eq!(name.as_ptr(), bytes[1..].as_ptr());
                assert_eq!(value.as_ptr(), bytes[8..].as_ptr());
            }
            other => panic!("expected literal field, got {other:?}"),
        }
    }

    #[test]
    fn appendix_b1_prefix_and_static_literal() {
        // stream 0: 0000 510b 2f69 6e64 6578 2e68 746d 6c
        let bytes = [
            0x00, 0x00, 0x51, 0x0b, 0x2f, 0x69, 0x6e, 0x64, 0x65, 0x78, 0x2e, 0x68, 0x74, 0x6d,
            0x6c,
        ];
        let mut cursor = &bytes[..];
        let prefix = HeaderPrefix::decode(&mut cursor, MAX_ENTRIES, 0).unwrap();
        assert_eq!(prefix, HeaderPrefix::new(0, 0));
        let line = FieldLine::decode(&mut cursor, 4096).unwrap();
        match line {
            FieldLine::LiteralWithNameRef {
                never_index,
                is_static,
                name_index,
                ref value,
                ..
            } => {
                assert!(!never_index);
                assert!(is_static);
                assert_eq!(name_index, 1); // static :path
                assert_eq!(&value[..], b"/index.html");
            }
            other => panic!("unexpected: {other:?}"),
        }
        assert!(cursor.is_empty());
    }

    #[test]
    fn appendix_b2_prefix_and_post_base() {
        // stream 4: 03 81 10 11 ; total inserts = 2
        let prefix = prefix_decode(&[0x03, 0x81], 2);
        assert_eq!(prefix, HeaderPrefix::new(2, 0));

        let mut cursor = &[0x10u8, 0x11][..];
        assert_eq!(
            FieldLine::decode(&mut cursor, 4096).unwrap(),
            FieldLine::IndexedPostBase { index: 0 }
        );
        assert_eq!(
            FieldLine::decode(&mut cursor, 4096).unwrap(),
            FieldLine::IndexedPostBase { index: 1 }
        );
    }

    #[test]
    fn appendix_b4_prefix_and_dynamic_indexed() {
        // stream 8: 05 00 80 c1 81 ; total inserts = 4
        let prefix = prefix_decode(&[0x05, 0x00], 4);
        assert_eq!(prefix, HeaderPrefix::new(4, 4));

        let mut cursor = &[0x80u8, 0xc1, 0x81][..];
        assert_eq!(
            FieldLine::decode(&mut cursor, 4096).unwrap(),
            FieldLine::Indexed {
                is_static: false,
                index: 0
            }
        );
        assert_eq!(
            FieldLine::decode(&mut cursor, 4096).unwrap(),
            FieldLine::Indexed {
                is_static: true,
                index: 1
            }
        );
        assert_eq!(
            FieldLine::decode(&mut cursor, 4096).unwrap(),
            FieldLine::Indexed {
                is_static: false,
                index: 1
            }
        );
    }

    #[test]
    fn prefix_round_trip() {
        for (ric, base, inserts) in [(0u64, 0u64, 0u64), (2, 0, 2), (4, 4, 4), (3, 5, 3)] {
            let mut buf = BytesMut::new();
            HeaderPrefix::new(ric, base)
                .encode(&mut buf, MAX_ENTRIES)
                .unwrap();
            let mut cursor = &buf[..];
            let decoded = HeaderPrefix::decode(&mut cursor, MAX_ENTRIES, inserts).unwrap();
            assert_eq!(decoded, HeaderPrefix::new(ric, base));
            assert!(cursor.is_empty());
        }
    }

    #[test]
    fn a_prefix_naming_entries_needs_a_table_that_holds_one() {
        let mut buf = BytesMut::new();
        HeaderPrefix::new(0, 0).encode(&mut buf, 0).unwrap();
        assert_eq!(buf.as_ref(), [0, 0]);
        for max_entries in [0, u64::MAX] {
            let mut buf = BytesMut::new();
            assert_eq!(
                HeaderPrefix::new(1, 1).encode(&mut buf, max_entries),
                Err(InvalidPrefix::InvalidRequiredInsertCount),
                "{max_entries} entries"
            );
        }
    }

    /// RFC 9204 §4.5.1.1: every Required Insert Count in the window a decoder accepts survives
    /// the modular encoding, on both sides of each wrap.
    #[test]
    fn required_insert_counts_wrap_around_the_window() {
        for max_entries in [1u64, 2, 4, 128] {
            let full_range = 2 * max_entries;
            for total_inserts in 0..5 * full_range {
                let max_value = total_inserts + max_entries;
                let lowest = (max_value + 1).saturating_sub(full_range).max(1);
                for ric in lowest..=max_value {
                    let mut buf = BytesMut::new();
                    HeaderPrefix::new(ric, ric)
                        .encode(&mut buf, max_entries)
                        .unwrap();
                    assert_eq!(
                        HeaderPrefix::decode(&mut &buf[..], max_entries, total_inserts),
                        Ok(HeaderPrefix::new(ric, ric)),
                        "ric {ric}, {total_inserts} inserts, {max_entries} entries"
                    );
                }
            }
        }
    }

    #[test]
    fn prefix_rejects_negative_base() {
        // S=1, RIC small, DeltaBase large: enc_ric picks RIC, delta byte 0x80|big
        // RIC=2 (enc byte 0x03, inserts 2), delta byte S=1 delta=5 -> base negative
        let mut cursor = &[0x03u8, 0x85][..];
        assert_eq!(
            HeaderPrefix::decode(&mut cursor, MAX_ENTRIES, 2),
            Err(InvalidPrefix::NegativeBase)
        );
    }

    #[test]
    fn prefix_rejects_enc_ric_too_large() {
        // dynamic table disabled: max_entries 0, enc_ric = 1 -> error
        let mut cursor = &[0x01u8, 0x00][..];
        assert_eq!(
            HeaderPrefix::decode(&mut cursor, 0, 0),
            Err(InvalidPrefix::EncodedInsertCountTooLarge)
        );
    }

    #[test]
    fn field_line_round_trip_all_variants() {
        let lines = [
            FieldLine::Indexed {
                is_static: true,
                index: 25,
            },
            FieldLine::Indexed {
                is_static: false,
                index: 3,
            },
            FieldLine::IndexedPostBase { index: 2 },
            FieldLine::LiteralWithNameRef {
                never_index: true,
                is_static: true,
                name_index: 15,
                value: Bytes::from_static(b"example.com"),
                value_huffman: true,
            },
            FieldLine::LiteralWithPostBaseNameRef {
                never_index: false,
                name_index: 1,
                value: Bytes::from_static(b"value"),
                value_huffman: false,
            },
            FieldLine::LiteralWithLiteralName {
                never_index: false,
                name: Bytes::from_static(b"custom-key"),
                name_huffman: false,
                value: Bytes::from_static(b"custom-value"),
                value_huffman: true,
            },
        ];
        for line in lines {
            let mut buf = BytesMut::new();
            line.encode(&mut buf);
            assert_eq!(FieldLine::encoded_len(&buf, 4096), Ok(buf.len()));
            for split in 0..buf.len() {
                assert_eq!(
                    FieldLine::encoded_len(&buf[..split], 4096),
                    Err(PrefixError::UnexpectedEnd)
                );
            }
            let mut cursor = &buf[..];
            let decoded = FieldLine::decode(&mut cursor, 4096).unwrap();
            assert_eq!(decoded, line);
            assert!(cursor.is_empty());
        }
    }

    #[test]
    fn field_line_incomplete_is_distinct() {
        // literal with name ref, but value truncated
        let mut buf = BytesMut::new();
        FieldLine::LiteralWithNameRef {
            never_index: false,
            is_static: true,
            name_index: 1,
            value: Bytes::from_static(b"/index.html"),
            value_huffman: false,
        }
        .encode(&mut buf);
        let truncated = &buf[..buf.len() - 3];
        let mut cursor = truncated;
        assert_eq!(
            FieldLine::decode(&mut cursor, 4096),
            Err(PrefixError::UnexpectedEnd)
        );
    }
}
