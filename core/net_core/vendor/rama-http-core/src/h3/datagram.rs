//! HTTP/3 datagram association and demultiplexing (RFC 9297 §2.1).
//!
//! The connection driver is the only reader of QUIC DATAGRAM frames. It splits the Quarter
//! Stream ID prefix (sharing the frame's storage) and files each payload under its request
//! stream. Every request stream is registered while datagrams are enabled, so the driver
//! alone decides, without any application poll, whether a datagram is queued, dropped or a
//! violation of the request's datagram semantics.

use super::{
    Error,
    connection::Shared,
    qlog,
    transport::{self, BoxedStreamHandle, SendDatagramError},
};
use ahash::HashMap;
use pin_project_lite::pin_project;
use rama_core::bytes::{BufMut as _, Bytes, BytesMut};
use rama_http::datagram::{
    NativeDatagramChannel, NativeRecvError, NativeSendError, NativeSendPolicy, NativeSendReady,
    ViolationPolicy,
};
use rama_http_types::proto::h3::{Code, QuarterStreamId};
use rama_quic_proto::{Dir, Side, StreamId, VarInt};
use rama_utils::octets::kib;
use std::{
    collections::{BTreeSet, VecDeque},
    future::Future,
    pin::Pin,
    sync::{
        Arc,
        atomic::{AtomicBool, Ordering},
    },
    task::{Context, Poll, Waker},
    time::Duration,
};
use tokio::{
    sync::{Notify, futures::OwnedNotified},
    time::Instant,
};

/// HTTP/3 datagram support of a connection.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct DatagramConfig {
    /// Buffering budgets for received datagrams.
    pub limits: DatagramLimits,
    /// Reaction to peer violations of the datagram rules that do not affect framing.
    ///
    /// [`ViolationPolicy::Ignore`] (default) drops and counts: a datagram for a request
    /// without datagram semantics, an invalid Quarter Stream ID, or one beyond the client
    /// bidirectional stream limit. [`ViolationPolicy::Reject`] aborts the request with
    /// `H3_DATAGRAM_ERROR`, or closes the connection with `H3_DATAGRAM_ERROR` and
    /// `H3_ID_ERROR` respectively (RFC 9297 §2, §2.1).
    pub violations: ViolationPolicy,
}

/// Buffering budgets for received HTTP/3 datagrams. A zero `queue_len`, `pending_len` or
/// `max_buffered_bytes` drops (and counts) every datagram it would hold. The request semantics
/// are enforced regardless.
///
/// A registration lives as long as its request stream or a retained carrier handle of it
/// ([`NativeDatagrams`](rama_http::datagram::NativeDatagrams)): the peer's bidirectional stream
/// limit bounds those of live streams, idle datagram sessions included, while an application
/// that keeps a carrier handle after its tunnel ended keeps its registration until it drops it.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct DatagramLimits {
    /// Datagrams queued per request; the oldest is discarded when it is full.
    pub queue_len: usize,
    /// Datagrams held briefly for request streams that do not exist yet.
    pub pending_len: usize,
    /// Bytes buffered per connection across all requests. A buffered datagram owns just its
    /// payload, charged its length but at least [`MIN_DATAGRAM_CHARGE`].
    pub max_buffered_bytes: usize,
}

impl Default for DatagramLimits {
    fn default() -> Self {
        Self {
            queue_len: 32,
            pending_len: 16,
            max_buffered_bytes: kib(256),
        }
    }
}

/// Received HTTP/3 datagrams a connection discarded, by reason.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
#[non_exhaustive]
pub struct DatagramDrops {
    /// For a request without datagram semantics.
    pub no_semantics: u64,
    /// With a truncated or out-of-range Quarter Stream ID.
    pub invalid_id: u64,
    /// For a stream beyond the client bidirectional stream limit.
    pub beyond_limit: u64,
    /// For a stream that was released (or never used).
    pub unknown_stream: u64,
    /// After the request's receive side, its consumer or the connection ended.
    pub receive_closed: u64,
    /// Displaced from a full request queue.
    pub queue_full: u64,
    /// Over the connection's buffered byte budget.
    pub over_budget: u64,
    /// Held for a future stream that did not appear in time.
    pub expired: u64,
    /// Received while this endpoint did not advertise `SETTINGS_H3_DATAGRAM`.
    pub unadvertised: u64,
}

