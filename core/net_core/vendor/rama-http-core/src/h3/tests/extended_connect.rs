//! Extended CONNECT negotiation (RFC 9220, RFC 8441 §3–§4) over real QUIC connections.

use super::{LIMIT, Pair};
use crate::h3::{
    client,
    connection::{Config, initial_control},
    control::Role,
    qpack::{Encoder, EncoderConfig},
    server,
};
use rama_core::{
    bytes::{Bytes, BytesMut},
    extensions::ExtensionsRef as _,
    futures::{FutureExt as _, stream},
    rt::{Executor, spawn},
};
use rama_http::{
    datagram::{
        ViolationPolicy,
        handshake::{CapsuleHandshakeError, prepare_capsule_request, validate_capsule_response},
    },
    io::upgrade::{OnMalformedMessage, handle_upgrade},
};
use rama_http_types::{
    Body, Method, Request, Response, StatusCode, Version,
    body::{StreamingBody as _, util::BodyExt as _},
    header,
    proto::{
        ext::Protocol,
        h3::{Code, FrameHeader, FrameType, PseudoHeader, PseudoHeaderOrder, SettingId, Settings},
    },
};
use rama_net::uri::Uri;
use std::{
    convert::Infallible,
    sync::{
        Arc,
        atomic::{AtomicUsize, Ordering},
    },
};
use tokio::io::{AsyncReadExt as _, AsyncWriteExt as _};

fn extended_connect_server() -> Config {
    Config {
        extended_connect: true,
        ..Config::default()
    }
}

fn client_connect_advertisement(value: u64) -> Config {
    let mut settings = Settings::new();
    settings
        .set(SettingId::ENABLE_CONNECT_PROTOCOL, value)
        .unwrap();
    settings.set(SettingId::H3_DATAGRAM, 1).unwrap();
    Config::default()
        .try_with_client_settings(Arc::new(settings))
        .unwrap()
}

fn extended_connect(uri: &str, protocol: Protocol) -> Request<Body> {
    let request = Request::builder()
        .method(Method::CONNECT)
        .uri(uri)
        .header("x-app", "kept")
        .body(Body::empty())
        .unwrap();
    request.extensions().insert(protocol);
    request
}

#[tokio::test]
async fn custom_token_round_trip_exposes_tunnel_after_success() {
    tokio::time::timeout(LIMIT, async {
        let pair = Pair::new(None, None).await;
        let (mut client, client_driver) = client::handshake::<Body, _>(
            pair.client.clone(),
            client_connect_advertisement(0),
            Executor::new(),
        )
        .unwrap();
        let (mut server, server_driver) =
            server::handshake(pair.server.clone(), extended_connect_server()).unwrap();
        spawn(client_driver.run());
        spawn(server_driver.run());
        let serve = spawn(async move {
            let (request, response) = server.accept().await.unwrap().resolve().await.unwrap();
            assert_eq!(request.method(), Method::CONNECT);
            assert_eq!(
                request.extensions().get_ref::<Protocol>(),
                Some(&Protocol::from_static("x-custom.v1"))
            );
            assert_eq!(request.uri().to_string(), "https://localhost/chat?room=1");
            assert_eq!(request.headers()["x-app"], "kept");
            let order: Vec<_> = request
                .extensions()
                .get_ref::<PseudoHeaderOrder>()
                .unwrap()
                .iter()
                .collect();
            assert!(order.contains(&PseudoHeader::Protocol), "{order:?}");
            let upgrade = handle_upgrade(&request);
            response
                .send_response(Response::new(Body::empty()))
                .await
                .unwrap();
            let mut tunnel = upgrade.await.unwrap();
            let mut received = [0; 4];
            tunnel.read_exact(&mut received).await.unwrap();
            assert_eq!(&received, b"ping");
            tunnel.write_all(b"pong").await.unwrap();
            tunnel.shutdown().await.unwrap();
            let mut rest = Vec::new();
            tunnel.read_to_end(&mut rest).await.unwrap();
            assert!(rest.is_empty());
        });
        let response = client
            .send_request(extended_connect(
                "https://localhost/chat?room=1",
                Protocol::from_static("x-custom.v1"),
            ))
            .await
            .unwrap();
        assert_eq!(response.status(), StatusCode::OK);
        let mut tunnel = handle_upgrade(&response).await.unwrap();
        tunnel.write_all(b"ping").await.unwrap();
        tunnel.flush().await.unwrap();
        let mut received = Vec::new();
        tunnel.read_to_end(&mut received).await.unwrap();
        assert_eq!(received, b"pong");
        tunnel.shutdown().await.unwrap();
        serve.await.unwrap();
        pair.close().await;
    })
    .await
    .unwrap();
}

