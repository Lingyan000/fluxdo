//! Profiles against their captures, and the observer-separation property: a profile changes
//! only what it says at each level of visibility.

#![expect(
    clippy::unwrap_used,
    clippy::expect_used,
    clippy::panic,
    reason = "a test's fixtures fail the test by panicking"
)]

#[cfg(all(feature = "rustls", any(feature = "aws-lc", feature = "ring")))]
use std::assert_matches;

#[cfg(feature = "boring")]
use rama_quic_proto::profile::ParameterOrderEntry;

use rama_core::{bytes::BytesMut, rt::Executor};
use rama_crypto::hmac::HmacSha2;
use rama_quic_proto::{
    ConnectionId, Side,
    capture::{
        CaptureError, CaptureLimits, FirstFlight, InitialKeys, KeyProvider, ObservedFrame,
        PacketKind, first_flight_with_limits, observe,
    },
    crypto::{HeaderKey as _, PacketKey as _},
    peek::{InitialPeek, PeekError},
    transport_parameters::TransportParameterId,
    version::{ClientVersionPolicy, LongKind, Version},
};
use rama_tls::client::{ClientHello, TlsClientConfig};
#[cfg(feature = "boring")]
use rama_tls::client::{ClientHelloExtension, ServerVerifyMode};
use rand::{SeedableRng, rngs::StdRng};
use std::{
    cell::Cell,
    net::{Ipv4Addr, SocketAddr},
    sync::Arc,
    time::{Duration, Instant},
};

use super::{
    browsers::{chrome_153, firefox_156},
    capture, *,
};
use crate::proto::{cid_generator::RandomConnectionIdGenerator, transport_parameters};
use crate::{ClientConfig, Endpoint, EndpointConfig};

macro_rules! include_fixture {
    ($name:literal) => {
        include_str!(concat!("../fixtures/", $name))
    };
}

fn hex(name: &str) -> Vec<u8> {
    let text = include_fixture(name);
    rama_utils::hex::decode(text.split_whitespace().collect::<String>()).expect("a hex fixture")
}

fn include_fixture(name: &str) -> &'static str {
    match name {
        "chrome-155-initial-1.hex" => include_fixture!("chrome-155-initial-1.hex"),
        "chrome-155-initial-2.hex" => include_fixture!("chrome-155-initial-2.hex"),
        "chrome-153-initial-1.hex" => include_fixture!("chrome-153-initial-1.hex"),
        "chrome-153-initial-2.hex" => include_fixture!("chrome-153-initial-2.hex"),
        "firefox-156-initial-1.hex" => include_fixture!("firefox-156-initial-1.hex"),
        "firefox-156-initial-2.hex" => include_fixture!("firefox-156-initial-2.hex"),
        "safari-26.5-initial-1.hex" => include_fixture!("safari-26.5-initial-1.hex"),
        "safari-26.5-initial-2.hex" => include_fixture!("safari-26.5-initial-2.hex"),
        "rama-standard-initial-1.hex" => include_fixture!("rama-standard-initial-1.hex"),
        other => panic!("unknown fixture {other}"),
    }
}

/// A server-side crypto provider, for reading a first flight back.
fn provider() -> std::sync::Arc<dyn crate::proto::crypto::ServerConfig> {
    let identity = crate::test_helpers::identity();
    let server = crate::test_helpers::server(&identity);
    server.crypto.into_fixed()
}

/// The parameter identifiers a capture carried, in order.
fn observed_parameters(datagrams: &[&[u8]]) -> Vec<TransportParameterId> {
    let flight = capture::first_flight(datagrams, &*provider()).expect("a readable first flight");
    flight.parameters
}

#[test]
fn a_capture_reads_back_as_the_client_it_was() {
    let one = hex("chrome-153-initial-1.hex");
    let two = hex("chrome-153-initial-2.hex");
    let flight = capture::first_flight(&[&one, &two], &*provider()).expect("chrome's first flight");
    assert_eq!(flight.version, Version::V1);
    assert_eq!(flight.dcid_len, 8);
    assert_eq!(flight.scid_len, 0);
    assert_eq!(flight.token_len, 0);
    assert_eq!(flight.datagram_sizes, vec![1230, 1230]);
    assert_eq!(flight.trailing_bytes, vec![0, 0]);
    assert_eq!(flight.chosen_version, Some(Version::V1));
    // Chrome's version_information: a greased reserved version, then v1.
    assert_eq!(flight.available_versions.len(), 2);
    assert!(flight.available_versions[0].is_reserved());
    assert_eq!(flight.available_versions[1], Version::V1);

    let ff_one = hex("firefox-156-initial-1.hex");
    let ff_two = hex("firefox-156-initial-2.hex");
    let flight =
        capture::first_flight(&[&ff_one, &ff_two], &*provider()).expect("firefox's first flight");
    assert_eq!(flight.dcid_len, 8);
    assert_eq!(flight.scid_len, 3);
    assert_eq!(flight.datagram_sizes, vec![1232, 1232]);
    // Firefox pads with zero bytes after the packet.
    assert_eq!(flight.padding, PaddingPlacement::DatagramTail);
    assert!(flight.trailing_bytes.iter().all(|&tail| tail > 0));
    // Its version_information offers v2 before v1, behind a greased version.
    assert_eq!(flight.chosen_version, Some(Version::V1));
    assert!(flight.available_versions.contains(&Version::V2));
    assert!(flight.available_versions.contains(&Version::V1));
    assert!(flight.available_versions.iter().any(|v| v.is_reserved()));
}

/// The observer split reads only the invariant header (RFC 8999 §5), so it works without keys.
#[test]
fn the_observer_split_needs_no_keys() {
    for name in ["chrome-153-initial-1.hex", "firefox-156-initial-1.hex"] {
        let datagram = hex(name);
        let observed = observe(&datagram).expect("a datagram splits");
        let first = &observed.packets[0];
        assert_eq!(first.kind, PacketKind::Initial);
        assert_eq!(first.version, Some(Version::V1));
        assert_eq!(first.dcid.len(), 8);
    }
}

/// Build a client with a profile, capture the datagrams of its own first flight through a
/// loopback socket, and return what a server reads from it, together with whether the client's
/// TLS backend can change version mid-handshake (so the profile's compatible offer stands).
fn rama_first_flight(profile: &QuicProfile) -> (FirstFlight, bool) {
    let identity = crate::test_helpers::identity();
    let (flight, capable, _) =
        rama_first_flight_with(profile, crate::test_helpers::client(&identity), "localhost");
    (flight, capable)
}

