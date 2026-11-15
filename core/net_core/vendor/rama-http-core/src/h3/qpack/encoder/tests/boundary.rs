use super::*;
use rama_http_types::proto::h3::{
    observation::FieldRepresentation,
    qpack::encoding::{InsertionPreferences, InsertionScope},
};

fn preference(representation: Representation) -> FieldPreferences {
    FieldPreferences {
        representation,
        value_huffman: Some(true),
        ..FieldPreferences::default()
    }
}

fn fields<'a>(
    input: &'a [(&'a str, &'a str, FieldPreferences)],
) -> impl Iterator<Item = EncodeField<'a, &'a [u8], &'a [u8]>> {
    input.iter().map(|(name, value, preferences)| EncodeField {
        name: name.as_bytes(),
        value: value.as_bytes(),
        never_index: false,
        preferences: Some(preferences),
    })
}

fn check(
    encoder: &mut Encoder,
    decoder: &mut Decoder,
    stream: u64,
    input: &[(&str, &str, FieldPreferences)],
    expected_base: u64,
) -> Bytes {
    let section = encoder
        .encode_with_base(
            stream,
            fields(input),
            FieldSectionBase::FromFieldPreferences,
        )
        .unwrap();
    decoder
        .feed_encoder_stream(&encoder.take_encoder_stream())
        .unwrap();
    let mut cursor = section.as_ref();
    let prefix = HeaderPrefix::decode(&mut cursor, 128, encoder.insert_count()).unwrap();
    assert_eq!(prefix.base, expected_base);
    for (_, _, preferences) in input {
        let line = FieldLine::decode(&mut cursor, 4096).unwrap();
        let observed = ObservedFieldRepresentation::from(&line);
        let expected = match preferences.representation {
            Representation::DynamicIndexBeforeBase => FieldRepresentation::DynamicIndex,
            Representation::DynamicIndexAfterBase => FieldRepresentation::DynamicPostBaseIndex,
            Representation::LiteralDynamicNameBeforeBase => FieldRepresentation::LiteralDynamicName,
            Representation::LiteralDynamicNameAfterBase => FieldRepresentation::LiteralPostBaseName,
            _ => panic!("test requires constrained fields"),
        };
        assert_eq!(observed.representation, expected);
        if matches!(
            preferences.representation,
            Representation::LiteralDynamicNameBeforeBase
                | Representation::LiteralDynamicNameAfterBase
        ) {
            assert!(observed.value_huffman);
        }
    }
    assert!(cursor.is_empty());
    let decoded = decoder
        .decode_field_section(stream, section.clone())
        .unwrap()
        .unwrap();
    for (actual, (name, value, _)) in decoded.iter().zip(input) {
        assert_eq!(actual.name.as_ref(), name.as_bytes());
        assert_eq!(actual.value.as_ref(), value.as_bytes());
        assert!(!actual.never_index);
    }
    assert_eq!(decoded.len(), input.len());
    section
}

#[test]
fn mixed_fetch_order_preserves_pre_and_post_base_families_with_current_values() {
    let input = [
        (
            "x-marker",
            "current-marker",
            preference(Representation::DynamicIndexAfterBase),
        ),
        (
            "alt-used",
            "current-authority",
            preference(Representation::DynamicIndexBeforeBase),
        ),
        (
            "sec-fetch-dest",
            "empty",
            preference(Representation::LiteralDynamicNameBeforeBase),
        ),
        (
            "sec-fetch-mode",
            "cors",
            preference(Representation::LiteralDynamicNameBeforeBase),
        ),
        (
            "sec-fetch-site",
            "same-origin",
            preference(Representation::DynamicIndexBeforeBase),
        ),
        (
            "priority",
            "u=4",
            preference(Representation::LiteralDynamicNameBeforeBase),
        ),
    ];
    let mut encoder = Encoder::new(EncoderConfig::default());
    let mut decoder = Decoder::new(DecoderConfig::default());
    check(&mut encoder, &mut decoder, 0, &input, 5);
    assert_eq!(encoder.insert_count(), 6);
}

