use super::table::{ENCODE_CODE_LENGTHS, ENCODE_CODES};

use rama_core::bytes::{BufMut, BytesMut};

/// Exact encoded length, without allocating a temporary output buffer.
pub(crate) fn encoded_len(src: &[u8]) -> usize {
    src.iter()
        .map(|&b| usize::from(ENCODE_CODE_LENGTHS[b as usize]))
        .sum::<usize>()
        .div_ceil(8)
}

pub(crate) fn encode<B: BufMut>(src: &[u8], dst: &mut B) {
    encode_bytes(src.iter().copied(), dst);
}

pub(crate) fn encode_lowercase_ascii(src: &[u8], dst: &mut BytesMut) {
    encode_bytes(src.iter().map(|b| b.to_ascii_lowercase()), dst);
}

fn encode_bytes<B: BufMut>(bytes: impl IntoIterator<Item = u8>, dst: &mut B) {
    let mut bits = 0u64;
    let mut bits_len = 0;

    for b in bytes {
        let nbits = usize::from(ENCODE_CODE_LENGTHS[b as usize]);
        let code = u64::from(ENCODE_CODES[b as usize]);

        bits = (bits << nbits) | code;
        bits_len += nbits;

        if bits_len >= 32 {
            let remaining = bits_len - 32;
            dst.put_u32((bits >> remaining) as u32);

            bits_len = remaining;
            if remaining == 0 {
                bits = 0;
            } else {
                bits &= (1 << remaining) - 1;
            }
        }
    }

    if bits_len != 0 {
        // Pad the final byte with the EOS prefix (all ones).
        let padding = (8 - (bits_len % 8)) % 8;
        bits = (bits << padding) | ((1 << padding) - 1);
        bits_len += padding;

        while bits_len != 0 {
            bits_len -= 8;
            dst.put_u8((bits >> bits_len) as u8);
        }
    }
}

#[cfg(test)]
mod test {
    use super::*;

    #[test]
    fn encode_single_byte() {
        let mut dst = BytesMut::with_capacity(1);

        encode(b"o", &mut dst);
        assert_eq!(&dst[..], &[0b00111111]);

        dst.clear();
        encode(b"0", &mut dst);
        assert_eq!(&dst[..], &[7]);

        dst.clear();
        encode(b"A", &mut dst);
        assert_eq!(&dst[..], &[(0x21 << 2) + 3]);
    }

    #[test]
    fn encode_rfc_example() {
        let mut dst = BytesMut::new();

        encode(b"www.example.com", &mut dst);

        assert_eq!(
            &dst[..],
            &[
                0xf1, 0xe3, 0xc2, 0xe5, 0xf2, 0x3a, 0x6b, 0xa0, 0xab, 0x90, 0xf4, 0xff
            ]
        );
    }

    #[test]
    fn encoded_len_is_exact() {
        for len in 0..300 {
            let src: Vec<u8> = (0..len).map(|i| (i * 31) as u8).collect();
            let mut dst = BytesMut::new();
            encode(&src, &mut dst);
            assert_eq!(encoded_len(&src), dst.len(), "len={len}");
        }
    }

    #[test]
    fn encode_lowercase_ascii_matches_encoding_lowercased() {
        let mut lowered = BytesMut::new();
        encode_lowercase_ascii(b"Content-Type", &mut lowered);
        let mut expected = BytesMut::new();
        encode(b"content-type", &mut expected);
        assert_eq!(lowered, expected);
    }
}