/// Pending datagrams wait "on the order of a round trip" (RFC 9297 §2.1); this floor keeps
/// very short RTT estimates from discarding datagrams that merely beat their HEADERS.
const PENDING_LIFETIME_FLOOR: Duration = Duration::from_millis(100);
const PENDING_LIFETIME_RTTS: u32 = 3;

/// Whether a request has datagram semantics (RFC 9297 §2).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum Semantics {
    /// A server's Extended CONNECT awaiting its response; datagrams are held.
    Provisional,
    /// Declared with [`HttpDatagrams`](rama_http_types::proto::ext::HttpDatagrams).
    Claimed,
    /// Datagrams for it are violations.
    None,
}

/// How a request's receive side ended.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum ReceiveEnd {
    /// The peer finished the stream.
    Finished,
    /// The peer reset the stream with this code.
    Reset(u64),
    /// This endpoint aborted the stream with this code.
    Aborted(u64),
    /// Nobody consumes its datagrams any more.
    Released,
}

/// Aborts a request that violated its datagram semantics.
pub(crate) trait AbortRequest: Clone {
    fn abort_request(&self);
}

impl AbortRequest for BoxedStreamHandle {
    fn abort_request(&self) {
        self.abort(VarInt::from_u32(Code::H3_DATAGRAM_ERROR.value() as u32));
    }
}

/// The smallest packet every QUIC path carries (RFC 9000 §14): what a buffered datagram is
/// charged at least, so tiny datagrams cannot fill the budget's queues for free.
pub const MIN_DATAGRAM_CHARGE: usize = 1200;

/// What a buffered datagram costs the connection's budget.
fn charge(payload: &Bytes) -> usize {
    payload.len().max(MIN_DATAGRAM_CHARGE)
}

/// Keep the non-empty queues' index in step with a queue's charges going from `before` to
/// `after`.
fn reindex(index: &mut BTreeSet<(usize, u64)>, stream: u64, before: usize, after: usize) {
    if before != after {
        if before != 0 {
            index.remove(&(before, stream));
        }
        if after != 0 {
            index.insert((after, stream));
        }
    }
}

/// A received payload shares its packet's allocation, up to the endpoint's receive limit
/// (64 KiB): a buffered copy keeps only its own bytes alive, so its charge bounds them.
fn compact(payload: &Bytes) -> Bytes {
    Bytes::copy_from_slice(payload)
}

struct Slot<A> {
    semantics: Semantics,
    queue: VecDeque<Bytes>,
    // Charges of `queue`, so an over-budget admission can find the largest queue.
    bytes: usize,
    waker: Option<Waker>,
    dropped: u64,
    receive: Option<ReceiveEnd>,
    // A FIN observed by the reader, including while its drain batch is in flight.
    finishing: bool,
    // The stream reader waiting for its finished receive side, see `poll_finished`.
    finish_waker: Option<Waker>,
    // Set by every datagram routed here before the semantics are final, even one discarded.
    observed: bool,
    abort: A,
    violated: Arc<AtomicBool>,
}

struct Pending {
    stream: u64,
    payload: Bytes,
    expires: Instant,
}

/// Work to do once the demux lock is released.
#[must_use]
pub(crate) struct Action<A = BoxedStreamHandle> {
    wake: Option<Waker>,
    abort: Option<A>,
}

impl<A> Default for Action<A> {
    fn default() -> Self {
        Self {
            wake: None,
            abort: None,
        }
    }
}

impl<A: AbortRequest> Action<A> {
    pub(crate) fn run(self) {
        if let Some(abort) = self.abort {
            abort.abort_request();
        }
        if let Some(waker) = self.wake {
            waker.wake();
        }
    }
}

/// Connection-wide datagram routing state, guarded by one short-held lock.
pub(crate) struct Demux<A = BoxedStreamHandle> {
    slots: HashMap<u64, Slot<A>>,
    // The non-empty queues by their charges, so over budget the largest is found at once,
    // whatever the number of registered requests.
    by_bytes: BTreeSet<(usize, u64)>,
    pending: VecDeque<Pending>,
    // Charges of `pending`, part of `buffered`.
    held: usize,
    buffered: usize,
    // The lowest request stream id never registered: below it an unknown id was released.
    watermark: u64,
    drops: DatagramDrops,
    closed: bool,
    drained: bool,
    // Streams the peer finished, whose receive side ends once received datagrams are filed.
    finishing: Vec<u64>,
}