#[test]
fn mixed_form_order_places_trailing_pre_base_name_before_user_activation() {
    let input = [
        (
            "alt-used",
            "current-authority",
            preference(Representation::DynamicIndexBeforeBase),
        ),
        (
            "sec-fetch-dest",
            "document",
            preference(Representation::LiteralDynamicNameBeforeBase),
        ),
        (
            "sec-fetch-mode",
            "navigate",
            preference(Representation::LiteralDynamicNameBeforeBase),
        ),
        (
            "sec-fetch-site",
            "same-origin",
            preference(Representation::DynamicIndexBeforeBase),
        ),
        (
            "sec-fetch-user",
            "?1",
            preference(Representation::DynamicIndexAfterBase),
        ),
        (
            "priority",
            "u=0, i",
            preference(Representation::LiteralDynamicNameBeforeBase),
        ),
    ];
    let mut encoder = Encoder::new(EncoderConfig::default());
    let mut decoder = Decoder::new(DecoderConfig::default());
    check(&mut encoder, &mut decoder, 0, &input, 5);
    assert_eq!(encoder.insert_count(), 6);
}

#[test]
fn legal_existing_references_and_repeated_names_reuse_current_entries() {
    let mut encoder = Encoder::new(EncoderConfig::default());
    let mut decoder = Decoder::new(DecoderConfig::default());
    let seed = encoder
        .encode(0, [("x-before", "one"), ("x-after", "two")])
        .unwrap();
    decoder
        .feed_encoder_stream(&encoder.take_encoder_stream())
        .unwrap();
    decoder.decode_field_section(0, seed).unwrap().unwrap();
    encoder
        .feed_decoder_stream(&decoder.take_decoder_stream())
        .unwrap();
    let mixed = [
        (
            "x-after",
            "two",
            preference(Representation::DynamicIndexAfterBase),
        ),
        (
            "x-before",
            "one",
            preference(Representation::DynamicIndexBeforeBase),
        ),
        (
            "x-before",
            "fresh literal",
            preference(Representation::LiteralDynamicNameBeforeBase),
        ),
    ];
    check(&mut encoder, &mut decoder, 4, &mixed, 1);
    assert_eq!(
        encoder.insert_count(),
        2,
        "legal existing post reference is not duplicated"
    );
    encoder
        .feed_decoder_stream(&decoder.take_decoder_stream())
        .unwrap();
    check(
        &mut encoder,
        &mut decoder,
        8,
        &[(
            "x-after",
            "two",
            preference(Representation::DynamicIndexAfterBase),
        )],
        0,
    );
    assert_eq!(
        encoder.insert_count(),
        2,
        "all-post existing reference is reused"
    );
    encoder
        .feed_decoder_stream(&decoder.take_decoder_stream())
        .unwrap();
    check(
        &mut encoder,
        &mut decoder,
        12,
        &[(
            "x-before",
            "one",
            preference(Representation::DynamicIndexBeforeBase),
        )],
        1,
    );
    assert_eq!(
        encoder.insert_count(),
        2,
        "all-pre existing reference is reused"
    );
    encoder
        .feed_decoder_stream(&decoder.take_decoder_stream())
        .unwrap();
    let same = [
        (
            "x-before",
            "one",
            preference(Representation::DynamicIndexAfterBase),
        ),
        (
            "x-before",
            "one",
            preference(Representation::DynamicIndexBeforeBase),
        ),
        (
            "x-before",
            "one",
            preference(Representation::DynamicIndexAfterBase),
        ),
    ];
    check(&mut encoder, &mut decoder, 16, &same, 1);
    assert_eq!(
        encoder.insert_count(),
        3,
        "one duplicate suffices for both post references"
    );
}

/// Decode `section` after the encoder's queued instructions; every current value survives.
fn decodes(
    encoder: &mut Encoder,
    decoder: &mut Decoder,
    stream: u64,
    section: Bytes,
    input: &[(&str, &str, FieldPreferences)],
) {
    decoder
        .feed_encoder_stream(&encoder.take_encoder_stream())
        .unwrap();
    let decoded = decoder
        .decode_field_section(stream, section)
        .unwrap()
        .unwrap();
    assert_eq!(decoded.len(), input.len());
    for (actual, (name, value, preferences)) in decoded.iter().zip(input) {
        assert_eq!(actual.name.as_ref(), name.as_bytes());
        assert_eq!(actual.value.as_ref(), value.as_bytes());
        assert_eq!(actual.never_index, preferences.never_index);
    }
}

