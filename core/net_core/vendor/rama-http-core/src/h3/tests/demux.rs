//! The datagram demultiplexer's budgets, lifetimes and end-of-receive rules, driven directly.

use crate::h3::datagram::{
    AbortRequest, DatagramConfig, DatagramLimits, Demux, MIN_DATAGRAM_CHARGE as C, ReceiveEnd,
    Semantics, invalid_prefix_error, pending_lifetime,
};
use rama_core::bytes::Bytes;
use rama_http::datagram::{NativeRecvError, ViolationPolicy};
use std::assert_matches;
use std::{
    sync::{
        Arc,
        atomic::{AtomicBool, AtomicUsize, Ordering},
    },
    task::{Context, Poll, Waker},
    time::Duration,
};
use tokio::time::Instant;

/// Counts aborted requests.
#[derive(Clone, Default)]
struct Aborts(Arc<AtomicUsize>);

impl AbortRequest for Aborts {
    fn abort_request(&self) {
        self.0.fetch_add(1, Ordering::AcqRel);
    }
}

fn config(queue_len: usize, pending_len: usize, max_buffered_bytes: usize) -> DatagramConfig {
    DatagramConfig {
        limits: DatagramLimits {
            queue_len,
            pending_len,
            max_buffered_bytes,
        },
        violations: ViolationPolicy::Reject,
    }
}

const LIFETIME: Duration = Duration::from_millis(100);

fn register(
    demux: &mut Demux<Aborts>,
    config: &DatagramConfig,
    stream: u64,
    now: Instant,
) -> Aborts {
    let aborts = Aborts::default();
    demux
        .register(
            config,
            stream,
            Semantics::Claimed,
            aborts.clone(),
            Arc::new(AtomicBool::new(false)),
            now,
        )
        .run();
    aborts
}

fn poll(demux: &mut Demux<Aborts>, stream: u64) -> Poll<Result<Option<Bytes>, NativeRecvError>> {
    demux.poll_recv(stream, &Context::from_waker(Waker::noop()))
}

fn deliver(
    demux: &mut Demux<Aborts>,
    config: &DatagramConfig,
    stream: u64,
    len: usize,
    now: Instant,
) {
    demux
        .deliver(config, stream, &Bytes::from(vec![0; len]), now, LIFETIME)
        .run();
}

#[test]
fn payloads_that_exactly_fit_the_budget_are_kept() {
    let config = config(4, 4, 8 * C);
    let now = Instant::now();
    let mut demux = Demux::default();
    // Held for a future stream, filling the budget exactly, then adopted.
    deliver(&mut demux, &config, 4, 8 * C, now);
    register(&mut demux, &config, 4, now);
    assert_matches!(poll(&mut demux, 4), Poll::Ready(Ok(Some(payload))) if payload.len() == 8 * C);
    // Queued: a sum that fits where a product would not, then one over the budget, for
    // which the oldest makes room.
    register(&mut demux, &config, 8, now);
    deliver(&mut demux, &config, 8, 2 * C, now);
    deliver(&mut demux, &config, 8, 5 * C, now);
    deliver(&mut demux, &config, 8, 2 * C, now);
    assert_matches!(poll(&mut demux, 8), Poll::Ready(Ok(Some(payload))) if payload.len() == 5 * C);
    assert_matches!(poll(&mut demux, 8), Poll::Ready(Ok(Some(payload))) if payload.len() == 2 * C);
    assert!(poll(&mut demux, 8).is_pending());
    assert_eq!(demux.drops().over_budget, 1);
    // The request's own count, reported through its native channel.
    assert_eq!(demux.slot_dropped(8), 1);
}

/// Held datagrams and a payload that together fill the budget exactly: queued datagrams make
/// the room, the payload stays.
#[test]
fn held_datagrams_and_a_payload_that_exactly_fill_the_budget_keep_it() {
    let config = config(4, 4, 10 * C);
    let now = Instant::now();
    let mut demux = Demux::default();
    register(&mut demux, &config, 0, now);
    deliver(&mut demux, &config, 0, 2 * C, now);
    deliver(&mut demux, &config, 8, 6 * C, now);
    deliver(&mut demux, &config, 0, 4 * C, now);
    assert_eq!(demux.slot_dropped(0), 1);
    assert_matches!(poll(&mut demux, 0), Poll::Ready(Ok(Some(payload))) if payload.len() == 4 * C);
    demux.assert_consistent(&config.limits);
}