#[tokio::test]
async fn an_upgraded_tunnel_keeps_the_connection_in_use_until_it_ends() {
    tokio::time::timeout(LIMIT, async {
        let pair = Pair::in_memory(None, None).await;
        let (mut client, client_driver) =
            client::handshake::<Body, _>(pair.client.clone(), Config::default(), Executor::new())
                .unwrap();
        let (mut server, server_driver) =
            server::handshake(pair.server.clone(), extended_connect_server()).unwrap();
        spawn(client_driver.run());
        spawn(server_driver.run());
        let serve = spawn(async move {
            let (request, response) = server.accept().await.unwrap().resolve().await.unwrap();
            let upgrade = handle_upgrade(&request);
            response
                .send_response(Response::new(Body::empty()))
                .await
                .unwrap();
            let mut tunnel = upgrade.await.unwrap();
            let mut rest = Vec::new();
            tunnel.read_to_end(&mut rest).await.unwrap();
            tunnel.shutdown().await.unwrap();
        });
        let admission = client.connection_admission();
        assert!(!admission.in_use());
        let response = client
            .send_request(extended_connect(
                "https://localhost/chat",
                Protocol::from_static("x-custom.v1"),
            ))
            .await
            .unwrap();
        assert_eq!(response.status(), StatusCode::OK);
        let mut tunnel = handle_upgrade(&response).await.unwrap();
        drop(response);
        assert!(admission.in_use(), "the tunnel outlives its response");

        tunnel.shutdown().await.unwrap();
        let mut rest = Vec::new();
        tunnel.read_to_end(&mut rest).await.unwrap();
        drop(tunnel);
        loop {
            let changed = admission.changed();
            if !admission.in_use() {
                break;
            }
            changed.await;
        }
        serve.await.unwrap();
        pair.close().await;
    })
    .await
    .unwrap();
}

/// As on HTTP/2, a CONNECT body is never sent: one that announces nothing, such as an empty
/// body being recorded, still opens the tunnel, and one that announces content is refused.
#[tokio::test]
async fn connect_sends_no_body_and_refuses_one_announcing_content() {
    tokio::time::timeout(LIMIT, async {
        let pair = Pair::in_memory(None, None).await;
        let (mut client, client_driver) =
            client::handshake::<Body, _>(pair.client.clone(), Config::default(), Executor::new())
                .unwrap();
        let (mut server, server_driver) =
            server::handshake(pair.server.clone(), extended_connect_server()).unwrap();
        spawn(client_driver.run());
        spawn(server_driver.run());
        spawn(async move {
            while let Ok(stream) = server.accept().await {
                if let Ok((request, response)) = stream.resolve().await {
                    let upgrade = handle_upgrade(&request);
                    _ = response.send_response(Response::new(Body::empty())).await;
                    if let Ok(mut tunnel) = upgrade.await {
                        let mut rest = Vec::new();
                        _ = tunnel.read_to_end(&mut rest).await;
                    }
                }
            }
        });

        let mut request = extended_connect(
            "https://localhost/chat",
            Protocol::from_static("x-custom.v1"),
        );
        *request.body_mut() = Body::from_stream(stream::empty::<Result<Bytes, Infallible>>());
        assert!(!request.body().is_end_stream());
        let response = client.send_request(request).await.unwrap();
        assert_eq!(response.status(), StatusCode::OK);
        let mut tunnel = handle_upgrade(&response).await.unwrap();
        tunnel.shutdown().await.unwrap();
        // As on HTTP/2, a shut-down tunnel takes no more writes.
        assert_eq!(
            tunnel.write(b"late").await.unwrap_err().kind(),
            std::io::ErrorKind::BrokenPipe
        );

        let mut request = extended_connect(
            "https://localhost/chat",
            Protocol::from_static("x-custom.v1"),
        );
        *request.body_mut() = Body::from("tunnel data");
        let error = client.send_request(request).await.unwrap_err();
        assert_eq!(error.code(), Code::H3_MESSAGE_ERROR);
        pair.close().await;
    })
    .await
    .unwrap();
}