#[test]
fn unavailable_positions_fall_back_to_native_fields_and_later_sections_recover() {
    let input = [
        (
            "x-post",
            "current",
            preference(Representation::DynamicIndexAfterBase),
        ),
        (
            "x-pre",
            "literal",
            preference(Representation::LiteralDynamicNameBeforeBase),
        ),
    ];
    for case in 0..9 {
        let mut config = EncoderConfig::default();
        match case {
            0 => config.max_encoder_stream_bytes = 0,
            1 => config.max_table_capacity = 0,
            2 => config.max_outstanding_references = 1,
            3 => config.max_outstanding_sections = 0,
            4 => config.max_blocked_streams = 0,
            5 => config.defer_dynamic_first_section = true,
            6 => config.target_capacity = 32,
            _ => (),
        }
        let mut encoder = Encoder::new(config);
        if case == 7 {
            encoder
                .on_decoder_instruction(DecoderInstruction::StreamCancellation { stream_id: 0 })
                .unwrap();
        }
        let mut input = input;
        if case == 8 {
            input[1].2.never_index = true;
        }
        let stream = 0;
        let section = encoder
            .encode_with_base(
                stream,
                fields(&input),
                FieldSectionBase::FromFieldPreferences,
            )
            .unwrap_or_else(|error| panic!("case {case}: {error}"));
        decodes(
            &mut encoder,
            &mut Decoder::new(DecoderConfig::default()),
            stream,
            section,
            &input,
        );
        if case == 0 || case == 7 {
            encoder.config.max_encoder_stream_bytes = 4096;
            let mut decoder = Decoder::new(DecoderConfig::default());
            check(
                &mut encoder,
                &mut decoder,
                if case == 7 { 4 } else { 0 },
                &input,
                1,
            );
        }
    }
}

#[test]
fn preflight_protects_existing_acknowledged_pre_base_entry_from_eviction() {
    let mut encoder = Encoder::new(EncoderConfig {
        target_capacity: 100,
        ..EncoderConfig::default()
    });
    encoder
        .encode(0, [("x-pre", "one"), ("x-other", "two")])
        .unwrap();
    encoder
        .on_decoder_instruction(DecoderInstruction::SectionAcknowledgment { stream_id: 0 })
        .unwrap();
    let mut decoder = Decoder::new(DecoderConfig::default());
    decoder
        .feed_encoder_stream(&encoder.take_encoder_stream())
        .unwrap();
    let input = [
        (
            "x-post",
            "a new entry that would evict the required oldest entry",
            preference(Representation::DynamicIndexAfterBase),
        ),
        (
            "x-pre",
            "one",
            preference(Representation::DynamicIndexBeforeBase),
        ),
    ];
    // The post-Base insertion would evict the pre-Base entry, so only that field falls back.
    let section = encoder
        .encode_with_base(4, fields(&input), FieldSectionBase::FromFieldPreferences)
        .unwrap();
    assert_eq!(encoder.insert_count(), 2);
    assert!(encoder.table.get(0).is_some());
    let mut cursor = section.as_ref();
    HeaderPrefix::decode(&mut cursor, 128, encoder.insert_count()).unwrap();
    let lines: Vec<_> = (0..2)
        .map(|_| {
            ObservedFieldRepresentation::from(&FieldLine::decode(&mut cursor, 4096).unwrap())
                .representation
        })
        .collect();
    assert_eq!(
        lines,
        [
            FieldRepresentation::LiteralName,
            FieldRepresentation::DynamicIndex
        ]
    );
    decodes(&mut encoder, &mut decoder, 4, section, &input);
}

#[test]
fn ordered_explicit_bootstrap_insertions_keep_relative_families_and_reuse() {
    let input: Vec<_> = (0..34)
        .map(|index| {
            (
                format!("x-current-{index}"),
                format!("value-{index}"),
                FieldPreferences {
                    insertion: Some(InsertionPreferences {
                        scope: InsertionScope::InitialSection,
                        ..InsertionPreferences::default()
                    }),
                    ..preference(Representation::DynamicIndexBeforeBase)
                },
            )
        })
        .collect();
    let borrowed: Vec<_> = input
        .iter()
        .map(|(name, value, p)| (name.as_str(), value.as_str(), *p))
        .collect();
    let mut encoder = Encoder::new(EncoderConfig::default());
    let mut decoder = Decoder::new(DecoderConfig::default());
    check(&mut encoder, &mut decoder, 0, &borrowed, 34);
    assert_eq!(encoder.insert_count(), 34);
    for (index, (name, value, _)) in input.iter().enumerate() {
        let actual = encoder.table.get(index as u64).unwrap();
        assert_eq!(actual.0.as_ref(), name.as_bytes());
        assert_eq!(actual.1.as_ref(), value.as_bytes());
    }
    encoder
        .feed_decoder_stream(&decoder.take_decoder_stream())
        .unwrap();
    check(&mut encoder, &mut decoder, 4, &borrowed, 34);
    assert_eq!(encoder.insert_count(), 34);
}