impl<A> Default for Demux<A> {
    fn default() -> Self {
        Self {
            slots: HashMap::default(),
            by_bytes: BTreeSet::new(),
            pending: VecDeque::new(),
            held: 0,
            buffered: 0,
            watermark: 0,
            drops: DatagramDrops::default(),
            closed: false,
            drained: false,
            finishing: Vec::new(),
        }
    }
}

impl<A: AbortRequest> Demux<A> {
    /// File a received payload.
    pub(crate) fn deliver(
        &mut self,
        config: &DatagramConfig,
        stream: u64,
        payload: &Bytes,
        now: Instant,
        lifetime: Duration,
    ) -> Action<A> {
        self.expire(now);
        if self.closed {
            self.drops.receive_closed += 1;
            return Action::default();
        }
        let Some(slot) = self.slots.get_mut(&stream) else {
            if stream < self.watermark {
                // RFC 9297 §2.1: a released stream's receive side is closed.
                self.drops.unknown_stream += 1;
            } else {
                self.hold(&config.limits, stream, payload, now + lifetime);
            }
            return Action::default();
        };
        if slot.receive.is_some() {
            slot.dropped += 1;
            self.drops.receive_closed += 1;
            return Action::default();
        }
        match slot.semantics {
            Semantics::None => violation(slot, config.violations, &mut self.drops),
            // A client claim can still become None on a refused response.
            Semantics::Provisional | Semantics::Claimed => {
                slot.observed = true;
                self.enqueue(&config.limits, stream, payload)
            }
        }
    }

    /// Register a request stream, adopting datagrams that arrived before it existed.
    pub(crate) fn register(
        &mut self,
        config: &DatagramConfig,
        stream: u64,
        semantics: Semantics,
        abort: A,
        violated: Arc<AtomicBool>,
        now: Instant,
    ) -> Action<A> {
        self.expire(now);
        self.watermark = self.watermark.max(stream.saturating_add(4));
        let replaced = self.slots.insert(
            stream,
            Slot {
                semantics,
                queue: VecDeque::new(),
                bytes: 0,
                waker: None,
                dropped: 0,
                receive: None,
                finishing: false,
                finish_waker: None,
                observed: false,
                abort,
                violated,
            },
        );
        if let Some(replaced) = replaced {
            self.buffered -= replaced.bytes;
            reindex(&mut self.by_bytes, stream, replaced.bytes, 0);
        }
        let mut action = Action::default();
        let mut held = Vec::new();
        let mut expired = 0;
        let mut released = 0;
        self.pending.retain(|pending| {
            let keep = pending.stream != stream;
            if !keep {
                released += charge(&pending.payload);
                // Lifetimes follow the RTT at arrival, so a later entry can expire first.
                if pending.expires > now {
                    held.push(pending.payload.clone());
                } else {
                    expired += 1;
                }
            }
            keep
        });
        self.drops.expired += expired;
        self.held -= released;
        self.buffered -= released;
        for payload in held {
            let Some(slot) = self.slots.get_mut(&stream) else {
                break;
            };
            slot.observed = true;
            let next = match slot.semantics {
                Semantics::None => violation(slot, config.violations, &mut self.drops),
                Semantics::Provisional | Semantics::Claimed => {
                    self.enqueue(&config.limits, stream, &payload)
                }
            };
            action.merge(next);
        }
        action
    }

    /// Make a request's datagram semantics final.
    pub(crate) fn decide(
        &mut self,
        config: &DatagramConfig,
        stream: u64,
        claimed: bool,
    ) -> Action<A> {
        let Some(slot) = self.slots.get_mut(&stream) else {
            return Action::default();
        };
        if claimed {
            slot.semantics = Semantics::Claimed;
            return Action::default();
        }
        slot.semantics = Semantics::None;
        self.drops.no_semantics += slot.queue.len() as u64;
        slot.queue.clear();
        let released = std::mem::take(&mut slot.bytes);
        self.buffered -= released;
        reindex(&mut self.by_bytes, stream, released, 0);
        if !slot.observed {
            return Action::default();
        }
        reject(slot, config.violations)
    }