/// A full hold gives way for a datagram that fits once the oldest held one has left.
#[test]
fn a_held_datagram_that_fits_in_the_oldest_place_replaces_it() {
    let config = config(4, 1, 3 * C);
    let now = Instant::now();
    let mut demux = Demux::default();
    deliver(&mut demux, &config, 4, 2 * C, now);
    deliver(&mut demux, &config, 8, 2 * C, now);
    assert_eq!(demux.drops().over_budget, 0);
    assert_eq!(demux.drops().expired, 1);
    assert_eq!((demux.pending_len(), demux.buffered()), (1, 2 * C));
    register(&mut demux, &config, 8, now);
    assert_matches!(poll(&mut demux, 8), Poll::Ready(Ok(Some(payload))) if payload.len() == 2 * C);
    demux.assert_consistent(&config.limits);
}

/// Adoption agrees with expiry: at exactly its lifetime a held datagram has expired.
#[test]
fn a_held_datagram_at_exactly_its_lifetime_has_expired() {
    let config = config(4, 4, 64 * C);
    let now = Instant::now();
    let mut demux = Demux::default();
    deliver(&mut demux, &config, 4, C, now);
    register(&mut demux, &config, 4, now + LIFETIME);
    assert!(poll(&mut demux, 4).is_pending());
    assert_eq!(demux.drops().expired, 1);
    demux.assert_consistent(&config.limits);
}

#[test]
fn held_datagrams_crowding_the_budget_drop_the_payload_not_the_queues() {
    let config = config(4, 4, 10 * C);
    let now = Instant::now();
    let mut demux = Demux::default();
    register(&mut demux, &config, 0, now);
    deliver(&mut demux, &config, 0, 4 * C, now);
    // Held for a stream not open yet, it leaves no room that evicting queues could make.
    deliver(&mut demux, &config, 8, 6 * C, now);
    deliver(&mut demux, &config, 0, 5 * C, now);
    assert_matches!(poll(&mut demux, 0), Poll::Ready(Ok(Some(payload))) if payload.len() == 4 * C);
    assert!(poll(&mut demux, 0).is_pending());
    assert_eq!(demux.drops().over_budget, 1);
    assert_eq!(demux.slot_dropped(0), 1);
}

#[test]
fn a_payload_that_can_never_fit_leaves_a_full_queue_alone() {
    let config = config(4, 4, 64 * C);
    let now = Instant::now();
    let mut demux = Demux::default();
    register(&mut demux, &config, 8, now);
    for _ in 0..4 {
        deliver(&mut demux, &config, 8, 8 * C, now);
    }
    deliver(&mut demux, &config, 8, 65 * C, now);
    for _ in 0..4 {
        assert_matches!(poll(&mut demux, 8), Poll::Ready(Ok(Some(payload))) if payload.len() == 8 * C);
    }
    assert!(poll(&mut demux, 8).is_pending());
    assert_eq!(demux.drops().over_budget, 1);
    assert_eq!(demux.drops().queue_full, 0);
    assert_eq!(demux.slot_dropped(8), 1);
}

/// A datagram keeps its whole packet alive, so even an empty one costs a packet's charge.
#[test]
fn small_datagrams_are_charged_a_packet() {
    let config = config(32, 4, 3 * C);
    let now = Instant::now();
    let mut demux = Demux::default();
    register(&mut demux, &config, 0, now);
    for len in [0, 1, 0, 1] {
        deliver(&mut demux, &config, 0, len, now);
    }
    assert_eq!(demux.buffered(), 3 * C);
    for len in [1, 0, 1] {
        assert_matches!(poll(&mut demux, 0), Poll::Ready(Ok(Some(payload))) if payload.len() == len);
    }
    assert!(poll(&mut demux, 0).is_pending());
    assert_eq!(demux.drops().over_budget, 1);
}

/// A held datagram that would not fit even in its predecessor's place costs nobody else theirs.
#[test]
fn a_held_datagram_that_cannot_fit_keeps_the_oldest() {
    let config = config(4, 2, 3 * C);
    let now = Instant::now();
    let mut demux = Demux::default();
    deliver(&mut demux, &config, 4, C, now);
    deliver(&mut demux, &config, 4, C, now);
    deliver(&mut demux, &config, 8, 3 * C, now);
    assert_eq!(demux.drops().over_budget, 1);
    assert_eq!(demux.drops().expired, 0);
    register(&mut demux, &config, 4, now);
    for _ in 0..2 {
        assert_matches!(poll(&mut demux, 4), Poll::Ready(Ok(Some(payload))) if payload.len() == C);
    }
}