/// Rama's first flight for `profile` over `client_config`, with the ClientHello it carried.
fn rama_first_flight_with(
    profile: &QuicProfile,
    mut client_config: ClientConfig,
    server_name: &str,
) -> (FirstFlight, bool, ClientHello) {
    let runtime = tokio::runtime::Builder::new_multi_thread()
        .enable_all()
        .build()
        .unwrap();
    runtime.block_on(async move {
        let peer = tokio::net::UdpSocket::bind(SocketAddr::new(Ipv4Addr::LOCALHOST.into(), 0))
            .await
            .unwrap();
        let server_addr = peer.local_addr().unwrap();

        let mut endpoint_config = crate::EndpointConfig::try_with_rand_key().unwrap();
        endpoint_config.apply_quic_profile(profile).unwrap();
        // The round trip exercises packetization and parameters; a backend that cannot change
        // version mid-handshake offers only the first flight's version, which the caller knows.
        let capable = client_config.apply_quic_profile(profile).is_ok();
        if !capable {
            let narrowed = profile
                .clone()
                .with_versions(profile.versions().clone().narrowed_public());
            client_config.apply_quic_profile(&narrowed).unwrap();
        }

        let client = Endpoint::build(Executor::new())
            .with_config(endpoint_config)
            .bind_address(SocketAddr::new(Ipv4Addr::LOCALHOST.into(), 0))
            .await
            .unwrap();
        let connecting = client
            .connect_with(client_config, server_addr, server_name)
            .unwrap();

        // Collect datagrams until the ClientHello reassembles into a first flight with its
        // parameters, so a timing-dependent later datagram cannot truncate the read.
        let mut datagrams: Vec<Vec<u8>> = Vec::new();
        let initial_provider = provider();
        let keys = capture::ProviderKeys(initial_provider.as_ref());
        let mut peek = InitialPeek::new(
            CaptureLimits::default(),
            Instant::now() + Duration::from_secs(5),
        );
        let mut peeked = None;
        let flight = loop {
            let mut buf = vec![0u8; 2048];
            let (len, _from) =
                tokio::time::timeout(std::time::Duration::from_secs(5), peer.recv_from(&mut buf))
                    .await
                    .expect("the client sends within the deadline")
                    .unwrap();
            buf.truncate(len);
            if peeked.is_none() {
                peeked = peek.inspect(Instant::now(), &buf, &keys).unwrap();
            }
            datagrams.push(buf);
            let borrowed: Vec<&[u8]> = datagrams.iter().map(Vec::as_slice).collect();
            match capture::first_flight(&borrowed, &*provider()) {
                Ok(flight) if peeked.is_some() => break flight,
                _ if datagrams.len() >= 8 => {
                    panic!("the client hello did not reassemble from its first flight")
                }
                _ => {}
            }
        };
        let peeked = peeked.expect("the peek completes with the first flight");
        drop(connecting);
        client.close(0u32, b"done");
        (flight, capable, peeked.client_hello)
    })
}

#[test]
fn the_standard_profile_produces_a_standard_first_flight() {
    let (flight, capable) = rama_first_flight(&QuicProfile::standard());
    assert_eq!(flight.version, Version::V1);
    assert_eq!(flight.dcid_len, 20);
    assert_eq!(flight.datagram_sizes[0], 1200);
    assert_eq!(flight.padding, PaddingPlacement::Frames);
    assert!(flight.available_versions.contains(&Version::V1));
    // The default policy offers v2 as a compatible version; a backend that cannot switch
    // narrows that to v1 only.
    assert_eq!(flight.available_versions.contains(&Version::V2), capable);
}

/// A profile's connection-ID lengths, datagram size, packet-number length, padding placement
/// and coalescing show up in rama's own first flight.
#[test]
fn a_profile_shapes_ramas_first_flight() {
    let profile = QuicProfile::standard()
        .with_connection_ids(
            ConnectionIdProfile::standard()
                .try_with_initial_destination_len(12)
                .unwrap()
                .try_with_local_len(4)
                .unwrap(),
        )
        .with_packetization(
            PacketizationProfile::standard()
                .try_with_initial_datagram_size(1350)
                .unwrap()
                .try_with_packet_number_length(PacketNumberLength::AtLeast(4))
                .unwrap()
                .with_padding(PaddingPlacement::DatagramTail),
        );
    let (flight, _capable_flight) = rama_first_flight(&profile);
    assert_eq!(flight.dcid_len, 12);
    assert_eq!(flight.scid_len, 4);
    assert!(flight.datagram_sizes.iter().all(|&size| size == 1350));
    assert_eq!(flight.packet_number_len, 4);
    assert_eq!(flight.padding, PaddingPlacement::DatagramTail);
    // The zero-byte tail brings the flight's last datagram up to size.
    assert!(flight.trailing_bytes.iter().any(|&tail| tail > 0));
}

/// A fixed transport-parameter order is reproduced on the wire.
#[test]
fn a_fixed_parameter_order_is_reproduced() {
    let order = vec![
        TransportParameterId::MaxIdleTimeout,
        TransportParameterId::InitialSourceConnectionId,
        TransportParameterId::InitialMaxData,
        TransportParameterId::VersionInformation,
    ];
    let profile = QuicProfile::standard().with_transport_parameters(
        TransportParameterProfile::standard()
            .try_with_order(ParameterOrder::fixed(order.clone()))
            .unwrap()
            .try_with_grease(GreaseParameter::None)
            .unwrap(),
    );
    let (flight, _capable_flight) = rama_first_flight(&profile);
    // The named parameters lead, in the order given; the rest follow.
    assert_eq!(&flight.parameters[..order.len()], &order[..]);
}

/// An extra vendor parameter is written, and a greased one lands where the order puts it.
#[test]
fn extra_and_greased_parameters_are_written() {
    let profile = QuicProfile::standard().with_transport_parameters(
        TransportParameterProfile::standard()
            .try_with_extra(vec![OpaqueParameter {
                id: TransportParameterId::from(0x3128),
                value: b"TEST".to_vec(),
            }])
            .unwrap()
            .try_with_grease(GreaseParameter::Fixed {
                id: TransportParameterId::from(27),
                value: vec![1, 2, 3],
            })
            .unwrap(),
    );
    let (flight, _capable_flight) = rama_first_flight(&profile);
    assert!(
        flight
            .parameters
            .contains(&TransportParameterId::from(0x3128))
    );
    assert!(flight.parameters.iter().any(|id| id.is_reserved()));
}

/// The browser profiles reproduce the parameter set their capture carried.
#[test]
fn a_browser_profile_offers_the_parameters_its_capture_did() {
    let chrome_capture = observed_parameters(&[
        &hex("chrome-153-initial-1.hex"),
        &hex("chrome-153-initial-2.hex"),
    ]);
    let (chrome, _capable_chrome) = rama_first_flight(&chrome_153());
    for id in &chrome_capture {
        assert!(
            chrome.parameters.contains(id)
                || *id == TransportParameterId::from(0x13c2_9813_4672_b34f),
            "chrome profile is missing parameter {id}"
        );
    }
    // Chrome's greased four-byte parameter, its google_connection_options and its lack of an
    // Initial source CID (empty SCID) are all reproduced.
    assert!(
        chrome
            .parameters
            .contains(&TransportParameterId::from(0x3128))
    );
    assert!(chrome.parameters.iter().any(|id| id.is_reserved()));

    let firefox_capture = observed_parameters(&[
        &hex("firefox-156-initial-1.hex"),
        &hex("firefox-156-initial-2.hex"),
    ]);
    let (firefox, _capable_firefox) = rama_first_flight(&firefox_156());
    for id in &firefox_capture {
        assert!(
            firefox.parameters.contains(id),
            "firefox profile is missing parameter {id}"
        );
    }
}

/// A browser profile reproduces the wire shape its capture showed: version offer, connection
/// ID lengths, datagram size, packet-number length, padding placement and coalescing.
#[test]
fn a_browser_profile_reproduces_its_captured_shape() {
    // Chrome: v1 only with a greased version first, 8/0 CIDs, 1230-byte datagrams, two-byte
    // packet numbers from one, frame padding, chaos layout, no coalescing.
    let (chrome, _capable_chrome) = rama_first_flight(&chrome_153());
    assert_eq!(chrome.version, Version::V1);
    assert_eq!(chrome.dcid_len, 8);
    assert_eq!(chrome.scid_len, 0);
    assert_eq!(chrome.datagram_sizes[0], 1230);
    assert_eq!(chrome.packet_number_len, 2);
    assert_eq!(chrome.first_packet_number, 1);
    assert_eq!(chrome.padding, PaddingPlacement::Frames);
    assert!(chrome.available_versions[0].is_reserved());
    assert_eq!(chrome.chosen_version, Some(Version::V1));
    assert!(!chrome.coalesced);

    // Firefox: 8/3 CIDs, 1232-byte datagrams padded after the packet, v2 offered before v1.
    let (firefox, capable) = rama_first_flight(&firefox_156());
    assert_eq!(firefox.dcid_len, 8);
    assert_eq!(firefox.scid_len, 3);
    assert!(firefox.datagram_sizes.iter().all(|&size| size == 1232));
    assert_eq!(firefox.padding, PaddingPlacement::DatagramTail);
    assert!(firefox.trailing_bytes.iter().any(|&tail| tail > 0));
    // Firefox offers v2 before v1; a backend that cannot switch offers only v1.
    assert_eq!(firefox.available_versions.contains(&Version::V2), capable);
    assert!(firefox.available_versions.iter().any(|v| v.is_reserved()));
}

