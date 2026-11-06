//! The oracle behind the backpressure case: that the cancelled payload is refused wherever it
//! turns up, that the one sent once there was room has to turn up, and that a report arriving
//! after it is still accounted for.

use super::Sent;
use crate::{scenario::Received, support::payload};

/// Three taken, a fourth cancelled, and a fifth sent once the peer was reading again.
fn sent() -> Sent {
    Sent {
        queued: 3,
        cancelled: payload(0x76, 64),
        after: payload(0x77, 64),
    }
}

/// One of the fill, named so the reports below are distinguishable.
fn filling(number: u8) -> Received {
    Received::Bytes(payload(number, 64))
}

/// The marker is recognised, and nothing else is taken for it.
#[test]
fn the_datagram_sent_once_there_was_room_is_recognised() {
    let sent = sent();
    assert!(sent.resumed(&Received::Bytes(sent.after.clone())));
    assert!(!sent.resumed(&filling(0x78)));
    assert!(!sent.resumed(&Received::Bytes(sent.cancelled.clone())));
}

/// A report that arrived after the marker is still one of the reports, and an allowed one is
/// accepted there.
#[test]
fn a_report_after_the_marker_is_still_accounted_for() {
    let sent = sent();
    sent.account_for(
        "oracle/no-room",
        &[Received::Bytes(sent.after.clone()), filling(0x78)],
    );
}

/// The cancelled payload after the marker is the failure this case is about, and stopping at
/// the marker is what would miss it.
#[test]
#[should_panic(expected = "the cancelled datagram was never enqueued")]
fn the_cancelled_payload_after_the_marker_is_refused() {
    let sent = sent();
    sent.account_for(
        "oracle/no-room",
        &[
            Received::Bytes(sent.after.clone()),
            Received::Bytes(sent.cancelled.clone()),
        ],
    );
}

/// Nothing having resumed is a failure too, however many of the fill arrived.
#[test]
#[should_panic(expected = "the datagram sent once there was room arrived")]
fn the_marker_has_to_arrive() {
    sent().account_for("oracle/no-room", &[filling(0x78), filling(0x7a)]);
}

/// And so is a peer reporting more than were ever sent.
#[test]
#[should_panic(expected = "the peer reported 5 datagrams where 4 were sent")]
fn more_than_were_sent_must_not_arrive() {
    let sent = sent();
    sent.account_for(
        "oracle/no-room",
        &[
            Received::Bytes(sent.after.clone()),
            filling(0x78),
            filling(0x7a),
            filling(0x7b),
            filling(0x7c),
        ],
    );
}
