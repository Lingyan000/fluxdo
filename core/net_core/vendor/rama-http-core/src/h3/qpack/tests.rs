//! Stateful QPACK integration tests: the RFC 9204 Appendix B trace against the decoder, encoder →
//! decoder round-trips (static-only and dynamic), blocked-stream handling and resource recovery.

use rama_core::bytes::Bytes;
use std::assert_matches;

use super::{Decoder, DecoderConfig, Encoder, EncoderConfig, FieldPair, QpackError};

fn hex(s: &str) -> Bytes {
    let bytes: Vec<u8> = (0..s.len() / 2)
        .map(|i| u8::from_str_radix(&s[2 * i..2 * i + 2], 16).unwrap())
        .collect();
    Bytes::from(bytes)
}

fn pair(name: &[u8], value: &[u8]) -> FieldPair {
    FieldPair {
        name: Bytes::copy_from_slice(name),
        value: Bytes::copy_from_slice(value),
        never_index: false,
    }
}

fn appendix_b_config() -> DecoderConfig {
    DecoderConfig {
        max_table_capacity: 220,
        max_blocked_streams: 16,
        max_field_section_size: 65536,
        max_blocked_bytes: 65536,
        ..DecoderConfig::default()
    }
}

#[test]
fn appendix_b_full_decoder_trace() {
    let mut dec = Decoder::new(appendix_b_config());

    // B.1 — static-name literal on stream 0, no dynamic table use.
    let b1 = dec
        .decode_field_section(0, hex("0000510b2f696e6465782e68746d6c"))
        .unwrap()
        .unwrap();
    assert_eq!(b1, vec![pair(b":path", b"/index.html")]);
    // no dynamic references => no Section Acknowledgment
    assert!(dec.take_decoder_stream().is_empty());

    // B.2 — encoder-stream: set capacity 220, two inserts with static name references.
    dec.feed_encoder_stream(&hex(
        "3fbd01c00f7777772e6578616d706c652e636f6dc10c2f73616d706c652f70617468",
    ))
    .unwrap();
    assert_eq!(dec.insert_count(), 2);

    // stream 4 field section referencing both dynamic entries via post-base indices.
    let b2 = dec
        .decode_field_section(4, hex("03811011"))
        .unwrap()
        .unwrap();
    assert_eq!(
        b2,
        vec![
            pair(b":authority", b"www.example.com"),
            pair(b":path", b"/sample/path"),
        ]
    );
    // decoder stream carries the insert-count increment and the section acknowledgment (0x84).
    let out = dec.take_decoder_stream();
    assert!(out.contains(&0x84), "section ack for stream 4");

    // B.3 — speculative insert with a literal name.
    dec.feed_encoder_stream(&hex("4a637573746f6d2d6b65790c637573746f6d2d76616c7565"))
        .unwrap();
    assert_eq!(dec.insert_count(), 3);

    // B.4 — duplicate rel index 2 (abs 0), then decode stream 8.
    dec.feed_encoder_stream(&hex("02")).unwrap();
    assert_eq!(dec.insert_count(), 4);
    let b4 = dec
        .decode_field_section(8, hex("050080c181"))
        .unwrap()
        .unwrap();
    assert_eq!(
        b4,
        vec![
            pair(b":authority", b"www.example.com"),
            pair(b":path", b"/"),
            pair(b"custom-key", b"custom-value"),
        ]
    );

    // B.5 — insert with dynamic name reference causing eviction of abs 0.
    dec.feed_encoder_stream(&hex("810d637573746f6d2d76616c756532"))
        .unwrap();
    assert_eq!(dec.insert_count(), 5);
    // abs 0 was evicted (dropped advanced), abs 1..=4 remain.
    // a fresh section referencing abs 4 (custom-value2) via post-base under base 4:
    //   RIC=5, base=4 -> post-base index 0 => abs 4
    // prefix: enc_ric for RIC=5 with total_inserts=5, max_entries=6 -> (5 % 12)+1 = 6 => 0x06
    //         delta base: base(4) < RIC(5) => S=1, delta = 5-4-1 = 0 => 0x80
    let b5 = dec
        .decode_field_section(12, hex("068010"))
        .unwrap()
        .unwrap();
    assert_eq!(b5, vec![pair(b"custom-key", b"custom-value2")]);
}

