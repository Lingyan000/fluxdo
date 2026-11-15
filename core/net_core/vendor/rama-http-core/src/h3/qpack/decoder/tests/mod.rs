use super::*;
use crate::h3::qpack::ErrorScope;
use rama_http_types::proto::h3::Code;
use std::assert_matches;

fn section(ric: u64, base: u64, line: &FieldLine) -> Bytes {
    let mut bytes = BytesMut::new();
    HeaderPrefix::new(ric, base)
        .encode(&mut bytes, DecoderConfig::default().max_table_capacity / 32)
        .unwrap();
    line.encode(&mut bytes);
    bytes.freeze()
}

fn insertion() -> Bytes {
    let mut bytes = BytesMut::new();
    EncoderInstruction::SetDynamicTableCapacity {
        capacity: kib_u64(4),
    }
    .encode(&mut bytes);
    EncoderInstruction::InsertWithLiteralName {
        name: Bytes::from_static(b"a"),
        value: Bytes::from_static(b"b"),
        name_huffman: false,
        value_huffman: false,
    }
    .encode(&mut bytes);
    bytes.freeze()
}

/// The table capacity counts names and values only, so an entry holds no more than those:
/// a literal decoded from Huffman codes far longer than a byte keeps no spare capacity.
#[test]
fn dynamic_table_entries_hold_only_their_own_bytes() {
    for huffman in [true, false] {
        let mut bytes = BytesMut::new();
        for instruction in [
            EncoderInstruction::SetDynamicTableCapacity {
                capacity: kib_u64(4),
            },
            EncoderInstruction::InsertWithLiteralName {
                name: Bytes::from(vec![b'a'; 100]),
                value: Bytes::from(vec![0x0a; 100]),
                name_huffman: huffman,
                value_huffman: huffman,
            },
            EncoderInstruction::InsertWithNameRef {
                is_static: true,
                name_index: 0,
                value: Bytes::from(vec![0x0a; 100]),
                value_huffman: huffman,
            },
        ] {
            instruction.encode(&mut bytes);
        }
        let mut decoder = Decoder::new(DecoderConfig::default());
        decoder.feed_encoder_stream(&bytes).unwrap();
        let (literal_name, literal_value) = decoder.table.get(0).expect("literal inserted");
        let (_, referenced_value) = decoder.table.get(1).expect("name reference inserted");
        drop(decoder);
        for octets in [literal_name, literal_value, referenced_value] {
            let octets = octets
                .try_into_mut()
                .expect("nothing else holds the entry once the decoder is gone");
            assert_eq!(octets.capacity(), octets.len(), "huffman: {huffman}");
        }
    }
}

/// Re-inserting an existing entry costs no allocation, however large the entry.
#[test]
fn duplicates_and_dynamic_name_references_share_entry_octets() {
    let mut bytes = BytesMut::new();
    for instruction in [
        EncoderInstruction::SetDynamicTableCapacity {
            capacity: kib_u64(4),
        },
        EncoderInstruction::InsertWithLiteralName {
            name: Bytes::from(vec![b'n'; 500]),
            value: Bytes::from(vec![b'v'; 500]),
            name_huffman: false,
            value_huffman: false,
        },
        EncoderInstruction::Duplicate { index: 0 },
        EncoderInstruction::InsertWithNameRef {
            is_static: false,
            name_index: 0,
            value: Bytes::from_static(b"x"),
            value_huffman: false,
        },
    ] {
        instruction.encode(&mut bytes);
    }
    let mut decoder = Decoder::new(DecoderConfig::default());
    decoder.feed_encoder_stream(&bytes).unwrap();
    let (name, value) = decoder.table.get(0).unwrap();
    let (duplicate_name, duplicate_value) = decoder.table.get(1).unwrap();
    let (referenced_name, _) = decoder.table.get(2).unwrap();
    assert_eq!(duplicate_name.as_ptr(), name.as_ptr());
    assert_eq!(duplicate_value.as_ptr(), value.as_ptr());
    assert_eq!(referenced_name.as_ptr(), name.as_ptr());
}

