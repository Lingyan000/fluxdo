use std::collections::VecDeque;

use rama_core::bytes::Bytes;
use rama_core::telemetry::tracing::{debug, trace};
use rama_quic_proto::{
    TransportError,
    frame::{ArrivedDatagram, Datagram, FrameStruct},
};

use crate::proto::config::TransportConfig;

use super::{
    Connection,
    retained::{Retained, retain},
};

/// API to control datagram traffic
pub(crate) struct Datagrams<'a> {
    pub(super) conn: &'a mut Connection,
}

impl Datagrams<'_> {
    pub(crate) const ENTRY_OVERHEAD: usize = size_of::<OutgoingDatagram>();
    /// Queue an unreliable, unordered datagram for immediate transmission
    ///
    /// If `drop` is true, previously queued datagrams which are still unsent may be discarded to
    /// make space for this datagram, in order of oldest to newest. If `drop` is false, and there
    /// isn't enough space due to previously queued datagrams, this function will return
    /// `SendDatagramError::Blocked`. `Event::DatagramsUnblocked` will be emitted once datagrams
    /// have been sent.
    ///
    /// Returns `Err` iff a `len`-byte datagram cannot currently be sent.
    pub(crate) fn send(&mut self, data: Bytes, drop: bool) -> Result<(), SendDatagramError> {
        let available = self.check_send(data.len())?;
        if drop {
            while self.conn.datagrams.outgoing.memory_used() > available {
                #[expect(
                    clippy::expect_used,
                    reason = "an empty queue uses zero memory and cannot exceed available space"
                )]
                let prev = self
                    .conn
                    .datagrams
                    .outgoing
                    .pop_front()
                    .expect("datagrams.outgoing.payload_bytes desynchronized");
                trace!(len = prev.data.len(), "dropping outgoing datagram");
            }
        } else if self.conn.datagrams.outgoing.memory_used() > available {
            self.conn.datagrams.send_blocked = true;
            return Err(SendDatagramError::Blocked(data));
        }
        self.conn.datagrams.outgoing.push_back(Datagram { data });
        Ok(())
    }

    /// Compute the maximum size of datagrams that may passed to `send_datagram`
    ///
    /// Returns `None` if disabled locally or the peer's limit cannot fit a datagram frame.
    ///
    /// This may change over the lifetime of a connection according to variation in the path MTU
    /// estimate. The peer can also enforce an arbitrarily small fixed limit, but if the peer's
    /// limit is large this is guaranteed to be a little over a kilobyte at minimum.
    ///
    /// Not necessarily the maximum size of received datagrams.
    /// Whether a datagram of `len` bytes could be sent at all, without queueing it; the send
    /// buffer space it may leave for queued ones.
    pub(crate) fn check_send(&self, len: usize) -> Result<usize, SendDatagramError> {
        if self.conn.config.datagram_receive_buffer_size.is_none() {
            return Err(SendDatagramError::Disabled);
        }
        let max = self.max_size().ok_or_else(|| {
            if self
                .conn
                .peer_params
                .max_datagram_frame_size
                .is_some_and(|size| size.into_inner() > 0)
            {
                SendDatagramError::TooLarge
            } else {
                SendDatagramError::UnsupportedByPeer
            }
        })?;
        if len > max {
            return Err(SendDatagramError::TooLarge);
        }
        let needed = len.saturating_add(Self::ENTRY_OVERHEAD);
        self.conn
            .config
            .datagram_send_buffer_size
            .checked_sub(needed)
            .ok_or(SendDatagramError::TooLarge)
    }

    pub(crate) fn max_size(&self) -> Option<usize> {
        // We use the conservative overhead bound for any packet number, reducing the budget by at
        // most 3 bytes, so that PN size fluctuations don't cause users sending maximum-size
        // datagrams to suffer avoidable packet loss.
        let max_size = self.conn.path.current_mtu() as usize
            - self.conn.predict_1rtt_overhead(None)
            - Datagram::SIZE_BOUND;
        let peer_limit = self.conn.peer_params.max_datagram_frame_size?.into_inner();
        // Our DATAGRAM encoding includes its length, even for an empty payload.
        if peer_limit < 2 || self.conn.config.datagram_receive_buffer_size.is_none() {
            return None;
        }
        let limit = peer_limit.saturating_sub(Datagram::SIZE_BOUND as u64);
        Some(limit.min(max_size as u64) as usize)
    }

    /// The sequence immediately after the last accepted outgoing datagram.
    pub(crate) fn send_queue_end(&self) -> DatagramQueuePosition {
        DatagramQueuePosition(self.conn.datagrams.outgoing.next)
    }

    /// Whether this endpoint accepts DATAGRAM frames, as its `max_datagram_frame_size` says.
    pub(crate) fn receive_enabled(&self) -> bool {
        self.conn.config.datagram_receive_enabled()
    }

    /// Receive an unreliable, unordered datagram
    pub(crate) fn recv(&mut self) -> Option<Bytes> {
        self.conn.datagrams.recv()
    }

    /// Received datagrams not yet taken by [`recv`](Self::recv).
    pub(crate) fn received_len(&self) -> usize {
        self.conn.datagrams.incoming.len()
    }

    /// Payload bytes available for one more datagram in the outgoing buffer
    ///
    /// Accounts for the payload and per-entry overhead of every queued datagram. When greater
    /// than zero, [`send`](Self::send)ing a datagram of at most this size is guaranteed not to be
    /// blocked or to evict older datagrams; a zero-length datagram additionally needs room for
    /// its entry, so `0` does not guarantee that one still fits.
    pub(crate) fn send_buffer_space(&self) -> usize {
        self.conn
            .config
            .datagram_send_buffer_size
            .saturating_sub(self.conn.datagrams.outgoing.memory_used())
            .saturating_sub(Self::ENTRY_OVERHEAD)
    }
}