    /// A refused Extended CONNECT: datagrams held while it was pending were sent for a request
    /// with datagram semantics, so they are dropped rather than violations; later ones are.
    pub(crate) fn refuse(&mut self, stream: u64) {
        let Some(slot) = self
            .slots
            .get_mut(&stream)
            .filter(|slot| slot.semantics == Semantics::Provisional)
        else {
            return;
        };
        slot.semantics = Semantics::None;
        self.drops.no_semantics += slot.queue.len() as u64;
        slot.queue.clear();
        let released = std::mem::take(&mut slot.bytes);
        self.buffered -= released;
        reindex(&mut self.by_bytes, stream, released, 0);
    }

    /// Release a stream and anything still buffered for it.
    pub(crate) fn unregister(&mut self, stream: u64) -> Option<Waker> {
        let slot = self.slots.remove(&stream)?;
        self.buffered -= slot.bytes;
        reindex(&mut self.by_bytes, stream, slot.bytes, 0);
        slot.waker
    }

    /// The stream's receive side or its consumer ended: later datagrams are dropped
    /// (RFC 9297 §2.1). A local end (released consumer, local abort) also discards the queue.
    pub(crate) fn receive_ended(&mut self, stream: u64, end: ReceiveEnd) -> Option<Waker> {
        let slot = self.slots.get_mut(&stream)?;
        let local = matches!(end, ReceiveEnd::Released | ReceiveEnd::Aborted(_));
        if slot.receive.is_none()
            || (local && !matches!(slot.receive, Some(ReceiveEnd::Aborted(_))))
        {
            slot.receive = Some(end);
        }
        if local {
            self.drops.receive_closed += slot.queue.len() as u64;
            slot.queue.clear();
            let released = std::mem::take(&mut slot.bytes);
            self.buffered -= released;
            reindex(&mut self.by_bytes, stream, released, 0);
        }
        slot.waker.take()
    }

    /// The peer finished `stream`. Its receive side ends at [`Self::finish_received`], once
    /// the datagrams the connection received before that end are filed: RFC 9297 §2.1 drops
    /// only later ones. Returns whether the driver must drain, and a consumer to wake
    /// when the connection already closed after draining its received datagrams.
    ///
    /// The driver takes the streams finished so far ([`Self::take_finishing`]) before it
    /// counts the received datagrams to file: a stream finished later waits for a later count.
    pub(crate) fn finish_after_received(&mut self, stream: u64) -> (bool, Option<Waker>) {
        match self.slots.get_mut(&stream) {
            Some(slot) if slot.receive.is_none() && self.closed => {
                let wake = self
                    .drained
                    .then(|| self.receive_ended(stream, ReceiveEnd::Finished))
                    .flatten();
                (false, wake)
            }
            Some(slot) if slot.receive.is_none() => {
                if !slot.finishing {
                    slot.finishing = true;
                    self.finishing.push(stream);
                }
                (true, None)
            }
            _ => (false, None),
        }
    }

    /// The streams finished since the last call.
    pub(crate) fn take_finishing(&mut self) -> Vec<u64> {
        std::mem::take(&mut self.finishing)
    }

    /// End the receive side of `streams`, from [`Self::take_finishing`].
    pub(crate) fn finish_received(&mut self, streams: Vec<u64>) -> Vec<Waker> {
        let mut wakers = Vec::new();
        for stream in streams {
            if let Some(waker) = self
                .slots
                .get_mut(&stream)
                .and_then(|slot| slot.finish_waker.take())
            {
                wakers.push(waker);
            }
            wakers.extend(self.receive_ended(stream, ReceiveEnd::Finished));
        }
        wakers
    }

    /// Ready once a stream passed to [`Self::finish_after_received`] has its receive side
    /// ended, so every datagram received before its end is queued.
    pub(crate) fn poll_finished(&mut self, stream: u64, cx: &Context<'_>) -> Poll<()> {
        if self.closed {
            return Poll::Ready(());
        }
        match self.slots.get_mut(&stream) {
            Some(slot) if slot.receive.is_none() => {
                slot.finish_waker = Some(cx.waker().clone());
                Poll::Pending
            }
            _ => Poll::Ready(()),
        }
    }