#[test]
fn clean_close_decode_preserves_outstanding_write_accounting() {
    let mut decoder = Decoder::new(DecoderConfig::default());
    decoder.feed_encoder_stream(&insertion()).unwrap();
    let output = decoder.take_output_for_write();
    let bytes = section(1, 0, &FieldLine::IndexedPostBase { index: 0 });
    assert!(
        decoder
            .decode_field_section_after_close(0, bytes)
            .unwrap()
            .is_some()
    );
    assert_eq!(decoder.output_in_flight, output.len());
    assert!(decoder.decoder_output.is_empty());
    decoder.output_written(output.len());
    assert_eq!(decoder.output_in_flight, 0);
}

#[test]
fn local_storage_limit_releases_only_affected_stream() {
    let bytes = section(1, 0, &FieldLine::IndexedPostBase { index: 0 });
    let mut decoder = Decoder::new(DecoderConfig {
        max_blocked_bytes: 2 * (bytes.len() + size_of::<BlockedSection>()),
        ..DecoderConfig::default()
    });
    decoder.decode_field_section(0, bytes.clone()).unwrap();
    decoder.decode_field_section(4, bytes.clone()).unwrap();
    let error = decoder.decode_field_section(0, bytes.clone()).unwrap_err();
    assert_eq!(error.code(), Some(Code::H3_EXCESSIVE_LOAD));
    assert_eq!(error.scope(), Some(ErrorScope::Stream));
    assert_eq!(decoder.blocked_stream_count(), 1);
    decoder.cancel_stream(0).unwrap();
    decoder.decode_field_section(8, bytes).unwrap();
    decoder.feed_encoder_stream(&insertion()).unwrap();
    let decoded = decoder.resume_blocked();
    assert_eq!(
        decoded.iter().map(|(id, _)| *id).collect::<Vec<_>>(),
        [4, 8]
    );
    assert!(decoded.into_iter().all(|(_, fields)| fields.is_ok()));
    assert_eq!(decoder.blocked_bytes, 0);
}

#[test]
fn aggregate_field_size_limit_has_http_stream_scope() {
    let mut decoder = Decoder::new(DecoderConfig {
        max_field_section_size: 32,
        ..DecoderConfig::default()
    });
    let bytes = section(
        0,
        0,
        &FieldLine::Indexed {
            is_static: true,
            index: 17,
        },
    );
    let error = decoder.decode_field_section(0, bytes).unwrap_err();
    assert_eq!(error.code(), Some(Code::H3_EXCESSIVE_LOAD));
    assert_eq!(error.scope(), Some(ErrorScope::Stream));
    assert_eq!(
        decoder
            .decode_field_section(4, Bytes::from_static(&[0, 0]))
            .unwrap(),
        Some(vec![])
    );
}

#[test]
fn field_line_limit_has_http_stream_scope() {
    let mut decoder = Decoder::new(DecoderConfig {
        max_field_lines: 2,
        ..DecoderConfig::default()
    });
    let line = FieldLine::Indexed {
        is_static: true,
        index: 17,
    };
    let mut lines = BytesMut::new();
    for _ in 0..3 {
        line.encode(&mut lines);
    }
    let three = [&[0u8, 0][..], &lines].concat();
    let error = decoder
        .decode_field_section(0, Bytes::from(three.clone()))
        .unwrap_err();
    assert_eq!(error.code(), Some(Code::H3_EXCESSIVE_LOAD));
    assert_eq!(error.scope(), Some(ErrorScope::Stream));
    let two = Bytes::from(three[..three.len() - 1].to_vec());
    assert_eq!(
        decoder.decode_field_section(4, two).unwrap().unwrap().len(),
        2
    );
}

#[test]
fn encoder_literal_budget_tracks_current_table_capacity() {
    let mut decoder = Decoder::new(DecoderConfig::default());
    let mut capacity = BytesMut::new();
    EncoderInstruction::SetDynamicTableCapacity { capacity: 64 }.encode(&mut capacity);
    decoder.feed_encoder_stream(&capacity).unwrap();
    assert_eq!(decoder.max_insert_string_len(), 32);
    let mut instruction = BytesMut::new();
    EncoderInstruction::InsertWithLiteralName {
        name: Bytes::from_static(b"x"),
        value: Bytes::from(vec![b'a'; kib(64)]),
        name_huffman: false,
        value_huffman: false,
    }
    .encode(&mut instruction);
    // The length prefix is sufficient to reject this impossible insertion;
    // no full literal or half-megabyte staging allocation is needed.
    assert_matches!(
        decoder.feed_encoder_stream(&instruction[..8]),
        Err(QpackError::EncoderStreamError(_)),
    );
    assert!(decoder.encoder_stream.capacity() < kib(1));
}

