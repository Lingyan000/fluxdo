//! Admission accounting for received packets queued towards connection drivers.
//!
//! Control messages never take this path: the endpoint applies them directly to a
//! connection's engine (see the lock-order note in `driver::connection`), so only packets
//! are ever queued, and every queued packet holds a [`PacketPermit`].

use std::{
    collections::VecDeque,
    sync::Arc,
    task::{Context, Poll, Waker},
};

use parking_lot::Mutex;

use crate::proto::ReceiveQueueLimits;

/// Bytes charged per queued message on top of its packet bytes.
///
/// Covers the queued message itself, the shared-buffer bookkeeping of its payload and the
/// per-slot slack of the channel that carries it; a unit test checks the message size.
pub(crate) const PACKET_OVERHEAD: usize = 512;

/// Bytes charged for a queued incoming connection attempt instead of [`PACKET_OVERHEAD`].
///
/// The decoded Initial (header, token, addresses) and its packet-protection keys outlive the
/// datagram. The struct size is checked by a unit test; the heap key material is a
/// conservative estimate rather than a measured bound.
pub(crate) const INCOMING_OVERHEAD: usize = 2048;

/// Occupancy and drop counters of a queue of received packets.
///
/// One snapshot of the counters as they stood when it was taken; they keep moving afterwards.
/// The two peaks are high-water marks since the queue was made and never fall.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
#[non_exhaustive]
pub struct PacketQueueStats {
    /// Datagrams waiting to be taken.
    pub queued_datagrams: usize,
    /// Charged retained payload capacity plus per-packet bookkeeping overhead; the overhead is
    /// an estimate.
    pub queued_bytes: usize,
    /// The most datagrams that have waited at once.
    pub peak_datagrams: usize,
    /// The largest charge that has stood at once, in bytes.
    pub peak_bytes: usize,
    /// Datagrams refused since the queue was made, because taking one would have passed either
    /// limit.
    pub dropped_datagrams: u64,
}

/// A shared, bounded budget of queued packets.
#[derive(Debug, Clone)]
pub(crate) struct PacketBudget(Arc<Mutex<State>>);

#[derive(Debug)]
struct State {
    limits: ReceiveQueueLimits,
    stats: PacketQueueStats,
}

impl PacketBudget {
    pub(crate) fn new(limits: ReceiveQueueLimits) -> Self {
        Self(Arc::new(Mutex::new(State {
            limits,
            stats: PacketQueueStats::default(),
        })))
    }

    #[cfg(all(
        test,
        any(
            feature = "boring",
            all(feature = "rustls", any(feature = "aws-lc", feature = "ring"))
        )
    ))]
    pub(crate) fn limits(&self) -> ReceiveQueueLimits {
        self.0.lock().limits
    }

    pub(crate) fn stats(&self) -> PacketQueueStats {
        self.0.lock().stats
    }

    fn charge(&self, bytes: usize) -> bool {
        let mut state = self.0.lock();
        let limits = state.limits;
        let stats = &mut state.stats;
        if stats.queued_datagrams >= limits.datagrams()
            || bytes > limits.bytes().saturating_sub(stats.queued_bytes)
        {
            stats.dropped_datagrams = stats.dropped_datagrams.saturating_add(1);
            return false;
        }
        stats.queued_datagrams += 1;
        stats.queued_bytes += bytes;
        stats.peak_datagrams = stats.peak_datagrams.max(stats.queued_datagrams);
        stats.peak_bytes = stats.peak_bytes.max(stats.queued_bytes);
        true
    }

    fn release(&self, bytes: usize) {
        let mut state = self.0.lock();
        state.stats.queued_datagrams = state.stats.queued_datagrams.saturating_sub(1);
        state.stats.queued_bytes = state.stats.queued_bytes.saturating_sub(bytes);
    }

    pub(crate) fn count_drop(&self) {
        let mut state = self.0.lock();
        state.stats.dropped_datagrams = state.stats.dropped_datagrams.saturating_add(1);
    }

    /// Reserve room for one packet whose payload retains `capacity` bytes.
    ///
    /// The charge is taken before the engine parses anything, so a dropped packet costs no
    /// engine work. Returns `None`, counting a drop, when either limit is reached.
    pub(crate) fn reserve(&self, capacity: usize) -> Option<PacketPermit> {
        let Some(bytes) = capacity.checked_add(PACKET_OVERHEAD) else {
            self.count_drop();
            return None;
        };
        self.charge(bytes).then(|| PacketPermit {
            endpoint: self.clone(),
            connection: None,
            bytes,
        })
    }
}

/// Smallest storage a drained bounded container keeps, so a steady trickle does not reallocate.
pub(crate) const MIN_RETAINED: usize = 16;

