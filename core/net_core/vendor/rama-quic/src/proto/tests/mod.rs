use std::{
    assert_matches,
    convert::TryInto,
    mem,
    net::{IpAddr, Ipv4Addr, Ipv6Addr, SocketAddr, SocketAddrV4, SocketAddrV6},
    sync::Arc,
};

use rama_core::{
    bytes::{Bytes, BytesMut},
    telemetry::tracing::info,
};
use rama_crypto::{
    hmac::HmacSha2,
    pki_types::{CertificateDer, PrivateKeyDer},
};
use rama_quic_proto::{
    ConnectionId, Dir, RESET_TOKEN_SIZE, ResetToken, ResetToken as TestResetToken, TransportError,
    TransportErrorCode, VarInt, frame,
    frame::{ApplicationClose, ConnectionClose, Datagram, Frame, FrameStruct},
    packet::{Header, InitialHeader, PacketNumber},
    transport_parameters::TransportParameters,
};
use rama_utils::octets;
use rand::Rng;
use rustc_hash::FxHashMap;

use super::*;
use crate::proto::{
    Duration, Instant,
    cid_generator::{ConnectionIdGenerator, RandomConnectionIdGenerator},
    connection::PreferredAddressState,
    token::reset_token,
};
pub(crate) mod util;
pub(crate) use util::Pair;
use util::*;

mod accept;
mod admission;
mod aead_limits;
mod closing;
mod datagrams;
mod early_packets;
mod grease;
mod loss_config;
mod migration_interop;
mod observation;
mod packet_vectors;
mod profile_endpoint;
mod qlog;
mod qlog_drops;
mod qlog_lifecycle;
mod qlog_negotiation;
mod qlog_paths;
mod recorded_initial;
mod tls;
mod token;
mod validation;
mod version;
mod zero_cid_routes;

#[cfg(all(target_family = "wasm", target_os = "unknown"))]
use wasm_bindgen_test::wasm_bindgen_test as test;

// Enable this if you want to run these tests in the browser.
// Unfortunately it's either-or: Enable this and you can run in the browser, disable to run in nodejs.
// #[cfg(all(target_family = "wasm", target_os = "unknown"))]
// wasm_bindgen_test::wasm_bindgen_test_configure!(run_in_browser);

#[test]
fn version_negotiate_server() {
    let _guard = subscribe();
    let client_addr = SocketAddr::from(([0, 0, 0, 0, 0, 0, 0, 2], 7890));
    let mut server = Endpoint::new(
        Arc::new(EndpointConfig::try_with_rand_key().unwrap()),
        Some(Arc::new(server_config())),
        true,
        None,
    );
    let now = Instant::now();
    let mut buf = Vec::with_capacity(server.config().get_max_udp_payload_size() as usize);
    // Long-header packet with reserved version number
    let header = [
        0x80, 0x0a, 0x1a, 0x2a, 0x3a, 0x04, 0x00, 0x00, 0x00, 0x00, 0x04, 0x00, 0x00, 0x00, 0x00,
        0x00,
    ];

    // RFC 9000 §5.2.2: packets too small to initiate a connection are dropped
    let event = server.handle(now, client_addr, None, None, header[..].into(), &mut buf);
    assert!(event.is_none());
    assert!(buf.is_empty());

    let mut packet = header.to_vec();
    packet.resize(MIN_INITIAL_SIZE as usize, 0);
    let event = server.handle(now, client_addr, None, None, packet[..].into(), &mut buf);
    let Some(DatagramEvent::Response(Transmit { .. })) = event else {
        panic!("expected a response");
    };

    assert_ne!(buf[0] & 0x80, 0);
    assert_eq!(
        &buf[1..15],
        [
            0x00, 0x00, 0x00, 0x00, 0x04, 0x00, 0x00, 0x00, 0x00, 0x04, 0x00, 0x00, 0x00, 0x00
        ]
    );
    assert!(buf[15..].chunks(4).any(|x| {
        DEFAULT_SUPPORTED_VERSIONS.contains(&Version::from_be_bytes(x.try_into().unwrap()))
    }));
}

#[test]
fn version_negotiate_client() {
    let _guard = subscribe();
    let server_addr = SocketAddr::from(([0, 0, 0, 0, 0, 0, 0, 2], 7890));
    // Configure client to use empty CIDs so we can easily hardcode a server version negotiation
    // packet
    let cid_generator_factory: fn() -> Box<dyn ConnectionIdGenerator> =
        || Box::new(RandomConnectionIdGenerator::new(0).expect("zero is a length"));
    let mut client = Endpoint::new(
        Arc::new(EndpointConfig {
            connection_id_generator_factory: Arc::new(cid_generator_factory),
            ..EndpointConfig::try_with_rand_key().unwrap()
        }),
        None,
        true,
        None,
    );
    let (_, mut client_ch) = client
        .connect(Instant::now(), client_config(), server_addr, "localhost")
        .unwrap();
    let now = Instant::now();
    let mut buf = Vec::with_capacity(client.config().get_max_udp_payload_size() as usize);
    let opt_event = client.handle(
        now,
        server_addr,
        None,
        None,
        // Version negotiation packet for reserved version, with empty DCID
        [
            0x80, 0x00, 0x00, 0x00, 0x00, 0x00, 0x04, 0x00, 0x00, 0x00, 0x00, 0x0a, 0x1a, 0x2a,
            0x3a,
        ][..]
            .into(),
        &mut buf,
    );
    if let Some(DatagramEvent::ConnectionEvent(_, event)) = opt_event {
        client_ch.handle_event(event);
    }
    match client_ch.poll() {
        Some(Event::ConnectionLost {
            reason: ConnectionError::VersionMismatch { .. },
        }) => {}
        other => panic!(
            "assertion failed: `{other:?}` does not match `Some(Event::ConnectionLost {{ reason: ConnectionError::VersionMismatch {{ .. }}, }})`"
        ),
    }
}

#[test]
fn lifecycle() {
    let _guard = subscribe();
    let mut pair = Pair::default();
    let (client_ch, server_ch) = pair.connect();
    match pair.client_conn_mut(client_ch).poll() {
        None => {}
        other => panic!("assertion failed: `{other:?}` does not match `None`"),
    }
    assert!(pair.client_conn_mut(client_ch).using_ecn());
    assert!(pair.server_conn_mut(server_ch).using_ecn());

    const REASON: &[u8] = b"whee";
    info!("closing");
    pair.client.connections.get_mut(&client_ch).unwrap().close(
        pair.time,
        VarInt::from_u32(42),
        REASON.into(),
    );
    pair.drive();
    match pair.server_conn_mut(server_ch).poll() {
        Some(Event::ConnectionLost {
            reason:
                ConnectionError::ApplicationClosed(ApplicationClose {
                    error_code,
                    ref reason,
                }),
        }) if reason == REASON && error_code == VarInt::from_u32(42) => {}
        other => panic!(
            "assertion failed: `{other:?}` does not match `Some(Event::ConnectionLost {{ reason: ConnectionError::ApplicationClosed( ApplicationClose {{ error_code: VarInt::from_u32(42), ref reason }} )}}) if reason == REASON`"
        ),
    }
    match pair.client_conn_mut(client_ch).poll() {
        None => {}
        other => panic!("assertion failed: `{other:?}` does not match `None`"),
    }
    assert_eq!(pair.client.known_connections(), 0);
    assert_eq!(pair.client.known_cids(), 0);
    assert_eq!(pair.server.known_connections(), 0);
    assert_eq!(pair.server.known_cids(), 0);
}

// The Rustls adapter additionally supports the pre-RFC transport-parameter codepoint.
#[cfg(all(feature = "rustls", any(feature = "aws-lc", feature = "ring")))]
#[test]
fn draft_version_compat() {
    let _guard = subscribe();

    // Draft versions are not advertised by default (v1 only); both endpoints opt in explicitly
    // for this compatibility fixture.
    let mut endpoint_config = EndpointConfig::try_with_rand_key().unwrap();
    endpoint_config.set_supported_versions([DEFAULT_SUPPORTED_VERSIONS, DRAFT_VERSIONS].concat());
    let mut client_config = client_config();
    client_config
        .set_version(Version::from_u32(0xff00_0020))
        .unwrap();

    let mut pair = Pair::new(Arc::new(endpoint_config), server_config());
    let (client_ch, server_ch) = pair.connect_with(client_config);

    match pair.client_conn_mut(client_ch).poll() {
        None => {}
        other => panic!("assertion failed: `{other:?}` does not match `None`"),
    }
    assert!(pair.client_conn_mut(client_ch).using_ecn());
    assert!(pair.server_conn_mut(server_ch).using_ecn());

    const REASON: &[u8] = b"whee";
    info!("closing");
    pair.client.connections.get_mut(&client_ch).unwrap().close(
        pair.time,
        VarInt::from_u32(42),
        REASON.into(),
    );
    pair.drive();
    match pair.server_conn_mut(server_ch).poll() {
        Some(Event::ConnectionLost {
            reason:
                ConnectionError::ApplicationClosed(ApplicationClose {
                    error_code,
                    ref reason,
                }),
        }) if reason == REASON && error_code == VarInt::from_u32(42) => {}
        other => panic!(
            "assertion failed: `{other:?}` does not match `Some(Event::ConnectionLost {{ reason: ConnectionError::ApplicationClosed( ApplicationClose {{ error_code: VarInt::from_u32(42), ref reason }} )}}) if reason == REASON`"
        ),
    }
    match pair.client_conn_mut(client_ch).poll() {
        None => {}
        other => panic!("assertion failed: `{other:?}` does not match `None`"),
    }
    assert_eq!(pair.client.known_connections(), 0);
    assert_eq!(pair.client.known_cids(), 0);
    assert_eq!(pair.server.known_connections(), 0);
    assert_eq!(pair.server.known_cids(), 0);
}

#[test]
fn server_stateless_reset() {
    let _guard = subscribe();
    let mut key_material = [0; 32];
    let mut rng = rand::rng();
    rng.fill_bytes(&mut key_material);
    let reset_key = HmacSha2::new_256(&key_material);
    rng.fill_bytes(&mut key_material);

    let mut endpoint_config = EndpointConfig::new(reset_key);
    endpoint_config.set_cid_generator(Arc::new(move || {
        Box::new(HashedConnectionIdGenerator::from_key(0))
    }));
    let endpoint_config = Arc::new(endpoint_config);

    let mut pair = Pair::new(endpoint_config.clone(), server_config());
    let (client_ch, _) = pair.connect();
    pair.drive(); // Flush any post-handshake frames
    pair.server.endpoint =
        Endpoint::new(endpoint_config, Some(Arc::new(server_config())), true, None);
    // Force the server to generate the smallest possible stateless reset
    pair.client.connections.get_mut(&client_ch).unwrap().ping();
    info!("resetting");
    pair.drive();
    match pair.client_conn_mut(client_ch).poll() {
        Some(Event::ConnectionLost {
            reason: ConnectionError::Reset,
        }) => {}
        other => panic!(
            "assertion failed: `{other:?}` does not match `Some(Event::ConnectionLost {{ reason: ConnectionError::Reset }})`"
        ),
    }
}

#[test]
fn client_stateless_reset() {
    let _guard = subscribe();
    let mut key_material = [0; 32];
    let mut rng = rand::rng();
    rng.fill_bytes(&mut key_material);
    let reset_key = HmacSha2::new_256(&key_material);
    rng.fill_bytes(&mut key_material);

    let mut endpoint_config = EndpointConfig::new(reset_key);
    endpoint_config.set_cid_generator(Arc::new(move || {
        Box::new(HashedConnectionIdGenerator::from_key(0))
    }));
    let endpoint_config = Arc::new(endpoint_config);

    let mut pair = Pair::new(endpoint_config.clone(), server_config());
    let (_, server_ch) = pair.connect();
    pair.client.endpoint =
        Endpoint::new(endpoint_config, Some(Arc::new(server_config())), true, None);
    // Keep the connection active: a local close already owns its outcome.
    // Stream data makes enough room for the client's smaller stateless reset.
    let stream = pair.server_streams(server_ch).open(Dir::Uni).unwrap();
    pair.server_send(server_ch, stream)
        .write(&[0xab; 128])
        .unwrap();
    info!("resetting");
    pair.drive();
    match pair.server_conn_mut(server_ch).poll() {
        Some(Event::ConnectionLost {
            reason: ConnectionError::Reset,
        }) => {}
        other => panic!(
            "assertion failed: `{other:?}` does not match `Some(Event::ConnectionLost {{ reason: ConnectionError::Reset }})`"
        ),
    }
}

/// Every loss a connection reports, in order, past its other events.
fn losses(conn: &mut Connection) -> Vec<ConnectionError> {
    let mut lost = Vec::new();
    while let Some(event) = conn.poll() {
        if let Event::ConnectionLost { reason } = event {
            lost.push(reason);
        }
    }
    lost
}

/// The server closes and, past its closing period, forgets the connection while its
/// CONNECTION_CLOSE still waits unread at the client.
fn server_closes_and_forgets(pair: &mut Pair, server_ch: ConnectionHandle, reason: &'static [u8]) {
    pair.drive(); // Flush post-handshake traffic so the close is the only unread datagram.
    let now = pair.time;
    pair.server_conn_mut(server_ch)
        .close(now, VarInt::from_u32(42), Bytes::from_static(reason));
    pair.drive_server();
    assert!(
        !pair.client.inbound.is_empty(),
        "the server sent its CONNECTION_CLOSE"
    );
    for _ in 0..100 {
        if pair.server.known_connections() == 0 {
            break;
        }
        pair.time = pair
            .server
            .next_wakeup()
            .expect("the server's close timer is armed");
        pair.drive_server();
    }
    assert_eq!(pair.server.known_connections(), 0, "the server forgot it");
    // Read at the current time, so the client is still draining when the reset arrives.
    for datagram in &mut pair.client.inbound {
        datagram.at = pair.time;
    }
}

/// Whether `lost` is exactly the server's application close carrying `reason`.
fn is_application_close(lost: &[ConnectionError], reason: &[u8]) -> bool {
    matches!(
        lost,
        [ConnectionError::ApplicationClosed(ApplicationClose {
            error_code,
            reason: got,
        })] if *error_code == VarInt::from_u32(42) && got == reason
    )
}

/// The client reads the peer's CONNECTION_CLOSE only after the peer forgot the connection, so
/// its answer draws a stateless reset, which it processes before the application polls. The
/// peer's reason is what the application learns (RFC 9000 §10.3.1).
#[test]
fn stateless_reset_while_draining_keeps_close_reason() {
    let _guard = subscribe();
    let mut pair = Pair::default();
    let (client_ch, server_ch) = pair.connect();
    const REASON: &[u8] = b"not accepted";
    server_closes_and_forgets(&mut pair, server_ch, REASON);

    pair.drive_client();
    assert!(
        !pair.server.inbound.is_empty(),
        "the client answered the close"
    );
    pair.drive_server();
    assert!(
        !pair.client.inbound.is_empty(),
        "the server answered with a stateless reset"
    );
    pair.drive_client();

    let client = pair.client_conn_mut(client_ch);
    assert!(client.is_drained());
    let lost = losses(client);
    assert!(is_application_close(&lost, REASON), "{lost:?}");
    assert_eq!(pair.client.known_connections(), 0);
}

/// The application already read the peer's reason when the reset arrives: the reset ends the
/// draining period and is not reported as a second loss.
#[test]
fn stateless_reset_while_draining_is_not_a_second_loss() {
    let _guard = subscribe();
    let mut pair = Pair::default();
    let (client_ch, server_ch) = pair.connect();
    const REASON: &[u8] = b"not accepted";
    server_closes_and_forgets(&mut pair, server_ch, REASON);

    pair.drive_client();
    let lost = losses(pair.client_conn_mut(client_ch));
    assert!(is_application_close(&lost, REASON), "{lost:?}");

    pair.drive_server();
    assert!(
        !pair.client.inbound.is_empty(),
        "the server answered with a stateless reset"
    );
    pair.drive_client();

    let client = pair.client_conn_mut(client_ch);
    assert!(client.is_drained());
    assert!(losses(client).is_empty());
    assert_eq!(pair.client.known_connections(), 0);
}

/// A connection closing on a protocol error it has not reported yet keeps that error as the
/// reason when the close it sends draws a stateless reset.
#[test]
fn stateless_reset_while_closing_keeps_an_unread_reason() {
    let _guard = subscribe();
    let mut endpoint_config = EndpointConfig::new(HmacSha2::new_256(&[0x11; 32]));
    endpoint_config.set_cid_generator(Arc::new(move || {
        Box::new(HashedConnectionIdGenerator::from_key(0))
    }));
    let endpoint_config = Arc::new(endpoint_config);

    let mut pair = Pair::new(endpoint_config.clone(), server_config());
    let (client_ch, _) = pair.connect();
    pair.drive(); // Flush any post-handshake frames
    pair.server.endpoint =
        Endpoint::new(endpoint_config, Some(Arc::new(server_config())), true, None);
    let now = pair.time;
    let client = pair.client_conn_mut(client_ch);
    client.overflow_retirement_queue();
    client.settle_deferred_error(now);

    pair.drive_client();
    assert!(!pair.server.inbound.is_empty(), "the client sent its close");
    pair.drive_server();
    assert!(
        !pair.client.inbound.is_empty(),
        "the server answered with a stateless reset"
    );
    pair.drive_client();

    // No time has passed, so only the reset can have ended the closing period.
    let client = pair.client_conn_mut(client_ch);
    assert!(client.is_drained());
    let lost = losses(client);
    match &lost[..] {
        [
            ConnectionError::TransportError(TransportError {
                code: TransportErrorCode::CONNECTION_ID_LIMIT_ERROR,
                ..
            }),
        ] => {}
        other => panic!("the protocol error stays the reason, not {other:?}"),
    }
}

/// A stateless reset whose token was derived with a different key is not a reset for us: the
/// bytes reach the real client receive path, are not recognised, and the connection stays usable.
/// A reset for the same CID with the real key is recognised, so only the key differs.
#[test]
fn stateless_reset_with_a_foreign_key_is_ignored() {
    let _guard = subscribe();
    // Fixed, distinct keys so the case is deterministic.
    let real_key = HmacSha2::new_256(&[0x11; 32]);
    let real_key_copy = HmacSha2::new_256(&[0x11; 32]);
    let foreign_key = HmacSha2::new_256(&[0x22; 32]);
    let cid_generator: ConnectionIdGeneratorFactory =
        Arc::new(|| Box::new(HashedConnectionIdGenerator::from_key(0)));
    let mut endpoint_config = EndpointConfig::new(real_key);
    endpoint_config.set_cid_generator(cid_generator);
    let endpoint_config = Arc::new(endpoint_config);
    let mut pair = Pair::new(endpoint_config, server_config());
    let (client_ch, server_ch) = pair.connect();
    pair.drive();

    // The client's current destination CID, read from a short-header packet it sends.
    pair.client_conn_mut(client_ch).ping();
    pair.client.drive(pair.time, pair.server.addr);
    let packet = pair
        .client
        .outbound
        .front()
        .map(|(_, buffer)| buffer.clone())
        .expect("the ping produced a packet");
    assert_eq!(
        packet[0] & rama_quic_proto::packet::LONG_HEADER_FORM,
        0,
        "short header expected"
    );
    let cid_len = HashedConnectionIdGenerator::from_key(0).cid_len();
    let dst_cid = ConnectionId::new(&packet[1..1 + cid_len]);
    pair.drive_client();
    pair.drive();

    // A syntactically valid stateless reset for that CID, signed with the foreign key.
    let build_reset = |token: ResetToken| {
        let mut reset = vec![0x40; 1];
        reset.extend_from_slice(&[0xab; 40]);
        reset.extend_from_slice(&token);
        reset
    };
    let foreign = build_reset(reset_token(&foreign_key, dst_cid));
    let genuine = reset_token(&real_key_copy, dst_cid);
    assert_ne!(
        &foreign[foreign.len() - 16..],
        &genuine[..],
        "the foreign token must not match the client's expectation"
    );
    pair.client
        .inbound
        .push_back(Inbound::plain(pair.time, None, foreign.as_slice().into()));
    pair.drive();
    assert!(
        !pair.client_conn_mut(client_ch).is_closed(),
        "a reset with a foreign token must not close the connection"
    );
    while let Some(event) = pair.client_conn_mut(client_ch).poll() {
        assert!(
            !matches!(event, Event::ConnectionLost { .. }),
            "no connection loss from a foreign reset: {event:?}"
        );
    }
    // Still usable end to end: a stream opened now reaches the server.
    let s = pair.client_streams(client_ch).open(Dir::Bi).unwrap();
    pair.client_send(client_ch, s)
        .write(b"still alive")
        .unwrap();
    pair.drive();
    assert_matches!(
        pair.server_conn_mut(server_ch).poll(),
        Some(Event::Stream(StreamEvent::Opened { dir: Dir::Bi })),
    );

    // Control: the same packet shape with the genuine token is a reset.
    pair.client.inbound.push_back(Inbound::plain(
        pair.time,
        None,
        build_reset(genuine).as_slice().into(),
    ));
    pair.drive();
    let mut lost = false;
    while let Some(event) = pair.client_conn_mut(client_ch).poll() {
        if matches!(
            event,
            Event::ConnectionLost {
                reason: ConnectionError::Reset
            }
        ) {
            lost = true;
        }
    }
    assert!(lost, "the genuine token is recognised as a reset");
}

/// The congestion controller a connection uses, and the window it starts from, are what the
/// transport configuration says. The window is read back through the public statistics, so the
/// choice is observable rather than merely stored: BBR starts from more than CUBIC's default,
/// and an explicit window overrides whichever controller is chosen.
#[test]
fn the_configured_congestion_controller_is_the_one_the_path_starts_with() {
    let _guard = subscribe();

    let configured = |control: CongestionControl, window: Option<u64>| {
        let mut transport = TransportConfig::default();
        transport.set_congestion_control(control);
        transport.try_maybe_set_initial_congestion_window(window)?;
        Ok::<_, ConfigError>(transport)
    };
    let started_with = |control: CongestionControl, window: Option<u64>| {
        let transport = configured(control, window).expect("the window is accepted");
        let mut config = client_config();
        config.transport = Arc::new(transport);
        let mut pair = Pair::default();
        let client_ch = pair.begin_connect(config);
        pair.drive();
        pair.client_conn_mut(client_ch).stats().path.cwnd
    };

    let cubic = started_with(CongestionControl::Cubic, None);
    let new_reno = started_with(CongestionControl::NewReno, None);
    let bbr = started_with(CongestionControl::Bbr, None);
    assert_eq!(
        cubic, new_reno,
        "CUBIC and NewReno start from the window RFC 9002 §7.2 recommends"
    );
    assert!(
        bbr > cubic,
        "BBR starts from more than that: {bbr} against {cubic}"
    );

    // An explicit window, which every controller starts from. BBR has already adjusted its
    // window by the time the handshake completes, so the assertion is a floor; the defaults
    // above are two orders of magnitude below it, so it still tells the settings apart.
    let window = octets::mib_u64(1);
    for control in CONTROLLERS {
        let started = started_with(control, Some(window));
        assert!(
            started >= window,
            "{control:?} starts from the configured window: {started} against {window}"
        );
    }
}

/// The window a connection may be configured with, at its edges: below the floor it is
/// refused, and at the floor, a mebibyte and the top of the range it connects, carries data,
/// and starts a fresh path from the same window.
#[test]
fn the_initial_congestion_window_is_refused_below_two_datagrams() {
    let _guard = subscribe();

    for control in CONTROLLERS {
        for refused in [0, 1, MIN_INITIAL_CONGESTION_WINDOW - 1] {
            let mut transport = TransportConfig::default();
            transport.set_congestion_control(control);
            assert_eq!(
                transport.try_set_initial_congestion_window(refused).err(),
                Some(ConfigError::OutOfBounds),
                "{control:?} refuses a window of {refused} bytes"
            );
        }

        for accepted in [MIN_INITIAL_CONGESTION_WINDOW, octets::mib_u64(1), u64::MAX] {
            let mut transport = TransportConfig::default();
            transport.set_congestion_control(control);
            transport
                .try_set_initial_congestion_window(accepted)
                .expect("the window is at or above the minimum");
            let mut config = client_config();
            config.transport = Arc::new(transport);

            // It connects and carries data, on the path it starts with and on a path that
            // starts again from the same configuration.
            let mut pair = Pair::default();
            let client_ch = pair.begin_connect(config);
            pair.drive();
            let server_ch = pair.server.assert_accept();
            let started = pair.client_conn_mut(client_ch).stats().path.cwnd;
            assert!(
                started >= accepted,
                "{control:?} starts from {accepted}: {started}"
            );
            exchange_on_a_stream(&mut pair, client_ch, server_ch, b"under this window");

            let now = pair.time;
            pair.client_conn_mut(client_ch).path_changed(now);
            let after = pair.client_conn_mut(client_ch).stats().path.cwnd;
            assert!(
                after >= accepted,
                "{control:?} starts a fresh path from {accepted} again: {after}"
            );
            exchange_on_a_stream(&mut pair, client_ch, server_ch, b"after the path reset");
        }
    }
}

/// Open a stream, write `message`, and read it on the other side.
fn exchange_on_a_stream(
    pair: &mut Pair,
    client_ch: ConnectionHandle,
    server_ch: ConnectionHandle,
    message: &[u8],
) {
    let stream = pair
        .client_streams(client_ch)
        .open(Dir::Uni)
        .expect("a stream opens");
    pair.client_send(client_ch, stream)
        .write(message)
        .expect("the write is queued");
    pair.client_send(client_ch, stream)
        .finish()
        .expect("the stream finishes");
    pair.drive();
    assert_eq!(
        pair.server_streams(server_ch).accept(Dir::Uni),
        Some(stream),
        "the peer sees the stream"
    );
    let mut received = pair.server_recv(server_ch, stream);
    let mut chunks = received.read(true).expect("the stream is readable");
    let chunk = chunks
        .next(message.len())
        .expect("a chunk arrives")
        .expect("with the payload");
    assert_eq!(&chunk.bytes[..], message, "the payload arrives as sent");
    let _transmit = chunks.finalize();
}

/// The controllers a connection may be configured with.
const CONTROLLERS: [CongestionControl; 3] = [
    CongestionControl::Cubic,
    CongestionControl::NewReno,
    CongestionControl::Bbr,
];

/// The key configured on an endpoint is the key its stateless reset tokens are derived from.
/// The client here holds a token the server issued, so a reset carrying the token that same
/// material gives for that connection ID is recognised, and one from other material is not.
/// That is the case of a second endpoint of the same service, or the same one after a restart,
/// resetting a connection it has no state for.
#[test]
fn a_configured_stateless_reset_key_is_what_the_issued_tokens_come_from() {
    let _guard = subscribe();
    const SEED: [u8; KEY_MATERIAL_SIZE] = [0x5c; KEY_MATERIAL_SIZE];
    const OTHER_SEED: [u8; KEY_MATERIAL_SIZE] = [0xa3; KEY_MATERIAL_SIZE];

    // Only the server's endpoint is given the key: it is the side whose tokens the client
    // learns and later recognises resets by.
    let cid_generator: ConnectionIdGeneratorFactory =
        Arc::new(|| Box::new(HashedConnectionIdGenerator::from_key(0)));
    let mut issuing = EndpointConfig::try_with_rand_key().unwrap();
    issuing
        .set_stateless_reset_key(StatelessResetKey::from_seed(&SEED))
        .set_cid_generator(cid_generator);
    let server = Endpoint::new(
        Arc::new(issuing),
        Some(Arc::new(server_config())),
        true,
        None,
    );
    let client = Endpoint::new(
        Arc::new(EndpointConfig::try_with_rand_key().unwrap()),
        None,
        true,
        None,
    );
    let mut pair = Pair::new_from_endpoint(client, server);
    let (client_ch, _server_ch) = pair.connect();
    pair.drive();

    // The connection ID the client sends to, which is the one the server issued a token for.
    pair.client_conn_mut(client_ch).ping();
    pair.client.drive(pair.time, pair.server.addr);
    let packet = pair
        .client
        .outbound
        .front()
        .map(|(_, buffer)| buffer.clone())
        .expect("the ping produced a packet");
    let cid_len = HashedConnectionIdGenerator::from_key(0).cid_len();
    let dst_cid = ConnectionId::new(&packet[1..1 + cid_len]);
    pair.drive_client();
    pair.drive();

    let build_reset = |token: ResetToken| {
        let mut reset = vec![0x40; 1];
        reset.extend_from_slice(&[0xab; 40]);
        reset.extend_from_slice(&token);
        reset
    };
    let elsewhere = HmacSha2::new_256(&OTHER_SEED);
    let configured = HmacSha2::new_256(&SEED);

    // Other material gives a token the client was never handed.
    pair.client.inbound.push_back(Inbound::plain(
        pair.time,
        None,
        build_reset(reset_token(&elsewhere, dst_cid))
            .as_slice()
            .into(),
    ));
    pair.drive();
    assert!(
        !pair.client_conn_mut(client_ch).is_closed(),
        "a token from other material is not the one the client holds"
    );

    // The configured material gives the token the client holds.
    pair.client.inbound.push_back(Inbound::plain(
        pair.time,
        None,
        build_reset(reset_token(&configured, dst_cid))
            .as_slice()
            .into(),
    ));
    pair.drive();
    let mut lost = false;
    while let Some(event) = pair.client_conn_mut(client_ch).poll() {
        if matches!(
            event,
            Event::ConnectionLost {
                reason: ConnectionError::Reset
            }
        ) {
            lost = true;
        }
    }
    assert!(lost, "the token the configured key gives is recognised");
}

/// Verify that stateless resets are rate-limited
#[test]
fn stateless_reset_limit() {
    let _guard = subscribe();
    let remote = SocketAddr::new(IpAddr::V4(Ipv4Addr::LOCALHOST), 42);
    let mut endpoint_config = EndpointConfig::try_with_rand_key().unwrap();
    endpoint_config.set_cid_generator(Arc::new(move || {
        Box::new(RandomConnectionIdGenerator::new(8).expect("eight bytes is a length"))
    }));
    let endpoint_config = Arc::new(endpoint_config);
    let mut endpoint = Endpoint::new(
        endpoint_config.clone(),
        Some(Arc::new(server_config())),
        true,
        None,
    );
    let time = Instant::now();
    let mut buf = Vec::new();
    let event = endpoint.handle(time, remote, None, None, [0u8; 1024][..].into(), &mut buf);
    assert!(matches!(event, Some(DatagramEvent::Response(_))));
    let event = endpoint.handle(time, remote, None, None, [0u8; 1024][..].into(), &mut buf);
    assert!(event.is_none());
    let event = endpoint.handle(
        time + endpoint_config
            .min_reset_interval
            .saturating_sub(Duration::from_nanos(1)),
        remote,
        None,
        None,
        [0u8; 1024][..].into(),
        &mut buf,
    );
    assert!(event.is_none());
    let event = endpoint.handle(
        time + endpoint_config.min_reset_interval,
        remote,
        None,
        None,
        [0u8; 1024][..].into(),
        &mut buf,
    );
    assert!(matches!(event, Some(DatagramEvent::Response(_))));
}

#[test]
fn export_keying_material() {
    let _guard = subscribe();
    let mut pair = Pair::default();
    let (client_ch, server_ch) = pair.connect();

    const LABEL: &[u8] = b"test_label";
    const CONTEXT: &[u8] = b"test_context";

    // client keying material
    let mut client_buf = [0u8; 64];
    pair.client_conn_mut(client_ch)
        .crypto_session()
        .export_keying_material(&mut client_buf, LABEL, CONTEXT)
        .unwrap();

    // server keying material
    let mut server_buf = [0u8; 64];
    pair.server_conn_mut(server_ch)
        .crypto_session()
        .export_keying_material(&mut server_buf, LABEL, CONTEXT)
        .unwrap();

    assert_eq!(&client_buf[..], &server_buf[..]);
}

#[test]
fn finish_stream_simple() {
    let _guard = subscribe();
    let mut pair = Pair::default();
    let (client_ch, server_ch) = pair.connect();

    let s = pair.client_streams(client_ch).open(Dir::Uni).unwrap();

    const MSG: &[u8] = b"hello";
    pair.client_send(client_ch, s).write(MSG).unwrap();
    assert_eq!(pair.client_streams(client_ch).send_streams(), 1);
    pair.client_send(client_ch, s).finish().unwrap();
    pair.drive();

    match pair.client_conn_mut(client_ch).poll() {
        Some(Event::Stream(StreamEvent::Finished { id })) if id == s => {}
        other => panic!(
            "assertion failed: `{other:?}` does not match `Some(Event::Stream(StreamEvent::Finished {{ id }})) if id == s`"
        ),
    }
    match pair.client_conn_mut(client_ch).poll() {
        None => {}
        other => panic!("assertion failed: `{other:?}` does not match `None`"),
    }
    assert_eq!(pair.client_streams(client_ch).send_streams(), 0);
    assert_eq!(pair.server_conn_mut(client_ch).streams().send_streams(), 0);
    match pair.server_conn_mut(server_ch).poll() {
        Some(Event::Stream(StreamEvent::Opened { dir: Dir::Uni })) => {}
        other => panic!(
            "assertion failed: `{other:?}` does not match `Some(Event::Stream(StreamEvent::Opened {{ dir: Dir::Uni }}))`"
        ),
    }
    // Receive-only streams do not get `StreamFinished` events
    assert_eq!(pair.server_conn_mut(client_ch).streams().send_streams(), 0);
    match pair.server_streams(server_ch).accept(Dir::Uni) {
        Some(stream) if stream == s => {}
        other => {
            panic!("assertion failed: `{other:?}` does not match `Some(stream) if stream == s`")
        }
    }
    match pair.server_conn_mut(server_ch).poll() {
        None => {}
        other => panic!("assertion failed: `{other:?}` does not match `None`"),
    }

    let mut recv = pair.server_recv(server_ch, s);
    let mut chunks = recv.read(false).unwrap();
    match chunks.next(usize::MAX) {
        Ok(Some(chunk)) if chunk.offset == 0 && chunk.bytes == MSG => {}
        other => panic!(
            "assertion failed: `{other:?}` does not match `Ok(Some(chunk)) if chunk.offset == 0 && chunk.bytes == MSG`"
        ),
    }
    match chunks.next(usize::MAX) {
        Ok(None) => {}
        other => panic!("assertion failed: `{other:?}` does not match `Ok(None)`"),
    }
    let _transmit = chunks.finalize();
}

#[test]
fn reset_stream() {
    let _guard = subscribe();
    let mut pair = Pair::default();
    let (client_ch, server_ch) = pair.connect();

    let s = pair.client_streams(client_ch).open(Dir::Uni).unwrap();

    const MSG: &[u8] = b"hello";
    pair.client_send(client_ch, s).write(MSG).unwrap();
    pair.drive();

    info!("resetting stream");
    const ERROR: VarInt = VarInt::from_u32(42);
    pair.client_send(client_ch, s).reset(ERROR).unwrap();
    pair.drive();

    match pair.server_conn_mut(server_ch).poll() {
        Some(Event::Stream(StreamEvent::Opened { dir: Dir::Uni })) => {}
        other => panic!(
            "assertion failed: `{other:?}` does not match `Some(Event::Stream(StreamEvent::Opened {{ dir: Dir::Uni }}))`"
        ),
    }
    match pair.server_streams(server_ch).accept(Dir::Uni) {
        Some(stream) if stream == s => {}
        other => {
            panic!("assertion failed: `{other:?}` does not match `Some(stream) if stream == s`")
        }
    }
    let mut recv = pair.server_recv(server_ch, s);
    let mut chunks = recv.read(false).unwrap();
    match chunks.next(usize::MAX) {
        Err(ReadError::Reset(ERROR)) => {}
        other => {
            panic!("assertion failed: `{other:?}` does not match `Err(ReadError::Reset(ERROR))`")
        }
    }
    let _transmit = chunks.finalize();
    match pair.client_conn_mut(client_ch).poll() {
        None => {}
        other => panic!("assertion failed: `{other:?}` does not match `None`"),
    }
}

#[test]
fn stop_stream() {
    let _guard = subscribe();
    let mut pair = Pair::default();
    let (client_ch, server_ch) = pair.connect();

    let s = pair.client_streams(client_ch).open(Dir::Uni).unwrap();
    const MSG: &[u8] = b"hello";
    pair.client_send(client_ch, s).write(MSG).unwrap();
    pair.drive();

    info!("stopping stream");
    const ERROR: VarInt = VarInt::from_u32(42);
    pair.server_recv(server_ch, s).stop(ERROR).unwrap();
    pair.drive();

    match pair.server_conn_mut(server_ch).poll() {
        Some(Event::Stream(StreamEvent::Opened { dir: Dir::Uni })) => {}
        other => panic!(
            "assertion failed: `{other:?}` does not match `Some(Event::Stream(StreamEvent::Opened {{ dir: Dir::Uni }}))`"
        ),
    }
    match pair.server_streams(server_ch).accept(Dir::Uni) {
        Some(stream) if stream == s => {}
        other => {
            panic!("assertion failed: `{other:?}` does not match `Some(stream) if stream == s`")
        }
    }

    match pair.client_send(client_ch, s).write(b"foo") {
        Err(WriteError::Stopped(ERROR)) => {}
        other => {
            panic!("assertion failed: `{other:?}` does not match `Err(WriteError::Stopped(ERROR))`")
        }
    }
    match pair.client_send(client_ch, s).finish() {
        Err(FinishError::Stopped(ERROR)) => {}
        other => panic!(
            "assertion failed: `{other:?}` does not match `Err(FinishError::Stopped(ERROR))`"
        ),
    }
}

#[test]
fn reject_self_signed_server_cert() {
    let _guard = subscribe();
    let mut pair = Pair::default();
    info!("connecting");

    let cert = crate::test_helpers::untrusted_identity();
    let client_ch = pair.begin_connect(client_config_with_certs(cert.cert_chain));

    pair.drive();

    match pair.client_conn_mut(client_ch).poll() {
        Some(Event::ConnectionLost {
            reason: ConnectionError::TransportError(ref error),
        }) if error.code == crate::test_helpers::untrusted_certificate_error() => {}
        other => panic!(
            "assertion failed: `{other:?}` does not match `Some(Event::ConnectionLost {{ reason: ConnectionError::TransportError(ref error)}}) if error.code == crate::test_helpers::untrusted_certificate_error()`"
        ),
    }
}

#[test]
fn reject_missing_client_cert() {
    let _guard = subscribe();

    let tls = rama_tls::server::TlsServerConfig::new()
        .with_server_auth(CERTIFIED_KEY.clone())
        .with_alpn([b"rama-quic-test".as_slice().into()].into_iter().collect())
        .with_client_verify(rama_tls::server::ClientVerifyMode::ClientAuth(
            CERTIFIED_KEY.cert_chain.clone(),
        ));
    let server_config =
        ServerConfig::try_from_rama_tls(&tls, crate::test_helpers::options()).unwrap();
    let mut pair = Pair::new(
        Arc::new(EndpointConfig::try_with_rand_key().unwrap()),
        server_config,
    );

    info!("connecting");
    let client_ch = pair.begin_connect(ClientConfig::new(Arc::new(client_crypto_with_alpn(vec![
        b"rama-quic-test".to_vec(),
    ]))));
    pair.drive();

    // The client completes the connection, but finds it immediately closed
    match pair.client_conn_mut(client_ch).poll() {
        Some(Event::HandshakeDataReady) => {}
        other => {
            panic!("assertion failed: `{other:?}` does not match `Some(Event::HandshakeDataReady)`")
        }
    }
    match pair.client_conn_mut(client_ch).poll() {
        Some(Event::Connected) => {}
        other => panic!("assertion failed: `{other:?}` does not match `Some(Event::Connected)`"),
    }
    match pair.client_conn_mut(client_ch).poll() {
        Some(Event::ConnectionLost {
            reason: ConnectionError::ConnectionClosed(ref close),
        }) if close.error_code == TransportErrorCode::crypto(116) => {}
        other => panic!(
            "assertion failed: `{other:?}` does not match `Some(Event::ConnectionLost {{ reason: ConnectionError::ConnectionClosed(ref close)}}) if close.error_code == TransportErrorCode::crypto(116)`"
        ),
    }

    // The server never completes the connection
    let server_ch = pair.server.assert_accept();
    match pair.server_conn_mut(server_ch).poll() {
        Some(Event::HandshakeDataReady) => {}
        other => {
            panic!("assertion failed: `{other:?}` does not match `Some(Event::HandshakeDataReady)`")
        }
    }
    match pair.server_conn_mut(server_ch).poll() {
        Some(Event::ConnectionLost {
            reason: ConnectionError::TransportError(ref error),
        }) if error.code == TransportErrorCode::crypto(116) => {}
        other => panic!(
            "assertion failed: `{other:?}` does not match `Some(Event::ConnectionLost {{ reason: ConnectionError::TransportError(ref error)}}) if error.code == TransportErrorCode::crypto(116)`"
        ),
    }
}

#[test]
fn congestion() {
    let _guard = subscribe();
    let mut pair = Pair::default();
    let (client_ch, _) = pair.connect();

    const TARGET: u64 = 2048;
    assert!(pair.client_conn_mut(client_ch).congestion_window() > TARGET);
    let s = pair.client_streams(client_ch).open(Dir::Uni).unwrap();
    // Send data without receiving ACKs until the congestion state falls below target
    while pair.client_conn_mut(client_ch).congestion_window() > TARGET {
        let n = pair.client_send(client_ch, s).write(&[42; 1024]).unwrap();
        assert_eq!(n, 1024);
        pair.drive_client();
    }
    // Ensure that the congestion state recovers after receiving the ACKs
    pair.drive();
    assert!(pair.client_conn_mut(client_ch).congestion_window() >= TARGET);
    pair.client_send(client_ch, s).write(&[42; 1024]).unwrap();
}

#[test]
fn full_initial_window() {
    let _guard = subscribe();

    // Keep `current_mtu` pinned to `INITIAL_MTU`, which the default initial window of 12000 bytes
    // is an exact multiple of, so that the window can be filled precisely.
    let mut transport = TransportConfig::default();
    transport.maybe_set_mtu_discovery_config(None);
    let mut config = client_config();
    config.transport = Arc::new(transport);

    let mut pair = Pair::default();
    let (client_ch, _) = pair.connect_with(config);
    assert_eq!(pair.client_conn_mut(client_ch).bytes_in_flight(), 0);
    let window = pair.client_conn_mut(client_ch).congestion_window();
    let mtu = u64::from(INITIAL_MTU);
    assert_eq!(window % mtu, 0, "window must be exactly fillable");

    let s = pair.client_streams(client_ch).open(Dir::Uni).unwrap();
    let data = vec![42; 2 * window as usize];
    assert_eq!(
        pair.client_send(client_ch, s).write(&data),
        Ok(data.len()),
        "the test must be limited by congestion control, not by flow control"
    );

    let span = rama_core::telemetry::tracing::info_span!("client");
    let _guard = span.enter();
    pair.client.drive(pair.time, pair.server.addr);
    assert_eq!(pair.client_conn_mut(client_ch).bytes_in_flight(), window);
    assert_eq!(pair.client.outbound.len() as u64, window / mtu);
}

#[test]
fn high_latency_handshake() {
    let _guard = subscribe();
    let mut pair = Pair::default();
    pair.latency = Duration::from_micros(200 * 1000);
    let (client_ch, server_ch) = pair.connect();
    assert_eq!(pair.client_conn_mut(client_ch).bytes_in_flight(), 0);
    assert_eq!(pair.server_conn_mut(server_ch).bytes_in_flight(), 0);
    assert!(pair.client_conn_mut(client_ch).using_ecn());
    assert!(pair.server_conn_mut(server_ch).using_ecn());
}

#[test]
fn zero_rtt_happypath() {
    let _guard = subscribe();
    let mut pair = Pair::default();
    pair.server.handle_incoming = Box::new(validate_incoming);
    let config = client_config();

    // Establish normal connection
    let client_ch = pair.begin_connect(config.clone());
    pair.drive();
    pair.server.assert_accept();
    pair.client.connections.get_mut(&client_ch).unwrap().close(
        pair.time,
        VarInt::from_u32(0),
        [][..].into(),
    );
    pair.drive();

    pair.client.addr = SocketAddr::new(
        Ipv6Addr::LOCALHOST.into(),
        CLIENT_PORTS.lock().next().unwrap(),
    );
    info!("resuming session");
    let client_ch = pair.begin_connect(config);
    assert!(pair.client_conn_mut(client_ch).has_0rtt());
    let s = pair.client_streams(client_ch).open(Dir::Uni).unwrap();
    const MSG: &[u8] = b"Hello, 0-RTT!";
    pair.client_send(client_ch, s).write(MSG).unwrap();
    pair.drive();

    match pair.client_conn_mut(client_ch).poll() {
        Some(Event::HandshakeDataReady) => {}
        other => {
            panic!("assertion failed: `{other:?}` does not match `Some(Event::HandshakeDataReady)`")
        }
    }
    match pair.client_conn_mut(client_ch).poll() {
        Some(Event::Connected) => {}
        other => panic!("assertion failed: `{other:?}` does not match `Some(Event::Connected)`"),
    }

    assert!(pair.client_conn_mut(client_ch).accepted_0rtt());
    let server_ch = pair.server.assert_accept();

    match pair.server_conn_mut(server_ch).poll() {
        Some(Event::HandshakeDataReady) => {}
        other => {
            panic!("assertion failed: `{other:?}` does not match `Some(Event::HandshakeDataReady)`")
        }
    }
    match pair.server_conn_mut(server_ch).poll() {
        Some(Event::HandshakeConfirmed) => {}
        other => {
            panic!("assertion failed: `{other:?}` does not match `Some(Event::HandshakeConfirmed)`")
        }
    }
    // We don't currently preserve stream event order wrt. connection events
    match pair.server_conn_mut(server_ch).poll() {
        Some(Event::Connected) => {}
        other => panic!("assertion failed: `{other:?}` does not match `Some(Event::Connected)`"),
    }
    match pair.server_conn_mut(server_ch).poll() {
        Some(Event::Stream(StreamEvent::Opened { dir: Dir::Uni })) => {}
        other => panic!(
            "assertion failed: `{other:?}` does not match `Some(Event::Stream(StreamEvent::Opened {{ dir: Dir::Uni }}))`"
        ),
    }

    let mut recv = pair.server_recv(server_ch, s);
    let mut chunks = recv.read(false).unwrap();
    match chunks.next(usize::MAX) {
        Ok(Some(chunk)) if chunk.offset == 0 && chunk.bytes == MSG => {}
        other => panic!(
            "assertion failed: `{other:?}` does not match `Ok(Some(chunk)) if chunk.offset == 0 && chunk.bytes == MSG`"
        ),
    }
    let _transmit = chunks.finalize();
    assert_eq!(pair.client_conn_mut(client_ch).stats().path.lost_packets, 0);
}

#[cfg(all(feature = "rustls", any(feature = "aws-lc", feature = "ring")))]
#[test]
fn zero_rtt_rejection() {
    let _guard = subscribe();
    let server_config = ServerConfig::with_crypto(Arc::new(server_crypto_with_alpn(vec![
        "foo".into(),
        "bar".into(),
    ])));
    let mut pair = Pair::new(
        Arc::new(EndpointConfig::try_with_rand_key().unwrap()),
        server_config,
    );
    let mut client_crypto = Arc::new(client_crypto_with_alpn(vec!["foo".into()]));
    let client_config = ClientConfig::new(client_crypto.clone());

    // Establish normal connection
    let client_ch = pair.begin_connect(client_config);
    pair.drive();
    let server_ch = pair.server.assert_accept();
    match pair.server_conn_mut(server_ch).poll() {
        Some(Event::HandshakeDataReady) => {}
        other => {
            panic!("assertion failed: `{other:?}` does not match `Some(Event::HandshakeDataReady)`")
        }
    }
    match pair.server_conn_mut(server_ch).poll() {
        Some(Event::HandshakeConfirmed) => {}
        other => {
            panic!("assertion failed: `{other:?}` does not match `Some(Event::HandshakeConfirmed)`")
        }
    }
    match pair.server_conn_mut(server_ch).poll() {
        Some(Event::Connected) => {}
        other => panic!("assertion failed: `{other:?}` does not match `Some(Event::Connected)`"),
    }
    match pair.server_conn_mut(server_ch).poll() {
        None => {}
        other => panic!("assertion failed: `{other:?}` does not match `None`"),
    }
    assert_eq!(
        pair.client_conn_mut(client_ch).loss_recovery_in_flight(),
        (0, 0),
        "after the handshake discarded its packet number spaces nothing is outstanding"
    );
    pair.client.connections.get_mut(&client_ch).unwrap().close(
        pair.time,
        VarInt::from_u32(0),
        [][..].into(),
    );
    pair.drive();
    match pair.server_conn_mut(server_ch).poll() {
        Some(Event::ConnectionLost { .. }) => {}
        other => panic!(
            "assertion failed: `{other:?}` does not match `Some(Event::ConnectionLost {{ .. }})`"
        ),
    }
    match pair.server_conn_mut(server_ch).poll() {
        None => {}
        other => panic!("assertion failed: `{other:?}` does not match `None`"),
    }
    pair.client.connections.clear();
    pair.server.connections.clear();

    // We want to have a TLS client config with the existing session cache (so resumption could
    // happen), but with different ALPN protocols (so that the server must reject it). Reuse
    // the existing `ClientConfig` and change the ALPN protocols to make that happen.
    let this = Arc::get_mut(&mut client_crypto).expect("QuicClientConfig is shared");
    let inner = Arc::get_mut(&mut this.inner).expect("QuicClientConfig.inner is shared");
    inner.alpn_protocols = vec!["bar".into()];

    // Changing protocols invalidates 0-RTT
    let client_config = ClientConfig::new(client_crypto);
    info!("resuming session");
    let client_ch = pair.begin_connect(client_config);
    assert!(pair.client_conn_mut(client_ch).has_0rtt());
    let s = pair.client_streams(client_ch).open(Dir::Uni).unwrap();
    const MSG: &[u8] = b"Hello, 0-RTT!";
    pair.client_send(client_ch, s).write(MSG).unwrap();
    pair.drive();
    assert!(!pair.client_conn_mut(client_ch).accepted_0rtt());
    // The rejected 0-RTT packets were removed from the in-flight count exactly once.
    let (counted, outstanding) = pair.client_conn_mut(client_ch).loss_recovery_in_flight();
    assert_eq!(counted, outstanding);
    let server_ch = pair.server.assert_accept();
    match pair.server_conn_mut(server_ch).poll() {
        Some(Event::HandshakeDataReady) => {}
        other => {
            panic!("assertion failed: `{other:?}` does not match `Some(Event::HandshakeDataReady)`")
        }
    }
    match pair.server_conn_mut(server_ch).poll() {
        Some(Event::HandshakeConfirmed) => {}
        other => {
            panic!("assertion failed: `{other:?}` does not match `Some(Event::HandshakeConfirmed)`")
        }
    }
    match pair.server_conn_mut(server_ch).poll() {
        Some(Event::Connected) => {}
        other => panic!("assertion failed: `{other:?}` does not match `Some(Event::Connected)`"),
    }
    match pair.server_conn_mut(server_ch).poll() {
        None => {}
        other => panic!("assertion failed: `{other:?}` does not match `None`"),
    }
    let s2 = pair.client_streams(client_ch).open(Dir::Uni).unwrap();
    assert_eq!(s, s2);

    let mut recv = pair.server_recv(server_ch, s2);
    let mut chunks = recv.read(false).unwrap();
    assert_eq!(chunks.next(usize::MAX), Err(ReadError::Blocked));
    let _transmit = chunks.finalize();
    assert_eq!(pair.client_conn_mut(client_ch).stats().path.lost_packets, 0);
}

/// A budget that holds three buffered datagrams of up to 1200 bytes and not a fourth.
fn three_buffered_datagrams() -> u64 {
    3 * endpoint::incoming_datagram_charge(1200)
}

fn test_zero_rtt_incoming_limit<F: FnOnce(&mut ServerConfig)>(configure_server: F) {
    // caller sets the server limit to three buffered datagrams
    // the client writes 8000 bytes
    const CLIENT_WRITES: usize = 8000;
    // this gets split across 8 packets
    // the first packet is stored in the Incoming
    // the next three are incoming-buffered, filling the budget
    // the last four are dropped due to the buffering limit and must be retransmitted
    const EXPECTED_DROPPED: u64 = 4;

    let _guard = subscribe();

    let mut transport = TransportConfig::default();
    // Assume a low-latency connection so pacing doesn't interfere with the test
    transport.set_initial_rtt(Duration::from_millis(10));
    let transport = Arc::new(transport);

    let mut server_config = server_config();
    configure_server(&mut server_config);
    let mut pair = Pair::new(
        Arc::new(EndpointConfig::try_with_rand_key().unwrap()),
        server_config,
    );
    let mut config = client_config();
    config.set_transport_config(transport);

    // Establish normal connection
    let client_ch = pair.begin_connect(config.clone());
    pair.drive();
    pair.server.assert_accept();
    pair.client.connections.get_mut(&client_ch).unwrap().close(
        pair.time,
        VarInt::from_u32(0),
        [][..].into(),
    );
    pair.drive();

    pair.client.addr = SocketAddr::new(
        Ipv6Addr::LOCALHOST.into(),
        CLIENT_PORTS.lock().next().unwrap(),
    );
    info!("resuming session");
    pair.server.handle_incoming = Box::new(|_| IncomingConnectionBehavior::Wait);
    let client_ch = pair.begin_connect(config);
    assert!(pair.client_conn_mut(client_ch).has_0rtt());
    let s = pair.client_streams(client_ch).open(Dir::Uni).unwrap();
    pair.client_send(client_ch, s)
        .write(&vec![0; CLIENT_WRITES])
        .unwrap();
    pair.drive();
    let incoming = pair.server.waiting_incoming.pop().unwrap();
    assert!(pair.server.waiting_incoming.is_empty());
    let _accepted = pair.server.try_accept(incoming, pair.time);
    pair.drive();

    match pair.client_conn_mut(client_ch).poll() {
        Some(Event::HandshakeDataReady) => {}
        other => {
            panic!("assertion failed: `{other:?}` does not match `Some(Event::HandshakeDataReady)`")
        }
    }
    match pair.client_conn_mut(client_ch).poll() {
        Some(Event::Connected) => {}
        other => panic!("assertion failed: `{other:?}` does not match `Some(Event::Connected)`"),
    }

    assert!(pair.client_conn_mut(client_ch).accepted_0rtt());
    let server_ch = pair.server.assert_accept();

    match pair.server_conn_mut(server_ch).poll() {
        Some(Event::HandshakeDataReady) => {}
        other => {
            panic!("assertion failed: `{other:?}` does not match `Some(Event::HandshakeDataReady)`")
        }
    }
    match pair.server_conn_mut(server_ch).poll() {
        Some(Event::HandshakeConfirmed) => {}
        other => {
            panic!("assertion failed: `{other:?}` does not match `Some(Event::HandshakeConfirmed)`")
        }
    }
    // We don't currently preserve stream event order wrt. connection events
    match pair.server_conn_mut(server_ch).poll() {
        Some(Event::Connected) => {}
        other => panic!("assertion failed: `{other:?}` does not match `Some(Event::Connected)`"),
    }
    match pair.server_conn_mut(server_ch).poll() {
        Some(Event::Stream(StreamEvent::Opened { dir: Dir::Uni })) => {}
        other => panic!(
            "assertion failed: `{other:?}` does not match `Some(Event::Stream(StreamEvent::Opened {{ dir: Dir::Uni }}))`"
        ),
    }

    let mut recv = pair.server_recv(server_ch, s);
    let mut chunks = recv.read(false).unwrap();
    let mut offset = 0;
    loop {
        match chunks.next(usize::MAX) {
            Ok(Some(chunk)) => {
                assert_eq!(chunk.offset as usize, offset);
                offset += chunk.bytes.len();
            }
            Err(ReadError::Blocked) => break,
            Ok(None) => panic!("unexpected stream end"),
            Err(e) => panic!("{}", e),
        }
    }
    assert_eq!(offset, CLIENT_WRITES);
    let _transmit = chunks.finalize();
    assert_eq!(
        pair.client_conn_mut(client_ch).stats().path.lost_packets,
        EXPECTED_DROPPED
    );
}

#[test]
fn zero_rtt_incoming_buffer_size() {
    test_zero_rtt_incoming_limit(|config| {
        config.set_incoming_buffer_size(three_buffered_datagrams());
    });
}

#[test]
fn zero_rtt_incoming_buffer_size_total() {
    test_zero_rtt_incoming_limit(|config| {
        config.set_incoming_buffer_size_total(three_buffered_datagrams());
    });
}

#[test]
fn tiny_datagrams_for_a_pending_connection_are_charged_their_entries() {
    const LIMIT: u64 = 8_000;
    let mut server_config = server_config();
    server_config.set_incoming_buffer_size(LIMIT);
    let mut pair = Pair::new(
        Arc::new(EndpointConfig::try_with_rand_key().unwrap()),
        server_config,
    );
    pair.server.handle_incoming = Box::new(|_| IncomingConnectionBehavior::Wait);
    pair.begin_connect(client_config());
    pair.drive_client();
    pair.drive_server();
    let incoming = pair
        .server
        .waiting_incoming
        .pop()
        .expect("an attempt is pending");
    let dst_cid = *incoming.orig_dst_cid();

    // The smallest 0-RTT long header that routes to the attempt: a one-byte body.
    let mut datagram = vec![0xd0];
    datagram.extend_from_slice(&Version::V1.to_be_bytes());
    datagram.push(dst_cid.len() as u8);
    datagram.extend_from_slice(&dst_cid);
    datagram.extend_from_slice(&[0, 1, 0]);
    let charge = endpoint::incoming_datagram_charge(datagram.len());
    let fits = LIMIT / charge;
    assert!(
        fits < LIMIT / datagram.len() as u64,
        "the entry is part of the charge"
    );

    let before = incoming.progress().generation();
    let mut buf = Vec::new();
    for _ in 0..LIMIT {
        assert!(
            pair.server
                .endpoint
                .handle(
                    pair.time,
                    pair.client.addr,
                    None,
                    None,
                    BytesMut::from(datagram.as_slice()),
                    &mut buf,
                )
                .is_none()
        );
    }
    assert_eq!(incoming.progress().generation() - before, fits);
    assert_eq!(pair.server.endpoint.incoming_buffer_bytes(), fits * charge);
    pair.server.reject(incoming);
}

/// A server config cleared while a connection attempt is pending stops new attempts; a datagram
/// the client still sends for the pending one is dropped, never a panic of the endpoint.
#[test]
fn a_pending_attempt_survives_its_server_config_being_cleared() {
    let mut pair = Pair::default();
    pair.server.handle_incoming = Box::new(|_| IncomingConnectionBehavior::Wait);
    pair.begin_connect(client_config());
    pair.drive_client();
    pair.drive_server();
    let incoming = pair
        .server
        .waiting_incoming
        .pop()
        .expect("an attempt is pending");
    let dst_cid = *incoming.orig_dst_cid();
    pair.server.endpoint.set_server_config(None);
    let mut datagram = vec![0xd0];
    datagram.extend_from_slice(&Version::V1.to_be_bytes());
    datagram.push(dst_cid.len() as u8);
    datagram.extend_from_slice(&dst_cid);
    datagram.extend_from_slice(&[0, 1, 0]);
    let before = pair.server.endpoint.incoming_buffer_bytes();
    let mut buf = Vec::new();
    assert!(
        pair.server
            .endpoint
            .handle(
                pair.time,
                pair.client.addr,
                None,
                None,
                BytesMut::from(datagram.as_slice()),
                &mut buf,
            )
            .is_none()
    );
    assert_eq!(pair.server.endpoint.incoming_buffer_bytes(), before);
    pair.server.reject(incoming);
}

#[test]
fn alpn_success() {
    let _guard = subscribe();
    let server_config = ServerConfig::with_crypto(Arc::new(server_crypto_with_alpn(vec![
        "foo".into(),
        "bar".into(),
        "baz".into(),
    ])));

    let mut pair = Pair::new(
        Arc::new(EndpointConfig::try_with_rand_key().unwrap()),
        server_config,
    );
    let client_config = ClientConfig::new(Arc::new(client_crypto_with_alpn(vec![
        "bar".into(),
        "quux".into(),
        "corge".into(),
    ])));

    // Establish normal connection
    let client_ch = pair.begin_connect(client_config);
    pair.drive();
    let server_ch = pair.server.assert_accept();
    match pair.server_conn_mut(server_ch).poll() {
        Some(Event::HandshakeDataReady) => {}
        other => {
            panic!("assertion failed: `{other:?}` does not match `Some(Event::HandshakeDataReady)`")
        }
    }
    match pair.server_conn_mut(server_ch).poll() {
        Some(Event::HandshakeConfirmed) => {}
        other => {
            panic!("assertion failed: `{other:?}` does not match `Some(Event::HandshakeConfirmed)`")
        }
    }
    match pair.server_conn_mut(server_ch).poll() {
        Some(Event::Connected) => {}
        other => panic!("assertion failed: `{other:?}` does not match `Some(Event::Connected)`"),
    }

    let settled = pair
        .client_conn_mut(client_ch)
        .crypto_session()
        .handshake_summary()
        .unwrap();
    assert_eq!(
        settled.application_layer_protocol,
        Some(rama_net::tls::ApplicationProtocol::from(&b"bar"[..]))
    );
}

#[cfg(all(feature = "rustls", any(feature = "aws-lc", feature = "ring")))]
#[test]
fn server_alpn_unset() {
    let _guard = subscribe();
    let mut pair = Pair::new(
        Arc::new(EndpointConfig::try_with_rand_key().unwrap()),
        server_config(),
    );
    let client_config = ClientConfig::new(Arc::new(client_crypto_with_alpn(vec!["foo".into()])));

    let client_ch = pair.begin_connect(client_config);
    pair.drive();
    match pair.client_conn_mut(client_ch).poll() {
        Some(Event::ConnectionLost {
            reason: ConnectionError::ConnectionClosed(err),
        }) if err.error_code == TransportErrorCode::crypto(0x78) => {}
        other => panic!(
            "assertion failed: `{other:?}` does not match `Some(Event::ConnectionLost {{ reason: ConnectionError::ConnectionClosed(err) }}) if err.error_code == TransportErrorCode::crypto(0x78)`"
        ),
    }
}

#[cfg(all(feature = "rustls", any(feature = "aws-lc", feature = "ring")))]
#[test]
fn client_alpn_unset() {
    let _guard = subscribe();
    let server_config = ServerConfig::with_crypto(Arc::new(server_crypto_with_alpn(vec![
        "foo".into(),
        "bar".into(),
        "baz".into(),
    ])));

    let mut pair = Pair::new(
        Arc::new(EndpointConfig::try_with_rand_key().unwrap()),
        server_config,
    );
    let client_ch = pair.begin_connect(client_config());
    pair.drive();
    match pair.client_conn_mut(client_ch).poll() {
        Some(Event::ConnectionLost {
            reason: ConnectionError::ConnectionClosed(err),
        }) if err.error_code == TransportErrorCode::crypto(0x78) => {}
        other => panic!(
            "assertion failed: `{other:?}` does not match `Some(Event::ConnectionLost {{ reason: ConnectionError::ConnectionClosed(err) }}) if err.error_code == TransportErrorCode::crypto(0x78)`"
        ),
    }
}

#[test]
fn alpn_mismatch() {
    let _guard = subscribe();
    let server_config = ServerConfig::with_crypto(Arc::new(server_crypto_with_alpn(vec![
        "foo".into(),
        "bar".into(),
        "baz".into(),
    ])));

    let mut pair = Pair::new(
        Arc::new(EndpointConfig::try_with_rand_key().unwrap()),
        server_config,
    );
    let client_ch = pair.begin_connect(ClientConfig::new(Arc::new(client_crypto_with_alpn(vec![
        "quux".into(),
        "corge".into(),
    ]))));

    pair.drive();
    match pair.client_conn_mut(client_ch).poll() {
        Some(Event::ConnectionLost {
            reason: ConnectionError::ConnectionClosed(err),
        }) if err.error_code == TransportErrorCode::crypto(0x78) => {}
        other => panic!(
            "assertion failed: `{other:?}` does not match `Some(Event::ConnectionLost {{ reason: ConnectionError::ConnectionClosed(err) }}) if err.error_code == TransportErrorCode::crypto(0x78)`"
        ),
    }
}

#[test]
fn stream_id_limit() {
    let _guard = subscribe();
    let server = ServerConfig {
        transport: Arc::new(TransportConfig {
            max_concurrent_uni_streams: 1u32.into(),
            ..TransportConfig::default()
        }),
        ..server_config()
    };
    let mut pair = Pair::new(
        Arc::new(EndpointConfig::try_with_rand_key().unwrap()),
        server,
    );
    let (client_ch, server_ch) = pair.connect();

    let s = pair
        .client
        .connections
        .get_mut(&client_ch)
        .unwrap()
        .streams()
        .open(Dir::Uni)
        .expect("couldn't open first stream");
    assert_eq!(
        pair.client_streams(client_ch).open(Dir::Uni),
        None,
        "only one stream is permitted at a time"
    );
    // Generate some activity to allow the server to see the stream
    const MSG: &[u8] = b"hello";
    pair.client_send(client_ch, s).write(MSG).unwrap();
    pair.client_send(client_ch, s).finish().unwrap();
    pair.drive();
    match pair.client_conn_mut(client_ch).poll() {
        Some(Event::Stream(StreamEvent::Finished { id })) if id == s => {}
        other => panic!(
            "assertion failed: `{other:?}` does not match `Some(Event::Stream(StreamEvent::Finished {{ id }})) if id == s`"
        ),
    }
    assert_eq!(
        pair.client_streams(client_ch).open(Dir::Uni),
        None,
        "server does not immediately grant additional credit"
    );
    match pair.server_conn_mut(server_ch).poll() {
        Some(Event::Stream(StreamEvent::Opened { dir: Dir::Uni })) => {}
        other => panic!(
            "assertion failed: `{other:?}` does not match `Some(Event::Stream(StreamEvent::Opened {{ dir: Dir::Uni }}))`"
        ),
    }
    match pair.server_streams(server_ch).accept(Dir::Uni) {
        Some(stream) if stream == s => {}
        other => {
            panic!("assertion failed: `{other:?}` does not match `Some(stream) if stream == s`")
        }
    }

    let mut recv = pair.server_recv(server_ch, s);
    let mut chunks = recv.read(false).unwrap();
    match chunks.next(usize::MAX) {
        Ok(Some(chunk)) if chunk.offset == 0 && chunk.bytes == MSG => {}
        other => panic!(
            "assertion failed: `{other:?}` does not match `Ok(Some(chunk)) if chunk.offset == 0 && chunk.bytes == MSG`"
        ),
    }
    assert_eq!(chunks.next(usize::MAX), Ok(None));
    let _transmit = chunks.finalize();

    // Server will only send MAX_STREAM_ID now that the application's been notified
    pair.drive();
    match pair.client_conn_mut(client_ch).poll() {
        Some(Event::Stream(StreamEvent::Available { dir: Dir::Uni })) => {}
        other => panic!(
            "assertion failed: `{other:?}` does not match `Some(Event::Stream(StreamEvent::Available {{ dir: Dir::Uni }}))`"
        ),
    }
    match pair.client_conn_mut(client_ch).poll() {
        None => {}
        other => panic!("assertion failed: `{other:?}` does not match `None`"),
    }

    // Try opening the second stream again, now that we've made room
    let s = pair
        .client
        .connections
        .get_mut(&client_ch)
        .unwrap()
        .streams()
        .open(Dir::Uni)
        .expect("didn't get stream id budget");
    pair.client_send(client_ch, s).finish().unwrap();
    pair.drive();
    // Make sure the server actually processes data on the newly-available stream
    match pair.server_conn_mut(server_ch).poll() {
        Some(Event::Stream(StreamEvent::Opened { dir: Dir::Uni })) => {}
        other => panic!(
            "assertion failed: `{other:?}` does not match `Some(Event::Stream(StreamEvent::Opened {{ dir: Dir::Uni }}))`"
        ),
    }
    match pair.server_streams(server_ch).accept(Dir::Uni) {
        Some(stream) if stream == s => {}
        other => {
            panic!("assertion failed: `{other:?}` does not match `Some(stream) if stream == s`")
        }
    }
    match pair.server_conn_mut(server_ch).poll() {
        None => {}
        other => panic!("assertion failed: `{other:?}` does not match `None`"),
    }

    let mut recv = pair.server_recv(server_ch, s);
    let mut chunks = recv.read(false).unwrap();
    match chunks.next(usize::MAX) {
        Ok(None) => {}
        other => panic!("assertion failed: `{other:?}` does not match `Ok(None)`"),
    }
    let _transmit = chunks.finalize();
}

fn streams_blocked_pair() -> Pair {
    let server = ServerConfig {
        transport: Arc::new(TransportConfig {
            max_concurrent_uni_streams: 1u32.into(),
            ..TransportConfig::default()
        }),
        ..server_config()
    };
    Pair::new(
        Arc::new(EndpointConfig::try_with_rand_key().unwrap()),
        server,
    )
}

#[test]
fn streams_blocked() {
    let _guard = subscribe();
    let mut pair = streams_blocked_pair();
    let (client_ch, server_ch) = pair.connect();

    // Use up the only stream slot, then try to open another
    let s = pair
        .client_streams(client_ch)
        .open(Dir::Uni)
        .expect("first uni stream");
    assert_eq!(pair.client_streams(client_ch).open(Dir::Uni), None);

    // Send data so the STREAMS_BLOCKED piggybacks on an outgoing packet
    pair.client_send(client_ch, s).write(b"hi").unwrap();
    pair.drive();

    assert_eq!(
        pair.client_conn_mut(client_ch)
            .stats()
            .frame_tx
            .streams_blocked_uni,
        1
    );
    assert_eq!(
        pair.server_conn_mut(server_ch)
            .stats()
            .frame_rx
            .streams_blocked_uni,
        1
    );
}

#[test]
fn streams_blocked_not_sent_under_limit() {
    let _guard = subscribe();
    let mut pair = Pair::default();
    let (client_ch, _server_ch) = pair.connect();

    // Default config allows many streams; opening one should not trigger STREAMS_BLOCKED
    let s = pair
        .client_streams(client_ch)
        .open(Dir::Uni)
        .expect("open stream");
    pair.client_send(client_ch, s).write(b"hi").unwrap();
    pair.drive();

    assert_eq!(
        pair.client_conn_mut(client_ch)
            .stats()
            .frame_tx
            .streams_blocked_uni,
        0
    );
}

/// A blocked `open` with nothing else queued must still produce a packet carrying
/// STREAMS_BLOCKED (RFC 9000 §19.14); the frame must not wait for unrelated payload.
#[test]
fn streams_blocked_sent_without_other_payload() {
    let _guard = subscribe();
    let mut pair = streams_blocked_pair();
    let (client_ch, server_ch) = pair.connect();

    let _s = pair
        .client_streams(client_ch)
        .open(Dir::Uni)
        .expect("first uni stream");
    pair.drive();
    assert_eq!(
        pair.client_conn_mut(client_ch)
            .stats()
            .frame_tx
            .streams_blocked_uni,
        0
    );

    assert_eq!(pair.client_streams(client_ch).open(Dir::Uni), None);
    // Nothing is written on any stream: the blocked open alone must be sendable work
    pair.drive_client();
    assert_eq!(
        pair.client_conn_mut(client_ch)
            .stats()
            .frame_tx
            .streams_blocked_uni,
        1
    );
    pair.drive();
    assert_eq!(
        pair.server_conn_mut(server_ch)
            .stats()
            .frame_rx
            .streams_blocked_uni,
        1
    );
    // Repeated blocked opens without a limit change do not spam the peer
    assert_eq!(pair.client_streams(client_ch).open(Dir::Uni), None);
    assert_eq!(pair.client_streams(client_ch).open(Dir::Uni), None);
    pair.drive();
    assert_eq!(
        pair.client_conn_mut(client_ch)
            .stats()
            .frame_tx
            .streams_blocked_uni,
        2
    );
}

/// A lost packet carrying STREAMS_BLOCKED is retransmitted.
#[test]
fn streams_blocked_retransmitted_after_loss() {
    let _guard = subscribe();
    let mut pair = streams_blocked_pair();
    let (client_ch, server_ch) = pair.connect();

    let _s = pair
        .client_streams(client_ch)
        .open(Dir::Uni)
        .expect("first uni stream");
    assert_eq!(pair.client_streams(client_ch).open(Dir::Uni), None);
    pair.drive_client();
    assert_eq!(
        pair.client_conn_mut(client_ch)
            .stats()
            .frame_tx
            .streams_blocked_uni,
        1
    );
    pair.server.inbound.clear(); // Lose it

    // Recover through loss detection
    pair.drive();
    assert!(
        pair.client_conn_mut(client_ch)
            .stats()
            .frame_tx
            .streams_blocked_uni
            >= 2,
        "STREAMS_BLOCKED must be retransmitted after loss"
    );
    assert!(
        pair.server_conn_mut(server_ch)
            .stats()
            .frame_rx
            .streams_blocked_uni
            >= 1
    );
}

/// Streams allocated without a STREAM frame are invisible to the peer. A
/// STREAMS_BLOCKED frame must release earned credit even when observed IDs
/// have not exhausted the grant and the ordinary batching threshold is unmet.
#[test]
fn streams_blocked_releases_batched_credit_for_unannounced_streams() {
    const CREDIT: u32 = 16;
    let _guard = subscribe();
    for dir in Dir::iter() {
        let mut pair = Pair::new(
            Arc::new(EndpointConfig::try_with_rand_key().unwrap()),
            ServerConfig {
                transport: Arc::new(TransportConfig {
                    max_concurrent_uni_streams: CREDIT.into(),
                    max_concurrent_bidi_streams: CREDIT.into(),
                    ..TransportConfig::default()
                }),
                ..server_config()
            },
        );
        let (client_ch, server_ch) = pair.connect();
        let first = pair.client_streams(client_ch).open(dir).unwrap();
        for _ in 1..CREDIT {
            pair.client_streams(client_ch).open(dir).unwrap();
        }
        // Only stream zero reaches the peer; the other slots remain reserved.
        pair.client_send(client_ch, first).finish().unwrap();
        pair.drive();
        assert_eq!(pair.server_streams(server_ch).accept(dir), Some(first));
        assert_eq!(pair.server_streams(server_ch).accept(dir), None);
        let mut recv = pair.server_recv(server_ch, first);
        let mut chunks = recv.read(true).unwrap();
        assert!(chunks.next(1).unwrap().is_none());
        let _transmit = chunks.finalize();
        if dir == Dir::Bi {
            pair.server_send(server_ch, first).finish().unwrap();
            pair.drive();
            let mut recv = pair.client_recv(client_ch, first);
            let mut chunks = recv.read(true).unwrap();
            assert!(chunks.next(1).unwrap().is_none());
            let _transmit = chunks.finalize();
        }
        pair.drive();
        let stats = pair.server_conn_mut(server_ch).stats().frame_tx;
        assert_eq!(stats.max_streams_bidi + stats.max_streams_uni, 0);

        assert_eq!(pair.client_streams(client_ch).open(dir), None);
        pair.drive();
        let stats = pair.server_conn_mut(server_ch).stats();
        assert_eq!(
            stats.frame_rx.streams_blocked_bidi + stats.frame_rx.streams_blocked_uni,
            1
        );
        assert_eq!(
            stats.frame_tx.max_streams_bidi + stats.frame_tx.max_streams_uni,
            1
        );
        let next = pair
            .client_streams(client_ch)
            .open(dir)
            .expect("freed slot advertised");
        assert_eq!(next.index(), u64::from(CREDIT));
        assert_eq!(pair.client_streams(client_ch).open(dir), None);
        pair.drive();
        let stats = pair.server_conn_mut(server_ch).stats().frame_tx;
        assert_eq!(
            stats.max_streams_bidi + stats.max_streams_uni,
            1,
            "unchanged credit must not trigger another MAX_STREAMS frame"
        );
    }
}

/// Once the peer raises the limit (MAX_STREAMS), the blocked flag is cleared and a subsequent
/// successful `open` does not emit STREAMS_BLOCKED.
#[test]
fn streams_blocked_cleared_by_max_streams() {
    let _guard = subscribe();
    let mut pair = streams_blocked_pair();
    let (client_ch, server_ch) = pair.connect();

    let s = pair
        .client_streams(client_ch)
        .open(Dir::Uni)
        .expect("first uni stream");
    assert_eq!(pair.client_streams(client_ch).open(Dir::Uni), None);
    pair.client_send(client_ch, s).write(b"hi").unwrap();
    pair.client_send(client_ch, s).finish().unwrap();
    pair.drive();
    assert_eq!(
        pair.client_conn_mut(client_ch)
            .stats()
            .frame_tx
            .streams_blocked_uni,
        1
    );

    // Server consumes the stream, which frees a stream slot and yields MAX_STREAMS
    match pair.server_streams(server_ch).accept(Dir::Uni) {
        Some(id) if id == s => {}
        other => panic!("assertion failed: `{other:?}` does not match `Some(id) if id == s`"),
    }
    let mut recv = pair.server_recv(server_ch, s);
    let mut chunks = recv.read(true).unwrap();
    match chunks.next(usize::MAX) {
        Ok(Some(_)) => {}
        other => panic!("assertion failed: `{other:?}` does not match `Ok(Some(_))`"),
    }
    match chunks.next(usize::MAX) {
        Err(ReadError::Blocked) | Ok(None) => {}
        other => panic!(
            "assertion failed: `{other:?}` does not match `Err(ReadError::Blocked) | Ok(None)`"
        ),
    }
    let _transmit = chunks.finalize();
    pair.drive();
    assert!(
        pair.server_conn_mut(server_ch)
            .stats()
            .frame_tx
            .max_streams_uni
            >= 1,
        "server must have raised the uni stream limit"
    );

    // Drain the client's events: the limit increase is announced as Available
    let mut available = false;
    while let Some(event) = pair.client_conn_mut(client_ch).poll() {
        if matches!(
            event,
            Event::Stream(StreamEvent::Available { dir: Dir::Uni })
        ) {
            available = true;
        }
    }
    assert!(available, "client must learn about the raised limit");

    // Opening succeeds now and must not produce another STREAMS_BLOCKED
    let s2 = pair
        .client_streams(client_ch)
        .open(Dir::Uni)
        .expect("stream limit was raised");
    pair.client_send(client_ch, s2).write(b"again").unwrap();
    pair.drive();
    assert_eq!(
        pair.client_conn_mut(client_ch)
            .stats()
            .frame_tx
            .streams_blocked_uni,
        1
    );
}

/// A peer that stops acknowledging while it keeps the connection busy must not let packet
/// numbers outrun their 4-byte encoding: near the limit the connection closes, naming why, and
/// past it nothing more is sent.
#[test]
fn packet_numbers_cannot_outrun_acknowledgements() {
    let _guard = subscribe();
    for server_sends in [false, true] {
        for (distance, closes_with_a_packet) in [
            (
                rama_quic_proto::packet::MAX_PACKET_NUMBER_DISTANCE - 1000,
                true,
            ),
            (
                rama_quic_proto::packet::MAX_PACKET_NUMBER_DISTANCE + 1,
                false,
            ),
            (u64::from(u32::MAX) * 4, false),
        ] {
            let mut pair = Pair::default();
            let (client_ch, server_ch) = pair.connect();
            let before = if server_sends {
                pair.server_conn_mut(server_ch)
                    .set_packet_number_distance(distance);
                let stream = pair.server_streams(server_ch).open(Dir::Uni).unwrap();
                pair.server_send(server_ch, stream).write(b"data").unwrap();
                pair.server_sent.len()
            } else {
                pair.client_conn_mut(client_ch)
                    .set_packet_number_distance(distance);
                let stream = pair.client_streams(client_ch).open(Dir::Uni).unwrap();
                pair.client_send(client_ch, stream).write(b"data").unwrap();
                pair.client_sent.len()
            };
            let (sent, event) = if server_sends {
                pair.drive_server();
                (
                    pair.server_sent.len() - before,
                    pair.server_conn_mut(server_ch).poll(),
                )
            } else {
                pair.drive_client();
                (
                    pair.client_sent.len() - before,
                    pair.client_conn_mut(client_ch).poll(),
                )
            };
            assert_eq!(
                sent > 0,
                closes_with_a_packet,
                "distance {distance}, server sends: {server_sends}"
            );
            match event {
                Some(Event::ConnectionLost {
                    reason:
                        ConnectionError::TransportError(TransportError {
                            code: TransportErrorCode::INTERNAL_ERROR,
                            ref reason,
                            ..
                        }),
                }) if reason == "packet numbers outran acknowledgements" => {}
                other => panic!("distance {distance}, server sends: {server_sends}: {other:?}"),
            }
        }
    }
}

/// RFC 9001 §6.6 at three points: one packet of budget left, none left, and past the limit. A
/// key phase is usually retired long before its keys reach the limit, but an update is not always
/// available, so the limit itself has to hold. The last packet of budget carries the close.
#[test]
fn one_rtt_keys_stop_at_their_confidentiality_limit_when_no_update_is_available() {
    let _guard = subscribe();

    // One packet of budget left: the close packet is sent, and it says why.
    let mut pair = Pair::default();
    let (client_ch, _server_ch) = pair.connect();
    let limit = pair.client_conn_mut(client_ch).confidentiality_limit();
    assert!(
        pair.client_force_key_update(client_ch),
        "the first update starts"
    );
    assert!(
        !pair.client_force_key_update(client_ch),
        "a second update cannot start while the first is unacknowledged"
    );
    pair.client_conn_mut(client_ch)
        .set_packets_sent_with_keys(limit - 1);
    let stream = pair
        .client_streams(client_ch)
        .open(Dir::Bi)
        .expect("a stream opens");
    pair.client_send(client_ch, stream)
        .write(b"the last packet")
        .expect("the write is queued");
    let before = pair.client_sent.len();
    pair.drive_client();
    assert_eq!(
        pair.client_sent.len() - before,
        1,
        "the remaining budget covers exactly one packet"
    );
    assert_eq!(
        pair.client_conn_mut(client_ch).packets_sent_with_keys(),
        limit,
        "the budget is spent exactly"
    );
    match pair.client_conn_mut(client_ch).poll() {
        Some(Event::ConnectionLost {
            reason:
                ConnectionError::TransportError(TransportError {
                    code: TransportErrorCode::AEAD_LIMIT_REACHED,
                    ref reason,
                    ..
                }),
        }) if reason == "confidentiality limit reached" => {}
        other => panic!("the connection ends naming the limit: {other:?}"),
    }

    // No budget left: nothing is encrypted, and the connection ends naming the limit.
    let mut pair = Pair::default();
    let (client_ch, _server_ch) = pair.connect();
    let limit = pair.client_conn_mut(client_ch).confidentiality_limit();
    assert!(pair.client_force_key_update(client_ch));
    pair.client_conn_mut(client_ch)
        .set_packets_sent_with_keys(limit);
    let stream = pair
        .client_streams(client_ch)
        .open(Dir::Bi)
        .expect("a stream opens");
    pair.client_send(client_ch, stream)
        .write(b"no budget remains")
        .expect("the write is queued");
    let before = pair.client_sent.len();
    pair.drive_client();
    assert_eq!(
        pair.client_sent.len() - before,
        0,
        "nothing is encrypted with keys that have no budget"
    );
    assert_eq!(
        pair.client_conn_mut(client_ch).packets_sent_with_keys(),
        limit,
        "the count does not move"
    );
    match pair.client_conn_mut(client_ch).poll() {
        Some(Event::ConnectionLost {
            reason:
                ConnectionError::TransportError(TransportError {
                    code: TransportErrorCode::AEAD_LIMIT_REACHED,
                    ..
                }),
        }) => {}
        other => panic!("the connection ends naming the limit: {other:?}"),
    }

    // Past the limit, the same: a connection that somehow got there sends nothing more.
    let mut pair = Pair::default();
    let (client_ch, _server_ch) = pair.connect();
    let limit = pair.client_conn_mut(client_ch).confidentiality_limit();
    assert!(pair.client_force_key_update(client_ch));
    pair.client_conn_mut(client_ch)
        .set_packets_sent_with_keys(limit + 1);
    let stream = pair
        .client_streams(client_ch)
        .open(Dir::Bi)
        .expect("a stream opens");
    pair.client_send(client_ch, stream)
        .write(b"well past it")
        .expect("the write is queued");
    let before = pair.client_sent.len();
    pair.drive_client();
    assert_eq!(
        pair.client_sent.len() - before,
        0,
        "nothing is encrypted past the limit"
    );
}

/// A packet number the filter passes over to catch a peer acknowledging what it never
/// received (RFC 9000 §21.4) protects nothing, so it costs a number and not a use of the keys.
/// RFC 9001 §6.6 counts packets protected, and a skip at the last packet of the budget must
/// not spend two of it.
#[test]
fn a_skipped_packet_number_does_not_spend_the_key_budget() {
    let _guard = subscribe();

    for skip in [false, true] {
        for from_the_end in [1u64, 0] {
            let mut pair = Pair::default();
            let (client_ch, _server_ch) = pair.connect();
            pair.drive();
            let limit = pair.client_conn_mut(client_ch).confidentiality_limit();
            assert!(pair.client_force_key_update(client_ch));
            pair.client_conn_mut(client_ch)
                .set_packets_sent_with_keys(limit - from_the_end);
            match skip {
                true => pair.client_conn_mut(client_ch).skip_next_packet_number(),
                // The filter's first skip is a random number in 0..64, which the handshake can
                // leave just ahead of this pass; this case is about a pass that skips nothing.
                false => pair.client_conn_mut(client_ch).skip_no_packet_number(),
            }
            let (skipped_before, number_before) = pair.client_conn_mut(client_ch).packet_numbers();
            let counted_before = pair.client_conn_mut(client_ch).packets_sent_with_keys();

            let stream = pair
                .client_streams(client_ch)
                .open(Dir::Bi)
                .expect("a stream opens");
            pair.client_send(client_ch, stream)
                .write(b"one packet of budget")
                .expect("the write is queued");
            let sent_before = pair.client_sent.len();
            pair.drive_client();
            let sent = pair.client_sent.len() - sent_before;

            let (skipped, number_after) = pair.client_conn_mut(client_ch).packet_numbers();
            let counted = pair.client_conn_mut(client_ch).packets_sent_with_keys();
            assert_eq!(
                sent as u64, from_the_end,
                "the pass sends the {from_the_end} packets the budget has left"
            );
            assert_eq!(
                counted - counted_before,
                sent as u64,
                "the budget is spent once per packet the keys protected ({skip}, \
                 {from_the_end} from the end)"
            );
            if skip && sent > 0 {
                assert_eq!(
                    skipped,
                    Some(number_before),
                    "the filter passed over the number this pass started at"
                );
                assert_ne!(
                    skipped, skipped_before,
                    "which it had not passed over before"
                );
                assert_eq!(
                    number_after - number_before,
                    sent as u64 + 1,
                    "and that number is spent, on top of the packets that were protected"
                );
            } else {
                assert_eq!(
                    number_after - number_before,
                    sent as u64,
                    "without a skip a number is spent per packet"
                );
            }
            assert!(
                counted <= limit,
                "and never past the limit: {counted} against {limit}"
            );
        }
    }
}

/// The count belongs to the keys. An update starts the new phase at zero, so a connection that
/// rotates keeps sending, and its peer receives what it sends.
#[test]
fn a_key_update_starts_the_new_phase_count_at_zero() {
    let _guard = subscribe();
    let mut pair = Pair::default();
    let (client_ch, server_ch) = pair.connect();

    let limit = pair.client_conn_mut(client_ch).confidentiality_limit();
    pair.client_conn_mut(client_ch)
        .set_packets_sent_with_keys(limit - 2);
    assert!(pair.client_force_key_update(client_ch), "the update starts");
    assert_eq!(
        pair.client_conn_mut(client_ch).packets_sent_with_keys(),
        0,
        "the new keys have sent nothing yet"
    );

    let stream = pair
        .client_streams(client_ch)
        .open(Dir::Bi)
        .expect("a stream opens");
    const MESSAGE: &[u8] = b"after the update";
    pair.client_send(client_ch, stream)
        .write(MESSAGE)
        .expect("the write is queued");
    pair.drive();

    assert_eq!(
        pair.server_streams(server_ch).accept(Dir::Bi),
        Some(stream),
        "the peer sees the stream"
    );
    let mut received = pair.server_recv(server_ch, stream);
    let mut chunks = received.read(true).expect("the stream is readable");
    let chunk = chunks
        .next(MESSAGE.len())
        .expect("a chunk arrives")
        .expect("with the payload");
    assert_eq!(&chunk.bytes[..], MESSAGE, "the payload arrives as sent");
    let _transmit = chunks.finalize();
}

/// The first key update comes within 1000 packets by default. Without the early update
/// (an interop-fixture switch for peers with key-update bugs) it waits for the limit.
#[test]
fn early_key_update_is_on_by_default_and_can_be_turned_off() {
    let _guard = subscribe();
    for early in [None, Some(false)] {
        let mut transport = TransportConfig::default();
        if let Some(early) = early {
            transport.set_early_key_update(early);
        }
        let transport = Arc::new(transport);
        let mut server_config = server_config();
        server_config.transport = transport.clone();
        let mut pair = Pair::new(
            Arc::new(EndpointConfig::try_with_rand_key().unwrap()),
            server_config,
        );
        let mut config = client_config();
        config.set_transport_config(transport);
        let (client, server) = pair.connect_with(config);

        // One ack-eliciting packet a round: past any randomized first phase.
        for _ in 0..1_100 {
            pair.client_conn_mut(client).ping();
            pair.drive();
        }
        let updates = pair.client_conn_mut(client).stats().key_updates
            + pair.server_conn_mut(server).stats().key_updates;
        if early.is_none() {
            assert!(updates > 0, "the default updates keys early");
        } else {
            assert_eq!(updates, 0, "no early update when turned off");
        }
    }
}

#[test]
fn key_update_simple() {
    let _guard = subscribe();
    let mut pair = Pair::default();
    let (client_ch, server_ch) = pair.connect();
    let s = pair
        .client
        .connections
        .get_mut(&client_ch)
        .unwrap()
        .streams()
        .open(Dir::Bi)
        .expect("couldn't open first stream");

    const MSG1: &[u8] = b"hello1";
    pair.client_send(client_ch, s).write(MSG1).unwrap();
    pair.drive();

    match pair.server_conn_mut(server_ch).poll() {
        Some(Event::Stream(StreamEvent::Opened { dir: Dir::Bi })) => {}
        other => panic!(
            "assertion failed: `{other:?}` does not match `Some(Event::Stream(StreamEvent::Opened {{ dir: Dir::Bi }}))`"
        ),
    }
    match pair.server_streams(server_ch).accept(Dir::Bi) {
        Some(stream) if stream == s => {}
        other => {
            panic!("assertion failed: `{other:?}` does not match `Some(stream) if stream == s`")
        }
    }
    match pair.server_conn_mut(server_ch).poll() {
        None => {}
        other => panic!("assertion failed: `{other:?}` does not match `None`"),
    }
    let mut recv = pair.server_recv(server_ch, s);
    let mut chunks = recv.read(false).unwrap();
    match chunks.next(usize::MAX) {
        Ok(Some(chunk)) if chunk.offset == 0 && chunk.bytes == MSG1 => {}
        other => panic!(
            "assertion failed: `{other:?}` does not match `Ok(Some(chunk)) if chunk.offset == 0 && chunk.bytes == MSG1`"
        ),
    }
    let _transmit = chunks.finalize();

    info!("initiating key update");
    pair.client_force_key_update(client_ch);

    const MSG2: &[u8] = b"hello2";
    pair.client_send(client_ch, s).write(MSG2).unwrap();
    pair.drive();

    match pair.server_conn_mut(server_ch).poll() {
        Some(Event::Stream(StreamEvent::Readable { id })) if id == s => {}
        other => panic!(
            "assertion failed: `{other:?}` does not match `Some(Event::Stream(StreamEvent::Readable {{ id }})) if id == s`"
        ),
    }
    match pair.server_conn_mut(server_ch).poll() {
        None => {}
        other => panic!("assertion failed: `{other:?}` does not match `None`"),
    }
    let mut recv = pair.server_recv(server_ch, s);
    let mut chunks = recv.read(false).unwrap();
    match chunks.next(usize::MAX) {
        Ok(Some(chunk)) if chunk.offset == 6 && chunk.bytes == MSG2 => {}
        other => panic!(
            "assertion failed: `{other:?}` does not match `Ok(Some(chunk)) if chunk.offset == 6 && chunk.bytes == MSG2`"
        ),
    }
    let _transmit = chunks.finalize();

    assert_eq!(pair.client_conn_mut(client_ch).stats().path.lost_packets, 0);
    assert_eq!(pair.server_conn_mut(server_ch).stats().path.lost_packets, 0);
}

#[test]
fn key_update_reordered() {
    let _guard = subscribe();
    let mut pair = Pair::default();
    let (client_ch, server_ch) = pair.connect();
    let s = pair
        .client
        .connections
        .get_mut(&client_ch)
        .unwrap()
        .streams()
        .open(Dir::Bi)
        .expect("couldn't open first stream");

    const MSG1: &[u8] = b"1";
    pair.client_send(client_ch, s).write(MSG1).unwrap();
    pair.client.drive(pair.time, pair.server.addr);
    assert!(!pair.client.outbound.is_empty());
    pair.client.delay_outbound();

    pair.client_force_key_update(client_ch);
    info!("updated keys");

    const MSG2: &[u8] = b"two";
    pair.client_send(client_ch, s).write(MSG2).unwrap();
    pair.client.drive(pair.time, pair.server.addr);
    pair.client.finish_delay();
    pair.drive();

    assert_eq!(pair.client_conn_mut(client_ch).stats().path.lost_packets, 0);
    match pair.server_conn_mut(server_ch).poll() {
        Some(Event::Stream(StreamEvent::Opened { dir: Dir::Bi })) => {}
        other => panic!(
            "assertion failed: `{other:?}` does not match `Some(Event::Stream(StreamEvent::Opened {{ dir: Dir::Bi }}))`"
        ),
    }
    match pair.server_streams(server_ch).accept(Dir::Bi) {
        Some(stream) if stream == s => {}
        other => {
            panic!("assertion failed: `{other:?}` does not match `Some(stream) if stream == s`")
        }
    }

    let mut recv = pair.server_recv(server_ch, s);
    let mut chunks = recv.read(true).unwrap();
    let buf1 = chunks.next(usize::MAX).unwrap().unwrap();
    match &*buf1.bytes {
        MSG1 => {}
        other => panic!("assertion failed: `{other:?}` does not match `MSG1`"),
    }
    let buf2 = chunks.next(usize::MAX).unwrap().unwrap();
    assert_eq!(buf2.bytes, MSG2);
    let _transmit = chunks.finalize();

    assert_eq!(pair.client_conn_mut(client_ch).stats().path.lost_packets, 0);
    assert_eq!(pair.server_conn_mut(server_ch).stats().path.lost_packets, 0);
}

#[test]
fn initial_retransmit() {
    let _guard = subscribe();
    let mut pair = Pair::default();
    let client_ch = pair.begin_connect(client_config());
    pair.client.drive(pair.time, pair.server.addr);
    pair.client.outbound.clear(); // Drop initial
    pair.drive();
    match pair.client_conn_mut(client_ch).poll() {
        Some(Event::HandshakeDataReady) => {}
        other => {
            panic!("assertion failed: `{other:?}` does not match `Some(Event::HandshakeDataReady)`")
        }
    }
    match pair.client_conn_mut(client_ch).poll() {
        Some(Event::Connected) => {}
        other => panic!("assertion failed: `{other:?}` does not match `Some(Event::Connected)`"),
    }
}

#[test]
fn instant_close_1() {
    let _guard = subscribe();
    let mut pair = Pair::default();
    info!("connecting");
    let client_ch = pair.begin_connect(client_config());
    pair.client.connections.get_mut(&client_ch).unwrap().close(
        pair.time,
        VarInt::from_u32(0),
        Bytes::new(),
    );
    pair.drive();
    let server_ch = pair.server.assert_accept();
    match pair.client_conn_mut(client_ch).poll() {
        None => {}
        other => panic!("assertion failed: `{other:?}` does not match `None`"),
    }
    match pair.server_conn_mut(server_ch).poll() {
        Some(Event::ConnectionLost {
            reason:
                ConnectionError::ConnectionClosed(ConnectionClose {
                    error_code: TransportErrorCode::APPLICATION_ERROR,
                    ..
                }),
        }) => {}
        other => panic!(
            "assertion failed: `{other:?}` does not match `Some(Event::ConnectionLost {{ reason: ConnectionError::ConnectionClosed(ConnectionClose {{ error_code: TransportErrorCode::APPLICATION_ERROR, .. }}), }})`"
        ),
    }
}

#[test]
fn instant_close_2() {
    let _guard = subscribe();
    let mut pair = Pair::default();
    info!("connecting");
    let client_ch = pair.begin_connect(client_config());
    // Unlike `instant_close`, the server sees a valid Initial packet first.
    pair.drive_client();
    pair.client.connections.get_mut(&client_ch).unwrap().close(
        pair.time,
        VarInt::from_u32(42),
        Bytes::new(),
    );
    pair.drive();
    match pair.client_conn_mut(client_ch).poll() {
        None => {}
        other => panic!("assertion failed: `{other:?}` does not match `None`"),
    }
    let server_ch = pair.server.assert_accept();
    match pair.server_conn_mut(server_ch).poll() {
        Some(Event::HandshakeDataReady) => {}
        other => {
            panic!("assertion failed: `{other:?}` does not match `Some(Event::HandshakeDataReady)`")
        }
    }
    match pair.server_conn_mut(server_ch).poll() {
        Some(Event::ConnectionLost {
            reason:
                ConnectionError::ConnectionClosed(ConnectionClose {
                    error_code: TransportErrorCode::APPLICATION_ERROR,
                    ..
                }),
        }) => {}
        other => panic!(
            "assertion failed: `{other:?}` does not match `Some(Event::ConnectionLost {{ reason: ConnectionError::ConnectionClosed(ConnectionClose {{ error_code: TransportErrorCode::APPLICATION_ERROR, .. }}), }})`"
        ),
    }
}

#[test]
fn instant_server_close() {
    let _guard = subscribe();
    let mut pair = Pair::default();
    info!("connecting");
    pair.begin_connect(client_config());
    pair.drive_client();
    pair.server.drive_incoming(pair.time, pair.client.addr);
    let server_ch = pair.server.assert_accept();
    info!("closing");
    pair.server.connections.get_mut(&server_ch).unwrap().close(
        pair.time,
        VarInt::from_u32(42),
        Bytes::new(),
    );
    pair.drive();
    match pair.client_conn_mut(server_ch).poll() {
        Some(Event::ConnectionLost {
            reason:
                ConnectionError::ConnectionClosed(ConnectionClose {
                    error_code: TransportErrorCode::APPLICATION_ERROR,
                    ..
                }),
        }) => {}
        other => panic!(
            "assertion failed: `{other:?}` does not match `Some(Event::ConnectionLost {{ reason: ConnectionError::ConnectionClosed(ConnectionClose {{ error_code: TransportErrorCode::APPLICATION_ERROR, .. }}), }})`"
        ),
    }
}

#[test]
fn idle_timeout() {
    let _guard = subscribe();
    const IDLE_TIMEOUT: u64 = 100;
    let server = ServerConfig {
        transport: Arc::new(TransportConfig {
            max_idle_timeout: Some(VarInt::from_u32(IDLE_TIMEOUT as u32)),
            ..TransportConfig::default()
        }),
        ..server_config()
    };
    let mut pair = Pair::new(
        Arc::new(EndpointConfig::try_with_rand_key().unwrap()),
        server,
    );
    let (client_ch, server_ch) = pair.connect();
    pair.client_conn_mut(client_ch).ping();
    let start = pair.time;

    while !pair.client_conn_mut(client_ch).is_closed()
        || !pair.server_conn_mut(server_ch).is_closed()
    {
        if !pair.step()
            && let Some(t) = min_opt(pair.client.next_wakeup(), pair.server.next_wakeup())
        {
            pair.time = t;
        }
        pair.client.inbound.clear(); // Simulate total S->C packet loss
    }

    assert!(pair.time - start < Duration::from_millis(2 * IDLE_TIMEOUT));
    match pair.client_conn_mut(client_ch).poll() {
        Some(Event::ConnectionLost {
            reason: ConnectionError::TimedOut,
        }) => {}
        other => panic!(
            "assertion failed: `{other:?}` does not match `Some(Event::ConnectionLost {{ reason: ConnectionError::TimedOut, }})`"
        ),
    }
    match pair.server_conn_mut(server_ch).poll() {
        Some(Event::ConnectionLost {
            reason: ConnectionError::TimedOut,
        }) => {}
        other => panic!(
            "assertion failed: `{other:?}` does not match `Some(Event::ConnectionLost {{ reason: ConnectionError::TimedOut, }})`"
        ),
    }
}

#[test]
fn connection_close_sends_acks() {
    let _guard = subscribe();
    let mut pair = Pair::default();
    let (client_ch, _server_ch) = pair.connect();

    let client_acks = pair.client_conn_mut(client_ch).stats().frame_rx.acks;

    pair.client_conn_mut(client_ch).ping();
    pair.drive_client();

    let time = pair.time;
    pair.server_conn_mut(client_ch)
        .close(time, VarInt::from_u32(42), Bytes::new());

    pair.drive();

    let client_acks_2 = pair.client_conn_mut(client_ch).stats().frame_rx.acks;
    assert!(
        client_acks_2 > client_acks,
        "Connection close should send pending ACKs"
    );
}

/// A connection closed while its congestion window is saturated must still deliver
/// CONNECTION_CLOSE to the peer promptly, rather than leaving the peer to discover the close via
/// its idle timeout
#[test]
fn connection_close_while_congestion_blocked() {
    let _guard = subscribe();
    let mut pair = Pair::default();
    let (client_ch, server_ch) = pair.connect();

    // Saturate the congestion window with unacknowledged stream data by transmitting from the
    // client without driving the server, so no ACKs come back and in-flight bytes stay pinned at
    // the window
    let s = pair.client_streams(client_ch).open(Dir::Uni).unwrap();
    pair.client_send(client_ch, s)
        .write(&[42; octets::mib(1)])
        .unwrap();
    pair.drive_client();

    // Close while the window is full and stream data is still pending
    const REASON: &[u8] = b"whee";
    let close_time = pair.time;
    pair.client.connections.get_mut(&client_ch).unwrap().close(
        pair.time,
        VarInt::from_u32(42),
        REASON.into(),
    );

    // Step the simulation by hand so we can catch the exact moment the server hears about the
    // close: check for the event after each packet exchange, before the clock jumps ahead
    let mut result = None;
    for _ in 0..500 {
        pair.drive_client();
        pair.drive_server();
        while let Some(event) = pair.server_conn_mut(server_ch).poll() {
            if let Event::ConnectionLost { reason } = event {
                result = Some((reason, pair.time));
            }
        }
        if result.is_some() || !pair.step() {
            break;
        }
    }
    let (reason, delivered_at) = result.expect("server never learned of the close");
    match reason {
        ConnectionError::ApplicationClosed(ApplicationClose {
            error_code,
            ref reason,
        }) if reason == REASON && error_code == VarInt::from_u32(42) => {}
        other => panic!(
            "assertion failed: `{other:?}` does not match `ConnectionError::ApplicationClosed( ApplicationClose {{ error_code: VarInt::from_u32(42), ref reason }} ) if reason == REASON`"
        ),
    }
    // Close packets aren't congestion controlled and the test link has no latency, so the close
    // should arrive the moment it was issued; any delay means a timer had to rescue it
    assert_eq!(delivered_at, close_time);
}

#[test]
fn server_hs_retransmit() {
    let _guard = subscribe();
    let mut pair = Pair::default();
    let client_ch = pair.begin_connect(client_config());
    pair.step();
    assert!(!pair.client.inbound.is_empty()); // Initial + Handshakes
    pair.client.inbound.clear();
    pair.drive();
    match pair.client_conn_mut(client_ch).poll() {
        Some(Event::HandshakeDataReady) => {}
        other => {
            panic!("assertion failed: `{other:?}` does not match `Some(Event::HandshakeDataReady)`")
        }
    }
    match pair.client_conn_mut(client_ch).poll() {
        Some(Event::Connected) => {}
        other => panic!("assertion failed: `{other:?}` does not match `Some(Event::Connected)`"),
    }
}

#[test]
fn migration() {
    let _guard = subscribe();
    let mut pair = Pair::default();
    let (client_ch, server_ch) = pair.connect();
    pair.drive();

    let client_stats_after_connect = pair.client_conn_mut(client_ch).stats();

    pair.client.addr = SocketAddr::new(
        Ipv4Addr::new(127, 0, 0, 1).into(),
        CLIENT_PORTS.lock().next().unwrap(),
    );
    pair.client_conn_mut(client_ch).ping();

    // Assert that just receiving the ping message is accounted into the servers
    // anti-amplification budget
    pair.drive_client();
    pair.drive_server();
    assert_ne!(pair.server_conn_mut(server_ch).total_recvd(), 0);

    pair.drive();
    match pair.client_conn_mut(client_ch).poll() {
        None => {}
        other => panic!("assertion failed: `{other:?}` does not match `None`"),
    }
    assert_eq!(
        pair.server_conn_mut(server_ch).remote_address(),
        pair.client.addr
    );

    // Assert that the client's response to the PATH_CHALLENGE was an IMMEDIATE_ACK, instead of a
    // second ping. There are two challenges to answer: the server's first one goes out under the
    // amplification limit on the new address and so cannot prove the path carries 1200 bytes, and
    // RFC 9000 §8.2.3 asks for a second, expanded validation once the address itself is settled.
    let client_stats_after_migrate = pair.client_conn_mut(client_ch).stats();
    assert_eq!(
        client_stats_after_migrate.frame_tx.ping - client_stats_after_connect.frame_tx.ping,
        1
    );
    assert_eq!(
        client_stats_after_migrate.frame_tx.immediate_ack
            - client_stats_after_connect.frame_tx.immediate_ack,
        2
    );
}

fn test_flow_control(config: TransportConfig, window_size: usize) {
    let _guard = subscribe();
    let mut pair = Pair::new(
        Arc::new(EndpointConfig::try_with_rand_key().unwrap()),
        ServerConfig {
            transport: Arc::new(config),
            ..server_config()
        },
    );
    let (client_ch, server_ch) = pair.connect();
    let msg = vec![0xAB; window_size + 10];

    // Stream reset before read
    let s = pair.client_streams(client_ch).open(Dir::Uni).unwrap();
    info!("writing");
    assert_eq!(pair.client_send(client_ch, s).write(&msg), Ok(window_size));
    assert_eq!(
        pair.client_send(client_ch, s).write(&msg[window_size..]),
        Err(WriteError::Blocked)
    );
    pair.drive();
    info!("resetting");
    pair.client_send(client_ch, s)
        .reset(VarInt::from_u32(42))
        .unwrap();
    pair.drive();

    let mut recv = pair.server_recv(server_ch, s);
    let mut chunks = recv.read(true).unwrap();
    assert_eq!(
        chunks.next(usize::MAX).err(),
        Some(ReadError::Reset(VarInt::from_u32(42)))
    );
    let _transmit = chunks.finalize();

    // Happy path
    info!("writing");
    let s = pair.client_streams(client_ch).open(Dir::Uni).unwrap();
    assert_eq!(pair.client_send(client_ch, s).write(&msg), Ok(window_size));
    assert_eq!(
        pair.client_send(client_ch, s).write(&msg[window_size..]),
        Err(WriteError::Blocked)
    );

    pair.drive();
    let mut cursor = 0;
    let mut recv = pair.server_recv(server_ch, s);
    let mut chunks = recv.read(true).unwrap();
    loop {
        match chunks.next(usize::MAX) {
            Ok(Some(chunk)) => {
                cursor += chunk.bytes.len();
            }
            Ok(None) => {
                panic!("end of stream");
            }
            Err(ReadError::Blocked) => {
                break;
            }
            Err(e) => {
                panic!("{}", e);
            }
        }
    }
    let _transmit = chunks.finalize();

    info!("finished reading");
    assert_eq!(cursor, window_size);
    pair.drive();
    info!("writing");
    assert_eq!(pair.client_send(client_ch, s).write(&msg), Ok(window_size));
    assert_eq!(
        pair.client_send(client_ch, s).write(&msg[window_size..]),
        Err(WriteError::Blocked)
    );

    pair.drive();
    let mut cursor = 0;
    let mut recv = pair.server_recv(server_ch, s);
    let mut chunks = recv.read(true).unwrap();
    loop {
        match chunks.next(usize::MAX) {
            Ok(Some(chunk)) => {
                cursor += chunk.bytes.len();
            }
            Ok(None) => {
                panic!("end of stream");
            }
            Err(ReadError::Blocked) => {
                break;
            }
            Err(e) => {
                panic!("{}", e);
            }
        }
    }
    assert_eq!(cursor, window_size);
    let _transmit = chunks.finalize();
    info!("finished reading");
}

#[test]
fn stream_flow_control() {
    test_flow_control(
        TransportConfig {
            stream_receive_window: 2000u32.into(),
            ..TransportConfig::default()
        },
        2000,
    );
}

#[test]
fn conn_flow_control() {
    test_flow_control(
        TransportConfig {
            receive_window: 2000u32.into(),
            ..TransportConfig::default()
        },
        2000,
    );
}

#[test]
fn stop_opens_bidi() {
    let _guard = subscribe();
    let mut pair = Pair::default();
    let (client_ch, server_ch) = pair.connect();
    assert_eq!(pair.client_streams(client_ch).send_streams(), 0);
    let s = pair.client_streams(client_ch).open(Dir::Bi).unwrap();
    assert_eq!(pair.client_streams(client_ch).send_streams(), 1);
    const ERROR: VarInt = VarInt::from_u32(42);
    pair.client
        .connections
        .get_mut(&server_ch)
        .unwrap()
        .recv_stream(s)
        .stop(ERROR)
        .unwrap();
    pair.drive();

    match pair.server_conn_mut(server_ch).poll() {
        Some(Event::Stream(StreamEvent::Opened { dir: Dir::Bi })) => {}
        other => panic!(
            "assertion failed: `{other:?}` does not match `Some(Event::Stream(StreamEvent::Opened {{ dir: Dir::Bi }}))`"
        ),
    }
    assert_eq!(pair.server_conn_mut(client_ch).streams().send_streams(), 0);
    match pair.server_streams(server_ch).accept(Dir::Bi) {
        Some(stream) if stream == s => {}
        other => {
            panic!("assertion failed: `{other:?}` does not match `Some(stream) if stream == s`")
        }
    }
    assert_eq!(pair.server_conn_mut(client_ch).streams().send_streams(), 1);

    let mut recv = pair.server_recv(server_ch, s);
    let mut chunks = recv.read(false).unwrap();
    match chunks.next(usize::MAX) {
        Err(ReadError::Blocked) => {}
        other => panic!("assertion failed: `{other:?}` does not match `Err(ReadError::Blocked)`"),
    }
    let _transmit = chunks.finalize();

    match pair.server_send(server_ch, s).write(b"foo") {
        Err(WriteError::Stopped(ERROR)) => {}
        other => {
            panic!("assertion failed: `{other:?}` does not match `Err(WriteError::Stopped(ERROR))`")
        }
    }
    match pair.server_conn_mut(server_ch).poll() {
        Some(Event::Stream(StreamEvent::Stopped {
            id: _,
            error_code: ERROR,
        })) => {}
        other => panic!(
            "assertion failed: `{other:?}` does not match `Some(Event::Stream(StreamEvent::Stopped {{ id: _, error_code: ERROR }}))`"
        ),
    }
    match pair.server_conn_mut(server_ch).poll() {
        None => {}
        other => panic!("assertion failed: `{other:?}` does not match `None`"),
    }
}

#[test]
fn implicit_open() {
    let _guard = subscribe();
    let mut pair = Pair::default();
    let (client_ch, server_ch) = pair.connect();
    let s1 = pair.client_streams(client_ch).open(Dir::Uni).unwrap();
    let s2 = pair.client_streams(client_ch).open(Dir::Uni).unwrap();
    pair.client_send(client_ch, s2).write(b"hello").unwrap();
    pair.drive();
    match pair.server_conn_mut(server_ch).poll() {
        Some(Event::Stream(StreamEvent::Opened { dir: Dir::Uni })) => {}
        other => panic!(
            "assertion failed: `{other:?}` does not match `Some(Event::Stream(StreamEvent::Opened {{ dir: Dir::Uni }}))`"
        ),
    }
    assert_eq!(pair.server_streams(server_ch).accept(Dir::Uni), Some(s1));
    assert_eq!(pair.server_streams(server_ch).accept(Dir::Uni), Some(s2));
    assert_eq!(pair.server_streams(server_ch).accept(Dir::Uni), None);
}

#[test]
fn zero_length_cid() {
    let _guard = subscribe();
    let cid_generator_factory: fn() -> Box<dyn ConnectionIdGenerator> =
        || Box::new(RandomConnectionIdGenerator::new(0).expect("zero is a length"));
    let mut pair = Pair::new(
        Arc::new(EndpointConfig {
            connection_id_generator_factory: Arc::new(cid_generator_factory),
            ..EndpointConfig::try_with_rand_key().unwrap()
        }),
        server_config(),
    );
    let (client_ch, server_ch) = pair.connect();
    // Ensure we can reconnect after a previous connection is cleaned up
    info!("closing");
    pair.client.connections.get_mut(&client_ch).unwrap().close(
        pair.time,
        VarInt::from_u32(42),
        Bytes::new(),
    );
    pair.drive();
    pair.server.connections.get_mut(&server_ch).unwrap().close(
        pair.time,
        VarInt::from_u32(42),
        Bytes::new(),
    );
    pair.connect();
}

#[test]
fn keep_alive() {
    let _guard = subscribe();
    const IDLE_TIMEOUT: u64 = 10;
    let server = ServerConfig {
        transport: Arc::new(TransportConfig {
            keep_alive_interval: Some(Duration::from_millis(IDLE_TIMEOUT / 2)),
            max_idle_timeout: Some(VarInt::from_u32(IDLE_TIMEOUT as u32)),
            ..TransportConfig::default()
        }),
        ..server_config()
    };
    let mut pair = Pair::new(
        Arc::new(EndpointConfig::try_with_rand_key().unwrap()),
        server,
    );
    let (client_ch, server_ch) = pair.connect();
    // Run a good while longer than the idle timeout
    let end = pair.time + Duration::from_millis(20 * IDLE_TIMEOUT);
    while pair.time < end {
        if !pair.step()
            && let Some(time) = min_opt(pair.client.next_wakeup(), pair.server.next_wakeup())
        {
            pair.time = time;
        }
        assert!(!pair.client_conn_mut(client_ch).is_closed());
        assert!(!pair.server_conn_mut(server_ch).is_closed());
    }
}

#[test]
fn cid_rotation() {
    let _guard = subscribe();
    const CID_TIMEOUT: Duration = Duration::from_secs(2);

    let cid_generator_factory: fn() -> Box<dyn ConnectionIdGenerator> = || {
        Box::new(
            RandomConnectionIdGenerator::new(8)
                .expect("eight bytes is a length")
                .with_lifetime(CID_TIMEOUT),
        )
    };

    // Only test cid rotation on server side to have a clear output trace
    let server = Endpoint::new(
        Arc::new(EndpointConfig {
            connection_id_generator_factory: Arc::new(cid_generator_factory),
            ..EndpointConfig::try_with_rand_key().unwrap()
        }),
        Some(Arc::new(server_config())),
        true,
        None,
    );
    let client = Endpoint::new(
        Arc::new(EndpointConfig::try_with_rand_key().unwrap()),
        None,
        true,
        None,
    );

    let mut pair = Pair::new_from_endpoint(client, server);
    let (_, server_ch) = pair.connect();

    let mut round: u64 = 1;
    let mut stop = pair.time;
    let end = pair.time + 5 * CID_TIMEOUT;

    let mut previous = pair.server_conn_mut(server_ch).active_local_cid_seq();
    let active_cid_num = previous.1 - previous.0 + 1;
    assert!(active_cid_num <= crate::proto::LOC_CID_COUNT);

    while pair.time < end {
        stop += CID_TIMEOUT;
        // Run a while until PushNewCID timer fires, including one due as the window ends
        while pair.time <= stop {
            if !pair.step()
                && let Some(time) = min_opt(pair.client.next_wakeup(), pair.server.next_wakeup())
            {
                pair.time = time;
            }
        }
        info!(
            "Checking active cid sequence range before {:?} seconds",
            round * CID_TIMEOUT.as_secs()
        );
        let current = pair.server_conn_mut(server_ch).active_local_cid_seq();
        assert!(
            current.0 > previous.1,
            "expired connection IDs must be retired"
        );
        assert_eq!(current.1 - current.0 + 1, active_cid_num);
        previous = current;
        round += 1;
        pair.drive_server();
    }
}

#[test]
fn cid_retirement() {
    let _guard = subscribe();
    let mut pair = Pair::default();
    let (client_ch, server_ch) = pair.connect();

    let now = pair.time;
    // Server retires current active remote CIDs
    pair.server_conn_mut(server_ch).rotate_local_cid(1, now);
    pair.drive();
    // Any unexpected behavior may trigger TransportError::CONNECTION_ID_LIMIT_ERROR
    assert!(!pair.client_conn_mut(client_ch).is_closed());
    assert!(!pair.server_conn_mut(server_ch).is_closed());
    match pair.client_conn_mut(client_ch).active_rem_cid_seq() {
        1 => {}
        other => panic!("assertion failed: `{other:?}` does not match `1`"),
    }

    // Retire what was actually issued under the negotiated limit, rather
    // than assuming the peer advertised the storage capacity.
    let (_, highest) = pair.server_conn_mut(server_ch).active_local_cid_seq();
    let next_retire_prior_to = highest + 1;
    pair.client_conn_mut(client_ch).ping();
    let now = pair.time;
    // Server retires all valid remote CIDs
    pair.server_conn_mut(server_ch)
        .rotate_local_cid(next_retire_prior_to, now);
    pair.drive();
    assert!(!pair.client_conn_mut(client_ch).is_closed());
    assert!(!pair.server_conn_mut(server_ch).is_closed());

    assert_eq!(
        pair.client_conn_mut(client_ch).active_rem_cid_seq(),
        next_retire_prior_to,
    );
}

#[test]
fn finish_stream_flow_control_reordered() {
    let _guard = subscribe();
    let mut pair = Pair::default();
    let (client_ch, server_ch) = pair.connect();

    let s = pair.client_streams(client_ch).open(Dir::Uni).unwrap();

    const MSG: &[u8] = b"hello";
    pair.client_send(client_ch, s).write(MSG).unwrap();
    pair.drive_client(); // Send stream data
    pair.server.drive(pair.time, pair.client.addr); // Receive

    // Issue flow control credit
    let mut recv = pair.server_recv(server_ch, s);
    let mut chunks = recv.read(false).unwrap();
    match chunks.next(usize::MAX) {
        Ok(Some(chunk)) if chunk.offset == 0 && chunk.bytes == MSG => {}
        other => panic!(
            "assertion failed: `{other:?}` does not match `Ok(Some(chunk)) if chunk.offset == 0 && chunk.bytes == MSG`"
        ),
    }
    let _transmit = chunks.finalize();

    pair.server.drive(pair.time, pair.client.addr);
    pair.server.delay_outbound(); // Delay it

    pair.client_send(client_ch, s).finish().unwrap();
    pair.drive_client(); // Send FIN
    pair.server.drive(pair.time, pair.client.addr); // Acknowledge
    pair.server.finish_delay(); // Add flow control packets after
    pair.drive();

    match pair.client_conn_mut(client_ch).poll() {
        Some(Event::Stream(StreamEvent::Finished { id })) if id == s => {}
        other => panic!(
            "assertion failed: `{other:?}` does not match `Some(Event::Stream(StreamEvent::Finished {{ id }})) if id == s`"
        ),
    }
    match pair.client_conn_mut(client_ch).poll() {
        None => {}
        other => panic!("assertion failed: `{other:?}` does not match `None`"),
    }
    match pair.server_conn_mut(server_ch).poll() {
        Some(Event::Stream(StreamEvent::Opened { dir: Dir::Uni })) => {}
        other => panic!(
            "assertion failed: `{other:?}` does not match `Some(Event::Stream(StreamEvent::Opened {{ dir: Dir::Uni }}))`"
        ),
    }
    match pair.server_streams(server_ch).accept(Dir::Uni) {
        Some(stream) if stream == s => {}
        other => {
            panic!("assertion failed: `{other:?}` does not match `Some(stream) if stream == s`")
        }
    }

    let mut recv = pair.server_recv(server_ch, s);
    let mut chunks = recv.read(false).unwrap();
    match chunks.next(usize::MAX) {
        Ok(None) => {}
        other => panic!("assertion failed: `{other:?}` does not match `Ok(None)`"),
    }
    let _transmit = chunks.finalize();
}

#[test]
fn handshake_1rtt_handling() {
    let _guard = subscribe();
    let mut pair = Pair::default();
    let client_ch = pair.begin_connect(client_config());
    pair.drive_client();
    pair.drive_server();
    let server_ch = pair.server.assert_accept();
    // Server now has 1-RTT keys, but remains in Handshake state until the TLS CFIN has
    // authenticated the client. Delay the final client handshake flight so that doesn't happen yet.
    pair.client.drive(pair.time, pair.server.addr);
    pair.client.delay_outbound();

    // Send some 1-RTT data which will be received first.
    let s = pair.client_streams(client_ch).open(Dir::Uni).unwrap();
    const MSG: &[u8] = b"hello";
    pair.client_send(client_ch, s).write(MSG).unwrap();
    pair.client_send(client_ch, s).finish().unwrap();
    pair.client.drive(pair.time, pair.server.addr);

    // Add the handshake flight back on.
    pair.client.finish_delay();

    pair.drive();

    // The server holds the early 1-RTT data until the handshake completes, so none is resent.
    assert_eq!(pair.client_conn_mut(client_ch).stats().path.lost_packets, 0);
    let mut recv = pair.server_recv(server_ch, s);
    let mut chunks = recv.read(false).unwrap();
    match chunks.next(usize::MAX) {
        Ok(Some(chunk)) if chunk.offset == 0 && chunk.bytes == MSG => {}
        other => panic!(
            "assertion failed: `{other:?}` does not match `Ok(Some(chunk)) if chunk.offset == 0 && chunk.bytes == MSG`"
        ),
    }
    let _transmit = chunks.finalize();
}

#[test]
fn stop_before_finish() {
    let _guard = subscribe();
    let mut pair = Pair::default();
    let (client_ch, server_ch) = pair.connect();

    let s = pair.client_streams(client_ch).open(Dir::Uni).unwrap();
    const MSG: &[u8] = b"hello";
    pair.client_send(client_ch, s).write(MSG).unwrap();
    pair.drive();

    info!("stopping stream");
    const ERROR: VarInt = VarInt::from_u32(42);
    pair.server_recv(server_ch, s).stop(ERROR).unwrap();
    pair.drive();

    match pair.client_send(client_ch, s).finish() {
        Err(FinishError::Stopped(ERROR)) => {}
        other => panic!(
            "assertion failed: `{other:?}` does not match `Err(FinishError::Stopped(ERROR))`"
        ),
    }
}

#[test]
fn stop_during_finish() {
    let _guard = subscribe();
    let mut pair = Pair::default();
    let (client_ch, server_ch) = pair.connect();

    let s = pair.client_streams(client_ch).open(Dir::Uni).unwrap();
    const MSG: &[u8] = b"hello";
    pair.client_send(client_ch, s).write(MSG).unwrap();
    pair.drive();

    match pair.server_streams(server_ch).accept(Dir::Uni) {
        Some(stream) if stream == s => {}
        other => {
            panic!("assertion failed: `{other:?}` does not match `Some(stream) if stream == s`")
        }
    }
    info!("stopping and finishing stream");
    const ERROR: VarInt = VarInt::from_u32(42);
    pair.server_recv(server_ch, s).stop(ERROR).unwrap();
    pair.drive_server();
    pair.client_send(client_ch, s).finish().unwrap();
    pair.drive_client();
    match pair.client_conn_mut(client_ch).poll() {
        Some(Event::Stream(StreamEvent::Stopped {
            id,
            error_code: ERROR,
        })) if id == s => {}
        other => panic!(
            "assertion failed: `{other:?}` does not match `Some(Event::Stream(StreamEvent::Stopped {{ id, error_code: ERROR }})) if id == s`"
        ),
    }
}

// Ensure we can recover from loss of tail packets when the congestion window is full
#[test]
fn congested_tail_loss() {
    let _guard = subscribe();
    let mut pair = Pair::default();
    let (client_ch, _) = pair.connect();

    const TARGET: u64 = 2048;
    assert!(pair.client_conn_mut(client_ch).congestion_window() > TARGET);
    let s = pair.client_streams(client_ch).open(Dir::Uni).unwrap();
    // Send data without receiving ACKs until the congestion state falls below target
    while pair.client_conn_mut(client_ch).congestion_window() > TARGET {
        let n = pair.client_send(client_ch, s).write(&[42; 1024]).unwrap();
        assert_eq!(n, 1024);
        pair.drive_client();
    }
    assert!(!pair.server.inbound.is_empty());
    pair.server.inbound.clear();
    // Ensure that the congestion state recovers after retransmits occur and are ACKed
    info!("recovering");
    pair.drive();
    assert!(pair.client_conn_mut(client_ch).congestion_window() > TARGET);
    pair.client_send(client_ch, s).write(&[42; 1024]).unwrap();
}

// Send a tail-loss probe when GSO segment_size is less than INITIAL_MTU
#[test]
fn tail_loss_small_segment_size() {
    let _guard = subscribe();
    let mut pair = Pair::default();
    let (client_ch, server_ch) = pair.connect();

    // No datagrams frames received in the handshake.
    let server_stats = pair.server_conn_mut(server_ch).stats();
    assert_eq!(server_stats.frame_rx.datagram, 0);

    const DGRAM_LEN: usize = 1000; // Below INITIAL_MTU after packet overhead.
    const DGRAM_NUM: u64 = 5; // Enough to build a GSO batch.

    info!("Sending an ack-eliciting datagram");
    pair.client_conn_mut(client_ch).ping();
    pair.drive_client();

    // Drop these packets on the server side.
    assert!(!pair.server.inbound.is_empty());
    pair.server.inbound.clear();

    // Doing one step makes the client advance time to the PTO fire time.
    info!("stepping forward to PTO");
    pair.step();

    // Still no datagrams frames received by the server.
    let server_stats = pair.server_conn_mut(server_ch).stats();
    assert_eq!(server_stats.frame_rx.datagram, 0);

    // Now we can send another batch of datagrams, so the PTO can send them instead of
    // sending a ping.  These are small enough that the segment_size is less than the
    // INITIAL_MTU.
    info!("Sending datagram batch");
    for _ in 0..DGRAM_NUM {
        pair.client_datagrams(client_ch)
            .send(vec![0; DGRAM_LEN].into(), false)
            .unwrap();
    }

    // If this succeeds the datagrams are received by the server and the client did not
    // crash.
    pair.drive();

    // Finally the server should have received some datagrams.
    let server_stats = pair.server_conn_mut(server_ch).stats();
    assert_eq!(server_stats.frame_rx.datagram, DGRAM_NUM);
}

// Respect max_datagrams when TLP happens
#[test]
fn tail_loss_respect_max_datagrams() {
    let _guard = subscribe();
    let client_config = {
        let mut c_config = client_config();
        let mut t_config = TransportConfig::default();
        //Disabling GSO, so only a single segment should be sent per iops
        t_config.set_enable_segmentation_offload(false);
        c_config.set_transport_config(t_config.into());
        c_config
    };
    let mut pair = Pair::default();
    let (client_ch, _) = pair.connect_with(client_config);

    const DGRAM_LEN: usize = 1000; // High enough so GSO batch could be built
    const DGRAM_NUM: u64 = 5; // Enough to build a GSO batch.

    info!("Sending an ack-eliciting datagram");
    pair.client_conn_mut(client_ch).ping();
    pair.drive_client();

    // Drop these packets on the server side.
    assert!(!pair.server.inbound.is_empty());
    pair.server.inbound.clear();

    // Doing one step makes the client advance time to the PTO fire time.
    info!("stepping forward to PTO");
    pair.step();

    // start sending datagram batches but the first should be a TLP
    info!("Sending datagram batch");
    for _ in 0..DGRAM_NUM {
        pair.client_datagrams(client_ch)
            .send(vec![0; DGRAM_LEN].into(), false)
            .unwrap();
    }

    pair.drive();

    // Finally checking the number of sent udp datagrams match the number of iops
    let client_stats = pair.client_conn_mut(client_ch).stats();
    assert_eq!(client_stats.udp_tx.ios, client_stats.udp_tx.datagrams);
}

#[test]
fn datagram_send_recv() {
    let _guard = subscribe();
    let mut pair = Pair::default();
    let (client_ch, server_ch) = pair.connect();
    match pair.server_conn_mut(server_ch).poll() {
        None => {}
        other => panic!("assertion failed: `{other:?}` does not match `None`"),
    }
    match pair.client_datagrams(client_ch).max_size() {
        Some(x) if x > 0 => {}
        other => panic!("assertion failed: `{other:?}` does not match `Some(x) if x > 0`"),
    }

    const DATA: &[u8] = b"whee";
    pair.client_datagrams(client_ch)
        .send(DATA.into(), true)
        .unwrap();
    pair.drive();
    match pair.server_conn_mut(server_ch).poll() {
        Some(Event::DatagramReceived) => {}
        other => {
            panic!("assertion failed: `{other:?}` does not match `Some(Event::DatagramReceived)`")
        }
    }
    assert_eq!(pair.server_datagrams(server_ch).recv().unwrap(), DATA);
    match pair.server_datagrams(server_ch).recv() {
        None => {}
        other => panic!("assertion failed: `{other:?}` does not match `None`"),
    }
}

#[test]
fn datagram_recv_buffer_overflow() {
    let _guard = subscribe();
    const PAYLOAD_WINDOW: usize = 100;
    const METADATA_WINDOW: usize = 2 * size_of::<Datagram>();
    const WINDOW: usize = PAYLOAD_WINDOW + METADATA_WINDOW;
    let server = ServerConfig {
        transport: Arc::new(TransportConfig {
            // Account for exactly two datagrams of metadata space
            datagram_receive_buffer_size: Some(WINDOW),
            ..TransportConfig::default()
        }),
        ..server_config()
    };
    let mut pair = Pair::new(
        Arc::new(EndpointConfig::try_with_rand_key().unwrap()),
        server,
    );
    let (client_ch, server_ch) = pair.connect();
    match pair.server_conn_mut(server_ch).poll() {
        None => {}
        other => panic!("assertion failed: `{other:?}` does not match `None`"),
    }
    assert_eq!(
        pair.client_conn_mut(client_ch).datagrams().max_size(),
        Some(WINDOW - Datagram::SIZE_BOUND)
    );

    const DATA1: &[u8] = &[0xAB; (PAYLOAD_WINDOW / 3) + 1];
    const DATA2: &[u8] = &[0xBC; (PAYLOAD_WINDOW / 3) + 1];
    const DATA3: &[u8] = &[0xCD; (PAYLOAD_WINDOW / 3) + 1];
    pair.client_datagrams(client_ch)
        .send(DATA1.into(), true)
        .unwrap();
    pair.client_datagrams(client_ch)
        .send(DATA2.into(), true)
        .unwrap();
    pair.client_datagrams(client_ch)
        .send(DATA3.into(), true)
        .unwrap();
    pair.drive();
    match pair.server_conn_mut(server_ch).poll() {
        Some(Event::DatagramReceived) => {}
        other => {
            panic!("assertion failed: `{other:?}` does not match `Some(Event::DatagramReceived)`")
        }
    }
    assert_eq!(pair.server_datagrams(server_ch).recv().unwrap(), DATA2);
    assert_eq!(pair.server_datagrams(server_ch).recv().unwrap(), DATA3);
    match pair.server_datagrams(server_ch).recv() {
        None => {}
        other => panic!("assertion failed: `{other:?}` does not match `None`"),
    }

    pair.client_datagrams(client_ch)
        .send(DATA1.into(), true)
        .unwrap();
    pair.drive();
    assert_eq!(pair.server_datagrams(server_ch).recv().unwrap(), DATA1);
    match pair.server_datagrams(server_ch).recv() {
        None => {}
        other => panic!("assertion failed: `{other:?}` does not match `None`"),
    }
}

#[test]
fn datagram_send_buffer_overflow() {
    let _guard = subscribe();
    const PAYLOAD_WINDOW: usize = 100;
    const METADATA_WINDOW: usize = 2 * Datagrams::ENTRY_OVERHEAD;
    const WINDOW: usize = PAYLOAD_WINDOW + METADATA_WINDOW;
    let client_config = {
        let mut config = client_config();
        let mut transport = TransportConfig::default();
        transport.set_datagram_send_buffer_size(WINDOW);
        config.set_transport_config(transport.into());
        config
    };
    let mut pair = Pair::default();
    let (client_ch, server_ch) = pair.connect_with(client_config);
    match pair.server_conn_mut(server_ch).poll() {
        None => {}
        other => panic!("assertion failed: `{other:?}` does not match `None`"),
    }

    // Keep the send buffer full so most sends evict the oldest queued datagram;
    // `payload_bytes` bookkeeping must survive sustained eviction
    const LEN: usize = (PAYLOAD_WINDOW / 3) + 1;
    for i in 0..10u8 {
        pair.client_datagrams(client_ch)
            .send(vec![i; LEN].into(), true)
            .unwrap();
    }
    pair.drive();

    match pair.server_conn_mut(server_ch).poll() {
        Some(Event::DatagramReceived) => {}
        other => {
            panic!("assertion failed: `{other:?}` does not match `Some(Event::DatagramReceived)`")
        }
    }
    // The budget holds two entries including their metadata.
    for i in 8..10u8 {
        assert_eq!(
            pair.server_datagrams(server_ch).recv().unwrap(),
            vec![i; LEN]
        );
    }
    match pair.server_datagrams(server_ch).recv() {
        None => {}
        other => panic!("assertion failed: `{other:?}` does not match `None`"),
    }
}

#[test]
fn datagram_unsupported() {
    let _guard = subscribe();
    let server = ServerConfig {
        transport: Arc::new(TransportConfig {
            datagram_receive_buffer_size: None,
            ..TransportConfig::default()
        }),
        ..server_config()
    };
    let mut pair = Pair::new(
        Arc::new(EndpointConfig::try_with_rand_key().unwrap()),
        server,
    );
    let (client_ch, server_ch) = pair.connect();
    match pair.server_conn_mut(server_ch).poll() {
        None => {}
        other => panic!("assertion failed: `{other:?}` does not match `None`"),
    }
    match pair.client_datagrams(client_ch).max_size() {
        None => {}
        other => panic!("assertion failed: `{other:?}` does not match `None`"),
    }

    match pair.client_datagrams(client_ch).send(Bytes::new(), true) {
        Err(SendDatagramError::UnsupportedByPeer) => {}
        Err(e) => panic!("unexpected error: {e}"),
        Ok(_) => panic!("unexpected success"),
    }
}

#[test]
fn large_initial() {
    let _guard = subscribe();
    let server_config =
        ServerConfig::with_crypto(Arc::new(server_crypto_with_alpn(vec![vec![0, 0, 0, 42]])));

    let mut pair = Pair::new(
        Arc::new(EndpointConfig::try_with_rand_key().unwrap()),
        server_config,
    );
    let client_crypto =
        client_crypto_with_alpn((0..1000u32).map(|x| x.to_be_bytes().to_vec()).collect());
    let cfg = ClientConfig::new(Arc::new(client_crypto));
    let client_ch = pair.begin_connect(cfg);
    pair.drive();
    let server_ch = pair.server.assert_accept();
    match pair.client_conn_mut(client_ch).poll() {
        Some(Event::HandshakeDataReady) => {}
        other => {
            panic!("assertion failed: `{other:?}` does not match `Some(Event::HandshakeDataReady)`")
        }
    }
    match pair.client_conn_mut(client_ch).poll() {
        Some(Event::Connected) => {}
        other => panic!("assertion failed: `{other:?}` does not match `Some(Event::Connected)`"),
    }
    match pair.server_conn_mut(server_ch).poll() {
        Some(Event::HandshakeDataReady) => {}
        other => {
            panic!("assertion failed: `{other:?}` does not match `Some(Event::HandshakeDataReady)`")
        }
    }
    match pair.server_conn_mut(server_ch).poll() {
        Some(Event::HandshakeConfirmed) => {}
        other => {
            panic!("assertion failed: `{other:?}` does not match `Some(Event::HandshakeConfirmed)`")
        }
    }
    match pair.server_conn_mut(server_ch).poll() {
        Some(Event::Connected) => {}
        other => panic!("assertion failed: `{other:?}` does not match `Some(Event::Connected)`"),
    }
}

#[test]
/// Ensure that we don't yield a finish event before the actual FIN is acked so the peer isn't left
/// hanging
fn finish_acked() {
    let _guard = subscribe();
    let mut pair = Pair::default();
    let (client_ch, server_ch) = pair.connect();

    let s = pair.client_streams(client_ch).open(Dir::Uni).unwrap();

    const MSG: &[u8] = b"hello";
    pair.client_send(client_ch, s).write(MSG).unwrap();
    info!("client sends data to server");
    pair.drive_client(); // send data to server
    info!("server acknowledges data");
    pair.drive_server(); // process data and send data ack

    // Receive data
    match pair.server_conn_mut(server_ch).poll() {
        Some(Event::Stream(StreamEvent::Opened { dir: Dir::Uni })) => {}
        other => panic!(
            "assertion failed: `{other:?}` does not match `Some(Event::Stream(StreamEvent::Opened {{ dir: Dir::Uni }}))`"
        ),
    }
    match pair.server_conn_mut(server_ch).poll() {
        None => {}
        other => panic!("assertion failed: `{other:?}` does not match `None`"),
    }

    match pair.server_streams(server_ch).accept(Dir::Uni) {
        Some(stream) if stream == s => {}
        other => {
            panic!("assertion failed: `{other:?}` does not match `Some(stream) if stream == s`")
        }
    }

    let mut recv = pair.server_recv(server_ch, s);
    let mut chunks = recv.read(false).unwrap();
    match chunks.next(usize::MAX) {
        Ok(Some(chunk)) if chunk.offset == 0 && chunk.bytes == MSG => {}
        other => panic!(
            "assertion failed: `{other:?}` does not match `Ok(Some(chunk)) if chunk.offset == 0 && chunk.bytes == MSG`"
        ),
    }
    match chunks.next(usize::MAX) {
        Err(ReadError::Blocked) => {}
        other => panic!("assertion failed: `{other:?}` does not match `Err(ReadError::Blocked)`"),
    }
    let _transmit = chunks.finalize();

    // Finish before receiving data ack
    pair.client_send(client_ch, s).finish().unwrap();
    // Send FIN, receive data ack
    info!("client receives ACK, sends FIN");
    pair.drive_client();
    // Check for premature finish from data ack
    match pair.client_conn_mut(client_ch).poll() {
        None => {}
        other => panic!("assertion failed: `{other:?}` does not match `None`"),
    }
    // Process FIN ack
    info!("server ACKs FIN");
    pair.drive();
    match pair.client_conn_mut(client_ch).poll() {
        Some(Event::Stream(StreamEvent::Finished { id })) if id == s => {}
        other => panic!(
            "assertion failed: `{other:?}` does not match `Some(Event::Stream(StreamEvent::Finished {{ id }})) if id == s`"
        ),
    }

    let mut recv = pair.server_recv(server_ch, s);
    let mut chunks = recv.read(false).unwrap();
    match chunks.next(usize::MAX) {
        Ok(None) => {}
        other => panic!("assertion failed: `{other:?}` does not match `Ok(None)`"),
    }
    let _transmit = chunks.finalize();
}

#[test]
/// Ensure that we don't yield a finish event while there's still unacknowledged data
fn finish_retransmit() {
    let _guard = subscribe();
    let mut pair = Pair::default();
    let (client_ch, server_ch) = pair.connect();

    let s = pair.client_streams(client_ch).open(Dir::Uni).unwrap();

    const MSG: &[u8] = b"hello";
    pair.client_send(client_ch, s).write(MSG).unwrap();
    pair.drive_client(); // send data to server
    pair.server.inbound.clear(); // Lose it

    // Send FIN
    pair.client_send(client_ch, s).finish().unwrap();
    pair.drive_client();
    // Process FIN
    pair.drive_server();
    // Receive FIN ack, but no data ack
    pair.drive_client();
    // Check for premature finish from FIN ack
    match pair.client_conn_mut(client_ch).poll() {
        None => {}
        other => panic!("assertion failed: `{other:?}` does not match `None`"),
    }
    // Recover
    pair.drive();
    match pair.client_conn_mut(client_ch).poll() {
        Some(Event::Stream(StreamEvent::Finished { id })) if id == s => {}
        other => panic!(
            "assertion failed: `{other:?}` does not match `Some(Event::Stream(StreamEvent::Finished {{ id }})) if id == s`"
        ),
    }

    match pair.server_conn_mut(server_ch).poll() {
        Some(Event::Stream(StreamEvent::Opened { dir: Dir::Uni })) => {}
        other => panic!(
            "assertion failed: `{other:?}` does not match `Some(Event::Stream(StreamEvent::Opened {{ dir: Dir::Uni }}))`"
        ),
    }

    match pair.server_streams(server_ch).accept(Dir::Uni) {
        Some(stream) if stream == s => {}
        other => {
            panic!("assertion failed: `{other:?}` does not match `Some(stream) if stream == s`")
        }
    }

    let mut recv = pair.server_recv(server_ch, s);
    let mut chunks = recv.read(false).unwrap();
    match chunks.next(usize::MAX) {
        Ok(Some(chunk)) if chunk.offset == 0 && chunk.bytes == MSG => {}
        other => panic!(
            "assertion failed: `{other:?}` does not match `Ok(Some(chunk)) if chunk.offset == 0 && chunk.bytes == MSG`"
        ),
    }
    match chunks.next(usize::MAX) {
        Ok(None) => {}
        other => panic!("assertion failed: `{other:?}` does not match `Ok(None)`"),
    }
    let _transmit = chunks.finalize();
}

/// Ensures that exchanging data on a client-initiated bidirectional stream works past the initial
/// stream window.
#[test]
fn repeated_request_response() {
    let _guard = subscribe();
    let server = ServerConfig {
        transport: Arc::new(TransportConfig {
            max_concurrent_bidi_streams: 1u32.into(),
            ..TransportConfig::default()
        }),
        ..server_config()
    };
    let mut pair = Pair::new(
        Arc::new(EndpointConfig::try_with_rand_key().unwrap()),
        server,
    );
    let (client_ch, server_ch) = pair.connect();
    const REQUEST: &[u8] = b"hello";
    const RESPONSE: &[u8] = b"world";
    for _ in 0..3 {
        let s = pair.client_streams(client_ch).open(Dir::Bi).unwrap();

        pair.client_send(client_ch, s).write(REQUEST).unwrap();
        pair.client_send(client_ch, s).finish().unwrap();

        pair.drive();

        assert_eq!(pair.server_streams(server_ch).accept(Dir::Bi), Some(s));
        let mut recv = pair.server_recv(server_ch, s);
        let mut chunks = recv.read(false).unwrap();
        match chunks.next(usize::MAX) {
            Ok(Some(chunk)) if chunk.offset == 0 && chunk.bytes == REQUEST => {}
            other => panic!(
                "assertion failed: `{other:?}` does not match `Ok(Some(chunk)) if chunk.offset == 0 && chunk.bytes == REQUEST`"
            ),
        }

        match chunks.next(usize::MAX) {
            Ok(None) => {}
            other => panic!("assertion failed: `{other:?}` does not match `Ok(None)`"),
        }
        let _transmit = chunks.finalize();
        pair.server_send(server_ch, s).write(RESPONSE).unwrap();
        pair.server_send(server_ch, s).finish().unwrap();

        pair.drive();

        let mut recv = pair.client_recv(client_ch, s);
        let mut chunks = recv.read(false).unwrap();
        match chunks.next(usize::MAX) {
            Ok(Some(chunk)) if chunk.offset == 0 && chunk.bytes == RESPONSE => {}
            other => panic!(
                "assertion failed: `{other:?}` does not match `Ok(Some(chunk)) if chunk.offset == 0 && chunk.bytes == RESPONSE`"
            ),
        }
        match chunks.next(usize::MAX) {
            Ok(None) => {}
            other => panic!("assertion failed: `{other:?}` does not match `Ok(None)`"),
        }
        let _transmit = chunks.finalize();
    }
}

/// Ensures that the client sends an anti-deadlock probe after an incomplete server's first flight
#[test]
fn handshake_anti_deadlock_probe() {
    let _guard = subscribe();

    let (cert, key) = big_cert_and_key();
    let server = server_config_with_cert(cert.clone(), key);
    let client = client_config_with_certs(vec![cert]);
    let mut pair = Pair::new(
        Arc::new(EndpointConfig::try_with_rand_key().unwrap()),
        server,
    );

    let client_ch = pair.begin_connect(client);
    // Client sends initial
    pair.drive_client();
    // Server sends first flight, gets blocked on anti-amplification
    pair.drive_server();
    // Client acks...
    pair.drive_client();
    // ...but it's lost, so the server doesn't get anti-amplification credit from it
    pair.server.inbound.clear();
    // Client sends an anti-deadlock probe, and the handshake completes as usual.
    pair.drive();
    match pair.client_conn_mut(client_ch).poll() {
        Some(Event::HandshakeDataReady) => {}
        other => {
            panic!("assertion failed: `{other:?}` does not match `Some(Event::HandshakeDataReady)`")
        }
    }
    match pair.client_conn_mut(client_ch).poll() {
        Some(Event::Connected) => {}
        other => panic!("assertion failed: `{other:?}` does not match `Some(Event::Connected)`"),
    }
}

/// Ensures that the server can respond with 3 initial packets during the handshake
/// before the anti-amplification limit kicks in when MTUs are similar.
#[test]
fn server_can_send_3_inital_packets() {
    let _guard = subscribe();
    let mut transport = TransportConfig::default();
    // Assume a low-latency connection so pacing doesn't interfere with the test
    transport.set_initial_rtt(Duration::from_millis(10));
    let transport = Arc::new(transport);

    let (cert, key) = big_cert_and_key();
    let mut server = server_config_with_cert(cert.clone(), key);
    server.set_transport_config(transport);
    let client = client_config_with_certs(vec![cert]);
    let mut pair = Pair::new(
        Arc::new(EndpointConfig::try_with_rand_key().unwrap()),
        server,
    );

    let client_ch = pair.begin_connect(client);
    // Client sends initial
    pair.drive_client();
    // Server sends first flight, gets blocked on anti-amplification
    pair.drive_server();
    // Server should have queued 3 packets at this time
    assert_eq!(pair.client.inbound.len(), 3);

    pair.drive();
    match pair.client_conn_mut(client_ch).poll() {
        Some(Event::HandshakeDataReady) => {}
        other => {
            panic!("assertion failed: `{other:?}` does not match `Some(Event::HandshakeDataReady)`")
        }
    }
    match pair.client_conn_mut(client_ch).poll() {
        Some(Event::Connected) => {}
        other => panic!("assertion failed: `{other:?}` does not match `Some(Event::Connected)`"),
    }
}

/// Generate a big fat certificate that can't fit inside the initial anti-amplification limit
fn big_cert_and_key() -> (CertificateDer<'static>, PrivateKeyDer<'static>) {
    let request = rama_tls::server::LeafCertRequest {
        identities: std::iter::once(rama_crypto::cert::CertificateIdentity::Dns(
            "localhost".parse().unwrap(),
        ))
        .chain((0..1000).map(|i| {
            rama_crypto::cert::CertificateIdentity::Dns(format!("foo-{i}").parse().unwrap())
        }))
        .collect(),
        ..Default::default()
    };
    let auth = rama_tls::server::ServerAuthData::new_self_signed_leaf(request).unwrap();
    (auth.cert_chain[0].clone(), auth.private_key)
}

#[test]
fn malformed_token_len() {
    let _guard = subscribe();
    let client_addr = SocketAddr::from(([0, 0, 0, 0, 0, 0, 0, 2], 7890));
    let mut server = Endpoint::new(
        Arc::new(EndpointConfig::try_with_rand_key().unwrap()),
        Some(Arc::new(server_config())),
        true,
        None,
    );
    let mut buf = Vec::with_capacity(server.config().get_max_udp_payload_size() as usize);
    server.handle(
        Instant::now(),
        client_addr,
        None,
        None,
        [
            0x89, 0x00, 0x00, 0x00, 0x01, 0x01, 0x00, 0x00, 0x1b, 0x1b, 0x84, 0x1b, 0x00, 0x00,
            0x00, 0x00, 0x3f, 0x00,
        ][..]
            .into(),
        &mut buf,
    );
}

#[test]
fn loss_probe_requests_immediate_ack() {
    let _guard = subscribe();
    let mut pair = Pair::default();
    let (client_ch, _) = pair.connect();
    pair.drive();

    let stats_after_connect = pair.client_conn_mut(client_ch).stats();

    // Lose a ping
    let default_mtu = mem::replace(&mut pair.mtu, 0);
    pair.client_conn_mut(client_ch).ping();
    pair.drive_client();
    pair.mtu = default_mtu;

    // Drive the connection further so a loss probe is sent
    pair.drive();

    // Assert that two IMMEDIATE_ACKs were sent (two loss probes)
    let stats_after_recovery = pair.client_conn_mut(client_ch).stats();
    assert_eq!(
        stats_after_recovery.frame_tx.immediate_ack - stats_after_connect.frame_tx.immediate_ack,
        2
    );
}

#[test]
/// This is mostly a sanity check to ensure our testing code is correctly dropping packets above the
/// pmtu
fn connect_too_low_mtu() {
    let _guard = subscribe();
    let mut pair = Pair::default();

    // The maximum payload size is lower than 1200, so no packages will get through!
    pair.mtu = 1000;

    pair.begin_connect(client_config());
    pair.drive();
    pair.server.assert_no_accept();
}

#[test]
fn connect_lost_mtu_probes_do_not_trigger_congestion_control() {
    let _guard = subscribe();
    let mut pair = Pair::default();
    pair.mtu = 1200;

    let (client_ch, server_ch) = pair.connect();
    pair.drive();

    let client_stats = pair.client_conn_mut(client_ch).stats();
    let server_stats = pair.server_conn_mut(server_ch).stats();

    // Sanity check (all MTU probes should have been lost)
    assert_eq!(client_stats.path.sent_plpmtud_probes, 9);
    assert_eq!(client_stats.path.lost_plpmtud_probes, 9);
    assert_eq!(server_stats.path.sent_plpmtud_probes, 9);
    assert_eq!(server_stats.path.lost_plpmtud_probes, 9);

    // No congestion events
    assert_eq!(client_stats.path.congestion_events, 0);
    assert_eq!(server_stats.path.congestion_events, 0);
}

#[test]
fn connect_detects_mtu() {
    let _guard = subscribe();
    let max_udp_payload_and_expected_mtu = &[(1200, 1200), (1400, 1389), (1500, 1452)];

    for &(pair_max_udp, expected_mtu) in max_udp_payload_and_expected_mtu {
        let mut pair = Pair::default();
        pair.mtu = pair_max_udp;
        let (client_ch, server_ch) = pair.connect();
        pair.drive();

        assert_eq!(pair.client_conn_mut(client_ch).path_mtu(), expected_mtu);
        assert_eq!(pair.server_conn_mut(server_ch).path_mtu(), expected_mtu);
    }
}

#[test]
fn migrate_detects_new_mtu_and_respects_original_peer_max_udp_payload_size() {
    let _guard = subscribe();

    let client_max_udp_payload_size: u16 = 1400;

    // Set up a client with a max payload size of 1400 (and use the defaults for the server)
    let server_endpoint_config = EndpointConfig::try_with_rand_key().unwrap();
    let server = Endpoint::new(
        Arc::new(server_endpoint_config),
        Some(Arc::new(server_config())),
        true,
        None,
    );
    let client_endpoint_config = EndpointConfig {
        max_udp_payload_size: VarInt::from(client_max_udp_payload_size),
        ..EndpointConfig::try_with_rand_key().unwrap()
    };
    let client = Endpoint::new(Arc::new(client_endpoint_config), None, true, None);
    let mut pair = Pair::new_from_endpoint(client, server);
    pair.mtu = 1300;

    // Connect
    let (client_ch, server_ch) = pair.connect();
    pair.drive();

    // Sanity check: MTUD ran to completion (the numbers differ because binary search stops when
    // changes are smaller than 20, otherwise both endpoints would converge at the same MTU of 1300)
    assert_eq!(pair.client_conn_mut(client_ch).path_mtu(), 1293);
    assert_eq!(pair.server_conn_mut(server_ch).path_mtu(), 1300);

    // Migrate client to a different port (and simulate a higher path MTU)
    pair.mtu = 1500;
    pair.client.addr = SocketAddr::new(
        Ipv4Addr::new(127, 0, 0, 1).into(),
        CLIENT_PORTS.lock().next().unwrap(),
    );
    pair.client_conn_mut(client_ch).ping();
    pair.drive();

    // Sanity check: the server saw that the client address was updated
    assert_eq!(
        pair.server_conn_mut(server_ch).remote_address(),
        pair.client.addr
    );

    // MTU detection has successfully run after migrating
    assert_eq!(
        pair.server_conn_mut(server_ch).path_mtu(),
        client_max_udp_payload_size
    );

    // Sanity check: the client keeps the old MTU, because migration is triggered by incoming
    // packets from a different address
    assert_eq!(pair.client_conn_mut(client_ch).path_mtu(), 1293);
}

#[test]
fn connect_runs_mtud_again_after_600_seconds() {
    let _guard = subscribe();
    let mut server_config = server_config();
    let mut client_config = client_config();

    // Note: we use an infinite idle timeout to ensure we can wait 600 seconds without the
    // connection closing
    Arc::get_mut(&mut server_config.transport)
        .unwrap()
        .maybe_set_max_idle_timeout(None);
    Arc::get_mut(&mut client_config.transport)
        .unwrap()
        .maybe_set_max_idle_timeout(None);

    let mut pair = Pair::new(
        Arc::new(EndpointConfig::try_with_rand_key().unwrap()),
        server_config,
    );
    pair.mtu = 1400;
    let (client_ch, server_ch) = pair.connect_with(client_config);
    pair.drive();

    // Sanity check: the mtu has been discovered
    let client_conn = pair.client_conn_mut(client_ch);
    assert_eq!(client_conn.path_mtu(), 1389);
    assert_eq!(client_conn.stats().path.sent_plpmtud_probes, 5);
    assert_eq!(client_conn.stats().path.lost_plpmtud_probes, 3);
    let server_conn = pair.server_conn_mut(server_ch);
    assert_eq!(server_conn.path_mtu(), 1389);
    assert_eq!(server_conn.stats().path.sent_plpmtud_probes, 5);
    assert_eq!(server_conn.stats().path.lost_plpmtud_probes, 3);

    // Sanity check: the mtu does not change after the fact, even though the link now supports a
    // higher udp payload size
    pair.mtu = 1500;
    pair.drive();
    assert_eq!(pair.client_conn_mut(client_ch).path_mtu(), 1389);
    assert_eq!(pair.server_conn_mut(server_ch).path_mtu(), 1389);

    // The MTU changes after 600 seconds, because now MTUD runs for the second time
    pair.time += Duration::from_secs(600);
    pair.drive();
    assert!(!pair.client_conn_mut(client_ch).is_closed());
    assert!(!pair.server_conn_mut(client_ch).is_closed());
    assert_eq!(pair.client_conn_mut(client_ch).path_mtu(), 1452);
    assert_eq!(pair.server_conn_mut(server_ch).path_mtu(), 1452);
}

#[test]
fn blackhole_after_mtu_change_repairs_itself() {
    let _guard = subscribe();
    let mut pair = Pair::default();
    pair.mtu = 1500;
    let (client_ch, server_ch) = pair.connect();
    pair.drive();

    // Sanity check
    assert_eq!(pair.client_conn_mut(client_ch).path_mtu(), 1452);
    assert_eq!(pair.server_conn_mut(server_ch).path_mtu(), 1452);

    // Back to the base MTU
    pair.mtu = 1200;

    // The payload will be sent in a single packet, because the detected MTU was 1444, but it will
    // be dropped because the link no longer supports that packet size!
    let payload = vec![42; 1300];
    let s = pair.client_streams(client_ch).open(Dir::Uni).unwrap();
    // Probes recover single-write tails early; detection needs >3 independent bursts across writes.
    for _ in 0..4 {
        pair.client_send(client_ch, s).write(&payload).unwrap();
        assert!(
            !pair.drive_bounded(),
            "connections never reached an idle state"
        );
    }

    let recv = pair.server_recv(server_ch, s);
    let buf = stream_chunks(recv);

    // The whole packet arrived in the end
    assert_eq!(buf.len(), 4 * 1300);

    // Sanity checks (black hole detected after 3 lost packets)
    let client_stats = pair.client_conn_mut(client_ch).stats();
    assert!(client_stats.path.lost_packets >= 3);
    assert!(client_stats.path.congestion_events >= 3);
    assert_eq!(client_stats.path.black_holes_detected, 1);
}

/// Without MTU discovery, as the inner connection of a CONNECT-UDP tunnel runs, a connection
/// that starts above the minimum still falls back to it when the path shrinks.
#[test]
fn blackhole_without_mtu_discovery_falls_back_to_the_minimum() {
    let _guard = subscribe();
    let mut transport = TransportConfig::default();
    transport
        .maybe_set_mtu_discovery_config(None)
        .set_initial_mtu(1300);
    let mut config = client_config();
    config.transport = Arc::new(transport);
    let mut pair = Pair::default();
    pair.mtu = 1500;
    let (client_ch, server_ch) = pair.connect_with(config);
    pair.drive();
    assert_eq!(pair.client_conn_mut(client_ch).path_mtu(), 1300);

    // The path shrinks below the packets in flight but stays above the QUIC minimum.
    pair.mtu = 1250;
    let payload = vec![42; 3000];
    let s = pair.client_streams(client_ch).open(Dir::Uni).unwrap();
    // Probes recover single-write tails early; detection needs >3 independent bursts across writes.
    for _ in 0..4 {
        pair.client_send(client_ch, s).write(&payload).unwrap();
        assert!(
            !pair.drive_bounded(),
            "connections never reached an idle state"
        );
    }

    let recv = pair.server_recv(server_ch, s);
    assert_eq!(stream_chunks(recv).len(), 4 * payload.len());
    assert_eq!(pair.client_conn_mut(client_ch).path_mtu(), 1200);
    let stats = pair.client_conn_mut(client_ch).stats();
    assert_eq!(stats.path.black_holes_detected, 1);
    assert_eq!(stats.path.sent_plpmtud_probes, 0);
}

#[test]
fn the_native_datagram_maximum_follows_a_shrinking_path() {
    let _guard = subscribe();
    let mut transport = TransportConfig::default();
    transport
        .maybe_set_mtu_discovery_config(None)
        .set_initial_mtu(1350);
    let mut config = client_config();
    config.transport = Arc::new(transport);
    let mut pair = Pair::default();
    pair.mtu = 1500;
    let (client_ch, _server_ch) = pair.connect_with(config);
    pair.drive();
    let before = pair
        .client_conn_mut(client_ch)
        .datagrams()
        .max_size()
        .unwrap();

    // The path shrinks: black-hole detection falls back to the minimum, and with it the
    // largest datagram a CONNECT-UDP tunnel on this connection can carry.
    pair.mtu = 1250;
    let s = pair.client_streams(client_ch).open(Dir::Uni).unwrap();
    pair.client_send(client_ch, s).write(&[42; 4000]).unwrap();
    assert!(
        !pair.drive_bounded(),
        "connections never reached an idle state"
    );
    assert_eq!(pair.client_conn_mut(client_ch).path_mtu(), 1200);
    let after = pair
        .client_conn_mut(client_ch)
        .datagrams()
        .max_size()
        .unwrap();
    assert_eq!(before - after, 150, "before {before}, after {after}");
    assert!(
        after < 1200,
        "a 1200-byte inner packet no longer fits: {after}"
    );
}

#[test]
fn mtud_probes_include_immediate_ack() {
    let _guard = subscribe();
    let mut pair = Pair::default();
    let (client_ch, _) = pair.connect();
    pair.drive();

    let stats = pair.client_conn_mut(client_ch).stats();
    assert_eq!(stats.path.sent_plpmtud_probes, 4);

    // Each probe contains a ping and an immediate ack
    assert_eq!(stats.frame_tx.ping, 4);
    assert_eq!(stats.frame_tx.immediate_ack, 4);
}

#[test]
fn packet_splitting_with_default_mtu() {
    let _guard = subscribe();

    // The payload needs to be split in 2 in order to be sent, because it is higher than the max MTU
    let payload = vec![42; 1300];

    let mut pair = Pair::default();
    pair.mtu = 1200;
    let (client_ch, _) = pair.connect();
    pair.drive();

    let s = pair.client_streams(client_ch).open(Dir::Uni).unwrap();

    pair.client_send(client_ch, s).write(&payload).unwrap();
    pair.client.drive(pair.time, pair.server.addr);
    assert_eq!(pair.client.outbound.len(), 2);

    pair.drive_client();
    assert_eq!(pair.server.inbound.len(), 2);
}

#[test]
fn packet_splitting_not_necessary_after_higher_mtu_discovered() {
    let _guard = subscribe();
    let payload = vec![42; 1300];

    let mut pair = Pair::default();
    pair.mtu = 1500;

    let (client_ch, _) = pair.connect();
    pair.drive();

    let s = pair.client_streams(client_ch).open(Dir::Uni).unwrap();

    pair.client_send(client_ch, s).write(&payload).unwrap();
    pair.client.drive(pair.time, pair.server.addr);
    assert_eq!(pair.client.outbound.len(), 1);

    pair.drive_client();
    assert_eq!(pair.server.inbound.len(), 1);
}

#[test]
fn single_ack_eliciting_packet_triggers_ack_after_delay() {
    let _guard = subscribe();
    let mut pair = Pair::default_with_deterministic_pns();
    let (client_ch, _) = pair.connect_with(client_config_with_deterministic_pns());
    pair.drive();

    let stats_after_connect = pair.client_conn_mut(client_ch).stats();

    let start = pair.time;
    pair.client_conn_mut(client_ch).ping();
    pair.drive_client(); // Send ping
    pair.drive_server(); // Process ping
    pair.drive_client(); // Give the client a chance to process an ack, so our assertion can fail

    // Sanity check: the time hasn't advanced in the meantime)
    assert_eq!(pair.time, start);

    let stats_after_ping = pair.client_conn_mut(client_ch).stats();
    assert_eq!(
        stats_after_ping.frame_tx.ping - stats_after_connect.frame_tx.ping,
        1
    );
    assert_eq!(
        stats_after_ping.frame_rx.acks - stats_after_connect.frame_rx.acks,
        0
    );

    pair.client.capture_inbound_packets = true;
    pair.drive();
    let stats_after_drive = pair.client_conn_mut(client_ch).stats();
    assert_eq!(
        stats_after_drive.frame_rx.acks - stats_after_ping.frame_rx.acks,
        1
    );

    // The time is start + max_ack_delay
    let default_max_ack_delay_ms = TransportParameters::default().max_ack_delay.into_inner();
    assert_eq!(
        pair.time,
        start + Duration::from_millis(default_max_ack_delay_ms)
    );

    // The ACK delay is properly calculated
    assert_eq!(pair.client.captured_packets.len(), 1);
    let mut frames = frame::Iter::new(pair.client.captured_packets.remove(0).into())
        .unwrap()
        .collect::<Result<Vec<_>, _>>()
        .unwrap();
    assert_eq!(frames.len(), 1);
    if let Frame::Ack(ack) = frames.remove(0) {
        let ack_delay_exp = TransportParameters::default().ack_delay_exponent;
        let delay = ack.delay << ack_delay_exp.into_inner();
        assert_eq!(delay, default_max_ack_delay_ms * 1_000);
    } else {
        panic!("Expected ACK frame");
    }

    // Sanity check: no loss probe was sent, because the delayed ACK was received on time
    assert_eq!(
        stats_after_drive.frame_tx.ping - stats_after_connect.frame_tx.ping,
        1
    );
}

#[test]
fn immediate_ack_triggers_ack() {
    let _guard = subscribe();
    let mut pair = Pair::default_with_deterministic_pns();
    let (client_ch, _) = pair.connect_with(client_config_with_deterministic_pns());
    pair.drive();

    let acks_after_connect = pair.client_conn_mut(client_ch).stats().frame_rx.acks;

    pair.client_conn_mut(client_ch).immediate_ack();
    pair.drive_client(); // Send immediate ack
    pair.drive_server(); // Process immediate ack
    pair.drive_client(); // Give the client a chance to process the ack

    let acks_after_ping = pair.client_conn_mut(client_ch).stats().frame_rx.acks;

    assert_eq!(acks_after_ping - acks_after_connect, 1);
}

#[test]
fn out_of_order_ack_eliciting_packet_triggers_ack() {
    let _guard = subscribe();
    let mut pair = Pair::default_with_deterministic_pns();
    let (client_ch, server_ch) = pair.connect_with(client_config_with_deterministic_pns());
    pair.drive();

    let default_mtu = pair.mtu;

    let client_stats_after_connect = pair.client_conn_mut(client_ch).stats();
    let server_stats_after_connect = pair.server_conn_mut(server_ch).stats();

    // Send a packet that won't arrive right away (it will be dropped and be re-sent later)
    pair.mtu = 0;
    pair.client_conn_mut(client_ch).ping();
    pair.drive_client();

    // Sanity check (ping sent, no ACK received)
    let client_stats_after_first_ping = pair.client_conn_mut(client_ch).stats();
    assert_eq!(
        client_stats_after_first_ping.frame_tx.ping - client_stats_after_connect.frame_tx.ping,
        1
    );
    assert_eq!(
        client_stats_after_first_ping.frame_rx.acks - client_stats_after_connect.frame_rx.acks,
        0
    );

    // Restore the default MTU and send another ping, which will arrive earlier than the dropped one
    pair.mtu = default_mtu;
    pair.client_conn_mut(client_ch).ping();
    pair.drive_client();
    pair.drive_server();
    pair.drive_client();

    // Client sanity check (ping sent, one ACK received)
    let client_stats_after_second_ping = pair.client_conn_mut(client_ch).stats();
    assert_eq!(
        client_stats_after_second_ping.frame_tx.ping - client_stats_after_connect.frame_tx.ping,
        2
    );
    assert_eq!(
        client_stats_after_second_ping.frame_rx.acks - client_stats_after_connect.frame_rx.acks,
        1
    );

    // Server checks (single ping received, ACK sent)
    let server_stats_after_second_ping = pair.server_conn_mut(server_ch).stats();
    assert_eq!(
        server_stats_after_second_ping.frame_rx.ping - server_stats_after_connect.frame_rx.ping,
        1
    );
    assert_eq!(
        server_stats_after_second_ping.frame_tx.acks - server_stats_after_connect.frame_tx.acks,
        1
    );
}

#[test]
fn single_ack_eliciting_packet_with_ce_bit_triggers_immediate_ack() {
    let _guard = subscribe();
    let mut pair = Pair::default_with_deterministic_pns();
    let (client_ch, _) = pair.connect_with(client_config_with_deterministic_pns());
    pair.drive();

    let stats_after_connect = pair.client_conn_mut(client_ch).stats();

    let start = pair.time;

    pair.client_conn_mut(client_ch).ping();

    pair.congestion_experienced = true;
    pair.drive_client(); // Send ping
    pair.congestion_experienced = false;

    pair.drive_server(); // Process ping, send ACK in response to congestion
    pair.drive_client(); // Process ACK

    // Sanity check: the time hasn't advanced in the meantime)
    assert_eq!(pair.time, start);

    let stats_after_ping = pair.client_conn_mut(client_ch).stats();
    assert_eq!(
        stats_after_ping.frame_tx.ping - stats_after_connect.frame_tx.ping,
        1
    );
    assert_eq!(
        stats_after_ping.frame_rx.acks - stats_after_connect.frame_rx.acks,
        1
    );
    assert_eq!(
        stats_after_ping.path.congestion_events - stats_after_connect.path.congestion_events,
        1
    );
}

fn setup_ack_frequency_test(max_ack_delay: Duration) -> (Pair, ConnectionHandle, ConnectionHandle) {
    let mut client_config = client_config_with_deterministic_pns();
    let mut ack_freq_config = AckFrequencyConfig::default();
    ack_freq_config
        .set_ack_eliciting_threshold(10u32)
        .set_max_ack_delay(max_ack_delay);
    Arc::get_mut(&mut client_config.transport)
        .unwrap()
        .set_ack_frequency_config(ack_freq_config)
        .maybe_set_mtu_discovery_config(None) // To keep traffic cleaner
        .set_initial_rtt(Duration::from_millis(10)); // To avoid delays from pacing

    let mut pair = Pair::default_with_deterministic_pns();
    pair.latency = Duration::from_millis(10); // Need latency to avoid an RTT = 0
    let (client_ch, server_ch) = pair.connect_with(client_config);
    pair.drive();

    assert_eq!(
        pair.client_conn_mut(client_ch)
            .stats()
            .frame_tx
            .ack_frequency,
        1
    );
    assert_eq!(pair.client_conn_mut(client_ch).stats().frame_tx.ping, 0);
    (pair, client_ch, server_ch)
}

/// Verify that max ACK delay is counted from the first ACK-eliciting packet
#[test]
fn ack_frequency_ack_delayed_from_first_of_flight() {
    let _guard = subscribe();
    let (mut pair, client_ch, server_ch) = setup_ack_frequency_test(Duration::from_millis(30));

    // The client sends the following frames:
    //
    // * 0 ms: ping
    // * 5 ms: ping x2
    pair.client_conn_mut(client_ch).ping();
    pair.drive_client();

    pair.time += Duration::from_millis(5);
    for _ in 0..2 {
        pair.client_conn_mut(client_ch).ping();
        pair.drive_client();
    }

    pair.time += Duration::from_millis(5);
    // Server: receive the first ping and send no ACK
    let server_stats_before = pair.server_conn_mut(server_ch).stats();
    pair.drive_server();
    let server_stats_after = pair.server_conn_mut(server_ch).stats();
    assert_eq!(
        server_stats_after.frame_rx.ping - server_stats_before.frame_rx.ping,
        1
    );
    assert_eq!(
        server_stats_after.frame_tx.acks - server_stats_before.frame_tx.acks,
        0
    );

    // Server: receive the second and third pings and send no ACK
    pair.time += Duration::from_millis(10);
    let server_stats_before = pair.server_conn_mut(server_ch).stats();
    pair.drive_server();
    let server_stats_after = pair.server_conn_mut(server_ch).stats();
    assert_eq!(
        server_stats_after.frame_rx.ping - server_stats_before.frame_rx.ping,
        2
    );
    assert_eq!(
        server_stats_after.frame_tx.acks - server_stats_before.frame_tx.acks,
        0
    );

    // Server: Send an ACK after ACK delay expires
    pair.time += Duration::from_millis(20);
    let server_stats_before = pair.server_conn_mut(server_ch).stats();
    pair.drive_server();
    let server_stats_after = pair.server_conn_mut(server_ch).stats();
    assert_eq!(
        server_stats_after.frame_tx.acks - server_stats_before.frame_tx.acks,
        1
    );
}

#[test]
fn ack_frequency_ack_sent_after_max_ack_delay() {
    let _guard = subscribe();
    let max_ack_delay = Duration::from_millis(30);
    let (mut pair, client_ch, server_ch) = setup_ack_frequency_test(max_ack_delay);

    // Client sends a ping
    pair.client_conn_mut(client_ch).ping();
    pair.drive_client();

    // Server: receive the ping, send no ACK
    pair.time += pair.latency;
    let server_stats_before = pair.server_conn_mut(server_ch).stats();
    pair.drive_server();
    let server_stats_after = pair.server_conn_mut(server_ch).stats();
    assert_eq!(
        server_stats_after.frame_rx.ping - server_stats_before.frame_rx.ping,
        1
    );
    assert_eq!(
        server_stats_after.frame_tx.acks - server_stats_before.frame_tx.acks,
        0
    );

    // Server: send an ack after max_ack_delay has elapsed
    pair.time += max_ack_delay;
    let server_stats_before = pair.server_conn_mut(server_ch).stats();
    pair.drive_server();
    let server_stats_after = pair.server_conn_mut(server_ch).stats();
    assert_eq!(
        server_stats_after.frame_rx.ping - server_stats_before.frame_rx.ping,
        0
    );
    assert_eq!(
        server_stats_after.frame_tx.acks - server_stats_before.frame_tx.acks,
        1
    );
}

#[test]
fn ack_frequency_ack_sent_after_packets_above_threshold() {
    let _guard = subscribe();
    let max_ack_delay = Duration::from_millis(30);
    let (mut pair, client_ch, server_ch) = setup_ack_frequency_test(max_ack_delay);

    // The client sends the following frames:
    //
    // * 0 ms: ping
    // * 5 ms: ping (11x)
    pair.client_conn_mut(client_ch).ping();
    pair.drive_client();

    pair.time += Duration::from_millis(5);
    for _ in 0..11 {
        pair.client_conn_mut(client_ch).ping();
        pair.drive_client();
    }

    // Server: receive the first ping, send no ACK
    pair.time += Duration::from_millis(5);
    let server_stats_before = pair.server_conn_mut(server_ch).stats();
    pair.drive_server();
    let server_stats_after = pair.server_conn_mut(server_ch).stats();
    assert_eq!(
        server_stats_after.frame_rx.ping - server_stats_before.frame_rx.ping,
        1
    );
    assert_eq!(
        server_stats_after.frame_tx.acks - server_stats_before.frame_tx.acks,
        0
    );

    // Server: receive the remaining pings, send ACK
    pair.time += Duration::from_millis(5);
    let server_stats_before = pair.server_conn_mut(server_ch).stats();
    pair.drive_server();
    let server_stats_after = pair.server_conn_mut(server_ch).stats();
    assert_eq!(
        server_stats_after.frame_rx.ping - server_stats_before.frame_rx.ping,
        11
    );
    assert_eq!(
        server_stats_after.frame_tx.acks - server_stats_before.frame_tx.acks,
        1
    );
}

#[test]
fn ack_frequency_ack_sent_after_reordered_packets_below_threshold() {
    let _guard = subscribe();
    let max_ack_delay = Duration::from_millis(30);
    let (mut pair, client_ch, server_ch) = setup_ack_frequency_test(max_ack_delay);

    // The client sends the following frames:
    //
    // * 0 ms: ping
    // * 5 ms: ping (lost)
    // * 5 ms: ping
    pair.client_conn_mut(client_ch).ping();
    pair.drive_client();

    pair.time += Duration::from_millis(5);

    // Send and lose an ack-eliciting packet
    pair.mtu = 0;
    pair.client_conn_mut(client_ch).ping();
    pair.drive_client();

    // Restore the default MTU and send another ping, which will arrive earlier than the dropped one
    pair.mtu = DEFAULT_MTU;
    pair.client_conn_mut(client_ch).ping();
    pair.drive_client();

    // Server: receive first ping, send no ACK
    pair.time += Duration::from_millis(5);
    let server_stats_before = pair.server_conn_mut(server_ch).stats();
    pair.drive_server();
    let server_stats_after = pair.server_conn_mut(server_ch).stats();
    assert_eq!(
        server_stats_after.frame_rx.ping - server_stats_before.frame_rx.ping,
        1
    );
    assert_eq!(
        server_stats_after.frame_tx.acks - server_stats_before.frame_tx.acks,
        0
    );

    // Server: receive second ping, send no ACK
    pair.time += Duration::from_millis(5);
    let server_stats_before = pair.server_conn_mut(server_ch).stats();
    pair.drive_server();
    let server_stats_after = pair.server_conn_mut(server_ch).stats();
    assert_eq!(
        server_stats_after.frame_rx.ping - server_stats_before.frame_rx.ping,
        1
    );
    assert_eq!(
        server_stats_after.frame_tx.acks - server_stats_before.frame_tx.acks,
        0
    );
}

#[test]
fn ack_frequency_ack_sent_after_reordered_packets_above_threshold() {
    let _guard = subscribe();
    let max_ack_delay = Duration::from_millis(30);
    let (mut pair, client_ch, server_ch) = setup_ack_frequency_test(max_ack_delay);

    // Send a ping
    pair.client_conn_mut(client_ch).ping();
    pair.drive_client();

    // Send and lose two ack-eliciting packets
    pair.time += Duration::from_millis(5);
    pair.mtu = 0;
    for _ in 0..2 {
        pair.client_conn_mut(client_ch).ping();
        pair.drive_client();
    }

    // Restore the default MTU and send another ping, which will arrive earlier than the dropped ones
    pair.mtu = DEFAULT_MTU;
    pair.client_conn_mut(client_ch).ping();
    pair.drive_client();

    // Server: receive first ping, send no ACK
    pair.time += Duration::from_millis(5);
    let server_stats_before = pair.server_conn_mut(server_ch).stats();
    pair.drive_server();
    let server_stats_after = pair.server_conn_mut(server_ch).stats();
    assert_eq!(
        server_stats_after.frame_rx.ping - server_stats_before.frame_rx.ping,
        1
    );
    assert_eq!(
        server_stats_after.frame_tx.acks - server_stats_before.frame_tx.acks,
        0
    );

    // Server: receive remaining ping, send ACK
    pair.time += Duration::from_millis(5);
    let server_stats_before = pair.server_conn_mut(server_ch).stats();
    pair.drive_server();
    let server_stats_after = pair.server_conn_mut(server_ch).stats();
    assert_eq!(
        server_stats_after.frame_rx.ping - server_stats_before.frame_rx.ping,
        1
    );
    assert_eq!(
        server_stats_after.frame_tx.acks - server_stats_before.frame_tx.acks,
        1
    );
}

#[test]
fn ack_frequency_update_max_delay() {
    let _guard = subscribe();
    let (mut pair, client_ch, server_ch) = setup_ack_frequency_test(Duration::from_millis(200));

    // Ack frequency was sent initially
    assert_eq!(
        pair.server_conn_mut(server_ch)
            .stats()
            .frame_rx
            .ack_frequency,
        1
    );

    // Client sends a PING
    info!("first ping");
    pair.client_conn_mut(client_ch).ping();
    pair.drive();

    // No change in ACK frequency
    assert_eq!(
        pair.server_conn_mut(server_ch)
            .stats()
            .frame_rx
            .ack_frequency,
        1
    );

    // RTT jumps, client sends another ping
    info!("delayed ping");
    pair.latency *= 10;
    pair.client_conn_mut(client_ch).ping();
    pair.drive();

    // ACK frequency updated
    assert!(
        pair.server_conn_mut(server_ch)
            .stats()
            .frame_rx
            .ack_frequency
            >= 2
    );
}

fn stream_chunks(mut recv: RecvStream) -> Vec<u8> {
    let mut buf = Vec::new();

    let mut chunks = recv.read(true).unwrap();
    while let Ok(Some(chunk)) = chunks.next(usize::MAX) {
        buf.extend(chunk.bytes);
    }

    let _transmit = chunks.finalize();

    buf
}

/// Verify that an endpoint which receives but does not send ACK-eliciting data still receives ACKs
/// occasionally. This is not required for conformance, but makes loss detection more responsive and
/// reduces receiver memory use.
#[test]
fn pure_sender_voluntarily_acks() {
    let _guard = subscribe();
    let mut pair = Pair::default();
    let (client_ch, server_ch) = pair.connect();

    let receiver_acks_initial = pair.server_conn_mut(server_ch).stats().frame_rx.acks;

    for _ in 0..100 {
        const MSG: &[u8] = b"hello";
        pair.client_datagrams(client_ch)
            .send(Bytes::from_static(MSG), true)
            .unwrap();
        pair.drive();
        assert_eq!(pair.server_datagrams(server_ch).recv().unwrap(), MSG);
    }

    let receiver_acks_final = pair.server_conn_mut(server_ch).stats().frame_rx.acks;
    assert!(receiver_acks_final > receiver_acks_initial);
}

/// Initials rejected under saturation (here via `max_incoming(0)`) are dropped without
/// sending a response: the client times out rather than receiving a CONNECTION_REFUSED.
#[test]
fn silently_drop_rejected_initials() {
    let _guard = subscribe();
    let mut server_config = server_config();
    server_config.set_max_incoming(0);
    let mut pair = Pair::new(
        Arc::new(EndpointConfig::try_with_rand_key().unwrap()),
        server_config,
    );

    let client_ch = pair.begin_connect(client_config());
    pair.drive();
    pair.server.assert_no_accept();
    // `drive()` stops once the client's only remaining timer is its idle timeout; advance
    // past it so the unanswered attempt gives up.
    pair.time += Duration::from_secs(60);
    pair.drive();
    match pair.client_conn_mut(client_ch).poll() {
        Some(Event::ConnectionLost {
            reason: ConnectionError::TimedOut,
        }) => {}
        other => panic!(
            "assertion failed: `{other:?}` does not match `Some(Event::ConnectionLost {{ reason: ConnectionError::TimedOut, }})`"
        ),
    }
}

#[test]
fn reject_manually() {
    let _guard = subscribe();
    let mut pair = Pair::default();
    pair.server.handle_incoming = Box::new(|_| IncomingConnectionBehavior::Reject);

    // The server should now reject incoming connections.
    let client_ch = pair.begin_connect(client_config());
    pair.drive();
    pair.server.assert_no_accept();
    let client = pair.client.connections.get_mut(&client_ch).unwrap();
    assert!(client.is_closed());
    assert_matches!(
        client.poll(),
        Some(Event::ConnectionLost {
            reason: ConnectionError::ConnectionClosed(close)
        }) if close.error_code == TransportErrorCode::CONNECTION_REFUSED,
    );
}

#[test]
fn validate_then_reject_manually() {
    let _guard = subscribe();
    let mut pair = Pair::default();
    pair.server.handle_incoming = Box::new({
        let mut i = 0;
        move |incoming| {
            if incoming.remote_address_validated() {
                assert_eq!(i, 1);
                i += 1;
                IncomingConnectionBehavior::Reject
            } else {
                assert_eq!(i, 0);
                i += 1;
                IncomingConnectionBehavior::Retry
            }
        }
    });

    // The server should now retry and reject incoming connections.
    let client_ch = pair.begin_connect(client_config());
    pair.drive();
    pair.server.assert_no_accept();
    let client = pair.client.connections.get_mut(&client_ch).unwrap();
    assert!(client.is_closed());
    assert_matches!(
        client.poll(),
        Some(Event::ConnectionLost {
            reason: ConnectionError::ConnectionClosed(close)
        }) if close.error_code == TransportErrorCode::CONNECTION_REFUSED,
    );
    pair.drive();
    match pair.client_conn_mut(client_ch).poll() {
        None => {}
        other => panic!("assertion failed: `{other:?}` does not match `None`"),
    }
    assert_eq!(pair.client.known_connections(), 0);
    assert_eq!(pair.client.known_cids(), 0);
    assert_eq!(pair.server.known_connections(), 0);
    assert_eq!(pair.server.known_cids(), 0);
}

#[test]
fn endpoint_and_connection_impl_send_sync() {
    const fn is_send_sync<T: Send + Sync>() {}
    is_send_sync::<Endpoint>();
    is_send_sync::<Connection>();
}

#[test]
fn stream_gso() {
    let _guard = subscribe();
    let mut pair = Pair::default();
    let (client_ch, _) = pair.connect();

    let s = pair.client_streams(client_ch).open(Dir::Uni).unwrap();

    let initial_ios = pair.client_conn_mut(client_ch).stats().udp_tx.ios;

    // Send 20KiB of stream data, which comfortably fits inside two `tests::util::MAX_DATAGRAMS`
    // datagram batches
    info!("sending");
    for _ in 0..20 {
        pair.client_send(client_ch, s).write(&[0; 1024]).unwrap();
    }
    pair.client_send(client_ch, s).finish().unwrap();
    pair.drive();
    let final_ios = pair.client_conn_mut(client_ch).stats().udp_tx.ios;
    assert_eq!(final_ios - initial_ios, 2);
}

#[test]
fn datagram_gso() {
    let _guard = subscribe();
    let mut pair = Pair::default();
    let (client_ch, server_ch) = pair.connect();

    // Sending ack-eliciting packet from server let client send ACK, which prevents
    // sending bundled ACK for a while.
    pair.server_datagrams(server_ch)
        .send(Bytes::new(), false)
        .unwrap();
    pair.drive();

    let initial_ios = pair.client_conn_mut(client_ch).stats().udp_tx.ios;
    let initial_bytes = pair.client_conn_mut(client_ch).stats().udp_tx.bytes;

    // Send 10 datagrams above half the MTU, which fits inside a `tests::util::MAX_DATAGRAMS`
    // datagram batch
    info!("sending");
    const DATAGRAM_LEN: usize = 1024;
    const DATAGRAMS: usize = 10;
    for _ in 0..DATAGRAMS {
        pair.client_datagrams(client_ch)
            .send(Bytes::from_static(&[0; DATAGRAM_LEN]), false)
            .unwrap();
    }
    pair.drive();
    let final_ios = pair.client_conn_mut(client_ch).stats().udp_tx.ios;
    let final_bytes = pair.client_conn_mut(client_ch).stats().udp_tx.bytes;
    assert_eq!(final_ios - initial_ios, 1);
    // Expected overhead: flags + CID + PN + tag + frame type + frame length = 1 + 8 + 1 + 16 + 1 + 2 = 29
    assert_eq!(
        final_bytes - initial_bytes,
        ((29 + DATAGRAM_LEN) * DATAGRAMS) as u64
    );
}

#[test]
fn tiny_ack_packet_leaves_large_datagrams_for_the_next_gso_batch() {
    let mut pair = Pair::default();
    let (client, server) = pair.connect();
    pair.drive();
    // Gaps make the ACK larger than the spare bytes beside a maximum-size DATAGRAM.
    for i in 0..16 {
        pair.server_conn_mut(server).ping();
        pair.drive_server();
        if i % 2 == 1 {
            pair.client.inbound.pop_back();
        }
    }
    pair.client.drive_incoming(pair.time, pair.server.addr);
    pair.time += Duration::from_millis(25);
    let size = pair.client_datagrams(client).max_size().unwrap();
    for byte in [0xaa, 0xbb] {
        pair.client_datagrams(client)
            .send(vec![byte; size].into(), false)
            .unwrap();
    }
    let before = pair.client_conn_mut(client).stats().udp_tx.ios;
    pair.client.drive(pair.time, pair.server.addr);
    assert_eq!(pair.client.outbound.len(), 3);
    assert!(pair.client.outbound.front().unwrap().0.size < 100);
    assert_eq!(pair.client_conn_mut(client).stats().udp_tx.ios - before, 2);
    pair.drive();
    for byte in [0xaa, 0xbb] {
        assert_eq!(
            pair.server_datagrams(server).recv().unwrap().as_ref(),
            vec![byte; size]
        );
    }
}

#[test]
fn gso_truncation() {
    let _guard = subscribe();
    let mut pair = Pair::default();
    let (client_ch, server_ch) = pair.connect();

    let initial_ios = pair.client_conn_mut(client_ch).stats().udp_tx.ios;

    // Send three application datagrams such that each is large to be combined with another in a
    // single MTU, and the second datagram would require an unreasonably large amount of padding to
    // produce a QUIC packet of the same length as the first.
    info!("sending");
    const SIZES: [usize; 3] = [1024, 768, 768];
    for len in SIZES {
        pair.client_datagrams(client_ch)
            .send(vec![0; len].into(), false)
            .unwrap();
    }
    pair.drive();
    let final_ios = pair.client_conn_mut(client_ch).stats().udp_tx.ios;
    assert_eq!(final_ios - initial_ios, 2);
    for len in SIZES {
        assert_eq!(
            pair.server_datagrams(server_ch)
                .recv()
                .expect("datagram lost")
                .len(),
            len
        );
    }
}

/// Verify that UDP datagrams are padded to MTU if specified in the transport config.
#[test]
fn pad_to_mtu() {
    let _guard = subscribe();
    const MTU: u16 = 1333;
    let client_config = {
        let mut c_config = client_config();
        let t_config = TransportConfig {
            initial_mtu: MTU,
            mtu_discovery_config: None,
            pad_to_mtu: true,
            ..TransportConfig::default()
        };
        c_config.set_transport_config(t_config.into());
        c_config
    };
    let mut pair = Pair::default();
    let (client_ch, server_ch) = pair.connect_with(client_config);

    let initial_ios = pair.client_conn_mut(client_ch).stats().udp_tx.ios;
    pair.server.capture_inbound_packets = true;

    info!("sending");
    // Send two datagrams significantly smaller than MTU, but large enough to require two UDP datagrams.
    const LEN_1: usize = 800;
    const LEN_2: usize = 600;
    pair.client_datagrams(client_ch)
        .send(vec![0; LEN_1].into(), false)
        .unwrap();
    pair.client_datagrams(client_ch)
        .send(vec![0; LEN_2].into(), false)
        .unwrap();
    pair.client.drive(pair.time, pair.server.addr);

    // Check padding
    assert_eq!(pair.client.outbound.len(), 2);
    assert_eq!(pair.client.outbound[0].0.size, usize::from(MTU));
    assert_eq!(pair.client.outbound[0].1.len(), usize::from(MTU));
    assert_eq!(pair.client.outbound[1].0.size, usize::from(MTU));
    assert_eq!(pair.client.outbound[1].1.len(), usize::from(MTU));
    pair.drive_client();
    assert_eq!(pair.server.inbound.len(), 2);
    assert_eq!(pair.server.inbound[0].packet.len(), usize::from(MTU));
    assert_eq!(pair.server.inbound[1].packet.len(), usize::from(MTU));
    pair.drive();

    // Check that both datagrams ended up in the same GSO batch
    let final_ios = pair.client_conn_mut(client_ch).stats().udp_tx.ios;
    assert_eq!(final_ios - initial_ios, 1);

    assert_eq!(
        pair.server_datagrams(server_ch)
            .recv()
            .expect("datagram lost")
            .len(),
        LEN_1
    );
    assert_eq!(
        pair.server_datagrams(server_ch)
            .recv()
            .expect("datagram lost")
            .len(),
        LEN_2
    );
}

/// Verify that a large application datagram is sent successfully when an ACK frame too large to fit
/// alongside it is also queued, in exactly 2 UDP datagrams.
#[test]
fn large_datagram_with_acks() {
    let _guard = subscribe();
    let mut pair = Pair::default();
    let (client_ch, server_ch) = pair.connect();

    // Force the client to generate a large ACK frame by dropping several packets
    for _ in 0..10 {
        pair.server_conn_mut(server_ch).ping();
        pair.drive_server();
        pair.client.inbound.pop_back();
        pair.server_conn_mut(server_ch).ping();
        pair.drive_server();
    }

    let max_size = pair.client_datagrams(client_ch).max_size().unwrap();
    let msg = Bytes::from(vec![0; max_size]);
    pair.client_datagrams(client_ch)
        .send(msg.clone(), true)
        .unwrap();
    let initial_datagrams = pair.client_conn_mut(client_ch).stats().udp_tx.datagrams;
    pair.drive();
    let final_datagrams = pair.client_conn_mut(client_ch).stats().udp_tx.datagrams;
    assert_eq!(pair.server_datagrams(server_ch).recv().unwrap(), msg);
    assert_eq!(final_datagrams - initial_datagrams, 2);
}

/// Verify that an ACK prompted by receipt of many non-ACK-eliciting packets is sent alongside
/// outgoing application datagrams too large to coexist in the same packet with it.
#[test]
fn voluntary_ack_with_large_datagrams() {
    let _guard = subscribe();
    let mut pair = Pair::default();
    let (client_ch, _) = pair.connect();

    // Prompt many large ACKs from the server
    let initial_datagrams = pair.client_conn_mut(client_ch).stats().udp_tx.datagrams;
    // Send enough packets that we're confident some packet numbers will be skipped, ensuring that
    // larger ACKs occur
    const COUNT: usize = 256;
    for _ in 0..COUNT {
        let max_size = pair.client_datagrams(client_ch).max_size().unwrap();
        pair.client_datagrams(client_ch)
            .send(vec![0; max_size].into(), true)
            .unwrap();
        pair.drive();
    }
    let final_datagrams = pair.client_conn_mut(client_ch).stats().udp_tx.datagrams;
    // Failure may indicate `max_size` is too small and ACKs are reliably being packed into the same
    // datagram, which is reasonable behavior but makes this test ineffective.
    assert_ne!(
        final_datagrams - initial_datagrams,
        COUNT as u64,
        "client should have sent some ACK-only packets"
    );
}

#[test]
fn ack_bundled_with_datagrams() {
    let _guard = subscribe();
    let mut pair = Pair::default_with_deterministic_pns();
    let (client_ch, server_ch) = pair.connect_with(client_config_with_deterministic_pns());

    // Send packet from client and then send from server. the packet from server should include ACKs
    pair.client_datagrams(client_ch)
        .send(vec![0; 1].into(), false)
        .unwrap();
    pair.drive_client();
    pair.drive_server();

    let server_tx_acks_before_datagram = pair.server_conn_mut(server_ch).stats().frame_tx.acks;
    let server_tx_packets_before_datagram =
        pair.server_conn_mut(server_ch).stats().udp_tx.datagrams;

    pair.server_datagrams(server_ch)
        .send(vec![0; 1].into(), false)
        .unwrap();
    pair.drive_server();

    let server_tx_acks_after_datagram = pair.server_conn_mut(server_ch).stats().frame_tx.acks;

    assert_eq!(
        server_tx_acks_before_datagram + 1,
        server_tx_acks_after_datagram,
        "server should have sent ACK frame along with DATAGRAM frame"
    );
    assert_eq!(
        server_tx_packets_before_datagram + 1,
        pair.server_conn_mut(server_ch).stats().udp_tx.datagrams,
        "server should not have sent two or more QUIC packets"
    );

    pair.drive();

    // No more acks should be sent from server since ACK to the first packet has been sent with the datagram
    assert_eq!(
        server_tx_acks_after_datagram,
        pair.server_conn_mut(server_ch).stats().frame_tx.acks,
        "server should not sent ACK frames"
    );
}

/// Verify that dropping oversized datagrams will trigger a DatagramsUnblocked event.
#[test]
fn oversized_datagrams_trigger_unblock() {
    let _guard = subscribe();
    let mut pair = Pair::default();
    // Start the connection with a large MTU.
    const INITIAL_MTU: usize = 1300;
    pair.mtu = INITIAL_MTU;

    let mut client_config = client_config();
    let mut transport_config = TransportConfig::default();
    let send_buffer_size = transport_config.datagram_send_buffer_size;
    transport_config.set_initial_mtu(INITIAL_MTU as u16);
    client_config.set_transport_config(transport_config.into());

    let (client_ch, _) = pair.connect_with(client_config);

    // Send datagrams until the send buffer is full.
    let max_size = pair.client_datagrams(client_ch).max_size().unwrap();
    let data = vec![0; max_size];
    loop {
        match pair
            .client_datagrams(client_ch)
            .send(data.clone().into(), false)
        {
            Ok(_) => {}
            Err(SendDatagramError::Blocked(_)) => {
                break;
            }
            Err(e) => panic!("unexpected error: {e}"),
        }
    }
    // Set the MTU to a smaller value so the queued datagrams cannot be sent.
    pair.mtu = 1200;

    // Drive the pair until black hole detection kicks in and the path MTU is adjusted.
    while pair.step() {
        let err = loop {
            if let Err(e) = pair
                .client_datagrams(client_ch)
                .send(data.clone().into(), false)
            {
                break e;
            }
        };
        match err {
            SendDatagramError::Blocked(_) => {
                // continue with the next step but drain the DatagramsUnblocked events
                // emitted datagrams were sent out.
                while let Some(event) = pair.client_conn_mut(client_ch).poll() {
                    rama_core::telemetry::tracing::info!("ignoring connection event: {event:?}");
                }
            }
            SendDatagramError::TooLarge => {
                // mtu adjusted, break the loop
                break;
            }
            _ => panic!("unexpected error: {err}"),
        }
    }

    assert_eq!(
        pair.client_conn_mut(client_ch)
            .stats()
            .path
            .black_holes_detected,
        1,
        "expected a black hole to have been detected",
    );

    // `send_buffer_space` reserves one entry of queue overhead (`Datagrams::ENTRY_OVERHEAD`) so
    // that a datagram of the returned size can always be queued without evicting older ones.
    assert_eq!(
        pair.client_datagrams(client_ch).send_buffer_space(),
        send_buffer_size - Datagrams::ENTRY_OVERHEAD,
        "expected the send buffer to be empty after too large datagrams were dropped",
    );
    match pair.client_conn_mut(client_ch).poll() {
        Some(Event::DatagramsUnblocked) => {}
        _ => panic!("expected DatagramsUnblocked event"),
    }
}

#[test]
fn reject_short_idcid() {
    let _guard = subscribe();
    let client_addr = SocketAddr::from(([0, 0, 0, 0, 0, 0, 0, 2], 7890));
    let mut server = Endpoint::new(
        Arc::new(EndpointConfig::try_with_rand_key().unwrap()),
        Some(Arc::new(server_config())),
        true,
        None,
    );
    let now = Instant::now();
    let mut buf = Vec::with_capacity(server.config().get_max_udp_payload_size() as usize);
    // Initial header that has an empty DCID but is otherwise well-formed
    let mut initial =
        BytesMut::from([0xc4, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x3f].as_ref());
    initial.resize(MIN_INITIAL_SIZE.into(), 0);
    let event = server.handle(now, client_addr, None, None, initial, &mut buf);
    let Some(DatagramEvent::Response(Transmit { .. })) = event else {
        panic!("expected an initial close");
    };
}

/// Ensure that a connection can be made when a preferred address is advertised by the server,
/// regardless of whether the address is actually used.
#[test]
fn preferred_address() {
    let _guard = subscribe();
    let mut server_config = server_config();
    server_config.set_preferred_address_v6(SocketAddrV6::new(Ipv6Addr::LOCALHOST, 65535, 0, 0));

    let mut pair = Pair::new(
        Arc::new(EndpointConfig::try_with_rand_key().unwrap()),
        server_config,
    );
    pair.connect();
}

#[test]
fn handshake_sequence() {
    let _guard = subscribe();

    let mut pair = Pair::default();
    let ch = pair.begin_connect(client_config());

    pair.step();
    match pair.client_conn_mut(ch).poll() {
        None => {}
        other => panic!("assertion failed: `{other:?}` does not match `None`"),
    }
    let sh = pair.server.assert_accept();
    match pair.server_conn_mut(sh).poll() {
        Some(Event::HandshakeDataReady) => {}
        other => {
            panic!("assertion failed: `{other:?}` does not match `Some(Event::HandshakeDataReady)`")
        }
    }
    match pair.server_conn_mut(sh).poll() {
        None => {}
        other => panic!("assertion failed: `{other:?}` does not match `None`"),
    }

    pair.step();
    match pair.client_conn_mut(ch).poll() {
        Some(Event::HandshakeDataReady) => {}
        other => {
            panic!("assertion failed: `{other:?}` does not match `Some(Event::HandshakeDataReady)`")
        }
    }
    match pair.client_conn_mut(ch).poll() {
        Some(Event::Connected) => {}
        other => panic!("assertion failed: `{other:?}` does not match `Some(Event::Connected)`"),
    }
    match pair.client_conn_mut(ch).poll() {
        None => {}
        other => panic!("assertion failed: `{other:?}` does not match `None`"),
    }
    match pair.server_conn_mut(sh).poll() {
        Some(Event::HandshakeConfirmed) => {}
        other => {
            panic!("assertion failed: `{other:?}` does not match `Some(Event::HandshakeConfirmed)`")
        }
    }
    match pair.server_conn_mut(sh).poll() {
        Some(Event::Connected) => {}
        other => panic!("assertion failed: `{other:?}` does not match `Some(Event::Connected)`"),
    }
    match pair.server_conn_mut(sh).poll() {
        None => {}
        other => panic!("assertion failed: `{other:?}` does not match `None`"),
    }

    pair.drive_client();
    match pair.client_conn_mut(ch).poll() {
        Some(Event::HandshakeConfirmed) => {}
        other => {
            panic!("assertion failed: `{other:?}` does not match `Some(Event::HandshakeConfirmed)`")
        }
    }
    match pair.client_conn_mut(ch).poll() {
        None => {}
        other => panic!("assertion failed: `{other:?}` does not match `None`"),
    }
}

#[test]
fn handshake_confirmation_no_resumption_shortcut() {
    let _guard = subscribe();

    // Initial connection
    let mut pair = Pair::default();
    let config = client_config();
    let (ch, _) = pair.connect_with(config.clone());
    pair.client.connections.get_mut(&ch).unwrap().close(
        pair.time,
        VarInt::from_u32(0),
        [][..].into(),
    );
    pair.drive();

    // Resumed connection
    info!("resuming session");
    let ch = pair.begin_connect(config);
    assert!(pair.client_conn_mut(ch).has_0rtt());

    pair.step();
    match pair.client_conn_mut(ch).poll() {
        None => {}
        other => panic!("assertion failed: `{other:?}` does not match `None`"),
    }
    let sh = pair.server.assert_accept();
    match pair.server_conn_mut(sh).poll() {
        Some(Event::HandshakeDataReady) => {}
        other => {
            panic!("assertion failed: `{other:?}` does not match `Some(Event::HandshakeDataReady)`")
        }
    }
    match pair.server_conn_mut(sh).poll() {
        None => {}
        other => panic!("assertion failed: `{other:?}` does not match `None`"),
    }

    pair.step();
    match pair.client_conn_mut(ch).poll() {
        Some(Event::HandshakeDataReady) => {}
        other => {
            panic!("assertion failed: `{other:?}` does not match `Some(Event::HandshakeDataReady)`")
        }
    }
    match pair.client_conn_mut(ch).poll() {
        Some(Event::Connected) => {}
        other => panic!("assertion failed: `{other:?}` does not match `Some(Event::Connected)`"),
    }
    match pair.client_conn_mut(ch).poll() {
        None => {}
        other => panic!("assertion failed: `{other:?}` does not match `None`"),
    }
    match pair.server_conn_mut(sh).poll() {
        Some(Event::HandshakeConfirmed) => {}
        other => {
            panic!("assertion failed: `{other:?}` does not match `Some(Event::HandshakeConfirmed)`")
        }
    }
    match pair.server_conn_mut(sh).poll() {
        Some(Event::Connected) => {}
        other => panic!("assertion failed: `{other:?}` does not match `Some(Event::Connected)`"),
    }
    match pair.server_conn_mut(sh).poll() {
        None => {}
        other => panic!("assertion failed: `{other:?}` does not match `None`"),
    }

    pair.drive_client();
    match pair.client_conn_mut(ch).poll() {
        Some(Event::HandshakeConfirmed) => {}
        other => {
            panic!("assertion failed: `{other:?}` does not match `Some(Event::HandshakeConfirmed)`")
        }
    }
    match pair.client_conn_mut(ch).poll() {
        None => {}
        other => panic!("assertion failed: `{other:?}` does not match `None`"),
    }
}

/// A CONNECTION_CLOSE frame of type 0x1d must be rejected in an Initial packet
///
/// RFC 9000 §12.4 Table 3 lists CONNECTION_CLOSE with the packet-type marker `ih01`, defined as
/// "Only a CONNECTION_CLOSE frame of type 0x1c can appear in Initial or Handshake packets", and
/// §12.4 requires that "An endpoint MUST treat receipt of a frame in a packet type that is not
/// permitted as a connection error of type PROTOCOL_VIOLATION". §12.5 repeats the rule:
/// "CONNECTION_CLOSE frames signaling application errors (type 0x1d) MUST only appear in the
/// application data packet number space."
#[test]
fn application_close_in_initial_is_rejected() {
    let _guard = subscribe();
    let server_addr = SocketAddr::new(Ipv6Addr::LOCALHOST.into(), 4433);
    let mut client = Endpoint::new(
        Arc::new(EndpointConfig::try_with_rand_key().unwrap()),
        None,
        true,
        None,
    );
    let now = Instant::now();
    let (_, mut conn) = client
        .connect(now, client_config(), server_addr, "localhost")
        .unwrap();

    // Grab the client's Initial packet so we can learn the connection IDs and version it chose.
    let mut buf = Vec::new();
    let transmit = conn
        .poll_transmit(now, 1, &mut buf)
        .expect("client should send an Initial packet");
    let initial = &buf[..transmit.size];
    // Long header: flags(1) version(4) dcid_len(1) dcid scid_len(1) scid ...
    let version = Version::from_be_bytes(initial[1..5].try_into().unwrap());
    let dcid_len = initial[5] as usize;
    let orig_dst_cid = ConnectionId::new(&initial[6..6 + dcid_len]);
    let scid_len = initial[6 + dcid_len] as usize;
    let client_cid = ConnectionId::new(&initial[7 + dcid_len..7 + dcid_len + scid_len]);

    // Forge a server Initial packet whose payload is a single APPLICATION_CLOSE (0x1d) frame.
    // Initial packets are protected with keys derived from the client's original destination
    // connection ID, which travels in the clear, so anyone who observes the handshake can do this.
    let keys = server_config()
        .crypto
        .initial()
        .initial_keys(version, &orig_dst_cid)
        .unwrap();
    let number = PacketNumber::U8(0);
    let header = Header::Initial(InitialHeader {
        dst_cid: client_cid,
        src_cid: ConnectionId::new(&[]),
        token: Bytes::new(),
        number,
        version: version.to_wire().unwrap(),
    });
    let mut packet = Vec::new();
    let partial = header.encode(&mut packet);
    let header_len = packet.len();
    // APPLICATION_CLOSE: type 0x1d, Error Code (varint) = 42, Reason Phrase Length (varint) = 0
    packet.extend_from_slice(&[0x1d, 0x2a, 0x00]);
    // PADDING, so that the packet is long enough for header protection sampling
    packet.resize(header_len + 16, 0);
    // Room for the AEAD tag
    packet.resize(packet.len() + keys.local.packet.tag_len(), 0);
    partial
        .finish(
            &mut packet,
            keys.local.header.as_ref(),
            Some((0, keys.local.packet.as_ref())),
        )
        .unwrap();

    let event = client.handle(
        now,
        server_addr,
        None,
        None,
        BytesMut::from(&packet[..]),
        &mut buf,
    );
    let Some(DatagramEvent::ConnectionEvent(_, event)) = event else {
        panic!("forged Initial packet was not routed to the connection");
    };
    conn.handle_event(event);

    match conn.poll() {
        Some(Event::ConnectionLost {
            reason:
                ConnectionError::TransportError(TransportError {
                    code: TransportErrorCode::PROTOCOL_VIOLATION,
                    ..
                }),
        }) => {}
        other => panic!(
            "assertion failed: `{other:?}` does not match `Some(Event::ConnectionLost {{ reason: ConnectionError::TransportError(TransportError {{ code: TransportErrorCode::PROTOCOL_VIOLATION, .. }}) }})`"
        ),
    }
}

/// The default `aws-lc` provider prefers a post-quantum key exchange, which roughly doubles the
/// ClientHello. Sequence tests pin a classic key exchange (`test_provider`); this test keeps the
/// production provider and checks the large handshake flight still completes and carries data.
#[cfg(all(feature = "rustls", feature = "aws-lc", not(feature = "ring")))]
#[test]
fn post_quantum_handshake_and_transfer() {
    let _guard = subscribe();
    let server = ServerConfig::with_crypto(Arc::new(server_crypto_with_provider(
        crate::proto::crypto::rustls::configured_provider(),
        None,
        None,
    )));
    let mut pair = Pair::new(
        Arc::new(EndpointConfig::try_with_rand_key().unwrap()),
        server,
    );
    let client = ClientConfig::new(Arc::new(client_crypto_with_provider(
        crate::proto::crypto::rustls::configured_provider(),
        None,
        None,
    )));
    let client_ch = pair.begin_connect(client);
    pair.drive();
    let server_ch = pair.server.assert_accept();

    let mut client_connected = false;
    while let Some(event) = pair.client_conn_mut(client_ch).poll() {
        client_connected |= matches!(event, Event::Connected);
    }
    let mut server_connected = false;
    while let Some(event) = pair.server_conn_mut(server_ch).poll() {
        server_connected |= matches!(event, Event::Connected);
    }
    assert!(client_connected && server_connected);
    assert_eq!(
        pair.client_conn_mut(client_ch)
            .negotiated_key_exchange_group(),
        Some(X25519MLKEM768),
        "the production aws-lc provider negotiates the post-quantum hybrid group"
    );
    // The hybrid key share (1216 bytes) and ML-KEM ciphertext (1088 bytes) make both handshake
    // flights materially larger than the classic fixture's
    let pq_client_tx = pair.client_conn_mut(client_ch).stats().udp_tx.bytes;
    let pq_server_tx = pair.server_conn_mut(server_ch).stats().udp_tx.bytes;
    let mut classic = Pair::default();
    let (classic_client, classic_server) = classic.connect();
    let classic_client_tx = classic.client_conn_mut(classic_client).stats().udp_tx.bytes;
    let classic_server_tx = classic.server_conn_mut(classic_server).stats().udp_tx.bytes;
    assert!(
        pq_client_tx >= classic_client_tx + 1000 && pq_server_tx >= classic_server_tx + 1000,
        "post-quantum handshake must carry the larger key shares: client {pq_client_tx} vs {classic_client_tx}, server {pq_server_tx} vs {classic_server_tx}"
    );

    let s = pair.client_streams(client_ch).open(Dir::Bi).unwrap();
    const MSG: &[u8] = b"post-quantum hello";
    pair.client_send(client_ch, s).write(MSG).unwrap();
    pair.client_send(client_ch, s).finish().unwrap();
    pair.drive();
    match pair.server_streams(server_ch).accept(Dir::Bi) {
        Some(id) if id == s => {}
        other => panic!("assertion failed: `{other:?}` does not match `Some(id) if id == s`"),
    }
    let mut recv = pair.server_recv(server_ch, s);
    let mut chunks = recv.read(true).unwrap();
    match chunks.next(usize::MAX) {
        Ok(Some(chunk)) if chunk.bytes == MSG => {}
        other => panic!(
            "assertion failed: `{other:?}` does not match `Ok(Some(chunk)) if chunk.bytes == MSG`"
        ),
    }
    match chunks.next(usize::MAX) {
        Ok(None) => {}
        other => panic!("assertion failed: `{other:?}` does not match `Ok(None)`"),
    }
    let _transmit = chunks.finalize();
}

/// IANA `NamedGroup` codes used by the key-exchange assertions
const X25519: u16 = 0x001d;
#[cfg(all(feature = "rustls", feature = "aws-lc", not(feature = "ring")))]
const X25519MLKEM768: u16 = 0x11ec;

/// The simulator fixtures pin a classic key exchange so packet sequences stay provider independent
#[test]
fn classic_fixture_negotiates_x25519_in_one_initial() {
    let _guard = subscribe();
    let mut pair = Pair::default();
    let client_ch = pair.begin_connect(client_config());
    pair.drive_client();
    assert_eq!(
        pair.server.inbound.len(),
        1,
        "classic ClientHello fits one datagram"
    );
    // The classic server flight (ServerHello, certificate, Finished) coalesces into one padded
    // datagram; compare with `post_quantum_handshake_and_transfer`. Within the initial window
    // the server's first 1-RTT packets leave with it.
    pair.drive_server();
    let handshake: Vec<usize> = pair
        .client
        .inbound
        .iter()
        .filter(|x| x.packet[0] & rama_quic_proto::packet::LONG_HEADER_FORM != 0)
        .map(|x| x.packet.len())
        .collect();
    assert_eq!(handshake, [usize::from(INITIAL_MTU)]);
    pair.drive();
    let server_ch = pair.server.assert_accept();
    assert_eq!(
        pair.client_conn_mut(client_ch)
            .negotiated_key_exchange_group(),
        Some(X25519)
    );
    assert_eq!(
        pair.server_conn_mut(server_ch)
            .negotiated_key_exchange_group(),
        Some(X25519)
    );
}

/// The non-dropping DATAGRAM send path budgets queued payload *and* per-entry overhead, so an
/// application waiting for space cannot grow the queue without bound with tiny or empty frames.
#[test]
fn waiting_datagram_sends_respect_total_buffer_budget() {
    let _guard = subscribe();
    const ENTRY: usize = Datagrams::ENTRY_OVERHEAD;
    let mut config = client_config();
    let mut transport = TransportConfig::default();
    transport.set_datagram_send_buffer_size(3 * ENTRY);
    config.set_transport_config(transport.into());
    let mut pair = Pair::default();
    let (client_ch, server_ch) = pair.connect_with(config);

    // Three empty frames fill the budget exactly; the fourth must wait
    for i in 0..3 {
        assert_eq!(
            pair.client_datagrams(client_ch).send_buffer_space(),
            (3 - i - 1) * ENTRY,
            "space before empty frame {i}"
        );
        pair.client_datagrams(client_ch)
            .send(Bytes::new(), false)
            .unwrap();
    }
    assert_eq!(pair.client_datagrams(client_ch).send_buffer_space(), 0);
    match pair.client_datagrams(client_ch).send(Bytes::new(), false) {
        Err(SendDatagramError::Blocked(_)) => {}
        other => panic!("fourth empty frame must wait for queue space, got {other:?}"),
    }
    // A payload that can never fit the configured buffer is rejected outright
    match pair
        .client_datagrams(client_ch)
        .send(vec![0u8; 3 * ENTRY].into(), false)
    {
        Err(SendDatagramError::TooLarge) => {}
        other => panic!("oversized for the buffer, got {other:?}"),
    }

    // Draining the queue unblocks the sender and restores the budget; repeat a few cycles
    for cycle in 0..3 {
        pair.drive();
        match pair.client_conn_mut(client_ch).poll() {
            Some(Event::DatagramsUnblocked) => {}
            other => panic!("cycle {cycle}: expected DatagramsUnblocked, got {other:?}"),
        }
        for _ in 0..3 {
            assert!(pair.server_datagrams(server_ch).recv().is_some());
        }
        assert_eq!(
            pair.client_datagrams(client_ch).send_buffer_space(),
            2 * ENTRY
        );
        for _ in 0..3 {
            pair.client_datagrams(client_ch)
                .send(Bytes::new(), false)
                .unwrap();
        }
        assert_matches!(
            pair.client_datagrams(client_ch).send(Bytes::new(), false),
            Err(SendDatagramError::Blocked(_)),
        );
    }
}

/// Tiny payloads consume their bytes plus the entry overhead, up to the exact capacity
#[test]
fn tiny_waiting_datagrams_fill_exact_capacity() {
    let _guard = subscribe();
    const ENTRY: usize = Datagrams::ENTRY_OVERHEAD;
    let mut config = client_config();
    let mut transport = TransportConfig::default();
    transport.set_datagram_send_buffer_size(2 * (ENTRY + 1));
    config.set_transport_config(transport.into());
    let mut pair = Pair::default();
    let (client_ch, _server_ch) = pair.connect_with(config);

    assert_eq!(
        pair.client_datagrams(client_ch).send_buffer_space(),
        ENTRY + 2
    );
    pair.client_datagrams(client_ch)
        .send(vec![1u8].into(), false)
        .unwrap();
    assert_eq!(pair.client_datagrams(client_ch).send_buffer_space(), 1);
    // Two bytes no longer fit, one still does
    assert_matches!(
        pair.client_datagrams(client_ch)
            .send(vec![2u8; 2].into(), false),
        Err(SendDatagramError::Blocked(_)),
    );
    pair.client_datagrams(client_ch)
        .send(vec![2u8].into(), false)
        .unwrap();
    assert_eq!(pair.client_datagrams(client_ch).send_buffer_space(), 0);
    assert_matches!(
        pair.client_datagrams(client_ch).send(Bytes::new(), false),
        Err(SendDatagramError::Blocked(_)),
    );
}

/// A large persistent-congestion threshold still permits recovery of lost packets.
#[test]
fn large_persistent_congestion_threshold_recovers_losses() {
    let _guard = subscribe();
    let mut config = client_config();
    let mut transport = TransportConfig::default();
    transport.set_persistent_congestion_threshold(u32::MAX);
    config.set_transport_config(transport.into());
    let mut pair = Pair::default();
    let (client_ch, server_ch) = pair.connect_with(config);

    let s = pair.client_streams(client_ch).open(Dir::Uni).unwrap();
    pair.client_send(client_ch, s)
        .write(&[42; octets::kib(64)])
        .unwrap();
    // Lose several flights so loss detection (and the persistent congestion check) runs
    for _ in 0..4 {
        pair.drive_client();
        pair.server.inbound.clear();
        pair.step();
    }
    pair.drive();
    assert!(
        pair.client_conn_mut(client_ch).stats().path.lost_packets > 0,
        "losses must have been detected"
    );
    assert!(!pair.client_conn_mut(client_ch).is_closed());
    assert!(!pair.server_conn_mut(server_ch).is_closed());
}

/// When path validation fails and the connection falls back to the previous path, the loss
/// detection timer is recomputed for that path instead of keeping the stale value of the
/// abandoned one.
#[test]
fn loss_timer_rearmed_after_failed_path_validation() {
    let _guard = subscribe();
    let mut pair = Pair::default();
    let (client_ch, server_ch) = pair.connect();
    pair.drive();

    // Unacknowledged, ack-eliciting data stays in flight on the original path
    let s = pair.server_streams(server_ch).open(Dir::Uni).unwrap();
    pair.server_send(server_ch, s)
        .write(b"in flight on the original path")
        .unwrap();
    pair.drive_server();
    pair.client.inbound.clear(); // lost, so it is never acknowledged

    // Client appears from a new address; the server probes it with PATH_CHALLENGE
    pair.client.addr = SocketAddr::new(
        Ipv4Addr::new(127, 0, 0, 1).into(),
        CLIENT_PORTS.lock().next().unwrap(),
    );
    pair.client_conn_mut(client_ch).ping();
    pair.drive_client();
    pair.drive_server();
    assert_eq!(
        pair.server_conn_mut(server_ch).remote_address(),
        pair.client.addr
    );
    // The new path is a black hole in both directions: the challenge and any retransmission are
    // lost, and nothing from the client reaches the server until validation gives up
    let mut challenge_lost = false;
    for _ in 0..500 {
        if !pair.client.inbound.is_empty() {
            pair.client.inbound.clear();
            challenge_lost = true;
        }
        pair.server.inbound.clear();
        if !pair.step() {
            break;
        }
        if pair.server_conn_mut(server_ch).remote_address() != pair.client.addr {
            break;
        }
    }
    assert!(challenge_lost, "the server never probed the new path");
    // Validation failed: the server is back on the previous path with an armed, fresh loss timer
    let previous_remote = pair.server_conn_mut(server_ch).remote_address();
    assert_ne!(previous_remote, pair.client.addr);
    let now = pair.time;
    let timer = pair
        .server_conn_mut(server_ch)
        .loss_detection_timer()
        .expect("loss detection timer must be armed after falling back");
    // The timer is derived from the fallback path's RTT: the lost data is due for
    // retransmission within a couple of PTOs, not left waiting on the abandoned path's schedule
    assert!(
        timer <= now + Duration::from_millis(200),
        "loss timer must be recomputed from the fallback path RTT, got {:?} ahead",
        timer.checked_duration_since(now)
    );
}

/// A lost STREAMS_BLOCKED queued for retransmission is dropped once MAX_STREAMS lifted the limit
#[test]
fn streams_blocked_not_retransmitted_after_max_streams() {
    let _guard = subscribe();
    let mut pair = streams_blocked_pair();
    let (client_ch, server_ch) = pair.connect();

    let _first = pair
        .client_streams(client_ch)
        .open(Dir::Uni)
        .expect("first uni stream");
    assert_eq!(pair.client_streams(client_ch).open(Dir::Uni), None);
    pair.drive_client();
    assert_eq!(
        pair.client_conn_mut(client_ch)
            .stats()
            .frame_tx
            .streams_blocked_uni,
        1
    );
    pair.server.inbound.clear(); // the STREAMS_BLOCKED packet is lost

    // The server raises the limit before the loss is detected
    pair.server_conn_mut(server_ch)
        .set_max_concurrent_streams(Dir::Uni, 2u32.into());
    pair.drive_server();
    pair.drive_client();
    let mut available = false;
    while let Some(event) = pair.client_conn_mut(client_ch).poll() {
        available |= matches!(
            event,
            Event::Stream(StreamEvent::Available { dir: Dir::Uni })
        );
    }
    assert!(available, "client must learn about the raised limit");

    // Recover the loss: the stale STREAMS_BLOCKED must not be announced with the new limit
    pair.drive();
    assert_eq!(
        pair.client_conn_mut(client_ch)
            .stats()
            .frame_tx
            .streams_blocked_uni,
        1,
        "no retransmission of a limit that no longer blocks"
    );
    assert_eq!(
        pair.server_conn_mut(server_ch)
            .stats()
            .frame_rx
            .streams_blocked_uni,
        0
    );
    assert!(
        pair.client_streams(client_ch).open(Dir::Uni).is_some(),
        "the raised limit allows another stream"
    );
}

/// An active migration first switches to an unused destination connection ID (RFC 9000 §9.5).
/// Once the peer's spares are used up, `migrate_local_address` declines and changes nothing; the
/// retirements reach the peer, replacement IDs come back, and migration is possible again.
#[test]
fn local_migration_requires_an_unused_destination_cid() {
    let _guard = subscribe();
    let mut pair = Pair::default();
    let (client_ch, _server_ch) = pair.connect();
    pair.drive();
    assert!(pair.client_conn_mut(client_ch).handshake_confirmed());
    let mut used = vec![pair.client_conn_mut(client_ch).active_rem_cid()];
    let mut moves = 0;
    while pair.client_conn_mut(client_ch).can_migrate_locally() {
        assert!(pair.client_migrate_local_address(client_ch));
        let cid = pair.client_conn_mut(client_ch).active_rem_cid();
        assert!(!used.contains(&cid), "each address change uses a fresh ID");
        used.push(cid);
        moves += 1;
        assert!(
            moves < crate::proto::cid_queue::CidQueue::LEN,
            "the ID budget is bounded"
        );
    }
    assert!(moves >= 1, "spare IDs exist after the handshake");
    let current = *used.last().unwrap();
    assert!(
        !pair.client_migrate_local_address(client_ch),
        "without an unused ID nothing moves"
    );
    assert_eq!(pair.client_conn_mut(client_ch).active_rem_cid(), current);
    pair.drive();
    assert!(
        pair.client_conn_mut(client_ch)
            .stats()
            .frame_tx
            .retire_connection_id
            >= moves as u64,
        "every switched-away ID was retired to the peer"
    );
    assert!(
        pair.client_conn_mut(client_ch).can_migrate_locally(),
        "the peer replenished the IDs"
    );
    assert!(pair.client_migrate_local_address(client_ch));
    assert!(!used.contains(&pair.client_conn_mut(client_ch).active_rem_cid()));
}

/// A peer using zero-length connection IDs needs no ID switch: migration is always possible and
/// the connection keeps working.
#[test]
fn zero_length_destination_cids_need_no_switch_to_migrate() {
    let _guard = subscribe();
    let factory: fn() -> Box<dyn ConnectionIdGenerator> =
        || Box::new(RandomConnectionIdGenerator::new(0).expect("zero is a length"));
    let mut pair = Pair::new(
        Arc::new(EndpointConfig {
            connection_id_generator_factory: Arc::new(factory),
            ..EndpointConfig::try_with_rand_key().unwrap()
        }),
        server_config(),
    );
    let (client_ch, server_ch) = pair.connect();
    assert!(pair.client_conn_mut(client_ch).active_rem_cid().is_empty());
    for _ in 0..3 {
        assert!(pair.client_conn_mut(client_ch).can_migrate_locally());
        assert!(pair.client_migrate_local_address(client_ch));
        assert!(pair.client_conn_mut(client_ch).active_rem_cid().is_empty());
    }
    pair.drive();
    assert!(!pair.client_conn_mut(client_ch).is_closed());
    assert!(!pair.server_conn_mut(server_ch).is_closed());
}

/// A client's handshake is complete once it has processed the server's Finished, but confirmed
/// only when HANDSHAKE_DONE arrives one round trip later.
#[test]
fn a_client_handshake_is_complete_before_it_is_confirmed() {
    let _guard = subscribe();
    let mut pair = Pair::default();
    let client_ch = pair.begin_connect(client_config());
    pair.drive_client();
    pair.drive_server();
    pair.drive_client();
    let client = pair.client_conn_mut(client_ch);
    assert!(
        !client.is_handshaking(),
        "complete: the server's Finished was processed"
    );
    assert!(
        !client.handshake_confirmed(),
        "not confirmed: no HANDSHAKE_DONE yet"
    );
    pair.drive_server();
    pair.drive_client();
    assert!(pair.client_conn_mut(client_ch).handshake_confirmed());
    // Confirmation discarded the Handshake space: its packets left the in-flight count with it.
    let (counted, outstanding) = pair.client_conn_mut(client_ch).loss_recovery_in_flight();
    assert_eq!(counted, outstanding);
}

/// A server whose peer migrates while the server still has ack-eliciting packets in flight on
/// the old path: the PTO stays meaningful across the migration (the old path's packets still
/// await acknowledgement), the timer never fires with nothing to probe, and once the peer's
/// packets get through the data is delivered.
#[test]
fn server_pto_after_a_peer_migration_with_data_in_flight_on_the_old_path() {
    let _guard = subscribe();
    let mut pair = Pair::default();
    let (client_ch, server_ch) = pair.connect();
    pair.drive();
    // Server data goes out on the old path and is lost: it stays in flight, unacknowledged.
    let s = pair.server_streams(server_ch).open(Dir::Uni).unwrap();
    pair.server_send(server_ch, s)
        .write(b"in flight on the old path")
        .unwrap();
    pair.server.drive(pair.time, pair.client.addr);
    let lost = pair.server.outbound.drain(..).count();
    assert!(lost >= 1, "the server sent its data");
    // The client moves and pings from its new address; the server migrates to it.
    pair.client.addr = SocketAddr::new(
        Ipv4Addr::new(127, 0, 0, 1).into(),
        CLIENT_PORTS.lock().next().unwrap(),
    );
    pair.client_conn_mut(client_ch).ping();
    pair.drive_client();
    pair.drive_server();
    assert_eq!(
        pair.server_conn_mut(server_ch).remote_address(),
        pair.client.addr
    );
    // Let the server's loss timers fire on their own schedule: no misfire, and the lost data is
    // recovered on the new path.
    pair.drive();
    assert!(!pair.server_conn_mut(server_ch).is_closed());
    assert!(!pair.client_conn_mut(client_ch).is_closed());
    let mut recv = pair.client_recv(client_ch, s);
    let mut chunks = recv.read(true).unwrap();
    let chunk = chunks.next(usize::MAX).unwrap().unwrap();
    assert_eq!(&chunk.bytes[..], b"in flight on the old path");
    let _transmit = chunks.finalize();
}

/// The peer moves and sends an unreliable datagram from its new address, which gives the server
/// room under the anti-amplification limit to answer on that not-yet-validated path without
/// creating anything the server would later have to send on its own (no retransmission, no flow
/// control credit); the server's challenge and its response data are lost there. The peer moves
/// again: the server discards the unvalidated intermediate path together with its congestion
/// counters and validates the newest path.
///
/// Observed in this scenario, on real packets: once the newest path has nothing ack-eliciting in
/// flight and the data has still not arrived, the discarded path's packets are still outstanding,
/// the acknowledgement of the newest path's challenge has scheduled time-threshold loss detection
/// for them, the loss timer is armed, and with nothing but timers driving the server the loss is
/// declared and the data delivered on the newest path. The connection-wide in-flight count that
/// loss recovery decides on is checked separately, after those outcomes: it equals the outstanding
/// ack-eliciting packets right after the discarding migration and at the quiet point, whatever
/// happened to their paths. Loss thresholds are raised above the recommended minimums so that the
/// challenge's acknowledgement schedules the loss instead of declaring it on arrival; otherwise the
/// quiet-path state is never reached.
#[test]
fn lost_data_is_recovered_after_a_migration_that_discards_the_intermediate_path() {
    let _guard = subscribe();
    // No MTU discovery: its probes on the new path would be acknowledged and advance the largest
    // acknowledged packet number, declaring the lost data lost by packet number right away.
    let mut server_config = server_config();
    let mut transport = TransportConfig::default();
    transport.maybe_set_mtu_discovery_config(None);
    // Loss thresholds above the recommended minimums (RFC 9002 §6.1.1 and §6.1.2 fix only those
    // minimums): with the default time threshold the acknowledgement of the newest path's
    // challenge, arriving at least a round trip after data sent before the move, declares that
    // data lost on arrival. With a time threshold of four round trips and no packet-number
    // detection it schedules the loss for later instead, so the newest path becomes quiet while
    // the data is still outstanding.
    transport.set_packet_threshold(1_000);
    transport.try_set_time_threshold(4.0).unwrap();
    server_config.set_transport_config(Arc::new(transport));
    let mut pair = Pair::new(
        Arc::new(EndpointConfig::try_with_rand_key().unwrap()),
        server_config,
    );
    // A real round trip: with zero latency the first RTT sample on a fresh path would be tiny and
    // the loss-time threshold would pass before the newest path is quiet.
    pair.latency = Duration::from_millis(400);
    let (client_ch, server_ch) = pair.connect();
    pair.drive();
    // Each move changes the IP too, so the server treats it as a new path with a fresh RTT
    // estimate rather than a NAT rebinding that inherits the old one.
    let mut hop = 1u8;
    let mut move_client = |pair: &mut Pair| {
        hop += 1;
        pair.client.addr = SocketAddr::new(
            Ipv4Addr::new(127, 0, 0, hop).into(),
            CLIENT_PORTS.lock().next().unwrap(),
        );
        pair.client_conn_mut(client_ch).ping();
    };
    // First move, with a large unreliable datagram from the new address to lift the server's
    // amplification limit there; everything the server answers on that path is lost.
    move_client(&mut pair);
    let filler = pair
        .client_datagrams(client_ch)
        .max_size()
        .unwrap()
        .min(1100);
    pair.client_datagrams(client_ch)
        .send(Bytes::from(vec![0x42; filler]), false)
        .unwrap();
    pair.drive_client();
    pair.time += pair.latency;
    pair.server.drive(pair.time, pair.client.addr);
    pair.server.outbound.clear();
    assert_eq!(
        pair.server_conn_mut(server_ch).remote_address(),
        pair.client.addr
    );
    // Server data goes out on the unvalidated intermediate path and is lost.
    let s = pair.server_streams(server_ch).open(Dir::Uni).unwrap();
    pair.server_send(server_ch, s)
        .write(b"lost on the discarded path")
        .unwrap();
    let stream_frames_before = pair.server_conn_mut(server_ch).stats().frame_tx.stream;
    // The fresh path paces its first packets; give the server's clock a few milliseconds.
    for _ in 0..50 {
        pair.server.drive(pair.time, pair.client.addr);
        if pair.server_conn_mut(server_ch).stats().frame_tx.stream > stream_frames_before {
            break;
        }
        pair.time += Duration::from_millis(1);
    }
    pair.server.outbound.clear();
    assert!(
        pair.server_conn_mut(server_ch).stats().frame_tx.stream > stream_frames_before,
        "the data left on the intermediate path"
    );
    // Second move: the unvalidated intermediate path is discarded. Let real packets flow (the
    // newest path's challenge, response and acknowledgements) until that path has nothing
    // ack-eliciting in flight; the loop is bounded and also stops should the data arrive early.
    move_client(&mut pair);
    pair.drive_client();
    pair.time += pair.latency;
    pair.drive_server();
    assert_eq!(
        pair.server_conn_mut(server_ch).remote_address(),
        pair.client.addr
    );
    // The intermediate path is gone; the packets it carried are still outstanding. The count
    // loss recovery decides on is recorded here and checked at the end, after the observable
    // outcome (timer, delivery) has been judged.
    let after_discard = pair.server_conn_mut(server_ch).loss_recovery_in_flight();
    assert!(
        after_discard.1 >= 2,
        "the lost data and the challenge are outstanding: {}",
        after_discard.1
    );
    // Reading consumes the data, so whatever arrives is kept for the final check.
    let mut received: Option<Bytes> = None;
    let take_arrival = |pair: &mut Pair, received: &mut Option<Bytes>| -> bool {
        if received.is_none() {
            let mut recv = pair.client_recv(client_ch, s);
            let mut chunks = recv.read(true).unwrap();
            if let Ok(Some(chunk)) = chunks.next(usize::MAX) {
                *received = Some(chunk.bytes);
            }
            let _transmit = chunks.finalize();
        }
        received.is_some()
    };
    let moved_at = pair.time;
    while pair
        .server_conn_mut(server_ch)
        .current_path_in_flight_ack_eliciting()
        > 0
        && !take_arrival(&mut pair, &mut received)
        && pair.time.saturating_duration_since(moved_at) < 20 * pair.latency
        && pair.step()
    {}
    let lost_before = pair.server_conn_mut(server_ch).stats().path.lost_packets;
    let quiet = pair.server_conn_mut(server_ch).loss_recovery_in_flight();
    // The quiet-path state is a prerequisite of what follows, so it is asserted, not assumed:
    // the data has not arrived, the newest path (validated) has nothing in flight, the discarded
    // path's packets are still outstanding and older than the acknowledged challenge, so
    // time-threshold detection is scheduled for them and the loss timer is armed.
    assert!(
        !take_arrival(&mut pair, &mut received),
        "the data must still be missing when the newest path goes quiet"
    );
    assert_eq!(
        pair.server_conn_mut(server_ch)
            .current_path_in_flight_ack_eliciting(),
        0,
        "the newest path has nothing in flight"
    );
    assert!(quiet.1 >= 1, "the lost data is still outstanding");
    assert!(
        pair.server_conn_mut(server_ch).loss_time_pending(),
        "the challenge's acknowledgement scheduled time-threshold detection for the older packets"
    );
    assert!(
        pair.server_conn_mut(server_ch).loss_detection_armed(),
        "the loss timer is armed for the discarded path's packets"
    );
    // From here nothing but timers drives the server: the loss is declared when the time
    // threshold passes, the data is retransmitted on the newest path and delivered within
    // bounded steps.
    assert!(
        !pair.drive_bounded(),
        "the connection settles within bounded steps"
    );
    assert!(!pair.server_conn_mut(server_ch).is_closed());
    assert!(
        pair.server_conn_mut(server_ch).stats().path.lost_packets > lost_before,
        "the discarded path's packets were declared lost and retransmitted"
    );
    assert!(
        take_arrival(&mut pair, &mut received),
        "the data lost on the discarded path was retransmitted"
    );
    assert_eq!(
        &received.expect("received")[..],
        b"lost on the discarded path"
    );
    // The accounting behind those outcomes: loss recovery counted every outstanding
    // ack-eliciting packet, discarded path included, at both observation points.
    assert_eq!(
        after_discard.0, after_discard.1,
        "right after the discarding migration"
    );
    assert_eq!(quiet.0, quiet.1, "once the newest path was quiet");
}

/// RFC 9000 §10.3.1 for a candidate path: the identifier a probe of the preferred address was
/// sent with is in use, so a stateless reset from that address carrying its token resets the
/// connection. Once the attempt is given up and the identifier retired, the same reset is
/// nothing to us.
#[test]
fn a_reset_for_the_probed_identifier_counts_until_the_attempt_ends() {
    let _guard = subscribe();
    let probing = |pair: &mut Pair, server_ch: ConnectionHandle| {
        probe_once(pair, server_ch);
        pair.server.outbound.clear();
        // One more pass, so the endpoint takes in the association the transmitted probe made.
        pair.client.drive(pair.time, pair.server.addr);
    };

    // While the probe is outstanding the identifier it went out with can reset us.
    let (mut pair, key, preferred) = pair_preferring_with_key();
    let (ch, server_ch) = connect_armed(&mut pair);
    probing(&mut pair, server_ch);
    let probed = pair
        .client_conn_mut(ch)
        .reserved_rem_cid()
        .expect("an identifier is reserved for the candidate path");
    assert_eq!(
        pair.client_conn_mut(ch)
            .stats()
            .path
            .preferred_address_probes,
        1
    );
    pair.client.inbound.push_back(Inbound {
        at: pair.time,
        ecn: None,
        packet: stateless_reset_for(&key, probed).as_slice().into(),
        from: Some(preferred),
        to: Some(pair.client.addr),
    });
    pair.client.drive(pair.time, pair.server.addr);
    assert!(
        was_reset(pair.client_conn_mut(ch)),
        "the identifier the probe used is in use"
    );

    // Once the attempt is given up, that identifier is retired and the same reset means nothing.
    let (mut pair, key, preferred) = pair_preferring_with_key();
    let (ch, server_ch) = connect_armed(&mut pair);
    probing(&mut pair, server_ch);
    let probed = pair
        .client_conn_mut(ch)
        .reserved_rem_cid()
        .expect("reserved");
    drive_settled(&mut pair);
    assert_eq!(
        pair.client_conn_mut(ch).preferred_address_state(),
        PreferredAddressState::Failed
    );
    pair.client.inbound.push_back(Inbound {
        at: pair.time,
        ecn: None,
        packet: stateless_reset_for(&key, probed).as_slice().into(),
        from: Some(preferred),
        to: Some(pair.client.addr),
    });
    pair.client.drive(pair.time, pair.server.addr);
    assert!(!was_reset(pair.client_conn_mut(ch)));
    assert!(!pair.client_conn_mut(ch).is_closed());
    let s = pair.client_streams(ch).open(Dir::Uni).unwrap();
    pair.client_send(ch, s).write(b"still here").unwrap();
    drive_settled(&mut pair);
    assert!(saw_uni_stream(pair.server_conn_mut(server_ch)));
}

/// RFC 9000 §5.1.2: an identifier the peer retires while a probe of the preferred address is
/// outstanding is gone, and it takes that probe with it. The attempt starts over with another
/// identifier, nothing is addressed with the retired one again, and the answer to the challenge
/// it carried no longer moves us anywhere.
#[test]
fn an_identifier_the_peer_retires_between_probes_takes_its_probe_with_it() {
    let _guard = subscribe();

    // Control: with nothing retired, that same held-back answer validates the candidate path. So
    // what the retirement changes below is the outcome, not whether the answer arrives at all.
    {
        let (mut pair, preferred) = pair_preferring(true);
        let (ch, server_ch) = connect_armed(&mut pair);
        probe_once(&mut pair, server_ch);
        let answer: Vec<_> = pair.server.outbound.drain(..).collect();
        deliver_to_client(&mut pair, answer);
        pair.client.drive(pair.time, pair.server.addr);
        assert_eq!(
            pair.client_conn_mut(ch).preferred_address_state(),
            PreferredAddressState::Validated
        );
        assert_eq!(pair.client_conn_mut(ch).remote_address(), preferred);
    }

    let (mut pair, preferred) = pair_preferring(true);
    let (ch, server_ch) = connect_armed(&mut pair);
    probe_once(&mut pair, server_ch);

    let probed = pair
        .client_conn_mut(ch)
        .reserved_rem_cid()
        .expect("an identifier is reserved for the candidate path");
    let probed_seq = pair
        .client_sent
        .iter()
        .find_map(|s| (s.to == preferred).then_some(s.cid))
        .expect("the client probed the preferred address")
        .expect("a probe names the identifier it went out with");
    assert_eq!(sent_with(&pair, probed_seq), 1, "one probe, one identifier");

    // The server's answer to that probe, held back so that the retirement overtakes it.
    let answer: Vec<_> = pair.server.outbound.drain(..).collect();
    assert!(!answer.is_empty(), "the server answered the probe");

    // The peer retires every identifier up to and including the probed one.
    let now = pair.time;
    pair.server_conn_mut(server_ch)
        .rotate_local_cid(probed_seq + 1, now);
    pair.drive_server();
    pair.drive_client();

    assert!(
        pair.client_conn_mut(ch).active_rem_cid_seq() > probed_seq,
        "the connection moved off every identifier the retirement covered"
    );
    let restarted = pair
        .client_conn_mut(ch)
        .reserved_rem_cid()
        .expect("the attempt starts over");
    assert_ne!(restarted, probed, "with an identifier we still hold");
    assert_eq!(
        pair.client_conn_mut(ch).preferred_address_state(),
        PreferredAddressState::Probing
    );

    // The answer to the challenge the retired identifier carried arrives now.
    deliver_to_client(&mut pair, answer);
    pair.client.drive(pair.time, pair.server.addr);
    assert_ne!(
        pair.client_conn_mut(ch).preferred_address_state(),
        PreferredAddressState::Validated,
        "an answer to a probe that is gone validates nothing"
    );
    assert_eq!(
        pair.client_conn_mut(ch).remote_address(),
        pair.server.addr,
        "and moves the connection nowhere"
    );

    // Nothing more went out with the retired identifier, then or since. Only the client is
    // driven from here on, so what it sends is all that decides this and nothing can come back:
    // the pair is deliberately not driven to idle, because an in-flight datagram carrying an
    // identifier the peer has just retired draws a stateless reset from it, which is reported
    // separately and is not what this test is about.
    for _ in 0..32 {
        pair.time += Duration::from_millis(10);
        pair.drive_client();
    }
    assert_eq!(
        sent_with(&pair, probed_seq),
        1,
        "the retired identifier was used once, before it was retired"
    );
    assert!(
        !pair.client_conn_mut(ch).is_closed(),
        "the connection itself is unharmed: {:?}",
        std::iter::from_fn(|| pair.client_conn_mut(ch).poll()).collect::<Vec<_>>()
    );
}

/// RFC 9000 §10.3.1 binds recognition to the identifier *and* the address it was sent to. The
/// probe's identifier went to the preferred address and nowhere else, so a reset carrying its
/// token is ours from there and is not ours from the address the connection is on. Both datagrams
/// are addressed to one of our own identifiers, so the endpoint hands both to this connection.
/// Once the attempt is given up and the identifier retired, neither is ours.
#[test]
fn the_token_of_a_probed_identifier_is_recognised_only_from_where_it_was_sent() {
    let _guard = subscribe();
    let probed_pair = || {
        let (mut pair, key, preferred) = pair_preferring_with_key();
        let (ch, server_ch) = connect_armed(&mut pair);
        probe_once(&mut pair, server_ch);
        pair.server.outbound.clear();
        // One more pass, so the endpoint takes in the association the transmitted probe made.
        pair.client.drive(pair.time, pair.server.addr);
        let probed = pair
            .client_conn_mut(ch)
            .reserved_rem_cid()
            .expect("an identifier is reserved for the candidate path");
        let probed_seq = pair
            .client_sent
            .iter()
            .find_map(|s| (s.to == preferred).then_some(s.cid))
            .expect("the client probed the preferred address")
            .expect("a probe names the identifier it went out with");
        assert!(
            pair.client_conn_mut(ch).cid_confirmed(probed_seq),
            "the probe left, so the identifier has been used"
        );
        (pair, key, ch, server_ch, probed, probed_seq, preferred)
    };
    let deliver = |pair: &mut Pair, packet: &[u8], from: SocketAddr| {
        pair.client.inbound.push_back(Inbound {
            at: pair.time,
            ecn: None,
            packet: packet.into(),
            from: Some(from),
            to: Some(pair.client.addr),
        });
        pair.client.drive(pair.time, pair.server.addr);
    };

    // From the address the probe went to: ours.
    let (mut pair, key, ch, _server_ch, probed, _, preferred) = probed_pair();
    let packet = routed_reset_for(&pair.client, ch, &key, probed);
    deliver(&mut pair, &packet, preferred);
    assert!(
        was_reset(pair.client_conn_mut(ch)),
        "an identifier we sent to that address, in a datagram that reaches us"
    );

    // The same datagram from the address the connection is on, where that identifier was never
    // sent: not ours, and the connection carries on.
    let (mut pair, key, ch, server_ch, probed, _, _) = probed_pair();
    let server_addr = pair.server.addr;
    let packet = routed_reset_for(&pair.client, ch, &key, probed);
    deliver(&mut pair, &packet, server_addr);
    assert!(
        !was_reset(pair.client_conn_mut(ch)),
        "a token for an identifier never sent to that address is not ours"
    );
    assert!(!pair.client_conn_mut(ch).is_closed());
    let s = pair.client_streams(ch).open(Dir::Uni).unwrap();
    pair.client_send(ch, s).write(b"still here").unwrap();
    drive_settled(&mut pair);
    assert!(saw_uni_stream(pair.server_conn_mut(server_ch)));

    // Once the attempt is given up the identifier is retired, and neither route is ours.
    for from in [preferred, server_addr] {
        let (mut pair, key, ch, server_ch, probed, probed_seq, _) = probed_pair();
        let packet = routed_reset_for(&pair.client, ch, &key, probed);
        drive_settled(&mut pair);
        assert_eq!(
            pair.client_conn_mut(ch).preferred_address_state(),
            PreferredAddressState::Failed,
            "the attempt is over"
        );
        assert!(
            !pair.client_conn_mut(ch).cid_confirmed(probed_seq),
            "a retired identifier has no history left"
        );
        let from = if from == preferred {
            preferred
        } else {
            pair.server.addr
        };
        let probes = sent_with(&pair, probed_seq);
        assert!(probes >= 1, "the probes went out");
        deliver(&mut pair, &packet, from);
        assert!(
            !was_reset(pair.client_conn_mut(ch)),
            "a retired identifier resets nothing, from {from}"
        );
        assert!(!pair.client_conn_mut(ch).is_closed());
        let s = pair.client_streams(ch).open(Dir::Uni).unwrap();
        pair.client_send(ch, s).write(b"still here").unwrap();
        drive_settled(&mut pair);
        assert!(saw_uni_stream(pair.server_conn_mut(server_ch)));
        assert_eq!(
            sent_with(&pair, probed_seq),
            probes,
            "and the retired identifier carried nothing after the attempt ended"
        );
    }
}

/// A client whose own connection IDs are zero length is routed by its address, so it stays where
/// it is: a preferred address is neither probed nor armed (RFC 9000 §9).
#[test]
fn a_client_with_zero_length_ids_does_not_move_to_a_preferred_address() {
    let _guard = subscribe();
    let mut config = server_config();
    let alt = SocketAddrV6::new(
        Ipv6Addr::LOCALHOST,
        SERVER_PORTS.lock().next().unwrap(),
        0,
        0,
    );
    config.set_preferred_address_v6(alt);
    // The client's own identifiers are zero length; the server's are not.
    let mut client_config_endpoint = EndpointConfig::try_with_rand_key().unwrap();
    client_config_endpoint.set_cid_generator(Arc::new(|| {
        Box::new(RandomConnectionIdGenerator::new(0).expect("zero is a length"))
    }));
    let client = Endpoint::new(Arc::new(client_config_endpoint), None, true, None);
    let server = Endpoint::new(
        Arc::new(EndpointConfig::try_with_rand_key().unwrap()),
        Some(Arc::new(config)),
        true,
        None,
    );
    let mut pair = Pair::new_from_endpoint(client, server);
    pair.server.alt_addr = Some(alt.into());
    let ch = pair.begin_connect(client_config());
    drive_settled(&mut pair);
    let server_ch = pair.server.assert_accept();
    drive_settled(&mut pair);

    assert_eq!(
        pair.client_conn_mut(ch).preferred_address_state(),
        PreferredAddressState::Unused
    );
    assert_eq!(
        pair.client_conn_mut(ch)
            .stats()
            .path
            .preferred_address_probes,
        0
    );
    assert_eq!(addressed_to(&pair, alt.into()), 0);
    assert_ne!(
        pair.client_conn_mut(ch).remote_address(),
        SocketAddr::from(alt)
    );
    // The connection itself is unaffected.
    let s = pair.client_streams(ch).open(Dir::Uni).unwrap();
    pair.client_send(ch, s).write(b"staying here").unwrap();
    drive_settled(&mut pair);
    assert!(saw_uni_stream(pair.server_conn_mut(server_ch)));
    assert!(!pair.client_conn_mut(ch).is_closed());
}

/// A server whose own connection IDs are zero length cannot issue one for a preferred address, so
/// it advertises none however it is configured, and the handshake is unaffected (RFC 9000 §5.1.1).
#[test]
fn a_server_with_zero_length_ids_advertises_no_preferred_address() {
    let _guard = subscribe();
    let mut config = server_config();
    let alt = SocketAddrV6::new(
        Ipv6Addr::LOCALHOST,
        SERVER_PORTS.lock().next().unwrap(),
        0,
        0,
    );
    config.set_preferred_address_v6(alt);
    let cid_generator_factory: fn() -> Box<dyn ConnectionIdGenerator> =
        || Box::new(RandomConnectionIdGenerator::new(0).expect("zero is a length"));
    let mut pair = Pair::new(
        Arc::new(EndpointConfig {
            connection_id_generator_factory: Arc::new(cid_generator_factory),
            ..EndpointConfig::try_with_rand_key().unwrap()
        }),
        config,
    );
    pair.server.alt_addr = Some(alt.into());
    let (client_ch, server_ch) = pair.connect();
    drive_settled(&mut pair);
    assert_eq!(
        pair.client_conn_mut(client_ch).preferred_address_state(),
        PreferredAddressState::Unused
    );
    assert_eq!(addressed_to(&pair, alt.into()), 0);
    let s = pair.client_streams(client_ch).open(Dir::Uni).unwrap();
    pair.client_send(client_ch, s).write(b"unmoved").unwrap();
    drive_settled(&mut pair);
    assert!(saw_uni_stream(pair.server_conn_mut(server_ch)));
    assert!(!pair.client_conn_mut(client_ch).is_closed());
}

/// A frame that a seam withholds must not be announced as sendable: the connection stops
/// transmitting instead of producing packet after packet with nothing in them.
#[test]
fn a_withheld_handshake_done_leaves_nothing_to_send() {
    let _guard = subscribe();
    let mut pair = Pair::default();
    let ch = pair.begin_connect(client_config());
    pair.step();
    let server_ch = pair.server.assert_accept();
    pair.server_conn_mut(server_ch).hold_handshake_done(true);
    drive_settled(&mut pair);

    let now = pair.time;
    let mut buf = Vec::new();
    for _ in 0..4 {
        assert!(
            pair.server_conn_mut(server_ch)
                .poll_transmit(now, 1, &mut buf)
                .is_none(),
            "nothing is left to send while the frame is withheld"
        );
        buf.clear();
    }
    assert!(!pair.client_conn_mut(ch).is_closed());

    // Releasing it hands the frame over, and the client's handshake is confirmed.
    pair.server_conn_mut(server_ch).hold_handshake_done(false);
    drive_settled(&mut pair);
    let mut confirmed = false;
    while let Some(event) = pair.client_conn_mut(ch).poll() {
        confirmed |= matches!(event, Event::HandshakeConfirmed);
    }
    assert!(confirmed, "the released frame confirms the handshake");
}

/// A pair whose server advertises a second address of its own as preferred and receives there.
fn pair_preferring(alt_reachable: bool) -> (Pair, SocketAddr) {
    let mut config = server_config();
    let alt = SocketAddrV6::new(
        Ipv6Addr::LOCALHOST,
        SERVER_PORTS.lock().next().unwrap(),
        0,
        0,
    );
    config.set_preferred_address_v6(alt);
    let mut pair = Pair::new(
        Arc::new(EndpointConfig::try_with_rand_key().unwrap()),
        config,
    );
    if alt_reachable {
        pair.server.alt_addr = Some(alt.into());
    }
    (pair, alt.into())
}

/// A server that forbids active migration discards non-probing traffic from a new peer address
/// (RFC 9000 §9, §18.2). The discard is observed by the connection's received-datagram counter,
/// which does not move, and the connection stays on the path it had.
#[test]
fn a_server_that_forbids_migration_discards_traffic_from_a_new_peer_address() {
    let _guard = subscribe();
    let mut config = server_config();
    config.set_migration(false);
    let mut pair = Pair::new(
        Arc::new(EndpointConfig::try_with_rand_key().unwrap()),
        config,
    );
    let client_ch = pair.begin_connect(client_config());
    pair.step();
    let server_ch = pair.server.assert_accept();
    drive_settled(&mut pair);
    let home = pair.client.addr;
    let seen = pair.server_conn_mut(server_ch).stats().udp_rx.datagrams;

    // The peer's address changes and it sends ordinary traffic from there.
    let moved = SocketAddr::new(
        Ipv4Addr::new(127, 0, 0, 7).into(),
        CLIENT_PORTS.lock().next().unwrap(),
    );
    pair.client.addr = moved;
    pair.client_conn_mut(client_ch).ping();
    // The send queue is emptied first, so what is in it afterwards belongs to this window.
    // `pair.server_sent` is written by `Pair::drive_server`, which this test does not call.
    pair.server.outbound.clear();
    pair.drive_client();
    assert!(
        !pair.server.inbound.is_empty(),
        "the datagram from the new address reached the server's receive queue"
    );
    pair.server.drive(pair.time, moved);
    assert!(pair.server.inbound.is_empty(), "and was taken from it");
    assert_eq!(
        pair.server_conn_mut(server_ch).stats().udp_rx.datagrams,
        seen,
        "the connection discarded it rather than processing it"
    );
    assert_eq!(
        pair.server_conn_mut(server_ch).remote_address(),
        home,
        "the connection stays on the path it had"
    );
    let to_moved: Vec<_> = pair
        .server
        .outbound
        .iter()
        .map(|(transmit, _)| transmit.destination)
        .filter(|destination| *destination == moved)
        .collect();
    assert!(
        to_moved.is_empty(),
        "and nothing was queued for the address it refused: {to_moved:?}"
    );
    assert!(!pair.server_conn_mut(server_ch).is_closed());

    // The connection is unharmed: traffic from the address it knows is processed as before.
    pair.client.addr = home;
    pair.client_conn_mut(client_ch).ping();
    pair.server.outbound.clear();
    pair.drive_client();
    pair.server.drive(pair.time, home);
    assert!(
        pair.server_conn_mut(server_ch).stats().udp_rx.datagrams > seen,
        "traffic on the original path still arrives"
    );
    // The same queue holds the answer to that traffic, which is what makes the emptiness
    // asserted above a refusal to answer.
    assert!(
        pair.server
            .outbound
            .iter()
            .any(|(transmit, _)| transmit.destination == home),
        "the server answered on the path it kept"
    );
    assert!(!pair.server_conn_mut(server_ch).is_closed());
}

/// A switch of our own to a distant identifier, through the connection: the identifier it was
/// using is named for retirement, the numbers it never received are named up to the bound, the
/// bounded retirement queue is not overrun and the connection stays open. Naming the whole span
/// would defer a CONNECTION_ID_LIMIT_ERROR and end the connection over numbers it never held.
#[test]
fn a_distant_switch_names_a_bounded_set_of_numbers() {
    let _guard = subscribe();
    let mut pair = Pair::default();
    let (client_ch, _server_ch) = pair.connect();
    drive_settled(&mut pair);

    // Spend the identifiers the peer issued, so the distant one is the only unused one left.
    let mut moves = 0;
    while pair.client_migrate_local_address(client_ch) {
        moves += 1;
        assert!(
            moves < 16,
            "the peer's identifiers are spent in a bounded number of moves"
        );
    }
    let now = pair.time;
    let far = (1u64 << 40) + 7;
    pair.client_conn_mut(client_ch)
        .apply_new_cid(
            now,
            frame::NewConnectionId {
                sequence: far,
                retire_prior_to: 0,
                id: ConnectionId::new(&[0x6A; 8]),
                reset_token: ResetToken::from([0x6B; rama_quic_proto::RESET_TOKEN_SIZE]),
            },
        )
        .expect("a distant identifier is legal");

    let in_use = pair.client_conn_mut(client_ch).active_rem_cid_seq();
    assert!(
        pair.client_migrate_local_address(client_ch),
        "the distant identifier is the one left to take"
    );
    assert_eq!(pair.client_conn_mut(client_ch).active_rem_cid_seq(), far);
    let pending = pair.client_conn_mut(client_ch).pending_retirements();
    assert!(
        pending.contains(&in_use),
        "the identifier the connection was using is named: {pending:?}"
    );
    assert!(
        pending.len() <= crate::proto::cid_queue::CidQueue::LEN * 10,
        "the queue holds a bounded set: {} numbers",
        pending.len()
    );
    assert!(
        !pending.contains(&(far - 1)),
        "the numbers nearest the distant one are not named: {pending:?}"
    );

    // No retirement error was deferred: nothing closed the connection while the queue drained.
    // The identifier itself came from this test, not from the peer's endpoint, so nothing here
    // says data can be carried with it.
    drive_settled(&mut pair);
    assert!(!pair.client_conn_mut(client_ch).is_closed());
}

/// A peer that jumps its sequence numbers far ahead, through the whole path a frame takes: the
/// identifiers set aside, the unused ones, the switch and the numbers never received all reach the
/// connection's bounded retirement queue. Every identifier the connection received is named, the
/// numbers it never received are named up to `CidQueue::LEN` from the floor, and the connection
/// stays open. Naming the whole span would overrun the queue and close the connection with
/// CONNECTION_ID_LIMIT_ERROR over identifiers it never held.
#[test]
fn a_distant_retirement_names_a_bounded_set_of_numbers() {
    let _guard = subscribe();
    let mut pair = Pair::default();
    let (client_ch, _server_ch) = pair.connect();
    drive_settled(&mut pair);
    let in_use = pair.client_conn_mut(client_ch).active_rem_cid_seq();
    let received: Vec<u64> = (0..=in_use).collect();
    let unused: Vec<u64> = pair
        .client_conn_mut(client_ch)
        .unused_rem_cid_seqs()
        .into_iter()
        .collect();
    let now = pair.time;

    let far = 1u64 << 40;
    pair.client_conn_mut(client_ch)
        .apply_new_cid(
            now,
            frame::NewConnectionId {
                sequence: far,
                retire_prior_to: far,
                id: ConnectionId::new(&[0x5A; 8]),
                reset_token: ResetToken::from([0x5B; rama_quic_proto::RESET_TOKEN_SIZE]),
            },
        )
        .expect("a distant frame is applied rather than closing the connection");
    let pending = pair.client_conn_mut(client_ch).pending_retirements();

    assert_eq!(
        pair.client_conn_mut(client_ch).active_rem_cid_seq(),
        far,
        "the identifier the frame carried is the one in use"
    );
    for seq in received.iter().chain(unused.iter()) {
        assert!(
            pending.contains(seq),
            "the identifier {seq} this connection received is named for retirement: {pending:?}"
        );
    }
    let limit = crate::proto::cid_queue::CidQueue::LEN;
    assert!(
        pending.len() <= limit * 10,
        "the queue holds a bounded set: {} numbers",
        pending.len()
    );
    assert!(
        !pending.contains(&(far - 1)),
        "the numbers nearest the distant one are not named: {pending:?}"
    );
    assert!(!pair.client_conn_mut(client_ch).is_closed());

    // One of those numbers arriving late is refused as retired, which is what retires it then.
    let late = *pending.last().expect("something is named") + 1;
    let error = pair
        .client_conn_mut(client_ch)
        .apply_new_cid(
            now,
            frame::NewConnectionId {
                sequence: late,
                retire_prior_to: 0,
                id: ConnectionId::new(&[0x5C; 8]),
                reset_token: ResetToken::from([0x5D; rama_quic_proto::RESET_TOKEN_SIZE]),
            },
        )
        .err();
    assert!(
        error.is_none(),
        "a refused frame is not a connection error: {error:?}"
    );
    assert!(
        pair.client_conn_mut(client_ch)
            .pending_retirements()
            .contains(&late),
        "the late arrival is named for retirement"
    );
    assert!(!pair.client_conn_mut(client_ch).is_closed());
}

/// RFC 9000 §18.2 and §9.6.3: `disable_active_migration` covers the address used during the
/// handshake, and neither the client's move to the server's preferred address nor its later moves
/// from there are prohibited. The server forbids active migration and advertises a preferred
/// address. Checks: the client moves there, the server follows on its local side, data flows both
/// ways, and the server follows a later rebinding of the client.
#[test]
fn a_move_to_the_preferred_address_is_followed_though_active_migration_is_disabled() {
    let _guard = subscribe();
    let mut config = server_config();
    let alt = SocketAddrV6::new(
        Ipv6Addr::LOCALHOST,
        SERVER_PORTS.lock().next().unwrap(),
        0,
        0,
    );
    config.set_preferred_address_v6(alt);
    config.set_migration(false);
    let mut pair = Pair::new(
        Arc::new(EndpointConfig::try_with_rand_key().unwrap()),
        config,
    );
    pair.server.alt_addr = Some(alt.into());
    let preferred: SocketAddr = alt.into();

    // The peer's parameter binds the client until it acts on the preferred address.
    let (ch, server_ch) = connect_armed(&mut pair);
    let client_addr = pair.client.addr;
    assert!(
        !pair.client_conn_mut(ch).may_migrate_actively(),
        "the peer forbids active migration from the handshake address"
    );

    pair.server_conn_mut(server_ch).hold_handshake_done(false);
    drive_settled(&mut pair);
    assert_eq!(
        pair.client_conn_mut(ch).preferred_address_state(),
        PreferredAddressState::Validated
    );
    assert_eq!(pair.client_conn_mut(ch).remote_address(), preferred);
    assert_eq!(
        pair.server_conn_mut(server_ch).remote_address(),
        client_addr,
        "the peer's own address has not changed"
    );
    assert!(
        pair.client_conn_mut(ch).may_migrate_actively(),
        "and having moved there, the client may migrate from it"
    );

    // The server's datagrams now leave from the preferred address.
    let sent_before = pair.server_sent.len();
    const DOWN: &[u8] = b"from the preferred address";
    let down = pair.server_streams(server_ch).open(Dir::Uni).unwrap();
    pair.server_send(server_ch, down).write(DOWN).unwrap();
    pair.server_send(server_ch, down).finish().unwrap();
    drive_settled(&mut pair);
    let locals: Vec<_> = pair.server_sent[sent_before..]
        .iter()
        .map(|sent| sent.local)
        .collect();
    assert!(
        !locals.is_empty() && locals.iter().all(|local| *local == Some(preferred)),
        "every datagram left from the preferred address: {locals:?}"
    );
    assert!(saw_uni_stream(pair.client_conn_mut(ch)));
    let mut recv = pair.client_recv(ch, down);
    let mut chunks = recv.read(false).unwrap();
    match chunks.next(usize::MAX) {
        Ok(Some(chunk)) if chunk.offset == 0 && chunk.bytes == DOWN => {}
        other => panic!("the client received {other:?}"),
    }
    let _transmit = chunks.finalize();

    // The client's own address changes from there, and the server follows it.
    let rebound = SocketAddr::new(
        Ipv4Addr::new(127, 0, 0, 7).into(),
        CLIENT_PORTS.lock().next().unwrap(),
    );
    pair.client.addr = rebound;
    assert!(pair.client_migrate_local_address(ch));
    drive_settled(&mut pair);
    assert_eq!(
        pair.server_conn_mut(server_ch).remote_address(),
        rebound,
        "the server followed the client's move away from the handshake address"
    );
    assert_eq!(pair.client_conn_mut(ch).remote_address(), preferred);

    // Data flows in both directions on the path both sides hold.
    const UP: &[u8] = b"after the rebinding";
    let up = pair.client_streams(ch).open(Dir::Uni).unwrap();
    pair.client_send(ch, up).write(UP).unwrap();
    pair.client_send(ch, up).finish().unwrap();
    drive_settled(&mut pair);
    assert!(saw_uni_stream(pair.server_conn_mut(server_ch)));
    let mut recv = pair.server_recv(server_ch, up);
    let mut chunks = recv.read(false).unwrap();
    match chunks.next(usize::MAX) {
        Ok(Some(chunk)) if chunk.offset == 0 && chunk.bytes == UP => {}
        other => panic!("the server received {other:?}"),
    }
    let _transmit = chunks.finalize();
    assert!(!pair.client_conn_mut(ch).is_closed());
    assert!(!pair.server_conn_mut(server_ch).is_closed());
}

/// The handshake-done fixture covers the phase before the frame has been sent: setting it again
/// afterwards recalls nothing, and the connection stays confirmed and usable.
#[test]
fn the_handshake_done_seam_only_covers_the_phase_before_the_frame_is_sent() {
    let _guard = subscribe();
    let mut pair = Pair::default();
    let ch = pair.begin_connect(client_config());
    pair.step();
    let server_ch = pair.server.assert_accept();
    pair.server_conn_mut(server_ch).hold_handshake_done(true);
    drive_settled(&mut pair);
    let mut confirmed = false;
    while let Some(event) = pair.client_conn_mut(ch).poll() {
        confirmed |= matches!(event, Event::HandshakeConfirmed);
    }
    assert!(!confirmed, "held: the client is complete but not confirmed");

    pair.server_conn_mut(server_ch).hold_handshake_done(false);
    drive_settled(&mut pair);
    while let Some(event) = pair.client_conn_mut(ch).poll() {
        confirmed |= matches!(event, Event::HandshakeConfirmed);
    }
    assert!(confirmed, "released: the frame arrives");

    // Setting it again cannot take back a frame that has gone.
    pair.server_conn_mut(server_ch).hold_handshake_done(true);
    let s = pair.server_streams(server_ch).open(Dir::Uni).unwrap();
    pair.server_send(server_ch, s).write(b"still ours").unwrap();
    drive_settled(&mut pair);
    assert!(saw_uni_stream(pair.client_conn_mut(ch)));
    assert!(!pair.client_conn_mut(ch).is_closed());
    assert!(!pair.server_conn_mut(server_ch).is_closed());
}

/// A pair whose endpoints share a known reset key and whose server advertises a preferred address
/// that nothing answers at, so tests can forge resets from it.
fn pair_preferring_with_key() -> (Pair, HmacSha2, SocketAddr) {
    let key = HmacSha2::new_256(&[0x44; 32]);
    let key_copy = HmacSha2::new_256(&[0x44; 32]);
    let mut config = server_config();
    let alt = SocketAddrV6::new(
        Ipv6Addr::LOCALHOST,
        SERVER_PORTS.lock().next().unwrap(),
        0,
        0,
    );
    config.set_preferred_address_v6(alt);
    let endpoint_config = Arc::new(EndpointConfig::new(key));
    let mut pair = Pair::new(endpoint_config, config);
    pair.server.hide_local = true;
    (pair, key_copy, alt.into())
}

/// A connected pair whose client knows the preferred address but has not probed it yet: the
/// server's HANDSHAKE_DONE is held back, so probing starts when the test releases it.
fn connect_armed(pair: &mut Pair) -> (ConnectionHandle, ConnectionHandle) {
    let ch = pair.begin_connect(client_config());
    pair.step();
    let server_ch = pair.server.assert_accept();
    pair.server_conn_mut(server_ch).hold_handshake_done(true);
    drive_settled(pair);
    assert_eq!(
        pair.client_conn_mut(ch).preferred_address_state(),
        PreferredAddressState::Armed
    );
    assert!(pair.client_conn_mut(ch).reserved_rem_cid().is_none());
    (ch, server_ch)
}

/// Let the client confirm the handshake and transmit its first probe, without delivering the
/// server's answer.
fn probe_once(pair: &mut Pair, server_ch: ConnectionHandle) {
    pair.server_conn_mut(server_ch).hold_handshake_done(false);
    pair.drive_server();
    pair.drive_client();
    pair.server.drive(pair.time, pair.client.addr);
}

/// Whether `conn` reports a new unidirectional stream among the events it has queued.
fn saw_uni_stream(conn: &mut Connection) -> bool {
    let mut seen = false;
    while let Some(event) = conn.poll() {
        seen |= matches!(event, Event::Stream(StreamEvent::Opened { dir: Dir::Uni }));
    }
    seen
}

/// Drive both sides until they are idle, failing rather than looping when they never settle.
fn drive_settled(pair: &mut Pair) {
    for _ in 0..500 {
        if !pair.step() {
            return;
        }
    }
    panic!("the connection never settled");
}

/// How many datagrams the client addressed to `remote`.
fn addressed_to(pair: &Pair, remote: SocketAddr) -> usize {
    pair.client_sent.iter().filter(|s| s.to == remote).count()
}

/// How many datagrams the client sent with the destination connection ID numbered `seq`.
fn sent_with(pair: &Pair, seq: u64) -> usize {
    pair.client_sent
        .iter()
        .filter(|s| s.cid == Some(seq))
        .count()
}

/// RFC 9000 §9.6: the client probes the address the server advertised for the family in use with
/// the identifier the server bound to it, and moves there as soon as a probe is answered. The
/// path it leaves is not kept, so the identifier used there is retired. The server answers on the
/// path the probe arrived on, with an identifier of its own bound to it (§9.5), and the connection
/// carries data both ways at the new address.
#[test]
fn a_client_moves_to_the_servers_preferred_address_once_it_answers() {
    let _guard = subscribe();
    let (mut pair, preferred) = pair_preferring(true);
    let (ch, server_ch) = connect_armed(&mut pair);
    let before = pair.client_conn_mut(ch).active_rem_cid();
    pair.server_conn_mut(server_ch).hold_handshake_done(false);

    let mut steps = 0;
    while pair.client_conn_mut(ch).preferred_address_state() != PreferredAddressState::Validated {
        assert!(pair.step(), "the pair went idle before the move");
        steps += 1;
        assert!(steps < 200, "the move did not happen");
    }

    assert_eq!(pair.client_conn_mut(ch).remote_address(), preferred);
    assert_eq!(
        pair.client_conn_mut(ch).active_rem_cid_seq(),
        1,
        "the identifier the server bound to its preferred address"
    );
    assert!(pair.client_conn_mut(ch).reserved_rem_cid().is_none());
    assert!(
        !pair.client_conn_mut(ch).unused_rem_cids().contains(&before),
        "the identifier of the path left behind is not kept"
    );
    assert_eq!(
        pair.client_conn_mut(ch)
            .stats()
            .path
            .preferred_address_probes,
        1,
        "one probe was answered, so no other was transmitted"
    );
    assert!(addressed_to(&pair, preferred) >= 1);
    assert!(!pair.client_conn_mut(ch).is_closed());
    let before_move = pair.client_sent.len();

    // The connection carries data both ways at the new address, and keeps doing so. What matters
    // is the bytes and the end of the stream, not that a stream opened: opening proves delivery
    // started, not that it arrived whole.
    const UP: &[u8] = b"from the client";
    const DOWN: &[u8] = b"from the server";
    let up = pair.client_streams(ch).open(Dir::Uni).unwrap();
    pair.client_send(ch, up).write(UP).unwrap();
    pair.client_send(ch, up).finish().unwrap();
    let down = pair.server_streams(server_ch).open(Dir::Uni).unwrap();
    pair.server_send(server_ch, down).write(DOWN).unwrap();
    pair.server_send(server_ch, down).finish().unwrap();
    drive_settled(&mut pair);
    assert!(saw_uni_stream(pair.server_conn_mut(server_ch)), "upstream");
    assert!(saw_uni_stream(pair.client_conn_mut(ch)), "downstream");
    // Verify the exact bytes at offset zero and the end of stream, in both directions.
    {
        let mut recv = pair.server_recv(server_ch, up);
        let mut chunks = recv.read(false).unwrap();
        match chunks.next(usize::MAX) {
            Ok(Some(chunk)) if chunk.offset == 0 && chunk.bytes == UP => {}
            other => panic!("upstream bytes: {other:?}"),
        }
        assert_matches!(
            chunks.next(usize::MAX),
            Ok(None),
            "upstream did not end where the sender finished it",
        );
        let _transmit = chunks.finalize();
    }
    {
        let mut recv = pair.client_recv(ch, down);
        let mut chunks = recv.read(false).unwrap();
        match chunks.next(usize::MAX) {
            Ok(Some(chunk)) if chunk.offset == 0 && chunk.bytes == DOWN => {}
            other => panic!("downstream bytes: {other:?}"),
        }
        assert_matches!(
            chunks.next(usize::MAX),
            Ok(None),
            "downstream did not end where the sender finished it",
        );
        let _transmit = chunks.finalize();
    }
    assert_eq!(pair.client_conn_mut(ch).remote_address(), preferred);
    assert!(!pair.client_conn_mut(ch).is_closed());
    assert!(!pair.server_conn_mut(server_ch).is_closed());

    // Every datagram since the move went to the preferred address, with the identifier bound to
    // it and no other; the identifier the old path used was never sent there.
    let moved_seq = pair.client_conn_mut(ch).active_rem_cid_seq();
    for sent in pair.client_sent.iter().skip(before_move) {
        assert_eq!(
            (sent.to, sent.cid),
            (preferred, Some(moved_seq)),
            "after the move: {sent:?}"
        );
    }
}

/// A preferred address nothing answers at is probed three times and then given up: the identifier
/// reserved for it is retired, the connection stays where it is and keeps working.
#[test]
fn an_unanswered_preferred_address_is_given_up_after_three_probes() {
    let _guard = subscribe();
    let (mut pair, preferred) = pair_preferring(false);
    let (ch, server_ch) = connect_armed(&mut pair);
    let current = pair.client_conn_mut(ch).remote_address();
    probe_once(&mut pair, server_ch);
    assert_eq!(
        pair.client_conn_mut(ch).preferred_address_state(),
        PreferredAddressState::Probing
    );
    let reserved = pair
        .client_conn_mut(ch)
        .reserved_rem_cid()
        .expect("an identifier is set aside for the candidate path");
    assert_eq!(addressed_to(&pair, preferred), 1);
    let challenges_before = pair.client_conn_mut(ch).stats().frame_tx.path_challenge;

    // Each probe waits its own interval: the three are spread over time, not a busy loop.
    let mut sent_at = vec![pair.time];
    let mut seen = 1;
    for _ in 0..500 {
        if !pair.step() {
            break;
        }
        let probes = pair
            .client_conn_mut(ch)
            .stats()
            .path
            .preferred_address_probes;
        if probes > seen {
            seen = probes;
            sent_at.push(pair.time);
        }
    }
    assert_eq!(sent_at.len(), 3, "three probes, at {sent_at:?}");
    for pair_of in sent_at.windows(2) {
        assert!(
            pair_of[1].saturating_duration_since(pair_of[0]) >= Duration::from_millis(1),
            "the probes are spaced, not a busy loop: {sent_at:?}"
        );
    }
    assert_eq!(
        pair.client_conn_mut(ch).stats().frame_tx.path_challenge - challenges_before,
        2,
        "one PATH_CHALLENGE per probe after the first"
    );

    assert_eq!(
        pair.client_conn_mut(ch).preferred_address_state(),
        PreferredAddressState::Failed
    );
    assert_eq!(
        pair.client_conn_mut(ch)
            .stats()
            .path
            .preferred_address_probes,
        3
    );
    assert_eq!(addressed_to(&pair, preferred), 3, "nothing else went there");
    assert_eq!(pair.client_conn_mut(ch).remote_address(), current);
    assert!(pair.client_conn_mut(ch).reserved_rem_cid().is_none());
    assert!(
        !pair
            .client_conn_mut(ch)
            .unused_rem_cids()
            .contains(&reserved),
        "the identifier reserved for it is retired, not returned to the unused ones"
    );
    let s = pair.client_streams(ch).open(Dir::Uni).unwrap();
    pair.client_send(ch, s).write(b"still here").unwrap();
    drive_settled(&mut pair);
    assert!(saw_uni_stream(pair.server_conn_mut(server_ch)));
}

/// A client accepts a probe's answer from the address it is probing and from the address it is
/// using, and from nowhere else: an answer from an unrelated address validates nothing.
#[test]
fn a_response_from_an_unrelated_address_validates_nothing() {
    let _guard = subscribe();
    let (mut pair, preferred) = pair_preferring(true);
    let (ch, server_ch) = connect_armed(&mut pair);
    probe_once(&mut pair, server_ch);
    let answers: Vec<_> = pair.server.outbound.drain(..).collect();
    assert!(!answers.is_empty(), "the server answered the probe");
    let elsewhere = SocketAddr::new(
        Ipv6Addr::LOCALHOST.into(),
        SERVER_PORTS.lock().next().unwrap(),
    );
    for (transmit, buffer) in answers {
        pair.client.inbound.push_back(Inbound {
            at: pair.time,
            ecn: transmit.ecn,
            packet: buffer.as_ref().into(),
            from: Some(elsewhere),
            to: Some(pair.client.addr),
        });
    }
    pair.client.drive(pair.time, pair.server.addr);
    assert_eq!(
        pair.client_conn_mut(ch).preferred_address_state(),
        PreferredAddressState::Probing,
        "a packet from an address this connection does not use is not accepted"
    );
    assert_ne!(pair.client_conn_mut(ch).remote_address(), preferred);
    assert!(!pair.client_conn_mut(ch).is_closed());
}

/// An address a server advertises that is the one already in use arms nothing.
#[test]
fn a_preferred_address_that_is_the_one_in_use_is_not_probed() {
    let _guard = subscribe();
    let mut config = server_config();
    // The server advertises the very address the connection runs on.
    let own = SocketAddrV6::new(
        Ipv6Addr::LOCALHOST,
        SERVER_PORTS.lock().next().unwrap(),
        0,
        0,
    );
    config.set_preferred_address_v6(own);
    let mut pair = Pair::new(
        Arc::new(EndpointConfig::try_with_rand_key().unwrap()),
        config,
    );
    pair.server.addr = own.into();
    let ch = pair.begin_connect(client_config());
    drive_settled(&mut pair);
    let server_ch = pair.server.assert_accept();
    drive_settled(&mut pair);
    assert_eq!(
        pair.client_conn_mut(ch).remote_address(),
        SocketAddr::from(own)
    );
    assert_eq!(
        pair.client_conn_mut(ch).preferred_address_state(),
        PreferredAddressState::Unused
    );
    assert_eq!(
        pair.client_conn_mut(ch)
            .stats()
            .path
            .preferred_address_probes,
        0
    );
    assert!(pair.client_conn_mut(ch).reserved_rem_cid().is_none());
    assert!(!pair.server_conn_mut(server_ch).is_closed());
}

/// RFC 9000 §8.2.3 on the endpoint that started the validation: a response carrying a probe's
/// challenge data validates the path that probe was sent on, even when it arrives on another
/// accepted path. Here the server's answer is delivered on the path in use instead of from the
/// preferred address.
#[test]
fn a_response_on_another_path_validates_the_preferred_address() {
    let _guard = subscribe();
    let (mut pair, preferred) = pair_preferring(true);
    let (ch, server_ch) = connect_armed(&mut pair);
    probe_once(&mut pair, server_ch);
    assert_eq!(
        pair.client_conn_mut(ch).preferred_address_state(),
        PreferredAddressState::Probing
    );

    // Hand the client the server's answer with the address in use as its source.
    let answers: Vec<_> = pair.server.outbound.drain(..).collect();
    assert!(!answers.is_empty(), "the server answered the probe");
    for (transmit, buffer) in answers {
        assert_eq!(transmit.destination, pair.client.addr);
        pair.client.inbound.push_back(Inbound {
            at: pair.time,
            ecn: transmit.ecn,
            packet: buffer.as_ref().into(),
            from: Some(pair.server.addr),
            to: Some(pair.client.addr),
        });
    }
    pair.client.drive(pair.time, pair.server.addr);

    assert_eq!(
        pair.client_conn_mut(ch).preferred_address_state(),
        PreferredAddressState::Validated,
        "the challenge data identifies the path, not the address the answer came from"
    );
    assert_eq!(pair.client_conn_mut(ch).remote_address(), preferred);
    assert!(!pair.client_conn_mut(ch).is_closed());
    assert!(!pair.server_conn_mut(server_ch).is_closed());
    // As above: this server cannot serve the address it advertised, so the move is the end of
    // what C6a observes here.
    let now = pair.time;
    pair.client_conn_mut(ch)
        .close(now, VarInt::from_u32(0), Bytes::new());
    drive_settled(&mut pair);
}

/// A response to a probe of an attempt that was started over validates nothing: the stale data
/// matches no outstanding probe, the connection stays where it is, and the fresh attempt still
/// completes.
#[test]
fn a_stale_probe_answer_validates_nothing() {
    let _guard = subscribe();
    let (mut pair, preferred) = pair_preferring(true);
    let (ch, server_ch) = connect_armed(&mut pair);
    probe_once(&mut pair, server_ch);
    let stale = pair
        .client_conn_mut(ch)
        .reserved_rem_cid()
        .expect("reserved");
    let held: Vec<_> = pair.server.outbound.drain(..).collect();
    assert!(!held.is_empty(), "the server answered the probe");

    // The client's local address changes: the attempt starts over with a fresh identifier.
    pair.client.addr = SocketAddr::new(
        Ipv6Addr::LOCALHOST.into(),
        CLIENT_PORTS.lock().next().unwrap(),
    );
    assert!(pair.client_migrate_local_address(ch));
    let fresh = pair
        .client_conn_mut(ch)
        .reserved_rem_cid()
        .expect("reserved");
    assert_ne!(fresh, stale, "the candidate path takes a fresh identifier");

    // The held answer belongs to the attempt that was given up.
    for (transmit, buffer) in held {
        pair.client.inbound.push_back(Inbound {
            at: pair.time,
            ecn: transmit.ecn,
            packet: buffer.as_ref().into(),
            from: Some(preferred),
            to: Some(pair.client.addr),
        });
    }
    pair.client.drive(pair.time, pair.server.addr);
    assert_eq!(
        pair.client_conn_mut(ch).preferred_address_state(),
        PreferredAddressState::Probing,
        "a stale answer neither validates nor ends the attempt"
    );
    assert_ne!(pair.client_conn_mut(ch).remote_address(), preferred);

    // The fresh attempt is answered and completes.
    drive_settled(&mut pair);
    assert_eq!(
        pair.client_conn_mut(ch).preferred_address_state(),
        PreferredAddressState::Validated
    );
    assert_eq!(pair.client_conn_mut(ch).remote_address(), preferred);
    assert!(!pair.server_conn_mut(server_ch).is_closed());
}

/// RFC 9000 §5.1.2: the identifier a server binds to its preferred address may be retired before
/// the client uses it. The candidate path then takes another unused identifier.
#[test]
fn a_retired_preferred_identifier_is_replaced_by_another() {
    let _guard = subscribe();
    let (mut pair, preferred) = pair_preferring(true);
    let ch = pair.begin_connect(client_config());
    pair.step();
    let server_ch = pair.server.assert_accept();
    // Hold HANDSHAKE_DONE, so nothing is probed before the identifier is retired.
    pair.server_conn_mut(server_ch).hold_handshake_done(true);
    drive_settled(&mut pair);
    assert_eq!(
        pair.client_conn_mut(ch).preferred_address_state(),
        PreferredAddressState::Armed
    );
    assert!(pair.client_conn_mut(ch).reserved_rem_cid().is_none());
    let now = pair.time;
    pair.server_conn_mut(server_ch).rotate_local_cid(2, now);
    drive_settled(&mut pair);
    let bound = pair.client_conn_mut(ch).active_rem_cid();
    assert!(
        pair.client_conn_mut(ch).active_rem_cid_seq() >= 2,
        "the identifier bound to the preferred address is retired"
    );

    pair.server_conn_mut(server_ch).hold_handshake_done(false);
    drive_settled(&mut pair);
    assert_eq!(
        pair.client_conn_mut(ch).preferred_address_state(),
        PreferredAddressState::Validated
    );
    assert_eq!(pair.client_conn_mut(ch).remote_address(), preferred);
    assert_ne!(
        pair.client_conn_mut(ch).active_rem_cid(),
        bound,
        "the candidate path took another unused identifier"
    );
    assert!(pair.client_conn_mut(ch).active_rem_cid_seq() >= 3);
    assert!(!pair.client_conn_mut(ch).is_closed());
}

/// A client that declines the server's preferred address never sends anything there.
#[test]
fn a_declined_preferred_address_is_never_probed() {
    let _guard = subscribe();
    let (mut pair, preferred) = pair_preferring(true);
    let mut config = client_config();
    config.set_preferred_address_policy(PreferredAddressPolicy::Decline);
    let ch = pair.begin_connect(config);
    drive_settled(&mut pair);
    let server_ch = pair.server.assert_accept();
    drive_settled(&mut pair);
    assert_eq!(
        pair.client_conn_mut(ch).preferred_address_state(),
        PreferredAddressState::Unused
    );
    assert_eq!(
        pair.client_conn_mut(ch)
            .stats()
            .path
            .preferred_address_probes,
        0
    );
    assert_eq!(addressed_to(&pair, preferred), 0);
    assert!(pair.client_conn_mut(ch).reserved_rem_cid().is_none());
    assert_ne!(pair.client_conn_mut(ch).remote_address(), preferred);
    assert!(!pair.server_conn_mut(server_ch).is_closed());
}

/// An address advertised for a family other than the one in use is not probed: nothing is sent
/// there and no identifier is set aside. This is a missing address, not an unreachable one.
#[test]
fn a_preferred_address_of_another_family_is_not_probed() {
    let _guard = subscribe();
    let mut config = server_config();
    config.set_preferred_address_v4(SocketAddrV4::new(Ipv4Addr::LOCALHOST, 65535));
    let mut pair = Pair::new(
        Arc::new(EndpointConfig::try_with_rand_key().unwrap()),
        config,
    );
    let ch = pair.begin_connect(client_config());
    drive_settled(&mut pair);
    let server_ch = pair.server.assert_accept();
    drive_settled(&mut pair);
    assert!(pair.client_conn_mut(ch).remote_address().is_ipv6());
    assert_eq!(
        pair.client_conn_mut(ch).preferred_address_state(),
        PreferredAddressState::Unused
    );
    assert_eq!(
        pair.client_conn_mut(ch)
            .stats()
            .path
            .preferred_address_probes,
        0
    );
    assert!(pair.client_conn_mut(ch).reserved_rem_cid().is_none());
    assert!(!pair.client_conn_mut(ch).is_closed());
    assert!(!pair.server_conn_mut(server_ch).is_closed());
}

/// Hand the client datagrams the server put on the wire earlier, held back until now.
fn deliver_to_client(pair: &mut Pair, datagrams: Vec<(Transmit, Bytes)>) {
    for (packet, buffer) in datagrams {
        pair.client.inbound.push_back(Inbound {
            at: pair.time,
            ecn: packet.ecn,
            packet: buffer.as_ref().into(),
            from: packet.local,
            to: Some(pair.client.addr),
        });
    }
}

/// A datagram addressed to an identifier that routes to `ch`, so the endpoint hands it to that
/// connection rather than matching it by token alone, ending in the token `key` derives for `cid`.
fn routed_reset_for(
    endpoint: &TestEndpoint,
    ch: ConnectionHandle,
    key: &HmacSha2,
    cid: ConnectionId,
) -> Vec<u8> {
    let dcid = *endpoint
        .cids_routing_to(ch)
        .first()
        .expect("the endpoint is routed by its connection IDs");
    let mut reset = vec![0x40; 1];
    reset.extend_from_slice(&dcid);
    reset.extend_from_slice(&[0xab; 32]);
    reset.extend_from_slice(&reset_token(key, cid));
    reset
}

/// RFC 9000 §10.3.1 through a change of role: a NAT rebinding keeps the identifier the connection
/// was already sending, so its history is still ours and a reset for it still resets us without
/// waiting for another datagram to leave. The reset is addressed to one of our own identifiers, so
/// the endpoint hands it straight to the connection and what is under test is recognition alone,
/// not how quickly the token association for the new address is installed.
#[test]
fn a_rebinding_keeps_the_history_of_the_identifier_it_keeps() {
    let _guard = subscribe();
    let (mut pair, key) = pair_with_known_reset_key();
    let (client_ch, server_ch) = pair.connect();
    pair.drive();
    let cid = pair.server_conn_mut(server_ch).active_rem_cid();
    let seq = pair.server_conn_mut(server_ch).active_rem_cid_seq();
    assert!(
        pair.server_conn_mut(server_ch).cid_confirmed(seq),
        "the connection has been sending with it"
    );

    // The peer rebinds: same identifier, new address.
    let rebound = SocketAddr::new(
        Ipv4Addr::new(127, 0, 0, 7).into(),
        CLIENT_PORTS.lock().next().unwrap(),
    );
    pair.client.addr = rebound;
    pair.client_conn_mut(client_ch).ping();
    pair.drive_client();
    pair.server.drive(pair.time, rebound);
    assert_eq!(pair.server_conn_mut(server_ch).remote_address(), rebound);
    assert_eq!(
        pair.server_conn_mut(server_ch).active_rem_cid(),
        cid,
        "a rebinding keeps the identifier"
    );
    assert!(
        pair.server_conn_mut(server_ch).cid_confirmed(seq),
        "and keeps what that identifier has sent: a change of address is not a new identifier"
    );

    let packet = routed_reset_for(&pair.server, server_ch, &key, cid);
    pair.server.inbound.push_back(Inbound {
        at: pair.time,
        ecn: None,
        packet: packet.as_slice().into(),
        from: Some(rebound),
        to: Some(pair.server.addr),
    });
    pair.server.drive(pair.time, rebound);
    assert!(
        was_reset(pair.server_conn_mut(server_ch)),
        "an identifier we have sent is still one we have sent after it changes address"
    );
}

/// A protocol error raised where the caller cannot return one is told to the application as
/// itself, at the next transmit, and only once: the peer gets the frame the error names, and the
/// connection reports the same code rather than an engine that drained without a reason.
#[test]
fn a_deferred_protocol_error_is_reported_as_itself() {
    let _guard = subscribe();
    let mut pair = Pair::default();
    let (client_ch, _server_ch) = pair.connect();
    pair.drive();
    assert!(!pair.client_conn_mut(client_ch).is_closed());

    // A retirement too wide to queue is refused, and the refusal is deferred exactly as the
    // migration, timer and give-up paths defer theirs.
    pair.client_conn_mut(client_ch).overflow_retirement_queue();
    assert!(
        !pair.client_conn_mut(client_ch).is_closed(),
        "nothing has closed yet: the error is carried to the next transmit"
    );

    // One transmit is all it takes; no close timeout is involved.
    let mut buf = Vec::new();
    let now = pair.time;
    let _transmit = pair
        .client_conn_mut(client_ch)
        .poll_transmit(now, 1, &mut buf);
    assert!(pair.client_conn_mut(client_ch).is_closed());

    let mut reasons = Vec::new();
    while let Some(event) = pair.client_conn_mut(client_ch).poll() {
        if let Event::ConnectionLost { reason } = event {
            reasons.push(reason);
        }
    }
    assert_eq!(reasons.len(), 1, "reported once: {reasons:?}");
    match &reasons[0] {
        ConnectionError::TransportError(error) => assert_eq!(
            error.code,
            rama_quic_proto::TransportErrorCode::CONNECTION_ID_LIMIT_ERROR,
            "the code the failure carried, not a substitute"
        ),
        other => panic!("expected the original transport error, got {other:?}"),
    }
    // Draining is quiet: the error is not reported again.
    drive_settled(&mut pair);
    while let Some(event) = pair.client_conn_mut(client_ch).poll() {
        assert!(
            !matches!(event, Event::ConnectionLost { .. }),
            "reported twice: {event:?}"
        );
    }
}

/// A path the peer left before it was ever validated does not take the original's place: after
/// A -> B -> C, where the move off B happened while B was still unvalidated, the connection still
/// falls back to A, so a reset for that identifier from A is ours. An address it never sent to is
/// not, which is what stops this from passing for the wrong reason.
#[test]
fn a_fallback_survives_repeated_unvalidated_moves_and_keeps_its_route() {
    let _guard = subscribe();
    let (mut pair, key) = pair_with_known_reset_key();
    let (client_ch, server_ch) = pair.connect();
    pair.drive();
    let home = pair.client.addr;
    let cid = pair.server_conn_mut(server_ch).active_rem_cid();
    let seq = pair.server_conn_mut(server_ch).active_rem_cid_seq();
    assert!(pair.server_conn_mut(server_ch).cid_confirmed(seq));

    // Two rebindings in a row, the second while the first is still being validated. The
    // identifier travels with the peer, so the same one is now sent to three addresses.
    let mut moves = Vec::new();
    for last in [7u8, 8] {
        let moved = SocketAddr::new(
            Ipv4Addr::new(127, 0, 0, last).into(),
            CLIENT_PORTS.lock().next().unwrap(),
        );
        pair.client.addr = moved;
        pair.client_conn_mut(client_ch).ping();
        pair.drive_client();
        pair.server.drive(pair.time, moved);
        assert_eq!(pair.server_conn_mut(server_ch).remote_address(), moved);
        assert_eq!(
            pair.server_conn_mut(server_ch).active_rem_cid(),
            cid,
            "a rebinding keeps the identifier"
        );
        moves.push(moved);
    }

    // The original is still the address this connection would fall back to, so its route is live.
    let packet = routed_reset_for(&pair.server, server_ch, &key, cid);
    let unused = SocketAddr::new(
        Ipv4Addr::new(127, 0, 0, 9).into(),
        CLIENT_PORTS.lock().next().unwrap(),
    );
    let last = *moves.last().unwrap();
    let at = pair.time;
    let to = pair.server.addr;
    let from_unused = Inbound {
        at,
        ecn: None,
        packet: packet.as_slice().into(),
        from: Some(unused),
        to: Some(to),
    };
    processed_by_server(&mut pair, server_ch, from_unused, last);
    assert!(
        !was_reset(pair.server_conn_mut(server_ch)),
        "an address this identifier was never sent to cannot reset us"
    );

    let from_home = Inbound {
        at,
        ecn: None,
        packet: packet.as_slice().into(),
        from: Some(home),
        to: Some(to),
    };
    processed_by_server(&mut pair, server_ch, from_home, last);
    assert!(
        was_reset(pair.server_conn_mut(server_ch)),
        "the address the connection still falls back to keeps its route"
    );
}

/// Each connection's deadline is its own. Two connections are given different keep-alive
/// intervals, so their deadlines differ; advancing to the earlier one fires that connection's
/// timer and leaves the other's deadline where it was.
#[test]
fn one_connections_deadline_does_not_disturb_anothers() {
    let _guard = subscribe();
    let mut pair = Pair::default();
    let (soon, _soon_server) =
        pair.connect_with(client_config_with_keep_alive(Duration::from_secs(1)));
    let (later, _later_server) =
        pair.connect_with(client_config_with_keep_alive(Duration::from_secs(30)));
    drive_settled(&mut pair);

    let soon_at = pair
        .client
        .deadline_for(soon)
        .expect("the first has a deadline");
    let later_at = pair
        .client
        .deadline_for(later)
        .expect("the second has a deadline");
    assert!(
        soon_at < later_at,
        "the two deadlines differ: {soon_at:?} then {later_at:?}"
    );

    // Advance to the earlier deadline only, and drive once. The per-connection frame counters are
    // what tell the two connections apart.
    let pings = |pair: &mut Pair, ch| pair.client_conn_mut(ch).stats().frame_tx.ping;
    let soon_pings = pings(&mut pair, soon);
    let later_pings = pings(&mut pair, later);
    pair.time = soon_at;
    pair.drive_client();

    // The due connection sent its keep-alive; the other sent none.
    assert!(
        pings(&mut pair, soon) > soon_pings,
        "the connection whose deadline arrived pinged: {} then {}",
        soon_pings,
        pings(&mut pair, soon)
    );
    assert_eq!(
        pings(&mut pair, later),
        later_pings,
        "and the other connection did not"
    );

    // Its deadline is renewed to a later time, not merely different, and the other's is untouched.
    let renewed = pair
        .client
        .deadline_for(soon)
        .expect("the due connection has a new deadline");
    assert!(
        renewed > soon_at,
        "the renewed deadline is in the future: {renewed:?} after {soon_at:?}"
    );
    assert_eq!(
        pair.client.deadline_for(later),
        Some(later_at),
        "the other connection's deadline is untouched"
    );
    assert!(!pair.client_conn_mut(soon).is_closed());
    assert!(!pair.client_conn_mut(later).is_closed());
}

/// A datagram held back for its route, the timer of the connection it belongs to and that
/// connection's stall count are all per connection. Two connections share the client endpoint;
/// route installations are withheld for one, which rotates to an identifier whose stateless reset
/// token it knows, so its next datagram waits (RFC 9000 §10.3.1). Checks: the other connection's
/// sends leave the waiting datagram held and its count untouched, the waiting connection keeps a
/// deadline of its own, and a datagram that waits after progress counts from one.
#[test]
fn a_datagram_waiting_for_a_route_keeps_its_connections_timer_and_count() {
    let _guard = subscribe();
    let mut pair = Pair::default();
    let (stalled, stalled_server) = pair.connect();
    let (sending, _sending_server) = pair.connect();
    drive_settled(&mut pair);
    let before = pair.client_conn_mut(stalled).active_rem_cid_seq();

    pair.client.hold_route_installs.push(stalled);
    let now = pair.time;
    pair.server_conn_mut(stalled_server)
        .rotate_local_cid(2, now);
    pair.drive_server();
    pair.client_conn_mut(stalled).ping();
    pair.drive_client();

    assert!(
        pair.client_conn_mut(stalled).active_rem_cid_seq() > before,
        "the connection moved to another identifier: {} then {}",
        before,
        pair.client_conn_mut(stalled).active_rem_cid_seq()
    );
    assert!(
        pair.client.awaiting_route(stalled),
        "its datagram is waiting for the route the endpoint has not installed"
    );
    assert_eq!(pair.client.waiting_drives_for(stalled), 1);
    assert_eq!(
        pair.client.waiting_drives_for(sending),
        0,
        "the other connection is not waiting for anything"
    );

    // The other connection sends. The waiting datagram stays held and stays counted.
    let sent_before = pair.client_sent.len();
    pair.client_conn_mut(sending).ping();
    pair.drive_client();
    assert!(
        pair.client_sent.len() > sent_before,
        "the other connection put a datagram on the wire"
    );
    assert!(pair.client.awaiting_route(stalled));
    assert_eq!(
        pair.client.waiting_drives_for(stalled),
        2,
        "the stall count belongs to the waiting connection"
    );
    assert_eq!(pair.client.waiting_drives_for(sending), 0);

    // Advancing to the waiting connection's deadline fires its timer, and the deadline it sets
    // next is kept.
    let due = pair
        .client
        .deadline_for(stalled)
        .expect("the waiting connection has a deadline");
    pair.time = due;
    pair.drive_client();
    assert!(
        pair.client.awaiting_route(stalled),
        "and it is still waiting"
    );
    let renewed = pair
        .client
        .deadline_for(stalled)
        .expect("a datagram waiting for its route does not cost the connection its timer");
    assert!(
        renewed > due,
        "the deadline it set next is in the future: {renewed:?} after {due:?}"
    );
    assert_eq!(pair.client.waiting_drives_for(stalled), 3);
    assert_eq!(pair.client.waiting_drives_for(sending), 0);

    // Once the route is installed the datagram leaves with the identifier it was built with.
    let seq = pair.client_conn_mut(stalled).active_rem_cid_seq();
    pair.client.release_route_installs();
    let sent_before = pair.client_sent.len();
    pair.drive_client();
    assert!(
        !pair.client.awaiting_route(stalled),
        "the datagram left once its route was installed"
    );
    assert_eq!(pair.client.waiting_drives_for(stalled), 0);
    assert!(
        pair.client_sent[sent_before..]
            .iter()
            .any(|sent| sent.cid == Some(seq)),
        "it carried the identifier it was built with: {:?}",
        &pair.client_sent[sent_before..]
    );

    // A datagram that waits after that one left counts from one; the earlier stall is over.
    pair.client.hold_route_installs.push(stalled);
    let now = pair.time;
    pair.server_conn_mut(stalled_server)
        .rotate_local_cid(4, now);
    pair.drive_server();
    pair.client_conn_mut(stalled).ping();
    pair.drive_client();
    assert!(
        pair.client.awaiting_route(stalled),
        "another datagram waits for the route the endpoint has not installed"
    );
    assert_eq!(pair.client.waiting_drives_for(stalled), 1);
    assert_eq!(pair.client.waiting_drives_for(sending), 0);

    pair.client.release_route_installs();
    drive_settled(&mut pair);
    assert!(!pair.client.awaiting_route(stalled));
    assert_eq!(pair.client.waiting_drives_for(stalled), 0);
    assert!(!pair.client_conn_mut(stalled).is_closed());
    assert!(!pair.client_conn_mut(sending).is_closed());
}

/// Two connections on one endpoint each receive only their own arrivals and keep their own
/// deadline. A single shared deadline, or draining every handle's arrivals into whichever
/// connection is visited first, is not observable with one connection per endpoint.
#[test]
fn two_connections_on_one_endpoint_keep_their_own_arrivals_and_deadlines() {
    let _guard = subscribe();
    let mut pair = Pair::default();
    let (client_a, server_a) = pair.connect();
    let (client_b, server_b) = pair.connect();
    pair.drive();
    assert_ne!(client_a, client_b);
    assert_ne!(server_a, server_b);

    // Distinguishable payloads, both written client to server.
    const TO_A: &[u8] = b"for the first";
    const TO_B: &[u8] = b"for the second";
    let up_a = pair.client_streams(client_a).open(Dir::Uni).unwrap();
    pair.client_send(client_a, up_a).write(TO_A).unwrap();
    pair.client_send(client_a, up_a).finish().unwrap();
    let up_b = pair.client_streams(client_b).open(Dir::Uni).unwrap();
    pair.client_send(client_b, up_b).write(TO_B).unwrap();
    pair.client_send(client_b, up_b).finish().unwrap();
    drive_settled(&mut pair);

    // Each server connection sees its own bytes, and neither is closed by the other's traffic.
    for (ch, stream, expected) in [(server_a, up_a, TO_A), (server_b, up_b, TO_B)] {
        assert!(saw_uni_stream(pair.server_conn_mut(ch)));
        let mut recv = pair.server_recv(ch, stream);
        let mut chunks = recv.read(false).unwrap();
        match chunks.next(usize::MAX) {
            Ok(Some(chunk)) if chunk.offset == 0 && chunk.bytes == expected => {}
            other => panic!("connection {ch:?} received {other:?}"),
        }
        assert_matches!(chunks.next(usize::MAX), Ok(None));
        let _transmit = chunks.finalize();
    }
    assert!(!pair.server_conn_mut(server_a).is_closed());
    assert!(!pair.server_conn_mut(server_b).is_closed());

    // They hold different identifiers, so neither could have taken the other's packets.
    assert_ne!(
        pair.server_conn_mut(server_a).active_rem_cid(),
        pair.server_conn_mut(server_b).active_rem_cid()
    );

    // Each keeps its own deadline: closing one leaves the other's timer alone and running.
    let now = pair.time;
    pair.server_conn_mut(server_a).close(
        now,
        rama_quic_proto::VarInt::from_u32(0),
        rama_core::bytes::Bytes::new(),
    );
    drive_settled(&mut pair);
    assert!(pair.server_conn_mut(server_a).is_closed());
    assert!(
        !pair.server_conn_mut(server_b).is_closed(),
        "closing one connection did not disturb the other"
    );
    // The one still open keeps working, and its payload arrives whole.
    const AFTER: &[u8] = b"still here";
    let after = pair.server_streams(server_b).open(Dir::Uni).unwrap();
    pair.server_send(server_b, after).write(AFTER).unwrap();
    pair.server_send(server_b, after).finish().unwrap();
    drive_settled(&mut pair);
    assert!(saw_uni_stream(pair.client_conn_mut(client_b)));
    let mut recv = pair.client_recv(client_b, after);
    let mut chunks = recv.read(false).unwrap();
    match chunks.next(usize::MAX) {
        Ok(Some(chunk)) if chunk.offset == 0 && chunk.bytes == AFTER => {}
        other => panic!("the survivor received {other:?}"),
    }
    assert_matches!(chunks.next(usize::MAX), Ok(None));
    let _transmit = chunks.finalize();
}

/// The endpoint answers a route it cannot install with a refusal rather than an acknowledgement,
/// and its routing index gains nothing for the refused route. The engine cannot fill this table on
/// its own, so the events are handed to the endpoint directly.
#[test]
fn an_endpoint_with_no_room_refuses_the_route_and_indexes_nothing() {
    use crate::proto::shared::{ConnectionEventInner, EndpointEvent, EndpointEventInner};

    let _guard = subscribe();
    let mut pair = Pair::default();
    let (client_ch, _server_ch) = pair.connect();
    pair.drive();

    let slots = pair.client_conn_mut(client_ch).remote_cid_limit()
        * crate::proto::cid_queue::RemCid::REMOTES;
    // The handshake already installed a route for the identifier it used.
    let held_before = pair.client.endpoint.reset_route_count();
    assert!(held_before > 0 && held_before < slots);
    let mut installed = 0;
    let mut refused = 0;
    let mut accepted: Vec<(SocketAddr, TestResetToken)> = Vec::new();
    let mut denied: Vec<(SocketAddr, TestResetToken)> = Vec::new();
    // One address per association, so every one is a distinct route.
    for step in 0..slots + 4 {
        let remote = SocketAddr::new(
            Ipv4Addr::new(127, 1, (step / 250) as u8, (step % 250) as u8).into(),
            4433,
        );
        let token = TestResetToken::from([step as u8; rama_quic_proto::RESET_TOKEN_SIZE]);
        let answer = pair.client.endpoint.handle_event(
            client_ch,
            EndpointEvent(EndpointEventInner::ResetTokenUsed(
                remote,
                step as u64,
                token,
                step as u64,
            )),
        );
        match answer.map(|event| event.0) {
            Some(ConnectionEventInner::ResetRouteInstalled(at, seq, generation)) => {
                assert_eq!((at, seq, generation), (remote, step as u64, step as u64));
                accepted.push((remote, token));
                installed += 1;
            }
            Some(ConnectionEventInner::ResetRouteRefused(at, seq, generation)) => {
                assert_eq!((at, seq, generation), (remote, step as u64, step as u64));
                denied.push((remote, token));
                refused += 1;
            }
            other => panic!("step {step}: the endpoint answered {other:?}"),
        }
    }
    assert_eq!(
        installed + held_before,
        slots,
        "every remaining slot was filled and acknowledged"
    );
    assert_eq!(
        refused,
        4 + held_before,
        "and every route beyond the table's capacity was refused"
    );
    assert_eq!(
        pair.client.endpoint.reset_route_count(),
        slots,
        "the index holds exactly as many routes as the table has slots"
    );
    // Cardinality alone would not say *which* routes are there. Every acknowledged pair has to
    // route to this connection, and every refused pair has to route nowhere.
    for (remote, token) in &accepted {
        assert_eq!(
            pair.client.endpoint.reset_route_for(*remote, *token),
            Some(client_ch),
            "an acknowledged route does not reach the connection: {remote}"
        );
    }
    for (remote, token) in &denied {
        assert_eq!(
            pair.client.endpoint.reset_route_for(*remote, *token),
            None,
            "a refused route is in the index: {remote}"
        );
    }
}

/// A stateless reset datagram carrying the token `key` derives for `cid`.
fn stateless_reset_for(key: &HmacSha2, cid: ConnectionId) -> Vec<u8> {
    let mut reset = vec![0x40; 1];
    reset.extend_from_slice(&[0xab; 40]);
    reset.extend_from_slice(&reset_token(key, cid));
    reset
}

/// Hand one packet to the server and require its connection to have processed it: the datagram
/// left the receive queue and the connection counted it. What the connection decides afterwards
/// is then a decision about a packet it received.
fn processed_by_server(
    pair: &mut Pair,
    server_ch: ConnectionHandle,
    inbound: Inbound,
    remote: SocketAddr,
) {
    let before = pair.server_conn_mut(server_ch).stats().udp_rx.datagrams;
    pair.server.inbound.push_back(inbound);
    pair.server.drive(pair.time, remote);
    assert!(
        pair.server.inbound.is_empty(),
        "the endpoint took the datagram from its receive queue"
    );
    assert!(
        pair.server_conn_mut(server_ch).stats().udp_rx.datagrams > before,
        "the connection processed the datagram"
    );
}

/// Whether `conn` reported being reset by its peer.
fn was_reset(conn: &mut Connection) -> bool {
    let mut lost = false;
    while let Some(event) = conn.poll() {
        if matches!(
            event,
            Event::ConnectionLost {
                reason: ConnectionError::Reset
            }
        ) {
            lost = true;
        }
    }
    lost
}

/// A `Pair` whose two endpoints share a known reset key, so tests can forge the peer's resets.
fn pair_with_known_reset_key() -> (Pair, HmacSha2) {
    let key = HmacSha2::new_256(&[0x33; 32]);
    let key_copy = HmacSha2::new_256(&[0x33; 32]);
    let endpoint_config = Arc::new(EndpointConfig::new(key));
    (Pair::new(endpoint_config, server_config()), key_copy)
}

/// Drive until both sides are idle, checking every server datagram's destination on the way.
/// Bounded like `drive_settled`, so a pair that never settles is reported rather than hanging.
fn settle_checking_server_destinations(pair: &mut Pair, allowed: &[SocketAddr]) {
    for _ in 0..500 {
        if !step_checking_server_destinations(pair, allowed) {
            return;
        }
    }
    panic!("the pair never became idle in 500 steps with its destinations checked");
}

/// One `Pair` step that hands every server datagram to the client after checking its
/// destination is one of `allowed`. Returns `false` once both sides are idle.
fn step_checking_server_destinations(pair: &mut Pair, allowed: &[SocketAddr]) -> bool {
    pair.drive_client();
    pair.server.drive(pair.time, pair.client.addr);
    for (transmit, buffer) in pair.server.outbound.drain(..) {
        assert!(
            allowed.contains(&transmit.destination),
            "the server sent to {}, allowed: {allowed:?}",
            transmit.destination
        );
        pair.client.inbound.push_back(Inbound::plain(
            pair.time,
            transmit.ecn,
            buffer.as_ref().into(),
        ));
    }
    if pair.client.is_idle() && pair.server.is_idle() {
        return false;
    }
    match min_opt(pair.client.next_wakeup(), pair.server.next_wakeup()) {
        Some(t) => {
            pair.time = pair.time.max(t);
            true
        }
        None => false,
    }
}

/// RFC 9000 §19.16: retiring a connection ID invalidates its stateless reset token. A datagram
/// still in flight with an identifier the peer has just retired draws a stateless reset from the
/// endpoint that issued it, and that reset is not ours: the connection survives it.
///
/// Roles: the issuer is the server, whose local identifiers the client uses as destinations; the
/// retiring consumer is the client, which holds them in `rem_cids` and retires them.
#[test]
fn a_reset_for_an_identifier_the_peer_retired_is_not_ours() {
    let _guard = subscribe();
    let (mut pair, key) = pair_with_known_reset_key();
    let (client_ch, server_ch) = pair.connect();
    drive_settled(&mut pair);
    let server_addr = pair.server.addr;
    let retired = pair.client_conn_mut(client_ch).active_rem_cid();
    let retired_seq = pair.client_conn_mut(client_ch).active_rem_cid_seq();
    let retired_token = reset_token(&key, retired);
    assert!(
        pair.server
            .endpoint
            .cids_routing_to(server_ch)
            .contains(&retired),
        "the issuer routes the identifier the consumer is using"
    );

    // The connection carries data both ways before anything is injected.
    exchange_uni(&mut pair, client_ch, server_ch, b"up", Dir::Uni);
    exchange_uni_back(&mut pair, server_ch, client_ch, b"down");

    // One datagram of the consumer's is held back, carrying the identifier it is using.
    pair.client_conn_mut(client_ch).ping();
    pair.client.drive(pair.time, server_addr);
    pair.client.delay_outbound();
    assert_eq!(pair.client.delayed_len(), 1, "one datagram is held back");

    // The issuer asks for retirement; the consumer switches and retires.
    pair.server.capture_inbound_packets = true;
    let now = pair.time;
    pair.server_conn_mut(server_ch)
        .rotate_local_cid(retired_seq + 1, now);
    for _ in 0..6 {
        pair.drive_server();
        pair.drive_client();
    }
    assert!(
        pair.client_conn_mut(client_ch).active_rem_cid_seq() > retired_seq,
        "the consumer moved to another identifier"
    );
    let mut retirements = Vec::new();
    for packet in pair.server.captured_packets.drain(..) {
        if let Ok(frames) = frame::Iter::new(packet.into()) {
            for frame in frames.flatten() {
                if let Frame::RetireConnectionId { sequence } = frame {
                    retirements.push(sequence);
                }
            }
        }
    }
    assert!(
        retirements.contains(&retired_seq),
        "the issuer received RETIRE_CONNECTION_ID for that sequence: {retirements:?}"
    );
    assert!(
        !pair
            .server
            .endpoint
            .cids_routing_to(server_ch)
            .contains(&retired),
        "and stopped routing it"
    );
    assert_eq!(
        pair.client
            .endpoint
            .reset_route_for(server_addr, retired_token),
        None,
        "the consumer's endpoint released the route for its token"
    );

    // The held datagram arrives, and the issuer answers it with a reset carrying that token.
    pair.server.outbound.clear();
    pair.client.finish_delay();
    pair.drive_client();
    pair.server.drive(pair.time, pair.client.addr);
    let answers: Vec<&(Transmit, Bytes)> = pair.server.outbound.iter().collect();
    assert_eq!(answers.len(), 1, "one answer: {answers:?}");
    let reset = &answers[0].1;
    assert_eq!(
        &reset[reset.len() - RESET_TOKEN_SIZE..],
        &retired_token[..],
        "it carries the retired identifier's token"
    );

    // Delivered, that reset does not reach the connection: its destination identifier is padding,
    // so the consumer's endpoint has nothing to route it by. This is the consumer's own lookup,
    // separate from the issuer's lookup above that produced the reset, and it says nothing about
    // what the engine would do with the token: that is the next leg.
    let received = pair.client_conn_mut(client_ch).stats().udp_rx.datagrams;
    pair.drive_server();
    assert_eq!(
        pair.client.inbound.len(),
        1,
        "the reset is queued for the consumer's endpoint"
    );
    pair.client.drive(pair.time, server_addr);
    assert!(
        pair.client.inbound.is_empty(),
        "the consumer's endpoint took the datagram"
    );
    assert_eq!(
        pair.client_conn_mut(client_ch).stats().udp_rx.datagrams,
        received,
        "and did not hand it to the connection"
    );
    assert!(!was_reset(pair.client_conn_mut(client_ch)));
    assert!(!pair.client_conn_mut(client_ch).is_closed());

    // The same token addressed to an identifier the consumer's endpoint does route: the datagram
    // reaches the connection, which refuses the retired token.
    let routed = routed_reset_for(&pair.client, client_ch, &key, retired);
    let at = pair.time;
    let to = pair.client.addr;
    pair.client.inbound.push_back(Inbound {
        at,
        ecn: None,
        packet: routed.as_slice().into(),
        from: Some(server_addr),
        to: Some(to),
    });
    let received = pair.client_conn_mut(client_ch).stats().udp_rx.datagrams;
    pair.client.drive(at, server_addr);
    assert!(
        pair.client_conn_mut(client_ch).stats().udp_rx.datagrams > received,
        "the connection processed it"
    );
    assert!(
        !was_reset(pair.client_conn_mut(client_ch)),
        "and did not accept the retired identifier's token"
    );
    assert!(!pair.client_conn_mut(client_ch).is_closed());

    // Data still flows, both ways, on the identifier now in use.
    exchange_uni(&mut pair, client_ch, server_ch, b"after", Dir::Uni);
    exchange_uni_back(&mut pair, server_ch, client_ch, b"back");

    // The control, last, because it closes the connection: the same dispatch carrying the token of
    // the identifier in use is ours.
    let current = pair.client_conn_mut(client_ch).active_rem_cid();
    let routed = routed_reset_for(&pair.client, client_ch, &key, current);
    let at = pair.time;
    pair.client.inbound.push_back(Inbound {
        at,
        ecn: None,
        packet: routed.as_slice().into(),
        from: Some(server_addr),
        to: Some(to),
    });
    pair.client.drive(at, server_addr);
    assert!(
        was_reset(pair.client_conn_mut(client_ch)),
        "the token of the identifier in use resets us"
    );
    assert!(pair.client_conn_mut(client_ch).is_closed());
}

/// Write `payload` on a fresh unidirectional stream from the client and read it whole on the
/// server, with the stream's end observed.
fn exchange_uni(
    pair: &mut Pair,
    from: ConnectionHandle,
    to: ConnectionHandle,
    payload: &[u8],
    dir: Dir,
) {
    let stream = pair.client_streams(from).open(dir).unwrap();
    pair.client_send(from, stream).write(payload).unwrap();
    pair.client_send(from, stream).finish().unwrap();
    drive_settled(pair);
    assert!(saw_uni_stream(pair.server_conn_mut(to)));
    let mut recv = pair.server_recv(to, stream);
    let mut chunks = recv.read(false).unwrap();
    match chunks.next(usize::MAX) {
        Ok(Some(chunk)) if chunk.offset == 0 && chunk.bytes == payload => {}
        other => panic!("the server received {other:?}"),
    }
    assert_matches!(chunks.next(usize::MAX), Ok(None), "and its end");
    let _transmit = chunks.finalize();
}

/// The same from the server to the client.
fn exchange_uni_back(
    pair: &mut Pair,
    from: ConnectionHandle,
    to: ConnectionHandle,
    payload: &[u8],
) {
    let stream = pair.server_streams(from).open(Dir::Uni).unwrap();
    pair.server_send(from, stream).write(payload).unwrap();
    pair.server_send(from, stream).finish().unwrap();
    drive_settled(pair);
    assert!(saw_uni_stream(pair.client_conn_mut(to)));
    let mut recv = pair.client_recv(to, stream);
    let mut chunks = recv.read(false).unwrap();
    match chunks.next(usize::MAX) {
        Ok(Some(chunk)) if chunk.offset == 0 && chunk.bytes == payload => {}
        other => panic!("the client received {other:?}"),
    }
    assert_matches!(chunks.next(usize::MAX), Ok(None), "and its end");
    let _transmit = chunks.finalize();
}

/// RFC 9000 §10.3.1: a reset token belongs to the connection only once the connection ID it came
/// with has been used. Before that, a reset carrying it is not recognised; afterwards it is.
#[test]
fn a_reset_token_counts_only_once_its_connection_id_is_used() {
    let _guard = subscribe();
    let (mut pair, key) = pair_with_known_reset_key();
    let (client_ch, server_ch) = pair.connect();
    pair.drive();
    let unused = pair.client_conn_mut(client_ch).unused_rem_cids();
    let next = *unused
        .first()
        .expect("the server issued spare connection IDs");
    let reset = stateless_reset_for(&key, next);
    let token = reset_token(&key, next);
    let server_addr = pair.server.addr;

    // Unused: the endpoint holds no route for that identifier at that address.
    assert_eq!(
        pair.client.endpoint.reset_route_for(server_addr, token),
        None,
        "an identifier the connection has not used has no route"
    );
    pair.client
        .inbound
        .push_back(Inbound::plain(pair.time, None, reset.as_slice().into()));
    pair.drive();
    assert!(!was_reset(pair.client_conn_mut(client_ch)));
    assert!(!pair.client_conn_mut(client_ch).is_closed());
    let s = pair.client_streams(client_ch).open(Dir::Uni).unwrap();
    pair.client_send(client_ch, s).write(b"alive").unwrap();
    pair.drive();
    assert_matches!(
        pair.server_conn_mut(server_ch).poll(),
        Some(Event::Stream(StreamEvent::Opened { dir: Dir::Uni })),
    );

    // Used: the client moves and starts sending with that very ID.
    pair.client.addr = SocketAddr::new(
        Ipv4Addr::new(127, 0, 0, 1).into(),
        CLIENT_PORTS.lock().next().unwrap(),
    );
    assert!(pair.client_migrate_local_address(client_ch));
    assert_eq!(pair.client_conn_mut(client_ch).active_rem_cid(), next);
    pair.drive();
    assert_eq!(
        pair.client.endpoint.reset_route_for(server_addr, token),
        Some(client_ch),
        "sending with the identifier is what installs the route the reset arrives by"
    );
    pair.client
        .inbound
        .push_back(Inbound::plain(pair.time, None, reset.as_slice().into()));
    pair.drive();
    assert!(
        was_reset(pair.client_conn_mut(client_ch)),
        "the same reset is recognised once the ID is in use"
    );
}

/// While a peer move is being validated, the identifier kept for the previous path is still in
/// use: a reset carrying its token from that path's address is recognised. Once the new path is
/// validated the identifier is retired and the same reset is nothing to us, while a reset for
/// the identifier now in use is.
#[test]
fn a_reset_for_the_previous_paths_connection_id_counts_until_that_id_is_retired() {
    let _guard = subscribe();
    let setup = || {
        let (mut pair, key) = pair_with_known_reset_key();
        let (client_ch, server_ch) = pair.connect();
        pair.drive();
        let old_addr = pair.client.addr;
        let old_cid = pair.server_conn_mut(server_ch).active_rem_cid();
        pair.client.addr = SocketAddr::new(
            Ipv4Addr::new(127, 0, 0, 1).into(),
            CLIENT_PORTS.lock().next().unwrap(),
        );
        assert!(pair.client_migrate_local_address(client_ch));
        pair.drive_client();
        pair.server.drive(pair.time, pair.client.addr);
        assert_eq!(
            pair.server_conn_mut(server_ch).remote_address(),
            pair.client.addr
        );
        assert_eq!(
            pair.server_conn_mut(server_ch).held_rem_cid(),
            Some(old_cid),
            "the previous path keeps its identifier while the new one is validated"
        );
        assert_ne!(pair.server_conn_mut(server_ch).active_rem_cid(), old_cid);
        (pair, key, client_ch, server_ch, old_addr, old_cid)
    };

    // During validation: the endpoint holds the route, and the old identifier's token from the
    // old address resets us.
    let (mut pair, key, _client_ch, server_ch, old_addr, old_cid) = setup();
    pair.server.outbound.clear();
    let old_token = reset_token(&key, old_cid);
    assert_eq!(
        pair.server.endpoint.reset_route_for(old_addr, old_token),
        Some(server_ch),
        "the identifier kept for the previous path is still routed from that address"
    );
    pair.server.inbound.push_back(Inbound::plain(
        pair.time,
        None,
        stateless_reset_for(&key, old_cid).as_slice().into(),
    ));
    pair.server.drive(pair.time, old_addr);
    assert!(was_reset(pair.server_conn_mut(server_ch)));

    // After validation: the old identifier is retired, its token means nothing; the current one's
    // does.
    let (mut pair, key, client_ch, server_ch, old_addr, old_cid) = setup();
    pair.drive();
    assert_eq!(pair.server_conn_mut(server_ch).held_rem_cid(), None);
    assert_eq!(
        pair.server
            .endpoint
            .reset_route_for(old_addr, reset_token(&key, old_cid)),
        None,
        "retiring the identifier released the route its token arrived by"
    );
    pair.server.inbound.push_back(Inbound::plain(
        pair.time,
        None,
        stateless_reset_for(&key, old_cid).as_slice().into(),
    ));
    pair.server.drive(pair.time, old_addr);
    assert!(!was_reset(pair.server_conn_mut(server_ch)));
    assert!(!pair.server_conn_mut(server_ch).is_closed());
    let s = pair.server_streams(server_ch).open(Dir::Uni).unwrap();
    pair.server_send(server_ch, s).write(b"alive").unwrap();
    pair.drive();
    assert_matches!(
        pair.client_conn_mut(client_ch).poll(),
        Some(Event::Stream(StreamEvent::Opened { dir: Dir::Uni })),
    );
    let current = pair.server_conn_mut(server_ch).active_rem_cid();
    pair.server.inbound.push_back(Inbound::plain(
        pair.time,
        None,
        stateless_reset_for(&key, current).as_slice().into(),
    ));
    pair.server.drive(pair.time, pair.client.addr);
    assert!(was_reset(pair.server_conn_mut(server_ch)));
}

/// After a NAT rebinding the connection keeps its identifier but sends it to a new address, so
/// that address becomes the one a reset carrying its token may come from (RFC 9000 §10.3.1).
#[test]
fn a_reset_after_a_nat_rebinding_comes_from_the_new_address() {
    let _guard = subscribe();
    let (mut pair, key) = pair_with_known_reset_key();
    let (client_ch, server_ch) = pair.connect();
    pair.drive();
    let cid = pair.server_conn_mut(server_ch).active_rem_cid();

    let rebound = SocketAddr::new(
        Ipv4Addr::new(127, 0, 0, 7).into(),
        CLIENT_PORTS.lock().next().unwrap(),
    );
    pair.client.addr = rebound;
    pair.client_conn_mut(client_ch).ping();
    pair.drive_client();
    pair.server.drive(pair.time, rebound);
    assert_eq!(pair.server_conn_mut(server_ch).remote_address(), rebound);
    assert_eq!(
        pair.server_conn_mut(server_ch).active_rem_cid(),
        cid,
        "a rebinding keeps the identifier"
    );
    pair.server.outbound.clear();

    // The same identifier, now sent to the new address: a reset from there is ours.
    pair.server.inbound.push_back(Inbound {
        at: pair.time,
        ecn: None,
        packet: stateless_reset_for(&key, cid).as_slice().into(),
        from: Some(rebound),
        to: Some(pair.server.addr),
    });
    pair.server.drive(pair.time, rebound);
    assert!(was_reset(pair.server_conn_mut(server_ch)));
}

/// A peer move waiting for an unused connection ID is dropped when newer non-probing traffic
/// arrives on the current path: the connection IDs that come later do not revive it, and nothing
/// is ever sent to the address the peer left again.
#[test]
fn a_deferred_peer_move_is_dropped_when_the_peer_is_back_on_the_current_path() {
    let _guard = subscribe();
    let mut pair = Pair::default();
    let (client_ch, server_ch) = pair.connect();
    pair.drive();
    exhaust_server_cids(&mut pair, client_ch, server_ch);
    let current = pair.server_conn_mut(server_ch).remote_address();

    let elsewhere = SocketAddr::new(
        Ipv4Addr::new(127, 0, 0, 1).into(),
        CLIENT_PORTS.lock().next().unwrap(),
    );
    pair.client.addr = elsewhere;
    assert!(pair.client_migrate_local_address(client_ch));
    pair.drive_client();
    pair.server.drive(pair.time, elsewhere);
    assert!(pair.server_conn_mut(server_ch).deferred_move_pending());
    assert_eq!(pair.server_conn_mut(server_ch).remote_address(), current);
    pair.server.outbound.clear();

    // Back on the current path with newer non-probing traffic.
    pair.client.addr = current;
    pair.client_conn_mut(client_ch).ping();
    pair.drive_client();
    pair.server.drive(pair.time, current);
    assert!(
        !pair.server_conn_mut(server_ch).deferred_move_pending(),
        "traffic on the current path supersedes the pending move"
    );
    pair.server.outbound.clear();

    // The delayed connection IDs arrive; the obsolete move is not revived, traffic recovers.
    pair.client.release_held_identifiers();
    settle_checking_server_destinations(&mut pair, &[current]);
    assert_eq!(pair.server_conn_mut(server_ch).remote_address(), current);
    assert!(!pair.server_conn_mut(server_ch).deferred_move_pending());
    assert!(!pair.server_conn_mut(server_ch).is_closed());
    let s = pair.server_streams(server_ch).open(Dir::Uni).unwrap();
    pair.server_send(server_ch, s).write(b"recovered").unwrap();
    settle_checking_server_destinations(&mut pair, &[current]);
    assert_matches!(
        pair.client_conn_mut(client_ch).poll(),
        Some(Event::Stream(StreamEvent::Opened { dir: Dir::Uni })),
    );
}

/// The destination connection IDs the server has sent, per address it sent them to.
fn server_dcids_by_destination(pair: &Pair, len: usize) -> FxHashMap<SocketAddr, Vec<Vec<u8>>> {
    let mut seen: FxHashMap<SocketAddr, Vec<Vec<u8>>> = FxHashMap::default();
    for (transmit, buffer) in pair.server.outbound.iter() {
        if buffer.first().is_some_and(|first| first & 0x80 != 0) {
            continue; // long header: handshake traffic
        }
        if let Some(cid) = buffer.get(1..1 + len) {
            seen.entry(transmit.destination)
                .or_default()
                .push(cid.to_vec());
        }
    }
    seen
}

/// Every short-header datagram still in the server's send queue, as the tuple the engine emitted:
/// the local address it belongs to, where it goes, and the connection ID it carries.
fn server_emitted(pair: &Pair, len: usize) -> Vec<(Option<SocketAddr>, SocketAddr, Vec<u8>)> {
    pair.server
        .outbound
        .iter()
        .filter(|(_, buffer)| buffer.first().is_some_and(|first| first & 0x80 == 0))
        .filter_map(|(transmit, buffer)| {
            Some((
                transmit.local,
                transmit.destination,
                buffer.get(1..1 + len)?.to_vec(),
            ))
        })
        .collect()
}

/// RFC 9000 §8.2.2 and §9.5 in one datagram: the challenge that validates the path a peer move
/// left behind goes out on that path, with that path's local and remote address, and
/// carries the identifier kept for it, not the one the connection moved to.
#[test]
fn the_challenge_for_a_replaced_path_carries_that_paths_local_address_and_identifier() {
    let _guard = subscribe();
    let mut pair = Pair::default();
    let (client_ch, server_ch) = pair.connect();
    drive_settled(&mut pair);
    let previous = pair.client.addr;
    let local = pair.server.addr;
    let len = pair.server_conn_mut(server_ch).active_rem_cid().len();
    let kept = pair.server_conn_mut(server_ch).active_rem_cid();

    // A deliberate move: the server follows it with a fresh identifier and keeps the one it was
    // using for the path it left, which it now owes a challenge.
    let moved = SocketAddr::new(
        Ipv4Addr::new(127, 0, 0, 7).into(),
        CLIENT_PORTS.lock().next().unwrap(),
    );
    pair.client.addr = moved;
    assert!(pair.client_migrate_local_address(client_ch));
    pair.drive_client();
    pair.server.outbound.clear();
    pair.server.drive(pair.time, moved);
    assert_eq!(pair.server_conn_mut(server_ch).remote_address(), moved);
    assert_eq!(pair.server_conn_mut(server_ch).held_rem_cid(), Some(kept));

    let emitted = server_emitted(&pair, len);
    let to_previous: Vec<_> = emitted
        .iter()
        .filter(|&&(_, remote, _)| remote == previous)
        .collect();
    assert_eq!(
        to_previous.len(),
        1,
        "one datagram for the path left behind, out of {emitted:?}"
    );
    assert_eq!(
        (to_previous[0].0, to_previous[0].1, &to_previous[0].2[..]),
        (Some(local), previous, &kept[..]),
        "the challenge names the path it validates and the identifier kept for it"
    );
    assert!(
        emitted.iter().any(|&(l, remote, ref cid)| l == Some(local)
            && remote == moved
            && cid[..] != kept[..]),
        "and the path moved to has a fresh identifier of its own: {emitted:?}"
    );
}

/// RFC 9000 §8.2.2 and §9.5 for a challenge that arrives on a path the connection does not send
/// on: the answer leaves on that path, with an unused identifier bound to it rather than the one
/// the connection sends elsewhere. Here the client probes the address the server advertised and
/// the server knows which of its own addresses received the probe, so that path is not the one it
/// is on. Binding is what makes the answer legal, and the identifier stays bound to that path.
#[test]
fn an_off_path_challenge_is_answered_with_an_identifier_bound_to_that_path() {
    let _guard = subscribe();
    let (mut pair, preferred) = pair_preferring(true);
    let (ch, server_ch) = connect_armed(&mut pair);
    let server_addr = pair.server.addr;
    let elsewhere = pair.server_conn_mut(server_ch).active_rem_cid();
    let len = elsewhere.len();
    let spares = pair.server_conn_mut(server_ch).unused_rem_cids().len();
    assert!(spares > 1, "the server has identifiers to bind: {spares}");

    probe_once(&mut pair, server_ch);
    assert_eq!(
        addressed_to(&pair, preferred),
        1,
        "the client probed the preferred address"
    );

    // `probe_once` left the server's answer in its send queue: the answer went out on the path
    // the probe arrived on, with an identifier of its own.
    let answers: Vec<_> = server_emitted(&pair, len)
        .into_iter()
        .filter(|&(local, ..)| local == Some(preferred))
        .collect();
    assert_eq!(
        answers.len(),
        1,
        "one answer on that path, out of {:?}",
        server_emitted(&pair, len)
    );
    let (_, remote, bound) = answers[0].clone();
    assert_eq!(remote, pair.client.addr, "addressed to the peer");
    assert_ne!(
        &bound[..],
        &elsewhere[..],
        "not the identifier the connection sends on its own path"
    );
    assert_eq!(
        pair.server_conn_mut(server_ch)
            .stats()
            .path
            .unanswered_off_path_challenges,
        0,
        "nothing was dropped for want of an identifier"
    );
    assert!(
        !pair
            .server_conn_mut(server_ch)
            .unused_rem_cids()
            .iter()
            .any(|cid| cid[..] == bound[..]),
        "an identifier spent on a path does not go back to the unused ones"
    );
    assert_eq!(
        pair.server_conn_mut(server_ch).unused_rem_cids().len(),
        spares - 1,
        "exactly one identifier was spent"
    );
    assert_eq!(
        pair.server_conn_mut(server_ch).active_rem_cid(),
        elsewhere,
        "and the path the server is on still has the one it had"
    );

    // The binding lasts: the client moves to that address and the identifier stays spent, never
    // returning to the unused ones for another path to take.
    pair.client_conn_mut(ch).ping();
    drive_settled(&mut pair);
    assert_eq!(pair.client_conn_mut(ch).remote_address(), preferred);
    assert!(
        !pair
            .server_conn_mut(server_ch)
            .unused_rem_cids()
            .iter()
            .any(|cid| cid[..] == bound[..]),
        "the identifier bound to that path is still not one of the unused"
    );
    assert!(!pair.client_conn_mut(ch).is_closed());
    assert!(
        !pair.server_conn_mut(server_ch).is_closed(),
        "the connection is unharmed"
    );
    let _ = server_addr;
}

/// The identifier the server answered with on (`local`, `remote`), if it answered there.
fn answer_on(pair: &Pair, local: SocketAddr, remote: SocketAddr, len: usize) -> Option<Vec<u8>> {
    server_emitted(pair, len)
        .into_iter()
        .find(|&(l, r, _)| l == Some(local) && r == remote)
        .map(|(_, _, cid)| cid)
}

/// Move the client to `from` and let it probe `preferred` again. The server's answer is left in
/// its send queue and returned. Time advances to the client's own timer, which paces probing.
fn probe_from(
    pair: &mut Pair,
    from: SocketAddr,
    preferred: SocketAddr,
    len: usize,
) -> Option<Vec<u8>> {
    pair.client.addr = from;
    for _ in 0..32 {
        pair.server.outbound.clear();
        if let Some(at) = pair.client.next_wakeup() {
            pair.time = pair.time.max(at);
        }
        pair.drive_client();
        pair.server.drive(pair.time, from);
        if let Some(answer) = answer_on(pair, preferred, from, len) {
            return Some(answer);
        }
    }
    None
}

/// RFC 9000 §9.5 for two paths at once: each path the connection does not send on gets an
/// identifier of its own, and a further challenge on the first is answered with that path's
/// identifier. Refusal once nothing is left to bind is covered by
/// `an_off_path_challenge_with_no_identifier_to_bind_is_counted_and_dropped`.
#[test]
fn two_off_path_bindings_keep_their_own_identifiers() {
    let _guard = subscribe();
    let (mut pair, preferred) = pair_preferring(true);
    let (ch, server_ch) = connect_armed(&mut pair);
    let own = pair.server_conn_mut(server_ch).active_rem_cid();
    let len = own.len();
    let spares = pair.server_conn_mut(server_ch).unused_rem_cids().len();
    assert!(spares > 2, "the server has identifiers to bind: {spares}");

    let first_from = pair.client.addr;
    let second_from = SocketAddr::new(
        Ipv4Addr::new(127, 0, 0, 9).into(),
        CLIENT_PORTS.lock().next().unwrap(),
    );
    let dcid = pair.client_conn_mut(ch).active_rem_cid();
    let mut answers = Vec::new();
    // Probe three tuples directly. Do not advance a client recovery timer here:
    // an unrelated ACK from a new source would migrate the original path and
    // correctly abandon its preferred candidate and reserved identifier.
    for (index, from) in [first_from, second_from, first_from]
        .into_iter()
        .enumerate()
    {
        let mut frames = vec![0x1a]; // PATH_CHALLENGE
        frames.extend_from_slice(&(index as u64 + 1).to_be_bytes());
        let now = pair.time;
        let packet = pair
            .client_conn_mut(ch)
            .encode_peer_packet_for_test(now, dcid, &frames);
        pair.server.outbound.clear();
        pair.server.inbound.push_back(Inbound {
            at: now,
            ecn: None,
            packet,
            from: Some(from),
            to: Some(preferred),
        });
        pair.server.drive(now, from);
        answers
            .push(answer_on(&pair, preferred, from, len).expect("an answer on the probed tuple"));
        assert_eq!(
            pair.server_conn_mut(server_ch).path_local(),
            Some(pair.server.addr)
        );
    }
    let (first, second) = (&answers[0], &answers[1]);
    assert_ne!(first, second, "the two paths hold different identifiers");
    assert_ne!(&first[..], &own[..]);
    assert_ne!(&second[..], &own[..]);
    assert_eq!(&answers[2], first, "the first path kept its own identifier");

    // Both bindings are held at once: two identifiers were spent, and neither went back to the
    // unused ones for another path to take.
    assert_eq!(
        pair.server_conn_mut(server_ch).unused_rem_cids().len(),
        spares - 2,
        "exactly two identifiers were spent"
    );
    for bound in [&first, &second] {
        assert!(
            !pair
                .server_conn_mut(server_ch)
                .unused_rem_cids()
                .iter()
                .any(|cid| cid[..] == bound[..]),
            "an identifier bound to a path is not one of the unused: {bound:?}"
        );
    }
    assert!(!pair.client_conn_mut(ch).is_closed());
    assert!(!pair.server_conn_mut(server_ch).is_closed());
}

/// The other side of that guard: with no identifier to bind, the answer is dropped and the
/// connection says so rather than answering with one it sends from another local address. The
/// peer here issues nothing beyond the handshake, so the server has none to spare.
#[test]
fn an_off_path_challenge_with_no_identifier_to_bind_is_counted_and_dropped() {
    let _guard = subscribe();
    let (mut pair, preferred) = pair_preferring(true);
    // The client issues no connection IDs of its own, so the server has only the one it is using.
    pair.client.hold_identifiers = true;
    let (ch, server_ch) = connect_armed(&mut pair);
    let server_addr = pair.server.addr;
    let only = pair.server_conn_mut(server_ch).active_rem_cid();
    let probes_before = addressed_to(&pair, preferred);
    assert!(
        pair.server_conn_mut(server_ch).unused_rem_cids().is_empty(),
        "the server has nothing to bind"
    );

    let sent_before = pair.server_sent.len();
    probe_once(&mut pair, server_ch);
    assert_eq!(addressed_to(&pair, preferred), 1);
    assert_eq!(
        pair.server_conn_mut(server_ch)
            .stats()
            .path
            .unanswered_off_path_challenges,
        1,
        "the answer was dropped for want of an identifier"
    );
    // The counter says the answer was dropped. The transcript of what the server sent in this
    // window says nothing went out towards the probed address in its place. Reading the live
    // queue instead would depend on whether a drive had already emptied it.
    let emitted: Vec<_> = pair.server_sent[sent_before..]
        .iter()
        .filter(|sent| sent.to == preferred)
        .collect();
    assert!(
        emitted.is_empty(),
        "the dropped answer was not replaced: {emitted:?}"
    );
    assert_eq!(
        pair.server_conn_mut(server_ch).active_rem_cid(),
        only,
        "and the identifier in use was not sent from another address"
    );

    // The client gives the attempt up and stays where it is; both sides are unharmed.
    drive_settled(&mut pair);
    assert_eq!(
        pair.client_conn_mut(ch).preferred_address_state(),
        PreferredAddressState::Failed,
        "nothing ever answered the probes"
    );
    assert!(
        addressed_to(&pair, preferred) > probes_before,
        "the client did keep probing, so the state above is a real failure to answer"
    );
    assert_eq!(pair.client_conn_mut(ch).remote_address(), server_addr);
    assert!(!pair.client_conn_mut(ch).is_closed());
    assert!(!pair.server_conn_mut(server_ch).is_closed());
}

#[test]
fn descending_connection_ids_preserve_spares_for_the_first_preferred_probe() {
    let (mut pair, preferred) = pair_preferring(true);
    pair.client.hold_identifiers = true;
    let (client, server) = connect_armed(&mut pair);
    pair.client.release_held_identifiers();
    let issued = pair.client_conn_mut(client).send_pending_cids_descending();
    assert!(issued.len() >= 4);
    pair.drive_client();
    pair.drive_server();
    assert_eq!(pair.server_conn_mut(server).active_rem_cid(), issued[0].1);
    let mut unused = pair.server_conn_mut(server).unused_rem_cid_seqs();
    unused.sort_unstable();
    assert_eq!(
        unused,
        issued[1..].iter().map(|cid| cid.0).collect::<Vec<_>>()
    );
    pair.client.capture_inbound_packets = true;
    pair.client.drive_incoming(pair.time, pair.server.addr);
    let retired: Vec<_> = pair
        .client
        .captured_packets
        .iter()
        .flat_map(|packet| {
            frame::Iter::new(packet.clone().into())
                .unwrap()
                .filter_map(|frame| match frame.unwrap() {
                    Frame::RetireConnectionId { sequence } => Some(sequence),
                    _ => None,
                })
                .collect::<Vec<_>>()
        })
        .collect();
    assert_eq!(retired, [0]);
    probe_once(&mut pair, server);
    pair.drive_server();
    pair.drive_client();
    assert_eq!(pair.client_conn_mut(client).remote_address(), preferred);
    assert_eq!(
        pair.client_conn_mut(client)
            .stats()
            .path
            .preferred_address_probes,
        1
    );
    assert_eq!(
        pair.server_conn_mut(server)
            .stats()
            .path
            .unanswered_off_path_challenges,
        0
    );
    drive_settled(&mut pair);
}

/// RFC 9000 §9.5 across two moves of different kinds: a rebinding keeps the identifier in use, and
/// a deliberate move that follows before the rebound path is validated takes a fresh one. No
/// identifier is ever sent to two addresses, the old path included.
#[test]
fn no_identifier_is_sent_to_two_addresses_across_a_rebinding_and_a_move() {
    let _guard = subscribe();
    let mut pair = Pair::default();
    let (client_ch, server_ch) = pair.connect();
    drive_settled(&mut pair);
    let len = pair.server_conn_mut(server_ch).active_rem_cid().len();
    let first = pair.client.addr;

    // A rebinding: the same identifier from a new address, which the server may keep using.
    let rebound = SocketAddr::new(
        Ipv4Addr::new(127, 0, 0, 7).into(),
        CLIENT_PORTS.lock().next().unwrap(),
    );
    pair.client.addr = rebound;
    pair.client_conn_mut(client_ch).ping();
    pair.drive_client();
    pair.server.drive_incoming(pair.time, rebound);

    // A deliberate move before the server has transmitted anything, so it still owes the address
    // it started on a challenge when it takes a fresh identifier for the newest path.
    let moved = SocketAddr::new(
        Ipv4Addr::new(127, 0, 0, 8).into(),
        CLIENT_PORTS.lock().next().unwrap(),
    );
    pair.client.addr = moved;
    assert!(pair.client_migrate_local_address(client_ch));
    pair.drive_client();
    pair.server.drive_incoming(pair.time, moved);
    pair.server.drive_outgoing(pair.time);
    assert_eq!(pair.server_conn_mut(server_ch).remote_address(), moved);

    // The newest path's identifier went nowhere else, and no identifier reached both an old
    // address and the new one. The rebinding pair may share one: that is the §9.5 exception.
    let sent = server_dcids_by_destination(&pair, len);
    let to_moved = sent.get(&moved).cloned().unwrap_or_default();
    assert!(!to_moved.is_empty(), "the server sent to the newest path");
    for (address, cids) in sent.iter() {
        if *address == moved {
            continue;
        }
        for cid in cids {
            assert!(
                !to_moved.contains(cid),
                "connection ID {cid:?} was sent to {address} and to {moved}"
            );
        }
    }
    // Nothing goes to the address it started on: the identifier that path was sent with is the
    // one this switch left behind, so that path has none of its own any more.
    assert!(
        !sent.contains_key(&first),
        "an address whose identifier is gone is not sent to: {:?}",
        sent.keys().collect::<Vec<_>>()
    );
    assert!(!pair.server_conn_mut(server_ch).is_closed());
}

/// A rebinding keeps the identifier, so the address it left stays reachable with that one; once
/// the connection leaves that identifier for one the old address never saw, the old path has none
/// of its own any more (RFC 9000 §9.5). Nothing then waits for a route to it, which would hold up
/// every datagram behind it, and no identifier goes to two addresses.
#[test]
fn leaving_the_identifier_a_rebinding_kept_orphans_the_previous_path() {
    let _guard = subscribe();
    let mut pair = Pair::default();
    let (client_ch, server_ch) = pair.connect();
    drive_settled(&mut pair);

    let rebound = SocketAddr::new(
        Ipv4Addr::new(127, 0, 0, 7).into(),
        CLIENT_PORTS.lock().next().unwrap(),
    );
    pair.client.addr = rebound;
    pair.client_conn_mut(client_ch).ping();
    pair.drive_client();
    pair.server.drive(pair.time, rebound);
    assert_eq!(pair.server_conn_mut(server_ch).remote_address(), rebound);
    let kept = pair.server_conn_mut(server_ch).active_rem_cid_seq();
    // What the server sent on both paths is lost, so each challenge is still owed.
    pair.server.outbound.clear();

    // The server leaves the identifier both addresses saw before it sends anything more.
    let now = pair.time;
    assert!(pair.server_conn_mut(server_ch).migrate_local_address(now));
    assert_ne!(pair.server_conn_mut(server_ch).active_rem_cid_seq(), kept);
    pair.server.drive_outgoing(pair.time);
    drive_settled(&mut pair);

    let mut addresses: FxHashMap<u64, SocketAddr> = FxHashMap::default();
    for sent in &pair.server_sent {
        let Some(seq) = sent.cid.filter(|seq| *seq != kept) else {
            continue;
        };
        let address = *addresses.entry(seq).or_insert(sent.to);
        assert_eq!(
            address, sent.to,
            "connection ID {seq} was sent to {address} and to {}",
            sent.to
        );
    }
    assert!(!pair.server_conn_mut(server_ch).is_closed());
}

/// A second peer move before the first is validated does not replace the path kept as a
/// fallback: the connection returns to the address it was using when validation fails, not to the
/// unvalidated one in between (RFC 9000 §9.3.3).
#[test]
fn a_second_move_before_validation_keeps_the_original_path() {
    let _guard = subscribe();
    let mut pair = Pair::default();
    let (client_ch, server_ch) = pair.connect();
    drive_settled(&mut pair);
    let original = pair.client.addr;

    // Two moves in a row, the second before the first path is validated. Nothing answers at
    // either, so the server's own validation is what decides.
    for _ in 0..2 {
        pair.client.addr = SocketAddr::new(
            Ipv4Addr::new(127, 0, 0, 7).into(),
            CLIENT_PORTS.lock().next().unwrap(),
        );
        pair.client_conn_mut(client_ch).ping();
        pair.drive_client();
        pair.server.drive(pair.time, pair.client.addr);
        pair.server.outbound.clear();
    }
    let unvalidated = pair.client.addr;
    assert_eq!(
        pair.server_conn_mut(server_ch).remote_address(),
        unvalidated
    );
    pair.client.addr = original;

    // Validation fails on the path the server is on; it goes back to where it started.
    let mut steps = 0;
    while pair.server_conn_mut(server_ch).remote_address() == unvalidated {
        pair.server.outbound.clear();
        let next = pair
            .server
            .next_wakeup()
            .expect("a validation deadline is pending");
        pair.time = pair.time.max(next);
        pair.server.drive(pair.time, original);
        steps += 1;
        assert!(steps < 64, "the server did not leave the unvalidated path");
    }
    assert_eq!(
        pair.server_conn_mut(server_ch).remote_address(),
        original,
        "the fallback is the path the connection was using, not the one it passed through"
    );
    assert!(!pair.server_conn_mut(server_ch).is_closed());
    let s = pair.server_streams(server_ch).open(Dir::Uni).unwrap();
    pair.server_send(server_ch, s).write(b"back home").unwrap();
    settle_checking_server_destinations(&mut pair, &[original]);
    assert!(saw_uni_stream(pair.client_conn_mut(client_ch)));
}

/// A peer that moves again while its first move waits for an unused connection ID is followed
/// to where it is now, never to the address it left in between.
#[test]
fn a_deferred_peer_move_follows_the_latest_candidate() {
    let _guard = subscribe();
    let mut pair = Pair::default();
    let (client_ch, server_ch) = pair.connect();
    pair.drive();
    exhaust_server_cids(&mut pair, client_ch, server_ch);
    let current = pair.server_conn_mut(server_ch).remote_address();

    let mut latest = current;
    for index in 0..40 {
        latest = SocketAddr::new(
            Ipv4Addr::LOCALHOST.into(),
            CLIENT_PORTS.lock().next().unwrap(),
        );
        pair.client.addr = latest;
        if index == 0 {
            assert!(pair.client_migrate_local_address(client_ch));
        } else {
            pair.client_conn_mut(client_ch).ping();
        }
        pair.drive_client();
        assert!(
            !pair.server.inbound.is_empty(),
            "candidate {index} actually sent a packet"
        );
        pair.server.drive(pair.time, latest);
        assert!(pair.server_conn_mut(server_ch).deferred_move_pending());
        assert_eq!(pair.server_conn_mut(server_ch).remote_address(), current);
        assert!(!pair.server_conn_mut(server_ch).can_migrate_locally());
        pair.server.outbound.clear();
    }

    pair.client.release_held_identifiers();
    settle_checking_server_destinations(&mut pair, &[current, latest]);
    assert_eq!(pair.server_conn_mut(server_ch).remote_address(), latest);
    assert!(!pair.server_conn_mut(server_ch).deferred_move_pending());
    assert!(!pair.server_conn_mut(server_ch).is_closed());
    assert!(!pair.client_conn_mut(client_ch).is_closed());
}

/// A deliberate-looking move (changed destination connection ID) from an address the peer is
/// not at (forwarded by an attacker) makes the server follow it with a fresh connection ID; when
/// that path fails validation the server returns to the previous path and to the identifier kept
/// for it, and retires the one it used towards the failed path.
#[test]
fn a_failed_peer_migration_returns_to_the_previous_path_with_its_connection_id() {
    let _guard = subscribe();
    let mut pair = Pair::default();
    let (client_ch, server_ch) = pair.connect();
    pair.drive();
    let real = pair.client.addr;
    let real_cid = pair.server_conn_mut(server_ch).active_rem_cid();

    let spoofed = SocketAddr::new(
        Ipv4Addr::new(127, 0, 0, 7).into(),
        CLIENT_PORTS.lock().next().unwrap(),
    );
    pair.client.addr = spoofed;
    assert!(pair.client_migrate_local_address(client_ch));
    pair.drive_client();
    pair.server.drive(pair.time, spoofed);
    pair.client.addr = real;
    assert_eq!(pair.server_conn_mut(server_ch).remote_address(), spoofed);
    let used_towards_spoofed = pair.server_conn_mut(server_ch).active_rem_cid();
    assert_ne!(used_towards_spoofed, real_cid);
    assert_eq!(
        pair.server_conn_mut(server_ch).held_rem_cid(),
        Some(real_cid)
    );

    // Nobody answers at the spoofed address: the server's validation fails and it returns.
    let mut steps = 0;
    while pair.server_conn_mut(server_ch).remote_address() == spoofed {
        pair.server.outbound.clear();
        let next = pair
            .server
            .next_wakeup()
            .expect("a validation deadline is pending");
        pair.time = pair.time.max(next);
        pair.server.drive(pair.time, real);
        steps += 1;
        assert!(steps < 64, "the server did not return to the previous path");
    }
    assert_eq!(pair.server_conn_mut(server_ch).active_rem_cid(), real_cid);
    assert_eq!(pair.server_conn_mut(server_ch).held_rem_cid(), None);
    pair.server.outbound.clear();

    // Both directions work on the real path; the peer learns the abandoned identifier is retired
    // and replaces it.
    let spares_before = pair.server_conn_mut(server_ch).unused_rem_cids().len();
    let s = pair.server_streams(server_ch).open(Dir::Uni).unwrap();
    pair.server_send(server_ch, s).write(b"back").unwrap();
    settle_checking_server_destinations(&mut pair, &[real]);
    assert_matches!(
        pair.client_conn_mut(client_ch).poll(),
        Some(Event::Stream(StreamEvent::Opened { dir: Dir::Uni })),
    );
    assert!(
        pair.server_conn_mut(server_ch).unused_rem_cids().len() > spares_before,
        "the retired identifier was replaced"
    );
    assert!(
        !pair
            .server_conn_mut(server_ch)
            .unused_rem_cids()
            .contains(&used_towards_spoofed),
        "the identifier used towards the failed path is not reused"
    );
}

/// The same failure after a NAT rebinding (same destination connection ID from a new address):
/// the server kept its identifier for the new address, so returning keeps it too and retires
/// nothing.
#[test]
fn a_failed_nat_rebinding_returns_to_the_previous_path_keeping_the_connection_id() {
    let _guard = subscribe();
    let mut pair = Pair::default();
    let (client_ch, server_ch) = pair.connect();
    pair.drive();
    let real = pair.client.addr;
    let cid = pair.server_conn_mut(server_ch).active_rem_cid();
    let spares = pair.server_conn_mut(server_ch).unused_rem_cids();

    let rebound = SocketAddr::new(
        Ipv4Addr::new(127, 0, 0, 7).into(),
        CLIENT_PORTS.lock().next().unwrap(),
    );
    pair.client.addr = rebound;
    pair.client_conn_mut(client_ch).ping();
    pair.drive_client();
    pair.server.drive(pair.time, rebound);
    pair.client.addr = real;
    assert_eq!(pair.server_conn_mut(server_ch).remote_address(), rebound);
    assert_eq!(pair.server_conn_mut(server_ch).active_rem_cid(), cid);
    assert_eq!(pair.server_conn_mut(server_ch).held_rem_cid(), None);

    let mut steps = 0;
    while pair.server_conn_mut(server_ch).remote_address() == rebound {
        pair.server.outbound.clear();
        let next = pair
            .server
            .next_wakeup()
            .expect("a validation deadline is pending");
        pair.time = pair.time.max(next);
        pair.server.drive(pair.time, real);
        steps += 1;
        assert!(steps < 64, "the server did not return to the previous path");
    }
    assert_eq!(pair.server_conn_mut(server_ch).active_rem_cid(), cid);
    assert_eq!(pair.server_conn_mut(server_ch).unused_rem_cids(), spares);
    pair.server.outbound.clear();
    let s = pair.server_streams(server_ch).open(Dir::Uni).unwrap();
    pair.server_send(server_ch, s).write(b"back").unwrap();
    settle_checking_server_destinations(&mut pair, &[real]);
    assert_matches!(
        pair.client_conn_mut(client_ch).poll(),
        Some(Event::Stream(StreamEvent::Opened { dir: Dir::Uni })),
    );
}

/// Deliberate client migrations (fresh client DCID each time) make the server take a fresh
/// destination connection ID each time and retire the previous one once the new path is
/// validated. The client is slow to issue replacements (its endpoint holds them back), so the
/// server ends up without spares on a validated path while the client keeps its own spares. The
/// held replacements are released with `pair.client.release_held_identifiers()`.
fn exhaust_server_cids(pair: &mut Pair, client_ch: ConnectionHandle, server_ch: ConnectionHandle) {
    pair.client.hold_identifiers = true;
    // One move per spare would do if every path validated at once, but a datagram that waits for
    // its route to be installed can carry a challenge into the next step, so this drives to the
    // state it is after, no spares left, within a budget rather than counting moves.
    let mut moves = 0;
    while pair.server_conn_mut(server_ch).can_migrate_locally() {
        moves += 1;
        assert!(
            moves <= crate::proto::cid_queue::CidQueue::LEN * 4,
            "the server still had a spare identifier after {moves} moves"
        );
        pair.client.addr = SocketAddr::new(
            Ipv4Addr::new(127, 0, 0, 1).into(),
            CLIENT_PORTS.lock().next().unwrap(),
        );
        assert!(pair.client_migrate_local_address(client_ch));
        drive_settled(pair);
        assert_eq!(
            pair.server_conn_mut(server_ch).remote_address(),
            pair.client.addr
        );
        assert_eq!(
            pair.server_conn_mut(server_ch).held_rem_cid(),
            None,
            "the validated move retired the previous path's identifier"
        );
    }
    assert!(!pair.server_conn_mut(server_ch).can_migrate_locally());
    assert!(moves >= 1, "the server started with spares to exhaust");
}

/// RFC 9000 §9.5 on the server: a peer that moves and keeps sending the same destination
/// connection ID (a NAT rebinding, here to another IP) may keep being answered with the current
/// connection ID; a peer that moves and changes the destination connection ID (a deliberate
/// migration, here port-only) needs an unused connection ID on our side. With none available the
/// move is deferred (no packet leaves for the new tuple) and completes when the peer issues one.
#[test]
fn a_peer_move_needs_an_unused_cid_unless_it_is_a_nat_rebinding() {
    let _guard = subscribe();
    let mut pair = Pair::default();
    let (client_ch, server_ch) = pair.connect();
    pair.drive();
    exhaust_server_cids(&mut pair, client_ch, server_ch);
    let before = pair
        .server_conn_mut(server_ch)
        .stats()
        .path
        .deferred_migrations;
    let last_followed = pair.server_conn_mut(server_ch).remote_address();
    let followed_seq = pair.server_conn_mut(server_ch).active_rem_cid_seq();
    // The server has something to say during the deferral, so the record below cannot be empty
    // and what it asserts about is where that traffic went.
    let outgoing = pair.server_streams(server_ch).open(Dir::Uni).unwrap();
    pair.server_send(server_ch, outgoing)
        .write(b"still on the old path")
        .unwrap();
    let sent_before = pair.server_sent.len();

    // Port-only move with a changed destination connection ID: deferred.
    pair.client.addr = SocketAddr::new(
        Ipv4Addr::new(127, 0, 0, 1).into(),
        CLIENT_PORTS.lock().next().unwrap(),
    );
    assert!(pair.client_conn_mut(client_ch).can_migrate_locally());
    assert!(pair.client_migrate_local_address(client_ch));
    pair.drive_client();
    pair.drive_server();
    assert_eq!(
        pair.server_conn_mut(server_ch).remote_address(),
        last_followed,
        "no send towards the new tuple without an unused connection ID"
    );
    assert!(
        pair.server_conn_mut(server_ch)
            .stats()
            .path
            .deferred_migrations
            > before
    );
    // The queue itself is drained by every drive, so this reads the transcript recorded as the
    // datagrams left. It also has to be non-empty: an empty record would satisfy `all` trivially.
    let emitted = &pair.server_sent[sent_before..];
    assert!(
        !emitted.is_empty(),
        "the server sent nothing while the move was deferred, so this window says nothing about \
         where its traffic went — it had a stream to send"
    );
    for sent in emitted {
        assert_eq!(
            sent.to, last_followed,
            "the server sent to {} while it may only use {last_followed}",
            sent.to
        );
        assert_eq!(
            sent.cid,
            Some(followed_seq),
            "and with the identifier that path owns"
        );
    }
    pair.server.outbound.clear();
    // The peer gets round to issuing replacement connection IDs: the deferred move completes
    // with a fresh ID.
    pair.client.release_held_identifiers();
    pair.drive();
    assert_eq!(
        pair.server_conn_mut(server_ch).remote_address(),
        pair.client.addr
    );
    assert!(!pair.client_conn_mut(client_ch).is_closed());
    assert!(!pair.server_conn_mut(server_ch).is_closed());

    // Different IP, same destination connection ID (the client did not switch): NAT rebinding,
    // followed at once with the current connection ID even though no spare exists.
    exhaust_server_cids(&mut pair, client_ch, server_ch);
    pair.client.addr = SocketAddr::new(
        Ipv4Addr::new(127, 0, 0, 9).into(),
        CLIENT_PORTS.lock().next().unwrap(),
    );
    let before = pair
        .server_conn_mut(server_ch)
        .stats()
        .path
        .deferred_migrations;
    pair.client_conn_mut(client_ch).ping();
    pair.drive_client();
    pair.drive_server();
    assert_eq!(
        pair.server_conn_mut(server_ch).remote_address(),
        pair.client.addr,
        "a NAT rebinding is followed without a fresh connection ID"
    );
    assert_eq!(
        pair.server_conn_mut(server_ch)
            .stats()
            .path
            .deferred_migrations,
        before
    );
    pair.drive();
    assert!(!pair.server_conn_mut(server_ch).is_closed());
}

#[test]
fn blocked_early_open_does_not_generate_extra_initial_packets() {
    let mut pair = Pair::default();
    let ch = pair.begin_connect(client_config());
    assert!(pair.client_streams(ch).open(Dir::Uni).is_none());
    let now = pair.time;
    let conn = pair.client_conn_mut(ch);
    let mut buf = Vec::new();
    assert!(conn.poll_transmit(now, 1, &mut buf).is_some());
    buf.clear();
    assert!(
        conn.poll_transmit(now + Duration::from_secs(1), 1, &mut buf)
            .is_none(),
        "the blocked stream must not create another Initial packet"
    );
}

/// A ClientHello spanning several Initial packets leaves in one burst: the first flight is
/// within the initial congestion window, so it neither waits for a pacing interval nor for
/// the server's acknowledgement of its first packet (RFC 9002 §7.7).
#[test]
fn a_client_hello_spanning_initials_leaves_in_one_burst() {
    let _guard = subscribe();
    let mut pair = Pair::default();
    let protocols = (0..24u8).map(|n| vec![b'a' + n; 96]).collect();
    pair.begin_connect(ClientConfig::new(Arc::new(client_crypto_with_alpn(
        protocols,
    ))));
    pair.drive_client();
    let initials = pair
        .client_sent
        .iter()
        .filter(|sent| {
            sent.packets.iter().any(|packet| {
                packet.long_kind() == Some(rama_quic_proto::version::LongKind::Initial)
            })
        })
        .count();
    assert!(
        initials >= 2,
        "the whole ClientHello leaves at once: {initials}"
    );
}

/// A datagram buffered for one pending attempt advances only that attempt's progress, so only
/// its waiter wakes, and each ClientHello assembles from its own packets.
#[test]
fn buffered_datagrams_advance_only_their_own_attempt() {
    let _guard = subscribe();
    let mut pair = Pair::default();
    pair.server.handle_incoming = Box::new(|_| IncomingConnectionBehavior::Wait);
    pair.begin_connect(client_config());
    pair.drive_client();
    pair.drive_server();
    let other = pair.server.waiting_incoming.pop().unwrap();
    let other_before = other.progress().generation();

    let protocols = (0..24u8).map(|n| vec![b'a' + n; 96]).collect();
    pair.begin_connect(ClientConfig::new(Arc::new(client_crypto_with_alpn(
        protocols,
    ))));
    pair.drive_client();
    pair.drive_server();
    let large = pair.server.waiting_incoming.pop().unwrap();
    assert!(
        large.progress().generation() > 0,
        "the rest of the large ClientHello was buffered for its attempt"
    );
    assert_eq!(
        other.progress().generation(),
        other_before,
        "nothing arrived for the other attempt"
    );
    for incoming in [&large, &other] {
        assert!(matches!(
            pair.server.client_hello(incoming),
            ClientHelloPeek::Complete(_)
        ));
    }
    pair.server.ignore(large);
    pair.server.ignore(other);
}

#[test]
fn connections_enforce_the_advertised_active_cid_limit() {
    let _guard = subscribe();
    for explicit in [None, Some(2_u32), Some(5), Some(8)] {
        let mut pair = Pair::default();
        let mut config = client_config();
        let transport = TransportConfig {
            active_connection_id_limit: explicit.map(Into::into),
            ..TransportConfig::default()
        };
        config.set_transport_config(Arc::new(transport));
        let (client, _) = pair.connect_with(config);
        drive_settled(&mut pair);

        // The peer has filled the advertised allowance. A distinct additional
        // identifier must fail even when the implementation has spare storage.
        let now = pair.time;
        let extra = frame::NewConnectionId {
            sequence: 100,
            retire_prior_to: 0,
            id: ConnectionId::new(&[0x6A; 8]),
            reset_token: ResetToken::from([0x6B; RESET_TOKEN_SIZE]),
        };
        let error = pair
            .client_conn_mut(client)
            .apply_new_cid(now, extra)
            .unwrap_err();
        assert_eq!(error.code, TransportErrorCode::CONNECTION_ID_LIMIT_ERROR);
        pair.client_conn_mut(client)
            .apply_new_cid(
                now,
                frame::NewConnectionId {
                    retire_prior_to: 100,
                    ..extra
                },
            )
            .unwrap();
    }
}

/// A late reset can release routing state, but it must not replace an unpolled
/// close reason or report a second loss after the application consumed the first.
#[test]
fn late_stateless_reset_preserves_close_reason() {
    let _guard = subscribe();
    for server in [false, true] {
        for local_close in [false, true] {
            for poll_before_reset in [false, true] {
                let (mut pair, key) = pair_with_known_reset_key();
                let (client_ch, server_ch) = pair.connect();
                pair.drive();
                let now = pair.time;
                let (target, peer, target_ch, peer_ch) = if server {
                    (&mut pair.server, &mut pair.client, server_ch, client_ch)
                } else {
                    (&mut pair.client, &mut pair.server, client_ch, server_ch)
                };
                let target_conn = target.connections.get_mut(&target_ch).unwrap();
                while let Some(event) = target_conn.poll() {
                    assert!(!matches!(event, Event::ConnectionLost { .. }));
                }
                let reset = stateless_reset_for(&key, target_conn.active_rem_cid());
                let peer_addr = peer.addr;
                let reason = ApplicationClose {
                    error_code: VarInt::from_u32(73),
                    reason: Bytes::from_static(b"original application close"),
                };
                if local_close {
                    target_conn.close(now, reason.error_code, reason.reason.clone());
                } else {
                    peer.connections.get_mut(&peer_ch).unwrap().close(
                        now,
                        reason.error_code,
                        reason.reason.clone(),
                    );
                }

                // Exchange close packets at a fixed instant, without advancing
                // the draining timeout. Keep the original error unpolled.
                for _ in 0..3 {
                    pair.drive_client();
                    pair.drive_server();
                }
                let target = if server {
                    &mut pair.server
                } else {
                    &mut pair.client
                };
                let conn = target.connections.get_mut(&target_ch).unwrap();
                assert!(conn.is_closed());
                assert!(!conn.is_drained());
                let mut losses = Vec::new();
                if poll_before_reset {
                    while let Some(event) = conn.poll() {
                        if let Event::ConnectionLost { reason } = event {
                            losses.push(reason);
                        }
                    }
                }

                target
                    .inbound
                    .push_back(Inbound::plain(now, None, reset.as_slice().into()));
                target.drive(now, peer_addr);
                let conn = target.connections.get_mut(&target_ch).unwrap();
                assert!(
                    conn.is_drained(),
                    "the authenticated reset released the route"
                );
                while let Some(event) = conn.poll() {
                    if let Event::ConnectionLost { reason } = event {
                        losses.push(reason);
                    }
                }
                let expected = if local_close {
                    Vec::new()
                } else {
                    vec![ConnectionError::ApplicationClosed(reason)]
                };
                assert_eq!(
                    losses, expected,
                    "server={server}, local={local_close}, polled={poll_before_reset}"
                );
            }
        }
    }
}

mod initial_padding;
