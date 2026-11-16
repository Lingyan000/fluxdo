//! HTTP/3 datagrams (RFC 9297 §2.1) through the public session, over real QUIC connections.

use super::{LIMIT, Pair, qlog::Sink};
use crate::h3::{
    DatagramConfig, DatagramLimits, Error as H3Error, MIN_DATAGRAM_CHARGE, client,
    connection::{Config, Shared},
    qpack::{Encoder, EncoderConfig},
    server::{self, Connection as ServerConnection},
};
use rama_core::{
    bytes::{Buf as _, Bytes, BytesMut},
    extensions::ExtensionsRef as _,
    futures::{FutureExt as _, poll},
    io::AbortIo,
    rt::{Executor, spawn},
};
use rama_http::{
    datagram::{
        CapsuleObservation, DatagramTransport, HttpDatagramSession, NativeDatagrams,
        NativeRecvError, NativeSendError, NativeSendPolicy, NativeSendReady, SessionConfig,
        SessionError, SessionEvent, ViolationPolicy,
    },
    io::upgrade::{OnMalformedMessage, Upgraded, handle_upgrade},
};
use rama_http_types::{
    Body, Method, Request, Response, StatusCode,
    body::util::BodyExt as _,
    proto::{
        capsule::{CapsuleHeader, CapsuleType},
        ext::{HttpDatagrams, Protocol},
        h3::{Code, FrameHeader, FrameType, QuarterStreamId, VarInt},
    },
};
use rama_quic::{Connection as QuicConnection, TransportConfig};
use rama_quic_proto::coding::Codec as _;
use rama_udp::test_utils::{MemoryDatagramControl, MemoryDatagramFaultStats};
use rama_utils::octets::mib;
use std::assert_matches;
use std::{
    pin::{Pin, pin},
    sync::Arc,
    task::{Context, Poll, Waker},
    time::Duration,
};
use tokio::io::{AsyncReadExt as _, AsyncWrite, AsyncWriteExt as _};

const TOKEN: Protocol = Protocol::from_static("x-datagram-test");
const POLICIES: [ViolationPolicy; 2] = [ViolationPolicy::Ignore, ViolationPolicy::Reject];

#[tokio::test]
async fn native_and_reliable_metadata_uses_the_actual_nonzero_tunnel_stream() {
    tokio::time::timeout(LIMIT, async {
        for native in [false, true] {
            let log = Sink::new(true);
            let pair = Pair::in_memory(
                Some(TransportConfig::default().with_qlog_sink(Arc::new(log.clone()))),
                None,
            )
            .await;
            let datagrams = native.then(Default::default);
            let client_config = Config {
                datagrams: datagrams.clone(),
                ..Config::default()
            };
            let (mut client, mut server) =
                start_both(&pair, client_config, server_config(datagrams)).await;
            // The second actual CONNECT uses stream 4, rather than accidentally assuming zero.
            let first = tunnel(&mut client, &mut server, TOKEN).await;
            drop(first);
            let (client_io, server_io) = tunnel(&mut client, &mut server, TOKEN).await;
            assert!(client_io.extensions().contains::<CapsuleObservation>());
            if !native {
                assert!(!client_io.extensions().contains::<NativeDatagrams>());
            }
            let mut client_session = HttpDatagramSession::new(client_io);
            let mut server_session = HttpDatagramSession::new(server_io);
            if native {
                native_ready(&client_session).await;
                native_ready(&server_session).await;
            }
            let expected = if native {
                DatagramTransport::Native
            } else {
                DatagramTransport::Capsule
            };
            assert_eq!(
                client_session
                    .send_datagram(Bytes::from_static(b"private-request-sentinel"))
                    .await
                    .unwrap(),
                expected
            );
            let Some(SessionEvent::Datagram { payload, .. }) = server_session.recv().await.unwrap()
            else {
                panic!("request datagram");
            };
            assert_eq!(&payload[..], b"private-request-sentinel");
            assert_eq!(
                server_session
                    .send_datagram(Bytes::from_static(b"private-response-sentinel"))
                    .await
                    .unwrap(),
                expected
            );
            let Some(SessionEvent::Datagram { payload, .. }) = client_session.recv().await.unwrap()
            else {
                panic!("response datagram");
            };
            assert_eq!(&payload[..], b"private-response-sentinel");
            let rows = log.events.lock().clone();
            if native {
                for name in ["http3:datagram_created", "http3:datagram_parsed"] {
                    let events: Vec<_> = rows.iter().filter(|(event, _)| *event == name).collect();
                    assert_eq!(events.len(), 1);
                    assert_eq!(events[0].1["quarter_stream_id"], 1);
                }
                assert_eq!(log.count("http:capsule_created"), 0);
                assert_eq!(log.count("http:capsule_parsed"), 0);
            } else {
                for name in ["http:capsule_created", "http:capsule_parsed"] {
                    let events: Vec<_> = rows.iter().filter(|(event, _)| *event == name).collect();
                    assert_eq!(events.len(), 1);
                    assert_eq!(events[0].1["stream_id"], 4);
                    assert_eq!(events[0].1["capsule"]["capsule_type"], "datagram");
                }
                assert_eq!(log.count("http3:datagram_created"), 0);
                assert_eq!(log.count("http3:datagram_parsed"), 0);
            }
            let encoded = serde_json::to_string(&rows).unwrap();
            assert!(!encoded.contains("private-request-sentinel"));
            assert!(!encoded.contains("private-response-sentinel"));
            drop(client_session);
            drop(server_session);
            pair.close().await;
        }
    })
    .await
    .unwrap();
}

fn datagrams(limits: DatagramLimits, violations: ViolationPolicy) -> Option<DatagramConfig> {
    Some(DatagramConfig { limits, violations })
}

fn server_config(datagrams: Option<DatagramConfig>) -> Config {
    Config {
        extended_connect: true,
        datagrams,
        ..Config::default()
    }
}

async fn start(
    pair: &Pair,
    server: Config,
) -> (
    client::SendRequest<Body, QuicConnection>,
    ServerConnection<QuicConnection>,
) {
    start_both(pair, Config::default(), server).await
}

async fn start_both(
    pair: &Pair,
    client: Config,
    server: Config,
) -> (
    client::SendRequest<Body, QuicConnection>,
    ServerConnection<QuicConnection>,
) {
    let (client, client_driver) =
        client::handshake::<Body, _>(pair.client.clone(), client, Executor::new()).unwrap();
    let (server, server_driver) = server::handshake(pair.server.clone(), server).unwrap();
    spawn(client_driver.run());
    spawn(server_driver.run());
    (client, server)
}

fn connect(protocol: Protocol, declared: bool) -> Request<Body> {
    let request = Request::builder()
        .method(Method::CONNECT)
        .uri("https://localhost/datagrams")
        .body(Body::empty())
        .unwrap();
    request.extensions().insert(protocol);
    if declared {
        request.extensions().insert(HttpDatagrams);
    }
    request
}

fn accepted(declared: bool) -> Response<Body> {
    let response = Response::new(Body::empty());
    if declared {
        response.extensions().insert(HttpDatagrams);
    }
    response
}

/// Open one Extended CONNECT tunnel, each side declaring datagrams as given.
async fn tunnel_with(
    client: &mut client::SendRequest<Body, QuicConnection>,
    server: &mut ServerConnection<QuicConnection>,
    protocol: Protocol,
    client_declares: bool,
    server_declares: bool,
) -> (Upgraded, Upgraded) {
    let accept = async {
        let (request, response) = server.accept().await.unwrap().resolve().await.unwrap();
        let upgrade = handle_upgrade(&request);
        response
            .send_response(accepted(server_declares))
            .await
            .unwrap();
        upgrade.await.unwrap()
    };
    let (response, server_io) = tokio::join!(
        client.send_request(connect(protocol, client_declares)),
        accept
    );
    let response = response.unwrap();
    assert_eq!(response.status(), StatusCode::OK);
    (handle_upgrade(&response).await.unwrap(), server_io)
}

async fn tunnel(
    client: &mut client::SendRequest<Body, QuicConnection>,
    server: &mut ServerConnection<QuicConnection>,
    protocol: Protocol,
) -> (Upgraded, Upgraded) {
    tunnel_with(client, server, protocol, true, true).await
}

async fn sessions(
    client: &mut client::SendRequest<Body, QuicConnection>,
    server: &mut ServerConnection<QuicConnection>,
) -> (HttpDatagramSession, HttpDatagramSession) {
    let (client_io, server_io) = tunnel(client, server, TOKEN).await;
    (
        HttpDatagramSession::new(client_io),
        HttpDatagramSession::new(server_io),
    )
}

/// Native sending needs both SETTINGS; observe it rather than sleeping.
async fn native_ready(session: &HttpDatagramSession) -> usize {
    loop {
        if let Some(max) = session
            .native()
            .and_then(|native| native.channel().max_payload_size())
        {
            return max;
        }
        // A short virtual-time step keeps paused runtimes able to advance timers.
        tokio::time::sleep(Duration::from_millis(1)).await;
    }
}

/// Wait until the transport reports a closed send side through the native channel.
async fn native_closed(native: &NativeDatagrams) {
    loop {
        match native
            .channel()
            .send(Bytes::from_static(b"probe"), Default::default())
        {
            Err(NativeSendError::Closed) => return,
            Ok(()) => tokio::time::sleep(Duration::from_millis(1)).await,
            Err(error) => panic!("unexpected {error:?}"),
        }
    }
}

async fn wait_pending(server: &ServerConnection<QuicConnection>, count: usize) {
    while server.shared().datagram_demux().pending_len() != count {
        tokio::time::sleep(Duration::from_millis(1)).await;
    }
}

async fn wait_drops(
    server: &ServerConnection<QuicConnection>,
    done: impl Fn(crate::h3::DatagramDrops) -> bool,
) {
    while !done(server.datagram_drops()) {
        tokio::time::sleep(Duration::from_millis(1)).await;
    }
}

fn raw_datagram(stream: u64, payload: &[u8]) -> Bytes {
    let mut datagram = BytesMut::new();
    QuarterStreamId::new(stream / 4)
        .unwrap()
        .encode(&mut datagram);
    datagram.extend_from_slice(payload);
    datagram.freeze()
}

fn native(payload: &'static [u8]) -> Option<SessionEvent> {
    Some(SessionEvent::Datagram {
        payload: Bytes::from_static(payload),
        transport: DatagramTransport::Native,
    })
}

fn get() -> Request<Body> {
    Request::builder()
        .uri("https://localhost/")
        .body(Body::empty())
        .unwrap()
}

#[tokio::test]
async fn native_datagrams_round_trip_beside_reliable_capsules() {
    tokio::time::timeout(LIMIT, async {
        let pair = Pair::new(None, None).await;
        let (mut client, mut server) = start(&pair, server_config(Some(Default::default()))).await;
        let (mut client_session, mut server_session) = sessions(&mut client, &mut server).await;
        let max = native_ready(&client_session).await;
        assert!(max >= 1000, "{max}");
        native_ready(&server_session).await;
        assert_eq!(
            client_session
                .send_datagram(Bytes::from_static(b"ping"))
                .await
                .unwrap(),
            DatagramTransport::Native
        );
        assert_eq!(server_session.recv().await.unwrap(), native(b"ping"));
        server_session
            .send_datagram(Bytes::from_static(b""))
            .await
            .unwrap();
        assert_eq!(client_session.recv().await.unwrap(), native(b""));
        // Oversized native payloads fail instead of silently becoming reliable. The limit
        // follows the path MTU, so use a payload no QUIC DATAGRAM frame can carry.
        let error = client_session
            .send_datagram(Bytes::from(vec![0; 100_000]))
            .await
            .unwrap_err();
        assert_matches!(
            error,
            SessionError::Native(NativeSendError::TooLarge { .. }),
            "{error:?}"
        );
        let client_native = client_session.native().cloned().unwrap();
        client_session.close().await.unwrap();
        assert_eq!(server_session.recv().await.unwrap(), None);
        // The local send side is closed: nothing may follow (RFC 9297 §2.1).
        assert_eq!(
            client_native
                .channel()
                .send(Bytes::from_static(b"late"), Default::default()),
            Err(NativeSendError::Closed)
        );
        assert_matches!(
            client_session
                .send_datagram(Bytes::from_static(b"late"))
                .await,
            Err(SessionError::SendClosed)
        );
        // The reverse direction keeps working after the half-close.
        server_session
            .send_datagram(Bytes::from_static(b"reverse"))
            .await
            .unwrap();
        assert_eq!(client_session.recv().await.unwrap(), native(b"reverse"));
        server_session.close().await.unwrap();
        assert_eq!(client_session.recv().await.unwrap(), None);
        pair.close().await;
    })
    .await
    .unwrap();
}

#[tokio::test]
async fn capsules_carry_datagrams_when_the_peer_disables_them() {
    tokio::time::timeout(LIMIT, async {
        let pair = Pair::new(None, None).await;
        let (mut client, mut server) = start(&pair, server_config(None)).await;
        let (mut client_session, mut server_session) = sessions(&mut client, &mut server).await;
        // The server never advertised SETTINGS_H3_DATAGRAM and publishes no carrier.
        assert!(server_session.native().is_none());
        let native = client_session.native().expect("client associates");
        assert_eq!(native.channel().max_payload_size(), None);
        assert_eq!(
            client_session
                .send_datagram(Bytes::from_static(b"reliable"))
                .await
                .unwrap(),
            DatagramTransport::Capsule
        );
        assert_eq!(
            server_session.recv().await.unwrap(),
            Some(SessionEvent::Datagram {
                payload: Bytes::from_static(b"reliable"),
                transport: DatagramTransport::Capsule,
            })
        );
        pair.close().await;
    })
    .await
    .unwrap();
}

#[tokio::test]
async fn concurrent_sessions_receive_only_their_own_datagrams() {
    tokio::time::timeout(LIMIT, async {
        let pair = Pair::new(None, None).await;
        let (mut client, mut server) = start(&pair, server_config(Some(Default::default()))).await;
        let mut pairs = Vec::new();
        for _ in 0..8 {
            pairs.push(sessions(&mut client, &mut server).await);
        }
        for (client_session, server_session) in &pairs {
            native_ready(client_session).await;
            native_ready(server_session).await;
        }
        for (index, (client_session, _)) in pairs.iter_mut().enumerate() {
            for _ in 0..4 {
                client_session
                    .send_datagram(Bytes::from(vec![index as u8]))
                    .await
                    .unwrap();
            }
        }
        for (index, (_, server_session)) in pairs.iter_mut().enumerate() {
            // Loss is possible on real UDP; any datagram received must be this session's.
            let Some(SessionEvent::Datagram { payload, .. }) =
                tokio::time::timeout(Duration::from_secs(5), server_session.recv())
                    .await
                    .unwrap()
                    .unwrap()
            else {
                panic!("expected datagram");
            };
            assert_eq!(&payload[..], [index as u8]);
        }
        pair.close().await;
    })
    .await
    .unwrap();
}

