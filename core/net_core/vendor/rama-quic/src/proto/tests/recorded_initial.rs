//! Native recorded layouts: authenticate emitted packets, then complete a real handshake.

use std::sync::{
    Arc,
    atomic::{AtomicUsize, Ordering},
};

use rama_core::bytes::{Bytes, BytesMut};
use rama_quic_proto::{
    ConnectionId, Side, Version,
    capture::{CaptureError, CaptureLimits, FirstFlight, InitialKeys, KeyProvider, ObservedFrame},
    coding::BufMutExt as _,
    crypto::{CryptoError, HeaderKey, PacketKey},
    packet::{Header, InitialHeader, PacketNumber},
    peek::{InitialPeek, PeekError},
    profile::{
        GreaseParameter, InitialFlightLayout, PacketizationProfile, QuicProfile,
        initial::{InitialFrame, InitialPacket, RecordedInitialFlight},
    },
    version::ClientVersionPolicy,
};

use super::{
    EndpointConfig, Pair,
    util::{client_config, server_config},
};
use crate::profile::capture;

fn base_profile(version: Version) -> QuicProfile {
    let profile = QuicProfile::standard().with_versions(ClientVersionPolicy::new(version).unwrap());
    // Unconstrained GREASE value length intentionally changes the fresh hello's
    // extent. This test fixes that native policy, rather than guessing or padding TLS.
    profile.clone().with_transport_parameters(
        profile
            .transport_parameters()
            .clone()
            .try_with_grease(GreaseParameter::None)
            .unwrap(),
    )
}

fn pair(profile: &QuicProfile) -> (Pair, crate::proto::ClientConfig) {
    let mut endpoint = EndpointConfig::try_with_rand_key().unwrap();
    endpoint.apply_quic_profile(profile).unwrap();
    let pair = Pair::new(Arc::new(endpoint), server_config());
    let mut client = client_config();
    client.apply_quic_profile(profile).unwrap();
    (pair, client)
}

fn flight(pair: &Pair) -> FirstFlight {
    let buffers: Vec<&[u8]> = pair
        .server
        .inbound
        .iter()
        .map(|datagram| datagram.packet.as_ref())
        .collect();
    capture::first_flight(&buffers, &*server_config().crypto.into_fixed()).unwrap()
}

fn recorded_profile(version: Version, trailing_bytes: [u16; 2]) -> QuicProfile {
    recorded_profile_numbered(version, trailing_bytes, [1, 2])
}

/// `numbers` are the packet numbers in wire order; `[2, 1]` sends the later packet first.
fn recorded_profile_numbered(
    version: Version,
    trailing_bytes: [u16; 2],
    numbers: [u64; 2],
) -> QuicProfile {
    // Learn the actual provider's fresh ClientHello extent. The target handshake
    // has different random/key-share bytes but the same configured wire shape.
    let base = base_profile(version);
    let (mut source, client) = pair(&base);
    source.begin_connect(client);
    source.drive_client();
    let source = flight(&source);
    let extent = source
        .frames
        .iter()
        .flatten()
        .filter_map(|frame| match frame {
            ObservedFrame::Crypto { offset, len } => Some(*offset as usize + len),
            _ => None,
        })
        .max()
        .unwrap();
    let split = extent / 2;
    let cid = ConnectionId::try_from_bytes(&vec![0; source.dcid_len]).unwrap();
    let scid = ConnectionId::try_from_bytes(&vec![0; source.scid_len]).unwrap();
    let keys = server_config()
        .crypto
        .into_fixed()
        .initial_keys(version, &cid)
        .unwrap();
    let tag_len = keys.local.packet.tag_len();
    let packets = [(split, extent - split), (0, split)]
        .into_iter()
        .enumerate()
        .map(|(index, (offset, len))| {
            let number = numbers[index];
            let tail = trailing_bytes[index];
            let packet_size = 1252 - usize::from(tail);
            let width = index as u8 + 1;
            let mut header = Vec::new();
            Header::Initial(InitialHeader {
                dst_cid: cid,
                src_cid: scid,
                token: Bytes::new(),
                number: PacketNumber::new_at_least(number, 0, width).unwrap(),
                version: version.to_wire().unwrap(),
            })
            .encode_with_max_packet_len(&mut header, packet_size);
            let frames = vec![
                InitialFrame::Ping,
                InitialFrame::Crypto {
                    offset: offset as u64,
                    len,
                },
            ];
            let unpadded =
                InitialPacket::try_new(number, width, 1252, tail, frames.clone()).unwrap();
            let padding = packet_size - header.len() - tag_len - unpadded.payload_len();
            let mut frames = frames;
            frames.insert(1, InitialFrame::Padding { len: padding });
            InitialPacket::try_new(number, width, 1252, tail, frames).unwrap()
        })
        .collect();
    let layout = RecordedInitialFlight::try_new(
        version,
        source.dcid_len as u8,
        source.scid_len as u8,
        packets,
    )
    .unwrap();
    base.with_packetization(
        PacketizationProfile::standard().with_layout(InitialFlightLayout::Recorded(layout)),
    )
}

