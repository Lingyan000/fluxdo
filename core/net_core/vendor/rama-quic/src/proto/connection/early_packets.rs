//! Packets that arrive during the handshake before the keys that open them, held until those
//! keys are available instead of waiting for the peer to resend them (RFC 9001 §4.1.4).

use std::{collections::VecDeque, mem, net::SocketAddr};

use rama_core::telemetry::tracing::{debug, trace};
use rama_quic_proto::{
    EcnCodepoint,
    packet::{PartialDecode, SpaceId},
};

use crate::proto::{
    Instant,
    connection::{Connection, State, qlog::drops::DropInfo},
};

/// A held packet with what its datagram carried alongside it.
struct EarlyPacket {
    remote: SocketAddr,
    local: Option<SocketAddr>,
    ecn: Option<EcnCodepoint>,
    packet: PartialDecode,
}

/// The packets a connection holds, bounded by its transport configuration.
#[derive(Default)]
pub(super) struct EarlyPackets {
    queue: VecDeque<EarlyPacket>,
    bytes: usize,
    /// Set while held packets are processed, so none of them is held a second time.
    replaying: bool,
}

impl EarlyPackets {
    pub(super) fn clear(&mut self) {
        self.queue.clear();
        self.bytes = 0;
    }

    #[cfg(test)]
    pub(super) fn len(&self) -> usize {
        self.queue.len()
    }
}

impl Connection {
    /// Whether `packet` waits on keys this handshake has yet to produce.
    fn awaits_keys(&self, packet: &PartialDecode) -> bool {
        if !matches!(self.state, State::Handshake(_)) {
            return false;
        }
        if !packet.has_long_header() {
            // Neither role opens 1-RTT packets before the handshake completes (RFC 9001 §5.7).
            return true;
        }
        let handshake_keys = self.spaces[SpaceId::Handshake]
            .crypto
            .as_ref()
            .is_some_and(|keys| keys.remote.is_some());
        if packet.is_0rtt() {
            // A server derives 0-RTT keys from the complete ClientHello, as it does its
            // Handshake keys; a client never opens 0-RTT.
            return self.side.is_server() && self.zero_rtt_crypto.is_none() && !handshake_keys;
        }
        packet.space() == Some(SpaceId::Handshake) && !handshake_keys
    }

    /// Holds `packet` when it waits on keys and fits the configured bounds, otherwise hands it
    /// back to be processed (and dropped) as usual.
    pub(super) fn try_hold_early_packet(
        &mut self,
        now: Instant,
        remote: SocketAddr,
        local: Option<SocketAddr>,
        ecn: Option<EcnCodepoint>,
        packet: PartialDecode,
    ) -> Option<PartialDecode> {
        // Only packets from the handshake's own peer are processed, so only those are held.
        if self.early_packets.replaying || remote != self.path.remote || !self.awaits_keys(&packet)
        {
            return Some(packet);
        }
        let size = packet.len();
        if self.early_packets.queue.len() >= self.config.early_packet_buffer_packets
            || size
                > self
                    .config
                    .early_packet_buffer_size
                    .saturating_sub(self.early_packets.bytes)
        {
            debug!(
                "early packet buffer full, not holding {:?} packet ({} bytes)",
                packet.space(),
                size
            );
            return Some(packet);
        }
        trace!(
            "holding {:?} packet ({} bytes) until its keys are available",
            packet.space(),
            size
        );
        self.qlog_packet_buffered(now, DropInfo::partial(&packet));
        self.early_packets.bytes += size;
        self.early_packets.queue.push_back(EarlyPacket {
            remote,
            local,
            ecn,
            packet: packet.compact(),
        });
        None
    }

    /// Processes the held packets that no longer wait on keys, oldest first, until processing
    /// them opens up no others.
    pub(super) fn replay_early_packets(&mut self, now: Instant) {
        if self.early_packets.replaying || self.early_packets.queue.is_empty() {
            return;
        }
        self.early_packets.replaying = true;
        loop {
            let mut ready = Vec::new();
            for early in mem::take(&mut self.early_packets.queue) {
                if self.awaits_keys(&early.packet) {
                    self.early_packets.queue.push_back(early);
                } else {
                    self.early_packets.bytes -= early.packet.len();
                    ready.push(early);
                }
            }
            if ready.is_empty() {
                break;
            }
            for early in ready {
                trace!("processing held {:?} packet", early.packet.space());
                self.receive_packet(now, early.remote, early.local, early.ecn, early.packet);
            }
        }
        self.early_packets.replaying = false;
    }
}
