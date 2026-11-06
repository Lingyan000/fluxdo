//! Browser profiles, taken from captures of the named versions (see `fixtures/README.md`).
//!
//! Each constructor reproduces what the capture shows a first flight to look like: version
//! offer, transport parameter set and order, connection ID lengths, Initial datagram size,
//! packet number encoding and frame layout, and the advertised limits. Where this crate cannot
//! honour a value the browser advertises, the constructor says so and uses the closest value
//! it does honour.

use std::time::Duration;

use rama_quic_proto::{
    transport_parameters::TransportParameterId,
    version::{ClientVersionPolicy, ReservedVersionGrease, Version},
};

use super::{
    ConnectionIdProfile, GreaseParameter, InitialFlightLayout, OpaqueParameter, PacketNumberLength,
    PacketizationProfile, PaddingPlacement, ParameterOrder, QuicProfile, TransportLimits,
    TransportParameterProfile,
};

/// Google Chrome 153 (Chromium's QUIC stack), as captured over IPv6.
///
/// A v1 first flight offering only v1, with a reserved version listed before it; shuffled
/// transport parameters with a four-byte greased parameter and Chromium's
/// `google_connection_options`; an eight-byte destination and an empty source connection
/// ID; 1230-byte Initial datagrams with two-byte packet numbers counting from one; CRYPTO
/// data scattered among PING and PADDING frames; no coalescing; no QUIC bit greasing and no
/// ACK frequency extension.
#[must_use]
#[expect(
    clippy::expect_used,
    reason = "the values are constants taken from a capture and checked by this crate's tests"
)]
pub(crate) fn chrome_153() -> QuicProfile {
    let checked = || -> Result<QuicProfile, super::ProfileError> {
        let versions = ClientVersionPolicy::new(Version::V1)?
            .with_reserved_version_grease(ReservedVersionGrease::First);
        let parameters = TransportParameterProfile::standard()
            .try_with_order(ParameterOrder::Shuffled)?
            .try_with_grease(GreaseParameter::Random { value_len: Some(4) })?
            .try_with_extra(vec![OpaqueParameter {
                // google_connection_options
                id: TransportParameterId::from(0x3128),
                value: b"ORIG".to_vec(),
            }])?
            .with_min_ack_delay(false)
            .try_with_max_datagram_frame_size(Some(65536))?;
        let connection_ids = ConnectionIdProfile::standard()
            .try_with_initial_destination_len(8)?
            .try_with_local_len(0)?;
        let packetization = PacketizationProfile::standard()
            .try_with_initial_datagram_size(1230)?
            .try_with_packet_number_length(PacketNumberLength::AtLeast(2))?
            .try_with_first_packet_number(1)?
            .with_layout(InitialFlightLayout::Chaos)
            .with_padding(PaddingPlacement::Frames)
            .with_coalesce(false);
        let limits = TransportLimits {
            max_idle_timeout: Duration::from_secs(30),
            initial_max_data: 15_728_640,
            initial_max_stream_data_bidi_local: 6_291_456,
            initial_max_stream_data_bidi_remote: 6_291_456,
            initial_max_stream_data_uni: 6_291_456,
            initial_max_streams_bidi: 100,
            initial_max_streams_uni: 103,
            max_ack_delay: Duration::from_millis(25),
            active_connection_id_limit: None,
            max_udp_payload_size: 1472,
            datagram_receive_buffer_size: Some(65536),
        };
        Ok(QuicProfile::standard()
            .with_versions(versions)
            .with_transport_parameters(parameters)
            .with_connection_ids(connection_ids)
            .with_packetization(packetization)
            .try_with_limits(limits)?
            .with_grease_quic_bit(false))
    };
    checked().expect("a valid Chrome profile")
}

