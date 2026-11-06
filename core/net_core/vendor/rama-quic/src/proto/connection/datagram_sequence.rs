//! Exercise application datagrams through a client and a server whose packets an input-chosen
//! sequence drops, duplicates, reorders, truncates, corrupts, misroutes and injects.
//!
//! Every datagram a side receives must be one the other side's `send` accepted, byte for byte,
//! at most once; cumulative counters never fall; and once both sides close locally, each
//! connection drains on its own deadlines and its endpoint lets go of it, however many of the
//! closes were lost.

#![expect(
    clippy::unwrap_used,
    clippy::panic,
    reason = "invalid harness setup or a broken invariant must fail the fuzz run"
)]

use std::{
    collections::{BTreeMap, BTreeSet},
    net::SocketAddr,
};

use rama_core::bytes::Bytes;
use rama_quic_proto::{VarInt, Version};

use super::fuzz_pair::{Pair, Peer, configs};
use crate::proto::{ConnectionStats, Duration};

const MAX_OPS: usize = 64;
/// Packets waiting in one direction; more are dropped, as a full link would.
const MAX_QUEUED: usize = 64;
/// Bytes before an application datagram's tag; the tag says who sent it and which it was.
const TAG: usize = 5;
const MAX_PAYLOAD: usize = 1100;
/// Iterations the teardown may take to drain both connections.
const TEARDOWN_STEPS: usize = 4096;

/// A sender off every path the connection knows.
const STRANGER: SocketAddr = SocketAddr::new(
    std::net::IpAddr::V4(std::net::Ipv4Addr::new(192, 0, 2, 7)),
    7777,
);

/// What one case reached, so the fixed regressions can prove their path ran.
#[derive(Debug, Default, Clone, Copy)]
pub(super) struct Coverage {
    /// Application datagrams delivered: client to server, server to client.
    pub(super) delivered: [u64; 2],
    /// Application datagrams `send` accepted, per direction.
    pub(super) sent: [u64; 2],
    /// Packets delivered twice.
    pub(super) replayed: u64,
    /// Packets delivered after the one behind them.
    pub(super) reordered: u64,
    /// Packets delivered damaged: truncated or a bit flipped.
    pub(super) damaged: u64,
    /// Datagrams from the input, delivered raw.
    pub(super) injected: u64,
    /// Connections that drained in the teardown.
    pub(super) drained: u64,
    /// Datagrams held for their route, and those of them sent once it was in, both sides.
    pub(super) waited: [u64; 2],
}

/// Input: a version byte, then at most 64 `(opcode, a, u16 length)` operations.
#[cfg_attr(
    not(fuzzing),
    expect(
        unreachable_pub,
        reason = "also compiled for the harness regression tests"
    )
)]
pub fn datagram_sequence(input: &[u8]) {
    _ = run(input);
}

struct Case {
    pair: Pair,
    /// Accepted payloads per direction, by sequence number.
    sent: [BTreeMap<u32, Bytes>; 2],
    delivered: [BTreeSet<u32>; 2],
    next: [u32; 2],
    /// Cumulative counters as last seen, per side.
    stats: [Option<ConnectionStats>; 2],
    coverage: Coverage,
}

impl Case {
    fn peer(&mut self, side: usize) -> &mut Peer {
        if side == 0 {
            &mut self.pair.client
        } else {
            &mut self.pair.server
        }
    }

    /// The side a packet of direction `direction` goes to, and from where.
    fn ends(&self, direction: usize) -> (usize, SocketAddr) {
        if direction == 0 {
            (1, self.pair.client.address)
        } else {
            (0, self.pair.server.address)
        }
    }
}

pub(super) fn run(input: &[u8]) -> Coverage {
    let Some((&version, input)) = input.split_first() else {
        return Coverage::default();
    };
    let version = if version & 1 == 0 {
        Version::V1
    } else {
        Version::V2
    };
    let (client_config, server_config) = configs(version, b"rama-datagram-fuzz");
    let mut case = Case {
        pair: Pair::new(client_config, server_config, version),
        sent: [BTreeMap::new(), BTreeMap::new()],
        delivered: [BTreeSet::new(), BTreeSet::new()],
        next: [0, 0],
        stats: [None, None],
        coverage: Coverage::default(),
    };
    for operation in input.as_chunks::<4>().0.iter().take(MAX_OPS) {
        let [op, a, lo, hi] = *operation;
        let len = usize::from(u16::from_le_bytes([lo, hi]));
        step(&mut case, op, a, len);
        receive(&mut case);
        check_counters(&mut case);
    }
    teardown(case)
}