#[test]
fn a_request_without_queue_room_counts_its_drops() {
    let config = config(0, 4, 64 * C);
    let now = Instant::now();
    let mut demux = Demux::default();
    register(&mut demux, &config, 0, now);
    deliver(&mut demux, &config, 0, 3 * C, now);
    deliver(&mut demux, &config, 0, 3 * C, now);
    assert!(poll(&mut demux, 0).is_pending());
    assert_eq!(demux.drops().queue_full, 2);
    assert_eq!(demux.slot_dropped(0), 2);
}

#[test]
fn held_datagrams_expire_after_their_lifetime() {
    let config = config(4, 4, 64 * C);
    let now = Instant::now();
    let mut demux = Demux::default();
    deliver(&mut demux, &config, 4, 3 * C, now);
    register(&mut demux, &config, 4, now + LIFETIME * 2);
    assert!(poll(&mut demux, 4).is_pending());
    assert_eq!(demux.drops().expired, 1);
}

/// Expired held datagrams leave on any later delivery, freeing their budget, also when their
/// stream never registers.
#[test]
fn expired_held_datagrams_free_their_budget() {
    let config = config(4, 4, 64 * C);
    let now = Instant::now();
    let mut demux = Demux::default();
    register(&mut demux, &config, 0, now);
    deliver(&mut demux, &config, 4, 3 * C, now);
    assert_eq!((demux.pending_len(), demux.buffered()), (1, 3 * C));
    deliver(&mut demux, &config, 0, C, now + LIFETIME * 2);
    assert_eq!(demux.drops().expired, 1);
    assert_eq!((demux.pending_len(), demux.buffered()), (0, C));
}

#[test]
fn pending_datagrams_wait_a_few_round_trips_with_a_floor() {
    assert_eq!(
        pending_lifetime(Duration::from_millis(200)),
        Duration::from_millis(600)
    );
    assert_eq!(
        pending_lifetime(Duration::from_millis(1)),
        Duration::from_millis(100)
    );
}

#[test]
fn an_adopted_violation_aborts_its_request() {
    let config = config(4, 4, 64 * C);
    let now = Instant::now();
    let mut demux: Demux<Aborts> = Demux::default();
    deliver(&mut demux, &config, 4, 3 * C, now);
    deliver(&mut demux, &config, 4, 3 * C, now);
    let aborts = Aborts::default();
    demux
        .register(
            &config,
            4,
            Semantics::None,
            aborts.clone(),
            Arc::new(AtomicBool::new(false)),
            now,
        )
        .run();
    // Both held datagrams are violations; the request is aborted once.
    assert_eq!(aborts.0.load(Ordering::Acquire), 1);
    assert_eq!(demux.drops().no_semantics, 2);
}

#[test]
fn the_first_remote_end_stays_and_local_ends_override_it() {
    let config = config(4, 4, 64 * C);
    let now = Instant::now();
    let cases = [
        // A reset after the peer's FIN keeps the clean end.
        ([ReceiveEnd::Finished, ReceiveEnd::Reset(9)], Ok(None)),
        // A released consumer ends a reset stream cleanly for itself.
        ([ReceiveEnd::Reset(9), ReceiveEnd::Released], Ok(None)),
        // A local abort is final.
        (
            [ReceiveEnd::Aborted(5), ReceiveEnd::Released],
            Err(NativeRecvError::Aborted(5)),
        ),
        (
            [ReceiveEnd::Reset(9), ReceiveEnd::Finished],
            Err(NativeRecvError::Reset(9)),
        ),
    ];
    for (ends, expected) in cases {
        let mut demux = Demux::default();
        register(&mut demux, &config, 0, now);
        for end in ends {
            _ = demux.receive_ended(0, end);
        }
        assert_eq!(poll(&mut demux, 0), Poll::Ready(expected), "{ends:?}");
    }
}

