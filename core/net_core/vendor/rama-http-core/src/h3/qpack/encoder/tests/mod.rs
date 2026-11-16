use super::{EncodeField, Encoder, EncoderConfig};
use crate::h3::qpack::{Decoder, DecoderConfig, ErrorScope, QpackError};
use rama_core::bytes::{Bytes, BytesMut};
use rama_http_types::proto::h3::{
    Code, Setting, SettingId, Settings,
    observation::ObservedFieldRepresentation,
    qpack::{
        DecoderInstruction, EncoderInstruction, EncoderPreferences, FieldLine, FieldSectionBase,
        HeaderPrefix,
        encoding::{FieldPreferences, Representation},
    },
};
use rama_utils::octets::kib;
use std::assert_matches;
use std::collections::BTreeMap;

fn feedback(inst: DecoderInstruction) -> Bytes {
    let mut b = BytesMut::new();
    inst.encode(&mut b);
    b.freeze()
}

#[test]
fn decoder_feedback_every_split_and_bytewise() {
    for stream_id in [0, 4, 64, 128, 16384, (1u64 << 62) - 4] {
        for cancel in [false, true] {
            let inst = if cancel {
                DecoderInstruction::StreamCancellation { stream_id }
            } else {
                DecoderInstruction::SectionAcknowledgment { stream_id }
            };
            let wire = feedback(inst);
            for split in 0..=wire.len() {
                let mut enc = Encoder::new(EncoderConfig::default());
                enc.encode(stream_id, [(b"custom", b"value")]).unwrap();
                enc.feed_decoder_stream(&wire[..split]).unwrap();
                enc.feed_decoder_stream(&wire[split..]).unwrap();
                assert!(enc.is_at_decoder_instruction_boundary());
                assert_eq!(enc.tracked_section_count(), 0);
                assert_eq!(enc.tracked_reference_count(), 0);
                assert_eq!(enc.known_received_count(), u64::from(!cancel));
            }
            let mut enc = Encoder::new(EncoderConfig::default());
            enc.encode(stream_id, [(b"custom", b"value")]).unwrap();
            for byte in wire {
                enc.feed_decoder_stream(&[byte]).unwrap();
            }
            assert_eq!(enc.tracked_section_count(), 0);
        }
    }
}

#[test]
fn increments_zero_excess_and_overflow_are_rejected_without_changing_state() {
    let mut enc = Encoder::new(EncoderConfig::default());
    enc.encode(0, [(b"a", b"b")]).unwrap();
    for increment in [0, 2, u64::MAX] {
        assert_matches!(
            enc.on_decoder_instruction(DecoderInstruction::InsertCountIncrement { increment }),
            Err(QpackError::DecoderStreamError(_)),
        );
        assert_eq!(enc.known_received_count(), 0);
    }
    enc.on_decoder_instruction(DecoderInstruction::SectionAcknowledgment { stream_id: 0 })
        .unwrap();
    assert!(enc.feed_decoder_stream(&[1]).is_err());
    assert_eq!(enc.known_received_count(), 1);
}

#[test]
fn fragmented_increment_and_truncated_overflow() {
    let mut enc = Encoder::new(EncoderConfig {
        target_capacity: 8192,
        max_table_capacity: 8192,
        ..EncoderConfig::default()
    });
    for n in 0..64 {
        enc.encode(0, [(format!("x-{n}"), "y")]).unwrap();
    }
    let wire = feedback(DecoderInstruction::InsertCountIncrement { increment: 64 });
    assert_eq!(wire.len(), 2);
    enc.feed_decoder_stream(&wire[..1]).unwrap();
    assert!(!enc.is_at_decoder_instruction_boundary());
    assert_eq!(enc.known_received_count(), 0);
    enc.feed_decoder_stream(&wire[1..]).unwrap();
    assert_eq!(enc.known_received_count(), 64);
    let mut enc = Encoder::new(EncoderConfig::default());
    for _ in 0..10 {
        enc.feed_decoder_stream(&[0xff]).unwrap();
    }
    assert!(enc.feed_decoder_stream(&[0xff]).is_err());
}

#[test]
fn cancellation_does_not_acknowledge_insert_or_allow_eviction() {
    let mut enc = Encoder::new(EncoderConfig {
        max_table_capacity: 34,
        target_capacity: 34,
        huffman: false,
        ..EncoderConfig::default()
    });
    enc.encode(0, [(b"a", b"b")]).unwrap();
    let first_insert = enc.take_encoder_stream();
    enc.on_decoder_instruction(DecoderInstruction::StreamCancellation { stream_id: 0 })
        .unwrap();
    enc.encode(4, [(b"c", b"d")]).unwrap();
    enc.on_decoder_instruction(DecoderInstruction::StreamCancellation { stream_id: 4 })
        .unwrap();
    let last = enc.encode(8, [(b"e", b"f")]).unwrap();
    assert_eq!(enc.insert_count(), 1);
    assert_eq!(enc.known_received_count(), 0);
    let mut dec = Decoder::new(DecoderConfig {
        max_table_capacity: 34,
        ..DecoderConfig::default()
    });
    let fields = dec.decode_field_section(8, last).unwrap().unwrap();
    assert_eq!(&fields[0].name[..], b"e");
    assert_eq!(&fields[0].value[..], b"f");
    dec.feed_encoder_stream(&first_insert).unwrap();
    enc.feed_decoder_stream(&dec.take_decoder_stream()).unwrap();
    enc.encode(12, [(b"g", b"h")]).unwrap();
    assert_eq!(
        enc.insert_count(),
        2,
        "acknowledgment makes the old entry evictable"
    );
}