#[test]
fn large_huffman_insert_fragmented_bytewise_decodes_only_when_complete() {
    let mut decoder = Decoder::new(DecoderConfig::default());
    let mut bytes = BytesMut::new();
    EncoderInstruction::SetDynamicTableCapacity {
        capacity: kib_u64(4),
    }
    .encode(&mut bytes);
    decoder.feed_encoder_stream(&bytes).unwrap();
    bytes.clear();
    EncoderInstruction::InsertWithLiteralName {
        name: Bytes::from(vec![b'a'; kib(1)]),
        value: Bytes::from(vec![0xff; kib(2)]),
        name_huffman: true,
        value_huffman: true,
    }
    .encode(&mut bytes);
    let last = bytes.len() - 1;
    for (index, byte) in bytes.iter().enumerate() {
        decoder.feed_encoder_stream(&[*byte]).unwrap();
        assert_eq!(decoder.insert_count(), u64::from(index == last));
        assert!(decoder.encoder_stream.len() <= decoder.max_instruction_bytes());
    }
    assert!(decoder.encoder_stream.is_empty());
    assert_eq!(decoder.table.get(0).unwrap().1.as_ref(), vec![0xff; kib(2)]);
}

#[test]
fn detached_output_remains_charged_until_written() {
    let mut decoder = Decoder::new(DecoderConfig {
        max_decoder_stream_bytes: 10,
        ..DecoderConfig::default()
    });
    decoder.decoder_output.extend_from_slice(&[0; 10]);
    let output = decoder.take_output_for_write();
    assert_eq!(output.len(), 10);
    assert_eq!(decoder.reserve_output(1), Err(QpackError::OutputBlocked));
    decoder.output_written(4);
    decoder.reserve_output(4).unwrap();
    assert_eq!(decoder.reserve_output(5), Err(QpackError::OutputBlocked));
    decoder.decoder_output.extend_from_slice(&[0; 4]);
    assert_eq!(decoder.reserve_output(1), Err(QpackError::OutputBlocked));
    decoder.output_written(6);
    decoder.reserve_output(6).unwrap();
}

#[test]
fn every_dynamic_reference_must_be_below_ric() {
    let mut decoder = Decoder::new(DecoderConfig::default());
    decoder.feed_encoder_stream(&insertion()).unwrap();
    for (base, line) in [
        (
            1,
            FieldLine::Indexed {
                is_static: false,
                index: 0,
            },
        ),
        (0, FieldLine::IndexedPostBase { index: 0 }),
        (
            1,
            FieldLine::LiteralWithNameRef {
                is_static: false,
                name_index: 0,
                value: Bytes::new(),
                value_huffman: false,
                never_index: false,
            },
        ),
        (
            0,
            FieldLine::LiteralWithPostBaseNameRef {
                name_index: 0,
                value: Bytes::new(),
                value_huffman: false,
                never_index: false,
            },
        ),
    ] {
        assert_matches!(
            decoder.decode_field_section(0, section(0, base, &line)),
            Err(QpackError::DecompressionFailed(
                "dynamic reference exceeds required insert count"
            )),
        );
    }
}

#[test]
fn literal_is_shared_and_preserves_never_index() {
    let mut decoder = Decoder::new(DecoderConfig::default());
    let bytes = section(
        0,
        0,
        &FieldLine::LiteralWithLiteralName {
            name: Bytes::from_static(b"secret"),
            value: Bytes::from_static(b"value"),
            name_huffman: false,
            value_huffman: false,
            never_index: true,
        },
    );
    let start = bytes.as_ptr() as usize;
    let end = start + bytes.len();
    let fields = decoder.decode_field_section(0, bytes).unwrap().unwrap();
    assert!(fields[0].never_index);
    for bytes in [&fields[0].name, &fields[0].value] {
        assert!((start..end).contains(&(bytes.as_ptr() as usize)));
    }
}

#[test]
fn fragmented_instruction_matches_whole_and_inbox_is_bounded() {
    let bytes = insertion();
    for split in 0..=bytes.len() {
        let mut decoder = Decoder::new(DecoderConfig::default());
        decoder.feed_encoder_stream(&bytes[..split]).unwrap();
        decoder.feed_encoder_stream(&bytes[split..]).unwrap();
        assert_eq!(decoder.insert_count(), 1);
        assert!(decoder.encoder_stream.is_empty());
    }
    let mut decoder = Decoder::new(DecoderConfig {
        max_field_section_size: 1,
        ..DecoderConfig::default()
    });
    // Literal name length 31 plus a continuation encoding an over-limit length, then huge input.
    let mut malicious = vec![0; kib(256)];
    malicious[0] = 0x5f;
    malicious[1] = 1;
    assert!(decoder.feed_encoder_stream(&malicious).is_err());
    assert!(decoder.encoder_stream.len() <= decoder.max_instruction_bytes());
}

