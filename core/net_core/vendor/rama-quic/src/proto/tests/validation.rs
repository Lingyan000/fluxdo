//! Proving a path carries a full-size datagram, after an undersized challenge proved only
//! that the peer is at the address (RFC 9000 §8.2.1, §8.2.3).
//!
//! The anti-amplification limit on an address a peer has just moved to is a fraction of a
//! datagram, so the challenge that validates it cannot be expanded to 1200 bytes. Answering
//! such a challenge says nothing about the path's MTU; these cases are about the second
//! validation that does, and about what happens when it never succeeds.
//!
//! A response validating the path its challenge went out on, whichever path it arrives on
//! (RFC 9000 §8.2.3), is covered through the real receive path by
//! `a_response_on_another_path_validates_the_preferred_address` in the parent module: it
//! feeds the peer's protected answer in with a different source address. Nothing here
//! duplicates it.

use std::net::{Ipv4Addr, SocketAddr};

use rama_utils::octets;

use super::{
    ConnectionHandle, Dir, subscribe,
    util::{CLIENT_PORTS, Pair},
};

use crate::proto::{Duration, MIN_INITIAL_SIZE, connection::ConnectionError};
use rama_quic_proto::TransportErrorCode;

/// Move the client to a fresh address and put its ping on the wire, without letting the
/// server answer yet. Answers the address it moved to.
fn move_the_client(pair: &mut Pair, client_ch: ConnectionHandle) -> SocketAddr {
    move_the_client_to(pair, client_ch, Ipv4Addr::new(127, 0, 0, 1))
}

/// The same, on a chosen address. A move that changes the IP too is a new path rather than a
/// rebinding, so its MTU discovery starts again and has a probe to make.
fn move_the_client_to(pair: &mut Pair, client_ch: ConnectionHandle, ip: Ipv4Addr) -> SocketAddr {
    pair.client.addr = SocketAddr::new(ip.into(), CLIENT_PORTS.lock().next().unwrap());
    pair.client_conn_mut(client_ch).ping();
    pair.drive_client();
    pair.client.addr
}

/// The datagrams the server addressed to `to` since `before`. The challenge it owes the
/// address the peer left goes out too, and that one is not bounded by the new path's limit.
fn server_datagrams(pair: &Pair, before: usize, to: SocketAddr) -> Vec<usize> {
    pair.server_sent
        .iter()
        .skip(before)
        .filter(|sent| sent.to == to)
        .map(|sent| sent.bytes)
        .collect()
}

/// Drive the server through one undersized validation, leaving the expanded one outstanding.
/// Answers the address the client moved to, the token of each validation, and the sizes the
/// server put on the wire for each.
fn through_the_undersized_validation(
    pair: &mut Pair,
    client_ch: ConnectionHandle,
    server_ch: ConnectionHandle,
) -> (SocketAddr, u64, Vec<usize>, u64, Vec<usize>) {
    let moved_to = move_the_client(pair, client_ch);
    let before = pair.server_sent.len();
    pair.drive_server();
    let first = pair
        .server_conn_mut(server_ch)
        .challenge_token()
        .expect("the server challenged the new address");
    let undersized = server_datagrams(pair, before, moved_to);

    pair.drive_client();
    let before = pair.server_sent.len();
    pair.drive_server();
    let second = pair
        .server_conn_mut(server_ch)
        .challenge_token()
        .expect("the minimum MTU is being proved");
    let expanded = server_datagrams(pair, before, moved_to);
    (moved_to, first, undersized, second, expanded)
}

