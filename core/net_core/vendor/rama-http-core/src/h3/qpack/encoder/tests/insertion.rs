//! Encoder-stream insertion and field-line representation are independent choices.

use super::*;
use crate::h3::qpack::encoder::InitialSection;
use rama_http_types::proto::h3::qpack::{
    encoding::{InsertionNameEncoding, InsertionPreferences, InsertionScope},
    static_table,
};

fn insertion_preferences() -> FieldPreferences {
    FieldPreferences {
        representation: Representation::LiteralName,
        insertion: Some(InsertionPreferences {
            name_encoding: InsertionNameEncoding::Literal,
            name_huffman: Some(true),
            value_huffman: Some(true),
            ..InsertionPreferences::default()
        }),
        name_huffman: Some(false),
        value_huffman: Some(false),
        ..FieldPreferences::default()
    }
}

fn field<'a>(
    name: &'a str,
    value: &'a str,
    preferences: &'a FieldPreferences,
) -> EncodeField<'a, &'a str, &'a str> {
    EncodeField {
        name,
        value,
        never_index: false,
        preferences: Some(preferences),
    }
}

fn deferred() -> EncoderConfig {
    EncoderConfig {
        defer_dynamic_first_section: true,
        max_blocked_streams: 0,
        ..EncoderConfig::default()
    }
}

#[test]
fn automatic_reinsertion_emits_duplicate_against_the_live_table() {
    let mut encoder = Encoder::new(EncoderConfig::default());
    let mut decoder = Decoder::new(DecoderConfig::default());
    let preferences = FieldPreferences {
        representation: Representation::LiteralName,
        insertion: Some(InsertionPreferences::default()),
        ..FieldPreferences::default()
    };
    let first = encoder
        .encode(0, [field("x-repeat", "value", &preferences)])
        .unwrap();
    decoder
        .feed_encoder_stream(&encoder.take_encoder_stream())
        .unwrap();
    decoder.decode_field_section(0, first).unwrap().unwrap();
    encoder
        .feed_decoder_stream(&decoder.take_decoder_stream())
        .unwrap();

    // The intervening field moves the source's relative index from zero to one.
    // The next duplicate must resolve after the previous duplicate was inserted.
    let section = encoder
        .encode(
            4,
            [
                field("x-other", "other", &preferences),
                field("x-repeat", "value", &preferences),
                field("x-repeat", "value", &preferences),
            ],
        )
        .unwrap();
    let instructions = encoder.take_encoder_stream();
    let mut cursor = instructions.as_ref();
    assert_matches!(
        EncoderInstruction::decode(&mut cursor, 4096).unwrap(),
        EncoderInstruction::InsertWithLiteralName { .. }
    );
    assert_matches!(
        EncoderInstruction::decode(&mut cursor, 4096).unwrap(),
        EncoderInstruction::Duplicate { index: 1 }
    );
    assert_matches!(
        EncoderInstruction::decode(&mut cursor, 4096).unwrap(),
        EncoderInstruction::Duplicate { index: 0 }
    );
    assert!(cursor.is_empty());
    decoder.feed_encoder_stream(&instructions).unwrap();
    let fields = decoder.decode_field_section(4, section).unwrap().unwrap();
    assert_eq!(fields.len(), 3);
    assert_eq!(fields[1].value.as_ref(), b"value");
    assert_eq!(fields[2].value.as_ref(), b"value");
    // A subsequent indexed section proves both tables assigned the same indexes.
    encoder
        .feed_decoder_stream(&decoder.take_decoder_stream())
        .unwrap();
    let indexed = encoder.encode(8, [("x-repeat", "value")]).unwrap();
    decoder
        .feed_encoder_stream(&encoder.take_encoder_stream())
        .unwrap();
    assert_eq!(
        decoder.decode_field_section(8, indexed).unwrap().unwrap()[0]
            .value
            .as_ref(),
        b"value"
    );
}