#[test]
fn sensitive_fields_survive_forwarding_and_static_or_dynamic_matches() {
    let mut dec = Decoder::new(DecoderConfig::default());
    let fields = dec
        .decode_field_section(0, Bytes::from_static(&[0, 0, 0x31, b'x', 1, b'y']))
        .unwrap()
        .unwrap();
    let mut enc = Encoder::new(EncoderConfig::default());
    let forwarded = enc.encode(0, fields).unwrap();
    let mut cursor = &forwarded[..];
    HeaderPrefix::decode(&mut cursor, 128, 0).unwrap();
    assert_matches!(
        FieldLine::decode(&mut cursor, 4096).unwrap(),
        FieldLine::LiteralWithLiteralName {
            never_index: true,
            ..
        },
    );
    assert_eq!(enc.insert_count(), 0);
    enc.encode(4, [(b"x", b"y")]).unwrap();
    let insert_count = enc.insert_count();
    let wire = enc
        .encode(
            8,
            [
                EncodeField {
                    name: &b"x"[..],
                    value: &b"y"[..],
                    never_index: true,
                    preferences: None,
                },
                EncodeField {
                    name: b":method",
                    value: b"GET",
                    never_index: true,
                    preferences: None,
                },
            ],
        )
        .unwrap();
    let mut cursor = &wire[..];
    HeaderPrefix::decode(&mut cursor, 128, insert_count).unwrap();
    for _ in 0..2 {
        assert_matches!(
            FieldLine::decode(&mut cursor, 4096).unwrap(),
            FieldLine::LiteralWithNameRef {
                never_index: true,
                ..
            } | FieldLine::LiteralWithPostBaseNameRef {
                never_index: true,
                ..
            },
        );
    }
    assert_eq!(enc.insert_count(), insert_count);
}

#[test]
fn tracking_budgets_fall_back_and_recover_after_acknowledgment() {
    let mut enc = Encoder::new(EncoderConfig {
        max_outstanding_sections: 1,
        max_outstanding_references: 1,
        ..EncoderConfig::default()
    });
    let mut dec = Decoder::new(DecoderConfig::default());
    let first = enc.encode(0, [(b"a", b"b"), (b"a", b"b")]).unwrap();
    assert_eq!(enc.tracked_reference_count(), 1);
    dec.feed_encoder_stream(&enc.take_encoder_stream()).unwrap();
    // Acknowledging the insertion alone removes blocking, but must not bypass tracking budgets.
    enc.feed_decoder_stream(&dec.take_decoder_stream()).unwrap();
    for stream in 1..100 {
        let section = enc.encode(stream * 4, [(b"a", b"b")]).unwrap();
        let prefix = HeaderPrefix::decode(&mut &section[..], 128, 1).unwrap();
        assert_eq!(prefix.required_insert_count, 0);
        assert_eq!(enc.tracked_section_count(), 1);
        assert_eq!(enc.tracked_reference_count(), 1);
    }
    dec.decode_field_section(0, first).unwrap().unwrap();
    enc.feed_decoder_stream(&dec.take_decoder_stream()).unwrap();
    assert_eq!(enc.tracked_reference_count(), 0);
    enc.encode(400, [(b"a", b"b")]).unwrap();
    assert_eq!(enc.tracked_section_count(), 1);
}

#[test]
fn output_budget_falls_back_without_partial_instructions() {
    for limit in 0..40 {
        let mut enc = Encoder::new(EncoderConfig {
            max_encoder_stream_bytes: limit,
            huffman: false,
            ..EncoderConfig::default()
        });
        let mut dec = Decoder::new(DecoderConfig::default());
        for stream in 0..10 {
            let value = format!("{stream}");
            let section = enc.encode(stream * 4, [("x", value.as_str())]).unwrap();
            assert!(enc.encoder_stream_len() <= limit);
            dec.feed_encoder_stream(&enc.take_encoder_stream()).unwrap();
            let fields = dec
                .decode_field_section(stream * 4, section)
                .unwrap()
                .unwrap();
            assert_eq!(&fields[0].value[..], value.as_bytes());
            enc.feed_decoder_stream(&dec.take_decoder_stream()).unwrap();
        }
    }
}

#[test]
fn input_rejection_is_transactional_and_exact_limit_works() {
    let mut enc = Encoder::new(EncoderConfig {
        max_field_section_size: 34,
        ..EncoderConfig::default()
    });
    enc.encode(0, [(b"a", b"b"), (b"c", b"d")]).unwrap_err();
    assert_eq!(enc.insert_count(), 0);
    assert_eq!(enc.encoder_stream_len(), 0);
    enc.encode(u64::MAX, [(b"a", b"b")]).unwrap_err();
    assert_eq!(enc.encoder_stream_len(), 0);
    enc.encode(0, [(b"a", b"b")]).unwrap();
    assert_eq!(enc.insert_count(), 1);
}