#[test]
fn an_undersized_challenge_is_followed_by_an_expanded_one() {
    let _guard = subscribe();
    let mut pair = Pair::default();
    let (client_ch, server_ch) = pair.connect();
    pair.drive();

    let moved_to = move_the_client(&mut pair, client_ch);
    let before = pair.server_sent.len();
    pair.drive_server();
    let first = pair.server_conn_mut(server_ch).challenge_token();
    assert!(first.is_some(), "the server challenged the new address");
    assert!(
        !pair.server_conn_mut(server_ch).challenge_is_for_mtu(),
        "the first validation is of the address"
    );

    // Every datagram the server put on that address, and the one carrying the challenge among
    // them: the limit is what keeps it under 1200, so nothing here proves the MTU.
    let sizes = server_datagrams(&pair, before, moved_to);
    assert!(!sizes.is_empty(), "the server sent to the new address");
    assert!(
        sizes.iter().all(|&it| it < usize::from(MIN_INITIAL_SIZE)),
        "the amplification limit kept every datagram under {MIN_INITIAL_SIZE}: {sizes:?}"
    );
    assert!(!pair.server_conn_mut(server_ch).mtu_validated());

    // Answered: the address is settled, so the limit lifts and a token that has never been in
    // a small datagram goes out expanded.
    pair.drive_client();
    let before = pair.server_sent.len();
    let challenges_before = pair
        .server_conn_mut(server_ch)
        .stats()
        .frame_tx
        .path_challenge;
    pair.drive_server();
    let second = pair.server_conn_mut(server_ch).challenge_token();
    assert!(pair.server_conn_mut(server_ch).challenge_is_for_mtu());
    assert_ne!(
        second, first,
        "the second validation has a token of its own"
    );
    assert!(!pair.server_conn_mut(server_ch).mtu_validated());

    let sizes = server_datagrams(&pair, before, moved_to);
    assert!(!sizes.is_empty(), "the server sent again");
    assert!(
        pair.server_conn_mut(server_ch)
            .stats()
            .frame_tx
            .path_challenge
            > challenges_before,
        "a challenge went out in this pass"
    );
    // The challenge counter rose in this pass and every datagram to that address in it
    // reached the minimum size, which bounds the one that carried the token.
    assert!(
        sizes.iter().all(|&it| it >= usize::from(MIN_INITIAL_SIZE)),
        "and each was expanded to {MIN_INITIAL_SIZE} or more: {sizes:?}"
    );

    pair.drive();
    assert!(pair.server_conn_mut(server_ch).mtu_validated());
    assert_eq!(pair.server_conn_mut(server_ch).challenge_token(), None);
}

#[test]
fn an_expanded_challenge_settles_the_path_in_one_validation() {
    let _guard = subscribe();
    let mut pair = Pair::default();
    let (client_ch, server_ch) = pair.connect();
    pair.drive();

    // Enough arrives from the new address that the server's first challenge fits 1200 bytes.
    pair.client.addr = SocketAddr::new(
        Ipv4Addr::new(127, 0, 0, 1).into(),
        CLIENT_PORTS.lock().next().unwrap(),
    );
    let moved_to = pair.client.addr;
    let stream = pair.client_streams(client_ch).open(Dir::Uni).unwrap();
    pair.client_send(client_ch, stream)
        .write(&vec![0x5a; octets::kib(4)])
        .unwrap();
    pair.drive_client();

    let before = pair.server_sent.len();
    let challenges_before = pair
        .server_conn_mut(server_ch)
        .stats()
        .frame_tx
        .path_challenge;
    pair.drive_server();
    assert!(
        pair.server_conn_mut(server_ch)
            .stats()
            .frame_tx
            .path_challenge
            > challenges_before,
        "the move was challenged"
    );
    let sizes = server_datagrams(&pair, before, moved_to);
    assert!(!sizes.is_empty(), "the server answered the move");
    // The counter rose in this pass and every datagram to that address in it reached the
    // minimum size, which bounds the one that carried the token.
    assert!(
        sizes.iter().all(|&it| it >= usize::from(MIN_INITIAL_SIZE)),
        "and it went out expanded: {sizes:?}"
    );

    pair.drive();
    assert!(
        pair.server_conn_mut(server_ch).mtu_validated(),
        "one expanded challenge proved both"
    );
    assert_eq!(
        pair.server_conn_mut(server_ch).mtu_validations(),
        0,
        "no second validation was needed"
    );
}

