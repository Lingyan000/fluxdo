//! What the close observer records for each terminal event.
//!
//! The bridge labels the event a received CONNECTION_CLOSE installs. These drive the pinned
//! frame handlers directly, so a refused frame, an already chosen local close and a close
//! that arrives are each seen on their own.

mod common;

use common::*;

const PEER: &str = "aioquic";

#[tokio::test]
async fn the_close_observer_labels_only_the_event_a_received_frame_installs() {
    prepare().await;
    let deadline = Deadline::of(LIMIT);
    let mut peer = AioQuic::spawn("observer-states", &[]).await;

    let refused = peer.expect("refused-frame", deadline).await;
    assert_eq!(
        refused.raised(),
        Some("BufferReadError"),
        "{PEER}: the handler's own exception was not preserved"
    );
    assert_eq!(
        refused.labelled(),
        0,
        "{PEER}: a frame the handler refused was labelled"
    );

    let chosen = peer.expect("already-chosen", deadline).await;
    assert_eq!(
        chosen.labelled(),
        0,
        "{PEER}: a close already chosen locally was relabelled"
    );
    assert!(
        !chosen.close_arrived(),
        "{PEER}: a close chosen locally reported as one that arrived"
    );
    assert_eq!(chosen.code(), 42, "{PEER}: unexpected local close code");
    assert_eq!(
        chosen.reason(),
        "local cause",
        "{PEER}: unexpected local close reason"
    );

    for (event, application, code) in [
        ("arrived-application", true, 0),
        ("arrived-transport", false, 7),
    ] {
        let seen = peer.expect(event, deadline).await;
        assert_eq!(seen.labelled(), 1, "{PEER}/{event}: unexpected label count");
        assert!(
            seen.close_arrived(),
            "{PEER}/{event}: a close that arrived reported as local"
        );
        assert_eq!(
            seen.application(),
            application,
            "{PEER}/{event}: unexpected close category"
        );
        assert_eq!(seen.code(), code, "{PEER}/{event}: unexpected close code");
    }

    peer.expect("done", deadline).await;
    peer.finished(deadline).await;
}