#[test]
fn blocking_budget_and_same_stream_multiple_sections() {
    let mut enc = Encoder::new(EncoderConfig {
        max_blocked_streams: 1,
        ..EncoderConfig::default()
    });
    enc.encode(0, [(b"a", b"b")]).unwrap();
    enc.encode(0, [(b"c", b"d")]).unwrap();
    assert_eq!(enc.blocking_streams, 1);
    let other = enc.encode(4, [(b"e", b"f")]).unwrap();
    assert_eq!(
        HeaderPrefix::decode(&mut &other[..], 128, 2)
            .unwrap()
            .required_insert_count,
        0
    );
    enc.on_decoder_instruction(DecoderInstruction::SectionAcknowledgment { stream_id: 0 })
        .unwrap();
    assert_eq!(enc.blocking_streams, 1);
    enc.on_decoder_instruction(DecoderInstruction::SectionAcknowledgment { stream_id: 0 })
        .unwrap();
    assert_eq!(enc.blocking_streams, 0);
    assert!(
        enc.on_decoder_instruction(DecoderInstruction::SectionAcknowledgment { stream_id: 0 })
            .is_err()
    );
}

#[test]
fn native_header_sensitivity_is_preserved() {
    let name = rama_http_types::header::AUTHORIZATION;
    let mut value = rama_http_types::HeaderValue::from_static("secret");
    value.set_sensitive(true);
    let mut enc = Encoder::new(EncoderConfig::default());
    let field = EncodeField::from_header(&name, &value);
    assert_matches!(field.name, std::borrow::Cow::Borrowed(_));
    assert_eq!(field.value.as_ptr(), value.as_bytes().as_ptr());
    let bytes = enc.encode(0, [field]).unwrap();
    assert_eq!(enc.insert_count(), 0);
    let mut dec = Decoder::new(DecoderConfig::default());
    let fields = dec.decode_field_section(0, bytes).unwrap().unwrap();
    assert!(fields[0].never_index);
}

#[test]
fn adaptive_huffman_preserves_sensitive_literals_and_plain_mode() {
    // Expansion, equal length, and compression respectively, for both names and values.
    let cases: &[(&[u8], bool)] = &[
        (b"##########", false),
        (b"a", false),
        (b"www.example.com", true),
    ];
    for &(name, name_smaller) in cases {
        for &(value, value_smaller) in cases {
            for allow_huffman in [false, true] {
                let mut enc = Encoder::new(EncoderConfig {
                    huffman: allow_huffman,
                    ..Default::default()
                });
                let section = enc
                    .encode(
                        0,
                        [EncodeField {
                            name,
                            value,
                            never_index: true,
                            preferences: None,
                        }],
                    )
                    .unwrap();
                let mut cursor = &section[..];
                let prefix = HeaderPrefix::decode(&mut cursor, 128, 0).unwrap();
                assert_eq!(prefix.required_insert_count, 0);
                assert_eq!(enc.insert_count(), 0);
                assert_eq!(
                    FieldLine::decode(&mut cursor, 1024).unwrap(),
                    FieldLine::LiteralWithLiteralName {
                        name: Bytes::copy_from_slice(name),
                        value: Bytes::copy_from_slice(value),
                        name_huffman: allow_huffman && name_smaller,
                        value_huffman: allow_huffman && value_smaller,
                        never_index: true,
                    }
                );
                assert!(cursor.is_empty());
                let mut dec = Decoder::new(DecoderConfig::default());
                let fields = dec.decode_field_section(0, section).unwrap().unwrap();
                assert_eq!(&fields[0].name[..], name);
                assert_eq!(&fields[0].value[..], value);
                assert!(fields[0].never_index);
            }
        }
    }
}

#[test]
fn adaptive_insert_budget_matches_exact_wire_and_one_byte_short() {
    use rama_http_types::proto::h3::qpack::EncoderInstruction;
    let cases: &[(&[u8], bool)] = &[
        (b"##########", false),
        (b"a", false),
        (b"www.example.com", true),
    ];
    for &(value, value_huffman) in cases {
        // Exercise literal-name and static-name insertions independently.
        for name in [
            b"##########".as_slice(),
            b"www.example.com",
            b"a",
            b":authority",
        ] {
            let instruction = if name == b":authority" {
                EncoderInstruction::InsertWithNameRef {
                    is_static: true,
                    name_index: 0,
                    value: Bytes::copy_from_slice(value),
                    value_huffman,
                }
            } else {
                EncoderInstruction::InsertWithLiteralName {
                    name: Bytes::copy_from_slice(name),
                    value: Bytes::copy_from_slice(value),
                    name_huffman: name == b"www.example.com",
                    value_huffman,
                }
            };
            let mut expected = BytesMut::new();
            EncoderInstruction::SetDynamicTableCapacity { capacity: 128 }.encode(&mut expected);
            let capacity_len = expected.len();
            instruction.encode(&mut expected);
            for budget in [expected.len() - 1, expected.len()] {
                let mut enc = Encoder::new(EncoderConfig {
                    max_table_capacity: 128,
                    target_capacity: 128,
                    max_encoder_stream_bytes: budget,
                    ..Default::default()
                });
                let section = enc.encode(0, [(name, value)]).unwrap();
                let control = enc.take_encoder_stream();
                let inserted = budget == expected.len();
                assert_eq!(enc.insert_count(), u64::from(inserted));
                assert_eq!(
                    control,
                    if inserted {
                        &expected[..]
                    } else {
                        &expected[..capacity_len]
                    }
                );
                assert!(control.len() <= budget);
                let mut dec = Decoder::new(DecoderConfig {
                    max_table_capacity: 128,
                    ..Default::default()
                });
                for byte in control {
                    dec.feed_encoder_stream(&[byte]).unwrap();
                }
                let fields = dec.decode_field_section(0, section).unwrap().unwrap();
                assert_eq!(&fields[0].name[..], name);
                assert_eq!(&fields[0].value[..], value);
                enc.feed_decoder_stream(&dec.take_decoder_stream()).unwrap();
                assert_eq!(enc.tracked_reference_count(), 0);
            }
        }
    }
}