#[test]
fn duplicate_can_replace_its_acknowledged_source_at_capacity() {
    let mut encoder = Encoder::new(EncoderConfig {
        target_capacity: 45, // Exactly one x-repeat: value entry.
        ..EncoderConfig::default()
    });
    let mut decoder = Decoder::new(DecoderConfig::default());
    let preferences = FieldPreferences {
        representation: Representation::LiteralName,
        insertion: Some(InsertionPreferences::default()),
        ..FieldPreferences::default()
    };
    let first = encoder
        .encode(0, [field("x-repeat", "value", &preferences)])
        .unwrap();
    decoder
        .feed_encoder_stream(&encoder.take_encoder_stream())
        .unwrap();
    decoder.decode_field_section(0, first).unwrap().unwrap();
    encoder
        .feed_decoder_stream(&decoder.take_decoder_stream())
        .unwrap();

    let section = encoder
        .encode(4, [field("x-repeat", "value", &preferences)])
        .unwrap();
    let instructions = encoder.take_encoder_stream();
    let mut cursor = instructions.as_ref();
    assert_matches!(
        EncoderInstruction::decode(&mut cursor, 4096).unwrap(),
        EncoderInstruction::Duplicate { index: 0 }
    );
    assert!(cursor.is_empty());
    decoder.feed_encoder_stream(&instructions).unwrap();
    assert_eq!(encoder.insert_count(), 2);
    assert_eq!(
        decoder.decode_field_section(4, section).unwrap().unwrap()[0]
            .value
            .as_ref(),
        b"value"
    );
}

#[test]
fn explicit_insertion_wire_choices_do_not_become_duplicates() {
    for insertion in [
        InsertionPreferences {
            name_encoding: InsertionNameEncoding::Literal,
            ..Default::default()
        },
        InsertionPreferences {
            name_huffman: Some(false),
            ..Default::default()
        },
        InsertionPreferences {
            value_huffman: Some(true),
            ..Default::default()
        },
    ] {
        let mut encoder = Encoder::new(EncoderConfig::default());
        let preferences = FieldPreferences {
            representation: Representation::LiteralName,
            insertion: Some(insertion),
            ..Default::default()
        };
        encoder
            .encode(0, [field("x-repeat", "value", &preferences)])
            .unwrap();
        encoder.take_encoder_stream();
        encoder
            .encode(4, [field("x-repeat", "value", &preferences)])
            .unwrap();
        let instructions = encoder.take_encoder_stream();
        assert_matches!(
            EncoderInstruction::decode(&mut instructions.as_ref(), 4096).unwrap(),
            EncoderInstruction::InsertWithLiteralName { .. }
        );
    }
}

#[test]
fn explicit_insertions_use_current_values_while_the_first_field_section_stays_literal() {
    for (representation, blocked) in [
        (Representation::LiteralName, 0),
        (Representation::Automatic, 0),
        (Representation::Automatic, 4),
    ] {
        for value in ["first-current-value", "second-current-value"] {
            let mut config = deferred();
            config.max_blocked_streams = blocked;
            let mut encoder = Encoder::new(config);
            let mut preferences = insertion_preferences();
            preferences.representation = representation;
            let section = encoder
                .encode(0, [field("x-current", value, &preferences)])
                .unwrap();
            let instructions = encoder.take_encoder_stream();
            let mut decoder = Decoder::new(DecoderConfig::default());
            // Literal HEADERS decode before the independently ordered encoder stream.
            let decoded = decoder
                .decode_field_section(0, section.clone())
                .unwrap()
                .unwrap();
            assert_eq!(decoded[0].value.as_ref(), value.as_bytes());
            assert_eq!(encoder.insert_count(), 1);
            let mut cursor = instructions.as_ref();
            assert_matches!(
                EncoderInstruction::decode(&mut cursor, 4096).unwrap(),
                EncoderInstruction::SetDynamicTableCapacity { .. }
            );
            match EncoderInstruction::decode(&mut cursor, 4096).unwrap() {
                EncoderInstruction::InsertWithLiteralName {
                    name,
                    value: inserted,
                    name_huffman,
                    value_huffman,
                } => {
                    assert_eq!(name.as_ref(), b"x-current");
                    assert_eq!(inserted.as_ref(), value.as_bytes());
                    assert!(name_huffman && value_huffman);
                }
                other => panic!("expected current-field insertion, got {other:?}"),
            }
            assert!(cursor.is_empty());
            let mut cursor = section.as_ref();
            assert_eq!(
                HeaderPrefix::decode(&mut cursor, 128, 0)
                    .unwrap()
                    .required_insert_count,
                0
            );
            assert_matches!(
                FieldLine::decode(&mut cursor, 4096).unwrap(),
                FieldLine::LiteralWithLiteralName {
                    name_huffman: false,
                    value_huffman: false,
                    ..
                }
            );
            decoder.feed_encoder_stream(&instructions).unwrap();
            encoder
                .feed_decoder_stream(&decoder.take_decoder_stream())
                .unwrap();
            // Normal later compression can reference the acknowledged fresh entry.
            let later = encoder.encode(4, [("x-current", value)]).unwrap();
            assert!(
                HeaderPrefix::decode(&mut later.as_ref(), 128, 1)
                    .unwrap()
                    .required_insert_count
                    > 0
            );
            let decoded = decoder.decode_field_section(4, later).unwrap().unwrap();
            assert_eq!(decoded[0].value.as_ref(), value.as_bytes());
        }
    }
}