#[test]
fn recorded_initial_emits_exact_frames_and_widths_then_completes() {
    for version in [Version::V1, Version::V2] {
        let profile = recorded_profile(version, [0, 0]);
        let InitialFlightLayout::Recorded(expected) = profile.packetization().layout() else {
            panic!("the test constructs a recorded layout with PADDING then CRYPTO")
        };
        let (mut pair, client) = pair(&profile);
        let client = pair.begin_connect(client);
        pair.drive_client();
        let observed = flight(&pair);
        let actual = RecordedInitialFlight::try_from(&observed).unwrap();
        assert_eq!(&actual, expected);
        assert_eq!(observed.packet_number_lengths, [1, 2]);
        assert_eq!(observed.datagram_sizes, [1252, 1252]);
        assert!(pair.client_sent.iter().all(|sent| sent.packets.len() == 1));
        pair.drive();
        let server = pair.server.assert_accept();
        assert!(!pair.client_conn_mut(client).is_handshaking());
        assert!(!pair.server_conn_mut(server).is_handshaking());
    }
}

#[test]
fn recorded_initial_sends_a_reordered_burst_in_its_wire_order_then_completes() {
    for version in [Version::V1, Version::V2] {
        let profile = recorded_profile_numbered(version, [0, 0], [2, 1]);
        let InitialFlightLayout::Recorded(expected) = profile.packetization().layout() else {
            panic!("the test constructs a recorded layout")
        };
        let (mut pair, client) = pair(&profile);
        let client = pair.begin_connect(client);
        pair.drive_client();
        let observed = flight(&pair);
        assert_eq!(observed.packet_numbers, [2, 1]);
        assert_eq!(observed.first_packet_number, 2);
        assert_eq!(observed.datagram_sizes, [1252, 1252]);
        assert_eq!(
            &RecordedInitialFlight::try_from(&observed).unwrap(),
            expected
        );
        pair.drive();
        let server = pair.server.assert_accept();
        assert!(!pair.client_conn_mut(client).is_handshaking());
        assert!(!pair.server_conn_mut(server).is_handshaking());
    }
}

struct CountingKeys<'a> {
    provider: capture::ProviderKeys<'a>,
    derivations: AtomicUsize,
    decryptions: Arc<AtomicUsize>,
}

struct CountingPacketKey {
    key: Box<dyn PacketKey>,
    decryptions: Arc<AtomicUsize>,
}

impl PacketKey for CountingPacketKey {
    fn encrypt(&self, number: u64, bytes: &mut [u8], header_len: usize) -> Result<(), CryptoError> {
        self.key.encrypt(number, bytes, header_len)
    }

    fn decrypt(
        &self,
        number: u64,
        header: &[u8],
        payload: &mut BytesMut,
    ) -> Result<(), CryptoError> {
        self.decryptions.fetch_add(1, Ordering::Relaxed);
        self.key.decrypt(number, header, payload)
    }

    fn tag_len(&self) -> usize {
        self.key.tag_len()
    }
    fn confidentiality_limit(&self) -> u64 {
        self.key.confidentiality_limit()
    }
    fn integrity_limit(&self) -> u64 {
        self.key.integrity_limit()
    }
}

impl KeyProvider for CountingKeys<'_> {
    type Header = Box<dyn HeaderKey>;
    type Packet = CountingPacketKey;

    fn initial_keys(
        &self,
        version: Version,
        dcid: &[u8],
        side: Side,
    ) -> Result<InitialKeys<Self::Header, Self::Packet>, CaptureError> {
        self.derivations.fetch_add(1, Ordering::Relaxed);
        let keys = self.provider.initial_keys(version, dcid, side)?;
        Ok(InitialKeys {
            header: keys.header,
            packet: CountingPacketKey {
                key: keys.packet,
                decryptions: self.decryptions.clone(),
            },
        })
    }
}

