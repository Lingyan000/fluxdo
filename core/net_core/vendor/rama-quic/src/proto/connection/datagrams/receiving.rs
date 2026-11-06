//! What the receive side does with a DATAGRAM frame that arrives.
//!
//! The advertised `max_datagram_frame_size` bounds the encoded frame (RFC 9221 §3); what
//! holding one costs here is a separate matter. Frames are built and parsed rather than
//! described, so a case exercises the size that was really on the wire.

use super::*;
use rama_quic_proto::{
    TransportErrorCode,
    frame::{Frame, Iter},
    profile::{QuicProfile, TransportLimits, TransportParameterProfile},
};

/// How a built frame carries its payload length.
#[derive(Clone, Copy)]
enum Length {
    /// No LEN: the frame runs to the end of the packet (type 0x30).
    Absent,
    /// A LEN varint of this many bytes. QUIC allows 1, 2, 4 or 8, and a wider one than the
    /// value needs is legal (RFC 9000 §16).
    Of(usize),
}

/// Build a DATAGRAM frame and read it back through the parser, so its measured size is the
/// one the decoder saw.
fn parse(payload: usize, length: Length) -> ArrivedDatagram {
    let mut buf = Vec::new();
    match length {
        Length::Absent => buf.push(0x30),
        Length::Of(width) => {
            buf.push(0x31);
            buf.extend_from_slice(&varint(payload as u64, width));
        }
    }
    buf.extend(std::iter::repeat_n(0xd1, payload));

    let frames: Vec<_> = Iter::new(Bytes::from(buf))
        .expect("the packet holds frames")
        .collect::<Result<Vec<_>, _>>()
        .expect("the frame parses");
    match frames.into_iter().next().expect("one frame") {
        Frame::Datagram(arrived) => arrived,
        other => panic!("a datagram was built, not {other:?}"),
    }
}

/// `value` as a QUIC varint in `width` bytes, which may be wider than it needs.
fn varint(value: u64, width: usize) -> Vec<u8> {
    let prefix = match width {
        1 => 0b00,
        2 => 0b01,
        4 => 0b10,
        8 => 0b11,
        other => panic!("{other} is not a varint width"),
    };
    let mut bytes = value.to_be_bytes()[8 - width..].to_vec();
    bytes[0] |= prefix << 6;
    bytes
}

/// The bytes a frame occupies, counted from its parts rather than from the parser: the type
/// byte, the length varint where there is one, and the payload. A case states its own
/// expectation this way so the measurement under test is never its own oracle.
fn expected(payload: usize, length: Length) -> usize {
    1 + match length {
        Length::Absent => 0,
        Length::Of(width) => width,
    } + payload
}

/// The width a minimal length varint uses for this payload.
fn narrowest(payload: usize) -> usize {
    match payload {
        0..64 => 1,
        64..16384 => 2,
        16384..1_073_741_824 => 4,
        _ => 8,
    }
}

/// Receive a datagram as the only frame of its packet, so holding it costs its own length and
/// a case measures the queue's budget rather than what a packet around it keeps allocated.
trait ReceivedAlone {
    fn received_alone(
        &mut self,
        arrived: ArrivedDatagram,
        window: Option<usize>,
    ) -> Result<bool, TransportError>;
}

impl ReceivedAlone for DatagramState {
    fn received_alone(
        &mut self,
        arrived: ArrivedDatagram,
        window: Option<usize>,
    ) -> Result<bool, TransportError> {
        let allocated = arrived.datagram.data.len();
        self.received(
            arrived,
            allocated,
            &TransportConfig::default().maybe_with_datagram_receive_buffer_size(window),
        )
    }
}

fn refused(state: &mut DatagramState, arrived: ArrivedDatagram, window: usize) -> TransportError {
    state
        .received_alone(arrived, Some(window))
        .expect_err("a frame over the advertised size is refused")
}

#[test]
fn a_frame_exactly_at_the_advertised_size_is_not_a_protocol_error() {
    // The budget bounds the frame and the storage alike, and an entry costs more than the
    // payload, so a frame of exactly the advertised size never fits. It is dropped, and
    // dropping is not the peer's error.
    let mut state = DatagramState::default();
    let payload = 200;
    let width = narrowest(payload);
    let advertised = expected(payload, Length::Of(width));
    let arrived = parse(payload, Length::Of(width));
    assert_eq!(
        arrived.encoded, advertised,
        "the parser measured what the frame was built from"
    );
    let taken = state
        .received_alone(arrived, Some(advertised))
        .expect("a frame of exactly the advertised size is not a protocol error");
    assert!(!taken, "there was no room for it");
}