#[test]
fn explicit_static_name_encoding_is_independent_and_invalid_names_fall_back() {
    let mut encoder = Encoder::new(deferred());
    let mut decoder = Decoder::new(DecoderConfig::default());
    let mut preferences = insertion_preferences();
    preferences.insertion.as_mut().unwrap().name_encoding = InsertionNameEncoding::StaticName(17);
    // The second field's static name names another field: it is inserted natively.
    let ordinary = insertion_preferences();
    let section = encoder
        .encode(
            0,
            [
                field("x-first", "one", &ordinary),
                field("x-wrong", "two", &preferences),
            ],
        )
        .unwrap();
    assert_eq!(encoder.insert_count(), 2);
    let instructions = encoder.take_encoder_stream();
    let mut cursor = instructions.as_ref();
    EncoderInstruction::decode(&mut cursor, 4096).unwrap();
    for expected in ["x-first", "x-wrong"] {
        match EncoderInstruction::decode(&mut cursor, 4096).unwrap() {
            EncoderInstruction::InsertWithLiteralName { name, .. } => {
                assert_eq!(name.as_ref(), expected.as_bytes());
            }
            other => panic!("expected literal-name insertion, got {other:?}"),
        }
    }
    decoder.feed_encoder_stream(&instructions).unwrap();
    let decoded = decoder.decode_field_section(0, section).unwrap().unwrap();
    assert_eq!(decoded[1].value.as_ref(), b"two");

    let section = encoder
        .encode(4, [field(":method", "POST", &preferences)])
        .unwrap();
    let instructions = encoder.take_encoder_stream();
    let mut cursor = instructions.as_ref();
    assert_matches!(
        EncoderInstruction::decode(&mut cursor, 4096).unwrap(),
        EncoderInstruction::InsertWithNameRef {
            is_static: true,
            name_index: 17,
            ..
        }
    );
    decoder.feed_encoder_stream(&instructions).unwrap();
    assert_eq!(
        decoder.decode_field_section(4, section).unwrap().unwrap()[0]
            .value
            .as_ref(),
        b"POST"
    );
}

#[test]
fn explicit_insertions_cannot_override_caller_or_preference_sensitivity() {
    for caller in [false, true] {
        let mut encoder = Encoder::new(deferred());
        let mut preferences = insertion_preferences();
        preferences.never_index = !caller;
        let mut sensitive = field("authorization", "current secret", &preferences);
        sensitive.never_index = caller;
        let section = encoder.encode(0, [sensitive]).unwrap();
        assert_eq!(encoder.insert_count(), 0);
        assert!(encoder.take_encoder_stream().is_empty());
        assert_eq!(encoder.tracked_section_count(), 0);
        let decoded = Decoder::new(DecoderConfig::default())
            .decode_field_section(0, section)
            .unwrap()
            .unwrap();
        assert_eq!(decoded[0].value.as_ref(), b"current secret");
        assert!(decoded[0].never_index);
    }
}