/// Firefox 156 (Mozilla's neqo), as captured over IPv6.
///
/// A v1 first flight offering v2 first and v1 second, with a reserved version before both;
/// transport parameters in a fixed order, including neqo's empty `0x1d` parameter and the
/// draft-01 `min_ack_delay` codepoint, and no greased parameter; an eight-byte destination
/// and three-byte source connection ID; 1232-byte Initial datagrams padded with zero bytes
/// after the packet, one-byte packet numbers, CRYPTO frames in order, Handshake packets
/// coalesced with Initials; no QUIC bit greasing.
///
/// The capture's first packet numbers are not reproduced because the capture does not show
/// what they follow from. Offering v2 as a
/// compatible version needs a TLS backend that changes version mid-handshake, which only
/// BoringSSL does; applying this profile to a Rustls client fails for that reason.
#[must_use]
#[expect(
    clippy::expect_used,
    reason = "the values are constants taken from a capture and checked by this crate's tests"
)]
pub(crate) fn firefox_156() -> QuicProfile {
    let checked = || -> Result<QuicProfile, super::ProfileError> {
        let versions = ClientVersionPolicy::new(Version::V1)?
            .try_with_compatible(vec![Version::V2, Version::V1])?
            .try_with_supported(vec![Version::V2, Version::V1])?
            .with_reserved_version_grease(ReservedVersionGrease::First);
        let parameters = TransportParameterProfile::standard()
            .try_with_order(ParameterOrder::fixed(vec![
                TransportParameterId::MaxIdleTimeout,
                TransportParameterId::InitialMaxData,
                TransportParameterId::InitialMaxStreamDataBidiLocal,
                TransportParameterId::InitialMaxStreamDataBidiRemote,
                TransportParameterId::InitialMaxStreamDataUni,
                TransportParameterId::InitialMaxStreamsBidi,
                TransportParameterId::InitialMaxStreamsUni,
                TransportParameterId::MaxAckDelay,
                TransportParameterId::ActiveConnectionIdLimit,
                TransportParameterId::InitialSourceConnectionId,
                TransportParameterId::VersionInformation,
                TransportParameterId::from(0x1d),
                TransportParameterId::from(0xff02_de1a),
                TransportParameterId::MaxDatagramFrameSize,
            ]))?
            .try_with_grease(GreaseParameter::None)?
            .try_with_extra(vec![
                OpaqueParameter {
                    id: TransportParameterId::from(0x1d),
                    value: Vec::new(),
                },
                // min_ack_delay as draft-ietf-quic-ack-frequency-01 numbered it: 1000 µs.
                OpaqueParameter {
                    id: TransportParameterId::from(0xff02_de1a),
                    value: vec![0x43, 0xe8],
                },
            ])?
            .with_min_ack_delay(false)
            .try_with_max_datagram_frame_size(Some(65535))?;
        let connection_ids = ConnectionIdProfile::standard()
            .try_with_initial_destination_len(8)?
            .try_with_local_len(3)?;
        let packetization = PacketizationProfile::standard()
            .try_with_initial_datagram_size(1232)?
            .try_with_packet_number_length(PacketNumberLength::Minimal)?
            .with_layout(InitialFlightLayout::Ordered)
            .with_padding(PaddingPlacement::DatagramTail)
            .with_coalesce(true);
        let limits = TransportLimits {
            max_idle_timeout: Duration::from_secs(30),
            initial_max_data: 25_165_824,
            initial_max_stream_data_bidi_local: 12_582_912,
            initial_max_stream_data_bidi_remote: 1_048_576,
            initial_max_stream_data_uni: 1_048_576,
            initial_max_streams_bidi: 100,
            initial_max_streams_uni: 100,
            max_ack_delay: Duration::from_millis(20),
            // Firefox advertises eight independently of the engine queue capacity.
            active_connection_id_limit: Some(8),
            max_udp_payload_size: 65527,
            datagram_receive_buffer_size: Some(65535),
        };
        Ok(QuicProfile::standard()
            .with_versions(versions)
            .with_transport_parameters(parameters)
            .with_connection_ids(connection_ids)
            .with_packetization(packetization)
            .try_with_limits(limits)?
            .with_grease_quic_bit(false))
    };
    checked().expect("a valid Firefox profile")
}
