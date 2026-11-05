//! Packet drop and buffer event data.

use super::packet::RawInfo;
use serde::Serialize;

#[derive(Clone, Copy, Debug, Serialize)]
#[serde(rename_all = "snake_case")]
/// Reason a packet was discarded.
pub enum DropReason {
    /// The packet violated QUIC encoding or protocol requirements.
    Invalid,

    /// The packet number was already received.
    Duplicate,

    /// Packet authentication or decryption failed.
    DecryptionFailure,

    /// Required packet-protection keys were unavailable.
    KeyUnavailable,

    /// Connection state or endpoint policy rejected the packet.
    Rejected,

    /// The packet used an unsupported protocol version or feature.
    Unsupported,
}

#[derive(Clone, Copy, Debug, Serialize)]
/// Packet-drop data; undecodable headers and unknown wire lengths are omitted.
pub struct PacketDropped {
    /// Decoded header information, when available.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub header: Option<DropHeader>,

    /// Encoded packet size, when known.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub raw: Option<RawInfo>,

    /// Reason the packet was discarded.
    pub trigger: DropReason,
}

#[derive(Clone, Copy, Debug, Serialize)]
/// Known packet type and, when authenticated, expanded packet number.
pub struct DropHeader {
    /// Qlog packet type name, including unnumbered packet types.
    pub packet_type: DropPacketType,

    /// Full packet number, present only when authenticated.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub packet_number: Option<u64>,
}

/// Why a packet was held back for later processing.
#[derive(Clone, Copy, Debug, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum BufferReason {
    /// The keys that open the packet were not available yet.
    KeysUnavailable,
}

#[derive(Clone, Copy, Debug, Serialize)]
/// Packet-buffer data (QUIC events draft 13, section 5.8).
pub struct PacketBuffered {
    /// Known packet type; the packet number is protected until the packet is processed.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub header: Option<DropHeader>,

    /// Encoded packet size.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub raw: Option<RawInfo>,

    /// Reason the packet was held back.
    pub trigger: BufferReason,
}

/// Tagged event for a packet that was discarded or held back.
#[derive(Clone, Copy, Debug, Serialize)]
#[serde(tag = "name", content = "data")]
pub enum DropEvent {
    /// A packet was discarded before normal processing completed.
    #[serde(rename = "quic:packet_dropped")]
    PacketDropped(PacketDropped),

    /// A packet was held back until it can be processed.
    #[serde(rename = "quic:packet_buffered")]
    PacketBuffered(PacketBuffered),
}

/// Packet classification known when a packet is discarded.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
pub enum DropPacketType {
    /// An Initial packet.
    #[serde(rename = "initial")]
    Initial,

    /// A Handshake packet.
    #[serde(rename = "handshake")]
    Handshake,

    /// An early application-data packet.
    #[serde(rename = "0RTT")]
    ZeroRtt,

    /// An application-data packet.
    #[serde(rename = "1RTT")]
    OneRtt,

    /// A Retry packet.
    #[serde(rename = "retry")]
    Retry,

    /// A Version Negotiation packet.
    #[serde(rename = "version_negotiation")]
    VersionNegotiation,

    /// A stateless reset.
    #[serde(rename = "stateless_reset")]
    StatelessReset,

    /// An unrecognized packet type.
    #[serde(rename = "unknown")]
    Unknown,
}