    pub(crate) fn poll_recv(
        &mut self,
        stream: u64,
        cx: &Context<'_>,
    ) -> Poll<Result<Option<Bytes>, NativeRecvError>> {
        let Some(slot) = self.slots.get_mut(&stream) else {
            return Poll::Ready(Ok(None));
        };
        if let Some(payload) = slot.queue.pop_front() {
            let before = slot.bytes;
            slot.bytes -= charge(&payload);
            reindex(&mut self.by_bytes, stream, before, slot.bytes);
            self.buffered -= charge(&payload);
            return Poll::Ready(Ok(Some(payload)));
        }
        match slot.receive {
            Some(ReceiveEnd::Finished | ReceiveEnd::Released) => return Poll::Ready(Ok(None)),
            Some(ReceiveEnd::Reset(code)) => {
                return Poll::Ready(Err(NativeRecvError::Reset(code)));
            }
            Some(ReceiveEnd::Aborted(code)) => {
                return Poll::Ready(Err(NativeRecvError::Aborted(code)));
            }
            None if self.closed => return Poll::Ready(Err(NativeRecvError::Lost)),
            None => (),
        }
        if !slot
            .waker
            .as_ref()
            .is_some_and(|waker| waker.will_wake(cx.waker()))
        {
            slot.waker = Some(cx.waker().clone());
        }
        Poll::Pending
    }

    pub(crate) fn slot_dropped(&self, stream: u64) -> u64 {
        self.slots.get(&stream).map_or(0, |slot| slot.dropped)
    }

    pub(crate) fn drops(&self) -> DatagramDrops {
        self.drops
    }

    pub(crate) fn count_unadvertised(&mut self) {
        self.drops.unadvertised += 1;
    }

    pub(crate) fn count_invalid(&mut self, beyond_limit: bool) {
        if beyond_limit {
            self.drops.beyond_limit += 1;
        } else {
            self.drops.invalid_id += 1;
        }
    }

    #[cfg(any(test, feature = "fuzz-utils"))]
    pub(crate) fn pending_len(&self) -> usize {
        self.pending.len()
    }

    #[cfg(test)]
    pub(crate) fn buffered(&self) -> usize {
        self.buffered
    }

    #[cfg(test)]
    pub(crate) fn slot_count(&self) -> usize {
        self.slots.len()
    }

    /// Backing capacities: the slot map, the pending queue and all per-request queues.
    #[cfg(test)]
    pub(crate) fn capacities(&self) -> (usize, usize, usize) {
        let queues = self.slots.values().map(|slot| slot.queue.capacity()).sum();
        (self.slots.capacity(), self.pending.capacity(), queues)
    }

    #[cfg(feature = "fuzz-utils")]
    pub(crate) fn queued(&self, stream: u64) -> usize {
        self.slots.get(&stream).map_or(0, |slot| slot.queue.len())
    }

    /// The byte accounting matches what is held, within the configured bounds.
    #[cfg(any(test, feature = "fuzz-utils"))]
    pub(crate) fn assert_consistent(&self, limits: &DatagramLimits) {
        let queued: usize = self
            .slots
            .values()
            .flat_map(|slot| slot.queue.iter())
            .map(charge)
            .sum();
        let pending: usize = self
            .pending
            .iter()
            .map(|pending| charge(&pending.payload))
            .sum();
        assert_eq!(self.held, pending);
        assert_eq!(self.buffered, queued + pending);
        assert!(self.buffered <= limits.max_buffered_bytes);
        assert!(self.pending.len() <= limits.pending_len);
        let indexed: BTreeSet<_> = self
            .slots
            .iter()
            .filter(|(_, slot)| slot.bytes > 0)
            .map(|(stream, slot)| (slot.bytes, *stream))
            .collect();
        assert_eq!(self.by_bytes, indexed);
        for slot in self.slots.values() {
            assert!(slot.queue.len() <= limits.queue_len);
            assert_eq!(slot.bytes, slot.queue.iter().map(charge).sum::<usize>());
        }
    }

    /// Connection closed: wake every consumer; queued datagrams stay readable.
    pub(crate) fn close(&mut self) -> Vec<Waker> {
        self.closed = true;
        self.finishing.clear();
        self.drops.receive_closed += self.pending.len() as u64;
        self.pending.clear();
        self.buffered -= std::mem::take(&mut self.held);
        self.slots
            .values_mut()
            .flat_map(|slot| [slot.waker.take(), slot.finish_waker.take()])
            .flatten()
            .collect()
    }