#[tokio::test]
async fn stalled_session_drops_its_oldest_datagrams_without_blocking_others() {
    tokio::time::timeout(LIMIT, async {
        let pair = Pair::in_memory(None, None).await;
        let limits = DatagramLimits {
            queue_len: 4,
            ..DatagramLimits::default()
        };
        let (mut client, mut server) = start(
            &pair,
            server_config(datagrams(limits, ViolationPolicy::Ignore)),
        )
        .await;
        let (mut stalled_client, stalled_server) = sessions(&mut client, &mut server).await;
        let (mut active_client, mut active_server) = sessions(&mut client, &mut server).await;
        for session in [
            &stalled_client,
            &stalled_server,
            &active_client,
            &active_server,
        ] {
            native_ready(session).await;
        }
        for index in 0..16u8 {
            stalled_client
                .send_datagram(Bytes::from(vec![index]))
                .await
                .unwrap();
            // Deliver one at a time so the in-memory path cannot reorder or drop them.
            active_client
                .send_datagram(Bytes::from(vec![index]))
                .await
                .unwrap();
            let Some(SessionEvent::Datagram { payload, .. }) = active_server.recv().await.unwrap()
            else {
                panic!("expected datagram");
            };
            assert_eq!(&payload[..], [index]);
        }
        let (_, mut receiver) = stalled_server.split();
        assert_eq!(receiver.dropped_datagrams(), 12);
        for expected in 12..16u8 {
            let Some(SessionEvent::Datagram { payload, .. }) = receiver.recv().await.unwrap()
            else {
                panic!("expected datagram");
            };
            assert_eq!(&payload[..], [expected], "the newest datagrams are kept");
        }
        pair.close().await;
    })
    .await
    .unwrap();
}

#[tokio::test]
async fn datagrams_arriving_before_the_request_head_are_adopted() {
    tokio::time::timeout(LIMIT, async {
        let pair = Pair::in_memory(None, None).await;
        let (mut client, mut server) = start(&pair, server_config(Some(Default::default()))).await;
        // The request will open stream 0; its datagram overtakes the HEADERS.
        pair.client
            .send_datagram(raw_datagram(0, b"early"))
            .unwrap();
        wait_pending(&server, 1).await;
        let (_client_io, server_io) = tunnel(&mut client, &mut server, TOKEN).await;
        assert_eq!(server.shared().datagram_demux().pending_len(), 0);
        let mut session = HttpDatagramSession::new(server_io);
        assert_eq!(session.recv().await.unwrap(), native(b"early"));
        pair.close().await;
    })
    .await
    .unwrap();
}

/// One HTTP/3 frame of `frame_type` around `payload`.
fn raw_frame(frame_type: FrameType, payload: &[u8]) -> Bytes {
    let mut frame = BytesMut::new();
    FrameHeader::new(frame_type, payload.len() as u64)
        .encode(&mut frame)
        .unwrap();
    frame.extend_from_slice(payload);
    frame.freeze()
}

/// Read a raw request stream until `expected` appears in its DATA frame payloads.
async fn read_data_until(recv: &mut rama_quic::RecvStream, expected: &[u8]) {
    let mut wire = BytesMut::new();
    let mut data = Vec::new();
    while !data
        .windows(expected.len())
        .any(|window| window == expected)
    {
        let chunk = recv.read_chunk(usize::MAX, true).await.unwrap().unwrap();
        wire.extend_from_slice(&chunk.bytes);
        loop {
            let mut frame = &wire[..];
            let (Ok(frame_type), Ok(len)) =
                (VarInt::decode(&mut frame), VarInt::decode(&mut frame))
            else {
                break;
            };
            let len = len.into_inner() as usize;
            if frame.len() < len {
                break;
            }
            if frame_type.into_inner() == FrameType::DATA.value() {
                data.extend_from_slice(&frame[..len]);
            }
            let consumed = wire.len() - frame.len() + len;
            wire.advance(consumed);
        }
    }
}

#[tokio::test]
async fn datagrams_before_the_peers_settings_are_received_and_sending_waits_for_them() {
    tokio::time::timeout(LIMIT, async {
        let pair = Pair::in_memory(None, None).await;
        let (mut server, driver) =
            server::handshake(pair.server.clone(), server_config(Some(Default::default())))
                .unwrap();
        spawn(driver.run());
        // A raw client without a control stream: its datagram precedes any SETTINGS.
        pair.client
            .send_datagram(raw_datagram(0, b"early"))
            .unwrap();
        wait_pending(&server, 1).await;
        let (mut send, mut recv) = pair.client.open_bi().await.unwrap();
        let id = u64::from(send.id());
        let head = Encoder::before_peer_settings(EncoderConfig::default())
            .encode(
                id,
                vec![
                    (":method", "CONNECT"),
                    (":protocol", TOKEN.as_str()),
                    (":scheme", "https"),
                    (":authority", "localhost"),
                    (":path", "/datagrams"),
                ],
            )
            .unwrap();
        send.write_chunk(raw_frame(FrameType::HEADERS, &head))
            .await
            .unwrap();
        let (request, response) = server.accept().await.unwrap().resolve().await.unwrap();
        let upgrade = handle_upgrade(&request);
        response.send_response(accepted(true)).await.unwrap();
        let mut session = HttpDatagramSession::new(upgrade.await.unwrap());
        assert_eq!(session.recv().await.unwrap(), native(b"early"));

        // Until the peer's SETTINGS allow native datagrams, sending uses a DATAGRAM capsule.
        assert_eq!(session.native().unwrap().channel().max_payload_size(), None);
        assert_eq!(
            session
                .send_datagram(Bytes::from_static(b"later"))
                .await
                .unwrap(),
            DatagramTransport::Capsule
        );
        read_data_until(&mut recv, b"\x00\x05later").await;

        let mut settings = BytesMut::new();
        VarInt::from_u32(0x33).encode(&mut settings);
        VarInt::from_u32(1).encode(&mut settings);
        let mut control = BytesMut::new();
        VarInt::from_u32(0x00).encode(&mut control);
        control.extend_from_slice(&raw_frame(FrameType::SETTINGS, &settings));
        let mut control_stream = pair.client.open_uni().await.unwrap();
        control_stream.write_all(&control).await.unwrap();
        native_ready(&session).await;
        assert_eq!(
            session
                .send_datagram(Bytes::from_static(b"native"))
                .await
                .unwrap(),
            DatagramTransport::Native
        );
        assert_eq!(
            pair.client.read_datagram().await.unwrap(),
            raw_datagram(0, b"native")
        );
        pair.close().await;
    })
    .await
    .unwrap();
}

/// A peer advertising only the draft-04 `SETTINGS_H3_DATAGRAM` (0xffd277) gets capsules: the
/// draft setting is an unknown one, never read as RFC 9297 support.
#[tokio::test]
async fn the_draft_datagram_setting_does_not_enable_native_datagrams() {
    tokio::time::timeout(LIMIT, async {
        let pair = Pair::in_memory(None, None).await;
        let (mut server, driver) =
            server::handshake(pair.server.clone(), server_config(Some(Default::default())))
                .unwrap();
        spawn(driver.run());
        let mut settings = BytesMut::new();
        VarInt::from_u32(0xffd277).encode(&mut settings);
        VarInt::from_u32(1).encode(&mut settings);
        let mut control = BytesMut::new();
        VarInt::from_u32(0x00).encode(&mut control);
        control.extend_from_slice(&raw_frame(FrameType::SETTINGS, &settings));
        let mut control_stream = pair.client.open_uni().await.unwrap();
        control_stream.write_all(&control).await.unwrap();

        let (mut send, mut recv) = pair.client.open_bi().await.unwrap();
        let id = u64::from(send.id());
        let head = Encoder::before_peer_settings(EncoderConfig::default())
            .encode(
                id,
                vec![
                    (":method", "CONNECT"),
                    (":protocol", TOKEN.as_str()),
                    (":scheme", "https"),
                    (":authority", "localhost"),
                    (":path", "/datagrams"),
                ],
            )
            .unwrap();
        send.write_chunk(raw_frame(FrameType::HEADERS, &head))
            .await
            .unwrap();
        let (request, response) = server.accept().await.unwrap().resolve().await.unwrap();
        let upgrade = handle_upgrade(&request);
        response.send_response(accepted(true)).await.unwrap();
        let mut session = HttpDatagramSession::new(upgrade.await.unwrap());

        let peer = server.shared().peer_settings_snapshot().await.unwrap();
        assert!(!peer.h3_datagram());
        assert_eq!(session.native().unwrap().channel().max_payload_size(), None);
        assert_eq!(
            session
                .send_datagram(Bytes::from_static(b"capsule"))
                .await
                .unwrap(),
            DatagramTransport::Capsule
        );
        read_data_until(&mut recv, b"\x00\x07capsule").await;
        pair.close().await;
    })
    .await
    .unwrap();
}

/// The settings of the server's first SETTINGS frame, read off its control stream.
async fn server_settings(pair: &Pair) -> Vec<(u64, u64)> {
    let mut control = loop {
        let mut stream = pair.client.accept_uni().await.unwrap();
        let mut ty = [0];
        stream.read_exact(&mut ty).await.unwrap();
        if ty == [0x00] {
            break stream;
        }
    };
    let mut bytes = BytesMut::new();
    loop {
        let chunk = control.read_chunk(1024, true).await.unwrap().unwrap();
        bytes.extend_from_slice(&chunk.bytes);
        let mut frame = &bytes[..];
        let (Ok(ty), Ok(len)) = (VarInt::decode(&mut frame), VarInt::decode(&mut frame)) else {
            continue;
        };
        let Ok(len) = usize::try_from(len.into_inner()) else {
            continue;
        };
        if frame.len() < len {
            continue;
        }
        assert_eq!(ty.into_inner(), 0x04, "SETTINGS comes first");
        let mut payload = &frame[..len];
        let mut settings = Vec::new();
        while payload.has_remaining() {
            let id = VarInt::decode(&mut payload).unwrap().into_inner();
            let value = VarInt::decode(&mut payload).unwrap().into_inner();
            settings.push((id, value));
        }
        return settings;
    }
}

/// `SETTINGS_H3_DATAGRAM` follows this endpoint's own QUIC DATAGRAM support, whatever the
/// peer's (RFC 9297 §2.1.1): a peer that receives none may still send them.
#[tokio::test]
async fn datagram_settings_follow_this_endpoints_own_transport_support() {
    tokio::time::timeout(LIMIT, async {
        let mut client_transport = TransportConfig::default();
        client_transport.unset_datagram_receive_buffer_size();
        let pair = Pair::in_memory(Some(client_transport), None).await;
        let (_server, driver) =
            server::handshake(pair.server.clone(), server_config(Some(Default::default())))
                .unwrap();
        spawn(driver.run());
        assert!(server_settings(&pair).await.contains(&(0x33, 1)));
        pair.close().await;
    })
    .await
    .unwrap();
}

/// Native datagrams wait for this endpoint's own SETTINGS too (RFC 9297 §2.1.1): with the
/// client's control stream blocked, it keeps sending capsules after the server's arrived.
#[tokio::test]
async fn native_datagrams_wait_for_this_endpoints_settings() {
    tokio::time::timeout(LIMIT, async {
        // No data credit on unidirectional streams: the client's SETTINGS cannot leave.
        let mut server_transport = TransportConfig::default();
        server_transport.set_stream_receive_window_uni(0u32.into());
        let pair = Pair::in_memory(None, Some(server_transport)).await;
        let (mut client, mut server) = start(&pair, server_config(Some(Default::default()))).await;
        let (mut client_session, _server_session) = sessions(&mut client, &mut server).await;
        for _ in 0..20 {
            assert_eq!(
                client_session
                    .native()
                    .unwrap()
                    .channel()
                    .max_payload_size(),
                None
            );
            tokio::time::sleep(Duration::from_millis(5)).await;
        }
        assert_eq!(
            client_session
                .send_datagram(Bytes::from_static(b"capsule"))
                .await
                .unwrap(),
            DatagramTransport::Capsule
        );
        pair.close().await;
    })
    .await
    .unwrap();
}

#[tokio::test]
async fn datagrams_this_endpoint_never_advertised_are_counted_and_dropped() {
    tokio::time::timeout(LIMIT, async {
        let pair = Pair::in_memory(None, None).await;
        // QUIC DATAGRAM is negotiated, but the server never sends SETTINGS_H3_DATAGRAM.
        let (_client, server) = start(&pair, server_config(None)).await;
        pair.client.send_datagram(raw_datagram(0, b"x")).unwrap();
        wait_drops(&server, |drops| drops.unadvertised == 1).await;
        assert_eq!(server.shared().datagram_demux().pending_len(), 0);
        pair.close().await;
    })
    .await
    .unwrap();
}

#[tokio::test]
async fn datagrams_on_requests_without_datagram_semantics_follow_the_policy() {
    for policy in POLICIES {
        tokio::time::timeout(LIMIT, async {
            let pair = Pair::in_memory(None, None).await;
            let config = server_config(datagrams(DatagramLimits::default(), policy));
            let (mut client, mut server) = start(&pair, config).await;
            // Ordinary GET on stream 0: its datagram overtakes the HEADERS.
            pair.client.send_datagram(raw_datagram(0, b"x")).unwrap();
            wait_pending(&server, 1).await;
            let serve = async {
                let result = server.accept().await.unwrap().resolve().await;
                if policy == ViolationPolicy::Reject {
                    let error = result.map(|_| ()).unwrap_err();
                    assert_eq!(error.code(), Code::H3_DATAGRAM_ERROR);
                } else {
                    let (_request, response) = result.unwrap();
                    response
                        .send_response(Response::new(Body::from("ok")))
                        .await
                        .unwrap();
                }
            };
            let (response, ()) = tokio::join!(client.send_request(get()), serve);
            match policy {
                ViolationPolicy::Reject => {
                    assert_eq!(response.unwrap_err().code(), Code::H3_DATAGRAM_ERROR);
                }
                _ => assert_eq!(response.unwrap().status(), StatusCode::OK),
            }
            assert_eq!(server.datagram_drops().no_semantics, 1, "{policy:?}");

            // A token alone never implies datagrams: an undeclared WebSocket tunnel.
            let (mut client_io, mut server_io) =
                tunnel_with(&mut client, &mut server, Protocol::WEBSOCKET, false, false).await;
            for io in [&client_io, &server_io] {
                assert!(io.extensions().get_ref::<NativeDatagrams>().is_none());
            }
            pair.client.send_datagram(raw_datagram(4, b"y")).unwrap();
            wait_drops(&server, |drops| drops.no_semantics == 2).await;
            let mut byte = [0; 1];
            if policy == ViolationPolicy::Reject {
                // Aborted by the driver while nobody polls the tunnel.
                client_io.read(&mut byte).await.unwrap_err();
                server_io.read(&mut byte).await.unwrap_err();
            } else {
                client_io.write_all(b"z").await.unwrap();
                client_io.flush().await.unwrap();
                server_io.read_exact(&mut byte).await.unwrap();
                assert_eq!(&byte, b"z");
            }
            // The connection itself stays usable.
            let (_client_io, _server_io) = tunnel(&mut client, &mut server, TOKEN).await;
            pair.close().await;
        })
        .await
        .unwrap();
    }
}