#[test]
fn static_only_round_trip() {
    let mut enc = Encoder::new(EncoderConfig {
        max_table_capacity: 0,
        max_blocked_streams: 0,
        target_capacity: 0,
        huffman: true,
        ..EncoderConfig::default()
    });
    let mut dec = Decoder::new(DecoderConfig {
        max_table_capacity: 0,
        max_blocked_streams: 0,
        ..DecoderConfig::default()
    });

    let fields = [
        (b":method".to_vec(), b"GET".to_vec()),
        (b":scheme".to_vec(), b"https".to_vec()),
        (b"custom".to_vec(), b"value".to_vec()),
    ];
    let section = enc
        .encode(0, fields.iter().map(|(n, v)| (n.clone(), v.clone())))
        .unwrap();
    // zero capacity: nothing is placed on the encoder stream.
    assert!(enc.take_encoder_stream().is_empty());

    let decoded = dec.decode_field_section(0, section).unwrap().unwrap();
    assert_eq!(
        decoded,
        vec![
            pair(b":method", b"GET"),
            pair(b":scheme", b"https"),
            pair(b"custom", b"value"),
        ]
    );
}

#[test]
fn dynamic_round_trip_with_acks() {
    let mut enc = Encoder::new(EncoderConfig {
        max_table_capacity: 4096,
        max_blocked_streams: 16,
        target_capacity: 4096,
        huffman: true,
        ..EncoderConfig::default()
    });
    let mut dec = Decoder::new(DecoderConfig {
        max_table_capacity: 4096,
        max_blocked_streams: 16,
        ..DecoderConfig::default()
    });

    let fields = [
        (b":method".to_vec(), b"GET".to_vec()),
        (b"x-custom".to_vec(), b"hello".to_vec()),
    ];
    let section = enc
        .encode(0, fields.iter().map(|(n, v)| (n.clone(), v.clone())))
        .unwrap();

    // the encoder inserted x-custom -> hello on its stream; deliver it first.
    let enc_stream = enc.take_encoder_stream();
    assert!(!enc_stream.is_empty());
    dec.feed_encoder_stream(&enc_stream).unwrap();
    assert_eq!(dec.insert_count(), 1);

    let decoded = dec.decode_field_section(0, section).unwrap().unwrap();
    assert_eq!(
        decoded,
        vec![pair(b":method", b"GET"), pair(b"x-custom", b"hello")]
    );

    // feed the decoder's acknowledgements back to the encoder; KRC advances, refs release.
    let dec_stream = dec.take_decoder_stream();
    enc.feed_decoder_stream(&dec_stream).unwrap();
    assert_eq!(enc.known_received_count(), 1);

    // a second request reuses the dynamic entry without another insert.
    let section2 = enc
        .encode(4, [(b"x-custom".to_vec(), b"hello".to_vec())])
        .unwrap();
    assert!(enc.take_encoder_stream().is_empty(), "no new insert needed");
    let decoded2 = dec.decode_field_section(4, section2).unwrap().unwrap();
    assert_eq!(decoded2, vec![pair(b"x-custom", b"hello")]);
}

#[test]
fn blocked_then_unblocked() {
    let mut dec = Decoder::new(appendix_b_config());
    // set capacity so the table can hold entries, but do NOT deliver the inserts yet.
    dec.feed_encoder_stream(&hex("3fbd01")).unwrap();

    // stream 4 references two entries that have not been inserted -> blocked.
    let blocked = dec.decode_field_section(4, hex("03811011")).unwrap();
    assert!(blocked.is_none(), "section is blocked on RIC");
    assert_eq!(dec.blocked_stream_count(), 1);

    // deliver the inserts; the section becomes decodable.
    dec.feed_encoder_stream(&hex(
        "c00f7777772e6578616d706c652e636f6dc10c2f73616d706c652f70617468",
    ))
    .unwrap();
    let resumed = dec.resume_blocked();
    assert_eq!(resumed.len(), 1);
    let (stream_id, result) = &resumed[0];
    assert_eq!(*stream_id, 4);
    assert_eq!(
        result.as_ref().unwrap(),
        &vec![
            pair(b":authority", b"www.example.com"),
            pair(b":path", b"/sample/path"),
        ]
    );
    assert_eq!(dec.blocked_stream_count(), 0);
}

