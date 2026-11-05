//! What a connection in the closing state answers, and how often, and what a server may send
//! towards an address it has not validated.
//!
//! RFC 9000 §10.2.1 asks an endpoint in that state to answer received packets progressively less
//! often. These tests drive each side by hand so the peer never learns of the close, and release
//! the peer's packets one at a time, so what earns an answer is exactly what the test says it is.
//! The anti-amplification cases share those hand-driven helpers, which is why they are here.

use std::{collections::VecDeque, mem, net::SocketAddr, sync::Arc};

use crate::proto::Duration;
use rama_quic_proto::packet::{FixedLengthConnectionIdParser, PartialDecode};

use rama_core::bytes::Bytes;
use rama_utils::octets;

use super::{
    ApplicationClose, ConnectionError, ConnectionHandle, Dir, Event, Ipv6Addr, TransportConfig,
    VarInt, big_cert_and_key, subscribe, util::*,
};

use crate::proto::{
    DEFAULT_SUPPORTED_VERSIONS, MIN_INITIAL_SIZE,
    shared::{ConnectionEvent, ConnectionEventInner, DatagramConnectionEvent},
};

/// Take everything waiting for the client, so the test decides when each datagram reaches it.
fn hold_for_the_client(pair: &mut Pair) -> VecDeque<Inbound> {
    mem::take(&mut pair.client.inbound)
}

/// Fill that queue with packets the peer sends while the client is not looking.
fn gather_from_the_peer(
    pair: &mut Pair,
    server_ch: ConnectionHandle,
    count: usize,
) -> VecDeque<Inbound> {
    for _ in 0..count {
        pair.server_conn_mut(server_ch).ping();
        pair.drive_server();
    }
    let held = hold_for_the_client(pair);
    assert_eq!(
        held.len(),
        count,
        "the peer put {count} datagrams on the wire"
    );
    held
}

/// Give the client one held datagram, from `from` when given, and drive it. Answers whether it
/// transmitted anything.
fn release_one(pair: &mut Pair, held: &mut VecDeque<Inbound>, from: Option<SocketAddr>) -> bool {
    let mut datagram = held.pop_front().expect("a datagram was held for this");
    datagram.at = pair.time;
    if let Some(from) = from {
        datagram.from = Some(from);
    }
    pair.client.inbound.push_back(datagram);
    let before = pair.client_sent.len();
    pair.drive_client();
    assert!(
        pair.client.inbound.is_empty(),
        "the datagram was taken, not left waiting"
    );
    pair.client_sent.len() > before
}

/// Read a QUIC variable-length integer, answering its value and its width.
fn varint(bytes: &[u8], at: usize) -> Option<(u64, usize)> {
    let first = *bytes.get(at)?;
    let width = 1usize << (first >> 6);
    let mut value = u64::from(first & 0x3f);
    for step in 1..width {
        value = (value << 8) | u64::from(*bytes.get(at + step)?);
    }
    Some((value, width))
}

/// How many packets a datagram carries, walking the long headers by the length each declares.
/// A short header runs to the end of the datagram, so it is the last one. Every step is bounds
/// checked and a declared length that runs past the datagram is a fault, so a malformed one
/// cannot be counted as another packet.
fn packets_in(datagram: &[u8]) -> usize {
    let mut at = 0usize;
    let mut packets = 0usize;
    while at < datagram.len() {
        packets += 1;
        let first = datagram[at];
        if first & 0x80 == 0 {
            break;
        }
        let kind = (first & 0x30) >> 4;
        // The long header: one byte of flags, four of version, then each identifier with its
        // own length byte.
        let mut cursor = at + 5;
        for _ in 0..2 {
            let len = usize::from(*datagram.get(cursor).expect("an identifier length"));
            cursor = cursor
                .checked_add(1 + len)
                .filter(|next| *next <= datagram.len())
                .expect("an identifier inside the datagram");
        }
        if kind == 0 {
            let (token, width) = varint(datagram, cursor).expect("a token length");
            cursor = cursor
                .checked_add(width)
                .and_then(|next| next.checked_add(usize::try_from(token).ok()?))
                .filter(|next| *next <= datagram.len())
                .expect("a token inside the datagram");
        }
        if kind == 3 {
            // Retry carries no length and nothing may follow it.
            break;
        }
        let (length, width) = varint(datagram, cursor).expect("a payload length");
        at = cursor
            .checked_add(width)
            .and_then(|next| next.checked_add(usize::try_from(length).ok()?))
            .filter(|next| *next <= datagram.len())
            .expect("a payload inside the datagram");
    }
    packets
}

/// An address no connection in these tests is on, in the family the harness uses.
fn elsewhere() -> SocketAddr {
    SocketAddr::new(Ipv6Addr::new(0x2001, 0xdb8, 0, 0, 0, 0, 0, 9).into(), 4433)
}