#[test]
fn blocked_output_retries_preserve_sections_and_accounting() {
    let mut decoder = Decoder::new(DecoderConfig {
        max_decoder_stream_bytes: 11,
        max_blocked_bytes: 3 + size_of::<BlockedSection>(),
        ..DecoderConfig::default()
    });
    let bytes = section(1, 0, &FieldLine::IndexedPostBase { index: 0 });
    assert_eq!(bytes.len(), 3);
    assert_eq!(
        decoder.decode_field_section(4, bytes.clone()).unwrap(),
        None
    );
    decoder.decode_field_section(8, bytes).unwrap_err();
    decoder.feed_encoder_stream(&insertion()).unwrap();
    // Fill the remaining ten bytes with one-byte cancellations.
    for _ in 0..10 {
        decoder.cancel_stream(0).unwrap();
    }
    assert_eq!(
        decoder.resume_blocked(),
        vec![(4, Err(QpackError::OutputBlocked))]
    );
    assert_eq!(decoder.blocked_bytes, 3 + size_of::<BlockedSection>());
    assert_eq!(decoder.cancel_stream(4), Err(QpackError::OutputBlocked));
    assert_eq!(decoder.blocked_bytes, 3 + size_of::<BlockedSection>());
    assert_eq!(
        decoder.feed_encoder_stream(&[0]),
        Err(QpackError::OutputBlocked)
    );
    assert_eq!(decoder.insert_count(), 1);
    decoder.take_decoder_stream();
    let resumed = decoder.resume_blocked();
    assert_eq!(resumed.len(), 1);
    assert_eq!(resumed[0].1.as_ref().unwrap()[0].value, b"b"[..]);
    assert_eq!(decoder.blocked_bytes, 0);
    assert_eq!(decoder.blocked_stream_count(), 0);
    decoder.take_decoder_stream();
    decoder.feed_encoder_stream(&[0]).unwrap();
    assert_eq!(decoder.insert_count(), 2);
}

#[test]
fn malformed_resumed_section_releases_storage() {
    let mut decoder = Decoder::new(DecoderConfig {
        max_blocked_bytes: 3 + size_of::<BlockedSection>(),
        ..DecoderConfig::default()
    });
    // RIC=1 makes this wait, but post-base index 1 illegally exceeds that RIC.
    let bytes = section(1, 0, &FieldLine::IndexedPostBase { index: 1 });
    decoder.decode_field_section(4, bytes).unwrap();
    decoder.feed_encoder_stream(&insertion()).unwrap();
    let resumed = decoder.resume_blocked();
    assert_matches!(resumed[0].1, Err(QpackError::DecompressionFailed(_)));
    assert_eq!(decoder.blocked_bytes, 0);
    assert_eq!(decoder.blocked_stream_count(), 0);
}

#[test]
fn never_index_survives_all_literal_reference_forms() {
    let mut decoder = Decoder::new(DecoderConfig::default());
    decoder.feed_encoder_stream(&insertion()).unwrap();
    for (base, line) in [
        (
            1,
            FieldLine::LiteralWithNameRef {
                is_static: true,
                name_index: 0,
                value: Bytes::new(),
                value_huffman: false,
                never_index: true,
            },
        ),
        (
            1,
            FieldLine::LiteralWithNameRef {
                is_static: false,
                name_index: 0,
                value: Bytes::new(),
                value_huffman: false,
                never_index: true,
            },
        ),
        (
            0,
            FieldLine::LiteralWithPostBaseNameRef {
                name_index: 0,
                value: Bytes::new(),
                value_huffman: false,
                never_index: true,
            },
        ),
    ] {
        let fields = decoder
            .decode_field_section(0, section(1, base, &line))
            .unwrap()
            .unwrap();
        assert!(fields[0].never_index);
    }
}