#[test]
fn explicit_batch_capacity_and_output_credit_shortfalls_encode_natively() {
    let preferences = insertion_preferences();
    let mut reference = Encoder::new(deferred());
    reference
        .encode(
            0,
            [
                field("x-a", "one", &preferences),
                field("x-b", "two", &preferences),
            ],
        )
        .unwrap();
    let exact_wire = reference.take_encoder_stream().len();
    for case in 0..4 {
        let mut config = deferred();
        match case {
            0 => {
                config.max_table_capacity = 0;
                config.target_capacity = 0;
            }
            1 => {
                config.target_capacity = 40;
            }
            2 => {
                config.max_encoder_stream_bytes = exact_wire - 1;
            }
            3 => (),
            _ => unreachable!(),
        }
        let mut encoder = Encoder::new(config);
        let input = [
            field("x-a", "one", &preferences),
            field("x-b", "two", &preferences),
        ];
        let result = if case == 3 {
            encoder.encode_with_credit(0, input, exact_wire - 1, None)
        } else {
            encoder.encode(0, input)
        };
        let section = result.unwrap();
        assert_eq!(encoder.insert_count(), 0, "case {case}");
        assert!(encoder.take_encoder_stream().is_empty(), "case {case}");
        let decoded = Decoder::new(DecoderConfig::default())
            .decode_field_section(0, section)
            .unwrap()
            .unwrap();
        assert_eq!(decoded[0].value.as_ref(), b"one");
        assert_eq!(decoded[1].value.as_ref(), b"two");
    }
    let mut encoder = Encoder::new(deferred());
    encoder
        .encode_with_credit(
            0,
            [
                field("x-a", "one", &preferences),
                field("x-b", "two", &preferences),
            ],
            exact_wire,
            None,
        )
        .unwrap();
    assert_eq!(encoder.insert_count(), 2);
}

#[test]
fn explicit_batch_respects_outstanding_references_before_any_insertion() {
    let mut encoder = Encoder::new(EncoderConfig {
        target_capacity: 80,
        ..EncoderConfig::default()
    });
    let first = encoder.encode(0, [("x", "old")]).unwrap();
    let first_instructions = encoder.take_encoder_stream();
    let preferences = insertion_preferences();
    // Inserting would evict the unacknowledged entry: the fields go out without it.
    let literal = encoder
        .encode(
            4,
            [
                field("a", "one", &preferences),
                field("b", "two", &preferences),
            ],
        )
        .unwrap();
    assert_eq!(encoder.insert_count(), 1);
    assert!(encoder.take_encoder_stream().is_empty());
    let mut decoder = Decoder::new(DecoderConfig::default());
    decoder.feed_encoder_stream(&first_instructions).unwrap();
    decoder.decode_field_section(0, first).unwrap().unwrap();
    let fields = decoder.decode_field_section(4, literal).unwrap().unwrap();
    assert_eq!(fields[0].value.as_ref(), b"one");
    encoder
        .feed_decoder_stream(&decoder.take_decoder_stream())
        .unwrap();
    let next = encoder
        .encode(
            8,
            [
                field("a", "one", &preferences),
                field("b", "two", &preferences),
            ],
        )
        .unwrap();
    decoder
        .feed_encoder_stream(&encoder.take_encoder_stream())
        .unwrap();
    let fields = decoder.decode_field_section(8, next).unwrap().unwrap();
    assert_eq!(fields[0].name.as_ref(), b"a");
    assert_eq!(fields[1].value.as_ref(), b"two");
    assert_eq!(encoder.insert_count(), 3);
}

#[test]
fn automatic_insertion_name_encoding_uses_the_protocol_static_table() {
    let mut encoder = Encoder::new(deferred());
    let mut preferences = insertion_preferences();
    preferences.insertion = Some(InsertionPreferences::default());
    let section = encoder
        .encode(0, [field(":method", "POST", &preferences)])
        .unwrap();
    let instructions = encoder.take_encoder_stream();
    let mut cursor = instructions.as_ref();
    EncoderInstruction::decode(&mut cursor, 4096).unwrap();
    let index = match EncoderInstruction::decode(&mut cursor, 4096).unwrap() {
        EncoderInstruction::InsertWithNameRef {
            is_static: true,
            name_index,
            ..
        } => name_index,
        other => panic!("expected static insertion name, got {other:?}"),
    };
    assert_eq!(static_table::get(index as usize).unwrap().0, b":method");
    let mut decoder = Decoder::new(DecoderConfig::default());
    decoder.feed_encoder_stream(&instructions).unwrap();
    assert_eq!(
        decoder.decode_field_section(0, section).unwrap().unwrap()[0]
            .value
            .as_ref(),
        b"POST"
    );
}