/// Close the client and let its first close go out, then hand back packets the peer had already
/// sent, ready to be released one at a time.
fn closed_with_input_waiting(
    pair: &mut Pair,
    client_ch: ConnectionHandle,
    server_ch: ConnectionHandle,
    count: usize,
) -> VecDeque<Inbound> {
    let held = gather_from_the_peer(pair, server_ch, count);
    pair.client.connections.get_mut(&client_ch).unwrap().close(
        pair.time,
        VarInt::from_u32(42),
        Bytes::from_static(b"done"),
    );
    pair.drive_client();
    held
}

/// The answers fall further and further apart: each one doubles what the next costs.
#[test]
fn a_closed_connection_answers_progressively_less_often() {
    let _guard = subscribe();
    let mut pair = Pair::default();
    let (client_ch, server_ch) = pair.connect();
    let mut held = closed_with_input_waiting(&mut pair, client_ch, server_ch, 40);

    let mut answered_at = Vec::new();
    for packet in 1..=40 {
        if release_one(&mut pair, &mut held, None) {
            answered_at.push(packet);
        }
    }
    assert_eq!(answered_at, vec![2, 6, 14, 30]);
}

/// Packets from an address the connection is not on never reach it: the endpoint discards a
/// datagram from an address it does not recognise. That is the outer half of the path rule.
#[test]
fn the_endpoint_discards_input_from_another_path() {
    let _guard = subscribe();
    let mut pair = Pair::default();
    let (client_ch, server_ch) = pair.connect();
    let mut held = closed_with_input_waiting(&mut pair, client_ch, server_ch, 4);

    for _ in 0..4 {
        assert!(
            !release_one(&mut pair, &mut held, Some(elsewhere())),
            "nothing from another path is answered"
        );
    }
}

/// The inner half. A client discards a packet from another address before anything else looks
/// at it, so the closing state's own path guard is only reachable on a connection that would
/// otherwise follow a peer's move: a server that allows migration. Closed, it must not answer
/// an address it has not validated, and the packet must not buy eligibility either.
#[test]
fn a_closing_server_does_not_answer_an_address_it_has_not_validated() {
    let _guard = subscribe();
    let mut pair = Pair::default();
    let (client_ch, server_ch) = pair.connect();

    // Packets the client sent, held so the server takes them when this test says so.
    for _ in 0..12 {
        pair.client_conn_mut(client_ch).ping();
        pair.drive_client();
    }
    let mut held = mem::take(&mut pair.server.inbound);
    assert_eq!(held.len(), 12, "the client put 12 datagrams on the wire");

    pair.server.connections.get_mut(&server_ch).unwrap().close(
        pair.time,
        VarInt::from_u32(42),
        Bytes::from_static(b"done"),
    );
    pair.drive_server();

    for _ in 0..8 {
        let datagram = held.pop_front().expect("a datagram was held for this");
        let before = pair.server_sent.len();
        hand_to_the_server(&mut pair, server_ch, datagram, elsewhere());
        pair.drive_server();
        assert_eq!(
            pair.server_sent.len(),
            before,
            "an address it has not validated is not answered"
        );
    }

    let mut answered_at = Vec::new();
    for packet in 1..=4 {
        let mut datagram = held.pop_front().expect("a datagram was held for this");
        datagram.at = pair.time;
        pair.server.inbound.push_back(datagram);
        let before = pair.server_sent.len();
        pair.drive_server();
        if pair.server_sent.len() > before {
            answered_at.push(packet);
        }
    }
    assert_eq!(
        answered_at,
        vec![2],
        "none of it counted towards the next answer"
    );
}

/// A close waiting to be sent stays waiting: the pass that takes the next packet in also sends
/// it, and the peer reports it.
#[test]
fn a_pending_close_is_sent_on_the_next_pass() {
    let _guard = subscribe();
    let mut pair = Pair::default();
    let (client_ch, server_ch) = pair.connect();
    let mut held = gather_from_the_peer(&mut pair, server_ch, 1);

    // Closed, and not yet driven, so the close is still waiting to be encoded.
    pair.client.connections.get_mut(&client_ch).unwrap().close(
        pair.time,
        VarInt::from_u32(42),
        Bytes::from_static(b"done"),
    );

    assert!(
        release_one(&mut pair, &mut held, None),
        "the close that was waiting was sent"
    );
    pair.drive_server();
    match pair.server_conn_mut(server_ch).poll() {
        Some(Event::ConnectionLost {
            reason: ConnectionError::ApplicationClosed(ApplicationClose { error_code, .. }),
        }) if error_code == VarInt::from_u32(42) => {}
        other => panic!("the peer received the close, not {other:?}"),
    }
}

/// Hand a datagram straight to the server's connection, claiming it came from `remote`.
///
/// The endpoint discards a datagram from an address it does not recognise before any connection
/// sees it, so the closing state's own path guard cannot be reached through the endpoint. This
/// reaches it directly, which is the only way to test that guard.
fn hand_to_the_server(
    pair: &mut Pair,
    server_ch: ConnectionHandle,
    datagram: Inbound,
    remote: SocketAddr,
) {
    let (first_decode, remaining) = PartialDecode::new(
        datagram.packet,
        // The harness's endpoints use the default identifier length and grease the fixed bit.
        &FixedLengthConnectionIdParser::new(8),
        DEFAULT_SUPPORTED_VERSIONS,
        true,
    )
    .expect("the peer's datagram decodes");
    let now = pair.time;
    pair.server_conn_mut(server_ch)
        .handle_event(ConnectionEvent(ConnectionEventInner::Datagram(
            DatagramConnectionEvent {
                now,
                remote,
                local: datagram.to,
                ecn: datagram.ecn,
                first_decode,
                remaining,
            },
        )));
}