#[test]
fn bursts_and_churn_leave_bounded_storage() {
    // Budget for the whole burst, so every queue and the pending area fill.
    let config = config(32, 16, 4 * 1024 * 1024);
    let now = Instant::now();
    let mut demux = Demux::default();
    // Fill 64 request queues and the pending area for streams not yet opened.
    for stream in (0..64).map(|index| index * 4) {
        register(&mut demux, &config, stream, now);
        for _ in 0..32 {
            deliver(&mut demux, &config, stream, 1024, now);
        }
    }
    for stream in (64..80).map(|index| index * 4) {
        deliver(&mut demux, &config, stream, 1024, now);
    }
    let burst = demux.capacities();
    for stream in (0..80).map(|index| index * 4) {
        if stream >= 256 {
            register(&mut demux, &config, stream, now);
        }
        while let Poll::Ready(Ok(Some(_))) = poll(&mut demux, stream) {}
        _ = demux.unregister(stream);
    }
    let drained = demux.capacities();
    // One request at a time, many times over.
    for stream in (80..10_080).map(|index| index * 4) {
        register(&mut demux, &config, stream, now);
        deliver(&mut demux, &config, stream, 1024, now);
        assert_matches!(poll(&mut demux, stream), Poll::Ready(Ok(Some(_))));
        _ = demux.unregister(stream);
    }
    let churned = demux.capacities();
    eprintln!(
        "(slots, pending, queues) capacity: burst {burst:?}, drained {drained:?}, after 10000 churns {churned:?}"
    );
    assert_eq!(demux.buffered(), 0);
    // Released requests free their queues; the map and pending queue never grow past the
    // burst's peak, whatever the churn.
    assert!(burst.1 >= 16 && burst.2 >= 64 * 32, "{burst:?}");
    assert_eq!(drained.2, 0);
    assert!(
        churned.0 <= burst.0 && churned.1 <= burst.1,
        "{churned:?} {burst:?}"
    );
    assert_eq!(churned.2, 0);
}

/// Stalled queues make room for a healthy one instead of starving it of the budget.
#[test]
fn stalled_queues_make_room_for_a_healthy_one() {
    let config = config(4, 4, 64 * C);
    let now = Instant::now();
    let mut demux = Demux::default();
    for stream in [0, 4, 8] {
        register(&mut demux, &config, stream, now);
    }
    // Two consumers that never read fill the budget exactly.
    for stream in [0, 4] {
        for _ in 0..4 {
            deliver(&mut demux, &config, stream, 8 * C, now);
        }
    }
    assert_eq!(demux.buffered(), 64 * C);
    demux.assert_consistent(&config.limits);
    for _ in 0..100 {
        deliver(&mut demux, &config, 8, 8 * C, now);
        assert_matches!(poll(&mut demux, 8), Poll::Ready(Ok(Some(payload))) if payload.len() == 8 * C);
    }
    assert_eq!(demux.slot_dropped(8), 0);
    assert_eq!(demux.slot_dropped(0) + demux.slot_dropped(4), 1);
    assert_eq!(demux.drops().over_budget, 1);
    // The evicted queue's own accounting follows its datagram out.
    demux.assert_consistent(&config.limits);
    // A payload that can never fit is dropped without evicting anyone.
    deliver(&mut demux, &config, 8, 65 * C, now);
    assert_eq!(demux.slot_dropped(8), 1);
    assert_eq!(demux.slot_dropped(0) + demux.slot_dropped(4), 1);
    assert!(demux.buffered() <= 64 * C);
}

/// A held datagram is adopted only within its own lifetime, whatever the queue order: at its
/// expiry instant it has expired, even behind a longer-lived one the expiry sweep stops at.
#[test]
fn held_datagrams_expire_by_their_own_lifetime() {
    for registered_after in [Duration::from_millis(100), Duration::from_millis(190)] {
        let config = config(4, 4, 64 * C);
        let start = Instant::now();
        let mut demux = Demux::<Aborts>::default();
        demux
            .deliver(
                &config,
                4,
                &Bytes::from_static(b"long"),
                start,
                Duration::from_millis(600),
            )
            .run();
        // Arrives later with a shorter lifetime, after the RTT fell.
        let arrival = start + Duration::from_millis(10);
        demux
            .deliver(
                &config,
                8,
                &Bytes::from_static(b"short"),
                arrival,
                Duration::from_millis(100),
            )
            .run();
        register(&mut demux, &config, 8, arrival + registered_after);
        assert!(poll(&mut demux, 8).is_pending(), "{registered_after:?}");
        assert_eq!(demux.drops().expired, 1, "{registered_after:?}");
        assert_eq!(demux.pending_len(), 1, "{registered_after:?}");
        register(&mut demux, &config, 4, start + Duration::from_millis(300));
        assert_matches!(
            poll(&mut demux, 4),
            Poll::Ready(Ok(Some(payload))) if payload == b"long"[..],
            "{registered_after:?}"
        );
        assert_eq!(demux.buffered(), 0, "{registered_after:?}");
    }
}

