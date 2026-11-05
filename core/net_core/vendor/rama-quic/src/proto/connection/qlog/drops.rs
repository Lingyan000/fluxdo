//! Connection-scoped packet drops and buffers (QUIC events draft 13, sections 5.7 and 5.8).

pub(crate) use crate::qlog::event::drops::DropReason;
use crate::qlog::event::drops::{
    BufferReason, DropHeader, DropPacketType, PacketBuffered, PacketDropped,
};

use rama_quic_proto::packet::{Header, LongType, Packet, PartialDecode, SpaceId};

use super::event::RawInfo;
use crate::proto::{Instant, connection::Connection};

/// Only authenticated, expanded packet numbers are recorded. An undecodable header is omitted.
#[derive(Clone, Copy)]
pub(crate) struct DropInfo {
    packet_type: Option<DropPacketType>,
    pub(crate) number: Option<u64>,
    pub(crate) length: Option<usize>,
}

impl DropInfo {
    pub(crate) fn unknown() -> Self {
        Self {
            packet_type: None,
            number: None,
            length: None,
        }
    }

    pub(crate) fn partial(packet: &PartialDecode) -> Self {
        let packet_type = match packet.space() {
            Some(SpaceId::Initial) => Some(DropPacketType::Initial),
            Some(SpaceId::Handshake) => Some(DropPacketType::Handshake),
            Some(SpaceId::Data) if packet.is_0rtt() => Some(DropPacketType::ZeroRtt),
            Some(SpaceId::Data) => Some(DropPacketType::OneRtt),
            None => None,
        };
        Self {
            packet_type,
            number: None,
            length: Some(packet.len()),
        }
    }

    pub(crate) fn packet(packet: &Packet) -> Self {
        let packet_type = match packet.header {
            Header::Initial(_) => DropPacketType::Initial,
            Header::Long {
                ty: LongType::Handshake,
                ..
            } => DropPacketType::Handshake,
            Header::Long {
                ty: LongType::ZeroRtt,
                ..
            } => DropPacketType::ZeroRtt,
            Header::Short { .. } => DropPacketType::OneRtt,
            Header::Retry { .. } => DropPacketType::Retry,
            Header::VersionNegotiate { .. } => DropPacketType::VersionNegotiation,
        };
        Self {
            packet_type: Some(packet_type),
            number: None,
            length: Some(packet.header_data.len() + packet.payload.len()),
        }
    }

    /// Protected packet bodies have already lost their AEAD trailer at this point.
    pub(crate) fn decrypted(packet: &Packet, number: Option<u64>) -> Self {
        let mut info = Self::packet(packet).with_number(number);
        if packet.header.is_protected() {
            info.length = None;
        }
        info
    }

    pub(crate) fn with_number(mut self, number: Option<u64>) -> Self {
        self.number = number;
        self
    }
}

impl Connection {
    pub(crate) fn qlog_packet_dropped(&self, now: Instant, info: DropInfo, trigger: DropReason) {
        self.qlog_sink.emit(self.trace_cid, now, || PacketDropped {
            header: info.packet_type.map(|packet_type| DropHeader {
                packet_type,
                packet_number: info.number,
            }),
            raw: info.length.map(|length| RawInfo { length }),
            trigger,
        });
    }

    pub(crate) fn qlog_packet_buffered(&self, now: Instant, info: DropInfo) {
        self.qlog_sink.emit(self.trace_cid, now, || PacketBuffered {
            header: info.packet_type.map(|packet_type| DropHeader {
                packet_type,
                packet_number: None,
            }),
            raw: info.length.map(|length| RawInfo { length }),
            trigger: BufferReason::KeysUnavailable,
        });
    }
}
