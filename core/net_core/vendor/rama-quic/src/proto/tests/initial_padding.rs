use std::sync::Arc;

use rama_quic_proto::{
    Version,
    profile::{PacketizationProfile, PaddingPlacement, QuicProfile, TransportLimits},
    version::LongKind,
};

use super::util::{Pair, client_config, server_config};
use crate::proto::{EndpointConfig, TransportConfig};

#[test]
fn initial_datagrams_respect_configured_minimum_mtu_on_both_sides() {
    for version in [Version::V1, Version::V2] {
        for minimum in [1200, 1500] {
            for coalesce in [false, true] {
                for padding in [PaddingPlacement::Frames, PaddingPlacement::DatagramTail] {
                    let profile = QuicProfile::standard()
                        .with_packetization(
                            PacketizationProfile::standard()
                                .with_coalesce(coalesce)
                                .with_padding(padding),
                        )
                        .try_with_limits(TransportLimits {
                            max_udp_payload_size: 2000,
                            ..TransportLimits::standard()
                        })
                        .unwrap();
                    let mut transport = TransportConfig::from_quic_profile(&profile).unwrap();
                    transport.set_initial_mtu(1500).set_min_mtu(minimum);
                    let transport = Arc::new(transport);
                    let mut server = server_config();
                    server.set_transport_config(transport.clone());
                    let mut client = client_config();
                    client.set_transport_config(transport);
                    client.set_version(version).unwrap();
                    // The endpoint receive capacity must match the profile's
                    // advertised payload limit before a connection is allocated.
                    let mut endpoint = EndpointConfig::try_with_rand_key().unwrap();
                    endpoint.max_udp_payload_size(2000).unwrap();
                    let mut pair = Pair::new(Arc::new(endpoint), server);
                    pair.mtu = 2000;
                    pair.connect_with(client);
                    for sent in [&pair.client_sent, &pair.server_sent] {
                        let initial = sent
                            .iter()
                            .find(|datagram| {
                                datagram
                                    .packets
                                    .iter()
                                    .any(|packet| packet.long_kind() == Some(LongKind::Initial))
                            })
                            .expect("the successful handshake sent an Initial");
                        assert!(
                            initial.bytes >= usize::from(minimum),
                            "{version:?}, minimum {minimum}, coalesce {coalesce}, padding {padding:?}: {}",
                            initial.bytes
                        );
                    }
                }
            }
        }
    }
}