/// An invalid datagram prefix is the peer's failure, like every received-input violation.
#[test]
fn invalid_prefixes_are_remote_failures() {
    for beyond_limit in [false, true] {
        assert!(
            invalid_prefix_error(beyond_limit).is_remote_failure(),
            "{beyond_limit}"
        );
    }
}

/// A received payload shares its packet's allocation, of up to 64 KiB. Buffered, whether its
/// request registered or is still to come, it keeps only its own bytes alive, so the byte
/// budget bounds what the demultiplexer pins.
#[test]
fn buffered_datagrams_do_not_pin_their_packets() {
    struct Packet {
        bytes: Box<[u8]>,
        alive: Arc<AtomicBool>,
    }

    impl AsRef<[u8]> for Packet {
        fn as_ref(&self) -> &[u8] {
            &self.bytes
        }
    }

    impl Drop for Packet {
        fn drop(&mut self) {
            self.alive.store(false, Ordering::SeqCst);
        }
    }

    for packet_len in [1472, 65_527] {
        for registered in [true, false] {
            let case = format!("packet={packet_len} registered={registered}");
            let config = config(32, 16, 4 * C);
            let now = Instant::now();
            let mut demux = Demux::default();
            if registered {
                register(&mut demux, &config, 0, now);
            }
            let alive = Arc::new(AtomicBool::new(true));
            let packet = Bytes::from_owner(Packet {
                bytes: vec![7; packet_len].into_boxed_slice(),
                alive: alive.clone(),
            });
            demux
                .deliver(&config, 0, &packet.slice(40..41), now, LIFETIME)
                .run();
            drop(packet);
            demux.assert_consistent(&config.limits);
            assert_eq!(demux.buffered(), C, "{case}");
            assert!(
                !alive.load(Ordering::SeqCst),
                "{case}: the packet is still pinned"
            );
            if !registered {
                register(&mut demux, &config, 0, now);
            }
            assert_matches!(
                poll(&mut demux, 0),
                Poll::Ready(Ok(Some(payload))) if payload[..] == [7],
                "{case}"
            );
        }
    }
}

/// Held datagrams that leave no room drop the new one before any queued datagram is evicted,
/// also when the budget's arithmetic could overflow a narrower `usize`.
#[test]
fn a_payload_crowded_out_by_held_datagrams_leaves_queues_alone() {
    let config = config(32, 4, 262_144);
    let now = Instant::now();
    let mut demux = Demux::default();
    register(&mut demux, &config, 0, now);
    deliver(&mut demux, &config, 0, 2_144, now);
    for stream in [4, 8, 12, 16] {
        deliver(&mut demux, &config, stream, 65_000, now);
    }
    assert_eq!(demux.buffered(), 262_144);
    deliver(&mut demux, &config, 0, 16_384, now);
    demux.assert_consistent(&config.limits);
    assert_eq!(demux.drops().over_budget, 1);
    assert_eq!(demux.buffered(), 262_144);
    assert_matches!(poll(&mut demux, 0), Poll::Ready(Ok(Some(payload))) if payload.len() == 2_144);
}

/// Registering a stream again starts it afresh: what was queued for it is released, from the
/// budget and from the largest-queue order alike.
#[test]
fn registering_a_stream_again_releases_its_queue() {
    let config = config(4, 4, 64 * C);
    let now = Instant::now();
    let mut demux = Demux::default();
    register(&mut demux, &config, 0, now);
    deliver(&mut demux, &config, 0, 10, now);
    deliver(&mut demux, &config, 0, 10, now);
    assert_eq!(demux.buffered(), 2 * C);
    register(&mut demux, &config, 0, now);
    demux.assert_consistent(&config.limits);
    assert_eq!(demux.buffered(), 0);
    assert!(poll(&mut demux, 0).is_pending());
}