#[derive(Default)]
pub(super) struct DatagramState {
    pub(super) incoming: DatagramBuffer,
    pub(super) outgoing: OutgoingDatagrams,
    pub(super) send_blocked: bool,
}

impl DatagramState {
    /// Queue a DATAGRAM frame that arrived in a packet of `allocated` bytes.
    pub(super) fn received(
        &mut self,
        arrived: ArrivedDatagram,
        allocated: usize,
        config: &TransportConfig,
    ) -> Result<bool, TransportError> {
        let ArrivedDatagram { datagram, encoded } = arrived;
        let Some(advertised) = config.max_datagram_frame_size() else {
            return Err(TransportError::PROTOCOL_VIOLATION(
                "unexpected DATAGRAM frame",
            ));
        };

        // RFC 9221 §3 bounds the encoded frame by the value actually advertised.
        // Profile overrides can be either smaller or larger than the retention budget.
        if encoded as u64 > advertised.into_inner() {
            return Err(TransportError::PROTOCOL_VIOLATION("oversized datagram"));
        }

        // Storage is a separate matter. A frame that is valid on the wire but will not fit
        // is dropped, which RFC 9221 §5.3 allows; it is not the peer's protocol error.
        let window = config.datagram_receive_buffer_size.unwrap_or(0);
        let Retained { bytes, charge } = retain(datagram.data, allocated);
        let stored = charge + size_of::<Datagram>();
        // Nothing is given up for a frame that would not fit an empty queue: discarding
        // readable datagrams could not make room for it.
        if stored > window {
            debug!("dropping a datagram there is no room for");
            return Ok(false);
        }
        let was_empty = self.incoming.is_empty();
        while self.incoming.memory_used() + stored > window {
            debug!("dropping stale datagram");
            self.recv();
        }

        self.incoming
            .push_back_charged(Datagram { data: bytes }, charge);
        Ok(was_empty)
    }

    /// Discard outgoing datagrams with a payload larger than `max_payload` bytes
    ///
    /// Returns whether any datagrams were dropped.
    ///
    /// Used to ensure that reductions in MTU don't get us stuck in a state where we have a datagram
    /// queued but can't send it. A payload of exactly `max_payload` bytes still fits (see
    /// [`Datagrams::max_size`]) and is kept.
    pub(super) fn drop_oversized(&mut self, max_payload: usize) -> bool {
        let mut dropped_any = false;
        self.outgoing.queue.retain(|entry| {
            let result = entry.datagram.data.len() <= max_payload;
            if !result {
                trace!(
                    "dropping {} byte datagram violating {} byte limit",
                    entry.datagram.data.len(),
                    max_payload
                );
                self.outgoing.payload_bytes -= entry.datagram.data.len();
                dropped_any = true;
            }
            result
        });
        dropped_any
    }

    /// Attempt to write a datagram frame into `buf`, consuming it from `self.outgoing`
    ///
    /// Returns whether a frame was written. At most `max_size` bytes will be written, including
    /// framing.
    pub(super) fn write(&mut self, buf: &mut Vec<u8>, max_size: usize) -> bool {
        let Some(entry) = self.outgoing.queue.front() else {
            return false;
        };

        if buf.len() + entry.datagram.size(true) > max_size {
            // Future work: we could be more clever about cramming small datagrams into
            // mostly-full packets when a larger one is queued first
            return false;
        }
        let Some(datagram) = self.outgoing.pop_front() else {
            return false;
        };

        trace!(len = datagram.data.len(), "DATAGRAM");
        datagram.encode(true, buf);
        true
    }