#[test]
fn a_frame_is_delivered_when_there_is_room_for_it() {
    let mut state = DatagramState::default();
    let payload = 200;
    let taken = state
        .received_alone(parse(payload, Length::Of(2)), Some(4096))
        .expect("a frame inside the advertised size is not a protocol error");
    assert!(taken, "the reader is woken");
    assert_eq!(state.incoming.queue.len(), 1, "and it is queued");
    assert_eq!(
        state.incoming.queue[0].datagram.data.len(),
        payload,
        "with the payload that arrived"
    );
}

#[test]
fn a_frame_one_byte_over_the_advertised_size_is_a_protocol_violation() {
    let mut state = DatagramState::default();
    let payload = 200;
    let width = narrowest(payload);
    let advertised = expected(payload, Length::Of(width)) - 1;
    let error = refused(&mut state, parse(payload, Length::Of(width)), advertised);
    assert_eq!(error.code, TransportErrorCode::PROTOCOL_VIOLATION);
}

#[test]
fn a_wider_length_is_measured_at_the_width_it_was_written_in() {
    let payload = 200;
    for width in [2, 4, 8] {
        assert_eq!(
            parse(payload, Length::Of(width)).encoded,
            expected(payload, Length::Of(width)),
            "a length varint of {width} bytes counts for {width} bytes"
        );
    }
}

#[test]
fn a_wider_length_that_crosses_the_size_is_a_protocol_violation() {
    // The same payload is inside the advertised size written minimally and over it written
    // in a legal wider varint. Nothing here reads the measurement first, so a size taken
    // from the canonical encoding rather than the wire reaches the check and is refused
    // here, not at an earlier assertion.
    let payload = 200;
    let advertised = expected(payload, Length::Of(narrowest(payload))) + 1;

    let mut state = DatagramState::default();
    state
        .received_alone(
            parse(payload, Length::Of(narrowest(payload))),
            Some(advertised),
        )
        .expect("the minimal encoding fits");

    let mut state = DatagramState::default();
    let error = refused(&mut state, parse(payload, Length::Of(8)), advertised);
    assert_eq!(error.code, TransportErrorCode::PROTOCOL_VIOLATION);
}

#[test]
fn a_frame_without_a_length_is_measured_by_what_it_occupied() {
    let payload = 200;
    let arrived = parse(payload, Length::Absent);
    assert_eq!(
        arrived.encoded,
        expected(payload, Length::Absent),
        "a type byte and the payload, with no length between them"
    );
    let mut state = DatagramState::default();
    let error = refused(
        &mut state,
        parse(payload, Length::Absent),
        arrived.encoded - 1,
    );
    assert_eq!(error.code, TransportErrorCode::PROTOCOL_VIOLATION);
}

#[test]
fn a_frame_the_peer_may_send_is_not_a_protocol_error_for_want_of_room() {
    // Inside the advertised size on the wire, too large to hold once entry storage counts.
    let mut state = DatagramState::default();
    let payload = 250;
    let taken = state
        .received_alone(parse(payload, Length::Of(2)), Some(256))
        .expect("a frame that will not fit is dropped, not fatal");
    assert!(!taken, "nothing was queued, so no reader is woken");
    assert!(state.incoming.queue.is_empty(), "and the queue stays empty");
}

#[test]
fn a_frame_too_large_for_an_empty_queue_leaves_what_is_queued() {
    let mut state = DatagramState::default();
    state
        .received_alone(parse(16, Length::Of(1)), Some(256))
        .expect("a small datagram is queued");
    state
        .received_alone(parse(250, Length::Of(2)), Some(256))
        .expect("one that cannot fit is dropped, not fatal");
    assert_eq!(
        state.incoming.queue.len(),
        1,
        "the readable datagram was kept"
    );
    assert_eq!(
        state.incoming.queue[0].datagram.data.len(),
        16,
        "and it is the one that arrived first"
    );
}