#[tokio::test]
async fn servers_declare_semantics_on_their_response() {
    for policy in POLICIES {
        // A zero queue discards every payload: the violation is still observed.
        for queue_len in [0, 4] {
            tokio::time::timeout(LIMIT, async {
                let pair = Pair::in_memory(None, None).await;
                let limits = DatagramLimits {
                    queue_len,
                    ..DatagramLimits::default()
                };
                let (mut client, mut server) =
                    start(&pair, server_config(datagrams(limits, policy))).await;
                // One datagram is buffered, charged as its packet.
                let arrived = |server: &ServerConnection<QuicConnection>, count: u64| {
                    if queue_len == 0 {
                        server.datagram_drops().queue_full == count
                    } else {
                        server.shared().datagram_demux().buffered() == MIN_DATAGRAM_CHARGE
                    }
                };
                // Declared by the client only; the slow server answers without declaring.
                let (response, server_io) =
                    tokio::join!(client.send_request(connect(TOKEN, true)), async {
                        let (request, response) =
                            server.accept().await.unwrap().resolve().await.unwrap();
                        pair.client
                            .send_datagram(raw_datagram(0, b"early"))
                            .unwrap();
                        wait_drops(&server, |_| arrived(&server, 1)).await;
                        let upgrade = handle_upgrade(&request);
                        match response.send_response(accepted(false)).await {
                            Ok(()) => upgrade.await.ok(),
                            Err(_) => None,
                        }
                    });
                assert_eq!(server.shared().datagram_demux().buffered(), 0);
                if policy == ViolationPolicy::Reject {
                    // Aborted before the response left, whatever the queue kept.
                    assert_eq!(response.unwrap_err().code(), Code::H3_DATAGRAM_ERROR);
                } else {
                    let mut client_io = handle_upgrade(&response.unwrap()).await.unwrap();
                    let mut server_io = server_io.unwrap();
                    assert!(
                        server_io
                            .extensions()
                            .get_ref::<NativeDatagrams>()
                            .is_none()
                    );
                    client_io.write_all(b"z").await.unwrap();
                    client_io.flush().await.unwrap();
                    let mut byte = [0; 1];
                    server_io.read_exact(&mut byte).await.unwrap();
                    assert!(
                        server.datagram_drops().no_semantics + server.datagram_drops().queue_full
                            >= 1
                    );
                }
                // A declared response keeps datagrams that arrived while it was pending.
                let (response, server_io) =
                    tokio::join!(client.send_request(connect(TOKEN, true)), async {
                        let (request, response) =
                            server.accept().await.unwrap().resolve().await.unwrap();
                        pair.client.send_datagram(raw_datagram(4, b"held")).unwrap();
                        wait_drops(&server, |_| arrived(&server, 2)).await;
                        let upgrade = handle_upgrade(&request);
                        response.send_response(accepted(true)).await.unwrap();
                        upgrade.await.unwrap()
                    });
                assert_eq!(response.unwrap().status(), StatusCode::OK);
                if queue_len > 0 {
                    let mut session = HttpDatagramSession::new(server_io);
                    assert_eq!(session.recv().await.unwrap(), native(b"held"));
                }
                pair.close().await;
            })
            .await
            .unwrap();
        }
    }
}

#[tokio::test]
async fn refused_extended_connects_lose_their_client_declaration() {
    for policy in POLICIES {
        tokio::time::timeout(LIMIT, async {
            let pair = Pair::in_memory(None, None).await;
            let client_config = Config {
                datagrams: datagrams(DatagramLimits::default(), policy),
                ..Config::default()
            };
            let (mut client, mut server) = start_both(
                &pair,
                client_config,
                server_config(Some(DatagramConfig::default())),
            )
            .await;
            let serve = async {
                let (_request, response) = server.accept().await.unwrap().resolve().await.unwrap();
                let mut refused = Response::new(Body::from("refused"));
                *refused.status_mut() = StatusCode::FORBIDDEN;
                response.send_response(refused).await.unwrap();
            };
            let (response, ()) = tokio::join!(client.send_request(connect(TOKEN, true)), serve);
            let response = response.unwrap();
            assert_eq!(response.status(), StatusCode::FORBIDDEN);
            // The remaining response body carries no datagrams.
            pair.server.send_datagram(raw_datagram(0, b"x")).unwrap();
            while client.datagram_drops().no_semantics == 0 {
                tokio::time::sleep(Duration::from_millis(1)).await;
            }
            let body = response.into_body().collect().await;
            match policy {
                ViolationPolicy::Reject => assert!(body.is_err()),
                _ => assert_eq!(&body.unwrap().to_bytes()[..], b"refused"),
            }
            let (_client_io, _server_io) = tunnel(&mut client, &mut server, TOKEN).await;
            pair.close().await;
        })
        .await
        .unwrap();
    }
}

/// Even under `Reject`, a refused Extended CONNECT is answered after optimistic datagrams:
/// they were sent for a request with datagram semantics (RFC 9297 §2.1).
#[tokio::test]
async fn refusals_are_answered_after_optimistic_datagrams() {
    tokio::time::timeout(LIMIT, async {
        let pair = Pair::in_memory(None, None).await;
        let (mut client, mut server) = start(
            &pair,
            server_config(datagrams(
                DatagramLimits::default(),
                ViolationPolicy::Reject,
            )),
        )
        .await;
        let serve = async {
            let (_request, response) = server.accept().await.unwrap().resolve().await.unwrap();
            pair.client
                .send_datagram(raw_datagram(0, b"early"))
                .unwrap();
            while server.shared().datagram_demux().buffered() != MIN_DATAGRAM_CHARGE {
                tokio::time::sleep(Duration::from_millis(1)).await;
            }
            let mut refused = Response::new(Body::from("refused"));
            *refused.status_mut() = StatusCode::FORBIDDEN;
            response.send_response(refused).await.unwrap();
        };
        let (response, ()) = tokio::join!(client.send_request(connect(TOKEN, true)), serve);
        let response = response.unwrap();
        assert_eq!(response.status(), StatusCode::FORBIDDEN);
        let body = response.into_body().collect().await.unwrap().to_bytes();
        assert_eq!(&body[..], b"refused");
        assert_eq!(server.datagram_drops().no_semantics, 1);
        pair.close().await;
    })
    .await
    .unwrap();
}

/// A raw server stream answering one Extended CONNECT with `200`.
async fn raw_accept(pair: &Pair) -> (rama_quic::SendStream, rama_quic::RecvStream) {
    let (mut send, mut recv) = pair.server.accept_bi().await.unwrap();
    let id = u64::from(send.id());
    recv.read_chunk(usize::MAX, true).await.unwrap().unwrap();
    let encoded = Encoder::before_peer_settings(EncoderConfig::default())
        .encode(id, vec![(":status", "200")])
        .unwrap();
    let mut frame = BytesMut::new();
    FrameHeader::new(FrameType::HEADERS, encoded.len() as u64)
        .encode(&mut frame)
        .unwrap();
    frame.extend_from_slice(&encoded);
    send.write_chunk(frame.freeze()).await.unwrap();
    (send, recv)
}

#[tokio::test]
async fn native_sends_follow_the_transport_without_writer_polls() {
    tokio::time::timeout(LIMIT, async {
        let pair = Pair::in_memory(None, None).await;
        // The engine only supplies SETTINGS; the request stream is served raw.
        let (mut client, _server) =
            start(&pair, server_config(Some(DatagramConfig::default()))).await;
        let (response, (_send, mut recv)) =
            tokio::join!(client.send_request(connect(TOKEN, true)), raw_accept(&pair));
        let session = HttpDatagramSession::new(handle_upgrade(&response.unwrap()).await.unwrap());
        native_ready(&session).await;
        // Split halves and a clone; the writer is never polled again.
        let clone = session.native().cloned().unwrap();
        let (mut sender, _receiver) = session.split();
        clone
            .channel()
            .send(Bytes::from_static(b"open"), Default::default())
            .unwrap();
        recv.stop(VarInt::from_u32(0x33)).unwrap();
        native_closed(&clone).await;
        assert_matches!(
            sender.send_datagram(Bytes::from_static(b"stopped")).await,
            Err(SessionError::Native(NativeSendError::Closed))
        );
        // Other requests on the connection are unaffected.
        let (response, _raw) =
            tokio::join!(client.send_request(connect(TOKEN, true)), raw_accept(&pair));
        let other = HttpDatagramSession::new(handle_upgrade(&response.unwrap()).await.unwrap());
        other
            .native()
            .unwrap()
            .channel()
            .send(Bytes::from_static(b"other"), Default::default())
            .unwrap();
        pair.close().await;
    })
    .await
    .unwrap();
}

#[tokio::test]
async fn local_ends_close_native_sending_for_every_holder() {
    for end in ["fin", "malformed", "upstream", "drop", "connection"] {
        tokio::time::timeout(LIMIT, async {
            let pair = Pair::in_memory(None, None).await;
            let (mut client, mut server) =
                start(&pair, server_config(Some(DatagramConfig::default()))).await;
            let (client_io, _server_io) = tunnel(&mut client, &mut server, TOKEN).await;
            let native = client_io
                .extensions()
                .get_ref::<NativeDatagrams>()
                .cloned()
                .unwrap();
            let malformed = client_io.extensions().get_arc::<OnMalformedMessage>();
            let upstream = client_io.extensions().self_get_arc::<AbortIo>();
            let mut session = HttpDatagramSession::new(client_io);
            native_ready(&session).await;
            match end {
                "fin" => session.close().await.unwrap(),
                "malformed" => malformed.unwrap().call(),
                "upstream" => upstream.unwrap().abort(),
                "drop" => drop(session),
                _ => pair.client.close(VarInt::from_u32(0), b"gone"),
            }
            assert_eq!(
                native
                    .channel()
                    .send(Bytes::from_static(b"after"), Default::default()),
                Err(NativeSendError::Closed),
                "{end}"
            );
            pair.close().await;
        })
        .await
        .unwrap();
    }
}

#[tokio::test]
async fn released_streams_never_hold_datagrams() {
    tokio::time::timeout(LIMIT, async {
        let pair = Pair::in_memory(None, None).await;
        let (mut client, mut server) =
            start(&pair, server_config(Some(DatagramConfig::default()))).await;
        let serve = async {
            let (_request, response) = server.accept().await.unwrap().resolve().await.unwrap();
            response
                .send_response(Response::new(Body::from("ok")))
                .await
                .unwrap();
        };
        let (response, ()) = tokio::join!(client.send_request(get()), serve);
        drop(response.unwrap());
        while server.shared().datagram_demux().slot_count() != 0 {
            tokio::time::sleep(Duration::from_millis(1)).await;
        }
        // Stream 0 is below the watermark: silently dropped, never pending.
        pair.client.send_datagram(raw_datagram(0, b"late")).unwrap();
        wait_drops(&server, |drops| drops.unknown_stream == 1).await;
        assert_eq!(server.shared().datagram_demux().pending_len(), 0);
        // A future stream is still held, and late traffic for a released one never evicts it.
        pair.client
            .send_datagram(raw_datagram(8, b"early"))
            .unwrap();
        wait_pending(&server, 1).await;
        pair.client
            .send_datagram(raw_datagram(0, b"later"))
            .unwrap();
        wait_drops(&server, |drops| drops.unknown_stream == 2).await;
        wait_pending(&server, 1).await;
        pair.close().await;
        while server.shared().datagram_demux().buffered() != 0 {
            tokio::time::sleep(Duration::from_millis(1)).await;
        }
    })
    .await
    .unwrap();
}

#[tokio::test]
async fn malformed_datagram_prefixes_follow_the_policy() {
    let oversized = {
        let mut datagram = BytesMut::new();
        VarInt::from_u64(1 << 60).unwrap().encode(&mut datagram);
        datagram.freeze()
    };
    for policy in POLICIES {
        for (datagram, code) in [
            (Bytes::new(), Code::H3_DATAGRAM_ERROR),
            (oversized.clone(), Code::H3_DATAGRAM_ERROR),
            // Far beyond the client bidirectional stream limit (SHOULD, RFC 9297 §2.1).
            (raw_datagram(4 * 1_000_000, b""), Code::H3_ID_ERROR),
        ] {
            tokio::time::timeout(LIMIT, async {
                let pair = Pair::in_memory(None, None).await;
                let config = server_config(datagrams(DatagramLimits::default(), policy));
                let (mut client, mut server) = start(&pair, config).await;
                pair.client.send_datagram(datagram).unwrap();
                if policy == ViolationPolicy::Reject {
                    let reason = pair.client.closed().await;
                    let rama_quic::ConnectionError::ApplicationClosed(close) = reason else {
                        panic!("unexpected {reason:?}");
                    };
                    assert_eq!(close.error_code.into_inner(), code.value());
                } else {
                    wait_drops(&server, |drops| drops.invalid_id + drops.beyond_limit == 1).await;
                    let (_client_io, _server_io) = tunnel(&mut client, &mut server, TOKEN).await;
                }
                pair.close().await;
            })
            .await
            .unwrap();
        }
    }
}

#[tokio::test]
async fn datagrams_after_the_stream_closed_are_dropped() {
    tokio::time::timeout(LIMIT, async {
        let pair = Pair::in_memory(None, None).await;
        let (mut client, mut server) = start(&pair, server_config(Some(Default::default()))).await;
        let (mut client_session, mut server_session) = sessions(&mut client, &mut server).await;
        native_ready(&client_session).await;
        let server_native = server_session.native().cloned().unwrap();
        client_session.close().await.unwrap();
        assert_eq!(server_session.recv().await.unwrap(), None);
        // A misbehaving peer keeps sending on the finished stream.
        pair.client.send_datagram(raw_datagram(0, b"late")).unwrap();
        // A later request proves the connection processed and survived it.
        let (_a, _b) = sessions(&mut client, &mut server).await;
        assert_eq!(server.shared().datagram_demux().pending_len(), 0);
        while server_native.channel().dropped() == 0 {
            tokio::time::sleep(Duration::from_millis(1)).await;
        }
        let mut cx = Context::from_waker(Waker::noop());
        assert_eq!(
            server_native.channel().poll_recv(&mut cx),
            Poll::Ready(Ok(None)),
            "datagrams after the receive side closed are dropped"
        );
        pair.close().await;
    })
    .await
    .unwrap();
}

