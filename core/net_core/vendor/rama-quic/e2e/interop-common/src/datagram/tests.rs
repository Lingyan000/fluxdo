//! The oracle behind the datagram cases: that each direction's expectation is taken from the
//! side that actually sends it.

use super::{DatagramObservation, DatagramScenario, Received, Role};
use crate::scenario::Chunk;

/// The two directions of a case, with a send limit that admits one and not the other. It is
/// the oracle that is exercised here, not the wire: a real peer's negotiated limit is not
/// configurable enough to sit between two payloads on every stack.
fn asymmetric() -> (DatagramScenario, DatagramObservation, DatagramObservation) {
    let scenario = DatagramScenario {
        out: Chunk {
            seed: 0x01,
            len: 64,
        },
        back: Chunk {
            seed: 0x02,
            len: 200,
        },
        at_the_boundary: false,
    };
    // Rama is the client: it sent `out`, and the peer must be able to send `back` (200).
    let as_client = DatagramObservation {
        sendable: Some(200),
        advertised: None,
        received: Some(Received::Bytes(scenario.out.bytes())),
    };
    // Rama is the server: it sent `back`, and the peer must be able to send `out` (64).
    let as_server = DatagramObservation {
        sendable: Some(64),
        advertised: None,
        received: Some(Received::Bytes(scenario.back.bytes())),
    };
    (scenario, as_client, as_server)
}

#[test]
fn the_send_limit_is_checked_against_what_the_peer_sends() {
    let (scenario, as_client, as_server) = asymmetric();
    as_client.check(
        "oracle/rama-client",
        &scenario,
        Role::RamaClient,
        scenario.out,
    );
    as_server.check(
        "oracle/rama-server",
        &scenario,
        Role::RamaServer,
        scenario.back,
    );
}

/// A limit one byte short of what the peer has to send is caught, in either role. This is
/// what fails if the check takes its chunk from the wrong direction.
#[test]
#[should_panic(expected = "the peer may send the datagram this case asks of it")]
fn a_limit_short_of_what_the_peer_sends_is_refused() {
    let (scenario, mut as_client, _) = asymmetric();
    as_client.sendable = Some(scenario.back.len - 1);
    as_client.check(
        "oracle/rama-client",
        &scenario,
        Role::RamaClient,
        scenario.out,
    );
}

/// The same, with Rama as the server, so neither direction passes by accident.
#[test]
#[should_panic(expected = "the peer may send the datagram this case asks of it")]
fn a_limit_short_of_what_the_peer_sends_is_refused_in_the_other_role() {
    let (scenario, _, mut as_server) = asymmetric();
    as_server.sendable = Some(scenario.out.len - 1);
    as_server.check(
        "oracle/rama-server",
        &scenario,
        Role::RamaServer,
        scenario.back,
    );
}