    pub(super) fn recv(&mut self) -> Option<Bytes> {
        let x = self.incoming.pop_front()?.data;
        Some(x)
    }
}

#[derive(Default)]
pub(super) struct DatagramBuffer {
    queue: VecDeque<QueuedDatagram>,
    /// What the queued datagrams keep allocated.
    payload_bytes: usize,
}

struct QueuedDatagram {
    datagram: Datagram,
    charge: usize,
}

impl DatagramBuffer {
    fn push_back_charged(&mut self, datagram: Datagram, charge: usize) {
        self.payload_bytes += charge;
        self.queue.push_back(QueuedDatagram { datagram, charge });
    }

    fn pop_front(&mut self) -> Option<Datagram> {
        let QueuedDatagram { datagram, charge } = self.queue.pop_front()?;
        self.payload_bytes -= charge;
        Some(datagram)
    }

    fn memory_used(&self) -> usize {
        self.payload_bytes
            .saturating_add(self.queue.len() * size_of::<Datagram>())
    }

    pub(super) fn is_empty(&self) -> bool {
        self.queue.is_empty()
    }

    pub(super) fn len(&self) -> usize {
        self.queue.len()
    }
}

/// A position in the outgoing FIFO. Live queues occupy far less than half the
/// sequence space, so wrapping subtraction remains ordered across counter rollover.
#[derive(Clone, Copy, Debug, Default)]
pub(crate) struct DatagramQueuePosition(pub(super) u64);

impl DatagramQueuePosition {
    pub(crate) fn reached_by(self, retired: Self) -> bool {
        retired.0.wrapping_sub(self.0) < (1 << 63)
    }
}

#[derive(Default)]
pub(super) struct OutgoingDatagrams {
    queue: VecDeque<OutgoingDatagram>,
    payload_bytes: usize,
    next: u64,
}

struct OutgoingDatagram {
    datagram: Datagram,
    sequence: u64,
}

impl OutgoingDatagrams {
    fn push_back(&mut self, datagram: Datagram) {
        self.payload_bytes += datagram.data.len();
        self.queue.push_back(OutgoingDatagram {
            datagram,
            sequence: self.next,
        });
        self.next = self.next.wrapping_add(1);
    }

    fn pop_front(&mut self) -> Option<Datagram> {
        let entry = self.queue.pop_front()?;
        self.payload_bytes -= entry.datagram.data.len();
        Some(entry.datagram)
    }

    fn memory_used(&self) -> usize {
        self.payload_bytes
            .saturating_add(self.queue.len() * size_of::<OutgoingDatagram>())
    }

    /// Everything before this position was transmitted or dropped. Using the first
    /// remaining entry, rather than counting drops, handles holes left by MTU changes.
    pub(super) fn drained_to(&self) -> DatagramQueuePosition {
        DatagramQueuePosition(self.queue.front().map_or(self.next, |entry| entry.sequence))
    }

    pub(super) fn can_send_1rtt(&self, max_size: usize) -> bool {
        self.queue
            .front()
            .is_some_and(|entry| entry.datagram.size(true) <= max_size)
    }

    pub(super) fn is_empty(&self) -> bool {
        self.queue.is_empty()
    }
    #[cfg(test)]
    pub(super) fn len(&self) -> usize {
        self.queue.len()
    }
}

/// Errors that can arise when sending a datagram
#[derive(Debug, Clone, Eq, PartialEq, Ord, PartialOrd, Hash)]
pub(crate) enum SendDatagramError {
    /// The peer does not support receiving datagram frames
    UnsupportedByPeer,
    /// Datagram support is disabled locally
    Disabled,
    /// The datagram is larger than the connection can currently accommodate, or larger than the
    /// configured send buffer can ever hold
    ///
    /// Indicates that the path MTU minus overhead or the limit advertised by the peer has been
    /// exceeded.
    TooLarge,
    /// Send would block
    Blocked(Bytes),
}

impl core::fmt::Display for SendDatagramError {
    fn fmt(&self, f: &mut core::fmt::Formatter<'_>) -> core::fmt::Result {
        match self {
            Self::UnsupportedByPeer => f.write_str("datagrams not supported by peer"),
            Self::Disabled => f.write_str("datagram support disabled"),
            Self::TooLarge => f.write_str("datagram too large"),
            Self::Blocked(_) => f.write_str("datagram send blocked"),
        }
    }
}