fn step(case: &mut Case, op: u8, a: u8, len: usize) {
    let side = usize::from(a & 1);
    match op % 7 {
        0 => {
            for _ in 0..1 + (a >> 1) % 4 {
                transmit(case, side);
            }
        }
        1 => deliver(case, side, (a >> 1) % 7, len),
        2 => {
            let target = side;
            let from = if a & 2 == 0 {
                case.peer(1 - target).address
            } else {
                STRANGER
            };
            let bytes: Vec<u8> = (0..1 + len % 1500).map(|i| a ^ (i as u8)).collect();
            let now = case.pair.now;
            case.peer(target).receive(now, from, &bytes);
            case.coverage.injected += 1;
        }
        3 => send(case, side, len),
        4 => {
            case.pair.now += Duration::from_millis(1 + u64::from(a) * 10);
            for side in 0..2 {
                let now = case.pair.now;
                if let Some((_, connection)) = &mut case.peer(side).connection
                    && connection.poll_timeout().is_some_and(|at| at <= now)
                {
                    connection.handle_timeout(now);
                }
            }
        }
        5 => {
            for _ in 0..1 + a % 8 {
                for side in 0..2 {
                    transmit(case, side);
                    while !case.peer(side).outgoing.is_empty() {
                        deliver(case, side, 0, 0);
                    }
                }
                case.pair.now += Duration::from_millis(1);
            }
        }
        _ => {
            let now = case.pair.now;
            if let Some((_, connection)) = &mut case.peer(side).connection {
                connection.close(now, VarInt::from_u32(0), Bytes::new());
            }
        }
    }
}

fn transmit(case: &mut Case, side: usize) {
    let now = case.pair.now;
    let peer = case.peer(side);
    peer.transmit(now);
    while peer.outgoing.len() > MAX_QUEUED {
        peer.outgoing.pop_front();
    }
}

/// Act on the next packet `direction` sends: 0 deliver, 1 drop, 2 deliver twice, 3 swap with
/// the one behind it, 4 truncate, 5 flip a bit, 6 deliver from a stranger.
fn deliver(case: &mut Case, direction: usize, action: u8, len: usize) {
    let (target, from) = case.ends(direction);
    let now = case.pair.now;
    let Some(mut packet) = case.peer(direction).outgoing.pop_front() else {
        return;
    };
    let from = match action {
        1 => return,
        2 => {
            case.peer(target).receive(now, from, &packet);
            case.coverage.replayed += 1;
            from
        }
        3 => {
            let outgoing = &mut case.peer(direction).outgoing;
            if let Some(next) = outgoing.pop_front() {
                outgoing.push_front(packet);
                packet = next;
                case.coverage.reordered += 1;
            }
            from
        }
        4 => {
            packet.truncate(len % packet.len().max(1));
            case.coverage.damaged += 1;
            from
        }
        5 => {
            let bit = len % (packet.len() * 8).max(1);
            if let Some(byte) = packet.get_mut(bit / 8) {
                *byte ^= 1 << (bit % 8);
            }
            case.coverage.damaged += 1;
            from
        }
        6 => STRANGER,
        _ => from,
    };
    case.peer(target).receive(now, from, &packet);
}

/// Send a tagged application datagram from `side`, remembered only when `send` accepts it.
fn send(case: &mut Case, side: usize, len: usize) {
    let sequence = case.next[side];
    let mut payload = Vec::with_capacity(TAG + len % MAX_PAYLOAD);
    payload.push(side as u8);
    payload.extend_from_slice(&sequence.to_le_bytes());
    payload.extend((0..len % MAX_PAYLOAD).map(|i| (i as u8) ^ (sequence as u8)));
    let payload = Bytes::from(payload);
    let Some((_, connection)) = &mut case.peer(side).connection else {
        return;
    };
    if connection.datagrams().send(payload.clone(), false).is_ok() {
        case.sent[side].insert(sequence, payload);
        case.next[side] += 1;
        case.coverage.sent[side] += 1;
    }
}

/// Take what each side received: only what the other side sent, intact, once.
fn receive(case: &mut Case) {
    for side in 0..2 {
        let mut received = Vec::new();
        if let Some((_, connection)) = &mut case.peer(side).connection {
            while connection.poll().is_some() {}
            while let Some(datagram) = connection.datagrams().recv() {
                received.push(datagram);
            }
        }
        let direction = 1 - side;
        for datagram in received {
            let Some((&tag, rest)) = datagram.split_first() else {
                panic!("side {side} received an empty datagram");
            };
            let sequence = rest
                .get(..4)
                .map(|bytes| u32::from_le_bytes(bytes.try_into().unwrap()));
            let sent = sequence.and_then(|sequence| case.sent[direction].get(&sequence));
            if usize::from(tag) != direction || sent != Some(&datagram) {
                panic!("side {side} received a datagram nobody sent: {datagram:?}");
            }
            if !case.delivered[direction].insert(sequence.unwrap()) {
                panic!("side {side} received datagram {sequence:?} twice");
            }
            case.coverage.delivered[direction] += 1;
        }
    }
}