#[test]
fn a_zero_length_datagram_is_taken_and_is_not_disabled_support() {
    let mut state = DatagramState::default();
    state
        .received_alone(parse(0, Length::Of(1)), Some(256))
        .expect("an empty datagram is valid");
    assert_eq!(state.incoming.queue.len(), 1, "and it is queued");
    let error = state
        .received_alone(parse(0, Length::Of(1)), None)
        .expect_err("while no budget at all means the extension was never offered");
    assert_eq!(error.code, TransportErrorCode::PROTOCOL_VIOLATION);
}

#[test]
fn a_queued_datagram_is_charged_what_it_keeps_allocated() {
    const WIRE_LEN: usize = 1200;
    let overhead = size_of::<Datagram>();
    for (payload, charge) in [
        (1, 1),
        (64, 64),
        (599, 599),
        (600, WIRE_LEN),
        (1100, WIRE_LEN),
    ] {
        let mut state = DatagramState::default();
        state
            .received(
                parse(payload, Length::Of(2)),
                WIRE_LEN,
                &TransportConfig::default().with_datagram_receive_buffer_size(65_536),
            )
            .expect("the datagram is taken");
        assert_eq!(
            state.incoming.memory_used(),
            charge + overhead,
            "{payload}-byte datagram in a {WIRE_LEN}-byte packet"
        );
        state.recv().expect("it is readable");
        assert_eq!(
            state.incoming.memory_used(),
            0,
            "and reading releases its charge"
        );
    }
    // A window holds what the queue keeps allocated, not only the payload bytes: a 700-byte
    // datagram that shares its packet costs that packet.
    let mut state = DatagramState::default();
    for _ in 0..3 {
        state
            .received(
                parse(700, Length::Of(2)),
                WIRE_LEN,
                &TransportConfig::default().with_datagram_receive_buffer_size(3 * WIRE_LEN),
            )
            .expect("the datagram is taken");
    }
    assert_eq!(
        state.incoming.queue.len(),
        2,
        "the oldest gave way to the third"
    );
}

fn profile_config(window: Option<usize>, advertised: Option<u64>) -> TransportConfig {
    let profile = QuicProfile::standard()
        .with_transport_parameters(
            TransportParameterProfile::standard()
                .try_with_max_datagram_frame_size(advertised)
                .unwrap(),
        )
        .try_with_limits(TransportLimits {
            datagram_receive_buffer_size: window,
            ..TransportLimits::standard()
        })
        .unwrap();
    TransportConfig::from_quic_profile(&profile).unwrap()
}

#[test]
fn profile_datagram_frame_limit_is_independent_of_retention() {
    // A narrower profile rejects even an empty payload whose wide LEN encoding
    // crosses the advertised limit. Payload size alone cannot enforce this.
    let config = profile_config(Some(4096), Some(8));
    let mut state = DatagramState::default();
    let error = state
        .received(parse(0, Length::Of(8)), 9, &config)
        .unwrap_err();
    assert_eq!(error.code, TransportErrorCode::PROTOCOL_VIOLATION);
    assert!(state.recv().is_none());
    assert!(state.received(parse(6, Length::Of(1)), 8, &config).unwrap());
    assert_eq!(state.recv().unwrap().len(), 6);

    // A larger wire limit permits frames that cannot be retained. Dropping them
    // is allowed; reporting a peer protocol violation is not.
    let config = profile_config(Some(8), Some(128));
    assert!(
        !state
            .received(parse(64, Length::Of(2)), 67, &config)
            .unwrap()
    );
    assert!(state.recv().is_none());
    let config = profile_config(Some(0), Some(128));
    assert!(
        !state
            .received(parse(0, Length::Absent), 1, &config)
            .unwrap()
    );
}

#[test]
fn disabled_profile_datagrams_match_the_advertised_capability() {
    for (window, advertised) in [(None, None), (Some(0), None), (Some(4096), Some(0))] {
        let config = profile_config(window, advertised);
        assert!(!config.datagram_receive_enabled());
        let mut state = DatagramState::default();
        let error = state
            .received(parse(0, Length::Absent), 1, &config)
            .unwrap_err();
        assert_eq!(error.code, TransportErrorCode::PROTOCOL_VIOLATION);
    }
    assert!(profile_config(Some(4096), Some(1)).datagram_receive_enabled());
}