/// The closing state is finite, and neither input nor further close calls move its deadline.
#[test]
fn the_close_deadline_is_fixed_and_expires() {
    let _guard = subscribe();
    let mut pair = Pair::default();
    let (client_ch, server_ch) = pair.connect();
    let mut held = closed_with_input_waiting(&mut pair, client_ch, server_ch, 8);

    let deadline = pair
        .client_conn_mut(client_ch)
        .poll_timeout()
        .expect("a closed connection has a deadline to drain on");

    // Time moves on between them, so a deadline reset to now plus three PTO on each input would
    // show up as a later deadline rather than the same one.
    for _ in 0..4 {
        pair.time += Duration::from_millis(1);
        let now = pair.time;
        pair.client_conn_mut(client_ch).handle_timeout(now);
        release_one(&mut pair, &mut held, None);
        pair.client.connections.get_mut(&client_ch).unwrap().close(
            now,
            VarInt::from_u32(7),
            Bytes::from_static(b"again"),
        );
        assert_eq!(
            pair.client_conn_mut(client_ch).poll_timeout(),
            Some(deadline),
            "neither input nor another close call moves the deadline"
        );
    }

    // A moment before it, the connection is still closing.
    pair.time = deadline
        .checked_sub(Duration::from_micros(1))
        .expect("the deadline is past the epoch");
    let now = pair.time;
    pair.client_conn_mut(client_ch).handle_timeout(now);
    assert!(
        !pair.client_conn_mut(client_ch).is_drained(),
        "it has not drained yet"
    );

    // At it, the connection drains and says nothing more.
    pair.time = deadline;
    pair.client_conn_mut(client_ch).handle_timeout(deadline);
    assert!(
        pair.client_conn_mut(client_ch).is_drained(),
        "the deadline ended the closing state"
    );
    let before = pair.client_sent.len();
    release_one(&mut pair, &mut held, None);
    assert_eq!(
        pair.client_sent.len(),
        before,
        "and nothing is sent after it"
    );
}

/// Once the peer has closed too, the connection drains and answers nothing more, however much of
/// the peer's earlier traffic is delivered afterwards.
#[test]
fn a_peer_close_ends_the_answers() {
    let _guard = subscribe();
    let mut pair = Pair::default();
    let (client_ch, server_ch) = pair.connect();
    let mut held = closed_with_input_waiting(&mut pair, client_ch, server_ch, 8);

    // The peer takes the close and answers with its own, which puts this side into draining.
    pair.drive_server();
    pair.drive_client();
    assert!(
        !pair.client_conn_mut(client_ch).is_drained(),
        "draining, not yet drained"
    );

    let before = pair.client_sent.len();
    for _ in 0..8 {
        release_one(&mut pair, &mut held, None);
    }
    assert_eq!(
        pair.client_sent.len(),
        before,
        "a draining connection answers nothing"
    );
}

/// The same, with the peer's close arriving while a local close is still waiting to be sent.
#[test]
fn a_peer_close_while_a_local_close_waits_ends_the_answers() {
    let _guard = subscribe();
    let mut pair = Pair::default();
    let (client_ch, server_ch) = pair.connect();
    let mut held = gather_from_the_peer(&mut pair, server_ch, 8);

    // The peer closes first, and its close is held back.
    pair.server.connections.get_mut(&server_ch).unwrap().close(
        pair.time,
        VarInt::from_u32(9),
        Bytes::from_static(b"peer"),
    );
    pair.drive_server();
    let mut peer_close = mem::take(&mut pair.client.inbound);
    assert_eq!(peer_close.len(), 1, "the peer's close is on the wire");

    // This side closes too, and does not get to send it before the peer's close arrives.
    pair.client.connections.get_mut(&client_ch).unwrap().close(
        pair.time,
        VarInt::from_u32(42),
        Bytes::from_static(b"done"),
    );
    release_one(&mut pair, &mut peer_close, None);

    let before = pair.client_sent.len();
    for _ in 0..8 {
        release_one(&mut pair, &mut held, None);
    }
    assert_eq!(
        pair.client_sent.len(),
        before,
        "nothing is answered once the peer has closed"
    );
}