/// Counters that only accumulate never fall.
fn check_counters(case: &mut Case) {
    for side in 0..2 {
        let Some((_, connection)) = &case.peer(side).connection else {
            continue;
        };
        let stats = connection.stats();
        if let Some(last) = &case.stats[side] {
            let fell = stats.udp_tx.datagrams < last.udp_tx.datagrams
                || stats.udp_tx.bytes < last.udp_tx.bytes
                || stats.udp_rx.datagrams < last.udp_rx.datagrams
                || stats.udp_rx.bytes < last.udp_rx.bytes
                || stats.path.lost_packets < last.path.lost_packets;
            if fell {
                panic!("side {side}: a cumulative counter fell: {last:?} -> {stats:?}");
            }
        }
        case.stats[side] = Some(stats);
    }
}

/// Close both sides locally, lose whatever they send, and drive each on its own deadlines until
/// it drains and its endpoint lets go of it.
fn teardown(mut case: Case) -> Coverage {
    for side in 0..2 {
        let now = case.pair.now;
        if let Some((_, connection)) = &mut case.peer(side).connection
            && !connection.is_closed()
        {
            connection.close(now, VarInt::from_u32(0), Bytes::new());
        }
    }
    for _ in 0..TEARDOWN_STEPS {
        let mut next = None;
        for side in 0..2 {
            let now = case.pair.now;
            let peer = case.peer(side);
            peer.routes();
            let drained = peer
                .connection
                .as_ref()
                .is_some_and(|(_, connection)| connection.is_drained());
            if drained {
                peer.routes();
                peer.connection = None;
                case.coverage.drained += 1;
                continue;
            }
            peer.transmit(now);
            peer.outgoing.clear();
            if let Some((_, connection)) = &peer.connection {
                let at = connection.poll_timeout();
                next = match (next, at) {
                    (Some(next), Some(at)) => Some(std::cmp::min(next, at)),
                    (next, at) => next.or(at),
                };
            }
        }
        if case.pair.client.connection.is_none() && case.pair.server.connection.is_none() {
            break;
        }
        // Straight to the next deadline; a connection without one moves on by a millisecond.
        case.pair.now = next.map_or(case.pair.now + Duration::from_millis(1), |at| {
            at.max(case.pair.now)
        });
    }
    for side in 0..2 {
        let waited = case.peer(side).waited;
        case.coverage.waited[0] += waited[0];
        case.coverage.waited[1] += waited[1];
        let peer = case.peer(side);
        if peer.connection.is_some() {
            panic!("side {side}'s connection never drained");
        }
        if peer.endpoint.open_connections() != 0 {
            panic!("side {side}'s endpoint still holds a drained connection");
        }
    }
    case.coverage
}

#[cfg(test)]
mod tests {
    use super::{Coverage, MAX_OPS, datagram_sequence, run};

    const TRANSMIT: u8 = 0;
    const DELIVER: u8 = 1;
    const INJECT: u8 = 2;
    const SEND: u8 = 3;
    const ADVANCE: u8 = 4;
    const DRIVE: u8 = 5;
    const CLOSE: u8 = 6;

    /// Deliver actions, shifted into place above the direction bit.
    const PASS: u8 = 0;
    const TWICE: u8 = 2 << 1;
    const SWAP: u8 = 3 << 1;
    const TRUNCATE: u8 = 4 << 1;
    const FLIP: u8 = 5 << 1;
    const FROM_STRANGER: u8 = 6 << 1;

    const fn op(kind: u8, a: u8, len: u16) -> [u8; 4] {
        let [lo, hi] = len.to_le_bytes();
        [kind, a, lo, hi]
    }

    fn input(version: u8, operations: &[[u8; 4]]) -> Vec<u8> {
        let mut input = vec![version];
        for operation in [op(DRIVE, 7, 0), op(DRIVE, 7, 0)].iter().chain(operations) {
            input.extend_from_slice(operation);
        }
        input
    }

    fn each_version(operations: &[[u8; 4]]) -> [Coverage; 2] {
        [run(&input(0, operations)), run(&input(1, operations))]
    }