/// Chaos layout scatters the CRYPTO frames; ordered layout keeps them in order with padding
/// after them. The reassembled ClientHello is the same either way, which the capture read
/// proves by decoding it at all.
#[test]
fn chaos_layout_scatters_crypto_but_keeps_the_client_hello() {
    let (ordered, _capable_ordered) = rama_first_flight(
        &QuicProfile::standard().with_packetization(PacketizationProfile::standard()),
    );
    let ordered_crypto = ordered.frames[0]
        .iter()
        .filter(|frame| matches!(frame, ObservedFrame::Crypto { .. }))
        .count();
    // One CRYPTO frame, then padding, with the padding trailing.
    assert_eq!(ordered_crypto, 1);

    // Chaos scatters at random, so a single flight may occasionally land on one CRYPTO frame and
    // no PING; a handful of flights shows the scattering reliably without a false failure. Every
    // flight must still reassemble into a readable ClientHello.
    let scattered = (0..16).any(|_| {
        let (chaos, _capable_chaos) =
            rama_first_flight(&QuicProfile::standard().with_packetization(
                PacketizationProfile::standard().with_layout(InitialFlightLayout::Chaos),
            ));
        assert!(
            chaos.chosen_version.is_some(),
            "the ClientHello still reassembles"
        );
        let chaos_frames: usize = chaos
            .frames
            .iter()
            .map(|packet| {
                packet
                    .iter()
                    .filter(|frame| {
                        matches!(frame, ObservedFrame::Crypto { .. } | ObservedFrame::Ping)
                    })
                    .count()
            })
            .sum();
        chaos_frames > 1
    });
    assert!(
        scattered,
        "chaos never scattered the frames across 16 flights"
    );
}

/// Every knob a profile changes is checked; an invalid one is refused, not silently accepted.
#[test]
fn invalid_profiles_are_refused() {
    // A first destination CID must be at least 8 bytes.
    ConnectionIdProfile::standard()
        .try_with_initial_destination_len(4)
        .unwrap_err();
    ConnectionIdProfile::standard()
        .try_with_local_len(21)
        .unwrap_err();
    // An Initial datagram must be at least 1200 bytes.
    PacketizationProfile::standard()
        .try_with_initial_datagram_size(1100)
        .unwrap_err();
    PacketizationProfile::standard()
        .try_with_packet_number_length(PacketNumberLength::AtLeast(5))
        .unwrap_err();
    // An extra parameter may not shadow a known one.
    TransportParameterProfile::standard()
        .try_with_extra(vec![OpaqueParameter {
            id: TransportParameterId::MaxIdleTimeout,
            value: Vec::new(),
        }])
        .unwrap_err();
    // A greased parameter must use a reserved identifier.
    TransportParameterProfile::standard()
        .try_with_grease(GreaseParameter::Fixed {
            id: TransportParameterId::from(0x28),
            value: Vec::new(),
        })
        .unwrap_err();
}

#[test]
fn active_connection_id_capacity_is_exact_and_excess_is_clamped() {
    const SAFARI_ACTIVE_CONNECTION_ID_LIMIT: u64 = 64;

    assert_eq!(
        MAX_ACTIVE_CONNECTION_ID_LIMIT,
        SAFARI_ACTIVE_CONNECTION_ID_LIMIT
    );
    let profile = QuicProfile::standard()
        .try_with_limits(TransportLimits {
            active_connection_id_limit: Some(SAFARI_ACTIVE_CONNECTION_ID_LIMIT),
            ..TransportLimits::standard()
        })
        .unwrap();
    let transport = TransportConfig::from_quic_profile(&profile).unwrap();
    assert_eq!(
        transport.active_connection_id_limit,
        Some(SAFARI_ACTIVE_CONNECTION_ID_LIMIT.try_into().unwrap())
    );
    assert_eq!(
        crate::proto::cid_queue::CidQueue::LEN as u64,
        MAX_ACTIVE_CONNECTION_ID_LIMIT
    );

    let unsupported = QuicProfile::standard()
        .try_with_limits(TransportLimits {
            active_connection_id_limit: Some(MAX_ACTIVE_CONNECTION_ID_LIMIT + 1),
            ..TransportLimits::standard()
        })
        .unwrap();
    let clamped = TransportConfig::from_quic_profile(&unsupported).unwrap();
    assert_eq!(
        clamped.active_connection_id_limit,
        Some(MAX_ACTIVE_CONNECTION_ID_LIMIT.try_into().unwrap())
    );
}

/// A Rustls client cannot offer a compatible version, so the Firefox profile, which offers v2,
/// is refused when applied to a Rustls client. On Boring it is accepted.
#[cfg(feature = "boring")]
#[test]
fn the_firefox_profile_needs_a_switch_capable_backend_on_boring() {
    let identity = crate::test_helpers::identity();
    let mut config = boring_client(&identity);
    config
        .apply_quic_profile(&firefox_156())
        .expect("the firefox profile applies on a switch-capable backend");
}

#[cfg(feature = "boring")]
fn boring_client(identity: &rama_tls::server::ServerAuthData) -> ClientConfig {
    let tls = TlsClientConfig::new()
        .with_alpn([b"rama-quic-test".as_slice().into()].into_iter().collect())
        .try_with_server_trust_anchors([identity.cert_chain.last().unwrap().clone()])
        .unwrap();
    ClientConfig::try_from_rama_tls_with_provider(
        &tls,
        crate::tls::TlsOptions::default(),
        &crate::tls::BoringTlsProvider,
    )
    .unwrap()
}

#[cfg(all(feature = "rustls", any(feature = "aws-lc", feature = "ring")))]
#[test]
fn the_firefox_profile_is_refused_on_a_rustls_client() {
    let identity = crate::test_helpers::identity();
    let tls = TlsClientConfig::new()
        .with_alpn([b"rama-quic-test".as_slice().into()].into_iter().collect())
        .try_with_server_trust_anchors([identity.cert_chain.last().unwrap().clone()])
        .unwrap();
    let mut config =
        ClientConfig::try_from_rama_tls(&tls, crate::tls::TlsOptions::default()).unwrap();
    assert_matches!(
        config.apply_quic_profile(&firefox_156()),
        Err(crate::ConfigError::VersionPolicy(_)),
    );
}

/// An observation is serializable data that may describe another datagram; one whose packet range
/// runs past the bytes handed in is refused, not trusted.
#[test]
fn an_observation_that_outruns_its_datagram_is_refused() {
    let one = hex("chrome-153-initial-1.hex");
    let observed = observe(&one).expect("a chrome Initial");
    let provider = provider();
    let keys = capture::ProviderKeys(&*provider);
    for len in [0, 1, 100, one.len() - 1] {
        let error = observed
            .unprotect_initials(&one[..len], &keys, rama_quic_proto::Side::Server, None)
            .unwrap_err();
        assert!(
            matches!(error, rama_quic_proto::capture::CaptureError::Malformed(_)),
            "{len} bytes: {error:?}"
        );
    }
    observed
        .unprotect_initials(&one, &keys, rama_quic_proto::Side::Server, None)
        .unwrap();
}