/// A close the receive path decides on, rather than one the application asked for, is answered
/// on the very pass that decided it: no further input is needed, and the peer is told why.
#[test]
fn a_protocol_error_close_answers_on_the_pass_that_decided_it() {
    let _guard = subscribe();
    let mut pair = Pair::default();

    // A certificate from an issuer the client does not trust, distinct from the default root so
    // the failure is the anchor and not path building.
    let identity = crate::test_helpers::untrusted_identity();
    let client_ch = pair.begin_connect(client_config_with_certs(identity.cert_chain));

    pair.drive_client();
    let mut outcome = None;
    let mut answered_on_that_pass = false;
    for _ in 0..12 {
        pair.drive_server();
        let before = pair.client_sent.len();
        pair.drive_client();
        if let Some(event) = pair.client_conn_mut(client_ch).poll() {
            answered_on_that_pass = pair.client_sent.len() > before;
            outcome = Some(event);
            break;
        }
    }

    match outcome {
        Some(Event::ConnectionLost {
            reason: ConnectionError::TransportError(ref error),
        }) if error.code == crate::test_helpers::untrusted_certificate_error() => {}
        other => panic!("the client stopped on the certificate check, not {other:?}"),
    }
    assert!(
        answered_on_that_pass,
        "and answered on the pass that decided it, with no further input"
    );

    // The peer receives that close and reports the same reason.
    pair.drive_server();
    let server_ch = pair.server.assert_accept();
    let mut told = None;
    while let Some(event) = pair.server_conn_mut(server_ch).poll() {
        if let Event::ConnectionLost { reason } = event {
            told = Some(reason);
            break;
        }
    }
    match told {
        Some(ConnectionError::ConnectionClosed(ref close))
            if close.error_code == crate::test_helpers::untrusted_certificate_error() => {}
        other => panic!("the peer was told why, not {other:?}"),
    }
}

/// The keys' budget still governs. A closing connection whose 1-RTT keys have reached their
/// confidentiality limit encrypts nothing further with them: it dies on the limit instead.
#[test]
fn an_exhausted_key_budget_stops_the_answers() {
    let _guard = subscribe();
    let mut pair = Pair::default();
    let (client_ch, server_ch) = pair.connect();
    // Keep queued peer packets in this key phase: a peer update would install fresh
    // client keys and reset the packet budget this test is exhausting.
    pair.server_conn_mut(server_ch).set_key_phase_size(u64::MAX);
    let mut held = closed_with_input_waiting(&mut pair, client_ch, server_ch, 8);

    let limit = pair.client_conn_mut(client_ch).confidentiality_limit();
    pair.client_conn_mut(client_ch)
        .set_packets_sent_with_keys(limit);

    let gap = pair.client_conn_mut(client_ch).close_response_gap();
    for _ in 0..8 {
        release_one(&mut pair, &mut held, None);
    }
    assert_eq!(
        pair.client_conn_mut(client_ch).packets_sent_with_keys(),
        limit,
        "no further packet was encrypted with the spent keys"
    );
    assert_eq!(
        pair.client_conn_mut(client_ch).close_response_gap(),
        gap,
        "and no answer was counted for a pass that encoded none"
    );
    assert!(
        pair.client_conn_mut(client_ch).is_drained(),
        "the connection died on the limit rather than answering past it"
    );
}

/// A close made before the handshake is confirmed goes into every space that has keys, one
/// datagram each, and still counts as one answer: the gap doubles once, not once per space.
///
/// The spaces are not coalesced into a single datagram. A receiver that cannot read the first
/// packet of a datagram is asked by RFC 9000 §12.2 to try the ones behind it, and a receiver
/// that does not would never see the close that matters — the one in the space it still holds
/// keys for. Sending each on its own costs a datagram and does not depend on that behaviour.
#[test]
fn a_close_before_the_handshake_is_confirmed_reaches_every_space() {
    let _guard = subscribe();
    let mut pair = Pair::default();
    let client_ch = pair.begin_connect(client_config());

    // One flight each way, so the client holds keys for more than one space and has not been
    // confirmed.
    pair.drive_client();
    pair.drive_server();
    pair.drive_client();

    pair.client.connections.get_mut(&client_ch).unwrap().close(
        pair.time,
        VarInt::from_u32(42),
        Bytes::from_static(b"done"),
    );
    let spaces = pair.client_conn_mut(client_ch).spaces_with_close_keys();
    assert!(
        spaces > 1,
        "this close has more than one space to go into: {spaces}"
    );
    assert_eq!(
        pair.client_conn_mut(client_ch).close_response_gap(),
        1,
        "nothing has been answered yet"
    );

    let before = pair.server.inbound.len();
    pair.drive_client();
    let sent = &pair.server.inbound;
    assert_eq!(
        sent.len() - before,
        spaces,
        "one datagram for each space that had keys"
    );

    // What went out, as it sits on the wire: one packet per datagram, and the last of them a
    // short header, which is the space the peer will still be able to read.
    for datagram in sent.iter().skip(before) {
        assert_eq!(
            packets_in(&datagram.packet),
            1,
            "each datagram carries the close of one space and nothing else"
        );
    }
    let last = sent.back().expect("the close reached the peer's queue");
    assert!(
        last.packet[0] & 0x80 == 0,
        "the last of them is the 1-RTT close, in a short header"
    );

    assert_eq!(
        pair.client_conn_mut(client_ch).close_response_gap(),
        2,
        "one logical answer, however many datagrams carried it"
    );
}