    #[test]
    fn datagrams_are_delivered_both_ways_on_each_version() {
        for coverage in each_version(&[op(SEND, 0, 64), op(SEND, 1, 64), op(DRIVE, 3, 0)]) {
            assert_eq!(coverage.sent, [1, 1], "{coverage:?}");
            assert_eq!(coverage.delivered, [1, 1]);
            assert_eq!(coverage.drained, 2);
        }
    }

    #[test]
    fn a_replayed_packet_delivers_its_datagram_once() {
        for coverage in each_version(&[op(SEND, 0, 64), op(TRANSMIT, 0, 0), op(DELIVER, TWICE, 0)])
        {
            assert_eq!(coverage.replayed, 1, "{coverage:?}");
            assert_eq!(coverage.delivered[0], 1);
        }
    }

    #[test]
    fn reordered_packets_deliver_each_datagram_once() {
        for coverage in each_version(&[
            op(SEND, 0, 1000),
            op(SEND, 0, 1000),
            op(TRANSMIT, 1 << 1, 0),
            op(DELIVER, SWAP, 0),
            op(DELIVER, PASS, 0),
        ]) {
            assert_eq!(coverage.reordered, 1, "{coverage:?}");
            assert_eq!(coverage.delivered[0], 2);
        }
    }

    #[test]
    fn damaged_packets_deliver_nothing() {
        for coverage in each_version(&[
            op(SEND, 0, 64),
            op(TRANSMIT, 0, 0),
            op(DELIVER, TRUNCATE, 10),
            op(SEND, 0, 64),
            op(TRANSMIT, 0, 0),
            op(DELIVER, FLIP, 100),
        ]) {
            assert_eq!(coverage.damaged, 2, "{coverage:?}");
            assert_eq!(coverage.sent[0], 2);
            assert_eq!(coverage.delivered[0], 0);
        }
    }

    #[test]
    fn injected_and_misrouted_packets_break_nothing() {
        for coverage in each_version(&[
            op(INJECT, 0, 40),
            op(INJECT, 1 | 2, 1200),
            op(SEND, 0, 64),
            op(TRANSMIT, 0, 0),
            op(DELIVER, FROM_STRANGER, 0),
            op(SEND, 1, 64),
            op(DRIVE, 3, 0),
        ]) {
            assert_eq!(coverage.injected, 2, "{coverage:?}");
            assert_eq!(coverage.delivered[1], 1);
            assert_eq!(coverage.drained, 2);
        }
    }

    #[test]
    fn closes_lost_both_ways_still_drain() {
        for coverage in each_version(&[op(CLOSE, 0, 0), op(TRANSMIT, 0, 0), op(DELIVER, 1 << 1, 0)])
        {
            assert_eq!(coverage.drained, 2, "{coverage:?}");
        }
    }

    #[test]
    fn mixed_sequences_remain_bounded() {
        let mut state = 0xda7a_u64;
        for _ in 0..48 {
            let mut input = [0u8; 1 + 4 * MAX_OPS];
            for byte in &mut input {
                state = state.wrapping_mul(6364136223846793005).wrapping_add(1);
                *byte = (state >> 32) as u8;
            }
            datagram_sequence(&input);
        }
    }

    /// The client's first flight comes from a stranger and the rest from its own address, so the
    /// server rebinds on the handshake identifier and leaves it afterwards; a later packet from
    /// the stranger then has the server owe that address a challenge. The address never saw the
    /// identifier the server moved to, so nothing may wait on a route for it there. The first
    /// flight is one Initial or, with a post-quantum key share, two.
    #[test]
    fn leaving_the_handshake_identifier_after_a_rebinding_holds_nothing() {
        let operations = [
            op(DELIVER, FROM_STRANGER, 0),
            op(TRANSMIT, 0, 0),
            op(DELIVER, FROM_STRANGER, 0),
            op(DRIVE, 2, 0),
            op(SEND, 0, 0),
            op(TRANSMIT, 0, 0),
            op(DELIVER, FROM_STRANGER, 0),
            op(SEND, 0, 0),
            op(TRANSMIT, 1, 0),
            op(DRIVE, 0, 0),
            op(TRANSMIT, 0, 0),
            op(ADVANCE, 168, 0),
            op(DELIVER, PASS, 0),
            op(TRANSMIT, 1, 0),
        ];
        for version in 0..2 {
            let mut input = vec![version];
            for operation in operations {
                input.extend_from_slice(&operation);
            }
            let coverage = run(&input);
            assert_eq!(coverage.delivered[0], 2, "{coverage:?}");
            assert_eq!(coverage.waited[0], coverage.waited[1]);
            assert_eq!(coverage.drained, 2);
        }
    }
}