#[test]
fn initial_insertions_run_once_and_keep_later_current_values() {
    for defer in [false, true] {
        let mut config = deferred();
        config.defer_dynamic_first_section = defer;
        let mut encoder = Encoder::new(config);
        let mut preferences = insertion_preferences();
        preferences.insertion.as_mut().unwrap().scope = InsertionScope::InitialSection;
        let mut decoder = Decoder::new(DecoderConfig::default());
        let first = encoder
            .encode(0, [field("x-initial", "first-current", &preferences)])
            .unwrap();
        decoder
            .feed_encoder_stream(&encoder.take_encoder_stream())
            .unwrap();
        assert_eq!(
            decoder.decode_field_section(0, first).unwrap().unwrap()[0]
                .value
                .as_ref(),
            b"first-current"
        );
        assert_eq!(encoder.insert_count(), 1);
        assert_eq!(encoder.tracked_section_count(), 0);
        for (stream, value) in [(0, "trailer-current"), (4, "next-current")] {
            let section = encoder
                .encode(stream, [field("x-initial", value, &preferences)])
                .unwrap();
            assert_eq!(
                decoder
                    .decode_field_section(stream, section)
                    .unwrap()
                    .unwrap()[0]
                    .value
                    .as_ref(),
                value.as_bytes()
            );
            assert_eq!(encoder.insert_count(), 1);
            assert!(encoder.take_encoder_stream().is_empty());
        }
        let every = insertion_preferences();
        encoder
            .encode(8, [field("x-initial", "every-current", &every)])
            .unwrap();
        assert_eq!(encoder.insert_count(), 2);
        assert!(!encoder.take_encoder_stream().is_empty());
    }
}

#[test]
fn initial_insertion_without_output_credit_sends_the_section_natively_once() {
    let mut encoder = Encoder::new(deferred());
    let mut preferences = insertion_preferences();
    preferences.insertion.as_mut().unwrap().scope = InsertionScope::InitialSection;
    let section = encoder
        .encode_with_credit(0, [field("x-initial", "current", &preferences)], 0, None)
        .unwrap();
    assert_eq!(encoder.insert_count(), 0);
    assert!(encoder.take_encoder_stream().is_empty());
    assert_eq!(encoder.initial_section, InitialSection::Complete);
    let mut decoder = Decoder::new(DecoderConfig::default());
    let decoded = decoder.decode_field_section(0, section).unwrap().unwrap();
    assert_eq!(decoded[0].value.as_ref(), b"current");
    // The initial section went out, so its one-time insertion no longer applies.
    encoder
        .encode(4, [field("x-initial", "later-current", &preferences)])
        .unwrap();
    assert_eq!(encoder.insert_count(), 0);
}

#[test]
fn dynamic_field_preference_beats_an_exact_static_match_using_current_values() {
    for value in ["/", "/fresh-current-path"] {
        for representation in [Representation::Automatic, Representation::DynamicIndex] {
            let mut encoder = Encoder::new(EncoderConfig {
                field_section_base: FieldSectionBase::RequiredInsertCount,
                ..EncoderConfig::default()
            });
            let mut preferences = insertion_preferences();
            preferences.representation = representation;
            preferences.insertion.as_mut().unwrap().name_encoding =
                InsertionNameEncoding::StaticName(1);
            let section = encoder
                .encode(0, [field(":path", value, &preferences)])
                .unwrap();
            let instructions = encoder.take_encoder_stream();
            assert_eq!(encoder.insert_count(), 1);

            let dynamic = representation == Representation::DynamicIndex || value != "/";
            let mut cursor = section.as_ref();
            let prefix = HeaderPrefix::decode(&mut cursor, 128, 1).unwrap();
            assert_eq!(prefix.required_insert_count, u64::from(dynamic));
            assert_eq!(prefix.base, u64::from(dynamic));
            let line = FieldLine::decode(&mut cursor, 4096).unwrap();
            if dynamic {
                assert_matches!(
                    line,
                    FieldLine::Indexed {
                        is_static: false,
                        index: 0
                    }
                );
                // One insertion => Encoded Insert Count 2, Delta Base 0,
                // relative dynamic index 0 (RFC 9204 sections 4.5.1 and 4.5.2).
                assert_eq!(section.as_ref(), &[2, 0, 0x80]);
            } else {
                assert_matches!(
                    line,
                    FieldLine::Indexed {
                        is_static: true,
                        index: 1
                    }
                );
            }
            assert!(cursor.is_empty());

            let mut decoder = Decoder::new(DecoderConfig::default());
            decoder.feed_encoder_stream(&instructions).unwrap();
            let decoded = decoder.decode_field_section(0, section).unwrap().unwrap();
            assert_eq!(decoded[0].name.as_ref(), b":path");
            assert_eq!(decoded[0].value.as_ref(), value.as_bytes());
        }
    }
}