/// Datagrams sent before a stream's end arrive before that end, although the reader can see
/// the stream's FIN before the connection's datagram demux has filed them.
// Real sockets and worker threads: the FIN and the datagram demux race as in production.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn datagrams_sent_before_the_stream_ended_arrive_before_its_end() {
    tokio::time::timeout(LIMIT, async {
        let pair = Pair::new(None, None).await;
        let (mut client, mut server) = start(&pair, server_config(Some(Default::default()))).await;
        // The order only races: many rounds make a lost datagram show.
        for round in 0..50 {
            let (mut client_session, mut server_session) = sessions(&mut client, &mut server).await;
            native_ready(&client_session).await;
            // The receiver waits before anything arrives, as a relay does.
            let receiving = tokio::spawn(async move {
                let mut received = Vec::new();
                while let Some(event) = server_session.recv().await.unwrap() {
                    received.push(event);
                }
                received
            });
            tokio::time::sleep(Duration::from_millis(2)).await;
            for _ in 0..3 {
                client_session
                    .send_datagram(Bytes::from_static(b"last words"))
                    .await
                    .unwrap();
            }
            client_session.close().await.unwrap();
            let received = receiving.await.unwrap();
            assert_eq!(
                received,
                [
                    native(b"last words"),
                    native(b"last words"),
                    native(b"last words")
                ]
                .into_iter()
                .flatten()
                .collect::<Vec<_>>(),
                "round {round}"
            );
        }
        pair.close().await;
    })
    .await
    .unwrap();
}

/// A stream's end waits only for datagrams already received: another session's flood keeps
/// the connection's queue full but cannot hold the end back.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_stream_ends_while_other_sessions_flood_datagrams() {
    tokio::time::timeout(LIMIT, async {
        let pair = Pair::new(None, None).await;
        let (mut client, mut server) = start(&pair, server_config(Some(Default::default()))).await;
        let (flooding, _flooded) = sessions(&mut client, &mut server).await;
        native_ready(&flooding).await;
        let native = flooding.native().cloned().unwrap();
        let flood = tokio::spawn(async move {
            loop {
                _ = native
                    .channel()
                    .send(Bytes::from_static(b"flood"), Default::default());
                tokio::task::yield_now().await;
            }
        });
        for round in 0..20 {
            let (mut client_session, mut server_session) = sessions(&mut client, &mut server).await;
            native_ready(&client_session).await;
            client_session
                .send_datagram(Bytes::from_static(b"last words"))
                .await
                .unwrap();
            client_session.close().await.unwrap();
            let ended = tokio::time::timeout(Duration::from_secs(2), async {
                while server_session.recv().await.unwrap().is_some() {}
            })
            .await;
            assert!(ended.is_ok(), "round {round}: the end waited on the flood");
        }
        flood.abort();
        pair.close().await;
    })
    .await
    .unwrap();
}

/// A writer blocked on stream flow control resumes when the peer reads, even after a read in
/// another task flushed for it: the stream wakes only the task registered last.
#[tokio::test]
async fn a_blocked_writer_resumes_after_a_read_flushed_for_it() {
    tokio::time::timeout(LIMIT, async {
        let mut server_transport = TransportConfig::default();
        Config::default()
            .configure_transport(&mut server_transport)
            .unwrap();
        server_transport.set_stream_receive_window(VarInt::from_u32(4096));
        let pair = Pair::in_memory(None, Some(server_transport)).await;
        let (mut client, mut server) = start(&pair, server_config(None)).await;
        let (client_session, mut server_session) = sessions(&mut client, &mut server).await;
        let (mut sender, mut receiver) = client_session.split();
        const CAPSULES: usize = 64;
        let (sent_tx, mut sent) = tokio::sync::mpsc::unbounded_channel();
        let writer = spawn(async move {
            for _ in 0..CAPSULES {
                sender
                    .send_capsule(CapsuleType::DATAGRAM, Bytes::from(vec![7; 1024]))
                    .await
                    .unwrap();
                _ = sent_tx.send(());
            }
        });
        // The writer stalls once the peer's stream window is full.
        let mut written = 0;
        while matches!(
            tokio::time::timeout(Duration::from_millis(200), sent.recv()).await,
            Ok(Some(()))
        ) {
            written += 1;
        }
        assert!(written < CAPSULES, "the window never filled");
        // A read in another task polls the stream while the writer's data waits; that task
        // then ends, handing the receiver back so the tunnel stays open.
        let reader = spawn(async move {
            let event = receiver.recv().await;
            (event, receiver)
        });
        server_session
            .send_capsule(CapsuleType::DATAGRAM, Bytes::from_static(b"to the reader"))
            .await
            .unwrap();
        let (event, _receiver) = reader.await.unwrap();
        assert!(event.unwrap().is_some());
        // The peer takes everything: the writer finishes without another wake.
        let mut received = 0;
        while received < CAPSULES {
            match server_session.recv().await.unwrap() {
                Some(SessionEvent::Datagram { .. }) => received += 1,
                other => panic!("unexpected {other:?}"),
            }
        }
        writer.await.unwrap();
        pair.close().await;
    })
    .await
    .unwrap();
}

#[tokio::test]
async fn sessions_continue_through_graceful_shutdown_and_end_with_the_connection() {
    tokio::time::timeout(LIMIT, async {
        let pair = Pair::in_memory(None, None).await;
        let (mut client, mut server) = start(&pair, server_config(Some(Default::default()))).await;
        let (mut client_session, mut server_session) = sessions(&mut client, &mut server).await;
        native_ready(&client_session).await;
        server.shutdown().unwrap();
        while !client.is_draining() {
            tokio::task::yield_now().await;
        }
        client_session
            .send_datagram(Bytes::from_static(b"draining"))
            .await
            .unwrap();
        assert_eq!(server_session.recv().await.unwrap(), native(b"draining"));
        // A pending receive wakes when the connection goes away.
        let recv = spawn(async move { client_session.recv().await });
        pair.server.close(VarInt::from_u32(0x100), b"done");
        let result = recv.await.unwrap();
        assert!(!matches!(result, Ok(Some(_))), "{result:?}");
        assert!(
            client
                .send_request(connect(TOKEN, true))
                .now_or_never()
                .is_some()
        );
        pair.close().await;
    })
    .await
    .unwrap();
}

#[tokio::test]
async fn goaway_refuses_new_extended_connects_as_retryable_and_drains_open_ones() {
    tokio::time::timeout(LIMIT, async {
        let pair = Pair::in_memory(None, None).await;
        let (mut client, mut server) = start(&pair, server_config(Some(Default::default()))).await;
        let (mut client_session, mut server_session) = sessions(&mut client, &mut server).await;
        native_ready(&client_session).await;
        server.shutdown().unwrap();
        while !client.is_draining() {
            tokio::task::yield_now().await;
        }
        // RFC 9114 §5.2: a request beyond the GOAWAY identifier is never processed.
        let refused = client.send_request(connect(TOKEN, true)).await.unwrap_err();
        assert_eq!(refused.code(), Code::H3_REQUEST_REJECTED);

        // The open session keeps flowing in both directions and still ends cleanly.
        client_session
            .send_datagram(Bytes::from_static(b"up"))
            .await
            .unwrap();
        assert_eq!(server_session.recv().await.unwrap(), native(b"up"));
        server_session
            .send_datagram(Bytes::from_static(b"down"))
            .await
            .unwrap();
        assert_eq!(client_session.recv().await.unwrap(), native(b"down"));
        client_session.close().await.unwrap();
        assert_eq!(server_session.recv().await.unwrap(), None);
        server_session.close().await.unwrap();
        pair.close().await;
    })
    .await
    .unwrap();
}

#[tokio::test(start_paused = true)]
async fn lost_datagrams_do_not_stall_the_session() {
    tokio::time::timeout(LIMIT, async {
        let pair = Pair::impaired().await;
        let (mut client, mut server) = start(&pair, server_config(Some(Default::default()))).await;
        let (mut client_session, mut server_session) = sessions(&mut client, &mut server).await;
        native_ready(&client_session).await;
        let [client_faults, _] = pair.datagram_faults.as_ref().unwrap();
        client_faults.drop_next(1);
        client_session
            .send_datagram(Bytes::from_static(b"lost"))
            .await
            .unwrap();
        // Send the next datagram only after the first packet was lost, not coalesced with it.
        while client_faults.stats().dropped == 0 {
            tokio::time::sleep(Duration::from_millis(1)).await;
        }
        client_session
            .send_datagram(Bytes::from_static(b"kept"))
            .await
            .unwrap();
        assert_eq!(server_session.recv().await.unwrap(), native(b"kept"));
        pair.close().await;
    })
    .await
    .unwrap();
}

const FAULT_SESSIONS: usize = 4;
const FAULT_ROUNDS: u8 = 24;
/// A round tag no faulted datagram uses: its echo proves the session is past the faults.
const MARKER: u8 = u8::MAX;

/// Arm one kind of fault in both directions, cycling with the round.
fn arm_faults(faults: &[MemoryDatagramControl; 2], round: u8) {
    for direction in faults {
        match round % 3 {
            0 => direction.drop_next(1),
            1 => direction.duplicate_next(1),
            _ => direction.reorder_next_pair().unwrap(),
        }
    }
}

/// Wait until both directions applied the faults armed in `round`.
async fn faults_applied(
    faults: &[MemoryDatagramControl; 2],
    before: [MemoryDatagramFaultStats; 2],
    round: u8,
) {
    for (direction, before) in faults.iter().zip(before) {
        loop {
            let now = direction.stats();
            let applied = match round % 3 {
                0 => now.dropped > before.dropped,
                1 => now.duplicated > before.duplicated,
                _ => now.reordered_pairs > before.reordered_pairs,
            };
            if applied {
                break;
            }
            tokio::time::sleep(Duration::from_millis(1)).await;
        }
    }
}

#[tokio::test(start_paused = true)]
async fn sessions_survive_loss_duplication_and_reordering_on_both_carriers() {
    for native_carrier in [true, false] {
        tokio::time::timeout(LIMIT, async {
            let pair = Pair::impaired().await;
            let datagrams = native_carrier.then(DatagramConfig::default);
            let (mut client, mut server) = start(&pair, server_config(datagrams)).await;
            let mut clients = Vec::new();
            let mut echoes = Vec::new();
            for _ in 0..FAULT_SESSIONS {
                let (client_session, mut server_session) = sessions(&mut client, &mut server).await;
                if native_carrier {
                    native_ready(&client_session).await;
                }
                echoes.push(spawn(async move {
                    let mut seen = Vec::new();
                    while let Some(event) = server_session.recv().await.unwrap() {
                        if let SessionEvent::Datagram { payload, .. } = event {
                            if payload[1] != MARKER {
                                seen.push(payload.clone());
                            }
                            server_session.send_datagram(payload).await.unwrap();
                        }
                    }
                    server_session.close().await.unwrap();
                    seen
                }));
                clients.push(client_session);
            }

            let faults = pair.datagram_faults.as_ref().unwrap();
            for round in 0..FAULT_ROUNDS {
                let before = [faults[0].stats(), faults[1].stats()];
                arm_faults(faults, round);
                for (index, session) in clients.iter_mut().enumerate() {
                    let tag = Bytes::from(vec![u8::try_from(index).unwrap(), round]);
                    session.send_datagram(tag).await.unwrap();
                }
                faults_applied(faults, before, round).await;
            }
            for direction in faults {
                direction.drop_next(0);
                direction.duplicate_next(0);
            }

            let sent: Vec<Vec<Bytes>> = (0..FAULT_SESSIONS)
                .map(|index| {
                    (0..FAULT_ROUNDS)
                        .map(|round| Bytes::from(vec![u8::try_from(index).unwrap(), round]))
                        .collect()
                })
                .collect();
            for (index, mut session) in clients.into_iter().enumerate() {
                let mut received = Vec::new();
                // The faults are disarmed: resend the unreliable marker until its echo is back,
                // so the session only closes once the faulted exchange is behind it.
                let marker = Bytes::from(vec![u8::try_from(index).unwrap(), MARKER]);
                'marked: loop {
                    session.send_datagram(marker.clone()).await.unwrap();
                    let wait = tokio::time::timeout(Duration::from_millis(50), async {
                        loop {
                            let Some(SessionEvent::Datagram { payload, .. }) =
                                session.recv().await.unwrap()
                            else {
                                continue;
                            };
                            if payload == marker {
                                return;
                            }
                            received.push(payload);
                        }
                    });
                    if wait.await.is_ok() {
                        break 'marked;
                    }
                }
                session.close().await.unwrap();
                while let Some(event) = session.recv().await.unwrap() {
                    if let SessionEvent::Datagram { payload, .. } = event
                        && payload != marker
                    {
                        received.push(payload);
                    }
                }
                let seen = echoes.remove(0).await.unwrap();
                for delivered in [&seen, &received] {
                    if native_carrier {
                        // Unreliable: a subset, each at most once and only of this session.
                        assert!(!delivered.is_empty(), "session {index}: nothing arrived");
                        assert!(delivered.iter().all(|tag| sent[index].contains(tag)));
                        let mut unique = delivered.clone();
                        unique.sort();
                        unique.dedup();
                        assert_eq!(unique.len(), delivered.len(), "session {index}: duplicate");
                    } else {
                        // Capsules ride the stream: all of them, once, in order.
                        assert_eq!(delivered, &sent[index], "session {index}");
                    }
                }
            }
            // The connection still serves ordinary requests.
            let serve = spawn(async move {
                let (_request, response) = server.accept().await.unwrap().resolve().await.unwrap();
                response
                    .send_response(Response::new(Body::from("ok")))
                    .await
                    .unwrap();
            });
            let response = client.send_request(get()).await.unwrap();
            assert_eq!(response.status(), StatusCode::OK);
            serve.await.unwrap();
            pair.close().await;
        })
        .await
        .unwrap();
    }
}

/// Wait until neither side's demux keeps a slot.
async fn slots_released(
    client: &client::SendRequest<Body, QuicConnection>,
    server: &ServerConnection<QuicConnection>,
) {
    while client.shared().datagram_demux().slot_count() != 0
        || server.shared().datagram_demux().slot_count() != 0
    {
        tokio::time::sleep(Duration::from_millis(1)).await;
    }
}