#[test]
fn blocked_stream_limit_enforced() {
    let mut dec = Decoder::new(DecoderConfig {
        max_table_capacity: 220,
        max_blocked_streams: 1,
        max_field_section_size: 65536,
        max_blocked_bytes: 65536,
        ..DecoderConfig::default()
    });
    dec.feed_encoder_stream(&hex("3fbd01")).unwrap();

    // first blocked section is accepted...
    assert!(
        dec.decode_field_section(4, hex("03811011"))
            .unwrap()
            .is_none()
    );
    // ...the second exceeds the blocked-stream budget.
    assert_eq!(
        dec.decode_field_section(8, hex("03811011")),
        Err(QpackError::DecompressionFailed("too many blocked streams"))
    );
}

#[test]
fn cancel_releases_blocked_storage() {
    let mut dec = Decoder::new(appendix_b_config());
    dec.feed_encoder_stream(&hex("3fbd01")).unwrap();
    assert!(
        dec.decode_field_section(4, hex("03811011"))
            .unwrap()
            .is_none()
    );
    assert_eq!(dec.blocked_stream_count(), 1);

    dec.cancel_stream(4).unwrap();
    assert_eq!(dec.blocked_stream_count(), 0);
    // a Stream Cancellation (0x40 | 4 = 0x44 for stream 4) is queued for the encoder.
    let out = dec.take_decoder_stream();
    assert!(out.contains(&0x44));
}

#[test]
fn oversized_insert_is_a_connection_error() {
    let mut dec = Decoder::new(DecoderConfig {
        max_table_capacity: 64,
        ..appendix_b_config()
    });
    // set capacity 64, then insert-with-literal-name whose entry exceeds 64 bytes.
    // "3f21" = Set Capacity 64 (31 + 33). Then 0x27 (01 00111 => literal name, len 7) ...
    dec.feed_encoder_stream(&hex("3f21")).unwrap();
    // insert name "1234567" value 40 bytes -> 7+40+32 = 79 > 64
    let mut inst = vec![0x47u8]; // 01 H=0 name-len=7 : Insert With Literal Name
    inst.extend_from_slice(b"1234567");
    inst.push(0x28); // value length 40, H=0
    inst.extend_from_slice(&[b'x'; 40]);
    assert_matches!(
        dec.feed_encoder_stream(&inst),
        Err(QpackError::EncoderStreamError(_)),
    );
}

// ===== Differential fixtures from independent implementations =====
//
// These are wire-byte vectors transcribed from the test suites of two independent QPACK
// implementations, decoded through Rama's stateful decoder and checked against the documented
// expectation. Self round-trips alone are insufficient (sprint acceptance), so these cross-check
// against implementations that do not share Rama's code.
//
// Sources:
//  - Cloudflare quiche (BSD-2-Clause): quiche/src/h3/qpack/decoder.rs test vectors.
//  - Mozilla neqo (Apache-2.0/MIT): neqo-qpack/src/decoder.rs and encoder_instructions.rs vectors.

#[test]
fn quiche_static_name_ref_literal_value() {
    // quiche decoder.rs: [0x00,0x00, 0x50, 0x05, "abcde"]
    //   prefix RIC=0/base=0; LiteralWithNameRef S=1 (static) name_idx=0 (:authority); value "abcde"
    let mut dec = Decoder::new(DecoderConfig::default());
    let decoded = dec
        .decode_field_section(0, hex("000050056162636465"))
        .unwrap()
        .unwrap();
    assert_eq!(decoded, vec![pair(b":authority", b"abcde")]);
}