impl std::error::Error for SendDatagramError {}

#[cfg(test)]
mod tests {
    use super::*;

    /// A datagram as it would arrive, with the bytes a minimal encoding of it occupies.
    fn datagram(len: usize) -> ArrivedDatagram {
        let datagram = Datagram {
            data: Bytes::from(vec![0u8; len]),
        };
        let encoded = datagram.size(true);
        ArrivedDatagram { datagram, encoded }
    }

    fn state_with(lens: &[usize]) -> DatagramState {
        let mut state = DatagramState::default();
        for &len in lens {
            state.outgoing.push_back(datagram(len).datagram);
        }
        state
    }

    fn lens(state: &DatagramState) -> Vec<usize> {
        state
            .outgoing
            .queue
            .iter()
            .map(|d| d.datagram.data.len())
            .collect()
    }

    #[test]
    fn queue_positions_follow_the_drained_prefix_including_mtu_drop_holes_and_wrap() {
        for start in [0, u64::MAX - 1] {
            let mut state = DatagramState::default();
            state.outgoing.next = start;
            for len in [100, 1300, 100] {
                state.outgoing.push_back(datagram(len).datagram);
            }
            let first = DatagramQueuePosition(start.wrapping_add(1));
            let all = DatagramQueuePosition(start.wrapping_add(3));
            assert!(state.drop_oversized(1200));
            // Dropping the newer entry cannot retire the older one ahead of it.
            assert!(!first.reached_by(state.outgoing.drained_to()));
            assert!(!state.write(&mut Vec::new(), 10));
            assert!(!first.reached_by(state.outgoing.drained_to()));
            assert!(state.write(&mut Vec::new(), 1200));
            assert!(first.reached_by(state.outgoing.drained_to()));
            assert!(!all.reached_by(state.outgoing.drained_to()));
            // Drop-oldest and successful packet writes retire identically.
            state.outgoing.pop_front().unwrap();
            assert!(all.reached_by(state.outgoing.drained_to()));
            assert_eq!(state.outgoing.memory_used(), 0);
        }
    }

    #[test]
    fn drop_oversized_keeps_payload_of_exactly_max_size() {
        // `max_size()` is inclusive: a payload of exactly `max` bytes may be queued and must
        // survive an MTU reduction to that exact size.
        let mut state = state_with(&[1199, 1200, 1201]);
        assert!(state.drop_oversized(1200));
        assert_eq!(lens(&state), vec![1199, 1200]);
        assert_eq!(state.outgoing.payload_bytes, 1199 + 1200);
        assert_eq!(
            state.outgoing.memory_used(),
            1199 + 1200 + 2 * size_of::<OutgoingDatagram>()
        );
    }

    #[test]
    fn drop_oversized_reports_nothing_dropped() {
        let mut state = state_with(&[10, 1200]);
        assert!(!state.drop_oversized(1200));
        assert_eq!(lens(&state), vec![10, 1200]);
        assert_eq!(state.outgoing.payload_bytes, 1210);
    }

    #[test]
    fn drop_oversized_keeps_empty_entries_and_their_overhead() {
        // Zero-length DATAGRAMs are legitimate (RFC 9221 §4) and still cost queue overhead
        let mut state = state_with(&[0, 0, 5000, 0]);
        assert!(state.drop_oversized(1200));
        assert_eq!(lens(&state), vec![0, 0, 0]);
        assert_eq!(state.outgoing.payload_bytes, 0);
        assert_eq!(
            state.outgoing.memory_used(),
            3 * size_of::<OutgoingDatagram>()
        );
        // Dropping to a zero-byte limit keeps empty entries: they always fit
        assert!(!state.drop_oversized(0));
        assert_eq!(lens(&state), vec![0, 0, 0]);
    }

    #[test]
    fn drop_oversized_accounting_survives_repeated_shrinks() {
        let mut state = state_with(&[1400, 1300, 1200, 1100]);
        assert!(state.drop_oversized(1300));
        assert_eq!(lens(&state), vec![1300, 1200, 1100]);
        assert!(state.drop_oversized(1200));
        assert_eq!(lens(&state), vec![1200, 1100]);
        assert_eq!(state.outgoing.payload_bytes, 2300);
        assert!(state.outgoing.pop_front().is_some());
        assert!(state.outgoing.pop_front().is_some());
        assert!(state.outgoing.pop_front().is_none());
        assert_eq!(state.outgoing.payload_bytes, 0);
        assert_eq!(state.outgoing.memory_used(), 0);
    }
}

#[cfg(test)]
mod receiving;