/// CRYPTO data repeats when a client retransmits; a chunk already covered by what came before
/// leaves the ClientHello as it was.
#[test]
fn a_covered_crypto_chunk_does_not_lose_the_client_hello() {
    let one = hex("chrome-153-initial-1.hex");
    let two = hex("chrome-153-initial-2.hex");
    let provider = provider();
    let keys = capture::ProviderKeys(&*provider);
    let mut initials = Vec::new();
    for datagram in [&one, &two] {
        initials.extend(
            observe(datagram)
                .unwrap()
                .unprotect_initials(datagram, &keys, rama_quic_proto::Side::Server, None)
                .unwrap(),
        );
    }
    let hello = rama_quic_proto::capture::client_hello(&initials).expect("chrome's ClientHello");
    let mut repeated = initials.clone();
    let (offset, data) = repeated[0].crypto[0].clone();
    repeated[0]
        .crypto
        .push((offset + 1, data[1..data.len() / 2].to_vec()));
    assert_eq!(
        rama_quic_proto::capture::client_hello(&repeated),
        Some(hello)
    );
}

/// An Initial's destination connection ID chooses its keys, so one longer than any version
/// allows (RFC 9000 §17.2) is refused before key derivation, in every build.
#[test]
fn an_oversized_initial_connection_id_is_refused_before_key_derivation() {
    let provider = provider();
    let keys = capture::ProviderKeys(&*provider);
    for len in [21u8, 255] {
        let mut datagram = vec![0xc0, 0, 0, 0, 1, len];
        datagram.extend(std::iter::repeat_n(7, usize::from(len)));
        datagram.extend_from_slice(&[0, 0, 1, 0]);
        let observed = observe(&datagram).expect("the invariant layout parses");
        for side in [rama_quic_proto::Side::Server, rama_quic_proto::Side::Client] {
            let error = observed
                .unprotect_initials(&datagram, &keys, side, None)
                .unwrap_err();
            assert!(
                matches!(error, rama_quic_proto::capture::CaptureError::Malformed(_)),
                "{len}-byte connection ID: {error:?}"
            );
        }
        let Err(rama_quic_proto::capture::CaptureError::Malformed(_)) =
            rama_quic_proto::capture::KeyProvider::initial_keys(
                &keys,
                Version::V1,
                &datagram[6..6 + usize::from(len)],
                rama_quic_proto::Side::Server,
            )
        else {
            panic!("a {len}-byte connection ID reached key derivation");
        };
    }
}

fn verify_passive_provider(keys: &impl KeyProvider) {
    let server = provider();
    for version in [Version::V1, Version::V2] {
        for side in [Side::Client, Side::Server] {
            for cid_len in [0, 8, 20] {
                let cid = vec![0x53; cid_len];
                let expected = server
                    .initial_keys(version, &ConnectionId::try_from_bytes(&cid).unwrap())
                    .unwrap();
                let expected = match side {
                    Side::Server => expected.remote.unwrap(),
                    Side::Client => expected.local,
                };
                let observed = keys.initial_keys(version, &cid, side).unwrap();
                let mut packet = vec![0; 64];
                packet[0] = 0xc0;
                packet[1..5].copy_from_slice(&version.to_be_bytes());
                expected.packet.encrypt(7, &mut packet, 8).unwrap();
                let mut payload = BytesMut::from(&packet[8..]);
                observed
                    .packet
                    .decrypt(7, &packet[..8], &mut payload)
                    .unwrap();
                assert_eq!(&payload[..], &[0; 40]);
                let mut expected_header = packet.clone();
                expected.header.encrypt(5, &mut expected_header);
                let mut observed_header = packet;
                observed.header.encrypt(5, &mut observed_header);
                assert_eq!(observed_header, expected_header);
            }
            for cid_len in [21, 255] {
                assert!(matches!(
                    keys.initial_keys(version, &vec![0; cid_len], side),
                    Err(CaptureError::Malformed(_))
                ));
            }
            let unknown = Version::from_u32(0xface_b00c);
            assert!(matches!(
                keys.initial_keys(unknown, &[0; 8], side),
                Err(CaptureError::UnknownVersion(version)) if version == unknown
            ));
        }
    }
    for names in [
        ["chrome-153-initial-1.hex", "chrome-153-initial-2.hex"],
        ["firefox-156-initial-1.hex", "firefox-156-initial-2.hex"],
    ] {
        let datagrams = names.map(hex);
        let datagrams = datagrams.each_ref().map(Vec::as_slice);
        let expected = capture::first_flight(&datagrams, &*server).unwrap();
        let observed = rama_quic_proto::capture::first_flight(&datagrams, keys).unwrap();
        assert_eq!(observed, expected);
    }
}

#[cfg(feature = "boring")]
#[test]
fn passive_initial_keys_need_no_boring_server_identity() {
    verify_passive_provider(&crate::tls::BoringTlsProvider);
}

#[cfg(all(feature = "rustls", any(feature = "aws-lc", feature = "ring")))]
#[test]
fn passive_initial_keys_need_no_rustls_server_identity() {
    verify_passive_provider(&crate::tls::RustlsTlsProvider::new(
        crate::proto::crypto::rustls::configured_provider(),
    ));
}

#[test]
fn standard_initial_observation_snapshot_and_budgets() {
    let datagrams = [hex("rama-standard-initial-1.hex")];
    let borrowed: Vec<_> = datagrams.iter().map(Vec::as_slice).collect();
    let provider = provider();
    let keys = capture::ProviderKeys(provider.as_ref());
    let flight = first_flight_with_limits(&borrowed, &keys, &CaptureLimits::default()).unwrap();
    assert!(flight.complete);
    let expected: serde_json::Value =
        serde_json::from_str(include_fixture!("rama-standard-first-flight.json")).unwrap();
    assert_eq!(serde_json::to_value(&flight).unwrap(), expected);
    let frame_count = flight.frames.iter().map(Vec::len).sum::<usize>();
    let fragments = flight
        .frames
        .iter()
        .flatten()
        .filter(|f| matches!(f, ObservedFrame::Crypto { .. }))
        .count();
    for limits in [
        CaptureLimits {
            datagrams: datagrams.len() - 1,
            ..CaptureLimits::default()
        },
        CaptureLimits {
            bytes: datagrams.iter().map(Vec::len).sum::<usize>() - 1,
            ..CaptureLimits::default()
        },
        CaptureLimits {
            packets: flight.packet_numbers.len() - 1,
            ..CaptureLimits::default()
        },
        CaptureLimits {
            frames: frame_count - 1,
            ..CaptureLimits::default()
        },
        CaptureLimits {
            crypto_fragments: fragments - 1,
            ..CaptureLimits::default()
        },
        CaptureLimits {
            parameters: flight.parameters.len() - 1,
            ..CaptureLimits::default()
        },
    ] {
        assert!(
            matches!(
                first_flight_with_limits(&borrowed, &keys, &limits),
                Err(CaptureError::LimitExceeded(_))
            ),
            "{limits:?}"
        );
    }
    let incomplete = first_flight_with_limits(
        &borrowed,
        &keys,
        &CaptureLimits {
            client_hello_bytes: 1,
            ..CaptureLimits::default()
        },
    );
    assert!(matches!(
        incomplete,
        Err(CaptureError::LimitExceeded("ClientHello bytes"))
    ));
    let mut duplicate = borrowed.clone();
    duplicate.push(borrowed[0]);
    let repeated = first_flight_with_limits(&duplicate, &keys, &CaptureLimits::default()).unwrap();
    assert_eq!(
        repeated.packet_numbers.len(),
        flight.packet_numbers.len() + 1
    );
    assert_eq!(repeated.frames, flight.frames);
}