#[tokio::test]
async fn refused_without_server_setting_and_opens_no_stream() {
    tokio::time::timeout(LIMIT, async {
        let pair = Pair::in_memory(None, None).await;
        let (mut client, client_driver) = client::handshake::<Body, _>(
            pair.client.clone(),
            client_connect_advertisement(1),
            Executor::new(),
        )
        .unwrap();
        let (mut server, server_driver) =
            server::handshake(pair.server.clone(), Config::default()).unwrap();
        spawn(client_driver.run());
        spawn(server_driver.run());
        // Any request that does reach the server is answered, so a missing local gate fails
        // on the assertions below instead of waiting for the watchdog.
        let accepted = Arc::new(AtomicUsize::new(0));
        spawn({
            let accepted = accepted.clone();
            async move {
                while let Ok(stream) = server.accept().await {
                    accepted.fetch_add(1, Ordering::SeqCst);
                    if let Ok((_request, response)) = stream.resolve().await {
                        let mut refused = Response::new(Body::empty());
                        *refused.status_mut() = StatusCode::BAD_REQUEST;
                        _ = response.send_response(refused).await;
                    }
                }
            }
        });
        for _ in 0..3 {
            let error = client
                .send_request(extended_connect(
                    "https://localhost/chat",
                    Protocol::WEBSOCKET,
                ))
                .await
                .map(|response| response.status())
                .unwrap_err();
            assert_eq!(error.code(), Code::H3_MESSAGE_ERROR);
        }
        // Refused requests must not consume even one stream ID.
        let (send, recv) = pair.client.open_bi().await.unwrap();
        assert_eq!(u64::from(send.id()), 0);
        assert_eq!(accepted.load(Ordering::SeqCst), 0);
        drop((send, recv, client));
        pair.close().await;
    })
    .await
    .unwrap();
}

#[tokio::test]
async fn protocol_on_other_methods_fails_locally_without_a_stream() {
    tokio::time::timeout(LIMIT, async {
        let pair = Pair::in_memory(None, None).await;
        let (mut client, driver) =
            client::handshake::<Body, _>(pair.client.clone(), Config::default(), Executor::new())
                .unwrap();
        let request = Request::builder()
            .uri("https://localhost/chat")
            .body(Body::empty())
            .unwrap();
        request.extensions().insert(Protocol::WEBSOCKET);
        let error = client
            .send_request(request)
            .now_or_never()
            .expect("local validation needs no peer traffic")
            .unwrap_err();
        assert_eq!(error.code(), Code::H3_MESSAGE_ERROR);
        let (send, recv) = pair.client.open_bi().await.unwrap();
        assert_eq!(u64::from(send.id()), 0);
        drop((send, recv, client, driver));
        pair.close().await;
    })
    .await
    .unwrap();
}

#[tokio::test]
async fn client_waits_for_late_settings_before_opening_a_stream() {
    tokio::time::timeout(LIMIT, async {
        let pair = Pair::new(None, None).await;
        let (mut client, client_driver) = client::handshake::<Body, _>(
            pair.client.clone(),
            client_connect_advertisement(1),
            Executor::new(),
        )
        .unwrap();
        let (mut server, server_driver) =
            server::handshake(pair.server.clone(), extended_connect_server()).unwrap();
        spawn(client_driver.run());
        let mut request = spawn(async move {
            let response = client
                .send_request(extended_connect(
                    "https://localhost/late",
                    Protocol::WEBSOCKET,
                ))
                .await
                .unwrap();
            (client, response)
        });
        // Without the server's control stream no request stream may be opened.
        tokio::task::yield_now().await;
        assert!((&mut request).now_or_never().is_none());
        assert!(pair.server.accept_bi().now_or_never().is_none());
        spawn(server_driver.run());
        let (accepted, response) = server.accept().await.unwrap().resolve().await.unwrap();
        assert_eq!(accepted.uri().request_target(), "/late");
        response
            .send_response(Response::new(Body::empty()))
            .await
            .unwrap();
        let (_client, response) = request.await.unwrap();
        assert_eq!(response.status(), StatusCode::OK);
        pair.close().await;
    })
    .await
    .unwrap();
}

