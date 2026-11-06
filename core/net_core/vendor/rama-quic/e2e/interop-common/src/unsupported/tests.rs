//! The oracle behind the unsupported case: that a datagram no peer should have seen, and an
//! exchange that is not the one the case names, both fail.

use super::{Received, UnsupportedObservation, unsupported_cases};

/// A peer that reports a datagram on a connection where none could be sent is the failure this
/// case exists to catch.
#[test]
#[should_panic(expected = "was sent one of 64 bytes")]
fn a_datagram_reported_by_a_peer_that_offered_none_is_refused() {
    let scenario = unsupported_cases()[0].scenario;
    let observed = UnsupportedObservation {
        datagram: Some(Received::Bytes(scenario.refused.bytes())),
        carried: Some(Received::Bytes(scenario.carried.bytes())),
    };
    observed.check("oracle/unsupported", &scenario);
}

/// And the exchange is checked against the case's own chunk, not whatever came back.
#[test]
#[should_panic(expected = "the whole exchange")]
fn an_exchange_that_is_not_the_one_the_case_names_is_refused() {
    let scenario = unsupported_cases()[0].scenario;
    let observed = UnsupportedObservation {
        datagram: None,
        carried: Some(Received::Bytes(scenario.refused.bytes())),
    };
    observed.check("oracle/unsupported", &scenario);
}

/// The pair a peer actually produces passes both.
#[test]
fn a_connection_that_carried_only_the_exchange_passes() {
    let scenario = unsupported_cases()[0].scenario;
    let observed = UnsupportedObservation {
        datagram: None,
        carried: Some(Received::Bytes(scenario.carried.bytes())),
    };
    observed.check("oracle/unsupported", &scenario);
}
