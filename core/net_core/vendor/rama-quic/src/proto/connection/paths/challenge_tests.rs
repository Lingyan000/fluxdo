//! What a validation token can prove, and when.
//!
//! A response names only the token, so the rules here are what keep a small datagram from
//! ever standing in for an expanded one (RFC 9000 §8.2.1).

use crate::proto::{MIN_INITIAL_SIZE, connection::paths::Challenge};

#[test]
fn retransmission_waits_and_stays_bounded_when_rtt_changes() {
    use crate::proto::{Duration, Instant};
    let mut now = Instant::now();
    let mut challenge = Challenge::of_address(0x1234, 7);
    for attempt in 0..3 {
        assert!(challenge.pending());
        let delay = Duration::from_millis(100 >> attempt);
        challenge.written(now, delay);
        challenge.rearm(now + delay / 2);
        assert!(!challenge.pending());
        now += delay;
        challenge.rearm(now);
    }
    assert!(!challenge.pending());
    assert!(challenge.retry_at().is_none());
    challenge.rearm(now + Duration::from_secs(60));
    assert!(!challenge.pending());
}

/// A token whose first datagram was expanded may never go into a smaller one afterwards:
/// a response names the token, not the transmission, so a later undersized copy could be
/// the one answered and would certify an MTU the path never showed.
#[test]
fn an_expanded_token_is_never_offered_undersized() {
    let mut challenge = Challenge::of_address(0x1234, 7);
    challenge.note_sent(usize::from(MIN_INITIAL_SIZE));
    assert!(challenge.proves_mtu(), "the first datagram was expanded");
    assert!(challenge.may_go_in(true), "it may go out expanded again");
    assert!(
        !challenge.may_go_in(false),
        "and never in a datagram that cannot expand"
    );
}

/// The reverse stays conservative: a token first sent undersized keeps proving only the
/// address, however large a later datagram carrying it turns out to be.
#[test]
fn an_undersized_token_stays_undersized_evidence() {
    let mut challenge = Challenge::of_address(0x1234, 7);
    challenge.note_sent(usize::from(MIN_INITIAL_SIZE) - 1);
    assert!(!challenge.proves_mtu());
    assert!(challenge.may_go_in(false), "it may still be retransmitted");
    challenge.note_sent(usize::from(MIN_INITIAL_SIZE));
    assert!(
        !challenge.proves_mtu(),
        "a later expanded copy does not revise what a response proves"
    );
}

/// The validation that exists to prove the MTU is only ever offered expanded, from the
/// first datagram onwards.
#[test]
fn an_mtu_token_is_only_ever_offered_expanded() {
    let challenge = Challenge::of_mtu(0x5678, 7);
    assert!(!challenge.may_go_in(false));
    assert!(challenge.may_go_in(true));
}

/// A token nothing has sent answers nothing, and one from another path validates nothing
/// on this one.
#[test]
fn a_token_answers_only_once_it_has_gone_out_on_this_path() {
    let mut challenge = Challenge::of_address(0x9abc, 7);
    assert!(
        !challenge.is_answered_by(0x9abc, 7),
        "nothing carrying it has left yet"
    );
    challenge.note_sent(usize::from(MIN_INITIAL_SIZE));
    assert!(challenge.is_answered_by(0x9abc, 7));
    assert!(!challenge.is_answered_by(0x9abc, 8), "another generation");
    assert!(!challenge.is_answered_by(0x9abd, 7), "another token");
}