    /// Only the clean driver path may certify that all received datagrams were filed.
    /// Remember it for FINs read after closure as well as cancelled FIN batches.
    pub(crate) fn close_drained(&mut self) -> Vec<Waker> {
        if !self.closed {
            self.drained = true;
            for slot in self.slots.values_mut() {
                if slot.finishing && slot.receive.is_none() {
                    slot.receive = Some(ReceiveEnd::Finished);
                }
            }
        }
        self.close()
    }

    /// Queue a payload for a registered stream. Over the byte budget the oldest datagram of
    /// the largest queue makes room, so stalled consumers cannot starve the others.
    fn enqueue(&mut self, limits: &DatagramLimits, stream: u64, payload: &Bytes) -> Action<A> {
        let Some(slot) = self.slots.get_mut(&stream) else {
            return Action::default();
        };
        let cost = charge(payload);
        if limits.queue_len == 0 {
            slot.dropped += 1;
            self.drops.queue_full += 1;
            return Action::default();
        }
        if self.buffered + cost > limits.max_buffered_bytes {
            // Held datagrams cannot make room: when they alone crowd the payload out, or it
            // can never fit, drop it before any queued datagram is given up for it.
            if self.held + cost > limits.max_buffered_bytes {
                slot.dropped += 1;
                self.drops.over_budget += 1;
                return Action::default();
            }
        }
        if slot.queue.len() >= limits.queue_len
            && let Some(oldest) = slot.queue.pop_front()
        {
            let before = slot.bytes;
            slot.bytes -= charge(&oldest);
            reindex(&mut self.by_bytes, stream, before, slot.bytes);
            self.buffered -= charge(&oldest);
            slot.dropped += 1;
            self.drops.queue_full += 1;
        }
        // The held check above leaves a queued datagram to evict for as long as this runs.
        while self.buffered + cost > limits.max_buffered_bytes
            && let Some((before, largest)) = self.by_bytes.last().copied()
            && let Some(slot) = self.slots.get_mut(&largest)
            && let Some(oldest) = slot.queue.pop_front()
        {
            slot.bytes -= charge(&oldest);
            reindex(&mut self.by_bytes, largest, before, slot.bytes);
            self.buffered -= charge(&oldest);
            slot.dropped += 1;
            self.drops.over_budget += 1;
        }
        let Some(slot) = self.slots.get_mut(&stream) else {
            return Action::default();
        };
        self.buffered += cost;
        let before = slot.bytes;
        slot.bytes += cost;
        reindex(&mut self.by_bytes, stream, before, slot.bytes);
        slot.queue.push_back(compact(payload));
        Action {
            wake: slot.waker.take(),
            abort: None,
        }
    }

    fn hold(&mut self, limits: &DatagramLimits, stream: u64, payload: &Bytes, expires: Instant) {
        if limits.pending_len == 0 {
            self.drops.expired += 1;
            return;
        }
        let cost = charge(payload);
        let full = self.pending.len() >= limits.pending_len;
        // The oldest held datagram only gives way when the new one then fits.
        let freed = self
            .pending
            .front()
            .filter(|_| full)
            .map_or(0, |oldest| charge(&oldest.payload));
        if self.buffered - freed + cost > limits.max_buffered_bytes {
            self.drops.over_budget += 1;
            return;
        }
        if full && let Some(oldest) = self.pending.pop_front() {
            self.held -= charge(&oldest.payload);
            self.buffered -= charge(&oldest.payload);
            self.drops.expired += 1;
        }
        self.held += cost;
        self.buffered += cost;
        self.pending.push_back(Pending {
            stream,
            payload: compact(payload),
            expires,
        });
    }

    fn expire(&mut self, now: Instant) {
        while let Some(front) = self.pending.front()
            && front.expires <= now
        {
            self.held -= charge(&front.payload);
            self.buffered -= charge(&front.payload);
            self.drops.expired += 1;
            self.pending.pop_front();
        }
    }
}

impl<A> Action<A> {
    fn merge(&mut self, other: Self) {
        self.wake = self.wake.take().or(other.wake);
        self.abort = self.abort.take().or(other.abort);
    }
}

/// A datagram for a request without datagram semantics (RFC 9297 §2).
fn violation<A: Clone>(
    slot: &mut Slot<A>,
    policy: ViolationPolicy,
    drops: &mut DatagramDrops,
) -> Action<A> {
    drops.no_semantics += 1;
    reject(slot, policy)
}