#[test]
fn native_peek_retains_only_the_complete_initial_prefix_when_requested() {
    for version in [Version::V1, Version::V2] {
        let profile = recorded_profile(version, [0, 7]);
        let (mut pair, client) = pair(&profile);
        pair.begin_connect(client);
        pair.drive_client();
        let expected = flight(&pair);
        let provider = server_config().crypto.into_fixed();
        let keys = CountingKeys {
            provider: capture::ProviderKeys(provider.as_ref()),
            derivations: AtomicUsize::new(0),
            decryptions: Arc::new(AtomicUsize::new(0)),
        };
        let now = pair.time;
        let deadline = now + std::time::Duration::from_secs(1);
        let mut routing = InitialPeek::new(CaptureLimits::default(), deadline);
        let mut retained = InitialPeek::new_with_first_flight(CaptureLimits::default(), deadline);
        for (index, datagram) in pair.server.inbound.iter().enumerate() {
            let plain = routing.inspect(now, &datagram.packet, &keys).unwrap();
            let shaped = retained.inspect(now, &datagram.packet, &keys).unwrap();
            assert_eq!(plain.is_some(), index + 1 == pair.server.inbound.len());
            assert_eq!(shaped.is_some(), plain.is_some());
            if let (Some(plain), Some(shaped)) = (plain, shaped) {
                assert!(plain.first_flight.is_none());
                let observed = shaped.first_flight.expect("requested structural prefix");
                assert_eq!(observed, expected);
                let admitted = RecordedInitialFlight::try_from(&observed).unwrap();
                assert_eq!(admitted.packets().len(), 2);
                assert_eq!(observed.packet_number_lengths, [1, 2]);
                assert_eq!(observed.trailing_bytes, [0, 7]);
            }
        }
        assert_eq!(
            keys.derivations.load(Ordering::Relaxed),
            2,
            "one derivation for each inspector"
        );
        assert_eq!(
            keys.decryptions.load(Ordering::Relaxed),
            2 * expected.packet_numbers.len(),
            "each inspector opens each packet once"
        );
    }
}

#[test]
fn retained_initial_prefix_keeps_cumulative_limits_and_deadline() {
    let profile = recorded_profile(Version::V1, [0, 0]);
    let (mut source, client) = pair(&profile);
    source.begin_connect(client);
    source.drive_client();
    let provider = server_config().crypto.into_fixed();
    let keys = capture::ProviderKeys(provider.as_ref());
    let now = source.time;
    let deadline = now + std::time::Duration::from_secs(1);
    let first_size = source.server.inbound.front().unwrap().packet.len();
    let cases = [
        (
            "datagrams",
            CaptureLimits {
                datagrams: 1,
                ..CaptureLimits::default()
            },
        ),
        (
            "bytes",
            CaptureLimits {
                bytes: first_size,
                ..CaptureLimits::default()
            },
        ),
        (
            "packets",
            CaptureLimits {
                packets: 1,
                ..CaptureLimits::default()
            },
        ),
        (
            "frames",
            CaptureLimits {
                frames: 1,
                ..CaptureLimits::default()
            },
        ),
        (
            "fragments",
            CaptureLimits {
                crypto_fragments: 1,
                ..CaptureLimits::default()
            },
        ),
        (
            "parameters",
            CaptureLimits {
                parameters: 0,
                ..CaptureLimits::default()
            },
        ),
    ];
    for (name, limits) in cases {
        let mut peek = InitialPeek::new_with_first_flight(limits, deadline);
        let mut refused = false;
        for datagram in &source.server.inbound {
            match peek.inspect(now, &datagram.packet, &keys) {
                Ok(None) => {}
                Err(PeekError::Capture(CaptureError::LimitExceeded(_))) => {
                    refused = true;
                    break;
                }
                other => panic!("{name}: expected bounded retention refusal, got {other:?}"),
            }
        }
        assert!(refused, "{name}");
        assert!(matches!(
            peek.inspect(now, &source.server.inbound[0].packet, &keys),
            Err(PeekError::Finished)
        ));
    }
    let mut peek = InitialPeek::new_with_first_flight(CaptureLimits::default(), deadline);
    assert!(
        peek.inspect(now, &source.server.inbound[0].packet, &keys)
            .unwrap()
            .is_none()
    );
    assert!(matches!(
        peek.inspect(deadline, &source.server.inbound[1].packet, &keys),
        Err(PeekError::Deadline)
    ));
}