/// Completed low-occupancy drain cycles before a container gives back excess storage.
pub(crate) const QUIET_DRAINS_BEFORE_SHRINK: u8 = 8;

/// A deque whose retained storage follows its use within a hard limit.
///
/// Storage is allocated lazily and grows geometrically from [`MIN_RETAINED`] entries, never
/// beyond `limit` entries. A drain is a successful [`pop_front`](Self::pop_front) that empties
/// the container. Capacity above `2 × MIN_RETAINED` shrinks only after eight consecutive drains
/// whose peak occupancy was at most one quarter of that capacity. The shrink target is the
/// larger of [`MIN_RETAINED`] and twice the last cycle's peak, capped at the entry limit. A
/// busier cycle resets the quiet-drain count, so repeated bursts retain their storage.
///
/// Empty polls and ordinary pops never shrink storage. A queue that becomes idle retains its
/// recent capacity until further drain cycles or destruction; a never-used queue allocates
/// nothing. [`clear`](Self::clear) releases all storage, and [`drain_all`](Self::drain_all) is for
/// a container being destroyed. A push that cannot get storage (limit reached, or the allocator
/// refuses) returns the item instead of panicking or growing past the limit.
#[derive(Debug)]
pub(crate) struct BoundedDeque<T> {
    items: VecDeque<T>,
    limit: usize,
    cycle_peak: usize,
    quiet_drains: u8,
}

impl<T> BoundedDeque<T> {
    pub(crate) fn new(limit: usize) -> Self {
        Self {
            items: VecDeque::new(),
            limit,
            cycle_peak: 0,
            quiet_drains: 0,
        }
    }

    pub(crate) fn push_back(&mut self, item: T) -> Result<(), T> {
        if self.items.len() >= self.limit {
            return Err(item);
        }
        // Storage refusal and the limit are both reported as the returned item.
        if self.items.len() == self.items.capacity() {
            let target = self
                .items
                .len()
                .saturating_mul(2)
                .clamp(MIN_RETAINED.min(self.limit), self.limit);
            if self
                .items
                .try_reserve_exact(target - self.items.len())
                .is_err()
            {
                return Err(item);
            }
        }
        self.items.push_back(item);
        self.cycle_peak = self.cycle_peak.max(self.items.len());

        Ok(())
    }

    pub(crate) fn pop_front(&mut self) -> Option<T> {
        let item = self.items.pop_front()?;
        if self.items.is_empty() {
            let capacity = self.items.capacity();
            if capacity > 2 * MIN_RETAINED && self.cycle_peak <= capacity / 4 {
                self.quiet_drains += 1;
                if self.quiet_drains == QUIET_DRAINS_BEFORE_SHRINK {
                    let target = MIN_RETAINED
                        .max(self.cycle_peak.saturating_mul(2))
                        .min(self.limit);
                    self.items.shrink_to(target);
                    self.quiet_drains = 0;
                }
            } else {
                self.quiet_drains = 0;
            }
            self.cycle_peak = 0;
        }

        Some(item)
    }

    pub(crate) fn front(&self) -> Option<&T> {
        self.items.front()
    }

    pub(crate) fn len(&self) -> usize {
        self.items.len()
    }

    pub(crate) fn is_empty(&self) -> bool {
        self.items.is_empty()
    }

    /// Entries the container currently retains storage for.
    pub(crate) fn capacity(&self) -> usize {
        self.items.capacity()
    }

    pub(crate) fn clear(&mut self) {
        self.items.clear();
        self.items.shrink_to(0);
        self.cycle_peak = 0;
        self.quiet_drains = 0;
    }

    /// Lower (or raise) the entry limit; a test seam for forcing storage refusal.
    #[cfg(all(
        test,
        any(
            feature = "boring",
            all(feature = "rustls", any(feature = "aws-lc", feature = "ring"))
        )
    ))]
    pub(crate) fn set_limit(&mut self, limit: usize) {
        self.limit = limit;
    }

    pub(crate) fn drain_all(&mut self) -> std::collections::vec_deque::Drain<'_, T> {
        self.cycle_peak = 0;
        self.quiet_drains = 0;
        self.items.drain(..)
    }
}

/// Create a bounded queue for `limit` entries whose storage follows use (see [`BoundedDeque`]).
pub(crate) fn bounded_queue<T>(limit: usize) -> (BoundedSender<T>, BoundedReceiver<T>) {
    let shared = Arc::new(Mutex::new(QueueState {
        items: BoundedDeque::new(limit),
        waker: None,
        sender_dropped: false,
        closed: false,
    }));
    (
        BoundedSender {
            shared: shared.clone(),
        },
        BoundedReceiver { shared },
    )
}