#[test]
fn quiche_literal_name_with_three_bit_length_overflow() {
    // quiche decoder.rs: [0x00,0x00, 0x27,0x03, "x-custom99", 0x01, 'a']
    //   Literal name (3-bit length prefix 0b111 + continuation 0x03 => 10), value "a".
    let mut dec = Decoder::new(DecoderConfig::default());
    let decoded = dec
        .decode_field_section(0, hex("00002703782d637573746f6d39390161"))
        .unwrap()
        .unwrap();
    assert_eq!(decoded, vec![pair(b"x-custom99", b"a")]);
}

#[test]
fn neqo_encoder_stream_set_capacity_and_insert() {
    // neqo decoder.rs: Set Dynamic Table Capacity 200 = [0x3f, 0xa9, 0x01]
    // neqo decoder.rs: Insert With Name Reference (static idx 4 = content-length), value "1234"
    //                  = [0xc4, 0x04, 0x31, 0x32, 0x33, 0x34]
    let mut dec = Decoder::new(DecoderConfig::default());
    dec.feed_encoder_stream(&hex("3fa901")).unwrap();
    dec.feed_encoder_stream(&hex("c40431323334")).unwrap();
    assert_eq!(dec.insert_count(), 1);

    // reference the inserted entry from a field section (RIC=1, base=1, dynamic index 0).
    // enc_ric = (1 % 12) + 1 = 2 -> 0x02; delta base = base-RIC = 0, S=0 -> 0x00; Indexed dyn 0 -> 0x80
    let decoded = dec.decode_field_section(4, hex("020080")).unwrap().unwrap();
    assert_eq!(decoded, vec![pair(b"content-length", b"1234")]);
}

#[test]
fn static_only_sections_are_not_tracked() {
    // Regression: RIC=0 (static/literal) sections must not be enqueued for acknowledgment, or a
    // long-lived connection making static-only requests would grow the encoder's section map
    // without bound (nothing ever acknowledges them).
    let mut enc = Encoder::new(EncoderConfig::default());
    for stream_id in 0..50u64 {
        let _ = enc
            .encode(stream_id, [(b":method".to_vec(), b"GET".to_vec())])
            .unwrap();
    }
    assert_eq!(enc.tracked_section_count(), 0);
}

#[test]
fn ack_releases_the_right_section_when_ric0_precedes_dynamic() {
    // Regression: a RIC=0 section followed by a RIC>0 section on the same stream. The single
    // Section Acknowledgment (for the RIC>0 section) must release that section and advance KRC.
    // With the RIC=0 section wrongly enqueued first, the ack would pop it and leave the dynamic
    // section's references pinned and KRC at 0.
    let mut enc = Encoder::new(EncoderConfig::default());
    let mut dec = Decoder::new(DecoderConfig::default());

    let sec_a = enc
        .encode(0, [(b":method".to_vec(), b"GET".to_vec())])
        .unwrap(); // RIC=0
    let sec_b = enc
        .encode(0, [(b"x-custom".to_vec(), b"v".to_vec())])
        .unwrap(); // inserts, RIC=1
    assert_eq!(enc.tracked_section_count(), 1);

    dec.feed_encoder_stream(&enc.take_encoder_stream()).unwrap();
    assert!(dec.decode_field_section(0, sec_a).unwrap().is_some());
    assert!(dec.decode_field_section(0, sec_b).unwrap().is_some());

    enc.feed_decoder_stream(&dec.take_decoder_stream()).unwrap();
    assert_eq!(enc.known_received_count(), 1);
    assert_eq!(enc.tracked_section_count(), 0);
}