#[test]
fn incompatible_explicit_order_and_caller_base_fall_back_per_field() {
    let explicit = Some(InsertionPreferences::default());
    let input = [
        (
            "x-post",
            "one",
            FieldPreferences {
                insertion: explicit,
                ..preference(Representation::DynamicIndexAfterBase)
            },
        ),
        (
            "x-pre",
            "two",
            FieldPreferences {
                insertion: explicit,
                ..preference(Representation::DynamicIndexBeforeBase)
            },
        ),
    ];
    for policy in [
        FieldSectionBase::FromFieldPreferences,
        FieldSectionBase::BeforeSection,
    ] {
        let mut encoder = Encoder::new(EncoderConfig::default());
        let section = encoder.encode_with_base(0, fields(&input), policy).unwrap();
        // Both explicit insertions still happen in their supplied order.
        assert_eq!(encoder.insert_count(), 2, "{policy:?}");
        decodes(
            &mut encoder,
            &mut Decoder::new(DecoderConfig::default()),
            0,
            section,
            &input,
        );
    }
}

#[test]
fn no_hint_automatic_encoding_retains_original_wire_and_state() {
    let mut ordinary = Encoder::new(EncoderConfig::default());
    let mut preferences = Encoder::new(EncoderConfig::default());
    let input = [("x-custom", "current", FieldPreferences::default())];
    for stream in [0, 4] {
        assert_eq!(
            ordinary.encode(stream, [("x-custom", "current")]).unwrap(),
            preferences.encode(stream, fields(&input)).unwrap()
        );
        assert_eq!(
            ordinary.take_encoder_stream(),
            preferences.take_encoder_stream()
        );
        assert_eq!(ordinary.insert_count(), preferences.insert_count());
        assert_eq!(
            ordinary.tracked_reference_count(),
            preferences.tracked_reference_count()
        );
    }
}

#[test]
fn automatic_fields_under_explicit_base_policy_keep_legal_literal_fallbacks() {
    let mut encoder = Encoder::new(EncoderConfig {
        max_table_capacity: 0,
        max_blocked_streams: 0,
        max_encoder_stream_bytes: 0,
        ..EncoderConfig::default()
    });
    let input = [
        ("x-current", "value", FieldPreferences::default()),
        (":method", "GET", FieldPreferences::default()),
    ];
    let section = encoder
        .encode_with_base(0, fields(&input), FieldSectionBase::FromFieldPreferences)
        .unwrap();
    assert_eq!(encoder.insert_count(), 0);
    assert_eq!(encoder.tracked_reference_count(), 0);
    assert_eq!(encoder.encoder_stream_len(), 0);
    let mut decoder = Decoder::new(DecoderConfig::default());
    let decoded = decoder.decode_field_section(0, section).unwrap().unwrap();
    assert_eq!(decoded[0].name.as_ref(), b"x-current");
    assert_eq!(decoded[0].value.as_ref(), b"value");
    assert_eq!(decoded[1].value.as_ref(), b"GET");
    let unpositioned = [(
        "x-current",
        "value",
        preference(Representation::DynamicIndex),
    )];
    let section = encoder
        .encode_with_base(
            4,
            fields(&unpositioned),
            FieldSectionBase::FromFieldPreferences,
        )
        .unwrap();
    assert_eq!(encoder.insert_count(), 0);
    assert_eq!(encoder.tracked_reference_count(), 0);
    decodes(&mut encoder, &mut decoder, 4, section, &unpositioned);
}