/// Over budget the largest queue gives up its oldest datagram, so a stalled consumer pays and
/// a small, healthy queue keeps what it has, whatever the order of registration.
#[test]
fn the_largest_queue_makes_room() {
    for stalled in [0, 4] {
        let healthy = 4 - stalled;
        let config = config(8, 4, 4 * C);
        let now = Instant::now();
        let mut demux = Demux::default();
        for stream in [0, 4, 8] {
            register(&mut demux, &config, stream, now);
        }
        deliver(&mut demux, &config, healthy, 10, now);
        for len in [11, 12, 13] {
            deliver(&mut demux, &config, stalled, len, now);
        }
        assert_eq!(demux.buffered(), 4 * C);
        deliver(&mut demux, &config, 8, 20, now);
        demux.assert_consistent(&config.limits);
        assert_eq!(demux.slot_dropped(healthy), 0, "stalled={stalled}");
        assert_eq!(demux.slot_dropped(stalled), 1, "stalled={stalled}");
        assert_matches!(poll(&mut demux, healthy), Poll::Ready(Ok(Some(payload))) if payload.len() == 10);
        // The stalled queue lost its oldest.
        assert_matches!(poll(&mut demux, stalled), Poll::Ready(Ok(Some(payload))) if payload.len() == 12);
    }
}

/// Streams finish in the batches the driver takes: one finished while a batch drains waits
/// for the next, since its datagrams from before its end may lie beyond that batch's count.
#[test]
fn a_stream_finished_during_a_drain_ends_with_the_next_batch() {
    let config = config(4, 4, 64 * C);
    let now = Instant::now();
    let mut demux = Demux::default();
    register(&mut demux, &config, 0, now);
    register(&mut demux, &config, 4, now);
    let cx = Context::from_waker(Waker::noop());

    assert!(demux.finish_after_received(0).0);
    let first = demux.take_finishing();
    // Stream 4 ends during that drain; its datagram from before that end is filed later.
    assert!(demux.finish_after_received(4).0);
    deliver(&mut demux, &config, 4, C, now);
    let _wakers = demux.finish_received(first);
    assert!(demux.poll_finished(0, &cx).is_ready());
    assert!(demux.poll_finished(4, &cx).is_pending());
    assert_matches!(poll(&mut demux, 0), Poll::Ready(Ok(None)));

    let second = demux.take_finishing();
    let _wakers = demux.finish_received(second);
    assert!(demux.poll_finished(4, &cx).is_ready());
    assert_matches!(poll(&mut demux, 4), Poll::Ready(Ok(Some(payload))) if payload.len() == C);
    assert_matches!(poll(&mut demux, 4), Poll::Ready(Ok(None)));
    demux.assert_consistent(&config.limits);
}

#[test]
fn only_a_drained_close_preserves_observed_fins() {
    for drained in [false, true] {
        let config = config(4, 4, 64 * C);
        let now = Instant::now();
        let mut demux = Demux::default();
        let cx = Context::from_waker(Waker::noop());
        for stream in [0, 4, 8, 12] {
            register(&mut demux, &config, stream, now);
            deliver(&mut demux, &config, stream, C, now);
        }
        assert!(demux.finish_after_received(0).0);
        // A batch taken then cancelled, a pending batch, a later FIN, and no FIN.
        assert_eq!(demux.take_finishing(), [0]);
        assert!(demux.poll_finished(0, &cx).is_pending());
        assert!(demux.finish_after_received(4).0);
        let _wakers = if drained {
            demux.close_drained()
        } else {
            demux.close()
        };
        assert!(!demux.finish_after_received(8).0);
        for stream in [0, 4, 8, 12] {
            assert!(demux.poll_finished(stream, &cx).is_ready());
            assert_matches!(poll(&mut demux, stream), Poll::Ready(Ok(Some(payload))) if payload.len() == C);
            let end = if drained && stream != 12 {
                Ok(None)
            } else {
                Err(NativeRecvError::Lost)
            };
            assert_eq!(
                poll(&mut demux, stream),
                Poll::Ready(end),
                "drained={drained}, stream={stream}"
            );
        }
        // A later cleanup/drop must neither invent a drain nor undo one.
        let _wakers = demux.close_drained();
        assert_eq!(
            poll(&mut demux, 8),
            Poll::Ready(if drained {
                Ok(None)
            } else {
                Err(NativeRecvError::Lost)
            })
        );
        demux.assert_consistent(&config.limits);
    }
}