#[test]
fn stream_ids_are_validated_before_mutation() {
    let mut decoder = Decoder::new(DecoderConfig::default());
    let invalid = VarInt::MAX.into_inner() + 1;
    decoder
        .decode_field_section(invalid, Bytes::from_static(&[0, 0]))
        .unwrap_err();
    decoder.cancel_stream(invalid).unwrap_err();
    assert_eq!(decoder.blocked_bytes, 0);
    assert!(decoder.take_decoder_stream().is_empty());
    decoder.cancel_stream(VarInt::MAX.into_inner()).unwrap();
}

#[test]
fn retained_sections_and_table_literals_do_not_pin_staging_allocations() {
    let mut decoder = Decoder::new(DecoderConfig::default());
    let mut allocation = vec![0; kib(256)];
    allocation[..3].copy_from_slice(&[2, 0x80, 0x10]);
    let allocation = Bytes::from(allocation);
    let start = allocation.as_ptr() as usize;
    let end = start + allocation.len();
    decoder
        .decode_field_section(0, allocation.slice(..3))
        .unwrap();
    let retained = &decoder.blocked[&0][0].body;
    assert!(!(start..end).contains(&(retained.as_ptr() as usize)));
    let instructions = insertion();
    decoder
        .feed_encoder_stream(&instructions[..instructions.len() - 1])
        .unwrap();
    let start = decoder.encoder_stream.as_ptr() as usize;
    let end = start + decoder.encoder_stream.capacity();
    decoder
        .feed_encoder_stream(&instructions[instructions.len() - 1..])
        .unwrap();
    let (name, value) = decoder.table.get(0).unwrap();
    assert!(!(start..end).contains(&(name.as_ptr() as usize)));
    assert!(!(start..end).contains(&(value.as_ptr() as usize)));
}

#[test]
fn blocked_stream_limit_counts_only_unreceived_insertions() {
    let mut decoder = Decoder::new(DecoderConfig {
        max_blocked_streams: 1,
        ..DecoderConfig::default()
    });
    decoder
        .decode_field_section(0, section(1, 0, &FieldLine::IndexedPostBase { index: 0 }))
        .unwrap();
    assert_eq!(decoder.blocked_stream_count(), 1);
    decoder.feed_encoder_stream(&insertion()).unwrap();
    // Stream 0 remains queued, but is now ready and does not consume the protocol budget.
    assert_eq!(decoder.blocked_stream_count(), 0);
    decoder
        .decode_field_section(4, section(2, 0, &FieldLine::IndexedPostBase { index: 1 }))
        .unwrap();
    assert_eq!(decoder.blocked_stream_count(), 1);
    assert_eq!(
        decoder.decode_field_section(0, section(2, 0, &FieldLine::IndexedPostBase { index: 1 })),
        Err(QpackError::DecompressionFailed("too many blocked streams"))
    );
    // A ready section can queue for ordering without consuming another blocked-stream slot.
    decoder
        .decode_field_section(0, Bytes::from_static(&[0, 0]))
        .unwrap();
    assert_eq!(decoder.blocked_stream_count(), 1);
}

#[test]
fn one_byte_output_budget_can_progress_by_splitting_input() {
    let mut decoder = Decoder::new(DecoderConfig {
        max_decoder_stream_bytes: 1,
        ..DecoderConfig::default()
    });
    for byte in insertion() {
        decoder.feed_encoder_stream(&[byte]).unwrap();
        decoder.take_decoder_stream();
    }
    assert_eq!(decoder.insert_count(), 1);
    // Sixty-three potential insertions need a two-byte increment reservation.
    assert_eq!(
        decoder.feed_encoder_stream(&[0; 63]),
        Err(QpackError::OutputBlocked)
    );
    assert_eq!(decoder.insert_count(), 1);
    for _ in 0..63 {
        decoder.feed_encoder_stream(&[0]).unwrap();
        assert_eq!(decoder.take_decoder_stream(), [1][..]);
    }
    assert_eq!(decoder.insert_count(), 64);
}