#[test]
fn a_duplicate_undersized_response_neither_settles_nor_defers_the_expanded_attempt() {
    let _guard = subscribe();
    let mut pair = Pair::default();
    let (client_ch, server_ch) = pair.connect();
    pair.drive();
    let (_, undersized, _, expanded, _) =
        through_the_undersized_validation(&mut pair, client_ch, server_ch);
    assert_ne!(undersized, expanded);

    let deadline = pair.server_conn_mut(server_ch).path_validation_deadline();
    assert!(deadline.is_some(), "the expanded attempt is on a deadline");
    pair.time += Duration::from_millis(25);

    // A delayed copy of the response to the token that went out small.
    let now = pair.time;
    assert!(
        !pair
            .server_conn_mut(server_ch)
            .replay_path_response(now, undersized),
        "it answers nothing that is outstanding"
    );
    assert!(!pair.server_conn_mut(server_ch).mtu_validated());
    assert_eq!(
        pair.server_conn_mut(server_ch).challenge_token(),
        Some(expanded),
        "the expanded validation is untouched"
    );
    assert_eq!(
        pair.server_conn_mut(server_ch).path_validation_deadline(),
        deadline,
        "and its deadline did not move"
    );
}

#[test]
fn ordinary_traffic_crosses_while_the_minimum_mtu_is_unproven() {
    let _guard = subscribe();
    let mut pair = Pair::default();
    let (client_ch, server_ch) = pair.connect();
    pair.drive();
    // A move that changes the IP is a new path, so its MTU discovery has something to do.
    move_the_client_to(&mut pair, client_ch, Ipv4Addr::new(127, 0, 0, 2));
    pair.drive_server();
    pair.drive_client();
    pair.drive_server();
    assert!(
        pair.server_conn_mut(server_ch).challenge_is_for_mtu(),
        "the expanded validation is what remains"
    );
    let probes_before = pair
        .server_conn_mut(server_ch)
        .stats()
        .path
        .sent_plpmtud_probes;

    // Ordinary traffic crosses while the expanded response is withheld: the address works,
    // and that is not licence to probe for a larger MTU. The client answers the challenge as
    // usual, and that answer is taken off the wire before it reaches the server.
    let payload = vec![0x22; octets::kib(8)];
    let stream = pair.server_streams(server_ch).open(Dir::Uni).unwrap();
    pair.server_send(server_ch, stream).write(&payload).unwrap();
    let mut arrived = Vec::new();
    for _ in 0..16 {
        pair.time += Duration::from_millis(10);
        pair.drive_server();
        pair.drive_client();
        // Nothing the client sends in this window reaches the server, so its answer to the
        // challenge cannot; the data being checked is what the server already put on the wire.
        pair.server.inbound.clear();
        let mut recv = pair.client_recv(client_ch, stream);
        if let Ok(mut chunks) = recv.read(true) {
            while let Ok(Some(chunk)) = chunks.next(usize::MAX) {
                arrived.extend_from_slice(&chunk.bytes);
            }
            let _transmit = chunks.finalize();
        }
        if arrived.len() >= payload.len() {
            break;
        }
    }
    assert_eq!(
        arrived, payload,
        "the ordinary data crossed while it was withheld"
    );
    assert!(
        !pair.server_conn_mut(server_ch).mtu_validated(),
        "and the expanded response never arrived"
    );
    // No probe went out here either, which is a weaker observation than it looks: a probe is
    // written only when a pass produced nothing else, and while this validation is
    // outstanding the connection is either carrying the challenge or running out of attempts.
    // This does not pin the `mtu_validated` gate.
    assert_eq!(
        pair.server_conn_mut(server_ch)
            .stats()
            .path
            .sent_plpmtud_probes,
        probes_before,
        "nothing probed for a larger MTU while the path was still being proved"
    );

    // It arrives, and discovery is released.
    pair.drive();
    assert!(pair.server_conn_mut(server_ch).mtu_validated());
    assert!(
        pair.server_conn_mut(server_ch)
            .stats()
            .path
            .sent_plpmtud_probes
            > probes_before,
        "discovery runs once the path has shown it carries 1200 bytes"
    );
}