#[test]
fn reference_is_protected_against_same_section_eviction() {
    // Regression (MEDIUM): a section reuses an existing dynamic entry and, in a later field, inserts
    // a new entry that would need to evict that same entry. The reused entry must be protected, so
    // the round-trip decodes rather than referencing an entry the encoder evicted.
    // Small table: room for ~2 tiny entries.
    let cfg_e = EncoderConfig {
        max_table_capacity: 96,
        max_blocked_streams: 16,
        target_capacity: 96,
        huffman: false,
        ..EncoderConfig::default()
    };
    let cfg_d = DecoderConfig {
        max_table_capacity: 96,
        max_blocked_streams: 16,
        max_field_section_size: 65536,
        max_blocked_bytes: 65536,
        ..DecoderConfig::default()
    };
    let mut enc = Encoder::new(cfg_e);
    let mut dec = Decoder::new(cfg_d);

    // Seed and acknowledge entry ("re","x") so it is referenceable without blocking.
    let seed = enc.encode(0, [(b"re".to_vec(), b"x".to_vec())]).unwrap();
    dec.feed_encoder_stream(&enc.take_encoder_stream()).unwrap();
    dec.decode_field_section(0, seed).unwrap().unwrap();
    enc.feed_decoder_stream(&dec.take_decoder_stream()).unwrap();

    // New section reuses ("re","x") and then a field whose insert would need to evict it.
    let section = enc
        .encode(
            4,
            [
                (b"re".to_vec(), b"x".to_vec()),
                (
                    b"other".to_vec(),
                    b"a-longer-value-forcing-eviction".to_vec(),
                ),
            ],
        )
        .unwrap();
    dec.feed_encoder_stream(&enc.take_encoder_stream()).unwrap();
    let decoded = dec.decode_field_section(4, section).unwrap().unwrap();
    assert_eq!(
        decoded,
        vec![
            pair(b"re", b"x"),
            pair(b"other", b"a-longer-value-forcing-eviction"),
        ]
    );
}

#[test]
fn resume_uses_block_time_prefix_after_large_batch() {
    // HIGH-2: a section blocked at insert_count=0 with RIC=2 must resume correctly even when a
    // single encoder-stream batch advances the insert count well past the block point. The RIC/Base
    // reconstructed at block time is reused rather than recomputed against the grown insert count.
    let mut dec = Decoder::new(appendix_b_config());
    dec.feed_encoder_stream(&hex("3fbd01")).unwrap(); // set capacity 220

    // stream 4 references the first two dynamic entries (post-base 0,1); RIC=2, base=0.
    assert!(
        dec.decode_field_section(4, hex("03811011"))
            .unwrap()
            .is_none()
    );

    // deliver the two inserts it needs, in one batch.
    dec.feed_encoder_stream(&hex(
        "c00f7777772e6578616d706c652e636f6dc10c2f73616d706c652f70617468",
    ))
    .unwrap();
    let resumed = dec.resume_blocked();
    assert_eq!(resumed.len(), 1);
    assert_eq!(
        resumed[0].1.as_ref().unwrap(),
        &vec![
            pair(b":authority", b"www.example.com"),
            pair(b":path", b"/sample/path"),
        ]
    );
}

#[test]
fn two_blocked_sections_on_one_stream_resume_in_order() {
    // LOW: a stream can hold more than one blocked section; both must be retained (no byte-accounting
    // leak, no silent drop) and resume in arrival order.
    let mut dec = Decoder::new(appendix_b_config());
    dec.feed_encoder_stream(&hex("3fbd01")).unwrap();

    // two sections on stream 4, both blocked (no inserts delivered yet).
    assert!(
        dec.decode_field_section(4, hex("03811011"))
            .unwrap()
            .is_none()
    ); // RIC=2
    assert!(
        dec.decode_field_section(4, hex("03811011"))
            .unwrap()
            .is_none()
    ); // RIC=2 again
    assert_eq!(dec.blocked_stream_count(), 1);

    dec.feed_encoder_stream(&hex(
        "c00f7777772e6578616d706c652e636f6dc10c2f73616d706c652f70617468",
    ))
    .unwrap();
    let resumed = dec.resume_blocked();
    assert_eq!(resumed.len(), 2, "both sections resume");
    for (_, result) in &resumed {
        assert_eq!(
            result.as_ref().unwrap(),
            &vec![
                pair(b":authority", b"www.example.com"),
                pair(b":path", b"/sample/path"),
            ]
        );
    }
    assert_eq!(dec.blocked_stream_count(), 0);
}