#[test]
fn observed_dynamic_field_indexes_select_native_policy_without_reusing_indexes() {
    for line in [
        FieldLine::Indexed {
            is_static: false,
            index: 900,
        },
        FieldLine::IndexedPostBase { index: 700 },
    ] {
        let preferences =
            FieldPreferences::from_observed(&ObservedFieldRepresentation::from(&line)).unwrap();
        let mut encoder = Encoder::new(EncoderConfig::default());
        let section = encoder
            .encode_with_base(
                0,
                [field(":path", "/", &preferences)],
                FieldSectionBase::FromFieldPreferences,
            )
            .unwrap();
        let mut cursor = section.as_ref();
        let prefix = HeaderPrefix::decode(&mut cursor, 128, 1).unwrap();
        assert_eq!(prefix.required_insert_count, 1);
        let observed = ObservedFieldRepresentation::from(&line);
        let actual =
            ObservedFieldRepresentation::from(&FieldLine::decode(&mut cursor, 4096).unwrap());
        assert_eq!(actual.representation, observed.representation);
        assert_eq!(actual.index, Some(0));
        let mut decoder = Decoder::new(DecoderConfig::default());
        decoder
            .feed_encoder_stream(&encoder.take_encoder_stream())
            .unwrap();
        let fields = decoder.decode_field_section(0, section).unwrap().unwrap();
        assert_eq!(fields[0].value.as_ref(), b"/");
    }
}

#[test]
fn dynamic_field_preference_retains_sensitivity_deferral_and_resource_limits() {
    let preferences = FieldPreferences {
        representation: Representation::DynamicIndex,
        ..FieldPreferences::default()
    };
    for (case, config, never_index) in [
        (
            "peer disallows blocked streams",
            EncoderConfig {
                max_blocked_streams: 0,
                ..EncoderConfig::default()
            },
            false,
        ),
        (
            "dynamic capacity is disabled",
            EncoderConfig {
                target_capacity: 0,
                ..EncoderConfig::default()
            },
            false,
        ),
        (
            "section tracking is exhausted",
            EncoderConfig {
                max_outstanding_sections: 0,
                ..EncoderConfig::default()
            },
            false,
        ),
        (
            "reference tracking is exhausted",
            EncoderConfig {
                max_outstanding_references: 0,
                ..EncoderConfig::default()
            },
            false,
        ),
        (
            "encoder output credit is exhausted",
            EncoderConfig {
                max_encoder_stream_bytes: 0,
                ..EncoderConfig::default()
            },
            false,
        ),
        (
            "initial references are deferred",
            EncoderConfig {
                defer_dynamic_first_section: true,
                ..EncoderConfig::default()
            },
            false,
        ),
        (
            "caller marks the field sensitive",
            EncoderConfig::default(),
            true,
        ),
        (
            "current entry exceeds table capacity",
            EncoderConfig {
                target_capacity: 1,
                ..EncoderConfig::default()
            },
            false,
        ),
    ] {
        let mut encoder = Encoder::new(config);
        let section = encoder
            .encode(
                0,
                [EncodeField {
                    name: ":path",
                    value: "/",
                    never_index,
                    preferences: Some(&preferences),
                }],
            )
            .unwrap();
        assert_eq!(encoder.insert_count(), 0, "case {case}");
        let mut cursor = section.as_ref();
        assert_eq!(
            HeaderPrefix::decode(&mut cursor, 128, 0)
                .unwrap()
                .required_insert_count,
            0
        );
        assert_matches!(
            FieldLine::decode(&mut cursor, 4096).unwrap(),
            FieldLine::LiteralWithNameRef {
                is_static: true,
                name_index: 1,
                ..
            }
        );
        let mut decoder = Decoder::new(DecoderConfig::default());
        decoder
            .feed_encoder_stream(&encoder.take_encoder_stream())
            .unwrap();
        let fields = decoder.decode_field_section(0, section).unwrap().unwrap();
        assert_eq!(fields[0].value.as_ref(), b"/");
        assert_eq!(fields[0].never_index, never_index, "{case}");
    }
}
