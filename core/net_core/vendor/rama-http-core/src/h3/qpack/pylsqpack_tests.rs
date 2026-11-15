//! Reproducible independent ls-qpack traces, including duplicates, Huffman names, blocked
//! sections, negative Delta Base, and repeated Required Insert Count wraps at small capacities.

use super::{Decoder, DecoderConfig};
use rama_core::bytes::Bytes;

fn hex(value: &str) -> Bytes {
    let (pairs, remainder) = value.as_bytes().as_chunks::<2>();
    assert!(remainder.is_empty());
    pairs
        .iter()
        .map(|[hi, lo]| rama_utils::hex::decode_pair(*hi, *lo).unwrap())
        .collect::<Vec<_>>()
        .into()
}

#[test]
fn pylsqpack_dynamic_traces_at_every_fragment_size() {
    // Test each instruction byte boundary, with independently delayed field sections. Generated
    // fixtures are deterministic and runtime tests require neither Python nor external packages.
    for fragment_size in 1..=16 {
        let mut decoder = Decoder::new(DecoderConfig::default());
        let mut sections = 0;
        let mut blocked_sections = 0;
        for (line_number, line) in include_str!("fixtures/pylsqpack.tsv").lines().enumerate() {
            if line.starts_with('#') {
                continue;
            }
            let columns: Vec<_> = line.split('\t').collect();
            if columns[0] == "C" {
                decoder = Decoder::new(DecoderConfig {
                    max_table_capacity: columns[1].parse().unwrap(),
                    max_blocked_streams: 4,
                    ..Default::default()
                });
                for part in hex(columns[2]).chunks(fragment_size) {
                    decoder.feed_encoder_stream(part).unwrap();
                }
                continue;
            }
            let stream = columns[1].parse().unwrap();
            let control = hex(columns[2]);
            let section = hex(columns[3]);
            let expected_blocked = columns[4] == "1";
            let mut decoded = decoder.decode_field_section(stream, section).unwrap();
            assert_eq!(
                decoded.is_none(),
                expected_blocked,
                "fixture line {line_number}"
            );
            for part in control.chunks(fragment_size) {
                decoder.feed_encoder_stream(part).unwrap();
            }
            if expected_blocked {
                blocked_sections += 1;
                let mut ready = decoder.resume_blocked();
                assert_eq!(ready.len(), 1);
                let (resumed_stream, fields) = ready.remove(0);
                assert_eq!(resumed_stream, stream);
                decoded = Some(fields.unwrap());
            }
            let fields = decoded.unwrap();
            assert_eq!(fields.len(), 1);
            assert_eq!(
                fields[0].name,
                hex(columns[5]),
                "fixture line {line_number}"
            );
            assert_eq!(
                fields[0].value,
                hex(columns[6]),
                "fixture line {line_number}"
            );
            assert!(!fields[0].never_index);
            assert_eq!(decoder.blocked_stream_count(), 0);
            let _ = decoder.take_decoder_stream();
            sections += 1;
        }
        assert_eq!(sections, 288);
        assert!(blocked_sections > 100);
        // The final 256-byte trace crosses its modulo-16 RIC range repeatedly.
        assert!(decoder.insert_count() >= 32);
    }
}