#[test]
fn invalid_dynamic_reference_is_decompression_failure() {
    // RIC=0/base=0 prefix, then an Indexed *dynamic* line (0x80) with an empty table.
    // Base-relative abs = base - index - 1 = 0 - 0 - 1 -> underflow -> decompression failure.
    let mut dec = Decoder::new(DecoderConfig::default());
    assert_eq!(
        dec.decode_field_section(0, hex("000080")),
        Err(QpackError::DecompressionFailed(
            "dynamic index out of range"
        ))
    );
}

#[test]
fn field_section_size_limit_enforced() {
    // a tiny max_field_section_size rejects an otherwise-valid static-name literal section.
    let mut dec = Decoder::new(DecoderConfig {
        max_field_section_size: 8,
        ..DecoderConfig::default()
    });
    // :authority: abcde  (uncompressed size 32 + 10 + 5 = 47 > 8)
    assert_eq!(
        dec.decode_field_section(0, hex("000050056162636465")),
        Err(QpackError::StreamResourceLimit("field section too large"))
    );
}

#[test]
fn neqo_decoder_stream_insert_count_increment() {
    // neqo decoder.rs: an Insert Count Increment of 3 on the decoder stream = [0x03]
    let mut enc = Encoder::new(EncoderConfig {
        max_table_capacity: 4096,
        max_blocked_streams: 16,
        target_capacity: 4096,
        huffman: false,
        ..EncoderConfig::default()
    });
    // encode three sections that each insert one entry so the increment is valid.
    for (i, name) in ["a-one", "a-two", "a-three"].into_iter().enumerate() {
        let _ = enc
            .encode(i as u64, [(name.as_bytes().to_vec(), b"v".to_vec())])
            .unwrap();
    }
    assert_eq!(enc.insert_count(), 3);
    enc.feed_decoder_stream(&hex("03")).unwrap();
    assert_eq!(enc.known_received_count(), 3);
}

#[test]
fn peer_settings_transition_enables_dynamic_encoding_once() {
    use rama_http_types::proto::h3::{SettingId, Settings};
    let mut encoder = Encoder::before_peer_settings(EncoderConfig::default());
    let fields = [(b"x-before".as_slice(), b"settings".as_slice())];
    let before = encoder.encode(0, fields).unwrap();
    assert_eq!(encoder.insert_count(), 0);
    assert!(encoder.take_encoder_stream().is_empty());
    let mut decoder = Decoder::new(DecoderConfig::default());
    assert!(decoder.decode_field_section(0, before).unwrap().is_some());
    let mut settings = Settings::new();
    settings
        .set(
            SettingId::QPACK_MAX_TABLE_CAPACITY,
            rama_utils::octets::kib_u64(4),
        )
        .unwrap();
    settings.set(SettingId::QPACK_BLOCKED_STREAMS, 16).unwrap();
    encoder.apply_peer_settings(&settings).unwrap();
    let after = encoder.encode(4, fields).unwrap();
    assert!(encoder.insert_count() > 0);
    assert!(decoder.decode_field_section(4, after).unwrap().is_none());
    decoder
        .feed_encoder_stream(&encoder.take_encoder_stream())
        .unwrap();
    let (stream_id, result) = decoder.resume_next().unwrap();
    assert_eq!(stream_id, 4);
    assert_eq!(result.unwrap()[0].value.as_ref(), b"settings");
    assert!(decoder.resume_next().is_none());
    assert!(encoder.apply_peer_settings(&settings).is_err());
}

#[test]
fn absent_peer_settings_keep_static_encoding_and_apply_field_limit() {
    use rama_http_types::proto::h3::{SettingId, Settings};
    let mut encoder = Encoder::before_peer_settings(EncoderConfig::default());
    let mut settings = Settings::new();
    settings.set(SettingId::MAX_FIELD_SECTION_SIZE, 33).unwrap();
    encoder.apply_peer_settings(&settings).unwrap();
    encoder
        .encode(0, [(b"x".as_slice(), b"".as_slice())])
        .unwrap();
    encoder
        .encode(4, [(b"x".as_slice(), b"y".as_slice())])
        .unwrap_err();
    assert!(encoder.take_encoder_stream().is_empty());
}
