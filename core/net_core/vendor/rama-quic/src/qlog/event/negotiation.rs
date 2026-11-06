//! Version, ALPN, transport parameter, and traffic-key event data.

use super::Initiator;
use rama_quic_proto::ConnectionId;
use serde::{Serialize, Serializer, ser::SerializeSeq};
use std::borrow::Cow;

/// Version, ALPN, transport parameter, and traffic-key observations.
#[derive(Clone, Debug, Serialize)]
#[serde(tag = "name", content = "data")]
pub enum NegotiationEventView<'a> {
    /// Versions advertised by either endpoint and the selected version.
    #[serde(rename = "quic:version_information")]
    VersionInformation(VersionInformationView<'a>),

    /// The application protocol negotiated during the handshake.
    #[serde(rename = "quic:alpn_information")]
    AlpnInformation {
        /// Selected ALPN protocol identifier.
        chosen_alpn: AlpnIdentifierView<'a>,
    },

    /// Local or remote transport parameters became available.
    #[serde(rename = "quic:parameters_set")]
    ParametersSet(ParametersSet),

    /// Remembered transport parameters were restored for session resumption.
    #[serde(rename = "quic:parameters_restored")]
    ParametersRestored(RestoredParameters),

    /// Packet-protection keys became available or advanced to a new generation.
    #[serde(rename = "quic:key_updated")]
    KeyUpdated(KeyChange),

    /// Packet-protection keys were discarded.
    #[serde(rename = "quic:key_discarded")]
    KeyDiscarded(KeyChange),
}

/// Negotiation event with owned or static backing storage.
pub type NegotiationEvent = NegotiationEventView<'static>;

/// Binary data borrowed during observation, serialized as hexadecimal only by the encoder.
#[derive(Clone, Debug, Serialize)]
pub struct HexView<'a>(
    /// Original binary contents; hexadecimal conversion is deferred until serialization.
    #[serde(with = "rama_utils::bytes::serde_hex")]
    pub Cow<'a, [u8]>,
);

/// Binary data with owned or static backing storage.
pub type Hex = HexView<'static>;

/// Four-byte network-order QUIC version.
#[derive(Clone, Copy, Debug, Serialize)]
pub struct Version(
    /// Version identifier in network byte order.
    #[serde(with = "rama_utils::bytes::serde_hex")]
    pub [u8; 4],
);

/// A version list in its existing host or wire representation, without conversion at capture.
#[derive(Clone, Debug)]
pub enum VersionListView<'a> {
    /// Version identifiers stored as host-order integers.
    Host(Cow<'a, [rama_quic_proto::Version]>),

    /// Version identifiers stored as network-order four-byte values.
    Network(Cow<'a, [[u8; 4]]>),
}

/// Version list with owned or static backing storage.
pub type VersionList = VersionListView<'static>;

impl Serialize for VersionListView<'_> {
    fn serialize<S: Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
        match self {
            Self::Host(versions) => {
                let mut sequence = serializer.serialize_seq(Some(versions.len()))?;
                for version in versions.as_ref() {
                    sequence.serialize_element(&Version(version.to_be_bytes()))?;
                }
                sequence.end()
            }
            Self::Network(versions) => {
                let mut sequence = serializer.serialize_seq(Some(versions.len()))?;
                for version in versions.as_ref() {
                    sequence.serialize_element(&Version(*version))?;
                }
                sequence.end()
            }
        }
    }
}

impl VersionListView<'_> {
    /// Retain this list, copying borrowed storage and moving existing owned storage.
    pub fn into_owned(self) -> VersionList {
        match self {
            Self::Host(values) => VersionListView::Host(Cow::Owned(values.into_owned())),
            Self::Network(values) => VersionListView::Network(Cow::Owned(values.into_owned())),
        }
    }

    /// Conservative heap bytes needed when retaining this value, including existing spare capacity.
    pub fn owned_heap_size(&self) -> usize {
        match self {
            Self::Host(Cow::Borrowed(values)) => values
                .len()
                .saturating_mul(size_of::<rama_quic_proto::Version>()),
            Self::Network(Cow::Borrowed(values)) => {
                values.len().saturating_mul(size_of::<[u8; 4]>())
            }
            Self::Host(Cow::Owned(_)) | Self::Network(Cow::Owned(_)) => self.heap_size(),
        }
    }

    /// Retained heap bytes, including spare capacity; excludes borrowed data and allocator metadata.
    pub fn heap_size(&self) -> usize {
        match self {
            Self::Host(Cow::Owned(values)) => values
                .capacity()
                .saturating_mul(size_of::<rama_quic_proto::Version>()),
            Self::Network(Cow::Owned(values)) => {
                values.capacity().saturating_mul(size_of::<[u8; 4]>())
            }
            Self::Host(Cow::Borrowed(_)) | Self::Network(Cow::Borrowed(_)) => 0,
        }
    }
}