/// Re-encode real native TLS slices using a legal but wider source integer encoding.
/// Native replay must refuse that shape rather than silently canonicalize its bytes.
#[test]
fn retained_nonminimal_initial_encodings_fall_back_to_native_output() {
    #[derive(Clone, Copy, Debug)]
    enum WiderEncoding {
        CryptoOffset,
        PacketLength,
    }

    for version in [Version::V1, Version::V2] {
        for encoding_kind in [WiderEncoding::CryptoOffset, WiderEncoding::PacketLength] {
            let wider_length = matches!(encoding_kind, WiderEncoding::PacketLength);
            let profile = recorded_profile(version, [0, 0]);
            let (mut source, client) = pair(&profile);
            source.begin_connect(client);
            source.drive_client();
            let provider = server_config().crypto.into_fixed();
            let keys = capture::ProviderKeys(provider.as_ref());
            let mut datagrams = Vec::new();
            for datagram in &source.server.inbound {
                let observed = rama_quic_proto::capture::observe(&datagram.packet).unwrap();
                let opened = observed
                    .unprotect_initials(
                        &datagram.packet,
                        &keys,
                        rama_quic_proto::Side::Server,
                        None,
                    )
                    .unwrap();
                let packet = &opened[0];
                let cid = ConnectionId::try_from_bytes(&packet.header.dcid).unwrap();
                let scid =
                    ConnectionId::try_from_bytes(packet.header.scid.as_ref().unwrap()).unwrap();
                let number =
                    PacketNumber::new_at_least(packet.packet_number, 0, packet.packet_number_len)
                        .unwrap();
                let native_keys = provider.initial_keys(version, &cid).unwrap();
                let write_keys = native_keys.remote.unwrap();
                let mut encoded = Vec::new();
                // Reserving a larger legal Length width creates an actual four-byte encoding.
                let encoding = Header::Initial(InitialHeader {
                    dst_cid: cid,
                    src_cid: scid,
                    token: Bytes::new(),
                    number,
                    version: version.to_wire().unwrap(),
                })
                .encode_with_max_packet_len(
                    &mut encoded,
                    if wider_length {
                        1 << 15
                    } else {
                        datagram.packet.len()
                    },
                );
                let mut widened_crypto = false;
                for frame in &packet.frames {
                    match frame {
                        ObservedFrame::Ping => encoded.push(1),
                        ObservedFrame::Padding { len } => {
                            // Keep the source packet size unchanged after widening its header.
                            let removed = if wider_length {
                                2
                            } else if packet.crypto.iter().any(|(offset, _)| *offset == 0) {
                                1
                            } else {
                                0
                            };
                            encoded.resize(encoded.len() + len - removed, 0);
                        }
                        ObservedFrame::Crypto { offset, .. } => {
                            let (_, data) =
                                packet.crypto.iter().find(|(at, _)| at == offset).unwrap();
                            encoded.push(6);
                            if !wider_length && *offset == 0 {
                                encoded.extend_from_slice(&[0x40, 0]);
                                widened_crypto = true;
                            } else {
                                encoded.write_var(*offset);
                            }
                            encoded.write_var(data.len() as u64);
                            encoded.extend_from_slice(data);
                        }
                        other => panic!("fixture has an unsupported frame: {other:?}"),
                    }
                }
                assert!(
                    wider_length
                        || widened_crypto
                        || packet.crypto.iter().all(|(offset, _)| *offset != 0)
                );
                encoded.resize(encoded.len() + write_keys.packet.tag_len(), 0);
                assert_eq!(encoded.len(), datagram.packet.len());
                encoding
                    .finish(
                        &mut encoded,
                        &*write_keys.header,
                        Some((packet.packet_number, &*write_keys.packet)),
                    )
                    .unwrap();
                datagrams.push(encoded);
            }
            let now = source.time;
            let mut peek = InitialPeek::new_with_first_flight(
                CaptureLimits::default(),
                now + std::time::Duration::from_secs(1),
            );
            let mut complete = None;
            for datagram in &datagrams {
                complete = peek.inspect(now, datagram, &keys).unwrap();
            }
            let observed = complete
                .expect("legal source Initials still reassemble")
                .first_flight
                .unwrap();
            let layout = RecordedInitialFlight::try_from(&observed).unwrap();
            let requested = profile.with_packetization(
                PacketizationProfile::standard().with_layout(InitialFlightLayout::Recorded(layout)),
            );
            // The canonical encoder cannot reproduce the wider source geometry,
            // so the connection packetizes its Initial natively and completes.
            let (mut target, client) = pair(&requested);
            let client = target.begin_connect(client);
            target.drive();
            let server = target.server.assert_accept();
            assert!(!target.client_conn_mut(client).is_handshaking());
            assert!(!target.server_conn_mut(server).is_handshaking());
        }
    }
}