#[test]
fn impossible_atomic_output_is_terminal_instead_of_retryable() {
    let mut decoder = Decoder::new(DecoderConfig {
        max_decoder_stream_bytes: 1,
        ..DecoderConfig::default()
    });
    let expected = QpackError::ResourceLimit("decoder instruction exceeds output budget");
    assert_eq!(decoder.cancel_stream(64), Err(expected));
    assert!(decoder.take_decoder_stream().is_empty());

    let bytes = section(1, 0, &FieldLine::IndexedPostBase { index: 0 });
    decoder.decode_field_section(128, bytes.clone()).unwrap();
    for byte in insertion() {
        decoder.feed_encoder_stream(&[byte]).unwrap();
        decoder.take_decoder_stream();
    }
    let retained = decoder.blocked_bytes;
    assert_eq!(decoder.resume_blocked(), vec![(128, Err(expected))]);
    assert_eq!(decoder.blocked_bytes, retained);
    assert_eq!(decoder.decode_field_section(132, bytes), Err(expected));
    assert_eq!(decoder.blocked_bytes, retained);
    assert!(decoder.take_decoder_stream().is_empty());
}

#[test]
fn individual_limits_have_rfc_7_4_scope_and_recover_stream_storage() {
    let config = DecoderConfig {
        max_field_section_size: 1,
        ..DecoderConfig::default()
    };
    let mut decoder = Decoder::new(config);
    let oversized = section(
        1,
        0,
        &FieldLine::LiteralWithLiteralName {
            name: Bytes::from_static(b"ab"),
            value: Bytes::new(),
            never_index: true,
            name_huffman: false,
            value_huffman: false,
        },
    );
    decoder.decode_field_section(0, oversized).unwrap();
    decoder
        .decode_field_section(0, Bytes::from_static(&[0, 0]))
        .unwrap();
    decoder.feed_encoder_stream(&insertion()).unwrap();
    let results = decoder.resume_blocked();
    assert_eq!(results.len(), 1);
    let error = results[0].1.as_ref().unwrap_err();
    assert_eq!(error.scope(), Some(ErrorScope::Stream));
    assert_eq!(error.code(), Some(Code::QPACK_DECOMPRESSION_FAILED));
    assert_eq!(decoder.blocked_bytes, 0);
    assert!(decoder.blocked.is_empty());
    decoder.cancel_stream(0).unwrap();
    assert_eq!(
        decoder
            .decode_field_section(4, Bytes::from_static(&[0, 0]))
            .unwrap(),
        Some(vec![])
    );
    let mut other = Decoder::new(config);
    let error = other
        .feed_encoder_stream(&[0x42, b'a', b'b', 0])
        .unwrap_err();
    assert_eq!(error.scope(), Some(ErrorScope::Connection));
    assert_eq!(error.code(), Some(Code::QPACK_ENCODER_STREAM_ERROR));
}

#[test]
fn cancellation_recovers_exact_blocked_byte_budget() {
    let mut decoder = Decoder::new(DecoderConfig {
        max_blocked_bytes: 3 + size_of::<BlockedSection>(),
        ..DecoderConfig::default()
    });
    let bytes = section(1, 0, &FieldLine::IndexedPostBase { index: 0 });
    decoder.decode_field_section(4, bytes.clone()).unwrap();
    decoder.cancel_stream(4).unwrap();
    assert_eq!(decoder.blocked_bytes, 0);
    assert_eq!(decoder.decode_field_section(8, bytes).unwrap(), None);
    assert_eq!(decoder.blocked_bytes, 3 + size_of::<BlockedSection>());
}

#[test]
fn observation_qpack_keeps_representation_before_resolution() {
    let lines = [
        FieldLine::Indexed {
            is_static: true,
            index: 17,
        },
        FieldLine::Indexed {
            is_static: false,
            index: 0,
        },
        FieldLine::IndexedPostBase { index: 0 },
        FieldLine::LiteralWithNameRef {
            is_static: true,
            name_index: 17,
            value: Bytes::from_static(b"GET"),
            value_huffman: true,
            never_index: true,
        },
        FieldLine::LiteralWithNameRef {
            is_static: false,
            name_index: 0,
            value: Bytes::from_static(b"c"),
            value_huffman: false,
            never_index: true,
        },
        FieldLine::LiteralWithPostBaseNameRef {
            name_index: 0,
            value: Bytes::from_static(b"d"),
            value_huffman: true,
            never_index: false,
        },
        FieldLine::LiteralWithLiteralName {
            name: Bytes::from_static(b"x"),
            value: Bytes::from_static(b"e"),
            name_huffman: true,
            value_huffman: true,
            never_index: true,
        },
    ];
    for line in lines {
        let mut decoder = Decoder::new(DecoderConfig::default());
        decoder.observe(ObservationLimits::default());
        decoder.feed_encoder_stream(&insertion()).unwrap();
        let base = if matches!(
            line,
            FieldLine::IndexedPostBase { .. } | FieldLine::LiteralWithPostBaseNameRef { .. }
        ) {
            0
        } else {
            1
        };
        let fields = decoder
            .decode_field_section(0, section(1, base, &line))
            .unwrap()
            .unwrap();
        assert_eq!(
            format!("{:?}", decoder.take_field_observation(0).unwrap()),
            format!("{:?}", [ObservedFieldRepresentation::from(&line)])
        );
        assert!(!fields[0].name.is_empty());
    }
}

