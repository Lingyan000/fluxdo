//! Real instruction/field-section decoding exercises association identity and bounds.

use super::*;

fn decode_literals(
    decoder: &mut Decoder,
    values: &[(&'static [u8], &'static [u8])],
) -> Vec<FieldPair> {
    let mut encoded = BytesMut::new();
    HeaderPrefix::new(0, 0)
        .encode(
            &mut encoded,
            DecoderConfig::default().max_table_capacity / 32,
        )
        .unwrap();
    for (name, value) in values {
        FieldLine::LiteralWithLiteralName {
            name: Bytes::from_static(name),
            value: Bytes::from_static(value),
            name_huffman: false,
            value_huffman: false,
            never_index: false,
        }
        .encode(&mut encoded);
    }
    decoder
        .decode_field_section(0, encoded.freeze())
        .unwrap()
        .unwrap()
}

fn insert(decoder: &mut Decoder, name: &'static [u8], value: &'static [u8]) {
    let mut bytes = BytesMut::new();
    EncoderInstruction::InsertWithLiteralName {
        name: Bytes::from_static(name),
        value: Bytes::from_static(value),
        name_huffman: false,
        value_huffman: true,
    }
    .encode(&mut bytes);
    decoder.feed_encoder_stream(&bytes).unwrap();
}

fn capacity(decoder: &mut Decoder, bytes: u64) {
    let mut encoded = BytesMut::new();
    EncoderInstruction::SetDynamicTableCapacity { capacity: bytes }.encode(&mut encoded);
    decoder.feed_encoder_stream(&encoded).unwrap();
}

#[test]
fn initial_request_bindings_match_exact_octets_and_retain_only_positions() {
    let mut decoder = Decoder::new(DecoderConfig::default());
    decoder.observe(ObservationLimits::default());
    capacity(&mut decoder, 4096);
    // Same lengths are deliberately insufficient to identify these entries.
    insert(&mut decoder, b"name", b"one");
    insert(&mut decoder, b"else", b"two");
    insert(&mut decoder, b"name", b"two");
    insert(&mut decoder, b"lost", b"old");
    let fields = decode_literals(
        &mut decoder,
        &[(b"else", b"two"), (b"name", b"two"), (b"name", b"one")],
    );
    decoder.bind_initial_request(0, &fields);
    let bindings = decoder.encoder_bindings().unwrap();
    assert!(bindings.complete);
    assert_eq!(bindings.stream_id, 0);
    let facts: Vec<_> = bindings
        .insertions
        .iter()
        .map(|b| (b.instruction_index, b.insertion_index, b.field))
        .collect();
    assert_eq!(
        facts,
        [
            (1, 0, InsertionFieldMatch::Unique { field_index: 2 }),
            (2, 1, InsertionFieldMatch::Unique { field_index: 0 }),
            (3, 2, InsertionFieldMatch::Unique { field_index: 1 }),
            (4, 3, InsertionFieldMatch::Absent),
        ]
    );
    // A later request cannot replace the identity of the initial field section.
    decoder.bind_initial_request(4, &fields[..1]);
    assert_eq!(decoder.encoder_bindings().unwrap().stream_id, 0);
    assert_eq!(decoder.encoder_bindings().unwrap().insertions.len(), 4);
}

#[test]
fn duplicate_fields_and_evicted_entries_are_explicitly_unavailable_for_selection() {
    let mut decoder = Decoder::new(DecoderConfig::default());
    decoder.observe(ObservationLimits::default());
    capacity(&mut decoder, 40);
    insert(&mut decoder, b"a", b"old");
    insert(&mut decoder, b"b", b"new");
    let fields = decode_literals(&mut decoder, &[(b"b", b"new"), (b"b", b"new")]);
    decoder.bind_initial_request(0, &fields);
    let bindings = decoder.encoder_bindings().unwrap();
    assert!(bindings.complete);
    assert_eq!(bindings.insertions[0].field, InsertionFieldMatch::Evicted);
    assert_eq!(bindings.insertions[1].field, InsertionFieldMatch::Ambiguous);
}