#[tokio::test]
async fn tunnels_keep_their_hooks_out_of_the_connection_extensions() {
    tokio::time::timeout(LIMIT, async {
        let pair = Pair::in_memory(None, None).await;
        let (mut client, mut server) = start(&pair, server_config(Some(Default::default()))).await;
        let stored = |shared: &Shared| shared.transport_extensions.self_iter_all().count();
        let (client_before, server_before) = (stored(client.shared()), stored(server.shared()));
        for _ in 0..3 {
            let (mut client_session, mut server_session) = sessions(&mut client, &mut server).await;
            assert!(client_session.native().is_some() && server_session.native().is_some());
            client_session.close().await.unwrap();
            assert_eq!(server_session.recv().await.unwrap(), None);
        }
        // Per-tunnel carriers and abort hooks live in each tunnel's fork only.
        for shared in [client.shared(), server.shared()] {
            assert!(!shared.transport_extensions.contains::<NativeDatagrams>());
            assert!(!shared.transport_extensions.contains::<OnMalformedMessage>());
            assert!(!shared.transport_extensions.contains::<AbortIo>());
        }
        assert_eq!(
            (stored(client.shared()), stored(server.shared())),
            (client_before, server_before)
        );
        pair.close().await;
    })
    .await
    .unwrap();
}

/// Every dynamically encoded section was acknowledged or cancelled by the peer's decoder.
async fn qpack_settled(
    client: &client::SendRequest<Body, QuicConnection>,
    server: &ServerConnection<QuicConnection>,
) {
    let (inserted, _) = client.shared().qpack_sections();
    assert!(inserted > 0, "the requests used the dynamic table");
    while client.shared().qpack_sections().1 != 0 || server.shared().qpack_sections().1 != 0 {
        tokio::time::sleep(Duration::from_millis(1)).await;
    }
}

/// Idle datagram sessions hold demux slots only as long as their streams live, so the peer's
/// stream limit bounds them: a request beyond it waits for stream credit, not for a slot.
#[tokio::test]
async fn idle_sessions_hold_at_most_the_stream_limit_of_demux_slots() {
    tokio::time::timeout(LIMIT, async {
        let server_transport = TransportConfig::default().with_max_concurrent_bidi_streams(3u32);
        let pair = Pair::in_memory(None, Some(server_transport)).await;
        let (mut client, mut server) = start(&pair, server_config(Some(Default::default()))).await;
        let mut held = Vec::new();
        for _ in 0..3 {
            held.push(sessions(&mut client, &mut server).await);
        }
        assert_eq!(server.shared().datagram_demux().slot_count(), 3);

        let fourth = spawn({
            let mut client = client.clone();
            async move { client.send_request(connect(TOKEN, true)).await }
        });
        let early = tokio::time::timeout(Duration::from_millis(100), server.accept()).await;
        assert!(early.is_err(), "a fourth stream beyond the limit arrived");
        assert_eq!(server.shared().datagram_demux().slot_count(), 3);

        // One session ends: its slot goes, and the waiting request takes the stream credit.
        drop(held.pop());
        let (_request, response) = server.accept().await.unwrap().resolve().await.unwrap();
        response.send_response(accepted(true)).await.unwrap();
        assert_eq!(fourth.await.unwrap().unwrap().status(), StatusCode::OK);
        assert!(server.shared().datagram_demux().slot_count() <= 3);
        pair.close().await;
    })
    .await
    .unwrap();
}

/// A carrier handle kept after its tunnel ended keeps the registration, until it is dropped.
#[tokio::test]
async fn a_retained_carrier_handle_keeps_its_registration() {
    tokio::time::timeout(LIMIT, async {
        let pair = Pair::in_memory(None, None).await;
        let (mut client, mut server) = start(&pair, server_config(Some(Default::default()))).await;
        let (client_session, server_session) = sessions(&mut client, &mut server).await;
        let retained = server_session.native().unwrap().clone();
        drop((client_session, server_session));
        tokio::time::sleep(Duration::from_millis(50)).await;
        assert_eq!(server.shared().datagram_demux().slot_count(), 1);
        drop(retained);
        while server.shared().datagram_demux().slot_count() != 0 {
            tokio::time::sleep(Duration::from_millis(1)).await;
        }
        pair.close().await;
    })
    .await
    .unwrap();
}

#[tokio::test]
async fn cancelled_extended_connects_release_their_datagram_slots() {
    tokio::time::timeout(LIMIT, async {
        let pair = Pair::in_memory(None, None).await;
        let (mut client, mut server) = start(&pair, server_config(Some(Default::default()))).await;

        // Cancelled while waiting for the response HEADERS.
        let pending = spawn({
            let mut client = client.clone();
            async move { client.send_request(connect(TOKEN, true)).await }
        });
        let (_request, held) = server.accept().await.unwrap().resolve().await.unwrap();
        pending.abort();
        assert!(pending.await.unwrap_err().is_cancelled());
        drop(held);
        slots_released(&client, &server).await;
        qpack_settled(&client, &server).await;

        // Abandoned mid-capsule after the tunnel opened.
        let (mut client_io, server_io) = tunnel(&mut client, &mut server, TOKEN).await;
        let mut server_session = HttpDatagramSession::new(server_io);
        // A DATAGRAM capsule header announcing more bytes than ever follow.
        client_io.write_all(&[0x00, 0x10, b'p']).await.unwrap();
        client_io.flush().await.unwrap();
        drop(client_io);
        let ended = server_session.recv().await;
        assert!(!matches!(ended, Ok(Some(_))), "{ended:?}");
        drop(server_session);
        slots_released(&client, &server).await;
        qpack_settled(&client, &server).await;

        // The connection serves a full session afterwards.
        let (mut client_session, mut server_session) = sessions(&mut client, &mut server).await;
        native_ready(&client_session).await;
        client_session
            .send_datagram(Bytes::from_static(b"after"))
            .await
            .unwrap();
        assert_eq!(server_session.recv().await.unwrap(), native(b"after"));
        pair.close().await;
    })
    .await
    .unwrap();
}

/// Wait until a datagram for the server was either discarded or buffered; report which.
async fn discarded_or_buffered(server: &ServerConnection<QuicConnection>) -> (u64, usize) {
    loop {
        let discarded = server.datagram_drops().receive_closed;
        let buffered = server.shared().datagram_demux().buffered();
        if discarded > 0 || buffered > 0 {
            return (discarded, buffered);
        }
        tokio::time::sleep(Duration::from_millis(1)).await;
    }
}

#[tokio::test]
async fn full_native_queues_reject_or_displace_by_send_policy() {
    tokio::time::timeout(LIMIT, async {
        let mut transport = TransportConfig::default();
        Config::default()
            .configure_transport(&mut transport)
            .unwrap();
        transport.set_datagram_send_buffer_size(256);
        let pair = Pair::in_memory(Some(transport), None).await;
        let (mut client, mut server) = start(&pair, server_config(Some(Default::default()))).await;
        let (client_session, mut server_session) = sessions(&mut client, &mut server).await;
        native_ready(&client_session).await;
        let channel = client_session.native().unwrap().channel();
        let reject = NativeSendPolicy::RejectWhenFull;
        // Without yielding, the driver cannot drain the queue: it fills and then rejects.
        let mut accepted = 0u8;
        while channel
            .send(Bytes::from(vec![accepted; 64]), reject)
            .is_ok()
        {
            accepted += 1;
            assert!(accepted < 16, "the 256 byte send queue never filled");
        }
        assert!(accepted > 0);
        assert_eq!(
            channel.send(Bytes::from(vec![0xff; 64]), reject),
            Err(NativeSendError::Full)
        );
        // Every accepted datagram is kept and delivered, in order, on this lossless link.
        for expected in 0..accepted {
            let Some(SessionEvent::Datagram { payload, transport }) =
                server_session.recv().await.unwrap()
            else {
                panic!("no datagram");
            };
            assert_eq!(transport, DatagramTransport::Native);
            assert_eq!(
                &payload[..],
                [expected; 64],
                "a rejected send displaced nothing"
            );
        }
        // The drained queue accepts again. The default policy never reports Full: without
        // a yield in between, its sends displace the still-queued older datagram.
        while channel.send(Bytes::from_static(b"again"), reject).is_err() {
            tokio::time::sleep(Duration::from_millis(1)).await;
        }
        for _ in 0..16 {
            channel
                .send(Bytes::from_static(b"displace"), Default::default())
                .unwrap();
        }
        assert_eq!(server_session.recv().await.unwrap(), native(b"displace"));
        pair.close().await;
    })
    .await
    .unwrap();
}

#[tokio::test]
async fn native_payloads_up_to_the_maximum_are_sent() {
    tokio::time::timeout(LIMIT, async {
        let pair = Pair::in_memory(None, None).await;
        let (mut client, mut server) = start(&pair, server_config(Some(Default::default()))).await;
        let (mut client_session, mut server_session) = sessions(&mut client, &mut server).await;
        let max = native_ready(&client_session).await;
        assert_eq!(
            client_session
                .send_datagram(Bytes::from(vec![7; max]))
                .await
                .unwrap(),
            DatagramTransport::Native
        );
        let Some(SessionEvent::Datagram { payload, transport }) =
            server_session.recv().await.unwrap()
        else {
            panic!("no datagram");
        };
        assert_eq!((payload.len(), transport), (max, DatagramTransport::Native));
        pair.close().await;
    })
    .await
    .unwrap();
}

#[tokio::test]
async fn a_dropped_tunnel_stops_receiving_for_remaining_carrier_holders() {
    tokio::time::timeout(LIMIT, async {
        let pair = Pair::in_memory(None, None).await;
        let (mut client, mut server) = start(&pair, server_config(Some(Default::default()))).await;
        // A bare tunnel: no session receiver whose release would end receiving first.
        let (client_io, server_io) = tunnel(&mut client, &mut server, TOKEN).await;
        // The client side stays open, so only the server's tunnel ends.
        let client_session = HttpDatagramSession::new(client_io);
        native_ready(&client_session).await;
        // Keeps the request's registration alive past its tunnel.
        let holder = server_io
            .extensions()
            .get_ref::<NativeDatagrams>()
            .cloned()
            .unwrap();
        drop(server_io);
        pair.client.send_datagram(raw_datagram(0, b"late")).unwrap();
        assert_eq!(discarded_or_buffered(&server).await, (1, 0));
        drop((holder, client_session));
        pair.close().await;
    })
    .await
    .unwrap();
}

#[tokio::test]
async fn a_released_receiver_discards_later_datagrams() {
    tokio::time::timeout(LIMIT, async {
        let pair = Pair::in_memory(None, None).await;
        let (mut client, mut server) = start(&pair, server_config(Some(Default::default()))).await;
        let (mut client_session, server_session) = sessions(&mut client, &mut server).await;
        native_ready(&client_session).await;
        let (_sender, receiver) = server_session.split();
        drop(receiver);
        assert_eq!(
            client_session
                .send_datagram(Bytes::from_static(b"unread"))
                .await
                .unwrap(),
            DatagramTransport::Native
        );
        assert_eq!(discarded_or_buffered(&server).await, (1, 0));
        pair.close().await;
    })
    .await
    .unwrap();
}

/// Stream credit far below what the tunnels write, so their FIN cannot be sent yet.
fn tight_stream_window() -> TransportConfig {
    let mut transport = TransportConfig::default();
    Config::default()
        .configure_transport(&mut transport)
        .unwrap();
    transport.set_stream_receive_window(1024u32);
    transport
}

/// Queue more than the peer's credit and start shutting down: native sending must stop at
/// once, before the FIN is committed (RFC 9297 §2.1), for every holder of the channel.
async fn native_closes_while_shutdown_is_pending(mut io: Upgraded) {
    let native = io
        .extensions()
        .get_ref::<NativeDatagrams>()
        .cloned()
        .unwrap();
    while native.channel().max_payload_size().is_none() {
        tokio::task::yield_now().await;
    }
    let accepted = io.write(&vec![1; 65536]).await.unwrap();
    assert!(accepted > 1024);
    let mut cx = Context::from_waker(Waker::noop());
    assert!(Pin::new(&mut io).poll_shutdown(&mut cx).is_pending());
    assert_eq!(
        native
            .channel()
            .send(Bytes::from_static(b"after"), NativeSendPolicy::DropOldest),
        Err(NativeSendError::Closed)
    );
}

#[tokio::test]
async fn a_pending_shutdown_closes_native_sending_before_its_fin() {
    for client_side in [true, false] {
        tokio::time::timeout(LIMIT, async {
            // The peer of the side under test grants only a small stream window.
            let pair = if client_side {
                Pair::in_memory(None, Some(tight_stream_window())).await
            } else {
                Pair::in_memory(Some(tight_stream_window()), None).await
            };
            let (mut client, mut server) =
                start(&pair, server_config(Some(Default::default()))).await;
            let (client_io, server_io) = tunnel(&mut client, &mut server, TOKEN).await;
            let (tested, peer) = if client_side {
                (client_io, server_io)
            } else {
                (server_io, client_io)
            };
            native_closes_while_shutdown_is_pending(tested).await;
            drop(peer);
            pair.close().await;
        })
        .await
        .unwrap();
    }
}

#[tokio::test]
async fn a_cleanly_ended_session_delivers_then_frees_its_pre_fin_native_queue() {
    for through_session in [false, true] {
        tokio::time::timeout(LIMIT, async {
            let pair = Pair::in_memory(None, None).await;
            let (mut client, mut server) =
                start(&pair, server_config(Some(Default::default()))).await;
            let (client_io, mut server_io) = tunnel(&mut client, &mut server, TOKEN).await;
            let mut client_session = HttpDatagramSession::new(client_io);
            native_ready(&client_session).await;
            // Queued at the server before the client finishes its data stream.
            client_session
                .send_datagram(Bytes::from_static(b"pre-fin"))
                .await
                .unwrap();
            while server.shared().datagram_demux().buffered() == 0 {
                tokio::time::sleep(Duration::from_millis(1)).await;
            }
            client_session.close().await.unwrap();
            let mut rest = Vec::new();
            server_io.read_to_end(&mut rest).await.unwrap();
            assert!(rest.is_empty());
            if !through_session {
                // A raw consumer can still drain what arrived before the FIN.
                let native = server_io
                    .extensions()
                    .get_ref::<NativeDatagrams>()
                    .cloned()
                    .unwrap();
                let received = std::future::poll_fn(|cx| native.channel().poll_recv(cx)).await;
                assert_eq!(received, Ok(Some(Bytes::from_static(b"pre-fin"))));
                pair.close().await;
                return;
            }
            let mut server_session = HttpDatagramSession::new(server_io);
            // What arrived before the FIN is delivered before the end.
            assert_eq!(
                server_session.recv().await.unwrap(),
                Some(SessionEvent::Datagram {
                    payload: Bytes::from_static(b"pre-fin"),
                    transport: DatagramTransport::Native,
                })
            );
            assert_eq!(server_session.recv().await.unwrap(), None);
            assert_eq!(server_session.recv().await.unwrap(), None);
            // The ended receiver is still alive, yet its native queue is released.
            assert_eq!(server.shared().datagram_demux().buffered(), 0);
            // The healthy reverse direction keeps working.
            assert_eq!(
                server_session
                    .send_datagram(Bytes::from_static(b"back"))
                    .await
                    .unwrap(),
                DatagramTransport::Native
            );
            assert_eq!(client_session.recv().await.unwrap(), native(b"back"));
            pair.close().await;
        })
        .await
        .unwrap();
    }
}