/// The space a close is due in moves on only when a pass actually writes one, and a pass
/// that writes nothing changes nothing.
///
/// A pass blocked while the close is still pending is not reachable here: a close is exempt
/// from congestion control and pacing on purpose (see `poll_transmit`), and three close
/// datagrams do not exhaust the amplification limit this fixture leaves. So the second half
/// is shown where a pass writing nothing is reachable — once the close is complete — and the
/// pending half rests on the source, which advances neither the cursor nor the budget unless
/// a frame was encoded.
#[test]
fn the_close_cursor_follows_what_was_written() {
    let _guard = subscribe();
    let mut pair = Pair::default();
    let client_ch = pair.begin_connect(client_config());

    // One flight each way, so the client holds keys for more than one space.
    pair.drive_client();
    pair.drive_server();
    pair.drive_client();
    let spaces = pair.client_conn_mut(client_ch).spaces_with_close_keys();
    assert!(spaces > 1, "this close has {spaces} spaces to go into");

    pair.client.connections.get_mut(&client_ch).unwrap().close(
        pair.time,
        VarInt::from_u32(42),
        Bytes::from_static(b"done"),
    );

    // One pass, one space, and the cursor follows what went out.
    let mut buf = Vec::new();
    let mut written = 0;
    let mut due = pair.client_conn_mut(client_ch).close_due_from();
    for step in 0..spaces {
        buf.clear();
        let now = pair.time;
        let sent = pair
            .client_conn_mut(client_ch)
            .poll_transmit(now, 1, &mut buf);
        assert!(sent.is_some(), "the pass carried a datagram");
        written += 1;
        let moved = pair.client_conn_mut(client_ch).close_due_from();
        if step + 1 < spaces {
            assert!(
                moved > due,
                "the space due next moved on from {due} once a close was written"
            );
            assert_eq!(
                pair.client_conn_mut(client_ch).close_response_gap(),
                1,
                "and the close is still pending while a space is left"
            );
        }
        due = moved;
    }
    assert_eq!(written, spaces, "one datagram for each space that had keys");
    let gap = pair.client_conn_mut(client_ch).close_response_gap();
    assert_eq!(gap, 2, "one logical answer for the whole of it");

    // A pass with nothing to write changes nothing.
    let cursor = pair.client_conn_mut(client_ch).close_due_from();
    for _ in 0..3 {
        buf.clear();
        let now = pair.time;
        assert!(
            pair.client_conn_mut(client_ch)
                .poll_transmit(now, 1, &mut buf)
                .is_none(),
            "there is nothing left to send"
        );
        assert_eq!(
            pair.client_conn_mut(client_ch).close_due_from(),
            cursor,
            "the cursor stays where it was"
        );
        assert_eq!(
            pair.client_conn_mut(client_ch).close_response_gap(),
            gap,
            "and so does the budget"
        );
    }
}

/// A close in the Initial space rides in a datagram padded to the minimum a client may send
/// (RFC 9000 §14.1). The close is made before the client has any other space, so there is an
/// Initial close to look at rather than an assertion that passes because there is none.
#[test]
fn an_initial_close_is_padded() {
    let _guard = subscribe();
    let mut pair = Pair::default();
    let client_ch = pair.begin_connect(client_config());

    // Only the first flight has gone out, so Initial is the one space with keys.
    pair.drive_client();
    assert_eq!(
        pair.client_conn_mut(client_ch).spaces_with_close_keys(),
        1,
        "the client holds Initial keys and no others"
    );

    pair.client.connections.get_mut(&client_ch).unwrap().close(
        pair.time,
        VarInt::from_u32(42),
        Bytes::from_static(b"done"),
    );
    let before = pair.server.inbound.len();
    pair.drive_client();
    let sent: Vec<_> = pair.server.inbound.iter().skip(before).collect();
    assert_eq!(sent.len(), 1, "the close went out in one datagram");

    let datagram = sent[0];
    assert_eq!(
        datagram.packet[0] & 0xb0,
        0x80,
        "it carries an Initial packet"
    );
    assert!(
        datagram.packet.len() >= usize::from(MIN_INITIAL_SIZE),
        "and is padded to {MIN_INITIAL_SIZE}, not {}",
        datagram.packet.len()
    );
}

/// An endpoint that receives a close while more than one space still has keys answers with
/// one packet and nothing after it, which is what RFC 9000 §10.2.2 allows a draining endpoint.
#[test]
fn a_draining_endpoint_answers_with_one_packet() {
    let _guard = subscribe();
    let mut pair = Pair::default();
    let client_ch = pair.begin_connect(client_config());

    // One flight each way, so both sides hold keys for more than one space.
    pair.drive_client();
    pair.drive_server();
    pair.drive_client();
    let server_ch = pair.server.assert_accept();
    assert!(
        pair.server_conn_mut(server_ch).spaces_with_close_keys() > 1,
        "the answering side has more than one space with keys"
    );

    pair.client.connections.get_mut(&client_ch).unwrap().close(
        pair.time,
        VarInt::from_u32(42),
        Bytes::from_static(b"done"),
    );
    pair.drive_client();

    // The server takes the close, enters draining, and answers.
    let before = pair.client.inbound.len();
    pair.drive_server();
    let answered: usize = pair
        .client
        .inbound
        .iter()
        .skip(before)
        .map(|datagram| packets_in(&datagram.packet))
        .sum();
    assert!(
        answered <= 1,
        "a draining endpoint answers with at most one packet, not {answered}"
    );

    // And nothing after it, however much is driven.
    let after_the_answer = pair.client.inbound.len();
    for _ in 0..4 {
        pair.drive_server();
    }
    assert_eq!(
        pair.client.inbound.len(),
        after_the_answer,
        "a draining endpoint sends nothing further"
    );
}