#[tokio::test]
async fn a_connection_lost_before_settings_fails_the_waiting_request() {
    tokio::time::timeout(LIMIT, async {
        let pair = Pair::new(None, None).await;
        let (mut client, client_driver) =
            client::handshake::<Body, _>(pair.client.clone(), Config::default(), Executor::new())
                .unwrap();
        spawn(client_driver.run());
        let mut request = spawn(async move {
            client
                .send_request(extended_connect(
                    "https://localhost/never",
                    Protocol::WEBSOCKET,
                ))
                .await
        });
        tokio::task::yield_now().await;
        assert!((&mut request).now_or_never().is_none());
        // The server never sends SETTINGS; its connection closes instead.
        pair.server.close(0x100u32, b"no settings");
        request.await.unwrap().unwrap_err();
        pair.server
            .accept_bi()
            .await
            .expect_err("no stream was opened");
        pair.close().await;
    })
    .await
    .unwrap();
}

#[tokio::test]
async fn unsuccessful_response_keeps_its_body_and_offers_no_tunnel() {
    tokio::time::timeout(LIMIT, async {
        let pair = Pair::new(None, None).await;
        let (mut client, client_driver) =
            client::handshake::<Body, _>(pair.client.clone(), Config::default(), Executor::new())
                .unwrap();
        let (mut server, server_driver) =
            server::handshake(pair.server.clone(), extended_connect_server()).unwrap();
        spawn(client_driver.run());
        spawn(server_driver.run());
        let serve = spawn(async move {
            for _ in 0..2 {
                let (_request, response) = server.accept().await.unwrap().resolve().await.unwrap();
                response
                    .send_response(
                        Response::builder()
                            .status(StatusCode::NOT_IMPLEMENTED)
                            .body(Body::from("unsupported protocol"))
                            .unwrap(),
                    )
                    .await
                    .unwrap();
            }
            server
        });
        // A second request proves the refused stream released its admission.
        for _ in 0..2 {
            let response = client
                .send_request(extended_connect(
                    "https://localhost/",
                    Protocol::from_static("unknown"),
                ))
                .await
                .unwrap();
            assert_eq!(response.status(), StatusCode::NOT_IMPLEMENTED);
            handle_upgrade(&response).await.unwrap_err();
            assert_eq!(
                response.into_body().collect().await.unwrap().to_bytes(),
                "unsupported protocol"
            );
        }
        drop(serve.await.unwrap());
        pair.close().await;
    })
    .await
    .unwrap();
}

/// RFC 9114 §4.1: a server that completed its side stops reading with H3_NO_ERROR, for
/// Extended CONNECT and ordinary CONNECT tunnels alike.
#[tokio::test]
async fn servers_stop_reading_finished_tunnels_without_error() {
    let extended = [
        (":method", "CONNECT"),
        (":protocol", "websocket"),
        (":scheme", "https"),
        (":authority", "localhost"),
        (":path", "/chat"),
    ];
    let ordinary = [(":method", "CONNECT"), (":authority", "localhost:443")];
    tokio::time::timeout(LIMIT, async {
        let pair = Pair::in_memory(None, None).await;
        let (mut server, server_driver) =
            server::handshake(pair.server.clone(), extended_connect_server()).unwrap();
        spawn(server_driver.run());
        for (head, finish, expected) in [
            (&extended[..], true, Code::H3_NO_ERROR),
            (&extended[..], false, Code::H3_REQUEST_CANCELLED),
            (&ordinary[..], true, Code::H3_NO_ERROR),
            (&ordinary[..], false, Code::H3_REQUEST_CANCELLED),
        ] {
            // A raw client that never ends its own direction.
            let (mut send, _recv) = pair.client.open_bi().await.unwrap();
            let fields = Encoder::before_peer_settings(EncoderConfig::default())
                .encode(u64::from(send.id()), head.iter().copied())
                .unwrap();
            let mut frame = BytesMut::new();
            FrameHeader::new(FrameType::HEADERS, fields.len() as u64)
                .encode(&mut frame)
                .unwrap();
            frame.extend_from_slice(&fields);
            send.write_chunk(frame.freeze()).await.unwrap();
            let (request, response) = server.accept().await.unwrap().resolve().await.unwrap();
            let upgrade = handle_upgrade(&request);
            response
                .send_response(Response::new(Body::empty()))
                .await
                .unwrap();
            let mut tunnel = upgrade.await.unwrap();
            if finish {
                tunnel.write_all(b"done").await.unwrap();
                tunnel.shutdown().await.unwrap();
            }
            drop(tunnel);
            assert_eq!(
                send.stopped().await.unwrap().map(u64::from),
                Some(expected.value()),
                "{head:?} finish {finish}"
            );
        }
        pair.close().await;
    })
    .await
    .unwrap();
}