#[test]
fn default_and_profile_connection_id_limits_have_independent_wire_values() {
    let endpoint = EndpointConfig::new(HmacSha2::new_256(&[37; 32]));
    let mut rng = StdRng::seed_from_u64(41);

    // The unsent zero-CID default, ordinary endpoint default, and explicit
    // browser limits must not follow changes to internal queue capacity.
    for (cid_len, explicit, expected) in [
        (0, None, 2),
        (8, None, 5),
        (8, Some(2_u32), 2),
        (8, Some(8), 8),
    ] {
        let config = TransportConfig {
            active_connection_id_limit: explicit.map(Into::into),
            ..TransportConfig::default()
        };
        let generator = RandomConnectionIdGenerator::new(cid_len).unwrap();
        let source = ConnectionId::try_from_bytes(&[1; 8][..cid_len]).unwrap();
        let parameters =
            transport_parameters::new(&config, &endpoint, &generator, source, None, &mut rng);
        assert_eq!(parameters.active_connection_id_limit.into_inner(), expected);
    }
}

#[test]
fn excess_connection_id_limit_is_clamped_when_applied_to_a_client() {
    let identity = crate::test_helpers::identity();
    let mut client = crate::test_helpers::client(&identity);
    let profile = QuicProfile::standard()
        .with_versions(ClientVersionPolicy::new(Version::V1).unwrap())
        .with_connection_ids(
            ConnectionIdProfile::standard()
                .try_with_initial_destination_len(12)
                .unwrap(),
        )
        .try_with_limits(TransportLimits {
            active_connection_id_limit: Some(MAX_ACTIVE_CONNECTION_ID_LIMIT + 1),
            ..TransportLimits::standard()
        })
        .unwrap();

    // This is a valid protocol profile exceeding this engine's CID storage.
    client.apply_quic_profile(&profile).unwrap();
    assert_eq!(
        client.transport.active_connection_id_limit,
        Some(MAX_ACTIVE_CONNECTION_ID_LIMIT.try_into().unwrap())
    );
}

#[test]
fn profile_endpoint_mismatches_fail_before_allocating_a_connection() {
    // Endpoint compatibility is independent of the TLS provider's version-switch support.
    let profile =
        QuicProfile::standard().with_versions(ClientVersionPolicy::new(Version::V1).unwrap());
    let identity = crate::test_helpers::identity();
    let mut client = crate::test_helpers::client(&identity);
    client.apply_quic_profile(&profile).unwrap();
    for mismatch in [
        ProfileEndpointMismatch::ConnectionIdLength,
        ProfileEndpointMismatch::QuicBitGreasing,
        ProfileEndpointMismatch::MaximumUdpPayload,
    ] {
        let mut config = EndpointConfig::try_with_rand_key().unwrap();
        config.apply_quic_profile(&profile).unwrap();
        match mismatch {
            ProfileEndpointMismatch::ConnectionIdLength => {
                config.set_connection_id_generator_factory(Arc::new(|| {
                    Box::new(RandomConnectionIdGenerator::new(3).unwrap())
                }));
            }
            ProfileEndpointMismatch::QuicBitGreasing => {
                config.set_grease_quic_bit(!profile.greases_quic_bit());
            }
            ProfileEndpointMismatch::MaximumUdpPayload => {
                config.max_udp_payload_size(1400).unwrap();
            }
        }
        let mut endpoint =
            crate::proto::Endpoint::new(Arc::new(config), None, false, Some([1; 32]));
        let result = endpoint.connect(
            crate::proto::Instant::now(),
            client.clone(),
            SocketAddr::from((Ipv4Addr::LOCALHOST, 443)),
            "localhost",
        );
        assert!(
            matches!(result, Err(crate::ConnectError::ProfileEndpointMismatch(actual)) if actual == mismatch)
        );
        assert_eq!(endpoint.open_connections(), 0);
    }
}

struct CountInitialKeys<P> {
    inner: P,
    calls: Cell<usize>,
}

impl<P: KeyProvider> KeyProvider for CountInitialKeys<P> {
    type Header = P::Header;
    type Packet = P::Packet;

    fn initial_keys(
        &self,
        version: Version,
        dcid: &[u8],
        side: Side,
    ) -> Result<InitialKeys<Self::Header, Self::Packet>, CaptureError> {
        self.calls.set(self.calls.get() + 1);
        self.inner.initial_keys(version, dcid, side)
    }
}

#[test]
fn initial_peek_reassembles_reordered_and_duplicate_browser_datagrams() {
    let server = provider();
    let keys = capture::ProviderKeys(server.as_ref());
    let now = Instant::now();
    for names in [
        ["chrome-153-initial-1.hex", "chrome-153-initial-2.hex"],
        ["firefox-156-initial-1.hex", "firefox-156-initial-2.hex"],
    ] {
        let datagrams = names.map(hex);
        for order in [vec![0, 1], vec![1, 0], vec![0, 0, 1], vec![1, 1, 0]] {
            let mut peek = InitialPeek::new(CaptureLimits::default(), now + Duration::from_secs(1));
            for (index, packet) in order.iter().enumerate() {
                let hello = peek.inspect(now, &datagrams[*packet], &keys).unwrap();
                assert_eq!(hello.is_some(), index + 1 == order.len());
                if let Some(hello) = hello {
                    assert_eq!(hello.version, Version::V1);
                }
            }
            assert!(matches!(
                peek.inspect(now, &datagrams[0], &keys),
                Err(PeekError::Finished)
            ));
        }
    }
}

#[test]
fn initial_peek_charges_cumulative_limits_before_crypto_and_never_renews_deadline() {
    let server = provider();
    let keys = CountInitialKeys {
        inner: capture::ProviderKeys(server.as_ref()),
        calls: Cell::new(0),
    };
    let datagram = hex("chrome-153-initial-1.hex");
    let now = Instant::now();
    let deadline = now + Duration::from_secs(1);
    for limits in [
        CaptureLimits {
            datagrams: 2,
            ..CaptureLimits::default()
        },
        CaptureLimits {
            bytes: 2 * datagram.len(),
            ..CaptureLimits::default()
        },
        CaptureLimits {
            packets: 2,
            ..CaptureLimits::default()
        },
    ] {
        let mut peek = InitialPeek::new(limits, deadline);
        assert!(peek.inspect(now, &datagram, &keys).unwrap().is_none());
        assert!(peek.inspect(now, &datagram, &keys).unwrap().is_none());
        let calls = keys.calls.get();
        peek.inspect(now, &datagram, &keys).unwrap_err();
        assert_eq!(keys.calls.get(), calls);
        assert!(matches!(
            peek.inspect(now, &datagram, &keys),
            Err(PeekError::Finished)
        ));
    }
    let mut peek = InitialPeek::new(CaptureLimits::default(), deadline);
    assert!(peek.inspect(now, &datagram, &keys).unwrap().is_none());
    assert!(
        peek.inspect(
            deadline.checked_sub(Duration::from_nanos(1)).unwrap(),
            &datagram,
            &keys
        )
        .unwrap()
        .is_none()
    );
    let calls = keys.calls.get();
    assert_eq!(peek.deadline(), deadline);
    assert!(matches!(
        peek.inspect(deadline, &datagram, &keys),
        Err(PeekError::Deadline)
    ));
    assert_eq!(keys.calls.get(), calls);
}

#[test]
fn initial_peek_rejects_mixed_attempts_before_crypto() {
    let server = provider();
    let keys = CountInitialKeys {
        inner: capture::ProviderKeys(server.as_ref()),
        calls: Cell::new(0),
    };
    let first = hex("chrome-153-initial-1.hex");
    let second = hex("firefox-156-initial-1.hex");
    let now = Instant::now();
    let mut peek = InitialPeek::new(CaptureLimits::default(), now + Duration::from_secs(1));
    assert!(peek.inspect(now, &first, &keys).unwrap().is_none());
    let calls = keys.calls.get();
    assert!(matches!(
        peek.inspect(now, &second, &keys),
        Err(PeekError::Capture(CaptureError::Malformed(
            "mixed Initial attempts"
        )))
    ));
    assert_eq!(keys.calls.get(), calls);
}

#[test]
fn initial_peek_accepts_runtime_v1_and_v2_flights() {
    for version in [Version::V1, Version::V2] {
        let profile =
            QuicProfile::standard().with_versions(ClientVersionPolicy::new(version).unwrap());
        let (flight, _) = rama_first_flight(&profile);
        assert_eq!(flight.version, version);
    }
}