#[test]
fn observation_pending_fields_are_bounded_and_release_on_take_or_cancel() {
    let mut decoder = Decoder::new(DecoderConfig::default());
    decoder.observe(ObservationLimits {
        pending_fields: 1,
        bytes: size_of::<ObservedFieldRepresentation>(),
        ..ObservationLimits::default()
    });
    let encoded = section(
        0,
        0,
        &FieldLine::Indexed {
            is_static: true,
            index: 17,
        },
    );
    for stream in [0, 4] {
        assert_eq!(
            decoder
                .decode_field_section(stream, encoded.clone())
                .unwrap()
                .unwrap()
                .len(),
            1
        );
    }
    assert!(decoder.take_field_observation(4).is_none());
    assert_eq!(decoder.take_field_observation(0).unwrap().len(), 1);
    decoder
        .decode_field_section(8, encoded.clone())
        .unwrap()
        .unwrap();
    decoder.cancel_stream(8).unwrap();
    assert!(decoder.take_field_observation(8).is_none());
    decoder.decode_field_section(12, encoded).unwrap().unwrap();
    assert_eq!(decoder.take_field_observation(12).unwrap().len(), 1);
    let observation = decoder.observation.as_ref().unwrap();
    assert_eq!(observation.field_bytes, 0);
    assert!(observation.fields.is_empty());
}

#[test]
fn observation_pending_field_bytes_are_shared_across_streams() {
    let mut decoder = Decoder::new(DecoderConfig::default());
    decoder.observe(ObservationLimits {
        pending_fields: 2,
        bytes: size_of::<ObservedFieldRepresentation>(),
        ..ObservationLimits::default()
    });
    let encoded = section(
        0,
        0,
        &FieldLine::Indexed {
            is_static: true,
            index: 17,
        },
    );
    for stream in [0, 4] {
        decoder
            .decode_field_section(stream, encoded.clone())
            .unwrap()
            .unwrap();
    }
    assert!(decoder.take_field_observation(4).unwrap().is_empty());
    assert_eq!(decoder.take_field_observation(0).unwrap().len(), 1);
    decoder.decode_field_section(8, encoded).unwrap().unwrap();
    assert_eq!(decoder.take_field_observation(8).unwrap().len(), 1);
}

#[test]
fn observation_disabled_keeps_the_ordinary_field_layout_and_no_capture_state() {
    assert_eq!(size_of::<FieldPair>(), size_of::<(Bytes, Bytes, bool)>());
    let mut decoder = Decoder::new(DecoderConfig::default());
    let encoded = section(
        0,
        0,
        &FieldLine::Indexed {
            is_static: true,
            index: 17,
        },
    );
    let fields = decoder.decode_field_section(0, encoded).unwrap().unwrap();
    assert_eq!(fields[0].value, b"GET"[..]);
    assert!(decoder.observation.is_none());
    assert!(decoder.take_field_observation(0).is_none());
}

#[test]
fn observation_qpack_byte_budget_bounds_instruction_and_field_metadata() {
    for bytes in [0, size_of::<ObservedFieldRepresentation>() - 1] {
        let mut decoder = Decoder::new(DecoderConfig::default());
        decoder.observe(ObservationLimits {
            bytes,
            ..ObservationLimits::default()
        });
        decoder.feed_encoder_stream(&insertion()).unwrap();
        let (instructions, complete) = decoder.instruction_observation().unwrap();
        assert!(instructions.len() <= bytes / size_of::<ObservedEncoderInstruction>());
        assert!(!complete);
        let fields = decoder
            .decode_field_section(
                0,
                section(
                    0,
                    0,
                    &FieldLine::Indexed {
                        is_static: true,
                        index: 17,
                    },
                ),
            )
            .unwrap()
            .unwrap();
        assert!(decoder.take_field_observation(0).unwrap().is_empty());
        assert_eq!(fields[0].value, b"GET"[..]);
    }
}

