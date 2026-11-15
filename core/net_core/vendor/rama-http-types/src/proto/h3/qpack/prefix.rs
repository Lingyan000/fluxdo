//! QPACK prefixed integers (RFC 9204 §4.1.1) and string literals (RFC 9204 §4.1.2).
//!
//! These are the shared low-level codings under every QPACK field-line and instruction
//! representation. They are decoded from a slice cursor (`&mut &[u8]`); a decoder that needs to
//! recover from a short read treats [`PrefixError::UnexpectedEnd`] as "need more bytes" and retries
//! from the start of the (retained) buffer. This transactional style keeps the codings themselves
//! free of retained state while still supporting fragmented input.

use rama_core::bytes::{BufMut, Bytes, BytesMut};

use crate::proto::h2::hpack::{DecoderError, huffman};

/// An error decoding a prefixed integer or string.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum PrefixError {
    /// The buffer ended before the value was complete; feed more bytes and retry.
    UnexpectedEnd,
    /// The encoded integer does not fit in a `u64`.
    IntegerOverflow,
    /// A Huffman-encoded string contained an invalid code or padding.
    InvalidHuffman,
    /// The encoded length was impossible within the bound, or decoded output reached it.
    LengthLimitExceeded,
}

impl core::fmt::Display for PrefixError {
    fn fmt(&self, f: &mut core::fmt::Formatter<'_>) -> core::fmt::Result {
        f.write_str(match self {
            Self::UnexpectedEnd => "unexpected end of QPACK input",
            Self::IntegerOverflow => "QPACK integer overflow",
            Self::InvalidHuffman => "invalid QPACK Huffman string",
            Self::LengthLimitExceeded => "QPACK string length limit exceeded",
        })
    }
}

impl std::error::Error for PrefixError {}

impl From<DecoderError> for PrefixError {
    fn from(_: DecoderError) -> Self {
        // the shared Huffman decoder only fails with an invalid code or padding for our inputs.
        Self::InvalidHuffman
    }
}

/// Number of wire bytes needed by a prefixed integer.
#[must_use]
pub fn int_encoded_len(value: u64, prefix_bits: u8) -> usize {
    debug_assert!((1..=8).contains(&prefix_bits));
    let mask = (1u64 << prefix_bits) - 1;
    if value < mask {
        1
    } else {
        let remainder = value - mask;
        1 + ((64 - remainder.leading_zeros()) as usize)
            .div_ceil(7)
            .max(1)
    }
}

/// Number of wire bytes needed by a string, including its length prefix.
#[must_use]
pub fn string_encoded_len(data: &[u8], prefix_bits: u8, huffman: bool) -> usize {
    let payload_len = if huffman {
        huffman::encoded_len(data)
    } else {
        data.len()
    };
    int_encoded_len(payload_len as u64, prefix_bits) + payload_len
}

/// Encode `value` as a prefixed integer with an `prefix_bits`-bit prefix, OR-ing `flags` into the
/// high `8 - prefix_bits` bits of the first byte (RFC 9204 §4.1.1).
///
/// `flags` must not set any of the low `prefix_bits` bits.
pub fn encode_int<B: BufMut>(dst: &mut B, value: u64, prefix_bits: u8, flags: u8) {
    debug_assert!((1..=8).contains(&prefix_bits));
    let mask = (1u16 << prefix_bits) - 1;
    debug_assert_eq!(flags as u16 & mask, 0, "flags overlap the integer prefix");
    let mask = mask as u64;
    if value < mask {
        dst.put_u8(flags | value as u8);
        return;
    }
    dst.put_u8(flags | mask as u8);
    let mut remainder = value - mask;
    while remainder >= 128 {
        dst.put_u8((remainder as u8 & 0x7f) | 0x80);
        remainder >>= 7;
    }
    dst.put_u8(remainder as u8);
}

/// Decode a prefixed integer with an `prefix_bits`-bit prefix from `src`, consuming the bytes it
/// uses (RFC 9204 §4.1.1). High bits of the first byte above the prefix are ignored — a caller
/// reads any representation flags from the first byte before calling this.
pub fn decode_int(src: &mut &[u8], prefix_bits: u8) -> Result<u64, PrefixError> {
    debug_assert!((1..=8).contains(&prefix_bits));
    let (&first, rest) = src.split_first().ok_or(PrefixError::UnexpectedEnd)?;
    let mask = ((1u16 << prefix_bits) - 1) as u8;
    let mut value = u64::from(first & mask);
    if (first & mask) != mask {
        *src = rest;
        return Ok(value);
    }
    // continuation bytes, 7 bits each, high bit = "more"
    let mut cursor = rest;
    let mut shift = 0u32;
    loop {
        let (&byte, next) = cursor.split_first().ok_or(PrefixError::UnexpectedEnd)?;
        cursor = next;
        if shift >= 64 {
            return Err(PrefixError::IntegerOverflow);
        }
        let digit = u64::from(byte & 0x7f);
        let shifted = digit << shift;
        // detect overflow of the shift itself
        if (shifted >> shift) != digit {
            return Err(PrefixError::IntegerOverflow);
        }
        value = value
            .checked_add(shifted)
            .ok_or(PrefixError::IntegerOverflow)?;
        shift += 7;
        if byte & 0x80 == 0 {
            break;
        }
    }
    *src = cursor;
    Ok(value)
}