// Recompute from the actual outstanding sections as an independent oracle for
// the incremental accounting. Required Insert Counts need not be FIFO ordered.
fn assert_blocking_accounting(encoder: &Encoder) {
    let mut index = BTreeMap::new();
    let mut streams = 0;
    for (&stream_id, sections) in &encoder.sections {
        let mut blocking = 0;
        for section in &sections.queue {
            if section.required_insert_count > encoder.known_received_count() {
                blocking += 1;
                *index
                    .entry((section.required_insert_count, stream_id))
                    .or_insert(0) += 1;
            }
        }
        assert_eq!(sections.blocking, blocking);
        streams += u64::from(blocking != 0);
    }
    assert_eq!(encoder.blocking_streams, streams);
    assert_eq!(encoder.blocking_sections, index);
}

#[test]
fn blocking_accounting_handles_shared_nonmonotonic_sections_and_feedback() {
    let mut encoder = Encoder::new(EncoderConfig {
        max_blocked_streams: 64,
        ..EncoderConfig::default()
    });
    let values = ["first", "second", "third", "fourth"];
    for value in values {
        encoder.encode(0, [("x-shared", value)]).unwrap();
    }
    // Later sections can refer to older entries, and multiple sections on one
    // stream may have the same Required Insert Count.
    for stream in 1..32 {
        for value in [values[3], values[0], values[3], values[1]] {
            encoder.encode(stream * 4, [("x-shared", value)]).unwrap();
            assert_blocking_accounting(&encoder);
        }
    }
    for increment in [1, 1] {
        encoder
            .on_decoder_instruction(DecoderInstruction::InsertCountIncrement { increment })
            .unwrap();
        assert_blocking_accounting(&encoder);
    }
    for stream in 0..32 {
        if stream % 2 == 0 {
            encoder
                .on_decoder_instruction(DecoderInstruction::StreamCancellation {
                    stream_id: stream * 4,
                })
                .unwrap();
        } else {
            for _ in 0..4 {
                encoder
                    .on_decoder_instruction(DecoderInstruction::SectionAcknowledgment {
                        stream_id: stream * 4,
                    })
                    .unwrap();
                assert_blocking_accounting(&encoder);
            }
        }
        assert_blocking_accounting(&encoder);
    }
    assert_eq!(encoder.tracked_section_count(), 0);
    assert_eq!(encoder.tracked_reference_count(), 0);
    assert_eq!(encoder.known_received_count(), 4);
    encoder.encode(128, [("x-shared", "fifth")]).unwrap();
    assert_eq!(encoder.blocking_streams, 1);
    assert_blocking_accounting(&encoder);
    encoder
        .on_decoder_instruction(DecoderInstruction::InsertCountIncrement { increment: 1 })
        .unwrap();
    assert_eq!(encoder.blocking_streams, 0);
    assert_blocking_accounting(&encoder);
}

#[test]
fn unknown_cancellation_flood_preserves_outstanding_sections_and_recovers() {
    let mut encoder = Encoder::new(EncoderConfig {
        max_blocked_streams: 1024,
        ..EncoderConfig::default()
    });
    for stream in 1..=1024 {
        encoder.encode(stream * 4, [("x-shared", "value")]).unwrap();
    }
    encoder.feed_decoder_stream(&vec![0x40; kib(64)]).unwrap();
    assert_eq!(encoder.tracked_section_count(), 1024);
    assert_eq!(encoder.tracked_reference_count(), 1024);
    assert_eq!(encoder.known_received_count(), 0);
    assert_blocking_accounting(&encoder);
    for stream in 1..=1024 {
        encoder
            .on_decoder_instruction(DecoderInstruction::StreamCancellation {
                stream_id: stream * 4,
            })
            .unwrap();
    }
    assert_eq!(encoder.tracked_section_count(), 0);
    assert_eq!(encoder.tracked_reference_count(), 0);
    assert_blocking_accounting(&encoder);
    encoder.encode(1025 * 4, [("x-new", "next")]).unwrap();
    assert_eq!(encoder.blocking_streams, 1);
    assert_blocking_accounting(&encoder);
}

#[test]
fn cancellation_before_first_encode_never_leaks_late_sections() {
    for class in 0..4 {
        let mut encoder = Encoder::new(EncoderConfig::default());
        let cancelled = 1100 * 4 + class;
        encoder
            .on_decoder_instruction(DecoderInstruction::StreamCancellation {
                stream_id: cancelled,
            })
            .unwrap();
        encoder
            .on_decoder_instruction(DecoderInstruction::StreamCancellation { stream_id: class })
            .unwrap();
        // More late responses/trailers than the entire outstanding-section
        // budget must not consume any references the peer will never release.
        let mut decoder = Decoder::new(DecoderConfig::default());
        for sequence in 0..=1100 {
            let stream = sequence * 4 + class;
            let section = encoder.encode(stream, [("x-late", "value")]).unwrap();
            assert_eq!(
                decoder
                    .decode_field_section(stream, section)
                    .unwrap()
                    .unwrap()[0]
                    .value,
                "value"
            );
        }
        assert_eq!(encoder.tracked_section_count(), 0);
        assert_eq!(encoder.tracked_reference_count(), 0);
        assert_eq!(encoder.insert_count(), 0);

        let next = cancelled + 4;
        let section = encoder.encode(next, [("x-new", "next")]).unwrap();
        assert_eq!(encoder.tracked_section_count(), 1);
        decoder
            .feed_encoder_stream(&encoder.take_encoder_stream())
            .unwrap();
        assert_eq!(
            decoder
                .decode_field_section(next, section)
                .unwrap()
                .unwrap()[0]
                .value,
            "next"
        );
        encoder
            .feed_decoder_stream(&decoder.take_decoder_stream())
            .unwrap();
        assert_eq!(encoder.tracked_reference_count(), 0);
        assert_blocking_accounting(&encoder);
    }
}