#[derive(Debug)]
struct QueueState<T> {
    items: BoundedDeque<T>,
    waker: Option<Waker>,
    sender_dropped: bool,
    closed: bool,
}

/// Why a [`BoundedSender::send`] handed its item back.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum Refusal {
    /// The receiver closed or was dropped; nothing will consume the queue again.
    Closed,
    /// The queue is at its limit or could not obtain storage; the receiver is still alive.
    Full,
}

/// Producer side of a [`bounded_queue`]; owned by the endpoint's connection table.
#[derive(Debug)]
pub(crate) struct BoundedSender<T> {
    shared: Arc<Mutex<QueueState<T>>>,
}

impl<T> BoundedSender<T> {
    /// Queue `item`, waking the receiver. Returns the item with the reason when the receiver
    /// closed the queue, the limit is reached, or storage could not be obtained, so the caller
    /// releases its charge and can account for the drop.
    pub(crate) fn send(&self, item: T) -> Result<(), (T, Refusal)> {
        let mut state = self.shared.lock();
        if state.closed {
            return Err((item, Refusal::Closed));
        }
        state
            .items
            .push_back(item)
            .map_err(|item| (item, Refusal::Full))?;

        let waker = state.waker.take();
        drop(state);

        if let Some(waker) = waker {
            waker.wake();
        }
        Ok(())
    }

    /// Tests can inspect the processing lock boundary without waiting on that lock.
    #[cfg(all(
        test,
        any(
            feature = "boring",
            all(feature = "rustls", any(feature = "aws-lc", feature = "ring"))
        )
    ))]
    pub(super) fn is_unlocked(&self) -> bool {
        self.shared.try_lock().is_some()
    }

    #[cfg(test)]
    /// Entries the container currently retains storage for.
    pub(crate) fn capacity(&self) -> usize {
        self.shared.lock().items.capacity()
    }
}

impl<T> Drop for BoundedSender<T> {
    fn drop(&mut self) {
        let mut state = self.shared.lock();
        state.sender_dropped = true;
        let waker = state.waker.take();
        drop(state);

        if let Some(waker) = waker {
            waker.wake();
        }
    }
}

/// Consumer side of a [`bounded_queue`]; owned by the connection driver.
#[derive(Debug)]
pub(crate) struct BoundedReceiver<T> {
    shared: Arc<Mutex<QueueState<T>>>,
}

impl<T> BoundedReceiver<T> {
    /// `Ready(None)` once the sender is gone and the queue is drained, or once this receiver
    /// closed the queue (terminal: nothing is queued after a close).
    #[expect(
        clippy::needless_pass_by_ref_mut,
        reason = "one consumer at a time is the receiver's contract, and polling takes the context by exclusive reference"
    )]
    pub(crate) fn poll_recv(&mut self, cx: &mut Context<'_>) -> Poll<Option<T>> {
        let mut state = self.shared.lock();
        if let Some(item) = state.items.pop_front() {
            return Poll::Ready(Some(item));
        }
        if state.sender_dropped || state.closed {
            return Poll::Ready(None);
        }
        state.waker = Some(cx.waker().clone());
        Poll::Pending
    }

    /// Refuse further sends and drop everything queued, releasing its charges, storage and any
    /// stored waker. Dropping the receiver does the same.
    #[expect(
        clippy::needless_pass_by_ref_mut,
        reason = "closing is the consumer's decision, so it takes the receiver exclusively"
    )]
    pub(crate) fn close(&mut self) {
        let mut state = self.shared.lock();
        state.closed = true;
        state.items.clear();
        state.waker = None;
    }

    pub(crate) fn capacity(&self) -> usize {
        self.shared.lock().items.capacity()
    }

    #[cfg(test)]
    fn len(&self) -> usize {
        self.shared.lock().items.len()
    }
}

impl<T> Drop for BoundedReceiver<T> {
    fn drop(&mut self) {
        self.close();
    }
}

/// Travels with one queued packet and releases its charge when the packet is processed,
/// dropped, or its queue is closed.
#[derive(Debug)]
pub(crate) struct PacketPermit {
    endpoint: PacketBudget,
    connection: Option<PacketBudget>,
    bytes: usize,
}

impl PacketPermit {
    /// Additionally charge the owning connection's budget.
    ///
    /// On refusal the permit is returned so the caller can drop it (releasing the endpoint
    /// share) after counting; the connection budget records the drop.
    pub(crate) fn for_connection(mut self, connection: &PacketBudget) -> Result<Self, Self> {
        debug_assert!(self.connection.is_none(), "permit already assigned");
        if connection.charge(self.bytes) {
            self.connection = Some(connection.clone());
            Ok(self)
        } else {
            Err(self)
        }
    }