/// Encode a string literal with an `prefix_bits`-bit length prefix (RFC 9204 §4.1.2).
///
/// `flags` occupies the bits above the Huffman bit; the Huffman bit itself is bit `prefix_bits`.
pub fn encode_string<B: BufMut>(
    dst: &mut B,
    data: &[u8],
    prefix_bits: u8,
    flags: u8,
    huffman: bool,
) {
    encode_string_payload(
        dst,
        data,
        prefix_bits,
        flags,
        huffman.then(|| huffman::encoded_len(data)),
    );
}

/// A borrowed string encoding plan with an exact output length.
///
/// Computes the Huffman length at most once, sharing the decision between output-budget
/// checks and encoding without allocating a temporary buffer.
#[derive(Debug)]
pub struct StringEncoder<'a> {
    data: &'a [u8],
    prefix_bits: u8,
    huffman_len: Option<usize>,
}

impl<'a> StringEncoder<'a> {
    /// Plan a string with a `prefix_bits`-bit length prefix. If `allow_huffman` is false,
    /// use plain encoding without computing a Huffman length.
    #[must_use]
    pub fn new(data: &'a [u8], prefix_bits: u8, allow_huffman: bool) -> Self {
        debug_assert!((1..=7).contains(&prefix_bits));
        let huffman_len = allow_huffman
            .then(|| huffman::encoded_len(data))
            .filter(|len| *len < data.len());
        Self {
            data,
            prefix_bits,
            huffman_len,
        }
    }

    /// Force Huffman encoding, including strings whose encoded form is not smaller.
    /// This preserves a caller's explicit wire preference; [`Self::new`] instead
    /// chooses plain encoding for ties and expansions.
    #[must_use]
    pub fn new_huffman(data: &'a [u8], prefix_bits: u8) -> Self {
        debug_assert!((1..=7).contains(&prefix_bits));
        Self {
            data,
            prefix_bits,
            huffman_len: Some(huffman::encoded_len(data)),
        }
    }

    /// The exact wire length, including the length prefix.
    #[must_use]
    pub fn encoded_len(&self) -> usize {
        let len = self.huffman_len.unwrap_or(self.data.len());
        int_encoded_len(len as u64, self.prefix_bits) + len
    }

    /// Write the planned representation, with `flags` above the Huffman bit.
    pub fn encode<B: BufMut>(&self, dst: &mut B, flags: u8) {
        encode_string_payload(dst, self.data, self.prefix_bits, flags, self.huffman_len);
    }
}

fn encode_string_payload<B: BufMut>(
    dst: &mut B,
    data: &[u8],
    prefix_bits: u8,
    flags: u8,
    huffman_len: Option<usize>,
) {
    if let Some(encoded_len) = huffman_len {
        let huffman_flag = 1u8 << prefix_bits;
        encode_int(dst, encoded_len as u64, prefix_bits, flags | huffman_flag);
        huffman::encode(data, dst);
    } else {
        encode_int(dst, data.len() as u64, prefix_bits, flags);
        dst.put_slice(data);
    }
}

/// A decoded QPACK string literal, plus whether it was Huffman-encoded on the wire.
#[derive(Clone, PartialEq, Eq, Debug)]
pub struct DecodedString {
    /// The decoded bytes.
    pub value: BytesMut,
    /// Whether the wire representation used Huffman coding.
    pub huffman: bool,
}

/// Decode a string literal with an `prefix_bits`-bit length prefix, rejecting a decoded length
/// above `max_len` (RFC 9204 §4.1.2). Plain lengths are checked before allocating;
/// Huffman output is bounded during decoding.
pub fn decode_string(
    src: &mut &[u8],
    prefix_bits: u8,
    max_len: usize,
) -> Result<DecodedString, PrefixError> {
    let decoded = decode_string_shared(src, prefix_bits, max_len, None)?;
    Ok(DecodedString {
        value: decoded
            .value
            .try_into_mut()
            .unwrap_or_else(|bytes| BytesMut::from(bytes.as_ref())),
        huffman: decoded.huffman,
    })
}