/// Under [`ViolationPolicy::Reject`], abort the request once (sticky).
fn reject<A: Clone>(slot: &mut Slot<A>, policy: ViolationPolicy) -> Action<A> {
    if policy == ViolationPolicy::Reject && !slot.violated.swap(true, Ordering::AcqRel) {
        return Action {
            wake: slot.waker.take(),
            abort: Some(slot.abort.clone()),
        };
    }
    Action::default()
}

/// How long a datagram for a stream that does not exist yet is kept.
pub(crate) fn pending_lifetime(rtt: Duration) -> Duration {
    (rtt * PENDING_LIFETIME_RTTS).max(PENDING_LIFETIME_FLOOR)
}

/// A received QUIC DATAGRAM payload, split per RFC 9297 §2.1.
pub(crate) enum Split {
    Datagram(u64, Bytes),
    InvalidId,
    BeyondLimit,
}

pub(crate) fn split(datagram: Bytes, role_is_server: bool, remote_bidi_limit: u64) -> Split {
    let Ok((id, payload)) = QuarterStreamId::split_datagram(datagram) else {
        return Split::InvalidId;
    };
    // A stream beyond the advertised client bidirectional limit cannot exist.
    if role_is_server && id.value() >= remote_bidi_limit {
        return Split::BeyondLimit;
    }
    Split::Datagram(u64::from(VarInt::from(id.request_stream())), payload)
}

/// The connection error [`ViolationPolicy::Reject`] applies to an invalid prefix.
pub(crate) fn invalid_prefix_error(beyond_limit: bool) -> Error {
    // Both are the peer's datagrams, like every other received-input violation.
    if beyond_limit {
        Error::connection(
            Code::H3_ID_ERROR,
            "datagram for a stream beyond the stream limit",
        )
        .remote()
    } else {
        Error::connection(
            Code::H3_DATAGRAM_ERROR,
            "invalid datagram quarter stream ID",
        )
        .remote()
    }
}

/// A request stream's entry in the connection demux, released when its last owner drops.
pub(crate) struct Registration {
    shared: Arc<Shared>,
    stream: u64,
    violated: Arc<AtomicBool>,
}

impl Registration {
    pub(crate) fn new(shared: Arc<Shared>, stream: u64, violated: Arc<AtomicBool>) -> Self {
        Self {
            shared,
            stream,
            violated,
        }
    }

    /// The driver aborted the request for a datagram without semantics.
    pub(crate) fn violated(&self) -> bool {
        self.violated.load(Ordering::Acquire)
    }

    pub(crate) fn decide(&self, claimed: bool) {
        self.shared.decide_datagrams(self.stream, claimed);
    }

    pub(crate) fn refuse(&self) {
        self.shared.refuse_datagrams(self.stream);
    }

    pub(crate) fn receive_ended(&self, end: ReceiveEnd) {
        self.shared.datagram_receive_ended(self.stream, end);
    }

    /// The peer finished the stream: see [`Demux::finish_after_received`].
    pub(crate) fn finished(&self) {
        self.shared.datagram_finished(self.stream);
    }

    /// See [`Demux::poll_finished`].
    pub(crate) fn poll_finished(&self, cx: &Context<'_>) -> Poll<()> {
        self.shared.poll_datagrams_finished(self.stream, cx)
    }
}

impl Drop for Registration {
    fn drop(&mut self) {
        self.shared.unregister_datagrams(self.stream);
    }
}

/// A claimed request's datagram association, shared by its tunnel and native channel.
pub(crate) struct Association {
    registration: Arc<Registration>,
    send: BoxedStreamHandle,
    send_open: AtomicBool,
    /// Wakes senders waiting for room once no datagram may follow.
    send_closed: Arc<Notify>,
}

impl Association {
    pub(crate) fn new(registration: Arc<Registration>, send: BoxedStreamHandle) -> Arc<Self> {
        Arc::new(Self {
            registration,
            send,
            send_open: AtomicBool::new(true),
            send_closed: Arc::new(Notify::new()),
        })
    }

    /// The stream's send side is finishing or reset: no datagrams may follow (RFC 9297 §2.1).
    pub(crate) fn close_send(&self) {
        self.send_open.store(false, Ordering::Release);
        self.send_closed.notify_waiters();
    }

    /// The tunnel is gone: neither direction carries datagrams any more.
    pub(crate) fn close(&self) {
        self.close_send();
        self.registration.receive_ended(ReceiveEnd::Released);
    }