#[test]
fn observation_qpack_limits_and_output_retry_are_transactional() {
    let mut decoder = Decoder::new(DecoderConfig {
        max_decoder_stream_bytes: 1,
        ..DecoderConfig::default()
    });
    decoder.observe(ObservationLimits {
        events: 2,
        fields: 0,
        ..ObservationLimits::default()
    });
    decoder.feed_encoder_stream(&insertion()).unwrap();
    assert_eq!(decoder.instruction_observation().unwrap().0.len(), 2);
    assert!(decoder.instruction_observation().unwrap().1);
    // A full output queue must not record an instruction before the retry succeeds.
    assert_eq!(
        decoder.feed_encoder_stream(&[0]),
        Err(QpackError::OutputBlocked)
    );
    assert!(decoder.instruction_observation().unwrap().1);
    decoder.take_decoder_stream();
    decoder.feed_encoder_stream(&[0]).unwrap();
    assert_eq!(decoder.instruction_observation().unwrap().0.len(), 2);
    assert!(!decoder.instruction_observation().unwrap().1);
    decoder.take_decoder_stream();
    let fields = decoder
        .decode_field_section(
            0,
            section(
                0,
                0,
                &FieldLine::Indexed {
                    is_static: true,
                    index: 17,
                },
            ),
        )
        .unwrap()
        .unwrap();
    assert!(decoder.take_field_observation(0).unwrap().is_empty());
    assert_eq!(fields[0].value, b"GET"[..]);
}

#[test]
fn required_insert_count_policy_covers_all_dynamic_reference_forms() {
    let value = Bytes::from_static(b"value");
    for (base, line) in [
        (
            2,
            FieldLine::Indexed {
                is_static: false,
                index: 0,
            },
        ),
        (0, FieldLine::IndexedPostBase { index: 1 }),
        (
            2,
            FieldLine::LiteralWithNameRef {
                is_static: false,
                name_index: 0,
                value: value.clone(),
                value_huffman: false,
                never_index: false,
            },
        ),
        (
            0,
            FieldLine::LiteralWithPostBaseNameRef {
                name_index: 1,
                value,
                value_huffman: false,
                never_index: false,
            },
        ),
    ] {
        // Every form references absolute index 1: exactly two insertions
        // are required, regardless of whether the whole entry or its name
        // is referenced. Table contents alone must not authorize a lower RIC.
        for ric in [1, 2, 3] {
            let mut decoder = Decoder::new(DecoderConfig::default());
            for _ in 0..3 {
                decoder.feed_encoder_stream(&insertion()).unwrap();
            }
            decoder.take_decoder_stream();
            let decoded = decoder.decode_field_section(0, section(ric, base, &line));
            if ric == 1 {
                assert_matches!(decoded, Err(QpackError::DecompressionFailed(_)));
                assert!(decoder.take_decoder_stream().is_empty());
            } else {
                assert_eq!(decoded.unwrap().unwrap().len(), 1);
                assert!(!decoder.take_decoder_stream().is_empty());
            }
        }
    }
}

#[test]
fn required_insert_count_overstatement_obeys_blocking_and_release_limits() {
    for resume_one in [false, true] {
        let mut decoder = Decoder::new(DecoderConfig {
            max_blocked_streams: 1,
            ..DecoderConfig::default()
        });
        // This static entry needs no dynamic state, but its declared RIC
        // still consumes the same blocked-stream budget as any other section.
        let bytes = section(
            1,
            0,
            &FieldLine::Indexed {
                is_static: true,
                index: 0,
            },
        );
        assert!(
            decoder
                .decode_field_section(0, bytes.clone())
                .unwrap()
                .is_none()
        );
        decoder.decode_field_section(4, bytes).unwrap_err();
        assert_eq!(decoder.blocked_stream_count(), 1);
        decoder.feed_encoder_stream(&insertion()).unwrap();
        let (stream, result) = if resume_one {
            decoder.resume_next().unwrap()
        } else {
            let mut results = decoder.resume_blocked();
            assert_eq!(results.len(), 1);
            results.remove(0)
        };
        assert_eq!(stream, 0);
        assert_eq!(result.unwrap().len(), 1);
        assert_eq!(decoder.blocked_stream_count(), 0);
        assert_eq!(decoder.blocked_bytes, 0);
        assert!(decoder.resume_next().is_none());
    }
}

mod insertion_bindings;