#[tokio::test(start_paused = true)]
async fn clean_connection_close_drains_native_datagrams_before_ending_tunnels() {
    // Include both native/stream polling parities, with and without buffered data.
    for count in [0, 1, 64, 65] {
        for native_first in [false, true] {
            clean_connection_close_drains_native_datagrams(false, count, native_first).await;
        }
    }
}

#[tokio::test(start_paused = true)]
async fn a_buffered_datagram_violation_outranks_clean_connection_close() {
    clean_connection_close_drains_native_datagrams(true, 64, false).await;
}

async fn clean_connection_close_drains_native_datagrams(
    malformed: bool,
    count: usize,
    native_first: bool,
) {
    tokio::time::timeout(LIMIT, async {
        let pair = Pair::in_memory(None, None).await;
        // Large cases span scheduling quanta; the final payload models a tunneled close.
        let config = DatagramConfig {
            limits: DatagramLimits {
                queue_len: count,
                ..Default::default()
            },
            violations: ViolationPolicy::Reject,
        };
        let (mut client, client_driver) =
            client::handshake::<Body, _>(pair.client.clone(), Config::default(), Executor::new())
                .unwrap();
        spawn(client_driver.run());
        let (mut server, driver) =
            server::handshake(pair.server.clone(), server_config(Some(config))).unwrap();
        let mut driver = pin!(driver.run());
        let (mut sender, mut receiver) = tokio::select! {
            sessions = sessions(&mut client, &mut server) => sessions,
            result = &mut driver => panic!("driver ended during setup: {result:?}"),
        };
        native_ready(&sender).await;
        if native_first {
            // A cancelled idle read advances source fairness before FIN arrives.
            let mut receiving = pin!(receiver.recv());
            assert!(poll!(receiving.as_mut()).is_pending());
        }
        // Leave the HTTP/3 driver unpolled, while the QUIC drivers still deliver and
        // acknowledge the datagrams and FIN. No packets are lost on this memory link.
        for index in 0..count {
            sender
                .send_datagram(Bytes::from(vec![index as u8]))
                .await
                .unwrap();
        }
        if malformed {
            // No Quarter Stream ID: a connection-level H3_DATAGRAM_ERROR.
            pair.client.send_datagram(Bytes::new()).unwrap();
        }
        sender.close().await.unwrap();
        assert_eq!(
            pair.server.received_datagrams(),
            count + usize::from(malformed)
        );
        assert_eq!(server.shared().datagram_demux().buffered(), 0);
        pair.client.close(Code::H3_NO_ERROR.value() as u32, b"done");
        pair.server.closed().await;

        let result = driver.await;
        if malformed {
            assert_eq!(result.unwrap_err().code(), Code::H3_DATAGRAM_ERROR);
            pair.close().await;
            return;
        }
        result.unwrap();
        assert_eq!(pair.server.received_datagrams(), 0);
        for index in 0..count {
            assert_eq!(
                receiver.recv().await.unwrap(),
                Some(SessionEvent::Datagram {
                    payload: Bytes::from(vec![index as u8]),
                    transport: DatagramTransport::Native,
                }),
                "payload {index} was received before the carrier closed"
            );
        }
        assert_eq!(receiver.recv().await.unwrap(), None);
        pair.close().await;
    })
    .await
    .unwrap();
}

#[tokio::test]
async fn truncated_capsules_reset_http3_streams_as_malformed() {
    tokio::time::timeout(LIMIT, async {
        let pair = Pair::in_memory(None, None).await;
        let (mut client, mut server) = start(&pair, server_config(None)).await;
        let (mut client_io, server_io) = tunnel(&mut client, &mut server, TOKEN).await;
        let mut session = HttpDatagramSession::new(server_io);
        client_io.write_all(b"\x00\x05ab").await.unwrap();
        client_io.shutdown().await.unwrap();
        let error = session.recv().await.unwrap_err();
        assert_matches!(error, SessionError::Malformed(_), "{error:?}");
        let mut rest = Vec::new();
        let error = client_io.read_to_end(&mut rest).await.unwrap_err();
        let error = error
            .get_ref()
            .and_then(|error| error.downcast_ref::<H3Error>())
            .copied()
            .expect("h3 error");
        assert_eq!(error.code(), Code::H3_MESSAGE_ERROR);
        pair.close().await;
    })
    .await
    .unwrap();
}

fn capsule_header(ty: CapsuleType, length: u64) -> BytesMut {
    let mut header = BytesMut::new();
    CapsuleHeader::new(ty, length).unwrap().encode(&mut header);
    header
}

#[tokio::test]
async fn http3_capsule_limits_apply_before_values_arrive() {
    tokio::time::timeout(LIMIT, async {
        let pair = Pair::in_memory(None, None).await;
        let (mut client, mut server) = start(&pair, server_config(None)).await;
        let (mut client_io, server_io) = tunnel(&mut client, &mut server, TOKEN).await;
        let control = CapsuleType::new(0x2a).unwrap();
        let mut config = SessionConfig::default();
        config.capsules.max_datagram_size = 8;
        config.capsules.max_capsule_size = 8;
        config.capsules.capsule_types = [control].into();
        let (_sender, mut receiver) = HttpDatagramSession::with_config(server_io, config).split();

        // Zero length is legal; a DATAGRAM value over the limit is skipped as it streams in.
        client_io
            .write_all(&capsule_header(CapsuleType::DATAGRAM, 0))
            .await
            .unwrap();
        let oversized = mib(1);
        client_io
            .write_all(&capsule_header(CapsuleType::DATAGRAM, oversized as u64))
            .await
            .unwrap();
        let skip = spawn(async move {
            client_io.write_all(&vec![0; oversized]).await.unwrap();
            let mut small = capsule_header(CapsuleType::DATAGRAM, 2);
            small.extend_from_slice(b"ok");
            client_io.write_all(&small).await.unwrap();
            client_io.flush().await.unwrap();
            client_io
        });
        let capsule = |payload: &'static [u8]| {
            Some(SessionEvent::Datagram {
                payload: Bytes::from_static(payload),
                transport: DatagramTransport::Capsule,
            })
        };
        assert_eq!(receiver.recv().await.unwrap(), capsule(b""));
        assert_eq!(receiver.recv().await.unwrap(), capsule(b"ok"));
        assert_eq!(receiver.dropped_datagrams(), 1);
        let mut client_io = skip.await.unwrap();

        // A registered control capsule over its limit fails on its header alone.
        client_io
            .write_all(&capsule_header(control, oversized as u64))
            .await
            .unwrap();
        client_io.flush().await.unwrap();
        let error = receiver.recv().await.unwrap_err();
        assert_matches!(error, SessionError::Malformed(_), "{error:?}");
        let mut rest = Vec::new();
        let error = client_io.read_to_end(&mut rest).await.unwrap_err();
        let error = error
            .get_ref()
            .and_then(|error| error.downcast_ref::<H3Error>())
            .copied()
            .expect("h3 error");
        assert_eq!(error.code(), Code::H3_MESSAGE_ERROR);
        pair.close().await;
    })
    .await
    .unwrap();
}

#[tokio::test]
async fn datagram_floods_do_not_starve_request_streams() {
    tokio::time::timeout(LIMIT, async {
        let pair = Pair::new(None, None).await;
        let (mut client, mut server) = start(&pair, server_config(Some(Default::default()))).await;
        // A claimed but never-read association absorbs the flood.
        let (_client_io, _server_io) = tunnel(&mut client, &mut server, TOKEN).await;
        let flood = {
            let connection = pair.client.clone();
            spawn(async move {
                let datagram = raw_datagram(0, &[0; 512]);
                loop {
                    if connection.send_datagram(datagram.clone()).is_err() {
                        return;
                    }
                    tokio::task::yield_now().await;
                }
            })
        };
        let serve = spawn(async move {
            for _ in 0..5 {
                let (_request, response) = server.accept().await.unwrap().resolve().await.unwrap();
                response
                    .send_response(Response::new(Body::from("ok")))
                    .await
                    .unwrap();
            }
            server
        });
        for _ in 0..5 {
            let request = Request::builder()
                .uri("https://localhost/")
                .body(Body::empty())
                .unwrap();
            let response = client.send_request(request).await.unwrap();
            assert_eq!(response.status(), StatusCode::OK);
        }
        let server = serve.await.unwrap();
        // The flood was bounded by the association queue and the connection budget.
        {
            let demux = server.shared().datagram_demux();
            assert!(demux.pending_len() <= DatagramLimits::default().pending_len);
            assert!(demux.buffered() <= DatagramLimits::default().max_buffered_bytes);
        }
        flood.abort();
        pair.close().await;
    })
    .await
    .unwrap();
}

/// The peer's error code on an aborted request stream.
async fn stream_error(io: &mut Upgraded) -> Code {
    let mut byte = [0; 1];
    let error = io.read(&mut byte).await.unwrap_err();
    error
        .get_ref()
        .and_then(|error| error.downcast_ref::<H3Error>())
        .copied()
        .expect("h3 error")
        .code()
}

#[tokio::test]
async fn rejected_violations_abort_unpolled_requests_in_both_roles() {
    // No buffering at all: eligibility is decided without any retained payload.
    let limits = DatagramLimits {
        queue_len: 0,
        pending_len: 0,
        max_buffered_bytes: 0,
    };
    tokio::time::timeout(LIMIT, async {
        let pair = Pair::in_memory(None, None).await;
        let strict = || Config {
            extended_connect: true,
            datagrams: datagrams(limits.clone(), ViolationPolicy::Reject),
            ..Config::default()
        };
        let (mut client, mut server) = start_both(&pair, strict(), strict()).await;
        // Server role: a datagram for an undeclared tunnel nobody polls.
        let (mut client_io, mut server_io) =
            tunnel_with(&mut client, &mut server, Protocol::WEBSOCKET, false, false).await;
        pair.client.send_datagram(raw_datagram(0, b"x")).unwrap();
        assert_eq!(stream_error(&mut client_io).await, Code::H3_DATAGRAM_ERROR);
        server_io.read(&mut [0; 1]).await.unwrap_err();
        // Client role, likewise.
        let (mut client_io, mut server_io) =
            tunnel_with(&mut client, &mut server, Protocol::WEBSOCKET, false, false).await;
        pair.server.send_datagram(raw_datagram(4, b"y")).unwrap();
        assert_eq!(stream_error(&mut server_io).await, Code::H3_DATAGRAM_ERROR);
        client_io.read(&mut [0; 1]).await.unwrap_err();
        assert_eq!(server.datagram_drops().no_semantics, 1);
        assert_eq!(client.datagram_drops().no_semantics, 1);
        qpack_settled(&client, &server).await;
        // Later requests, control and QPACK keep working.
        for _ in 0..2 {
            let (mut a, mut b) = tunnel(&mut client, &mut server, TOKEN).await;
            a.write_all(b"ok").await.unwrap();
            a.flush().await.unwrap();
            let mut buf = [0; 2];
            b.read_exact(&mut buf).await.unwrap();
        }
        pair.close().await;
    })
    .await
    .unwrap();
}

#[tokio::test]
async fn refused_connects_remember_datagrams_routed_before_the_response() {
    for queue_len in [0, 4] {
        tokio::time::timeout(LIMIT, async {
            let pair = Pair::in_memory(None, None).await;
            let limits = DatagramLimits {
                queue_len,
                ..DatagramLimits::default()
            };
            let client_config = Config {
                datagrams: datagrams(limits, ViolationPolicy::Reject),
                ..Config::default()
            };
            let (mut client, mut server) = start_both(
                &pair,
                client_config,
                server_config(Some(DatagramConfig::default())),
            )
            .await;
            let observer = client.clone();
            let serve = async {
                let (_request, response) = server.accept().await.unwrap().resolve().await.unwrap();
                pair.server
                    .send_datagram(raw_datagram(0, b"early"))
                    .unwrap();
                // Routed to the client's claimed slot, retained or discarded, before the 403.
                while observer.datagram_drops().queue_full == 0
                    && observer.shared().datagram_demux().buffered() == 0
                {
                    tokio::time::sleep(Duration::from_millis(1)).await;
                }
                let mut refused = Response::new(Body::from("refused"));
                *refused.status_mut() = StatusCode::FORBIDDEN;
                _ = response.send_response(refused).await;
            };
            let (response, ()) = tokio::join!(client.send_request(connect(TOKEN, true)), serve);
            let rejected = match response {
                Err(_) => true,
                Ok(response) => response.into_body().collect().await.is_err(),
            };
            assert!(rejected, "queue_len={queue_len}");
            let (_client_io, _server_io) = tunnel(&mut client, &mut server, TOKEN).await;
            pair.close().await;
        })
        .await
        .unwrap();
    }
}

#[tokio::test]
async fn local_abort_hooks_end_both_directions_at_once() {
    for malformed in [true, false] {
        tokio::time::timeout(LIMIT, async {
            let pair = Pair::in_memory(None, None).await;
            let (mut client, mut server) =
                start(&pair, server_config(Some(DatagramConfig::default()))).await;
            let (mut client_io, mut server_io) = tunnel(&mut client, &mut server, TOKEN).await;
            let native = server_io
                .extensions()
                .get_ref::<NativeDatagrams>()
                .cloned()
                .unwrap();
            // Reliable bytes and a native datagram already buffered on the server side.
            client_io.write_all(b"abc").await.unwrap();
            client_io.flush().await.unwrap();
            assert_eq!(server_io.read_u8().await.unwrap(), b'a');
            pair.client
                .send_datagram(raw_datagram(0, b"queued"))
                .unwrap();
            while server.shared().datagram_demux().buffered() != MIN_DATAGRAM_CHARGE {
                tokio::time::sleep(Duration::from_millis(1)).await;
            }
            let (code, upstream) = if malformed {
                let hook = server_io.extensions().get_arc::<OnMalformedMessage>();
                hook.unwrap().call();
                (Code::H3_MESSAGE_ERROR, false)
            } else {
                let hook = server_io.extensions().self_get_arc::<AbortIo>();
                hook.unwrap().abort();
                // RFC 9220 §3: an Extended CONNECT tunnel aborts as H3_REQUEST_CANCELLED.
                (Code::H3_REQUEST_CANCELLED, true)
            };
            // Native receiving ends without any reliable read, discarding what was queued.
            assert_eq!(server.shared().datagram_demux().buffered(), 0);
            let mut cx = Context::from_waker(Waker::noop());
            assert_eq!(
                native.channel().poll_recv(&mut cx),
                Poll::Ready(Err(NativeRecvError::Aborted(code.value()))),
                "upstream={upstream}"
            );
            // Newly arriving datagrams are dropped, not delivered.
            let before = server.datagram_drops().receive_closed;
            pair.client.send_datagram(raw_datagram(0, b"late")).unwrap();
            wait_drops(&server, |drops| drops.receive_closed > before).await;
            assert_eq!(
                native.channel().poll_recv(&mut cx),
                Poll::Ready(Err(NativeRecvError::Aborted(code.value())))
            );
            assert_eq!(server.shared().datagram_demux().buffered(), 0);
            // Buffered reliable bytes are not served after the abort.
            assert_eq!(stream_error(&mut server_io).await, code);
            let (_a, _b) = tunnel(&mut client, &mut server, TOKEN).await;
            pair.close().await;
        })
        .await
        .unwrap();
    }
}