#[test]
fn initial_peek_terminal_input_is_classified_without_crypto() {
    let server = provider();
    let keys = CountInitialKeys {
        inner: capture::ProviderKeys(server.as_ref()),
        calls: Cell::new(0),
    };
    let now = Instant::now();
    let deadline = now + Duration::from_secs(1);
    let mut peek = InitialPeek::new(CaptureLimits::default(), deadline);
    assert!(matches!(
        peek.inspect(now, &[0x40, 1], &keys),
        Err(PeekError::NotClientFlight)
    ));
    assert!(matches!(
        peek.inspect(now, &[0xc0], &keys),
        Err(PeekError::Finished)
    ));
    assert_eq!(keys.calls.get(), 0);

    // Too short for a version, a Version Negotiation, or an unknown version below an Initial's
    // size: none of these starts a client's flight.
    let mut negotiation = hex("chrome-153-initial-1.hex");
    negotiation[1..5].copy_from_slice(&[0; 4]);
    let mut short_unknown = hex("chrome-153-initial-1.hex");
    short_unknown.truncate(600);
    short_unknown[1..5].copy_from_slice(&[0x12, 0x34, 0x56, 0x78]);
    for datagram in [&[0xc0][..], &negotiation, &short_unknown] {
        let mut peek = InitialPeek::new(CaptureLimits::default(), deadline);
        assert!(matches!(
            peek.inspect(now, datagram, &keys),
            Err(PeekError::NotClientFlight)
        ));
    }
    assert_eq!(keys.calls.get(), 0);

    // A client's Initial fills 1200 bytes and names a destination of at least 8 (RFC 9000 §14.1,
    // §7.2); checked before any key is derived.
    for (dcid, size, reason) in [
        (8, 1199, "Initial datagram below 1200 bytes"),
        (7, 1200, "Initial destination CID below 8 bytes"),
    ] {
        let mut peek = InitialPeek::new(CaptureLimits::default(), deadline);
        assert!(
            matches!(
                peek.inspect(now, &opaque_initial(dcid, size), &keys),
                Err(PeekError::Capture(CaptureError::Malformed(found))) if found == reason
            ),
            "{reason}"
        );
    }
    assert_eq!(keys.calls.get(), 0);

    let mut unknown = hex("chrome-153-initial-1.hex");
    let version = Version::from_be_bytes([0x12, 0x34, 0x56, 0x78]);
    unknown[1..5].copy_from_slice(&[0x12, 0x34, 0x56, 0x78]);
    let mut peek = InitialPeek::new(CaptureLimits::default(), deadline);
    assert!(
        matches!(peek.inspect(now, &unknown, &keys), Err(PeekError::Capture(CaptureError::UnknownVersion(found))) if found == version)
    );
    assert_eq!(keys.calls.get(), 0);
}

#[test]
fn initial_peek_byte_boundary_precedes_crypto() {
    let server = provider();
    let keys = CountInitialKeys {
        inner: capture::ProviderKeys(server.as_ref()),
        calls: Cell::new(0),
    };
    let datagram = hex("chrome-153-initial-1.hex");
    let now = Instant::now();
    let two_datagrams = 2 * datagram.len();
    for bytes in [two_datagrams - 1, two_datagrams, two_datagrams + 1] {
        let mut peek = InitialPeek::new(
            CaptureLimits {
                bytes,
                ..CaptureLimits::default()
            },
            now + Duration::from_secs(1),
        );
        assert!(peek.inspect(now, &datagram, &keys).unwrap().is_none());
        // The attempt's keys are derived once, for its first Initial, and then reused.
        assert_eq!(keys.calls.get(), 1);
        let second = peek.inspect(now, &datagram, &keys);
        if bytes < two_datagrams {
            assert!(matches!(
                second,
                Err(PeekError::Capture(CaptureError::LimitExceeded("bytes")))
            ));
        } else {
            assert!(second.unwrap().is_none());
        }
        assert_eq!(keys.calls.get(), 1);
        keys.calls.set(0);
    }
    // A first datagram past the byte budget derives no keys at all.
    let mut peek = InitialPeek::new(
        CaptureLimits {
            bytes: datagram.len() - 1,
            ..CaptureLimits::default()
        },
        now + Duration::from_secs(1),
    );
    assert!(matches!(
        peek.inspect(now, &datagram, &keys),
        Err(PeekError::Capture(CaptureError::LimitExceeded("bytes")))
    ));
    assert_eq!(keys.calls.get(), 0);
}

/// A v1 Initial with a `dcid`-byte destination and an opaque payload, `size` bytes in all.
fn opaque_initial(dcid: usize, size: usize) -> Vec<u8> {
    let wire = Version::V1.wire().unwrap();
    let mut packet = vec![0xc0 | wire.long_type_bits(LongKind::Initial)];
    packet.extend_from_slice(&Version::V1.to_be_bytes());
    packet.push(dcid.try_into().unwrap());
    packet.resize(packet.len() + dcid, 1);
    packet.push(8);
    packet.extend([2; 8]);
    // No token, then a two-byte length covering the rest of the datagram.
    packet.push(0);
    let payload = size - packet.len() - 2;
    packet.extend_from_slice(&(0x4000 | u16::try_from(payload).unwrap()).to_be_bytes());
    packet.resize(size, 0x55);
    packet
}

#[test]
fn initial_peek_retains_reordered_early_data_as_opaque_metadata() {
    let server = provider();
    let keys = CountInitialKeys {
        inner: capture::ProviderKeys(server.as_ref()),
        calls: Cell::new(0),
    };
    let first = hex("chrome-153-initial-1.hex");
    let second = hex("chrome-153-initial-2.hex");
    let initial = observe(&first).unwrap().packets.remove(0);
    let wire = Version::V1.wire().unwrap();
    let mut early = vec![0xc0 | wire.long_type_bits(LongKind::ZeroRtt)];
    early.extend_from_slice(&Version::V1.to_be_bytes());
    early.push(initial.dcid.len().try_into().unwrap());
    early.extend_from_slice(&initial.dcid);
    let source = initial.scid.unwrap();
    early.push(source.len().try_into().unwrap());
    early.extend_from_slice(&source);
    // The ciphertext is intentionally opaque. The peeker must not ask for
    // application keys or treat these bytes as CRYPTO data.
    early.push(32);
    early.extend_from_slice(&[0; 32]);
    let now = Instant::now();
    let mut peek = InitialPeek::new(CaptureLimits::default(), now + Duration::from_secs(1));
    assert!(peek.inspect(now, &early, &keys).unwrap().is_none());
    assert_eq!(keys.calls.get(), 0);
    assert!(peek.inspect(now, &first, &keys).unwrap().is_none());
    let hello = peek.inspect(now, &second, &keys).unwrap().unwrap();
    assert!(hello.early_data_observed);
    assert_eq!(hello.version, Version::V1);
    // Initial keys only, derived once for the attempt; the opaque 0-RTT asked for none.
    assert_eq!(keys.calls.get(), 1);
}