#[tokio::test]
async fn server_treats_unadvertised_protocol_as_malformed() {
    tokio::time::timeout(LIMIT, async {
        let pair = Pair::in_memory(None, None).await;
        let (mut server, server_driver) =
            server::handshake(pair.server.clone(), Config::default()).unwrap();
        spawn(server_driver.run());
        // Receive the client's literal advertisement first. It must not enable
        // this server's Extended CONNECT parser or change its own capability.
        let client_config = client_connect_advertisement(1);
        let mut control = pair.client.open_uni().await.unwrap();
        control
            .write_chunk(initial_control(&client_config, Role::Client, true).unwrap())
            .await
            .unwrap();
        assert_eq!(
            server
                .peer_settings()
                .await
                .unwrap()
                .get(SettingId::ENABLE_CONNECT_PROTOCOL),
            Some(1)
        );
        let (mut send, _recv) = pair.client.open_bi().await.unwrap();
        let id = u64::from(send.id());
        let fields = Encoder::before_peer_settings(EncoderConfig::default())
            .encode(
                id,
                [
                    (":method", "CONNECT"),
                    (":protocol", "websocket"),
                    (":scheme", "https"),
                    (":authority", "localhost"),
                    (":path", "/chat"),
                ],
            )
            .unwrap();
        let mut frame = BytesMut::new();
        FrameHeader::new(FrameType::HEADERS, fields.len() as u64)
            .encode(&mut frame)
            .unwrap();
        frame.extend_from_slice(&fields);
        send.write_chunk(frame.freeze()).await.unwrap();
        let error = server
            .accept()
            .await
            .unwrap()
            .resolve()
            .await
            .map(|_| ())
            .unwrap_err();
        assert_eq!(error.code(), Code::H3_MESSAGE_ERROR);
        assert_eq!(
            send.stopped().await.unwrap().map(u64::from),
            Some(Code::H3_MESSAGE_ERROR.value())
        );
        pair.close().await;
    })
    .await
    .unwrap();
}

