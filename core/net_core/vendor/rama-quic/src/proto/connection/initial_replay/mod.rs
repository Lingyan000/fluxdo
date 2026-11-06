//! Execute an original Initial layout using fresh TLS output and ordinary recovery.
//!
//! Admission checks the entire burst before exposing a packet. The Initial packet
//! number selects a layout entry; no separate replay cursor or handshake copy is kept.

use rama_core::{bytes::Bytes, telemetry::tracing::debug};
use rama_quic_proto::{
    TransportError,
    coding::BufMutExt as _,
    frame,
    packet::{Header, InitialHeader, PacketNumber, SpaceId},
    profile::{
        InitialFlightLayout,
        initial::{InitialFrame, InitialPacket},
    },
};

use super::{Connection, ConnectionSide, State, transmit::SentFrames};

impl Connection {
    pub(super) fn recorded_initial(&self, space: SpaceId, number: u64) -> Option<&InitialPacket> {
        if space != SpaceId::Initial || !self.side.is_client() || !self.recorded_initial {
            return None;
        }
        match self.config.wire.packetization.layout() {
            InitialFlightLayout::Recorded(flight) => flight.packet(number),
            _ => None,
        }
    }

    /// Validate actual header/protection geometry, then replace the fresh CRYPTO
    /// queue with slices in recorded order. Ordinary connections allocate nothing.
    /// A layout that does not fit this connection, for example a ClientHello of
    /// another length, is not used: the Initial is packetized as usual.
    pub(super) fn prepare_recorded_initial(&mut self) -> Result<(), TransportError> {
        let InitialFlightLayout::Recorded(_) = self.config.wire.packetization.layout() else {
            return Ok(());
        };
        if !self.side.is_client() || self.spaces[SpaceId::Initial].crypto.is_none() {
            return Err(TransportError::INTERNAL_ERROR(
                "recorded Initial requires a client with Initial keys",
            ));
        }
        if let Err(error) = self.fit_recorded_initial() {
            debug!(%error, "QUIC: recorded Initial layout does not fit; packetizing natively");
            self.recorded_initial = false;
        }
        Ok(())
    }

    /// Bind the recorded layout to this connection; errors on any mismatch.
    fn fit_recorded_initial(&mut self) -> Result<(), TransportError> {
        let InitialFlightLayout::Recorded(flight) = self.config.wire.packetization.layout() else {
            return Err(TransportError::INTERNAL_ERROR(
                "missing recorded Initial layout",
            ));
        };
        let ConnectionSide::Client { token, .. } = &self.side else {
            return Err(TransportError::INTERNAL_ERROR(
                "recorded Initial requires a client",
            ));
        };
        let space = &self.spaces[SpaceId::Initial];
        let Some(keys) = space.crypto.as_ref() else {
            return Err(TransportError::INTERNAL_ERROR(
                "recorded Initial requires Initial keys",
            ));
        };
        let size = flight.packets()[0].datagram_size();
        let burst_size: u64 = flight
            .packets()
            .iter()
            .map(|packet| u64::from(packet.datagram_size()))
            .sum();
        if !token.is_empty()
            || flight.version().to_wire() != Some(self.wire_version)
            || usize::from(flight.destination_cid_len()) != self.rem_cids.active().len()
            || usize::from(flight.source_cid_len()) != self.handshake_cid.len()
            || size != self.path.current_mtu()
            || size < self.config.min_mtu
            || burst_size > self.path.congestion.window()
            || space.crypto_offset != flight.crypto_len() as u64
        {
            return Err(TransportError::INTERNAL_ERROR(
                "recorded Initial bindings do not match fresh connection",
            ));
        }

        // Use the packet codec itself: payload length encoding and protection
        // overhead must agree for every packet, including variable PN widths.
        let mut header_bytes = Vec::new();
        for packet in flight.packets() {
            let number = PacketNumber::new_at_least(packet.number(), 0, packet.number_len())
                .filter(|number| number.len() == usize::from(packet.number_len()))
                .ok_or_else(|| TransportError::INTERNAL_ERROR("recorded Initial number width"))?;
            header_bytes.clear();
            Header::Initial(InitialHeader {
                src_cid: self.handshake_cid,
                dst_cid: self.rem_cids.active(),
                token: Bytes::new(),
                number,
                version: self.wire_version,
            })
            .encode_with_max_packet_len(&mut header_bytes, usize::from(packet.packet_size()));
            if header_bytes.len() + packet.payload_len() + keys.local.packet.tag_len()
                != usize::from(packet.packet_size())
            {
                return Err(TransportError::INTERNAL_ERROR(
                    "recorded Initial frame geometry does not fit",
                ));
            }
        }

        let space = &mut self.spaces[SpaceId::Initial];
        let mut end = 0;
        for crypto in &space.pending.crypto {
            if crypto.offset != end {
                return Err(TransportError::INTERNAL_ERROR(
                    "fresh Initial CRYPTO queue is not contiguous",
                ));
            }
            end += crypto.data.len() as u64;
        }
        if end != flight.crypto_len() as u64 {
            return Err(TransportError::INTERNAL_ERROR(
                "fresh Initial CRYPTO queue has wrong extent",
            ));
        }
        let hello = if let Some(crypto) = space
            .pending
            .crypto
            .front()
            .filter(|_| space.pending.crypto.len() == 1)
        {
            crypto.data.clone()
        } else {
            let mut hello = Vec::with_capacity(flight.crypto_len());
            for crypto in &space.pending.crypto {
                hello.extend_from_slice(&crypto.data);
            }
            Bytes::from(hello)
        };
        space.pending.crypto.clear();
        // Packets are built in packet-number order; the wire order is restored when sent.
        for packet in flight.packets_by_number() {
            for frame in packet.frames() {
                if let InitialFrame::Crypto { offset, len } = frame {
                    space.pending.crypto.push_back(frame::Crypto {
                        offset: *offset,
                        data: hello.slice(*offset as usize..*offset as usize + len),
                    });
                }
            }
        }
        if let State::Handshake(state) = &mut self.state {
            state.client_hello = Some(hello);
        }
        space.next_packet_number = flight.first_number();
        Ok(())
    }

