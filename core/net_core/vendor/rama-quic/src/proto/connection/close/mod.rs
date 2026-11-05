//! Closing a connection: the application asking for it, an error killing it, and what the
//! closing state answers while it waits out its timer.

use std::num::NonZeroU32;

use rama_core::{bytes::Bytes, telemetry::tracing::trace};

use crate::proto::{
    Instant,
    connection::{Connection, ConnectionError, State, state, timer::Timer},
    shared::EndpointEventInner,
};
use rama_quic_proto::{
    VarInt,
    frame::{self, Close},
};

impl Connection {
    /// Close a connection immediately
    ///
    /// This does not ensure delivery of outstanding data. It is the application's responsibility to
    /// call this only when all important communications have been completed, e.g. by calling
    /// [`SendStream::finish`](crate::proto::connection::SendStream::finish) on outstanding streams and waiting for the corresponding
    /// [`StreamEvent::Finished`] event.
    ///
    /// If `Streams::send_streams` returns 0, all outstanding stream data has been
    /// delivered. There may still be data from the peer that has not been received.
    ///
    /// [`StreamEvent::Finished`]: crate::proto::StreamEvent::Finished
    pub(crate) fn close(&mut self, now: Instant, error_code: VarInt, reason: Bytes) {
        self.close_inner(
            now,
            Close::Application(frame::ApplicationClose { error_code, reason }),
        )
    }

    pub(crate) fn close_transport(&mut self, now: Instant, error: rama_quic_proto::TransportError) {
        self.close_inner(now, error.into());
    }

    pub(super) fn close_inner(&mut self, now: Instant, reason: Close) {
        let was_closed = self.state.is_closed();
        if !was_closed {
            self.qlog_local_close(now, &reason);
            self.close_common();
            self.set_close_timer(now);
            self.close = true;
            self.state = State::Closed(state::Closed { reason });
            self.qlog_observe_state(now);
        }
    }

    /// Whether the connection is closed
    ///
    /// Closed connections cannot transport any further data. A connection becomes closed when
    /// either peer application intentionally closes it, or when either transport layer detects an
    /// error such as a time-out or certificate validation failure.
    ///
    /// A `ConnectionLost` event is emitted with details when the connection becomes closed.
    pub(crate) fn is_closed(&self) -> bool {
        self.state.is_closed()
    }

    /// Whether there is no longer any need to keep the connection around
    ///
    /// Closed connections become drained after a brief timeout to absorb any remaining in-flight
    /// packets from the peer. All drained connections have been closed.
    pub(crate) fn is_drained(&self) -> bool {
        self.state.is_drained()
    }

    pub(super) fn close_common(&mut self) {
        trace!("connection closed");
        self.early_packets.clear();
        for &timer in &Timer::VALUES {
            self.timers.stop(timer);
        }
    }

    pub(super) fn set_close_timer(&mut self, now: Instant) {
        self.timers
            .set(Timer::Close, now + 3 * self.pto(self.highest_space));
    }

    /// Terminate the connection instantly, without sending a close packet
    /// Whether the peer has been told this connection is closing: a CONNECTION_CLOSE went out,
    /// or the peer's own close arrived and the connection is draining (RFC 9000 §10.2.2).
    pub(crate) fn close_announced(&self) -> bool {
        matches!(self.state, State::Draining)
            || (self.state.is_closed() && self.stats.frame_tx.connection_close > 0)
    }

    /// Leave the closing or draining period at once, which RFC 9000 §10.2 permits. The period
    /// exists to answer late packets and repeat the close; an endpoint that is stopping will do
    /// neither, so nothing is lost by not waiting it out. Refused until the peer has been told,
    /// and answers whether there was a period to leave.
    pub(crate) fn abandon_close(&mut self, now: Instant) -> bool {
        if !self.close_announced() || self.state.is_drained() {
            return false;
        }
        self.timers.stop(Timer::Close);
        self.state = State::Drained;
        self.qlog_observe_state(now);
        self.endpoint_events.push_back(EndpointEventInner::Drained);
        true
    }

    pub(super) fn kill(&mut self, now: Instant, reason: ConnectionError) {
        self.qlog_connection_error(now, &reason);
        self.close_common();
        self.error = Some(reason);
        self.state = State::Drained;
        self.qlog_observe_state(now);
        self.endpoint_events.push_back(EndpointEventInner::Drained);
    }
}

/// How often a connection in the closing state answers what the peer keeps sending.
///
/// RFC 9000 §10.2.1 asks an endpoint in that state to answer progressively less often, so each
/// answer doubles the input the next one needs. The unit is a received packet, which is what
/// the RFC suggests counting; a coalesced datagram therefore carries several. `gap` is a
/// `NonZeroU32`, so a response always costs at least one packet.
#[derive(Debug, Clone, Copy)]
pub(super) struct CloseResponses {
    pub(super) gap: NonZeroU32,
    pub(super) seen: u32,
}

impl CloseResponses {
    pub(super) const fn new() -> Self {
        Self {
            gap: NonZeroU32::MIN,
            seen: 0,
        }
    }

    /// Count one packet attributed to this connection's own path. Answers whether it arms the
    /// next response.
    pub(super) fn arrived(&mut self) -> bool {
        self.seen = self.seen.saturating_add(1);
        if self.seen >= self.gap.get() {
            self.seen = 0;
            true
        } else {
            false
        }
    }

    /// A response was encoded, so the one after it costs twice as much. Doubling a non-zero
    /// value keeps it non-zero, and saturating keeps it finite.
    pub(super) fn answered(&mut self) {
        self.gap = self.gap.saturating_mul(NonZeroU32::MIN.saturating_add(1));
        self.seen = 0;
    }
}

#[cfg(test)]
mod tests;