#[test]
fn cancellation_preserves_older_references_and_other_stream_classes() {
    let mut encoder = Encoder::new(EncoderConfig::default());
    encoder.encode(0, [("x-existing", "value")]).unwrap();
    encoder.encode(4, [("x-existing", "value")]).unwrap();
    encoder
        .on_decoder_instruction(DecoderInstruction::StreamCancellation { stream_id: 4 })
        .unwrap();
    for stream in [0, 4] {
        encoder.encode(stream, [("x-existing", "value")]).unwrap();
    }
    // Only the original section remains outstanding; cancellation of stream 4
    // must not release stream 0's references or acknowledge its insertion.
    assert_eq!(encoder.tracked_reference_count(), 1);
    assert_eq!(encoder.known_received_count(), 0);
    encoder.encode(1, [("x-existing", "value")]).unwrap();
    assert_eq!(encoder.tracked_reference_count(), 2);
    encoder
        .on_decoder_instruction(DecoderInstruction::SectionAcknowledgment { stream_id: 0 })
        .unwrap();
    assert_eq!(encoder.tracked_reference_count(), 1);
    encoder
        .on_decoder_instruction(DecoderInstruction::SectionAcknowledgment { stream_id: 1 })
        .unwrap();
    assert_eq!(encoder.tracked_reference_count(), 0);
    assert_blocking_accounting(&encoder);
}

#[test]
fn outgoing_section_size_limit_is_stream_scoped_and_recovers() {
    let mut encoder = Encoder::new(EncoderConfig {
        max_field_section_size: 34,
        ..EncoderConfig::default()
    });
    let error = encoder.encode(0, [("a", "bc")]).unwrap_err();
    assert_eq!(
        error,
        QpackError::EncodeFieldSectionLimit("field section too large")
    );
    assert_eq!(error.scope(), Some(ErrorScope::Stream));
    assert_eq!(error.code(), Some(Code::H3_MESSAGE_ERROR));
    assert_eq!(encoder.insert_count(), 0);
    assert_eq!(encoder.encoder_stream_len(), 0);
    encoder.encode(4, [("a", "b")]).unwrap();
    assert_eq!(encoder.tracked_section_count(), 1);
}

/// Whatever SETTINGS a peer sends, the encoder only produces sections that peer can decode: a
/// table too small for one entry gets no references, and extreme limits change nothing else.
#[test]
fn extreme_peer_settings_still_produce_decodable_sections() {
    const MAX: u64 = (1 << 62) - 1;
    for capacity in [0, 1, 31, 32, 64, 4096, MAX] {
        for blocked in [0, 1, MAX] {
            let mut settings = Settings::new();
            settings
                .set(SettingId::QPACK_MAX_TABLE_CAPACITY, capacity)
                .unwrap();
            settings
                .set(SettingId::QPACK_BLOCKED_STREAMS, blocked)
                .unwrap();
            let mut enc = Encoder::before_peer_settings(EncoderConfig::default());
            enc.apply_peer_settings(&settings).unwrap();
            let mut dec = Decoder::new(DecoderConfig {
                max_table_capacity: capacity,
                max_blocked_streams: blocked,
                ..DecoderConfig::default()
            });
            for stream in 0..16u64 {
                let section = enc
                    .encode(stream * 4, [(b"custom-name", b"custom-value")])
                    .unwrap();
                dec.feed_encoder_stream(&enc.take_encoder_stream()).unwrap();
                let fields = dec
                    .decode_field_section(stream * 4, section)
                    .unwrap()
                    .expect("the encoder stream arrived first");
                assert_eq!(fields.len(), 1);
                assert_eq!(fields[0].name.as_ref(), b"custom-name");
                assert_eq!(fields[0].value.as_ref(), b"custom-value");
            }
            if capacity < 32 {
                assert_eq!(enc.insert_count(), 0, "capacity {capacity}");
            }
        }
    }
}

/// A peer that accepts no field section at all refuses every message without touching the
/// compression state, so the connection stays usable.
#[test]
fn a_zero_field_section_limit_refuses_each_message() {
    let mut settings = Settings::new();
    settings
        .set(SettingId::QPACK_MAX_TABLE_CAPACITY, 4096)
        .unwrap();
    settings.set(SettingId::MAX_FIELD_SECTION_SIZE, 0).unwrap();
    let mut enc = Encoder::before_peer_settings(EncoderConfig::default());
    enc.apply_peer_settings(&settings).unwrap();
    for stream in 0..4u64 {
        assert_matches!(
            enc.encode(stream * 4, [(b"custom-name", b"custom-value")]),
            Err(QpackError::EncodeFieldSectionLimit(_)),
        );
        assert_eq!(enc.insert_count(), 0);
        assert_eq!(enc.encoder_stream_len(), 0);
        assert_eq!(enc.tracked_section_count(), 0);
    }
}