/// A close a server has not sent yet stays pending when a packet arrives from an address it has
/// not validated. The server allows migration, so the packet is not discarded before the closing
/// state sees it.
#[test]
fn a_pending_server_close_survives_input_from_elsewhere() {
    let _guard = subscribe();
    let mut pair = Pair::default();
    let (client_ch, server_ch) = pair.connect();

    pair.client_conn_mut(client_ch).ping();
    pair.drive_client();
    let mut held = mem::take(&mut pair.server.inbound);
    assert_eq!(held.len(), 1, "the client put a datagram on the wire");

    // Closed, and not yet driven, so the close is still waiting to be encoded.
    pair.server.connections.get_mut(&server_ch).unwrap().close(
        pair.time,
        VarInt::from_u32(42),
        Bytes::from_static(b"done"),
    );

    let datagram = held.pop_front().expect("a datagram was held for this");
    let before = pair.server_sent.len();
    hand_to_the_server(&mut pair, server_ch, datagram, elsewhere());
    pair.drive_server();
    assert!(
        pair.server_sent.len() > before,
        "the close that was waiting was not cleared by input from elsewhere"
    );

    pair.drive_client();
    match pair.client_conn_mut(client_ch).poll() {
        Some(Event::ConnectionLost {
            reason: ConnectionError::ApplicationClosed(ApplicationClose { error_code, .. }),
        }) if error_code == VarInt::from_u32(42) => {}
        other => panic!("the peer received the close, not {other:?}"),
    }
}

/// Before an address is validated a server may send no more than three times what it has
/// received from it (RFC 9000 §8.1). This counts the actual bytes both ways, on a path the
/// peer has just moved to, where the credit is a fraction of a datagram.
#[test]
fn the_amplification_bound_holds_on_a_new_path() {
    let _guard = subscribe();
    let mut pair = Pair::default();
    let (client_ch, server_ch) = pair.connect();

    // One datagram from somewhere else: the server has that many bytes of credit towards
    // the new address, and nothing has validated it.
    let received = move_the_client_to(&mut pair, client_ch, server_ch);

    // Something worth sending, larger than the credit.
    pair.server.connections.get_mut(&server_ch).unwrap().close(
        pair.time,
        VarInt::from_u32(42),
        Bytes::from(vec![b'x'; 1000]),
    );
    let sent = drive_the_server_towards_elsewhere(&mut pair);
    assert!(
        sent <= received * 3,
        "the server sent {sent} bytes towards an address it has {} of credit for",
        received * 3
    );
}

/// The bound is cumulative: round after round, everything the server has sent towards an
/// address it has not validated stays within three times everything that address has sent it
/// (RFC 9000 §8.1).
///
/// Both totals are counted from the datagrams themselves, so neither side of the comparison
/// is the connection's own receive counter. The queued load exceeds every round's credit, and
/// the configured window and latency estimate keep congestion and pacing from being the limit,
/// so the credit is what each round measures.
#[test]
fn the_amplification_bound_holds_across_repeated_input_on_a_new_path() {
    /// More than the rounds below can carry, so the server is never out of work.
    const QUEUED: usize = octets::kib(64);

    let _guard = subscribe();
    // A window far larger than any round's credit, so what stops the server each round is the
    // bound rather than congestion control. The peer never acknowledges anything here, so a
    // default window would fill and become the limit instead.
    let mut transport = TransportConfig::default();
    transport
        .try_set_initial_congestion_window(u64::try_from(QUEUED).expect("a window that fits"))
        .expect("the window is accepted");
    // A low latency estimate, so pacing does not decide how much of a round goes out.
    transport.set_initial_rtt(Duration::from_millis(10));
    let mut server = server_config();
    server.set_transport_config(Arc::new(transport));
    let mut pair = Pair::new(
        Arc::new(crate::proto::EndpointConfig::try_with_rand_key().unwrap()),
        server,
    );
    let (client_ch, server_ch) = pair.connect();
    let mut received = move_the_client_to(&mut pair, client_ch, server_ch);

    // Opened after the move, so all of it is subject to the new address's credit, and long
    // enough that the server always has more queued than any round may carry.
    let stream = pair
        .server_streams(server_ch)
        .open(Dir::Uni)
        .expect("the server opens a stream");
    pair.server_send(server_ch, stream)
        .write(&[b'x'; QUEUED])
        .expect("the stream takes the payload");

    let mut sent = drive_the_server_towards_elsewhere(&mut pair);
    assert!(
        sent > 0,
        "no bytes sent towards the address the peer moved to"
    );
    for round in 1..=3 {
        // Past any pacing delay, so what the round measures is the credit and not the clock.
        pair.time += Duration::from_millis(10);
        received = feed_the_server_from_elsewhere(&mut pair, client_ch, server_ch, received, 400);
        let this_round = drive_the_server_towards_elsewhere(&mut pair);
        sent += this_round;
        assert!(
            this_round > 0,
            "round {round}: no bytes sent after the input that earned credit"
        );
        assert!(
            sent <= received * 3,
            "round {round}: sent {sent} bytes towards an address that has sent {received}, \
             allowing {}",
            received * 3
        );
    }
    // The queue outlasted every round, so the credit was the limit and not the work.
    assert!(
        sent < QUEUED,
        "queued load of {QUEUED} bytes did not outlast the rounds: {sent} sent"
    );
}