#[test]
fn profile_datagram_capability_matches_its_transport_parameter() {
    let endpoint = EndpointConfig::new(HmacSha2::new_256(&[37; 32]));
    let generator = RandomConnectionIdGenerator::new(8).unwrap();
    let source = ConnectionId::try_from_bytes(&[1; 8]).unwrap();
    let mut rng = StdRng::seed_from_u64(41);
    for (window, advertised, expected) in [
        (None, None, None),
        (Some(0), None, Some(0)),
        (Some(4096), Some(0), Some(0)),
        (Some(4096), Some(8), Some(8)),
        (Some(8), Some(128), Some(128)),
        (Some(65536), None, Some(65535)),
        (Some(8), Some(65536), Some(65536)),
    ] {
        let profile = QuicProfile::standard()
            .with_transport_parameters(
                TransportParameterProfile::standard()
                    .try_with_max_datagram_frame_size(advertised)
                    .unwrap(),
            )
            .try_with_limits(TransportLimits {
                datagram_receive_buffer_size: window,
                ..TransportLimits::standard()
            })
            .unwrap();
        let config = TransportConfig::from_quic_profile(&profile).unwrap();
        let parameters =
            transport_parameters::new(&config, &endpoint, &generator, source, None, &mut rng);
        assert_eq!(
            parameters.max_datagram_frame_size.map(VarInt::into_inner),
            expected
        );
        assert_eq!(
            config.datagram_receive_enabled(),
            expected.is_some_and(|size| size > 0)
        );
    }
}

#[test]
fn profile_datagram_frame_size_is_dropped_with_reception_disabled() {
    for advertised in [0, 128] {
        let profile = QuicProfile::standard()
            .with_transport_parameters(
                TransportParameterProfile::standard()
                    .try_with_max_datagram_frame_size(Some(advertised))
                    .unwrap(),
            )
            .try_with_limits(TransportLimits {
                datagram_receive_buffer_size: None,
                ..TransportLimits::standard()
            })
            .unwrap();
        let config = TransportConfig::from_quic_profile(&profile).unwrap();
        assert_eq!(config.wire.parameters.max_datagram_frame_size(), None);
        assert!(!config.datagram_receive_enabled());
    }
}

/// Each peek budget holds at the Chrome flight's exact need and fails one below it, by name.
/// Its Initials are padded, yet need few frames: a PADDING run counts once.
#[test]
fn initial_peek_budgets_hold_at_a_real_flights_exact_need() {
    let server = provider();
    let keys = capture::ProviderKeys(server.as_ref());
    let flight = [
        hex("chrome-153-initial-1.hex"),
        hex("chrome-153-initial-2.hex"),
    ];
    let now = Instant::now();
    let run = |limits: CaptureLimits| {
        let mut peek = InitialPeek::new(limits, now + Duration::from_secs(1));
        let mut result = Ok(None);
        for datagram in &flight {
            result = peek.inspect(now, datagram, &keys);
            if !matches!(result, Ok(None)) {
                break;
            }
        }
        result
    };
    let budgets: [(&str, fn(&mut CaptureLimits) -> &mut usize, usize); 5] = [
        ("datagrams", |limits| &mut limits.datagrams, 2),
        ("bytes", |limits| &mut limits.bytes, 2460),
        ("packets", |limits| &mut limits.packets, 2),
        ("frames", |limits| &mut limits.frames, 41),
        (
            "CRYPTO fragments",
            |limits| &mut limits.crypto_fragments,
            15,
        ),
    ];
    for (name, budget, need) in budgets {
        let mut limits = CaptureLimits::default();
        *budget(&mut limits) = need;
        assert!(matches!(run(limits), Ok(Some(_))), "{name} at {need}");
        *budget(&mut limits) = need - 1;
        assert!(
            matches!(
                run(limits),
                Err(PeekError::Capture(CaptureError::LimitExceeded(found))) if found == name
            ),
            "{name} below {need}"
        );
    }
}

/// The ClientHello a captured first flight carried.
#[cfg(feature = "boring")]
fn captured_client_hello(names: [&str; 2]) -> ClientHello {
    let provider = provider();
    let keys = capture::ProviderKeys(provider.as_ref());
    let mut peek = InitialPeek::new(
        CaptureLimits::default(),
        Instant::now() + Duration::from_secs(5),
    );
    for name in names {
        if let Some(peeked) = peek.inspect(Instant::now(), &hex(name), &keys).unwrap() {
            return peeked.client_hello;
        }
    }
    panic!("no ClientHello in {names:?}");
}

/// A ClientHello's wire shape: every list and extension in order, with GREASE values,
/// key shares, ECH payloads and transport parameter bytes (connection IDs) reduced to what
/// is not drawn per connection.
#[cfg(feature = "boring")]
fn wire_shape(hello: &ClientHello) -> Vec<String> {
    fn listed<T: std::fmt::Debug>(items: impl Iterator<Item = (bool, T)>) -> String {
        items
            .map(|(grease, item)| {
                if grease {
                    "GREASE".to_owned()
                } else {
                    format!("{item:?}")
                }
            })
            .collect::<Vec<_>>()
            .join(",")
    }
    let mut shape = vec![format!(
        "ciphers {}",
        listed(hello.cipher_suites().iter().map(|c| (c.is_grease(), *c)))
    )];
    for ext in hello.extensions() {
        let id = ext.id();
        let body = match ext {
            ClientHelloExtension::SupportedGroups(groups) => {
                listed(groups.iter().map(|g| (g.is_grease(), *g)))
            }
            ClientHelloExtension::SignatureAlgorithms(schemes)
            | ClientHelloExtension::DelegatedCredentials(schemes) => {
                listed(schemes.iter().map(|s| (s.is_grease(), *s)))
            }
            ClientHelloExtension::SupportedVersions(versions) => {
                listed(versions.iter().map(|v| (v.is_grease(), *v)))
            }
            ClientHelloExtension::EncryptedClientHello(_) => "ECH GREASE".to_owned(),
            ClientHelloExtension::ServerName(_) => "the connection's name".to_owned(),
            ClientHelloExtension::Opaque { id, data }
                if id.is_grease()
                    || *id == rama_tls::ExtensionId::KEY_SHARE
                    || u16::from(*id) == 57 =>
            {
                format!("{} bytes", data.len())
            }
            other => format!("{other:?}"),
        };
        let id = if id.is_grease() {
            "GREASE".to_owned()
        } else {
            format!("{id:?}")
        };
        shape.push(format!("{id}: {body}"));
    }
    shape
}

/// The TLS ClientHello of a QUIC browser profile, mimicked from its capture, applied per
/// connection and sent with the profile's QUIC first flight, as the browser sent it.
#[cfg(feature = "boring")]
#[test]
fn a_captured_browser_client_hello_is_reproduced_over_quic() {
    use rama_tls_boring::client::BoringClientConfigExt as _;
    for (profile, files) in [
        (
            chrome_153(),
            ["chrome-153-initial-1.hex", "chrome-153-initial-2.hex"],
        ),
        (
            firefox_156(),
            ["firefox-156-initial-1.hex", "firefox-156-initial-2.hex"],
        ),
    ] {
        let captured = captured_client_hello(files);
        let server_name = captured.ext_server_name().unwrap().to_string();
        let tls = TlsClientConfig::new_from_client_hello(&captured)
            .with_server_verify(ServerVerifyMode::Disable);
        let config = ClientConfig::try_from_rama_tls_with_provider(
            &tls,
            crate::tls::TlsOptions::default(),
            &crate::tls::BoringTlsProvider,
        )
        .unwrap();
        let (_, _, emitted) = rama_first_flight_with(&profile, config, &server_name);
        assert_eq!(emitted.ext_server_name(), captured.ext_server_name());

        let mut expected = wire_shape(&captured);
        // Without the compression feature, no compressor is registered.
        if !cfg!(feature = "compression") {
            expected.retain(|ext| !ext.starts_with("COMPRESS_CERTIFICATE:"));
        }
        assert_eq!(wire_shape(&emitted), expected, "{server_name}");
    }
}