#[test]
fn late_insertion_cannot_turn_initial_request_bindings_into_a_complete_later_prefix() {
    let mut decoder = Decoder::new(DecoderConfig::default());
    decoder.observe(ObservationLimits::default());
    capacity(&mut decoder, 4096);
    insert(&mut decoder, b"a", b"b");
    let fields = decode_literals(&mut decoder, &[(b"a", b"b")]);
    decoder.bind_initial_request(0, &fields);
    assert!(decoder.encoder_bindings().unwrap().complete);
    insert(&mut decoder, b"c", b"d");
    let bindings = decoder.encoder_bindings().unwrap();
    assert!(!bindings.complete);
    assert_eq!(bindings.insertions.len(), 1);
}

#[test]
fn binding_field_and_byte_limits_never_admit_a_partial_match_as_unique() {
    let one_binding = 2 * size_of::<ObservedEncoderInstruction>()
        + size_of::<ObservedEncoderBindings>()
        + size_of::<ObservedInsertionBinding>();
    for (bytes, fields_limit) in [(kib(64), 1), (one_binding - 1, 256), (0, 256)] {
        let mut decoder = Decoder::new(DecoderConfig::default());
        decoder.observe(ObservationLimits {
            bytes,
            fields: fields_limit,
            ..ObservationLimits::default()
        });
        capacity(&mut decoder, 4096);
        insert(&mut decoder, b"a", b"b");
        let fields = decode_literals(&mut decoder, &[(b"a", b"b"), (b"a", b"b")]);
        decoder.bind_initial_request(0, &fields);
        let bindings = decoder.encoder_bindings().unwrap();
        assert!(!bindings.complete);
        assert!(
            bindings
                .insertions
                .iter()
                .all(|b| b.field == InsertionFieldMatch::Unavailable)
        );
        let capture = decoder.observation.as_ref().unwrap();
        let charged = capture.instructions.len() * size_of::<ObservedEncoderInstruction>()
            + bindings.insertions.len() * size_of::<ObservedInsertionBinding>();
        assert!(charged <= bytes);
    }
}

#[test]
fn disabled_observation_keeps_no_bindings_or_extra_owned_fields() {
    let mut decoder = Decoder::new(DecoderConfig::default());
    capacity(&mut decoder, 4096);
    insert(&mut decoder, b"a", b"b");
    let fields = decode_literals(&mut decoder, &[(b"a", b"b")]);
    decoder.bind_initial_request(0, &fields);
    assert!(decoder.encoder_bindings().is_none());
    assert!(decoder.observation.is_none());
    assert_eq!(fields[0].name.as_ref(), b"a");
    assert_eq!(fields[0].value.as_ref(), b"b");
}

#[test]
fn insertion_identity_covers_static_names_duplicates_and_an_existing_table() {
    let mut decoder = Decoder::new(DecoderConfig::default());
    capacity(&mut decoder, 4096);
    insert(&mut decoder, b"before", b"capture");
    decoder.observe(ObservationLimits::default());
    let mut encoded = BytesMut::new();
    EncoderInstruction::InsertWithNameRef {
        is_static: true,
        name_index: 17,
        value: Bytes::from_static(b"POST"),
        value_huffman: false,
    }
    .encode(&mut encoded);
    EncoderInstruction::Duplicate { index: 0 }.encode(&mut encoded);
    decoder.feed_encoder_stream(&encoded).unwrap();
    insert(&mut decoder, b"x", b"new");
    let fields = decode_literals(&mut decoder, &[(b"x", b"new"), (b":method", b"POST")]);
    decoder.bind_initial_request(0, &fields);
    let bindings = decoder.encoder_bindings().unwrap();
    assert!(bindings.complete);
    let facts: Vec<_> = bindings
        .insertions
        .iter()
        .map(|b| (b.instruction_index, b.insertion_index, b.field))
        .collect();
    assert_eq!(
        facts,
        [
            (0, 1, InsertionFieldMatch::Unique { field_index: 1 }),
            (1, 2, InsertionFieldMatch::Unique { field_index: 1 }),
            (2, 3, InsertionFieldMatch::Unique { field_index: 0 }),
        ]
    );
}