/// Advertised versions and the selected version, when known.
#[derive(Clone, Debug, Serialize)]
pub struct VersionInformationView<'a> {
    /// Versions advertised or supported by the server, when known.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub server_versions: Option<VersionListView<'a>>,

    /// Versions advertised or supported by the client, when known.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub client_versions: Option<VersionListView<'a>>,

    /// Selected QUIC version, when known.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub chosen_version: Option<Version>,
}

/// Version information with owned or static backing storage.
pub type VersionInformation = VersionInformationView<'static>;

/// An ALPN protocol identifier with arbitrary binary contents.
#[derive(Clone, Debug, Serialize)]
pub struct AlpnIdentifierView<'a> {
    /// Protocol identifier bytes, serialized as hexadecimal.
    pub byte_value: HexView<'a>,
}

/// ALPN identifier with owned or static backing storage.
pub type AlpnIdentifier = AlpnIdentifierView<'static>;

impl NegotiationEventView<'_> {
    /// Retain this event, copying borrowed storage and moving existing owned storage.
    pub fn into_owned(self) -> NegotiationEvent {
        match self {
            Self::VersionInformation(info) => {
                NegotiationEventView::VersionInformation(VersionInformationView {
                    server_versions: info.server_versions.map(VersionListView::into_owned),
                    client_versions: info.client_versions.map(VersionListView::into_owned),
                    chosen_version: info.chosen_version,
                })
            }
            Self::AlpnInformation { chosen_alpn } => NegotiationEventView::AlpnInformation {
                chosen_alpn: AlpnIdentifierView {
                    byte_value: HexView(Cow::Owned(chosen_alpn.byte_value.0.into_owned())),
                },
            },
            Self::ParametersSet(value) => NegotiationEventView::ParametersSet(value),
            Self::ParametersRestored(value) => NegotiationEventView::ParametersRestored(value),
            Self::KeyUpdated(value) => NegotiationEventView::KeyUpdated(value),
            Self::KeyDiscarded(value) => NegotiationEventView::KeyDiscarded(value),
        }
    }

    /// Conservative heap bytes needed when retaining this value, including existing spare capacity.
    pub fn owned_heap_size(&self) -> usize {
        match self {
            Self::VersionInformation(info) => info
                .server_versions
                .as_ref()
                .map_or(0, VersionListView::owned_heap_size)
                .saturating_add(
                    info.client_versions
                        .as_ref()
                        .map_or(0, VersionListView::owned_heap_size),
                ),
            Self::AlpnInformation { chosen_alpn } => match &chosen_alpn.byte_value.0 {
                Cow::Borrowed(bytes) => bytes.len(),
                Cow::Owned(bytes) => bytes.capacity(),
            },
            Self::ParametersSet(_)
            | Self::ParametersRestored(_)
            | Self::KeyUpdated(_)
            | Self::KeyDiscarded(_) => 0,
        }
    }

    /// Retained heap bytes, including spare capacity; excludes borrowed data and allocator metadata.
    pub fn heap_size(&self) -> usize {
        match self {
            Self::VersionInformation(info) => info
                .server_versions
                .as_ref()
                .map_or(0, VersionListView::heap_size)
                .saturating_add(
                    info.client_versions
                        .as_ref()
                        .map_or(0, VersionListView::heap_size),
                ),
            Self::AlpnInformation { chosen_alpn } => match &chosen_alpn.byte_value.0 {
                Cow::Borrowed(_) => 0,
                Cow::Owned(bytes) => bytes.capacity(),
            },
            Self::ParametersSet(_)
            | Self::ParametersRestored(_)
            | Self::KeyUpdated(_)
            | Self::KeyDiscarded(_) => 0,
        }
    }
}

#[derive(Clone, Copy, Debug, Serialize)]
/// Remembered transport parameters restored by the implementation.
/// Local and remote stream directions are relative to the endpoint advertising these parameters.
pub struct RestoredParameters {
    /// Whether the advertising endpoint prohibits peer-initiated active migration.
    pub disable_active_migration: bool,

    /// Advertised maximum idle timeout, in milliseconds; zero disables this timeout.
    pub max_idle_timeout: u64,