    #[cfg(test)]
    pub(crate) fn bytes(&self) -> usize {
        self.bytes
    }

    /// Charge `extra` more bytes on the endpoint budget for a packet that turned out to
    /// retain more than its datagram. Refused when the budget cannot take it.
    pub(crate) fn widen(&mut self, extra: usize) -> bool {
        debug_assert!(
            self.connection.is_none(),
            "only endpoint-level permits widen"
        );
        let mut state = self.endpoint.0.lock();
        let limits = state.limits;
        let stats = &mut state.stats;
        if extra > limits.bytes().saturating_sub(stats.queued_bytes) {
            stats.dropped_datagrams = stats.dropped_datagrams.saturating_add(1);
            return false;
        }
        stats.queued_bytes += extra;
        stats.peak_bytes = stats.peak_bytes.max(stats.queued_bytes);
        drop(state);
        self.bytes += extra;
        true
    }
}

impl Drop for PacketPermit {
    fn drop(&mut self) {
        self.endpoint.release(self.bytes);
        if let Some(connection) = &self.connection {
            connection.release(self.bytes);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use rama_utils::octets;
    use std::assert_matches;

    fn budget(datagrams: usize, bytes: usize) -> PacketBudget {
        PacketBudget::new(ReceiveQueueLimits::new(datagrams, bytes).unwrap())
    }

    #[test]
    fn empty_packets_consume_entries_and_overhead() {
        let budget = budget(2, 2 * PACKET_OVERHEAD);
        let first = budget.reserve(0).unwrap();
        let second = budget.reserve(0).unwrap();
        assert!(budget.reserve(0).is_none());
        assert_eq!(budget.stats().queued_bytes, 2 * PACKET_OVERHEAD);
        assert_eq!(budget.stats().dropped_datagrams, 1);
        drop(first);
        drop(second);
        let stats = budget.stats();
        assert_eq!((stats.queued_datagrams, stats.queued_bytes), (0, 0));
        assert_eq!(
            (stats.peak_datagrams, stats.peak_bytes),
            (2, 2 * PACKET_OVERHEAD)
        );
    }

    #[test]
    fn bytes_and_entries_each_enforce_their_limit() {
        let bytes = budget(10, PACKET_OVERHEAD + 1200);
        let packet = bytes.reserve(1200).unwrap();
        assert_eq!(packet.bytes(), PACKET_OVERHEAD + 1200);
        assert!(bytes.reserve(1).is_none());
        drop(packet);
        assert!(bytes.reserve(1201).is_none());
        assert!(
            bytes.reserve(usize::MAX).is_none(),
            "overflowing charge is refused"
        );
        assert_eq!(bytes.stats().queued_bytes, 0);
        assert_eq!(bytes.stats().dropped_datagrams, 3);
        let entries = budget(1, octets::mib(1));
        let _packet = entries.reserve(1).unwrap();
        assert!(entries.reserve(1).is_none());
    }

    #[test]
    fn busy_connection_cannot_consume_another_connections_share() {
        let endpoint = budget(3, 3 * (PACKET_OVERHEAD + 1200));
        let first = budget(1, 10_000);
        let second = budget(2, 10_000);
        let packet = endpoint
            .reserve(1200)
            .unwrap()
            .for_connection(&first)
            .unwrap();
        let refused = endpoint
            .reserve(1200)
            .unwrap()
            .for_connection(&first)
            .unwrap_err();
        assert_eq!(endpoint.stats().queued_datagrams, 2);
        drop(refused);
        assert_eq!(endpoint.stats().queued_datagrams, 1);
        assert_eq!(first.stats().dropped_datagrams, 1);
        let other = endpoint
            .reserve(1200)
            .unwrap()
            .for_connection(&second)
            .unwrap();
        drop(packet);
        assert_eq!(first.stats().queued_bytes, 0);
        assert_eq!(endpoint.stats().queued_datagrams, 1);
        drop(other);
        assert_eq!(second.stats().queued_bytes, 0);
        assert_eq!(endpoint.stats().queued_bytes, 0);
    }

    #[test]
    fn shared_budget_is_never_exceeded_under_contention() {
        let endpoint = budget(3, 3 * (PACKET_OVERHEAD + 1200));
        let threads: Vec<_> = (0..8)
            .map(|_| {
                let endpoint = endpoint.clone();
                std::thread::spawn(move || {
                    let connection = budget(1, 10_000);
                    for _ in 0..1000 {
                        if let Some(permit) = endpoint.reserve(1200) {
                            let _permit = permit.for_connection(&connection).unwrap();
                            let stats = endpoint.stats();
                            assert!(stats.queued_datagrams <= 3);
                            assert!(stats.queued_bytes <= 3 * (PACKET_OVERHEAD + 1200));
                        }
                    }
                })
            })
            .collect();
        for thread in threads {
            thread.join().unwrap();
        }
        assert_eq!(endpoint.stats().queued_bytes, 0);
        assert_eq!(endpoint.stats().queued_datagrams, 0);
    }

    #[test]
    fn bounded_queue_storage_follows_use_within_the_limit() {
        let (sender, mut receiver) = bounded_queue::<u64>(256);
        assert_eq!(sender.capacity(), 0, "an idle queue allocates nothing");
        let mut cx = Context::from_waker(Waker::noop());
        sender.send(1).unwrap();
        assert_eq!(sender.capacity(), MIN_RETAINED, "first growth step");
        for i in 2..=40 {
            sender.send(i).unwrap();
        }
        assert!(
            sender.capacity() <= 64 && sender.capacity() >= 40,
            "{}",
            sender.capacity()
        );
        for i in 41..=256 {
            sender.send(i).unwrap();
        }
        assert_eq!(sender.capacity(), 256, "growth is capped at the limit");
        assert_eq!(
            sender.send(u64::MAX),
            Err((u64::MAX, Refusal::Full)),
            "no entry beyond the limit"
        );
        for i in 1..=255 {
            assert_eq!(receiver.poll_recv(&mut cx), Poll::Ready(Some(i)));
            assert_eq!(receiver.capacity(), 256, "ordinary pops do not shrink");
        }
        assert_eq!(receiver.poll_recv(&mut cx), Poll::Ready(Some(256)));
        assert_eq!(receiver.capacity(), 256, "a burst keeps its capacity");
        assert!(receiver.poll_recv(&mut cx).is_pending());
        for round in 1..=QUIET_DRAINS_BEFORE_SHRINK {
            sender.send(1).unwrap();
            assert_eq!(receiver.poll_recv(&mut cx), Poll::Ready(Some(1)));
            assert_eq!(
                receiver.capacity(),
                if round < QUIET_DRAINS_BEFORE_SHRINK {
                    256
                } else {
                    MIN_RETAINED
                }
            );
        }
        // Small storage remains reusable across subsequent trickles.
        for i in 1..=17 {
            sender.send(i).unwrap();
        }
        while receiver.poll_recv(&mut cx).is_ready() {}
        sender.send(1).unwrap();
        assert_eq!(receiver.capacity(), 2 * MIN_RETAINED);
    }

    #[test]
    fn bounded_queue_storage_never_exceeds_small_or_odd_limits() {
        for limit in [1usize, 3, 15, 16, 17, 33] {
            let (sender, mut receiver) = bounded_queue::<usize>(limit);
            let mut cx = Context::from_waker(Waker::noop());
            for round in 0..3 {
                for i in 0..limit {
                    sender.send(i).unwrap();
                    assert!(
                        receiver.capacity() <= limit,
                        "limit {limit} round {round}: capacity {}",
                        receiver.capacity()
                    );
                }
                assert_eq!(sender.send(usize::MAX), Err((usize::MAX, Refusal::Full)));
                while receiver.poll_recv(&mut cx).is_ready() {}
                assert!(
                    receiver.capacity() <= limit,
                    "limit {limit}: drained baseline {}",
                    receiver.capacity()
                );
            }

            for _ in 0..QUIET_DRAINS_BEFORE_SHRINK {
                sender.send(1).unwrap();
                assert_eq!(receiver.poll_recv(&mut cx), Poll::Ready(Some(1)));
                assert!(receiver.capacity() <= limit);
            }
            assert!(receiver.capacity() <= limit.min(2 * MIN_RETAINED));
        }
    }

    #[test]
    fn dropping_the_receiver_releases_items_refuses_sends_and_drops_the_waker() {
        #[derive(Debug)]
        struct Tracked(Arc<std::sync::atomic::AtomicUsize>);

        impl Drop for Tracked {
            fn drop(&mut self) {
                self.0.fetch_sub(1, std::sync::atomic::Ordering::Relaxed);
            }
        }
        struct CountWake(std::sync::atomic::AtomicUsize);

        impl std::task::Wake for CountWake {
            fn wake(self: Arc<Self>) {
                self.0.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
            }
        }
        let live = Arc::new(std::sync::atomic::AtomicUsize::new(0));
        let make = || {
            live.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
            Tracked(live.clone())
        };
        let (sender, receiver) = bounded_queue(4);
        sender.send(make()).unwrap();
        sender.send(make()).unwrap();
        assert_eq!(live.load(std::sync::atomic::Ordering::Relaxed), 2);
        drop(receiver);
        assert_eq!(
            live.load(std::sync::atomic::Ordering::Relaxed),
            0,
            "dropping the receiver releases every queued item"
        );
        match sender.send(make()) {
            Err((item, Refusal::Closed)) => drop(item),
            other => panic!("{other:?}"),
        }
        assert_eq!(live.load(std::sync::atomic::Ordering::Relaxed), 0);
        assert_eq!(sender.capacity(), 0, "no storage survives the receiver");

        // A receiver that is still waiting (waker stored, nothing ever sent) releases the
        // stored waker when it is dropped while the sender lives on.
        let (sender, mut receiver) = bounded_queue::<u8>(4);
        let wake = Arc::new(CountWake(std::sync::atomic::AtomicUsize::new(0)));
        let waker = Waker::from(wake.clone());
        assert!(
            receiver
                .poll_recv(&mut Context::from_waker(&waker))
                .is_pending()
        );
        // The local waker plus the receiver's stored clone.
        assert_eq!(Arc::strong_count(&wake), 3, "the receiver stores the waker");
        drop(receiver);
        assert_eq!(
            Arc::strong_count(&wake),
            2,
            "the stored waker is released with the receiver, without a wake"
        );
        assert_eq!(wake.0.load(std::sync::atomic::Ordering::Relaxed), 0);
        assert_eq!(sender.send(2), Err((2, Refusal::Closed)));

        // Explicit close is terminal for the receiver even while the sender lives.
        let (sender, mut receiver) = bounded_queue::<u8>(4);
        sender.send(1).unwrap();
        receiver.close();
        assert_eq!(
            receiver.poll_recv(&mut Context::from_waker(&waker)),
            Poll::Ready(None)
        );
        assert_eq!(sender.send(2), Err((2, Refusal::Closed)));
    }

    #[test]
    fn dropping_the_receiver_releases_endpoint_and_connection_charges() {
        let endpoint = budget(8, 8 * (PACKET_OVERHEAD + 100));
        let connection = budget(4, 4 * (PACKET_OVERHEAD + 100));
        let (sender, receiver) = bounded_queue::<PacketPermit>(4);
        for _ in 0..3 {
            let permit = endpoint
                .reserve(100)
                .unwrap()
                .for_connection(&connection)
                .ok()
                .unwrap();
            sender.send(permit).unwrap();
        }
        assert_eq!(endpoint.stats().queued_datagrams, 3);
        assert_eq!(connection.stats().queued_datagrams, 3);
        assert_eq!(connection.stats().queued_bytes, 3 * (PACKET_OVERHEAD + 100));
        drop(receiver);
        assert_eq!(endpoint.stats().queued_datagrams, 0);
        assert_eq!(endpoint.stats().queued_bytes, 0);
        assert_eq!(connection.stats().queued_datagrams, 0);
        assert_eq!(connection.stats().queued_bytes, 0);
        assert_eq!(
            endpoint.stats().dropped_datagrams + connection.stats().dropped_datagrams,
            0,
            "releasing on destruction is not a receive drop"
        );
        // A late packet is refused and its charge released by the caller dropping it.
        let permit = endpoint.reserve(100).unwrap();
        assert_matches!(sender.send(permit), Err((_, Refusal::Closed)));
        assert_eq!(endpoint.stats().queued_datagrams, 0);
    }

    #[test]
    fn bounded_deque_keeps_small_storage_when_drained() {
        let mut queue = BoundedDeque::<u32>::new(1024);
        for i in 0..17 {
            queue.push_back(i).expect("the queue takes it");
        }
        assert_eq!(
            queue.capacity(),
            32,
            "one item past MIN_RETAINED doubles it"
        );
        while queue.pop_front().is_some() {}
        assert_eq!(
            queue.capacity(),
            32,
            "storage at or below 2 × MIN_RETAINED is retained across a drain"
        );
        queue.push_back(0).expect("the queue takes it");
        assert_eq!(queue.capacity(), 32, "no growth while storage remains");
        queue.clear();
        for i in 0..33 {
            queue.push_back(i).expect("the queue takes it");
        }
        assert_eq!(queue.capacity(), 64);
        while queue.pop_front().is_some() {}
        assert_eq!(
            queue.capacity(),
            64,
            "a busy drain keeps larger storage too"
        );
    }

    fn burst(queue: &mut BoundedDeque<usize>, count: usize) {
        for i in 0..count {
            queue.push_back(i).unwrap();
        }
        for i in 0..count {
            assert_eq!(queue.pop_front(), Some(i));
        }
    }

    #[test]
    fn repeated_busy_bursts_keep_storage_without_empty_polls_trimming_it() {
        for size in [64, 128] {
            let mut queue = BoundedDeque::new(256);
            for _ in 0..16 {
                burst(&mut queue, size);
                assert_eq!(queue.capacity(), size);
                for _ in 0..16 {
                    assert_eq!(queue.pop_front(), None);
                    assert_eq!(queue.capacity(), size);
                }
            }
        }
    }

    #[test]
    fn only_eight_completed_quiet_cycles_shrink_storage() {
        let mut queue = BoundedDeque::new(256);
        burst(&mut queue, 128);
        for _ in 1..QUIET_DRAINS_BEFORE_SHRINK {
            burst(&mut queue, 32);
            assert_eq!(queue.capacity(), 128);
        }
        // Empty observations do not count as drain cycles.
        for _ in 0..32 {
            assert_eq!(queue.pop_front(), None);
            assert_eq!(queue.capacity(), 128);
        }
        // The eighth quiet cycle is counted on its final pop, not its first.
        queue.push_back(1).unwrap();
        queue.push_back(2).unwrap();
        assert_eq!(queue.pop_front(), Some(1));
        assert_eq!(queue.capacity(), 128);
        assert_eq!(queue.pop_front(), Some(2));
        assert_eq!(queue.capacity(), MIN_RETAINED);
    }

    #[test]
    fn shrink_target_tracks_quiet_peak_and_busy_cycles_cancel_quiet_history() {
        let mut queue = BoundedDeque::new(256);
        burst(&mut queue, 128);
        for _ in 1..QUIET_DRAINS_BEFORE_SHRINK {
            burst(&mut queue, 32);
        }
        // One above the quiet threshold resets the run of quiet cycles.
        burst(&mut queue, 33);
        for _ in 1..QUIET_DRAINS_BEFORE_SHRINK {
            burst(&mut queue, 32);
            assert_eq!(queue.capacity(), 128);
        }
        burst(&mut queue, 32);
        assert_eq!(queue.capacity(), 64, "twice the final quiet peak");
        for _ in 0..QUIET_DRAINS_BEFORE_SHRINK {
            burst(&mut queue, 16);
        }
        assert_eq!(queue.capacity(), 32);
        for _ in 0..16 {
            burst(&mut queue, 1);
        }
        assert_eq!(queue.capacity(), 32, "the small baseline remains reusable");
        queue.clear();
        assert_eq!(queue.capacity(), 0);
        burst(&mut queue, 128);
        burst(&mut queue, 1);
        assert_eq!(queue.capacity(), 128, "clear resets the quiet history");
    }

    #[test]
    fn sender_wakes_after_releasing_the_queue_lock() {
        use std::sync::atomic::{AtomicUsize, Ordering};

        struct InspectWake {
            queue: std::sync::Weak<Mutex<QueueState<u8>>>,
            wakes: AtomicUsize,
        }

        impl std::task::Wake for InspectWake {
            fn wake(self: Arc<Self>) {
                let shared = self.queue.upgrade().unwrap();
                let state = shared
                    .try_lock()
                    .expect("wake must run outside the queue lock");
                assert!(state.waker.is_none(), "the stored waker was taken");
                assert_eq!(state.items.len(), usize::from(!state.sender_dropped));
                self.wakes.fetch_add(1, Ordering::Relaxed);
            }
        }

        let (sender, mut receiver) = bounded_queue(4);
        let wake = Arc::new(InspectWake {
            queue: Arc::downgrade(&receiver.shared),
            wakes: AtomicUsize::new(0),
        });
        let waker = Waker::from(wake.clone());
        let mut cx = Context::from_waker(&waker);
        assert!(receiver.poll_recv(&mut cx).is_pending());
        sender.send(1).unwrap();
        assert_eq!(wake.wakes.load(Ordering::Relaxed), 1);
        assert_eq!(receiver.poll_recv(&mut cx), Poll::Ready(Some(1)));
        assert!(receiver.poll_recv(&mut cx).is_pending());
        drop(sender);
        assert_eq!(wake.wakes.load(Ordering::Relaxed), 2);
        assert_eq!(receiver.poll_recv(&mut cx), Poll::Ready(None));
    }

    #[test]
    fn bounded_deque_refuses_when_it_cannot_grow() {
        let mut small = BoundedDeque::<u8>::new(3);
        small.push_back(1).expect("the queue takes it");
        assert_eq!(
            small.capacity(),
            3,
            "growth never exceeds a limit below the minimum"
        );
        small.push_back(2).expect("the queue takes it");
        small.push_back(3).expect("the queue takes it");
        assert_eq!(small.push_back(4), Err(4));
        // A limit whose storage cannot exist is refused by the allocator, not a panic.
        let mut huge = BoundedDeque::<[u8; 1024]>::new(usize::MAX);
        huge.push_back([0; 1024]).expect("the first step is small");
        assert_eq!(huge.capacity(), MIN_RETAINED);
        let mut zero = BoundedDeque::<u8>::new(0);
        assert_eq!(zero.push_back(7), Err(7));
        assert_eq!(zero.capacity(), 0);
    }

    #[test]
    fn many_sparse_queues_retain_only_what_they_used() {
        let queues: Vec<_> = (0..1000).map(|_| bounded_queue::<[u8; 96]>(256)).collect();
        assert_eq!(
            queues.iter().map(|(s, _)| s.capacity()).sum::<usize>(),
            0,
            "idle connections retain no queue storage"
        );
        for (sender, _) in &queues {
            sender.send([0; 96]).unwrap();
        }
        assert_eq!(
            queues.iter().map(|(s, _)| s.capacity()).sum::<usize>(),
            1000 * MIN_RETAINED,
            "one packet each retains the minimum step, not the limit"
        );
    }

    #[test]
    fn closing_or_dropping_a_bounded_queue_releases_its_items_and_wakes() {
        #[derive(Debug)]
        struct Tracked(Arc<std::sync::atomic::AtomicUsize>);

        impl Drop for Tracked {
            fn drop(&mut self) {
                self.0.fetch_sub(1, std::sync::atomic::Ordering::Relaxed);
            }
        }
        let live = Arc::new(std::sync::atomic::AtomicUsize::new(0));
        let make = || {
            live.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
            Tracked(live.clone())
        };
        let (sender, mut receiver) = bounded_queue(3);
        sender.send(make()).unwrap();
        sender.send(make()).unwrap();
        assert_eq!(live.load(std::sync::atomic::Ordering::Relaxed), 2);
        receiver.close();
        assert_eq!(
            live.load(std::sync::atomic::Ordering::Relaxed),
            0,
            "close releases queued items"
        );
        assert_eq!(receiver.capacity(), 0, "close releases the storage");
        match sender.send(make()) {
            Err((item, Refusal::Closed)) => drop(item),
            other => panic!("{other:?}"),
        }
        assert_eq!(
            live.load(std::sync::atomic::Ordering::Relaxed),
            0,
            "a refused item is returned and released"
        );

        struct CountWake(std::sync::atomic::AtomicUsize);

        impl std::task::Wake for CountWake {
            fn wake(self: Arc<Self>) {
                self.0.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
            }
        }
        let (sender, mut receiver) = bounded_queue::<u8>(1);
        let wake = Arc::new(CountWake(std::sync::atomic::AtomicUsize::new(0)));
        let waker = Waker::from(wake.clone());
        assert!(
            receiver
                .poll_recv(&mut Context::from_waker(&waker))
                .is_pending()
        );
        drop(sender);
        assert_eq!(wake.0.load(std::sync::atomic::Ordering::Relaxed), 1);
        assert_eq!(
            receiver.poll_recv(&mut Context::from_waker(&waker)),
            Poll::Ready(None)
        );
        assert_eq!(receiver.len(), 0);
    }

    #[test]
    fn charged_overhead_covers_queued_message_storage() {
        // Message plus the channel's per-slot bookkeeping; the payload bytes are charged apart.
        let packet = std::mem::size_of::<crate::driver::QueuedPacket>();
        let incoming = std::mem::size_of::<crate::driver::endpoint::QueuedIncoming>();
        assert!(
            packet + 128 <= PACKET_OVERHEAD,
            "queued packet is {packet} bytes"
        );
        assert!(
            incoming + 128 <= INCOMING_OVERHEAD / 2,
            "queued incoming is {incoming} bytes"
        );
    }

    #[test]
    fn widening_charges_the_endpoint_budget_and_is_refused_at_the_limit() {
        let budget = budget(4, INCOMING_OVERHEAD + 100);
        let mut permit = budget.reserve(100).unwrap();
        assert!(permit.widen(INCOMING_OVERHEAD - PACKET_OVERHEAD));
        assert_eq!(permit.bytes(), INCOMING_OVERHEAD + 100);
        assert_eq!(budget.stats().queued_bytes, INCOMING_OVERHEAD + 100);
        assert!(!permit.widen(1));
        assert_eq!(budget.stats().dropped_datagrams, 1);
        assert_eq!(
            permit.bytes(),
            INCOMING_OVERHEAD + 100,
            "a refused widen changes nothing"
        );
        drop(permit);
        assert_eq!(budget.stats().queued_bytes, 0);
    }
}