#[test]
fn a_lost_expanded_challenge_is_retried_and_can_still_succeed() {
    let _guard = subscribe();
    let mut pair = Pair::default();
    let (client_ch, server_ch) = pair.connect();
    pair.drive();
    let (_, _, _, first_expanded, _) =
        through_the_undersized_validation(&mut pair, client_ch, server_ch);

    // The first expanded challenge is dropped where it is actually queued — the last
    // `drive_server` already moved it into the client's inbound — so the deadline runs out.
    assert!(
        !pair.client.inbound.is_empty(),
        "the expanded challenge is waiting for the client"
    );
    pair.client.inbound.clear();
    pair.time += Duration::from_millis(400);
    pair.server.drive(pair.time, pair.client.addr);
    let retried = pair.server_conn_mut(server_ch).challenge_token();
    assert!(
        retried.is_some_and(|it| it != first_expanded),
        "a lost challenge costs a retry with a token of its own, not the path"
    );
    assert!(pair.server_conn_mut(server_ch).challenge_is_for_mtu());

    // The retry is answered, and the path settles.
    pair.drive();
    assert!(
        pair.server_conn_mut(server_ch).mtu_validated(),
        "the retry succeeded"
    );
    assert!(!pair.server_conn_mut(server_ch).is_closed());
}

#[test]
fn a_third_move_keeps_the_fallback_that_is_proven() {
    let _guard = subscribe();
    let mut pair = Pair::default();
    let (client_ch, server_ch) = pair.connect();
    pair.drive();
    let proven = pair.server_conn_mut(server_ch).remote_address();

    // The peer moves and the server settles that address but not its MTU.
    through_the_undersized_validation(&mut pair, client_ch, server_ch);
    assert!(!pair.server_conn_mut(server_ch).mtu_validated());
    assert_eq!(
        pair.server_conn_mut(server_ch).previous_path_remote(),
        Some(proven),
        "the proven path is the fallback"
    );

    // The expanded challenge never reaches the client, so that path keeps only its address
    // proof, and the peer moves again. An address-only path is not a fallback, so it must
    // not displace the one that is proven.
    pair.client.inbound.clear();
    move_the_client(&mut pair, client_ch);
    pair.drive_server();
    assert!(!pair.server_conn_mut(server_ch).mtu_validated());
    assert_eq!(
        pair.server_conn_mut(server_ch).previous_path_remote(),
        Some(proven),
        "the address-only path did not displace the proven fallback"
    );
    assert!(!pair.server_conn_mut(server_ch).is_closed());
}

#[test]
fn a_fallback_keeps_its_identifier_and_carries_traffic() {
    let _guard = subscribe();
    let mut pair = Pair::default();
    let (client_ch, server_ch) = pair.connect();
    pair.drive();
    let proven = pair.server_conn_mut(server_ch).remote_address();
    through_the_undersized_validation(&mut pair, client_ch, server_ch);

    // Nothing answers the expanded challenge, so the attempts run out and the path goes.
    for _ in 0..64 {
        if !pair.server_conn_mut(server_ch).challenge_is_for_mtu() {
            break;
        }
        pair.time += Duration::from_millis(200);
        pair.server.drive(pair.time, pair.client.addr);
        pair.server.outbound.clear();
    }
    assert_eq!(
        pair.server_conn_mut(server_ch).remote_address(),
        proven,
        "the connection returned to the path it had proven"
    );
    assert!(!pair.server_conn_mut(server_ch).is_closed());

    // And that path still works: the client is put back on it and data crosses.
    pair.client.addr = proven;
    let stream = pair.server_streams(server_ch).open(Dir::Uni).unwrap();
    pair.server_send(server_ch, stream)
        .write(b"back on the proven path")
        .unwrap();
    pair.drive();
    let mut recv = pair.client_recv(client_ch, stream);
    let mut chunks = recv.read(true).expect("the stream is readable");
    let chunk = chunks
        .next(usize::MAX)
        .expect("a chunk")
        .expect("the data arrived");
    let _transmit = chunks.finalize();
    assert_eq!(&chunk.bytes[..], b"back on the proven path");
}