pub(super) struct SharedDecodedString {
    pub value: Bytes,
    pub huffman: bool,
}

/// Read and bound a string envelope without inspecting or allocating its body.
/// A valid Huffman symbol takes at most 30 bits; padding takes at most seven.
/// This wire bound rejects impossible lengths early without rejecting valid
/// strings whose encoded representation is larger than the decoded output.
pub(super) fn string_payload<'a>(
    src: &mut &'a [u8],
    prefix_bits: u8,
    max_len: usize,
) -> Result<(&'a [u8], bool), PrefixError> {
    let mut cursor = *src;
    let first = *cursor.first().ok_or(PrefixError::UnexpectedEnd)?;
    let huffman = first & (1 << prefix_bits) != 0;
    let len = decode_int(&mut cursor, prefix_bits)?;
    let max_wire_len = if huffman {
        (max_len as u64).saturating_mul(30).saturating_add(7) / 8
    } else {
        max_len as u64
    };
    if len > max_wire_len {
        return Err(PrefixError::LengthLimitExceeded);
    }
    let len = usize::try_from(len).map_err(|_overflow| PrefixError::LengthLimitExceeded)?;
    if cursor.len() < len {
        return Err(PrefixError::UnexpectedEnd);
    }
    let (raw, rest) = cursor.split_at(len);
    *src = rest;
    Ok((raw, huffman))
}