    /// Largest UDP payload the advertising endpoint accepts, in bytes.
    pub max_udp_payload_size: u64,

    /// Maximum peer-issued connection IDs the advertising endpoint retains.
    pub active_connection_id_limit: u64,

    /// Initial connection-wide receive credit, in bytes.
    pub initial_max_data: u64,

    /// Initial receive credit for locally initiated bidirectional streams, in bytes.
    pub initial_max_stream_data_bidi_local: u64,

    /// Initial receive credit for remotely initiated bidirectional streams, in bytes.
    pub initial_max_stream_data_bidi_remote: u64,

    /// Initial receive credit per remotely initiated unidirectional stream, in bytes.
    pub initial_max_stream_data_uni: u64,

    /// Initial number of bidirectional streams the peer may open.
    pub initial_max_streams_bidi: u64,

    /// Initial number of unidirectional streams the peer may open.
    pub initial_max_streams_uni: u64,

    /// Largest accepted DATAGRAM frame, including its header, in bytes.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub max_datagram_frame_size: Option<u64>,

    /// Whether the endpoint accepts a cleared QUIC fixed bit.
    pub grease_quic_bit: bool,
}

#[derive(Clone, Copy, Debug, Serialize)]
/// Local or remote transport parameters, including public connection IDs.
/// Excludes reset tokens. Maximum ACK delay is expressed in milliseconds.
pub struct ParametersSet {
    /// Endpoint advertising these parameters: local or remote.
    pub initiator: Initiator,

    /// Transport parameters also retained across session resumption.
    #[serde(flatten)]
    pub parameters: RestoredParameters,

    /// Base-two exponent scaling encoded acknowledgement delays.
    pub ack_delay_exponent: u64,

    /// Maximum advertised acknowledgement delay, in milliseconds.
    pub max_ack_delay: u64,

    /// Destination connection ID from the client’s first Initial packet.
    #[serde(skip_serializing_if = "Option::is_none")]
    #[serde(serialize_with = "super::serialize_optional_cid")]
    pub original_destination_connection_id: Option<ConnectionId>,

    /// Source connection ID from the advertising endpoint’s first Initial packet.
    #[serde(skip_serializing_if = "Option::is_none")]
    #[serde(serialize_with = "super::serialize_optional_cid")]
    pub initial_source_connection_id: Option<ConnectionId>,

    /// Source connection ID from the server’s Retry packet, if any.
    #[serde(skip_serializing_if = "Option::is_none")]
    #[serde(serialize_with = "super::serialize_optional_cid")]
    pub retry_source_connection_id: Option<ConnectionId>,
}

#[derive(Clone, Copy, Debug, Serialize)]
/// Traffic-key generation and update cause. Contains no secret key material.
pub struct KeyChange {
    /// Qlog key type identifying endpoint role and encryption level.
    pub key_type: KeyType,

    /// Monotonic 1-RTT key generation, rather than the single wire phase bit.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub key_phase: Option<u64>,

    /// Cause of the key update or discard, when known.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub trigger: Option<KeyChangeTrigger>,
}

/// Endpoint role and encryption level of a traffic key.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
pub enum KeyType {
    /// Server initial traffic secret.
    #[serde(rename = "server_initial_secret")]
    ServerInitialSecret,

    /// Server handshake traffic secret.
    #[serde(rename = "server_handshake_secret")]
    ServerHandshakeSecret,

    /// Server 0-RTT traffic secret.
    #[serde(rename = "server_0rtt_secret")]
    ServerZeroRttSecret,

    /// Server 1-RTT traffic secret.
    #[serde(rename = "server_1rtt_secret")]
    ServerOneRttSecret,

    /// Client initial traffic secret.
    #[serde(rename = "client_initial_secret")]
    ClientInitialSecret,

    /// Client handshake traffic secret.
    #[serde(rename = "client_handshake_secret")]
    ClientHandshakeSecret,

    /// Client 0-RTT traffic secret.
    #[serde(rename = "client_0rtt_secret")]
    ClientZeroRttSecret,

    /// Client 1-RTT traffic secret.
    #[serde(rename = "client_1rtt_secret")]
    ClientOneRttSecret,
}

/// Cause of a traffic-key update or discard.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum KeyChangeTrigger {
    /// TLS generated or discarded the keys.
    Tls,

    /// The peer initiated a key update.
    RemoteUpdate,

    /// The logging endpoint initiated a key update.
    LocalUpdate,
}