#[test]
fn a_path_given_up_with_no_fallback_ends_the_connection_with_no_viable_path() {
    let _guard = subscribe();
    let mut pair = Pair::default();
    let (client_ch, server_ch) = pair.connect();
    pair.drive();
    through_the_undersized_validation(&mut pair, client_ch, server_ch);

    // Abandon the fallback the way a completed validation does, identifier and all, so the
    // path being proved is the only one left.
    pair.server_conn_mut(server_ch).abandon_the_fallback();
    assert_eq!(
        pair.server_conn_mut(server_ch).previous_path_remote(),
        None,
        "nothing is kept behind this path"
    );

    // Nothing answers the expanded validation.
    pair.client.inbound.clear();
    for _ in 0..96 {
        if pair.server_conn_mut(server_ch).is_closed() {
            break;
        }
        pair.time += Duration::from_millis(200);
        pair.server.drive(pair.time, pair.client.addr);
        pair.server.outbound.clear();
    }

    // RFC 9000 §8.2.4 names this outcome, and §14.2 is why: the path exists but has not
    // shown it carries 1200 bytes, and no other path remains.
    match pair.server_conn_mut(server_ch).ended_because() {
        Some(ConnectionError::TransportError(error)) => assert_eq!(
            error.code,
            TransportErrorCode::NO_VIABLE_PATH,
            "it ended on the error §8.2.4 names, not on some other failure"
        ),
        other => panic!("expected a NO_VIABLE_PATH transport error, got {other:?}"),
    }

    // Nothing ordinary goes out afterwards: §14.2 forbids using a path that has not shown it
    // carries 1200 bytes, and there is no other.
    pair.time += Duration::from_millis(200);
    pair.server.drive(pair.time, pair.client.addr);
    assert!(
        pair.server.outbound.is_empty(),
        "a connection with nowhere to send stops sending"
    );
}

/// Rama waits for minimum-MTU validation before starting its discovery search: a probe is
/// larger than the path is known to carry, and what may go towards an unvalidated address is
/// bounded in bytes (RFC 9000 §8).
///
/// Both arms reach one state — a peer that has just moved, so the new path has a fresh
/// search with work to do — and differ only in `mtu_validated`. The unvalidated arm is what
/// a move reaches, which the test asserts before setting anything. The validated arm is set
/// through a private test helper, since the natural route to it would also exchange the
/// packets that prove the path.
#[test]
fn a_path_that_has_not_proven_its_minimum_mtu_gets_no_discovery_probe() {
    let _guard = subscribe();
    let after_the_move = |proven: bool| {
        let mut pair = Pair::default();
        // Below what the link carries, so the search after the move has somewhere to go.
        pair.mtu = 1300;
        let (client_ch, server_ch) = pair.connect();
        pair.drive();
        pair.mtu = 1500;
        let carried = pair.server_conn_mut(server_ch).path_mtu();

        let moved_to = SocketAddr::new(
            Ipv4Addr::new(127, 0, 0, 1).into(),
            CLIENT_PORTS.lock().next().unwrap(),
        );
        pair.client.addr = moved_to;
        pair.client_conn_mut(client_ch).ping();
        pair.drive_client();
        // Counted from before the server sees the move, so a probe emitted while the new
        // path is unproven is counted too.
        let probes_before = pair
            .server_conn_mut(server_ch)
            .stats()
            .path
            .sent_plpmtud_probes;
        let sent_before = pair.server_sent.len();

        pair.drive_server();
        assert!(
            !pair.server_conn_mut(server_ch).mtu_validated(),
            "new path reports minimum-MTU validation before any is proven"
        );
        pair.server_conn_mut(server_ch).set_mtu_validated(proven);
        // Past the pacing delay, so pacing is not the limit under test.
        pair.time += Duration::from_millis(50);
        pair.drive_server();

        let probes = pair
            .server_conn_mut(server_ch)
            .stats()
            .path
            .sent_plpmtud_probes
            - probes_before;
        // A probe is the only datagram here larger than the path's known MTU.
        let full_size: Vec<usize> = pair
            .server_sent
            .iter()
            .skip(sent_before)
            .filter(|sent| sent.to == moved_to && sent.bytes > usize::from(carried))
            .map(|sent| sent.bytes)
            .collect();
        (probes, full_size, carried)
    };

    let (probes, full_size, carried) = after_the_move(true);
    assert_eq!(
        full_size.len(),
        1,
        "no PMTU probe emitted after minimum-MTU validation (path carries {carried}): \
         {full_size:?}"
    );
    assert_eq!(probes, 1, "unexpected PMTU probe count after validation");

    let (probes, full_size, carried) = after_the_move(false);
    assert!(
        full_size.is_empty(),
        "PMTU probe emitted before minimum-MTU validation (path carries {carried}): \
         {full_size:?}"
    );
    assert_eq!(
        probes, 0,
        "unexpected PMTU probe count before minimum-MTU validation"
    );
}