#[tokio::test]
async fn connection_loss_is_never_reported_as_a_peer_reset() {
    tokio::time::timeout(LIMIT, async {
        let pair = Pair::in_memory(None, None).await;
        let (mut client, mut server) =
            start(&pair, server_config(Some(DatagramConfig::default()))).await;
        let (_client_io, mut server_io) = tunnel(&mut client, &mut server, TOKEN).await;
        let native = server_io
            .extensions()
            .get_ref::<NativeDatagrams>()
            .cloned()
            .unwrap();
        // Only CONNECTION_CLOSE, without a request FIN or RESET_STREAM.
        pair.client
            .close(VarInt::from_u32(Code::H3_NO_ERROR.value() as u32), b"done");
        _ = pair.server.closed().await;
        _ = server.shared().failed().await;
        let mut cx = Context::from_waker(Waker::noop());
        assert_eq!(
            native.channel().poll_recv(&mut cx),
            Poll::Ready(Err(NativeRecvError::Lost))
        );
        assert_eq!(
            stream_error(&mut server_io).await,
            Code::H3_REQUEST_INCOMPLETE
        );
        for _ in 0..2 {
            assert_eq!(
                native.channel().poll_recv(&mut cx),
                Poll::Ready(Err(NativeRecvError::Lost))
            );
        }
        pair.close().await;
    })
    .await
    .unwrap();
}

#[tokio::test]
async fn peer_resets_keep_the_local_send_direction_open() {
    tokio::time::timeout(LIMIT, async {
        let pair = Pair::in_memory(None, None).await;
        let (mut client, _server) =
            start(&pair, server_config(Some(DatagramConfig::default()))).await;
        let (response, (mut peer_send, mut peer_recv)) =
            tokio::join!(client.send_request(connect(TOKEN, true)), raw_accept(&pair));
        let mut session =
            HttpDatagramSession::new(handle_upgrade(&response.unwrap()).await.unwrap());
        native_ready(&session).await;
        let native = session.native().cloned().unwrap();
        native
            .channel()
            .send(Bytes::from_static(b"before"), Default::default())
            .unwrap();
        // The peer ends only its own direction.
        peer_send
            .reset(VarInt::from_u32(Code::H3_REQUEST_CANCELLED.value() as u32))
            .unwrap();
        session.recv().await.unwrap_err();
        let mut cx = Context::from_waker(Waker::noop());
        assert_eq!(
            native.channel().poll_recv(&mut cx),
            Poll::Ready(Err(NativeRecvError::Reset(
                Code::H3_REQUEST_CANCELLED.value()
            )))
        );
        native
            .channel()
            .send(Bytes::from_static(b"after"), Default::default())
            .unwrap();
        session
            .send_capsule(
                CapsuleType::new(0x2a).unwrap(),
                Bytes::from_static(b"reverse"),
            )
            .await
            .unwrap();
        // The peer still receives reliable data, possibly split over DATA frames.
        let mut reverse = Vec::new();
        while reverse.len() < 9 {
            assert_eq!(peer_recv.read_u8().await.unwrap(), 0);
            let len = usize::from(peer_recv.read_u8().await.unwrap());
            let start = reverse.len();
            reverse.resize(start + len, 0);
            peer_recv.read_exact(&mut reverse[start..]).await.unwrap();
        }
        assert_eq!(&reverse, b"\x2a\x07reverse");
        for _ in 0..2 {
            let (response, _raw) =
                tokio::join!(client.send_request(connect(TOKEN, true)), raw_accept(&pair));
            assert_eq!(response.unwrap().status(), StatusCode::OK);
        }
        pair.close().await;
    })
    .await
    .unwrap();
}

#[tokio::test]
async fn peer_resets_keep_their_raw_wire_code() {
    tokio::time::timeout(LIMIT, async {
        let pair = Pair::in_memory(None, None).await;
        let (mut client, _server) =
            start(&pair, server_config(Some(DatagramConfig::default()))).await;
        let (response, (mut peer_send, _peer_recv)) =
            tokio::join!(client.send_request(connect(TOKEN, true)), raw_accept(&pair));
        let mut session =
            HttpDatagramSession::new(handle_upgrade(&response.unwrap()).await.unwrap());
        native_ready(&session).await;
        let native = session.native().cloned().unwrap();
        // An unknown code: H3_NO_ERROR semantics (RFC 9114 §8), yet reported as received.
        peer_send.reset(VarInt::from_u32(0xdead)).unwrap();
        session.recv().await.unwrap_err();
        let mut cx = Context::from_waker(Waker::noop());
        assert_eq!(
            native.channel().poll_recv(&mut cx),
            Poll::Ready(Err(NativeRecvError::Reset(0xdead)))
        );
        native
            .channel()
            .send(Bytes::from_static(b"after"), Default::default())
            .unwrap();
        pair.close().await;
    })
    .await
    .unwrap();
}

#[tokio::test]
async fn local_connection_close_is_reported_as_lost() {
    tokio::time::timeout(LIMIT, async {
        let pair = Pair::in_memory(None, None).await;
        let (mut client, mut server) =
            start(&pair, server_config(Some(DatagramConfig::default()))).await;
        let (_client_io, mut server_io) = tunnel(&mut client, &mut server, TOKEN).await;
        let native = server_io
            .extensions()
            .get_ref::<NativeDatagrams>()
            .cloned()
            .unwrap();
        // This endpoint closes the connection, without a request FIN or RESET_STREAM.
        pair.server
            .close(VarInt::from_u32(Code::H3_NO_ERROR.value() as u32), b"done");
        _ = pair.server.closed().await;
        _ = server.shared().failed().await;
        let mut cx = Context::from_waker(Waker::noop());
        assert_eq!(
            native.channel().poll_recv(&mut cx),
            Poll::Ready(Err(NativeRecvError::Lost))
        );
        assert_eq!(
            stream_error(&mut server_io).await,
            Code::H3_REQUEST_INCOMPLETE
        );
        for _ in 0..2 {
            assert_eq!(
                native.channel().poll_recv(&mut cx),
                Poll::Ready(Err(NativeRecvError::Lost))
            );
        }
        pair.close().await;
    })
    .await
    .unwrap();
}

#[tokio::test]
async fn peer_resets_mid_frame_stay_terminal_for_tunnel_reads() {
    // The reset lands inside a DATA frame, after its header, and at a frame boundary.
    for (wire, readable) in [(&b"\x00\x05x"[..], 1), (b"\x00", 0), (b"\x00\x01x", 1)] {
        tokio::time::timeout(LIMIT, async {
            let pair = Pair::in_memory(None, None).await;
            let (mut client, _server) =
                start(&pair, server_config(Some(DatagramConfig::default()))).await;
            let (response, (mut peer_send, mut peer_recv)) =
                tokio::join!(client.send_request(connect(TOKEN, true)), raw_accept(&pair));
            let mut io = handle_upgrade(&response.unwrap()).await.unwrap();
            peer_send.write_all(wire).await.unwrap();
            for _ in 0..readable {
                assert_eq!(io.read_u8().await.unwrap(), b'x');
            }
            peer_send
                .reset(VarInt::from_u32(Code::H3_REQUEST_CANCELLED.value() as u32))
                .unwrap();
            // Every later read reports the same reset, never a connection frame error.
            for _ in 0..3 {
                assert_eq!(
                    stream_error(&mut io).await,
                    Code::H3_REQUEST_CANCELLED,
                    "{wire:?}"
                );
            }
            // The local send direction still reaches the peer.
            io.write_all(b"reverse").await.unwrap();
            io.flush().await.unwrap();
            let mut reverse = Vec::new();
            while reverse.len() < 7 {
                assert_eq!(peer_recv.read_u8().await.unwrap(), 0);
                let len = usize::from(peer_recv.read_u8().await.unwrap());
                let start = reverse.len();
                reverse.resize(start + len, 0);
                peer_recv.read_exact(&mut reverse[start..]).await.unwrap();
            }
            assert_eq!(&reverse, b"reverse");
            for _ in 0..2 {
                let (response, _raw) =
                    tokio::join!(client.send_request(connect(TOKEN, true)), raw_accept(&pair));
                assert_eq!(response.unwrap().status(), StatusCode::OK);
            }
            pair.close().await;
        })
        .await
        .unwrap();
    }
}

#[tokio::test]
async fn connection_loss_stays_lost_across_repeated_reads() {
    // Either tunnel end, either endpoint closing, clean or unknown code, either read order.
    for server_side in [true, false] {
        for local_close in [true, false] {
            for code in [Code::H3_NO_ERROR.value(), 0x1f0a] {
                for native_first in [true, false] {
                    tokio::time::timeout(LIMIT, async {
                        let pair = Pair::in_memory(None, None).await;
                        let (mut client, mut server) =
                            start(&pair, server_config(Some(DatagramConfig::default()))).await;
                        let (client_io, server_io) =
                            tunnel(&mut client, &mut server, TOKEN).await;
                        let (mut io, _other) = if server_side {
                            (server_io, client_io)
                        } else {
                            (client_io, server_io)
                        };
                        let native = io.extensions().get_ref::<NativeDatagrams>().cloned().unwrap();
                        let (this, peer) = if server_side {
                            (&pair.server, &pair.client)
                        } else {
                            (&pair.client, &pair.server)
                        };
                        let closer = if local_close { this } else { peer };
                        closer.close(VarInt::from_u64(code).unwrap(), b"done");
                        _ = this.closed().await;
                        if server_side {
                            _ = server.shared().failed().await;
                        } else {
                            _ = client.shared().failed().await;
                        }
                        let mut cx = Context::from_waker(Waker::noop());
                        let lost = Poll::Ready(Err(NativeRecvError::Lost));
                        if native_first {
                            assert_eq!(native.channel().poll_recv(&mut cx), lost);
                        }
                        let first = stream_error(&mut io).await;
                        for turn in 0..3 {
                            assert_eq!(
                                native.channel().poll_recv(&mut cx),
                                lost,
                                "server={server_side} local={local_close} code={code:#x} turn={turn}"
                            );
                            // Every reliable read repeats the same loss, never a stream abort.
                            assert_eq!(stream_error(&mut io).await, first);
                        }
                        pair.close().await;
                    })
                    .await
                    .unwrap();
                }
            }
        }
    }
}

#[tokio::test]
async fn a_rejected_native_send_is_not_logged_as_created() {
    tokio::time::timeout(LIMIT, async {
        let log = Sink::new(true);
        let mut transport = TransportConfig::default().with_qlog_sink(Arc::new(log.clone()));
        Config::default()
            .configure_transport(&mut transport)
            .unwrap();
        transport.set_datagram_send_buffer_size(256);
        let pair = Pair::in_memory(Some(transport), None).await;
        let (mut client, mut server) = start(&pair, server_config(Some(Default::default()))).await;
        let (client_session, _server_session) = sessions(&mut client, &mut server).await;
        native_ready(&client_session).await;
        let channel = client_session.native().unwrap().channel();
        let reject = NativeSendPolicy::RejectWhenFull;
        let mut accepted = 0;
        while channel.send(Bytes::from(vec![0; 64]), reject).is_ok() {
            accepted += 1;
            assert!(accepted < 16, "the 256 byte send queue never filled");
        }
        assert_eq!(log.count("http3:datagram_created"), accepted);
        pair.close().await;
    })
    .await
    .unwrap();
}

/// Fill the native queue under `RejectWhenFull`, returning readiness registered just before
/// the refused send.
fn fill_until_full(native: &NativeDatagrams) -> [NativeSendReady; 2] {
    let channel = native.channel();
    let reject = NativeSendPolicy::RejectWhenFull;
    for attempt in 0..16u8 {
        let readiness = [channel.send_ready(), channel.send_ready()];
        match channel.send(Bytes::from(vec![attempt; 64]), reject) {
            Ok(()) => {}
            Err(NativeSendError::Full) => return readiness,
            Err(error) => panic!("unexpected native send error: {error}"),
        }
    }
    panic!("the 256 byte send queue never filled");
}

async fn small_native_queue() -> (Pair, HttpDatagramSession, HttpDatagramSession) {
    let mut transport = TransportConfig::default();
    Config::default()
        .configure_transport(&mut transport)
        .unwrap();
    transport.set_datagram_send_buffer_size(256);
    let pair = Pair::in_memory(Some(transport), None).await;
    let (mut client, mut server) = start(&pair, server_config(Some(Default::default()))).await;
    let (client_session, server_session) = sessions(&mut client, &mut server).await;
    native_ready(&client_session).await;
    (pair, client_session, server_session)
}

#[tokio::test]
async fn native_send_ready_wakes_every_registration_once_the_queue_drains() {
    tokio::time::timeout(LIMIT, async {
        let (pair, client_session, mut server_session) = small_native_queue().await;
        let native = client_session.native().unwrap().clone();
        let [mut first, mut second] = fill_until_full(&native);
        // Nothing yielded since the refusal: neither registration can have fired yet.
        assert!(poll!(&mut first).is_pending());
        assert!(poll!(&mut second).is_pending());
        // The driver drains the queue without any inbound application datagram.
        first.await;
        second.await;
        let reject = NativeSendPolicy::RejectWhenFull;
        let mut retries = 0;
        loop {
            let ready = native.channel().send_ready();
            match native.channel().send(Bytes::from_static(b"after"), reject) {
                Ok(()) => break,
                Err(NativeSendError::Full) => ready.await,
                Err(error) => panic!("unexpected native send error: {error}"),
            }
            retries += 1;
            assert!(retries < 16, "the drained queue never accepted again");
        }
        loop {
            match server_session.recv().await.unwrap() {
                Some(SessionEvent::Datagram { payload, .. }) if &payload[..] == b"after" => break,
                Some(SessionEvent::Datagram { .. }) => {}
                other => panic!("unexpected event: {other:?}"),
            }
        }
        pair.close().await;
    })
    .await
    .unwrap();
}