#[test]
fn deferred_first_section_preserves_later_dynamic_compression_and_input_atomicity() {
    for settings_later in [false, true] {
        let mut config = EncoderConfig {
            max_field_section_size: 64,
            ..EncoderConfig::default()
        };
        config.apply_preferences(EncoderPreferences {
            defer_dynamic_first_section: Some(true),
            ..EncoderPreferences::default()
        });
        let mut encoder = if settings_later {
            Encoder::before_peer_settings(config)
        } else {
            Encoder::new(config)
        };
        // Rejected input must not consume the initial static/literal choice.
        encoder
            .encode(0, [(b"field".as_slice(), &[b'x'; 128][..])])
            .unwrap_err();
        let fields = [(b"custom".as_slice(), b"same-value".as_slice())];
        let first = encoder.encode(0, fields).unwrap();
        assert_eq!(
            first[0], 0,
            "first section has no required dynamic insert count"
        );
        assert_eq!(encoder.insert_count(), 0);
        assert!(encoder.take_encoder_stream().is_empty());
        let mut decoder = Decoder::new(DecoderConfig::default());
        let first_fields = decoder.decode_field_section(0, first).unwrap().unwrap();

        if settings_later {
            let mut peer = Settings::new();
            peer.insert(Setting::new(SettingId::QPACK_MAX_TABLE_CAPACITY, 4096))
                .unwrap();
            peer.insert(Setting::new(SettingId::QPACK_BLOCKED_STREAMS, 16))
                .unwrap();
            encoder.apply_peer_settings(&peer).unwrap();
        }
        let second = encoder.encode(4, fields).unwrap();
        assert_ne!(second[0], 0, "later sections can use dynamic references");
        assert_eq!(encoder.insert_count(), 1);
        let instructions = encoder.take_encoder_stream();
        assert!(!instructions.is_empty());
        decoder.feed_encoder_stream(&instructions).unwrap();
        let second_fields = decoder.decode_field_section(4, second).unwrap().unwrap();
        assert_eq!(first_fields, second_fields);
    }
}

#[test]
fn section_base_preferences_rebase_real_references_without_changing_table_policy() {
    let fields = [
        (b"custom".as_slice(), b"one".as_slice()),
        (b"custom", b"two"),
    ];
    for base in [
        FieldSectionBase::BeforeSection,
        FieldSectionBase::RequiredInsertCount,
    ] {
        let mut config = EncoderConfig::default();
        config.apply_preferences(EncoderPreferences {
            field_section_base: Some(base),
            ..EncoderPreferences::default()
        });
        let mut encoder = Encoder::new(config);
        let mut decoder = Decoder::new(DecoderConfig::default());
        let section = encoder.encode(0, fields).unwrap();
        let instructions = encoder.take_encoder_stream();
        let mut cursor = &section[..];
        let prefix = HeaderPrefix::decode(&mut cursor, 128, 2).unwrap();
        assert_eq!(prefix.required_insert_count, 2);
        for _ in 0..2 {
            let field = FieldLine::decode(&mut cursor, 4096).unwrap();
            match base {
                FieldSectionBase::BeforeSection => {
                    assert_matches!(field, FieldLine::IndexedPostBase { .. })
                }
                FieldSectionBase::RequiredInsertCount | FieldSectionBase::FromFieldPreferences => {
                    assert_matches!(
                        field,
                        FieldLine::Indexed {
                            is_static: false,
                            ..
                        }
                    )
                }
            }
        }
        assert!(cursor.is_empty());
        decoder.feed_encoder_stream(&instructions).unwrap();
        let decoded = decoder.decode_field_section(0, section).unwrap().unwrap();
        assert_eq!(decoded.len(), fields.len());
        for (actual, (name, value)) in decoded.iter().zip(fields) {
            assert_eq!(actual.name.as_ref(), name);
            assert_eq!(actual.value.as_ref(), value);
        }
        encoder
            .feed_decoder_stream(&decoder.take_decoder_stream())
            .unwrap();
        let subsequent = encoder.encode(4, fields).unwrap();
        assert_eq!(
            encoder.insert_count(),
            2,
            "rebasing never reinserts existing values"
        );
        decoder
            .decode_field_section(4, subsequent)
            .unwrap()
            .unwrap();
        assert!(encoder.take_encoder_stream().is_empty());
    }
}