/// A browser that permutes its extensions draws a fresh order per connection from one
/// configuration, always over the captured set.
#[cfg(feature = "boring")]
#[test]
fn a_permuting_browser_draws_its_extension_order_per_connection() {
    use rama_tls_boring::client::BoringClientConfigExt as _;
    let captured = captured_client_hello(["chrome-153-initial-1.hex", "chrome-153-initial-2.hex"]);
    let server_name = captured.ext_server_name().unwrap().to_string();
    let tls = TlsClientConfig::new_from_client_hello(&captured)
        .with_server_verify(ServerVerifyMode::Disable)
        .with_permute_extensions(true);
    let config = ClientConfig::try_from_rama_tls_with_provider(
        &tls,
        crate::tls::TlsOptions::default(),
        &crate::tls::BoringTlsProvider,
    )
    .unwrap();
    let sorted = |hello: &ClientHello| {
        let mut shape = wire_shape(hello);
        shape.sort();
        shape
    };
    let mut expected = wire_shape(&captured);
    if !cfg!(feature = "compression") {
        expected.retain(|ext| !ext.starts_with("COMPRESS_CERTIFICATE:"));
    }
    expected.sort();
    let mut orders = Vec::new();
    for _ in 0..4 {
        let (_, _, emitted) = rama_first_flight_with(&chrome_153(), config.clone(), &server_name);
        assert_eq!(sorted(&emitted), expected);
        orders.push(
            emitted
                .extensions()
                .iter()
                .map(|ext| ext.id())
                .collect::<Vec<_>>(),
        );
    }
    // Twelve extensions permute; four equal draws would mean the order is not drawn.
    assert!(orders.iter().any(|order| *order != orders[0]));
}

/// Compiling a browser's sent transport parameters reproduces the layout and limits its
/// hand-written profile states, except what a relay pins instead of drawing.
#[cfg(feature = "boring")]
#[test]
fn sent_transport_parameters_compile_to_the_captured_layouts() {
    use rama_quic_proto::capture::transport_parameters_from_hello;
    let compile = |files| {
        let sent = transport_parameters_from_hello(
            &captured_client_hello(files),
            &CaptureLimits::default(),
        )
        .unwrap();
        (
            sent.clone(),
            TransportParameterProfile::try_from_sent(&sent).unwrap(),
            TransportLimits::try_from_sent(&sent).unwrap(),
        )
    };

    let (sent, parameters, limits) =
        compile(["firefox-156-initial-1.hex", "firefox-156-initial-2.hex"]);
    let firefox = firefox_156();
    let ParameterOrder::Fixed(expected_order) = firefox.transport_parameters().order() else {
        panic!("Firefox writes a fixed order");
    };
    assert_eq!(
        parameters.order(),
        &ParameterOrder::fixed_with_explicit_defaults(sent.iter().map(|p| p.id))
    );
    assert_eq!(
        &sent
            .iter()
            .map(|p| ParameterOrderEntry::Parameter(p.id))
            .collect::<Vec<_>>(),
        expected_order
    );
    assert_eq!(parameters.grease(), &GreaseParameter::None);
    assert_eq!(parameters.extra(), firefox.transport_parameters().extra());
    assert_eq!(
        parameters.max_datagram_frame_size(),
        firefox.transport_parameters().max_datagram_frame_size()
    );
    assert_eq!(
        parameters.sends_min_ack_delay(),
        firefox.transport_parameters().sends_min_ack_delay()
    );
    assert_eq!(&limits, firefox.limits());

    let (sent, parameters, limits) =
        compile(["chrome-153-initial-1.hex", "chrome-153-initial-2.hex"]);
    let chrome = chrome_153();
    // Chrome draws its order and greased parameter per connection; a relay pins the drawn
    // ones, the greased parameter as an extra parameter with its value.
    let grease = sent.iter().find(|p| p.id.is_reserved()).unwrap();
    assert_eq!(grease.value.len(), 4);
    assert_eq!(parameters.grease(), &GreaseParameter::None);
    assert_eq!(
        parameters.order(),
        &ParameterOrder::fixed_with_explicit_defaults(sent.iter().map(|p| p.id))
    );
    assert!(
        parameters
            .extra()
            .iter()
            .any(|extra| extra.id == grease.id && extra.value == grease.value)
    );
    let mut chrome_extra = parameters.extra().to_vec();
    chrome_extra.retain(|extra| extra.id != grease.id);
    assert_eq!(chrome_extra, chrome.transport_parameters().extra());
    assert_eq!(
        parameters.max_datagram_frame_size(),
        chrome.transport_parameters().max_datagram_frame_size()
    );
    let expected = chrome.limits();
    assert_eq!(limits.initial_max_data, expected.initial_max_data);
    assert_eq!(
        (
            limits.initial_max_stream_data_bidi_local,
            limits.initial_max_stream_data_bidi_remote,
            limits.initial_max_stream_data_uni,
            limits.initial_max_streams_bidi,
            limits.initial_max_streams_uni,
        ),
        (
            expected.initial_max_stream_data_bidi_local,
            expected.initial_max_stream_data_bidi_remote,
            expected.initial_max_stream_data_uni,
            expected.initial_max_streams_bidi,
            expected.initial_max_streams_uni,
        )
    );
    assert_eq!(limits.max_idle_timeout, expected.max_idle_timeout);
    assert_eq!(limits.max_udp_payload_size, expected.max_udp_payload_size);
    assert_eq!(
        limits.datagram_receive_buffer_size,
        expected.datagram_receive_buffer_size
    );
}

mod versions;

#[test]
fn capture_retains_each_authenticated_packet_number_width() {
    // Owned Chrome155 loopback Initials: the second number grows to two bytes
    // even though its numeric value still fits in one. Do not infer widths.
    let datagrams = [
        hex("chrome-155-initial-1.hex"),
        hex("chrome-155-initial-2.hex"),
    ];
    let flight =
        capture::first_flight(&datagrams.each_ref().map(Vec::as_slice), &*provider()).unwrap();
    assert!(flight.complete);
    assert_eq!(flight.packet_numbers, [1, 2]);
    assert_eq!(flight.packet_number_lengths, [1, 2]);
    assert_eq!(flight.packet_number_len, flight.packet_number_lengths[0]);
}

#[cfg(all(feature = "boring", feature = "ua"))]
#[test]
fn safari_transport_capture_replays_without_version_information_or_cid_clamping() {
    use rama_quic_proto::capture::transport_parameters_from_hello;
    use rama_ua::profile::capture::{
        completeness::ProfileCaptureCompleteness,
        order::{OrderCaptureLimits, OrderNamespace, OrderedProtocolCapture},
        quic::QuicFlightCapture,
    };
    let names = ["safari-26.5-initial-1.hex", "safari-26.5-initial-2.hex"];
    let datagrams = names.map(hex);
    let flight = capture::first_flight(&[&datagrams[0], &datagrams[1]], &*provider()).unwrap();
    assert_eq!(flight.chosen_version, None);
    let sent =
        transport_parameters_from_hello(&captured_client_hello(names), &CaptureLimits::default())
            .unwrap();
    let parameters = OrderedProtocolCapture::capture(
        ProfileCaptureCompleteness::Complete,
        OrderNamespace::QuicParameter,
        sent.iter().map(|p| (u64::from(p.id), p.value.as_slice())),
        OrderCaptureLimits::default(),
    )
    .unwrap();
    let capture = QuicFlightCapture {
        completeness: ProfileCaptureCompleteness::Complete,
        flight,
    };
    let mut unsupported = capture.clone();
    unsupported.flight.version = rama_quic_proto::version::Version::from_u32(0xface_b00c);
    assert!(
        super::replay::transport::prepare(&parameters, None, Some(&unsupported), false)
            .unwrap()
            .is_none()
    );
    let profile = super::replay::transport::prepare(&parameters, None, Some(&capture), false)
        .unwrap()
        .unwrap();
    let identity = crate::test_helpers::identity();
    let (emitted, _, hello) = rama_first_flight_with(
        &profile,
        crate::test_helpers::client(&identity),
        "localhost",
    );
    assert_eq!(emitted.version, capture.flight.version);
    assert_eq!(emitted.chosen_version, None);
    assert_eq!(
        transport_parameters_from_hello(&hello, &CaptureLimits::default()).unwrap(),
        sent
    );
}