    fn stream(&self) -> u64 {
        self.registration.stream
    }

    fn shared(&self) -> &Shared {
        &self.registration.shared
    }
}

/// [`NativeDatagramChannel`] over the connection's QUIC DATAGRAM frames.
pub(crate) struct H3DatagramChannel<C> {
    association: Arc<Association>,
    connection: C,
    prefix: Bytes,
}

impl<C: transport::Connection> H3DatagramChannel<C> {
    pub(crate) fn new(association: Arc<Association>, connection: C) -> Option<Self> {
        let stream = StreamId::from(VarInt::from_u64(association.stream()).ok()?);
        let id = QuarterStreamId::from_request_stream(stream).ok()?;
        debug_assert!(stream.initiator() == Side::Client && stream.dir() == Dir::Bi);
        let mut prefix = BytesMut::with_capacity(id.size());
        id.encode(&mut prefix);
        Some(Self {
            association,
            connection,
            prefix: prefix.freeze(),
        })
    }
}

pin_project! {
    /// Room on the connection's datagram queue, or the end of this association's send side.
    struct H3SendReady<F> {
        #[pin]
        unblocked: F,
        closed: Pin<Box<OwnedNotified>>,
        send_closed: bool,
    }
}

impl<F: Future<Output = ()>> Future for H3SendReady<F> {
    type Output = ();

    fn poll(self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<()> {
        let this = self.project();
        if *this.send_closed || this.closed.as_mut().poll(cx).is_ready() {
            return Poll::Ready(());
        }
        this.unblocked.poll(cx)
    }
}

impl<C: transport::Connection> NativeDatagramChannel for H3DatagramChannel<C> {
    fn send_ready(&self) -> NativeSendReady {
        // Register both wakes before reading the state they guard.
        let mut closed = Box::pin(Arc::clone(&self.association.send_closed).notified_owned());
        closed.as_mut().enable();
        let unblocked = self.connection.datagram_send_ready();
        let send_closed = !self.association.send_open.load(Ordering::Acquire);
        NativeSendReady::new(H3SendReady {
            unblocked,
            closed,
            send_closed,
        })
    }

    fn max_payload_size(&self) -> Option<usize> {
        if !self.association.shared().native_datagrams() {
            return None;
        }
        self.connection
            .max_datagram_size()?
            .checked_sub(self.prefix.len())
    }

    fn send(&self, payload: Bytes, policy: NativeSendPolicy) -> Result<(), NativeSendError> {
        let max = self
            .max_payload_size()
            .ok_or(NativeSendError::Unavailable)?;
        if !self.association.send_open.load(Ordering::Acquire) {
            return Err(NativeSendError::Closed);
        }
        if payload.len() > max {
            return Err(NativeSendError::TooLarge { max });
        }
        let mut datagram = BytesMut::with_capacity(self.prefix.len() + payload.len());
        datagram.put_slice(&self.prefix);
        datagram.put_slice(&payload);
        let datagram = datagram.freeze();
        let length = datagram.len();
        // The transport checks the stream's send state under the lock that queues it.
        let result = match policy {
            NativeSendPolicy::DropOldest => self.association.send.send_datagram(datagram),
            NativeSendPolicy::RejectWhenFull => self.association.send.try_send_datagram(datagram),
        };
        if result.is_ok() {
            qlog::datagram(
                self.association.shared().qlog.as_ref(),
                "http3:datagram_created",
                self.association.stream(),
                length,
            );
        }
        result.map_err(|error| match error {
            SendDatagramError::TooLarge => NativeSendError::TooLarge { max },
            SendDatagramError::Blocked => NativeSendError::Full,
            SendDatagramError::Closed => {
                self.association.close_send();
                NativeSendError::Closed
            }
            SendDatagramError::Unavailable => NativeSendError::Unavailable,
        })
    }

    fn poll_recv(&self, cx: &mut Context<'_>) -> Poll<Result<Option<Bytes>, NativeRecvError>> {
        self.association
            .shared()
            .poll_datagram(self.association.stream(), cx)
    }

    fn dropped(&self) -> u64 {
        self.association
            .shared()
            .datagrams_dropped(self.association.stream())
    }

    fn release_recv(&self) {
        self.association
            .registration
            .receive_ended(ReceiveEnd::Released);
    }
}