pub(super) fn decode_string_shared(
    src: &mut &[u8],
    prefix_bits: u8,
    max_len: usize,
    backing: Option<&Bytes>,
) -> Result<SharedDecodedString, PrefixError> {
    let (raw, huffman) = string_payload(src, prefix_bits, max_len)?;
    let value = if huffman {
        let mut buf = BytesMut::new();
        huffman::decode_bounded(raw, &mut buf, max_len)
            .map_err(|error| match error {
                huffman::BoundedDecodeError::InvalidCode => PrefixError::InvalidHuffman,
                huffman::BoundedDecodeError::LengthLimit => PrefixError::LengthLimitExceeded,
            })?
            .freeze()
    } else if let Some(backing) = backing {
        backing.slice_ref(raw)
    } else {
        Bytes::copy_from_slice(raw)
    };
    Ok(SharedDecodedString { value, huffman })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn adaptive_string_size_matches_output_at_prefix_boundaries() {
        for byte in 0..=u8::MAX {
            for len in [0, 1, 7, 31, 127, 128] {
                let input = vec![byte; len];
                for bits in [3, 5, 7] {
                    let huffman_len = huffman::encoded_len(&input);
                    for allow_huffman in [false, true] {
                        let plan = StringEncoder::new(&input, bits, allow_huffman);
                        let mut wire = BytesMut::new();
                        plan.encode(&mut wire, 0);
                        assert_eq!(plan.encoded_len(), wire.len());
                        assert_eq!(
                            wire[0] & (1 << bits) != 0,
                            allow_huffman && huffman_len < len
                        );
                        assert!(wire.len() <= string_encoded_len(&input, bits, false));
                        let decoded = decode_string(&mut &wire[..], bits, len).unwrap();
                        assert_eq!(&decoded.value[..], input);
                    }
                }
            }
        }
    }

    fn enc(value: u64, prefix_bits: u8, flags: u8) -> Vec<u8> {
        let mut out = BytesMut::new();
        encode_int(&mut out, value, prefix_bits, flags);
        out.to_vec()
    }

    #[test]
    fn exact_huffman_output_limits_all_octets() {
        for byte in 0..=u8::MAX {
            for len in [0, 1, 2, 10, 127] {
                let input = vec![byte; len];
                let mut encoded = BytesMut::new();
                encode_string(&mut encoded, &input, 7, 0, true);
                assert_eq!(string_encoded_len(&input, 7, true), encoded.len());
                assert_eq!(
                    decode_string(&mut &encoded[..], 7, len).unwrap().value,
                    input
                );
                if len > 0 {
                    assert_eq!(
                        decode_string(&mut &encoded[..], 7, len - 1),
                        Err(PrefixError::LengthLimitExceeded)
                    );
                }
            }
        }
    }

    #[test]
    fn encoded_integer_lengths_match_wire_at_boundaries() {
        for bits in 1..=8 {
            let mask = (1u64 << bits) - 1;
            for value in [
                0,
                mask - 1,
                mask,
                mask + 1,
                mask + 127,
                mask + 128,
                u64::MAX,
            ] {
                assert_eq!(int_encoded_len(value, bits), enc(value, bits, 0).len());
            }
        }
    }

    #[test]
    fn impossible_huffman_wire_length_fails_without_body() {
        let mut out = BytesMut::new();
        encode_int(&mut out, 1000, 7, 0x80);
        assert_eq!(
            decode_string(&mut &out[..], 7, 1),
            Err(PrefixError::LengthLimitExceeded)
        );
    }

    #[test]
    fn rfc7541_c1_examples() {
        // RFC 7541 C.1.1: 10 with a 5-bit prefix => 0x0a
        assert_eq!(enc(10, 5, 0), vec![0x0a]);
        // C.1.2: 1337 with a 5-bit prefix => 0x1f 0x9a 0x0a
        assert_eq!(enc(1337, 5, 0), vec![0x1f, 0x9a, 0x0a]);
        // C.1.3: 42 with an 8-bit prefix => 0x2a
        assert_eq!(enc(42, 8, 0), vec![0x2a]);
    }

    #[test]
    fn int_round_trip_all_widths() {
        for prefix_bits in 1..=8u8 {
            for value in [
                0u64,
                1,
                30,
                31,
                127,
                128,
                255,
                256,
                16383,
                16384,
                u32::MAX as u64,
                u64::MAX,
            ] {
                let bytes = enc(value, prefix_bits, 0);
                let mut cursor = &bytes[..];
                assert_eq!(
                    decode_int(&mut cursor, prefix_bits),
                    Ok(value),
                    "n={prefix_bits} v={value}"
                );
                assert!(cursor.is_empty());
            }
        }
    }

    #[test]
    fn flags_preserved_and_ignored_on_decode() {
        // 5-bit prefix, high 3 bits set as an opcode
        let bytes = enc(5, 5, 0b1010_0000);
        assert_eq!(bytes[0] & 0b1110_0000, 0b1010_0000);
        let mut cursor = &bytes[..];
        assert_eq!(decode_int(&mut cursor, 5), Ok(5));
    }

    #[test]
    fn int_incomplete_is_distinct() {
        // 1337, 5-bit prefix = 0x1f 0x9a 0x0a; truncate continuation
        let mut cursor = &[0x1fu8, 0x9a][..];
        assert_eq!(decode_int(&mut cursor, 5), Err(PrefixError::UnexpectedEnd));
        let mut empty: &[u8] = &[];
        assert_eq!(decode_int(&mut empty, 5), Err(PrefixError::UnexpectedEnd));
    }

    #[test]
    fn int_overflow_rejected() {
        // 11 continuation bytes with high bits set never terminates within u64
        let mut buf = vec![0xffu8]; // prefix all-ones (8-bit)
        buf.extend(std::iter::repeat_n(0xffu8, 10));
        buf.push(0x7f);
        let mut cursor = &buf[..];
        assert_eq!(
            decode_int(&mut cursor, 8),
            Err(PrefixError::IntegerOverflow)
        );
    }

    #[test]
    fn string_plain_round_trip() {
        let mut out = BytesMut::new();
        encode_string(&mut out, b"/index.html", 7, 0, false);
        let mut cursor = &out[..];
        let decoded = decode_string(&mut cursor, 7, 1024).unwrap();
        assert!(!decoded.huffman);
        assert_eq!(&decoded.value[..], b"/index.html");
        assert!(cursor.is_empty());
    }

    #[test]
    fn string_huffman_round_trip() {
        let mut out = BytesMut::new();
        encode_string(&mut out, b"www.example.com", 7, 0, true);
        let mut cursor = &out[..];
        let decoded = decode_string(&mut cursor, 7, 1024).unwrap();
        assert!(decoded.huffman);
        assert_eq!(&decoded.value[..], b"www.example.com");
    }

    #[test]
    fn string_invalid_huffman_padding_rejected() {
        // Huffman flag set, length 1, byte 0x00: symbol '0' (00000) then 000 padding, which is not
        // the required all-ones padding => invalid.
        let mut cursor = &[0x81u8, 0x00][..];
        assert_eq!(
            decode_string(&mut cursor, 7, 1024),
            Err(PrefixError::InvalidHuffman)
        );
    }

    #[test]
    fn string_length_limit_before_alloc() {
        // advertises a huge plain length; must be rejected without buffering
        let mut out = BytesMut::new();
        encode_int(&mut out, 1_000_000, 7, 0);
        let mut cursor = &out[..];
        assert_eq!(
            decode_string(&mut cursor, 7, 64),
            Err(PrefixError::LengthLimitExceeded)
        );
    }

    #[test]
    fn string_incomplete_body() {
        let mut out = BytesMut::new();
        encode_string(&mut out, b"hello", 7, 0, false);
        let truncated = &out[..out.len() - 2];
        let mut cursor = truncated;
        assert_eq!(
            decode_string(&mut cursor, 7, 1024),
            Err(PrefixError::UnexpectedEnd)
        );
    }
}