#[test]
fn field_preferences_preserve_literal_choices_and_regenerate_dynamic_name_indexes() {
    let mut encoder = Encoder::new(EncoderConfig::default());
    let mut decoder = Decoder::new(DecoderConfig::default());
    let seed = encoder.encode(0, [("custom", "cached")]).unwrap();
    decoder
        .feed_encoder_stream(&encoder.take_encoder_stream())
        .unwrap();
    decoder.decode_field_section(0, seed).unwrap().unwrap();
    encoder
        .feed_decoder_stream(&decoder.take_decoder_stream())
        .unwrap();

    let source = [
        FieldLine::LiteralWithLiteralName {
            name: Bytes::from_static(b"custom"),
            value: Bytes::from_static(b"old"),
            name_huffman: false,
            value_huffman: false,
            never_index: true,
        },
        FieldLine::LiteralWithNameRef {
            is_static: false,
            name_index: 27,
            value: Bytes::from_static(b"old"),
            value_huffman: false,
            never_index: false,
        },
        FieldLine::LiteralWithNameRef {
            is_static: true,
            name_index: 95,
            value: Bytes::from_static(b"old"),
            value_huffman: false,
            never_index: false,
        },
    ];
    let mut preferences = source
        .iter()
        .map(|line| {
            FieldPreferences::from_observed(&ObservedFieldRepresentation::from(line)).unwrap()
        })
        .collect::<Vec<_>>();
    preferences.push(FieldPreferences::default());
    let fields = [
        ("custom", "cached"),
        ("custom", "fresh"),
        ("user-agent", "new agent"),
        ("custom", "cached"),
    ];
    let section = encoder
        .encode_with_base(
            4,
            fields.iter().zip(&preferences).enumerate().map(
                |(index, ((name, value), preferences))| EncodeField {
                    name: name.as_bytes(),
                    value: value.as_bytes(),
                    never_index: index == 3,
                    preferences: Some(preferences),
                },
            ),
            FieldSectionBase::FromFieldPreferences,
        )
        .unwrap();
    assert_eq!(
        encoder.insert_count(),
        1,
        "literal preferences must not insert"
    );
    assert!(encoder.take_encoder_stream().is_empty());
    let mut cursor = &section[..];
    HeaderPrefix::decode(&mut cursor, 128, 1).unwrap();
    assert_matches!(
        FieldLine::decode(&mut cursor, 4096).unwrap(),
        FieldLine::LiteralWithLiteralName {
            name_huffman: false,
            value_huffman: false,
            never_index: true,
            ..
        }
    );
    assert_matches!(
        FieldLine::decode(&mut cursor, 4096).unwrap(),
        FieldLine::LiteralWithNameRef {
            is_static: false,
            name_index: 0,
            value_huffman: false,
            never_index: false,
            ..
        }
    );
    assert_matches!(
        FieldLine::decode(&mut cursor, 4096).unwrap(),
        FieldLine::LiteralWithNameRef {
            is_static: true,
            name_index: 95,
            value_huffman: false,
            ..
        }
    );
    assert_matches!(
        FieldLine::decode(&mut cursor, 4096).unwrap(),
        FieldLine::LiteralWithLiteralName {
            never_index: true,
            ..
        }
    );
    assert!(cursor.is_empty());
    let decoded = decoder.decode_field_section(4, section).unwrap().unwrap();
    for ((name, value), actual) in fields.iter().zip(&decoded) {
        assert_eq!(actual.name.as_ref(), name.as_bytes());
        assert_eq!(actual.value.as_ref(), value.as_bytes());
    }
    assert!(decoded[0].never_index);
    assert!(
        decoded[3].never_index,
        "preferences cannot weaken caller sensitivity"
    );
}

#[test]
fn invalid_static_name_preference_falls_back_to_native_encoding() {
    let mut decoder = Decoder::new(DecoderConfig::default());
    for (stream, index) in [(0, 0), (4, 99), (8, u64::MAX)] {
        let mut encoder = Encoder::new(EncoderConfig {
            defer_dynamic_first_section: true,
            ..EncoderConfig::default()
        });
        let preferences = FieldPreferences {
            representation: Representation::LiteralStaticName(index),
            ..FieldPreferences::default()
        };
        let section = encoder
            .encode(
                stream,
                [EncodeField {
                    name: "custom",
                    value: "value",
                    never_index: false,
                    preferences: Some(&preferences),
                }],
            )
            .unwrap();
        assert_eq!(
            section,
            Encoder::new(EncoderConfig {
                defer_dynamic_first_section: true,
                ..EncoderConfig::default()
            })
            .encode(stream, [("custom", "value")])
            .unwrap()
        );
        assert_eq!(encoder.insert_count(), 0);
        assert!(encoder.take_encoder_stream().is_empty());
        let decoded = decoder
            .decode_field_section(stream, section)
            .unwrap()
            .unwrap();
        assert_eq!(decoded[0].value.as_ref(), b"value");
    }
}

#[test]
fn field_preferences_force_huffman_for_ties_and_expansions() {
    let preferences = FieldPreferences {
        representation: Representation::LiteralName,
        name_huffman: Some(true),
        value_huffman: Some(true),
        ..FieldPreferences::default()
    };
    let mut encoder = Encoder::new(EncoderConfig {
        max_table_capacity: 0,
        ..EncoderConfig::default()
    });
    let values: [&[u8]; 2] = [b"a", &[0x80]];
    let section = encoder
        .encode(
            0,
            values.into_iter().map(|value| EncodeField {
                name: b"a".as_slice(),
                value,
                never_index: false,
                preferences: Some(&preferences),
            }),
        )
        .unwrap();
    assert!(encoder.take_encoder_stream().is_empty());

    let mut cursor = &section[..];
    HeaderPrefix::decode(&mut cursor, 128, 0).unwrap();
    for value in values {
        match FieldLine::decode(&mut cursor, 4096).unwrap() {
            FieldLine::LiteralWithLiteralName {
                name,
                value: decoded,
                name_huffman,
                value_huffman,
                ..
            } => {
                assert_eq!(name.as_ref(), b"a");
                assert_eq!(decoded.as_ref(), value);
                assert!(name_huffman && value_huffman);
            }
            other => panic!("expected literal fields, got {other:?}"),
        }
    }
    assert!(cursor.is_empty());
    let mut decoder = Decoder::new(DecoderConfig::default());
    let decoded = decoder.decode_field_section(0, section).unwrap().unwrap();
    for (field, value) in decoded.iter().zip(values) {
        assert_eq!(field.name.as_ref(), b"a");
        assert_eq!(field.value.as_ref(), value);
    }
}