#[tokio::test]
async fn native_send_ready_wakes_a_blocked_sender_when_the_send_side_closes() {
    tokio::time::timeout(LIMIT, async {
        let (pair, mut client_session, _server_session) = small_native_queue().await;
        let native = client_session.native().unwrap().clone();
        let [mut blocked, _] = fill_until_full(&native);
        assert!(poll!(&mut blocked).is_pending());
        {
            // The first poll of the half-close commits the end of the send side; nothing
            // has yielded, so the queue cannot have drained.
            let mut close = pin!(client_session.close());
            _ = poll!(close.as_mut());
            assert!(poll!(&mut blocked).is_ready());
        }
        assert_eq!(
            native.channel().send(
                Bytes::from_static(b"late"),
                NativeSendPolicy::RejectWhenFull
            ),
            Err(NativeSendError::Closed)
        );
        // Readiness taken after the close completes at once.
        assert!(poll!(native.channel().send_ready()).is_ready());
        pair.close().await;
    })
    .await
    .unwrap();
}

#[tokio::test(start_paused = true)]
async fn datagram_violation_racing_clean_close_is_reported_consistently() {
    let mut masked = 0;
    for _ in 0..40 {
        tokio::time::timeout(LIMIT, async {
            let pair = Pair::in_memory(None, None).await;
            let config = DatagramConfig {
                limits: DatagramLimits::default(),
                violations: ViolationPolicy::Reject,
            };
            let (mut client, client_driver) = client::handshake::<Body, _>(
                pair.client.clone(),
                Config::default(),
                Executor::new(),
            )
            .unwrap();
            spawn(client_driver.run());
            let (mut server, driver) =
                server::handshake(pair.server.clone(), server_config(Some(config))).unwrap();
            let mut driver = pin!(driver.run());
            let (sender, _receiver) = tokio::select! {
                sessions = sessions(&mut client, &mut server) => sessions,
                result = &mut driver => panic!("driver ended during setup: {result:?}"),
            };
            native_ready(&sender).await;
            // No Quarter Stream ID: a connection-level H3_DATAGRAM_ERROR, read first.
            pair.client.send_datagram(Bytes::new()).unwrap();
            while pair.server.received_datagrams() == 0 {
                tokio::task::yield_now().await;
            }
            pair.client.close(Code::H3_NO_ERROR.value() as u32, b"done");
            pair.server.closed().await;
            match driver.await {
                Ok(()) => masked += 1,
                Err(error) => assert_eq!(error.code(), Code::H3_DATAGRAM_ERROR),
            }
            pair.close().await;
        })
        .await
        .unwrap();
    }
    assert_eq!(masked, 0);
}

#[tokio::test(start_paused = true)]
async fn error_close_after_observed_fin_reports_undrained_datagrams() {
    tokio::time::timeout(LIMIT, async {
        let pair = Pair::in_memory(None, None).await;
        let count = crate::h3::cooperative::OPERATIONS_PER_QUANTUM * 2;
        let config = DatagramConfig {
            limits: DatagramLimits {
                queue_len: count,
                ..Default::default()
            },
            violations: ViolationPolicy::Reject,
        };
        let (mut client, client_driver) =
            client::handshake::<Body, _>(pair.client.clone(), Config::default(), Executor::new())
                .unwrap();
        spawn(client_driver.run());
        let (mut server, driver) =
            server::handshake(pair.server.clone(), server_config(Some(config))).unwrap();
        let mut driver = pin!(driver.run());
        let (mut sender, mut receiver) = tokio::select! {
            sessions = sessions(&mut client, &mut server) => sessions,
            result = &mut driver => panic!("driver ended during setup: {result:?}"),
        };
        native_ready(&sender).await;
        for index in 0..count {
            sender
                .send_datagram(Bytes::from(vec![index as u8]))
                .await
                .unwrap();
        }
        sender.close().await.unwrap();
        assert_eq!(pair.server.received_datagrams(), count);
        // The tunnel reader observes FIN while the driver has not filed the datagrams yet.
        let early =
            tokio::time::timeout(std::time::Duration::from_millis(10), receiver.recv()).await;
        assert!(
            early.is_err(),
            "receiver must wait for the driver: {early:?}"
        );
        pair.client
            .close(Code::H3_INTERNAL_ERROR.value() as u32, b"boom");
        pair.server.closed().await;
        assert!(driver.await.is_err());
        let still_in_quic = pair.server.received_datagrams();
        let outcome = loop {
            match receiver.recv().await {
                Ok(Some(_)) => (),
                other => break other,
            }
        };
        assert!(
            !(still_in_quic > 0 && matches!(outcome, Ok(None))),
            "a clean EOF hides {still_in_quic} undrained datagrams"
        );
        pair.close().await;
    })
    .await
    .unwrap();
}

#[tokio::test(start_paused = true)]
async fn tunnel_fin_is_transmitted_after_earlier_queued_datagrams() {
    tokio::time::timeout(LIMIT, async {
        let count = 1024;
        let transport = || {
            let mut transport = TransportConfig::default();
            Config::default()
                .configure_transport(&mut transport)
                .unwrap();
            transport.set_datagram_receive_buffer_size(4 * 1024 * 1024);
            transport.set_datagram_send_buffer_size(4 * 1024 * 1024);
            transport
        };
        let pair = Pair::build(
            Some(transport()),
            Some(transport()),
            std::num::NonZeroUsize::new(2048),
            false,
        )
        .await;
        let config = DatagramConfig {
            limits: DatagramLimits {
                queue_len: count,
                max_buffered_bytes: count * 1500,
                ..Default::default()
            },
            ..Default::default()
        };
        let (mut client, client_driver) =
            client::handshake::<Body, _>(pair.client.clone(), Config::default(), Executor::new())
                .unwrap();
        let client_driver = spawn(client_driver.run());
        let (mut server, driver) =
            server::handshake(pair.server.clone(), server_config(Some(config))).unwrap();
        let mut driver = pin!(driver.run());
        let (mut sender, mut receiver) = tokio::select! {
            sessions = sessions(&mut client, &mut server) => sessions,
            result = &mut driver => panic!("driver ended during setup: {result:?}"),
        };
        native_ready(&sender).await;
        // One large payload per packet, plus room for a FIN: the old builder let
        // FIN pass the remaining FIFO entries in that leftover packet space.
        for index in 0..count {
            sender
                .send_datagram(Bytes::from(vec![index as u8; 1100]))
                .await
                .unwrap();
        }
        sender.close().await.unwrap();
        assert_eq!(
            pair.server.received_datagrams(),
            count,
            "FIN acknowledged before earlier datagrams were transmitted"
        );
        pair.client.close(Code::H3_NO_ERROR.value() as u32, b"done");
        pair.server.closed().await;
        driver.await.unwrap();
        for index in 0..count {
            assert!(matches!(
                receiver.recv().await.unwrap(),
                Some(SessionEvent::Datagram { payload, .. }) if payload == vec![index as u8; 1100]
            ));
        }
        assert_eq!(receiver.recv().await.unwrap(), None);
        client_driver.await.unwrap().unwrap();
        pair.close().await;
    })
    .await
    .unwrap();
}

#[cfg(feature = "opentelemetry")]
mod metrics {
    use super::*;
    use rama_core::telemetry::opentelemetry::{
        KeyValue, MeterOptions,
        metrics::MeterProvider as _,
        sdk::{
            error::OTelSdkResult,
            metrics::{
                PeriodicReader, SdkMeterProvider, Temporality,
                data::{AggregatedMetrics, MetricData, ResourceMetrics},
                exporter::PushMetricExporter,
            },
        },
    };

    /// The `u64` sum points of the latest export, by metric; cumulative, so the whole state.
    #[derive(Debug, Clone, Default)]
    struct Capture(std::sync::Arc<parking_lot::Mutex<Vec<(String, Vec<KeyValue>, u64)>>>);

    impl PushMetricExporter for Capture {
        async fn export(&self, metrics: &ResourceMetrics) -> OTelSdkResult {
            let mut points = Vec::new();
            for metric in metrics.scope_metrics().flat_map(|scope| scope.metrics()) {
                // Anything else records no points, which the exact expectations reject.
                let AggregatedMetrics::U64(MetricData::Sum(sum)) = metric.data() else {
                    continue;
                };
                points.extend(sum.data_points().map(|point| {
                    (
                        metric.name().to_owned(),
                        point.attributes().cloned().collect(),
                        point.value(),
                    )
                }));
            }
            *self.0.lock() = points;
            Ok(())
        }

        fn force_flush(&self) -> OTelSdkResult {
            Ok(())
        }

        fn shutdown_with_timeout(&self, _timeout: std::time::Duration) -> OTelSdkResult {
            Ok(())
        }

        fn temporality(&self) -> Temporality {
            Temporality::Cumulative
        }
    }

    struct Collector {
        provider: SdkMeterProvider,
        capture: Capture,
        metrics: crate::h3::H3Metrics,
    }

    impl Collector {
        fn new() -> Self {
            let capture = Capture::default();
            let provider = SdkMeterProvider::builder()
                .with_reader(PeriodicReader::builder(capture.clone()).build())
                .build();
            let metrics = crate::h3::H3Metrics::new_with_meter(
                &provider.meter("rama-h3-test"),
                MeterOptions {
                    attributes: Some(vec![KeyValue::new("service", "edge")]),
                    metric_prefix: None,
                },
            );
            Self {
                provider,
                capture,
                metrics,
            }
        }

        /// The recorded drops by reason, all from the server side.
        fn dropped(&self) -> Vec<(String, u64)> {
            self.provider.force_flush().unwrap();
            let mut points = Vec::new();
            for (_, attributes, value) in self
                .capture
                .0
                .lock()
                .iter()
                .filter(|(name, _, _)| name == "h3.datagrams.dropped")
            {
                assert!(attributes.contains(&KeyValue::new("http.h3.side", "server")));
                assert!(attributes.contains(&KeyValue::new("service", "edge")));
                let reason = attributes
                    .iter()
                    .find(|kv| kv.key.as_str() == "reason")
                    .unwrap()
                    .value
                    .to_string();
                points.push((reason, *value));
            }
            points.sort();
            points
        }

        async fn recorded(&self) -> Vec<(String, u64)> {
            loop {
                let points = self.dropped();
                if !points.is_empty() {
                    return points;
                }
                tokio::time::sleep(Duration::from_millis(1)).await;
            }
        }
    }

    fn expected() -> Vec<(String, u64)> {
        vec![
            ("receive_closed".to_owned(), 1),
            ("unknown_stream".to_owned(), 1),
        ]
    }

    /// The first request, released: a late datagram for its stream 0 is dropped as unknown.
    async fn release_first(
        pair: &Pair,
        client: &mut client::SendRequest<Body, QuicConnection>,
        server: &mut ServerConnection<QuicConnection>,
    ) {
        let serve = async {
            let (_request, response) = server.accept().await.unwrap().resolve().await.unwrap();
            response
                .send_response(Response::new(Body::from("ok")))
                .await
                .unwrap();
        };
        let (response, ()) = tokio::join!(client.send_request(get()), serve);
        drop(response.unwrap());
        while server.shared().datagram_demux().slot_count() != 0 {
            tokio::time::sleep(Duration::from_millis(1)).await;
        }
        pair.client.send_datagram(raw_datagram(0, b"late")).unwrap();
        wait_drops(server, |drops| drops.unknown_stream == 1).await;
    }

    /// A datagram held for a stream that never comes, which the close drops.
    async fn hold_one(pair: &Pair, server: &ServerConnection<QuicConnection>) {
        pair.client
            .send_datagram(raw_datagram(40, b"early"))
            .unwrap();
        wait_pending(server, 1).await;
    }

    /// Drops are recorded once when the driver ends, after the close counted the held one;
    /// what a retained handle discards later is not, and its release records nothing again.
    #[tokio::test]
    async fn datagram_drops_are_recorded_once_when_the_connection_ends() {
        let collector = Collector::new();
        tokio::time::timeout(LIMIT, async {
            let pair = Pair::in_memory(None, None).await;
            let mut config = server_config(Some(DatagramConfig::default()));
            config.metrics = Some(collector.metrics.clone());
            let (mut client, mut server) = start(&pair, config).await;
            release_first(&pair, &mut client, &mut server).await;

            // A tunnel whose carrier handle outlives the connection, with a datagram unread.
            let (mut client_session, server_session) = sessions(&mut client, &mut server).await;
            native_ready(&client_session).await;
            let retained = server_session.native().unwrap().clone();
            client_session
                .send_datagram(Bytes::from_static(b"unread"))
                .await
                .unwrap();
            while server.shared().datagram_demux().buffered() == 0 {
                tokio::time::sleep(Duration::from_millis(1)).await;
            }
            hold_one(&pair, &server).await;
            assert!(
                collector.dropped().is_empty(),
                "nothing recorded while it runs"
            );

            pair.close().await;
            assert_eq!(collector.recorded().await, expected());

            // The retained handle goes and discards its unread datagram: counted by the
            // connection, not recorded again.
            drop((client_session, server_session, retained));
            wait_drops(&server, |drops| drops.receive_closed == 2).await;
            assert_eq!(collector.dropped(), expected());
            drop((client, server));
            assert_eq!(collector.dropped(), expected());
        })
        .await
        .unwrap();
    }

    /// A cancelled driver never drains: the record follows the close its drop makes.
    #[tokio::test]
    async fn a_cancelled_driver_records_after_its_close() {
        let collector = Collector::new();
        tokio::time::timeout(LIMIT, async {
            let pair = Pair::in_memory(None, None).await;
            let mut config = server_config(Some(DatagramConfig::default()));
            config.metrics = Some(collector.metrics.clone());
            let (mut client, client_driver) = client::handshake::<Body, _>(
                pair.client.clone(),
                Config::default(),
                Executor::new(),
            )
            .unwrap();
            let (mut server, server_driver) =
                server::handshake(pair.server.clone(), config).unwrap();
            spawn(client_driver.run());
            let driver = spawn(server_driver.run());
            release_first(&pair, &mut client, &mut server).await;
            hold_one(&pair, &server).await;
            assert!(collector.dropped().is_empty());

            driver.abort();
            assert!(driver.await.unwrap_err().is_cancelled());
            assert_eq!(collector.recorded().await, expected());
            drop((client, server));
            pair.close().await;
            assert_eq!(collector.dropped(), expected());
        })
        .await
        .unwrap();
    }
}