/// Move the client to [`elsewhere`] with one small packet, and answer how many bytes of it the
/// server received: three times that is all it may send back until the address is validated.
fn move_the_client_to(
    pair: &mut Pair,
    client_ch: ConnectionHandle,
    server_ch: ConnectionHandle,
) -> usize {
    pair.client_conn_mut(client_ch).ping();
    pair.drive_client();
    let mut held = mem::take(&mut pair.server.inbound);
    let datagram = held.pop_front().expect("the client put one on the wire");
    let received = datagram.packet.len();
    hand_to_the_server(pair, server_ch, datagram, elsewhere());
    received
}

/// Let the server transmit, and answer what it put on the wire towards [`elsewhere`].
fn drive_the_server_towards_elsewhere(pair: &mut Pair) -> usize {
    let before = pair.server_sent.len();
    pair.drive_server();
    pair.server_sent
        .iter()
        .skip(before)
        .filter(|sent| sent.to == elsewhere())
        .map(|sent| sent.bytes)
        .sum()
}

#[test]
fn a_close_within_the_credit_goes_out_on_a_new_path() {
    let _guard = subscribe();
    let mut pair = Pair::default();
    let (client_ch, server_ch) = pair.connect();
    let received = move_the_client_to(&mut pair, client_ch, server_ch);

    // A short reason: the whole close fits in what one small packet earned.
    pair.server.connections.get_mut(&server_ch).unwrap().close(
        pair.time,
        VarInt::from_u32(42),
        Bytes::from_static(b"done"),
    );
    let sent = drive_the_server_towards_elsewhere(&mut pair);
    assert!(sent > 0, "the close went out");
    assert!(
        sent <= received * 3,
        "and fits the {} bytes of credit: {sent}",
        received * 3
    );
    assert_eq!(
        pair.server_conn_mut(server_ch)
            .stats()
            .frame_tx
            .connection_close,
        1,
        "one close frame was written"
    );
}

#[test]
fn nothing_more_goes_out_once_the_credit_on_a_new_path_is_spent() {
    let _guard = subscribe();
    let mut pair = Pair::default();
    let (client_ch, server_ch) = pair.connect();
    let received = move_the_client_to(&mut pair, client_ch, server_ch);

    // Nobody answers at that address, so the server validates nothing and spends the credit
    // the one packet earned, then stops.
    let mut spent = 0;
    for _ in 0..10 {
        spent += drive_the_server_towards_elsewhere(&mut pair);
        pair.time += Duration::from_millis(10);
    }
    assert!(spent > 0, "the server answered the move");
    assert!(
        spent <= received * 3,
        "within the {} bytes of credit: {spent}",
        received * 3
    );

    // A close now has nothing left to go out in, and nothing about it moves while it waits.
    pair.server.connections.get_mut(&server_ch).unwrap().close(
        pair.time,
        VarInt::from_u32(42),
        Bytes::from_static(b"done"),
    );
    let cursor = pair.server_conn_mut(server_ch).close_due_from();
    let gap = pair.server_conn_mut(server_ch).close_response_gap();
    for _ in 0..3 {
        assert_eq!(
            drive_the_server_towards_elsewhere(&mut pair),
            0,
            "there is no credit left for it"
        );
        assert_eq!(
            pair.server_conn_mut(server_ch).close_due_from(),
            cursor,
            "the cursor stays where it was"
        );
        assert_eq!(
            pair.server_conn_mut(server_ch).close_response_gap(),
            gap,
            "and so does the response budget"
        );
        assert_eq!(
            pair.server_conn_mut(server_ch)
                .stats()
                .frame_tx
                .connection_close,
            0,
            "no close frame was written"
        );
        pair.time += Duration::from_millis(10);
    }

    // More from that same address, and the close it was holding goes out within the credit.
    let total = feed_the_server_from_elsewhere(&mut pair, client_ch, server_ch, received, 400);
    let sent = drive_the_server_towards_elsewhere(&mut pair);
    assert!(sent > 0, "the close went out once the credit covered it");
    assert!(
        spent + sent <= total * 3,
        "and everything sent fits the {} bytes that address has earned: {}",
        total * 3,
        spent + sent
    );
    assert_eq!(
        pair.server_conn_mut(server_ch)
            .stats()
            .frame_tx
            .connection_close,
        1,
        "one close frame was written"
    );
}