#[test]
fn dynamic_name_preference_builds_a_fresh_name_without_inserting_its_value() {
    let preferences = FieldPreferences {
        representation: Representation::LiteralDynamicName,
        value_huffman: Some(false),
        ..FieldPreferences::default()
    };
    let mut encoder = Encoder::new(EncoderConfig {
        field_section_base: FieldSectionBase::RequiredInsertCount,
        ..EncoderConfig::default()
    });
    let mut decoder = Decoder::new(DecoderConfig::default());
    for (stream, value) in [(0, "current-value"), (4, "different-current-value")] {
        let section = encoder
            .encode(
                stream,
                [EncodeField {
                    name: "downlink",
                    value,
                    never_index: false,
                    preferences: Some(&preferences),
                }],
            )
            .unwrap();
        let instructions = encoder.take_encoder_stream();
        let mut cursor = instructions.as_ref();
        while !cursor.is_empty() {
            match EncoderInstruction::decode(&mut cursor, 4096).unwrap() {
                EncoderInstruction::SetDynamicTableCapacity { .. } => (),
                EncoderInstruction::InsertWithLiteralName { name, value, .. } => {
                    assert_eq!(name.as_ref(), b"downlink");
                    assert!(
                        value.is_empty(),
                        "only the name is shared with the peer table"
                    );
                }
                other => panic!("unexpected instruction: {other:?}"),
            }
        }
        assert_eq!(
            encoder.insert_count(),
            1,
            "reuse the same name for different values"
        );
        decoder.feed_encoder_stream(&instructions).unwrap();
        let mut cursor = section.as_ref();
        HeaderPrefix::decode(&mut cursor, 128, 1).unwrap();
        assert_matches!(
            FieldLine::decode(&mut cursor, 4096).unwrap(),
            FieldLine::LiteralWithNameRef {
                is_static: false,
                name_index: 0,
                value_huffman: false,
                ..
            }
        );
        let fields = decoder
            .decode_field_section(stream, section)
            .unwrap()
            .unwrap();
        assert_eq!(fields[0].name.as_ref(), b"downlink");
        assert_eq!(fields[0].value.as_ref(), value.as_bytes());
        encoder
            .feed_decoder_stream(&decoder.take_decoder_stream())
            .unwrap();
    }
}

#[test]
fn dynamic_name_preference_retains_sensitivity_deferral_and_resource_limits() {
    let preferences = FieldPreferences {
        representation: Representation::LiteralDynamicName,
        ..FieldPreferences::default()
    };
    for case in 0..8 {
        let mut config = EncoderConfig::default();
        match case {
            0 => config.max_blocked_streams = 0,
            1 => config.target_capacity = 0,
            2 => config.max_outstanding_sections = 0,
            3 => config.max_outstanding_references = 0,
            4 => config.max_encoder_stream_bytes = 0,
            5 => config.defer_dynamic_first_section = true,
            6 => (), // Caller sensitivity must survive an explicit dynamic-name preference.
            7 => config.target_capacity = 1,
            _ => unreachable!(),
        }
        let mut encoder = Encoder::new(config);
        let section = encoder
            .encode(
                0,
                [EncodeField {
                    name: "downlink",
                    value: "current-only",
                    never_index: case == 6,
                    preferences: Some(&preferences),
                }],
            )
            .unwrap();
        assert_eq!(encoder.insert_count(), 0, "case {case}");
        let mut decoder = Decoder::new(DecoderConfig::default());
        decoder
            .feed_encoder_stream(&encoder.take_encoder_stream())
            .unwrap();
        let mut cursor = section.as_ref();
        HeaderPrefix::decode(&mut cursor, 128, 0).unwrap();
        assert_matches!(
            FieldLine::decode(&mut cursor, 4096).unwrap(),
            FieldLine::LiteralWithLiteralName { .. }
        );
        let fields = decoder.decode_field_section(0, section).unwrap().unwrap();
        assert_eq!(fields[0].value.as_ref(), b"current-only");
        assert_eq!(fields[0].never_index, case == 6);
    }
}

mod insertion;

mod boundary;

#[test]
fn capacity_only_startup_with_literal_preferences_emits_no_insertions() {
    let mut encoder = Encoder::new(EncoderConfig {
        target_capacity: 4096,
        max_table_capacity: 4096,
        defer_dynamic_first_section: false,
        ..EncoderConfig::default()
    });
    let preferences = FieldPreferences {
        representation: Representation::LiteralName,
        ..FieldPreferences::default()
    };
    let fields = [("user-agent", "Safari"), ("x-custom", "current-value")];
    let section = encoder
        .encode(
            0,
            fields.map(|(name, value)| EncodeField {
                name,
                value,
                never_index: false,
                preferences: Some(&preferences),
            }),
        )
        .unwrap();
    let instructions = encoder.take_encoder_stream();
    let mut cursor = instructions.as_ref();
    assert_eq!(
        EncoderInstruction::decode(&mut cursor, 4096).unwrap(),
        EncoderInstruction::SetDynamicTableCapacity { capacity: 4096 }
    );
    assert!(cursor.is_empty());
    assert_eq!(encoder.insert_count(), 0);
    let mut decoder = Decoder::new(DecoderConfig::default());
    decoder.feed_encoder_stream(&instructions).unwrap();
    let decoded = decoder.decode_field_section(0, section).unwrap().unwrap();
    for ((name, value), actual) in fields.iter().zip(&decoded) {
        assert_eq!(actual.name.as_ref(), name.as_bytes());
        assert_eq!(actual.value.as_ref(), value.as_bytes());
    }
}