    /// Wire order of the recorded burst when it differs from packet-number order and
    /// the burst starts with the next Initial packet; it is then sent in one transmit.
    pub(super) fn recorded_initial_wire_order(&self) -> Option<Vec<u64>> {
        if !self.side.is_client() || !self.recorded_initial {
            return None;
        }
        let InitialFlightLayout::Recorded(flight) = self.config.wire.packetization.layout() else {
            return None;
        };
        (!flight.in_number_order()
            && self.spaces[SpaceId::Initial].next_packet_number == flight.first_number())
        .then(|| {
            flight
                .packets()
                .iter()
                .map(|packet| packet.number())
                .collect()
        })
    }

    pub(super) fn populate_recorded_initial(
        &mut self,
        buf: &mut Vec<u8>,
        max_size: usize,
        number: u64,
    ) -> Result<SentFrames, TransportError> {
        let InitialFlightLayout::Recorded(flight) = self.config.wire.packetization.layout() else {
            return Err(TransportError::INTERNAL_ERROR(
                "missing recorded Initial layout",
            ));
        };
        let packet = flight
            .packet(number)
            .ok_or_else(|| TransportError::INTERNAL_ERROR("missing recorded Initial packet"))?;
        // Validate the complete queue prefix before consuming any CRYPTO. Retry,
        // loss probes or a changed queue cannot silently alter the original shape.
        let mut pending = self.spaces[SpaceId::Initial].pending.crypto.iter();
        for frame in packet.frames() {
            if let InitialFrame::Crypto { offset, len } = frame
                && pending
                    .next()
                    .is_none_or(|crypto| crypto.offset != *offset || crypto.data.len() != *len)
            {
                return Err(TransportError::INTERNAL_ERROR(
                    "recorded Initial CRYPTO queue changed",
                ));
            }
        }
        if buf.len().checked_add(packet.payload_len()) != Some(max_size) {
            return Err(TransportError::INTERNAL_ERROR(
                "recorded Initial packet capacity changed",
            ));
        }
        let mut sent = SentFrames::default();
        let space = &mut self.spaces[SpaceId::Initial];
        for shape in packet.frames() {
            match shape {
                InitialFrame::Crypto { .. } => {
                    let crypto = space.pending.crypto.pop_front().ok_or_else(|| {
                        TransportError::INTERNAL_ERROR("recorded Initial queue exhausted")
                    })?;
                    crypto.encode(buf);
                    self.stats.frame_tx.crypto += 1;
                    sent.retransmits.get_or_create().crypto.push_back(crypto);
                }
                InitialFrame::Ping => {
                    buf.write(frame::FrameType::PING);
                    self.stats.frame_tx.ping += 1;
                    sent.non_retransmits = true;
                }
                InitialFrame::Padding { len } => buf.resize(buf.len() + len, 0),
                _ => {
                    return Err(TransportError::INTERNAL_ERROR(
                        "unsupported recorded Initial frame",
                    ));
                }
            }
        }
        sent.requires_padding = true;
        Ok(sent)
    }
}