/// RFC 9297 §3.2: Capsule messages must not carry Content-Length; a successful CONNECT keeps
/// the received field visible (ignored for framing, RFC 9110 §9.3.6) so validation rejects it.
#[tokio::test]
async fn capsule_validation_sees_content_length_on_successful_connect() {
    tokio::time::timeout(LIMIT, async {
        let pair = Pair::in_memory(None, None).await;
        let (mut client, client_driver) =
            client::handshake::<Body, _>(pair.client.clone(), Config::default(), Executor::new())
                .unwrap();
        // The server engine only supplies SETTINGS; its request streams are answered raw.
        let (_server, server_driver) =
            server::handshake(pair.server.clone(), extended_connect_server()).unwrap();
        spawn(client_driver.run());
        spawn(server_driver.run());
        let token = Protocol::from_static("x-capsule");
        let lengths: [&[&str]; 5] = [&["0"], &["5"], &["invalid"], &["0", "0"], &[]];
        for values in lengths {
            let mut request = Request::builder()
                .version(Version::HTTP_3)
                .uri("https://localhost/capsules")
                .body(Body::empty())
                .unwrap();
            prepare_capsule_request(&mut request, token.clone()).unwrap();
            let serve = async {
                let (mut send, mut recv) = pair.server.accept_bi().await.unwrap();
                let id = u64::from(send.id());
                // Consume the request HEADERS frame before answering.
                recv.read_chunk(usize::MAX, true).await.unwrap().unwrap();
                let mut fields = vec![(":status", "200"), ("capsule-protocol", "?1")];
                fields.extend(values.iter().map(|value| ("content-length", *value)));
                let encoded = Encoder::before_peer_settings(EncoderConfig::default())
                    .encode(id, fields)
                    .unwrap();
                let mut frame = BytesMut::new();
                FrameHeader::new(FrameType::HEADERS, encoded.len() as u64)
                    .encode(&mut frame)
                    .unwrap();
                frame.extend_from_slice(&encoded);
                send.write_chunk(frame.freeze()).await.unwrap();
                (send, recv)
            };
            let (response, (send, _recv)) = tokio::join!(client.send_request(request), serve);
            let response = response.unwrap();
            assert_eq!(response.status(), StatusCode::OK);
            let result = validate_capsule_response(
                Version::HTTP_3,
                &token,
                &response,
                ViolationPolicy::Reject,
            );
            let tunnel = handle_upgrade(&response).await.unwrap();
            if values.is_empty() {
                result.unwrap();
                continue;
            }
            assert_eq!(
                result,
                Err(CapsuleHandshakeError::ForbiddenField(
                    header::CONTENT_LENGTH
                )),
                "{values:?}"
            );
            // The malformed message resets only its own stream.
            tunnel
                .extensions()
                .get_ref::<OnMalformedMessage>()
                .unwrap()
                .call();
            assert_eq!(
                send.stopped().await.unwrap().map(u64::from),
                Some(Code::H3_MESSAGE_ERROR.value()),
                "{values:?}"
            );
        }
        pair.close().await;
    })
    .await
    .unwrap();
}

/// RFC 9110 §9.3.6: any successful CONNECT, even `204` with Content-Length, is a tunnel.
#[tokio::test]
async fn ordinary_connect_tunnels_ignore_content_length_on_every_2xx() {
    tokio::time::timeout(LIMIT, async {
        let pair = Pair::in_memory(None, None).await;
        let (mut client, client_driver) =
            client::handshake::<Body, _>(pair.client.clone(), Config::default(), Executor::new())
                .unwrap();
        let (_server, server_driver) =
            server::handshake(pair.server.clone(), Config::default()).unwrap();
        spawn(client_driver.run());
        spawn(server_driver.run());
        for status in ["200", "204", "206"] {
            let request = Request::builder()
                .method(Method::CONNECT)
                .uri(Uri::parse_http_request_target("localhost:443", true).unwrap())
                .body(Body::empty())
                .unwrap();
            let serve = async {
                let (mut send, mut recv) = pair.server.accept_bi().await.unwrap();
                recv.read_chunk(usize::MAX, true).await.unwrap().unwrap();
                let encoded = Encoder::before_peer_settings(EncoderConfig::default())
                    .encode(
                        u64::from(send.id()),
                        [(":status", status), ("content-length", "0")],
                    )
                    .unwrap();
                let mut frame = BytesMut::new();
                FrameHeader::new(FrameType::HEADERS, encoded.len() as u64)
                    .encode(&mut frame)
                    .unwrap();
                frame.extend_from_slice(&encoded);
                // Tunnel bytes beyond the declared zero length.
                FrameHeader::new(FrameType::DATA, 1)
                    .encode(&mut frame)
                    .unwrap();
                frame.extend_from_slice(b"x");
                send.write_chunk(frame.freeze()).await.unwrap();
                (send, recv)
            };
            let (response, _streams) = tokio::join!(client.send_request(request), serve);
            let response =
                response.unwrap_or_else(|error| panic!("ordinary CONNECT {status}: {error:?}"));
            assert_eq!(response.headers()[header::CONTENT_LENGTH], "0");
            let mut tunnel = handle_upgrade(&response).await.unwrap();
            let mut byte = [0];
            tunnel.read_exact(&mut byte).await.unwrap();
            assert_eq!(&byte, b"x", "{status}");
        }
        pair.close().await;
    })
    .await
    .unwrap();
}