#[test]
fn a_handshake_flight_fits_the_credit_the_client_earned() {
    let _guard = subscribe();
    let mut server_transport = TransportConfig::default();
    // A low-latency estimate, so pacing does not decide how much of the flight goes out, and a
    // segment that is not a whole fraction of what the client earns, so the last datagram the
    // server would like to add is the one the bound has to refuse.
    server_transport.set_initial_rtt(Duration::from_millis(10));
    server_transport.set_initial_mtu(1400);
    let (cert, key) = big_cert_and_key();
    let mut server = server_config_with_cert(cert, key);
    server.set_transport_config(Arc::new(server_transport));
    let mut pair = Pair::new(
        Arc::new(crate::proto::EndpointConfig::try_with_rand_key().unwrap()),
        server,
    );

    pair.begin_connect(client_config());
    pair.drive_client();
    let received: usize = pair.server.inbound.iter().map(|it| it.packet.len()).sum();
    assert_ne!(
        received * 3 % 1400,
        0,
        "the credit is not a whole number of the server's segments: {received}"
    );
    let before = pair.server_sent.len();
    pair.drive_server();
    let sent: usize = pair
        .server_sent
        .iter()
        .skip(before)
        .map(|sent| sent.bytes)
        .sum();
    assert!(
        sent > usize::from(MIN_INITIAL_SIZE),
        "the flight is more than one datagram: {sent}"
    );
    assert!(
        sent <= received * 3,
        "and the whole of it fits the {} bytes the client earned: {sent}",
        received * 3
    );
}

/// Send an unreliable datagram from the client, hand it to the server as coming from
/// [`elsewhere`], and answer everything that address has sent so far.
///
/// `already` is what that address had sent before this call, measured on the wire by the
/// caller. Every byte in the credit these cases check is counted here from the datagrams
/// handed over, never read back from the connection's own receive counter, so a fault in
/// that counter cannot move the allowance with it.
fn feed_the_server_from_elsewhere(
    pair: &mut Pair,
    client_ch: ConnectionHandle,
    server_ch: ConnectionHandle,
    already: usize,
    want: usize,
) -> usize {
    let size = pair
        .client_datagrams(client_ch)
        .max_size()
        .expect("the peer takes unreliable datagrams")
        .min(want);
    pair.client_datagrams(client_ch)
        .send(Bytes::from(vec![0x42; size]), false)
        .expect("the datagram is queued");
    pair.drive_client();
    let mut held = mem::take(&mut pair.server.inbound);
    let mut received = already;
    while let Some(datagram) = held.pop_front() {
        received += datagram.packet.len();
        hand_to_the_server(pair, server_ch, datagram, elsewhere());
    }
    received
}

/// RFC 9000 §10.2: a connection may leave its closing period early, but only once the peer has
/// been told. Before the close went out there is nothing to abandon; after it, the connection
/// drains at once and tells the endpoint so, without waiting for the close timer.
#[test]
fn the_closing_period_can_be_abandoned_once_the_close_went_out() {
    let _guard = subscribe();
    let mut pair = Pair::default();
    let (client_ch, server_ch) = pair.connect();
    pair.drive();
    let now = pair.time;

    assert!(
        !pair.client_conn_mut(client_ch).close_announced(),
        "an open connection has announced nothing"
    );
    assert!(!pair.client_conn_mut(client_ch).abandon_close(now));

    pair.client_conn_mut(client_ch)
        .close(now, VarInt::from_u32(7), Bytes::from_static(b"leaving"));
    assert!(
        !pair.client_conn_mut(client_ch).close_announced(),
        "closed, but the close has not gone out yet"
    );
    assert!(
        !pair.client_conn_mut(client_ch).abandon_close(now),
        "so the period cannot be abandoned yet"
    );

    pair.drive_client();
    assert!(pair.client_conn_mut(client_ch).close_announced());
    assert!(pair.client_conn_mut(client_ch).abandon_close(now));
    assert!(pair.client_conn_mut(client_ch).is_drained());
    assert!(
        pair.client_conn_mut(client_ch)
            .poll_endpoint_events()
            .is_some_and(|event| event.is_drained()),
        "the endpoint is told the connection is gone"
    );
    assert!(
        !pair.client_conn_mut(client_ch).abandon_close(now),
        "only once"
    );

    // The close that went out still reaches the peer, which then drains; the clock does not
    // move, so its own period has not run out.
    pair.drive_server();
    let mut told = None;
    while let Some(event) = pair.server_conn_mut(server_ch).poll() {
        if let Event::ConnectionLost { reason } = event {
            told = Some(reason);
        }
    }
    match told {
        Some(ConnectionError::ApplicationClosed(close))
            if close.error_code == VarInt::from_u32(7) => {}
        other => panic!("the peer learns of the close: {other:?}"),
    }
    // A draining connection was told by its peer, so it may leave too.
    let now = pair.time;
    assert!(pair.server_conn_mut(server_ch).close_announced());
    assert!(pair.server_conn_mut(server_ch).abandon_close(now));
}