#[test]
fn recorded_initial_loss_recovers_through_normal_crypto_retransmission() {
    let profile = recorded_profile(Version::V1, [0, 0]);
    let (mut pair, client) = pair(&profile);
    let client = pair.begin_connect(client);
    pair.drive_client();
    // Drop the packet containing the start of ClientHello. The peer cannot
    // complete TLS until recovery retransmits the tracked fresh CRYPTO ranges.
    pair.server.inbound.pop_back().unwrap();
    pair.drive();
    let server = pair.server.assert_accept();
    assert!(!pair.client_conn_mut(client).is_handshaking());
    assert!(!pair.server_conn_mut(server).is_handshaking());
    assert!(pair.client_sent.len() > 2);
}

#[test]
fn recorded_initial_with_wrong_fresh_extent_or_geometry_falls_back_to_native() {
    let valid = recorded_profile(Version::V1, [0, 0]);
    let InitialFlightLayout::Recorded(layout) = valid.packetization().layout() else {
        panic!("the test constructs a recorded layout with PADDING then CRYPTO")
    };
    for wrong_extent in [false, true] {
        let mut packets = layout.packets().to_vec();
        let packet = &packets[1];
        let mut frames = packet.frames().to_vec();
        match &mut frames[if wrong_extent { 2 } else { 1 }] {
            InitialFrame::Crypto { len, .. } | InitialFrame::Padding { len } => *len += 1,
            _ => panic!("the test constructs a recorded layout with PADDING then CRYPTO"),
        }
        packets[1] = InitialPacket::try_new(
            packet.number(),
            packet.number_len(),
            packet.datagram_size(),
            packet.trailing_bytes(),
            frames,
        )
        .unwrap();
        // Increasing the final range also increases the required fresh extent.
        // The second packet carries the beginning, so change the end range instead.
        if wrong_extent {
            let first = &packets[0];
            let mut frames = first.frames().to_vec();
            if let InitialFrame::Crypto { offset, len } = &mut frames[2] {
                *offset += 1;
                *len += 1;
            }
            packets[0] = InitialPacket::try_new(
                first.number(),
                first.number_len(),
                first.datagram_size(),
                first.trailing_bytes(),
                frames,
            )
            .unwrap();
        }
        let changed = RecordedInitialFlight::try_new(
            layout.version(),
            layout.destination_cid_len(),
            layout.source_cid_len(),
            packets,
        )
        .unwrap();
        let profile = valid.clone().with_packetization(
            PacketizationProfile::standard()
                .with_layout(InitialFlightLayout::Recorded(changed.clone())),
        );
        // An incompatible original layout is not used: the native Initial
        // completes the handshake instead.
        let (mut pair, client) = pair(&profile);
        let client = pair.begin_connect(client);
        pair.drive_client();
        let observed = flight(&pair);
        assert_ne!(
            &RecordedInitialFlight::try_from(&observed).unwrap(),
            &changed
        );
        pair.drive();
        let server = pair.server.assert_accept();
        assert!(!pair.client_conn_mut(client).is_handshaking());
        assert!(!pair.server_conn_mut(server).is_handshaking());
    }
}

#[test]
fn recorded_initial_tails_stay_outside_protection_and_recovery_counts_them() {
    for version in [Version::V1, Version::V2] {
        for dropped in [None, Some(0), Some(1)] {
            // Firefox's observed 1252-byte UDP shape includes a 997-byte
            // protected Initial plus a 255-byte ignored tail. The second
            // packet uses another tail length to prevent a burst-wide shortcut.
            let profile = recorded_profile(version, [255, 31]);
            let InitialFlightLayout::Recorded(expected) = profile.packetization().layout() else {
                panic!("the fixture supplies a recorded Initial layout")
            };
            let (mut pair, client) = pair(&profile);
            let client = pair.begin_connect(client);
            pair.drive_client();
            let observed = flight(&pair);
            assert_eq!(observed.trailing_bytes, [255, 31]);
            assert_eq!(observed.datagram_sizes, [1252, 1252]);
            assert_eq!(
                &RecordedInitialFlight::try_from(&observed).unwrap(),
                expected
            );
            assert_eq!(pair.client_conn_mut(client).bytes_in_flight(), 2504);

            for (datagram, tail) in pair.server.inbound.iter().zip([255, 31]) {
                assert!(
                    datagram.packet[datagram.packet.len() - tail..]
                        .iter()
                        .all(|byte| *byte == 0)
                );
            }
            if let Some(index) = dropped {
                pair.server.inbound.remove(index).unwrap();
            }
            pair.drive();
            let server = pair.server.assert_accept();
            assert!(!pair.client_conn_mut(client).is_handshaking());
            assert!(!pair.server_conn_mut(server).is_handshaking());
            assert_eq!(pair.client_conn_mut(client).bytes_in_flight(), 0);
        }
    }
}