#[test]
fn unpositioned_dynamic_preferences_use_the_pre_base_side_of_field_base() {
    let input = [
        (
            "x-name",
            "literal",
            preference(Representation::LiteralDynamicName),
        ),
        ("x-full", "value", preference(Representation::DynamicIndex)),
    ];
    let mut encoder = Encoder::new(EncoderConfig::default());
    let mut decoder = Decoder::new(DecoderConfig::default());
    let section = encoder
        .encode_with_base(0, fields(&input), FieldSectionBase::FromFieldPreferences)
        .unwrap();
    let mut cursor = section.as_ref();
    let prefix = HeaderPrefix::decode(&mut cursor, 128, encoder.insert_count()).unwrap();
    assert_eq!(prefix.base, 2);
    for expected in [
        FieldRepresentation::LiteralDynamicName,
        FieldRepresentation::DynamicIndex,
    ] {
        let line = FieldLine::decode(&mut cursor, 4096).unwrap();
        assert_eq!(
            ObservedFieldRepresentation::from(&line).representation,
            expected
        );
    }
    decodes(&mut encoder, &mut decoder, 0, section, &input);
}

#[test]
fn positioned_preferences_without_field_base_keep_their_family() {
    let input = [
        (
            "x-pre",
            "value",
            preference(Representation::DynamicIndexBeforeBase),
        ),
        (
            "x-post",
            "literal",
            preference(Representation::LiteralDynamicNameAfterBase),
        ),
    ];
    for policy in [
        FieldSectionBase::BeforeSection,
        FieldSectionBase::RequiredInsertCount,
    ] {
        let mut encoder = Encoder::new(EncoderConfig::default());
        let section = encoder.encode_with_base(0, fields(&input), policy).unwrap();
        let mut cursor = section.as_ref();
        HeaderPrefix::decode(&mut cursor, 128, encoder.insert_count()).unwrap();
        let lines: Vec<_> = (0..2)
            .map(|_| {
                let line = FieldLine::decode(&mut cursor, 4096).unwrap();
                ObservedFieldRepresentation::from(&line).representation
            })
            .collect();
        // Fresh entries land on the side of the Base the policy puts them.
        assert!(
            matches!(
                lines[0],
                FieldRepresentation::DynamicIndex | FieldRepresentation::DynamicPostBaseIndex
            ),
            "{policy:?}: {lines:?}"
        );
        assert!(
            matches!(
                lines[1],
                FieldRepresentation::LiteralDynamicName | FieldRepresentation::LiteralPostBaseName
            ),
            "{policy:?}: {lines:?}"
        );
        decodes(
            &mut encoder,
            &mut Decoder::new(DecoderConfig::default()),
            0,
            section,
            &input,
        );
    }
}

#[test]
fn ordered_initial_insertions_support_post_base_references_without_reordering() {
    let current = [
        ("alt-used", "current-authority"),
        ("sec-fetch-dest", "document"),
        ("sec-fetch-mode", "navigate"),
        ("sec-fetch-site", "none"),
        ("sec-fetch-user", "?1"),
        ("priority", "u=1"),
    ];
    for before in [0, 2] {
        let input: Vec<_> = current
            .iter()
            .enumerate()
            .map(|(index, (name, value))| {
                (
                    *name,
                    *value,
                    FieldPreferences {
                        insertion: Some(InsertionPreferences {
                            scope: InsertionScope::InitialSection,
                            name_huffman: Some(true),
                            value_huffman: Some(true),
                            ..InsertionPreferences::default()
                        }),
                        ..preference(if index < before {
                            Representation::DynamicIndexBeforeBase
                        } else {
                            Representation::DynamicIndexAfterBase
                        })
                    },
                )
            })
            .collect();
        let mut encoder = Encoder::new(EncoderConfig::default());
        let mut decoder = Decoder::new(DecoderConfig::default());
        let section = check(&mut encoder, &mut decoder, 0, &input, before as u64);
        assert_eq!(
            encoder.insert_count(),
            6,
            "no duplicate or reordered insertion"
        );
        let mut cursor = section.as_ref();
        let prefix = HeaderPrefix::decode(&mut cursor, 128, encoder.insert_count()).unwrap();
        assert_eq!(prefix.required_insert_count, 6);
        for (index, (name, value)) in current.iter().enumerate() {
            let entry = encoder.table.get(index as u64).unwrap();
            assert_eq!(entry.0.as_ref(), name.as_bytes());
            assert_eq!(entry.1.as_ref(), value.as_bytes());
            let field = FieldLine::decode(&mut cursor, 4096).unwrap();
            if index < before {
                assert!(
                    matches!(field, FieldLine::Indexed { is_static: false, index: relative } if relative == (before-index-1) as u64)
                );
            } else {
                assert!(
                    matches!(field, FieldLine::IndexedPostBase { index: post } if post == (index-before) as u64)
                );
            }
        }
        assert!(cursor.is_empty());
    }
}
