//! Exercise admission recovery and independent streams across a real QUIC connection.

use super::{LIMIT, Pair};
use crate::h3::{
    Error, client,
    connection::{Config, Driver, Shared, initial_control},
    control::Role,
    qpack::{Encoder, EncoderConfig, ErrorScope},
    quic::Writer,
    server,
};
use rama_core::{
    bytes::{Bytes, BytesMut},
    futures::{FutureExt as _, stream},
    rt::{Executor, spawn},
};
use rama_http_types::{
    Body, HeaderMap, Method, Request, Response, StatusCode,
    body::{Frame, util::BodyExt},
    proto::h3::{Code, FrameHeader, FrameType, StreamType},
};
use rama_net::uri::Uri;
use rama_quic::TransportConfig;
use rama_quic_proto::{Dir, MAX_STREAM_COUNT, Side, StreamId, VarInt, coding::Codec};
use rama_utils::octets::kib;
use std::assert_matches;
use std::{
    convert::Infallible,
    error::Error as _,
    future::poll_fn,
    pin::pin,
    sync::{
        Arc,
        atomic::{AtomicUsize, Ordering},
    },
    task::Poll,
};
use tokio::sync::{Barrier, oneshot};

/// An empty body never announces a length it cannot deliver, as on HTTP/1 and HTTP/2.
#[tokio::test(start_paused = true)]
async fn an_empty_request_body_drops_a_positive_content_length() {
    tokio::time::timeout(LIMIT, async {
        let pair = Pair::in_memory(None, None).await;
        let (mut client, client_driver) =
            client::handshake::<Body, _>(pair.client.clone(), Config::default(), Executor::new())
                .unwrap();
        let (mut server, server_driver) =
            server::handshake(pair.server.clone(), Config::default()).unwrap();
        spawn(client_driver.run());
        spawn(server_driver.run());
        let serve = spawn(async move {
            let (request, response) = server.accept().await.unwrap().resolve().await.unwrap();
            assert!(!request.headers().contains_key("content-length"));
            response
                .send_response(Response::new(Body::empty()))
                .await
                .unwrap();
        });
        let request = Request::builder()
            .method(Method::POST)
            .uri("https://localhost/")
            .header("content-length", "5")
            .body(Body::empty())
            .unwrap();
        let response = client.send_request(request).await.unwrap();
        assert_eq!(response.status(), StatusCode::OK);
        serve.await.unwrap();
        pair.close().await;
    })
    .await
    .unwrap();
}

#[tokio::test(start_paused = true)]
async fn memory_goaway_prevents_new_headers_when_stream_credit_arrives_concurrently() {
    // RFC 9114 section 5.2 permits a first GOAWAY at the maximum request ID.
    // That still prohibits new requests whose IDs would fall below this limit.
    const WAITERS: u32 = 32;
    tokio::time::timeout(LIMIT, async {
        let mut transport = TransportConfig::default();
        Config::default()
            .configure_transport(&mut transport)
            .unwrap();
        transport.set_max_concurrent_bidi_streams(0u32);
        let pair = Pair::in_memory(None, Some(transport)).await;
        let (mut client, driver) =
            client::handshake::<Body, _>(pair.client.clone(), Config::default(), Executor::new())
                .unwrap();
        let driver = spawn(driver.run());
        client.ready().await.unwrap();
        let mut requests = Vec::with_capacity(WAITERS as usize);
        for _ in 0..WAITERS {
            let mut sender = client.clone();
            let mut request = Box::pin(async move {
                sender
                    .send_request(
                        Request::builder()
                            .method(Method::POST)
                            .uri("https://localhost/stop-before-headers")
                            .body(Body::empty())
                            .unwrap(),
                    )
                    .await
            });
            assert!(poll_fn(|cx| Poll::Ready(request.as_mut().poll(cx).is_pending())).await);
            requests.push(request);
        }
        let mut control = pair.server.open_uni().await.unwrap();
        control
            .write_all(&initial_control(&Config::default(), Role::Client, false).unwrap())
            .await
            .unwrap();
        let limit = VarInt::from_u64(u64::from(StreamId::new(
            Side::Client,
            Dir::Bi,
            MAX_STREAM_COUNT - 1,
        )))
        .unwrap();
        let mut bytes = BytesMut::new();
        FrameHeader::new(FrameType::GOAWAY, limit.size() as u64)
            .encode(&mut bytes)
            .unwrap();
        limit.encode(&mut bytes);
        control.write_all(&bytes).await.unwrap();
        _ = client.closed_or_draining().await;

        // Make both cancellation and opening ready before repolling the pending
        // requests. The unused probe confirms receipt of the new MAX_STREAMS.
        pair.server.set_max_concurrent_bi_streams(WAITERS + 1);
        let _probe = pair.client.open_bi().await.unwrap();
        for mut request in requests {
            let result = poll_fn(|cx| Poll::Ready(request.as_mut().poll(cx))).await;
            let Poll::Ready(Err(error)) = result else {
                panic!(
                    "GOAWAY must reject before sending HEADERS, even with available stream credit"
                );
            };
            assert_eq!(error.code(), Code::H3_REQUEST_REJECTED);
        }
        pair.client.close(0u32, b"test complete");
        _ = driver.await.unwrap();
        pair.close().await;
    })
    .await
    .unwrap();
}

#[tokio::test(start_paused = true)]
async fn memory_goaway_releases_saturated_admission_and_preserves_active_response() {
    check_goaway_preserves_active_response(1).await;
}

#[tokio::test(start_paused = true)]
async fn memory_goaway_releases_stream_credit_waiter_and_preserves_active_response() {
    check_goaway_preserves_active_response(2).await;
}

async fn check_goaway_preserves_active_response(max_requests: usize) {
    // RFC 9114 section 5.2: stop opening requests after GOAWAY, while an
    // accepted request below its limit can still complete. Exercise the two
    // distinct waits before stream creation with the same one-stream peer.
    tokio::time::timeout(LIMIT, async {
        let mut transport = TransportConfig::default();
        Config::default()
            .configure_transport(&mut transport)
            .unwrap();
        transport.set_max_concurrent_bidi_streams(1u32);
        let pair = Pair::in_memory(None, Some(transport)).await;
        let (mut client, client_driver) = client::handshake::<Body, _>(
            pair.client.clone(),
            Config {
                max_requests,
                ..Config::default()
            },
            Executor::new(),
        )
        .unwrap();
        let (mut server, server_driver) =
            server::handshake(pair.server.clone(), Config::default()).unwrap();
        let client_driver = spawn(client_driver.run());
        let server_driver = spawn(server_driver.run());
        let accepted = spawn({
            let mut sender = client.clone();
            async move {
                sender
                    .send_request(
                        Request::builder()
                            .method(Method::POST)
                            .uri("https://localhost/accepted")
                            .body(Body::from("process once"))
                            .unwrap(),
                    )
                    .await
                    .unwrap()
            }
        });
        let (request, response) = server.accept().await.unwrap().resolve().await.unwrap();
        assert_eq!(request.method(), Method::POST);
        assert_eq!(
            request.into_body().collect().await.unwrap().to_bytes(),
            "process once"
        );
        let (release, wait) = oneshot::channel();
        let respond = spawn(async move {
            let body = Body::from_stream(stream::once(async move {
                wait.await.unwrap();
                Ok::<_, Infallible>(Bytes::from_static(b"completed after GOAWAY"))
            }));
            response.send_response(Response::new(body)).await.unwrap();
        });
        let active_response = accepted.await.unwrap();
        let body_polls = Arc::new(AtomicUsize::new(0));
        let request = || {
            let polls = body_polls.clone();
            Request::builder()
                .method(Method::POST)
                .uri("https://localhost/not-replayed")
                .body(Body::from_stream(stream::once(async move {
                    polls.fetch_add(1, Ordering::SeqCst);
                    Ok::<_, Infallible>(Bytes::from_static(b"side effect"))
                })))
                .unwrap()
        };
        {
            let mut blocked = pin!(client.send_request(request()));
            assert!(poll_fn(|cx| Poll::Ready(blocked.as_mut().poll(cx).is_pending())).await);
            server.shutdown().unwrap();
            let error = blocked.await.unwrap_err();
            assert_eq!(error.code(), Code::H3_REQUEST_REJECTED);
            assert_eq!(error.scope(), ErrorScope::Stream);
        }
        assert!(client.is_draining());
        assert!(!client.is_closed());
        assert_eq!(
            client.send_request(request()).await.unwrap_err().code(),
            Code::H3_REQUEST_REJECTED
        );
        assert_eq!(body_polls.load(Ordering::SeqCst), 0);

        // Keep the active stream's credit held until both rejections arrive.
        release.send(()).unwrap();
        assert_eq!(
            active_response
                .into_body()
                .collect()
                .await
                .unwrap()
                .to_bytes(),
            "completed after GOAWAY"
        );
        respond.await.unwrap();
        server.drained().await.unwrap();
        assert!(pair.server.accept_bi().now_or_never().is_none());
        assert_eq!(body_polls.load(Ordering::SeqCst), 0);
        assert!(pair.client.close_reason().is_none());
        pair.client.close(0u32, b"test complete");
        _ = client_driver.await.unwrap();
        _ = server_driver.await.unwrap();
        pair.close().await;
    })
    .await
    .unwrap();
}

#[tokio::test]
async fn malformed_control_streams_close_connection_and_wake_accept() {
    check_malformed_control_streams_close_connection_and_wake_accept(false).await;
}

#[tokio::test(start_paused = true)]
async fn memory_malformed_control_streams_close_connection_and_wake_accept() {
    check_malformed_control_streams_close_connection_and_wake_accept(true).await;
}

async fn check_malformed_control_streams_close_connection_and_wake_accept(in_memory: bool) {
    // RFC 9114 sections 6.2.1 and 7.2.4. Keep every sending stream open so
    // an unintended critical-stream FIN cannot mask the actual protocol error.
    let cases: &[(&str, &[&[u8]], Code)] = &[
        (
            "GOAWAY before SETTINGS",
            &[&[0, 7, 1, 0]],
            Code::H3_MISSING_SETTINGS,
        ),
        (
            "truncated setting integer",
            &[&[0, 4, 1, 0x40]],
            Code::H3_FRAME_ERROR,
        ),
        (
            "duplicate SETTINGS",
            &[&[0, 4, 0, 4, 0]],
            Code::H3_FRAME_UNEXPECTED,
        ),
        (
            "HTTP/2 reserved setting",
            &[&[0, 4, 2, 2, 0]],
            Code::H3_SETTINGS_ERROR,
        ),
        (
            "duplicate control stream",
            &[&[0, 4, 0], &[0, 4, 0]],
            Code::H3_STREAM_CREATION_ERROR,
        ),
        (
            "MAX_PUSH_ID decreased",
            &[&[0, 4, 0, 0x0d, 1, 5, 0x0d, 1, 3]],
            Code::H3_ID_ERROR,
        ),
        (
            "CANCEL_PUSH longer than one varint",
            &[&[0, 4, 0, 3, 9, 0, 0, 0, 0, 0, 0, 0, 0, 0]],
            Code::H3_FRAME_ERROR,
        ),
        (
            "GOAWAY without its identifier",
            &[&[0, 4, 0, 7, 0]],
            Code::H3_FRAME_ERROR,
        ),
        (
            "PRIORITY_UPDATE for a push never promised",
            &[&[0, 4, 0, 0x80, 0x0f, 0x07, 0x01, 4, 0, b'u', b'=', b'1']],
            Code::H3_ID_ERROR,
        ),
    ];
    for &(scenario, streams, expected) in cases {
        tokio::time::timeout(LIMIT, async {
            let pair = pair(None, None, in_memory).await;
            let (mut server, driver) =
                server::handshake(pair.server.clone(), Config::default()).unwrap();
            let driver = spawn(driver.run());
            let accept = spawn(async move { server.accept().await.err().unwrap() });
            let mut retained = Vec::new();
            for &bytes in streams {
                let mut send = pair.client.open_uni().await.unwrap();
                send.write_all(bytes).await.unwrap();
                retained.push(send);
            }
            assert_eq!(
                driver.await.unwrap().unwrap_err().code(),
                expected,
                "{scenario}"
            );
            assert!(pair.server.close_reason().is_some(), "{scenario}");
            // The public accept API must not remain asleep after the driver fails.
            _ = accept.await.unwrap();
            pair.close().await;
        })
        .await
        .unwrap_or_else(|error| panic!("{scenario}: {error}"));
    }
}

#[tokio::test]
async fn malformed_request_streams_leave_connection_and_admission_usable() {
    check_malformed_request_streams_leave_connection_and_admission_usable(false).await;
}

#[tokio::test(start_paused = true)]
async fn memory_malformed_request_streams_leave_connection_and_admission_usable() {
    check_malformed_request_streams_leave_connection_and_admission_usable(true).await;
}

async fn check_malformed_request_streams_leave_connection_and_admission_usable(in_memory: bool) {
    tokio::time::timeout(LIMIT, async {
        let pair = pair(None, None, in_memory).await;
        let config = Config {
            max_requests: 1,
            ..Config::default()
        };
        let (mut client, client_driver) =
            client::handshake::<Body, _>(pair.client.clone(), config.clone(), Executor::new())
                .unwrap();
        let (mut server, server_driver) = server::handshake(pair.server.clone(), config).unwrap();
        let client_driver = spawn(client_driver.run());
        let server_driver = spawn(server_driver.run());
        let mut encoder = Encoder::before_peer_settings(EncoderConfig::default());
        // RFC 9114 sections 4.1.2, 4.2 and 4.3: malformed HTTP messages
        // invalidate their own stream, not unrelated requests on the connection.
        let malformed: &[(&[u8], &[u8])] = &[
            (b"Uppercase", b"value"),
            (b"connection", b"close"),
            (b":method", b"GET"),
            (b"content-length", b"not-a-number"),
            (b"x-whitespace", b" leading-space"),
        ];
        for &(name, value) in malformed {
            let (send, mut recv) = pair.client.open_bi().await.unwrap();
            let id = u64::from(send.id());
            let fields = [
                (b":method".as_slice(), b"GET".as_slice()),
                (b":scheme".as_slice(), b"https".as_slice()),
                (b":authority".as_slice(), b"localhost".as_slice()),
                (b":path".as_slice(), b"/".as_slice()),
                (name, value),
            ];
            let mut writer = Writer::new(send);
            writer
                .queue(FrameType::HEADERS, encoder.encode(id, fields).unwrap())
                .unwrap();
            std::future::poll_fn(|cx| writer.poll_finish(cx))
                .await
                .unwrap();
            let error = server
                .accept()
                .await
                .unwrap()
                .resolve()
                .await
                .err()
                .unwrap();
            assert_eq!(error.code(), Code::H3_MESSAGE_ERROR, "field {name:?}");
            assert_eq!(error.scope(), ErrorScope::Stream);
            assert!(pair.server.close_reason().is_none());
            let error = recv.read_chunk(1024, true).await.unwrap_err();
            assert_matches!(
                error,
                rama_quic::ReadError::Reset(code)
                    if code.into_inner() == Code::H3_MESSAGE_ERROR.value(),
            );
        }
        let serve = spawn(async move {
            let (request, response) = server.accept().await.unwrap().resolve().await.unwrap();
            request.into_body().collect().await.unwrap();
            response
                .send_response(Response::new(Body::from("still usable")))
                .await
                .unwrap();
        });
        let response = client
            .send_request(
                Request::builder()
                    .uri("https://localhost/valid")
                    .body(Body::empty())
                    .unwrap(),
            )
            .await
            .unwrap();
        assert_eq!(
            response.into_body().collect().await.unwrap().to_bytes(),
            "still usable"
        );
        serve.await.unwrap();
        pair.client.close(0u32, b"test complete");
        _ = client_driver.await.unwrap();
        _ = server_driver.await.unwrap();
        pair.close().await;
    })
    .await
    .unwrap();
}

#[tokio::test]
async fn cancelled_idle_response_releases_single_admission_slot() {
    check_cancelled_idle_response_releases_single_admission_slot(false).await;
}

#[tokio::test(start_paused = true)]
async fn memory_cancelled_idle_response_releases_single_admission_slot() {
    check_cancelled_idle_response_releases_single_admission_slot(true).await;
}

async fn check_cancelled_idle_response_releases_single_admission_slot(in_memory: bool) {
    tokio::time::timeout(LIMIT, async {
        let pair = pair(None, None, in_memory).await;
        let config = Config {
            max_requests: 1,
            ..Config::default()
        };
        let (mut client, client_driver) =
            client::handshake::<Body, _>(pair.client.clone(), config.clone(), Executor::new())
                .unwrap();
        let (mut server, server_driver) = server::handshake(pair.server.clone(), config).unwrap();
        let client_driver = spawn(client_driver.run());
        let server_driver = spawn(server_driver.run());
        let serve = spawn(async move {
            // Repeated cancellation must release both sides' sole admission permit.
            for _ in 0..16 {
                let (request, response) = server.accept().await.unwrap().resolve().await.unwrap();
                request.into_body().collect().await.unwrap();
                let body = Body::from_stream(rama_core::futures::stream::pending::<
                    Result<Bytes, Infallible>,
                >());
                let error = response
                    .send_response(Response::new(body))
                    .await
                    .unwrap_err();
                assert_eq!(error.code(), Code::H3_REQUEST_CANCELLED);
            }
            let (request, response) = server.accept().await.unwrap().resolve().await.unwrap();
            request.into_body().collect().await.unwrap();
            response
                .send_response(Response::new(Body::from("recovered")))
                .await
                .unwrap();
        });
        for _ in 0..16 {
            let response = client
                .send_request(
                    Request::builder()
                        .uri("https://localhost/cancel")
                        .body(Body::empty())
                        .unwrap(),
                )
                .await
                .unwrap();
            drop(response);
        }
        let response = client
            .send_request(
                Request::builder()
                    .uri("https://localhost/recovered")
                    .body(Body::empty())
                    .unwrap(),
            )
            .await
            .unwrap();
        assert_eq!(
            response.into_body().collect().await.unwrap().to_bytes(),
            "recovered"
        );
        serve.await.unwrap();
        assert!(pair.client.close_reason().is_none());
        pair.client.close(0u32, b"test complete");
        _ = client_driver.await.unwrap();
        _ = server_driver.await.unwrap();
        pair.close().await;
    })
    .await
    .unwrap();
}

#[tokio::test]
async fn concurrent_stream_waves_recover_admission_and_flow_control_credit() {
    check_concurrent_stream_waves_recover_admission_and_flow_control_credit(false).await;
}

#[tokio::test(start_paused = true)]
async fn memory_concurrent_stream_waves_recover_admission_and_flow_control_credit() {
    check_concurrent_stream_waves_recover_admission_and_flow_control_credit(true).await;
}

async fn check_concurrent_stream_waves_recover_admission_and_flow_control_credit(in_memory: bool) {
    const CONCURRENT: usize = 8;
    const WAVES: usize = 16;
    tokio::time::timeout(LIMIT, async {
        let config = Config {
            max_requests: CONCURRENT,
            ..Config::default()
        };
        let transport = || {
            let mut transport = rama_quic::TransportConfig::default();
            config.configure_transport(&mut transport).unwrap();
            // Every body exceeds both stream and connection receive windows.
            transport.set_stream_receive_window(rama_utils::octets::kib(1) as u32);
            transport.set_receive_window(rama_utils::octets::kib(4) as u32);
            transport
        };
        let pair = pair(Some(transport()), Some(transport()), in_memory).await;
        let (client, client_driver) =
            client::handshake::<Body, _>(pair.client.clone(), config.clone(), Executor::new())
                .unwrap();
        let (mut server, server_driver) = server::handshake(pair.server.clone(), config).unwrap();
        let client_driver = spawn(client_driver.run());
        let server_driver = spawn(server_driver.run());
        let serve = spawn(async move {
            for _ in 0..WAVES {
                let mut responses = tokio::task::JoinSet::new();
                for _ in 0..CONCURRENT {
                    let stream = server.accept().await.unwrap();
                    responses.spawn(async move {
                        let (request, response) = stream.resolve().await.unwrap();
                        let body = request.into_body().collect().await.unwrap().to_bytes();
                        response
                            .send_response(Response::new(Body::from(body)))
                            .await
                            .unwrap();
                    });
                }
                while let Some(result) = responses.join_next().await {
                    result.unwrap();
                }
            }
        });
        for wave in 0..WAVES {
            let barrier = Arc::new(Barrier::new(CONCURRENT));
            let mut requests = tokio::task::JoinSet::new();
            for stream in 0..CONCURRENT {
                let mut client = client.clone();
                let barrier = barrier.clone();
                requests.spawn(async move {
                    barrier.wait().await;
                    let payload = Bytes::from(vec![
                        (wave * CONCURRENT + stream) as u8;
                        rama_utils::octets::kib(8)
                    ]);
                    let response = client
                        .send_request(
                            Request::builder()
                                .method(Method::POST)
                                .uri("https://localhost/echo")
                                .body(Body::from(payload.clone()))
                                .unwrap(),
                        )
                        .await
                        .unwrap();
                    assert_eq!(
                        response.into_body().collect().await.unwrap().to_bytes(),
                        payload
                    );
                });
            }
            while let Some(result) = requests.join_next().await {
                result.unwrap();
            }
        }
        serve.await.unwrap();
        assert!(pair.client.close_reason().is_none());
        pair.client.close(0u32, b"test complete");
        _ = client_driver.await.unwrap();
        _ = server_driver.await.unwrap();
        pair.close().await;
    })
    .await
    .unwrap();
}

async fn pair(
    client: Option<rama_quic::TransportConfig>,
    server: Option<rama_quic::TransportConfig>,
    in_memory: bool,
) -> Pair {
    if in_memory {
        Pair::in_memory(client, server).await
    } else {
        Pair::new(client, server).await
    }
}

#[tokio::test(start_paused = true)]
async fn memory_reset_before_headers_does_not_fragment_priority_history() {
    const REQUESTS: usize = 300;
    tokio::time::timeout(LIMIT, async {
        let pair = Pair::in_memory(None, None).await;
        let (mut client, client_driver) =
            client::handshake::<Body, _>(pair.client.clone(), Config::default(), Executor::new())
                .unwrap();
        let (mut server, server_driver) =
            server::handshake(pair.server.clone(), Config::default()).unwrap();
        let client_driver = spawn(client_driver.run());
        let server_driver = spawn(server_driver.run());
        let serve = spawn(async move {
            for _ in 0..REQUESTS {
                let error = server
                    .accept()
                    .await
                    .unwrap()
                    .resolve()
                    .await
                    .err()
                    .unwrap();
                assert_eq!(error.scope(), ErrorScope::Stream);
                let (request, response) = server.accept().await.unwrap().resolve().await.unwrap();
                request.into_body().collect().await.unwrap();
                response
                    .send_response(Response::new(Body::from("ok")))
                    .await
                    .unwrap();
            }
        });
        for _ in 0..REQUESTS {
            let (mut send, mut recv) = pair.client.open_bi().await.unwrap();
            // A partial HEADERS frame followed by reset must release admission,
            // scheduling and compression bookkeeping just like a valid request.
            send.write_all(&[1]).await.unwrap();
            send.reset(Code::H3_REQUEST_CANCELLED.value() as u32)
                .unwrap();
            recv.stop(Code::H3_REQUEST_CANCELLED.value() as u32)
                .unwrap();
            let response = client
                .send_request(
                    Request::builder()
                        .uri("https://localhost/survivor")
                        .body(Body::empty())
                        .unwrap(),
                )
                .await
                .unwrap();
            assert_eq!(
                response.into_body().collect().await.unwrap().to_bytes(),
                "ok"
            );
            assert!(pair.client.close_reason().is_none());
        }
        serve.await.unwrap();
        pair.client
            .close(Code::H3_NO_ERROR.value() as u32, b"complete");
        client_driver.await.unwrap().unwrap();
        server_driver.await.unwrap().unwrap();
        pair.close().await;
    })
    .await
    .unwrap();
}

#[tokio::test(start_paused = true)]
async fn memory_clean_close_preserves_buffered_response_and_trailers() {
    tokio::time::timeout(LIMIT, async {
        let pair = Pair::in_memory(None, None).await;
        let (mut client, driver) =
            client::handshake::<Body, _>(pair.client.clone(), Config::default(), Executor::new())
                .unwrap();
        let driver = spawn(driver.run());
        client.ready().await.unwrap();
        let mut response = pin!(
            client.send_request(
                Request::builder()
                    .uri("https://localhost/buffered")
                    .body(Body::empty())
                    .unwrap(),
            )
        );
        assert!(poll_fn(|cx| Poll::Ready(response.as_mut().poll(cx).is_pending())).await);
        let (mut send, mut recv) = pair.server.accept_bi().await.unwrap();
        recv.read_to_end(4096).await.unwrap();
        let mut encoder = Encoder::new(EncoderConfig {
            max_table_capacity: 0,
            ..EncoderConfig::default()
        });
        let mut bytes = BytesMut::new();
        for (ty, payload) in [
            (
                FrameType::HEADERS,
                encoder
                    .encode(0, [(":status", "200"), ("content-length", "4")])
                    .unwrap(),
            ),
            (FrameType::DATA, Bytes::from_static(b"done")),
            (
                FrameType::HEADERS,
                encoder.encode(0, [("x-end", "yes")]).unwrap(),
            ),
        ] {
            FrameHeader::new(ty, payload.len() as u64)
                .encode(&mut bytes)
                .unwrap();
            bytes.extend_from_slice(&payload);
        }
        send.write_all(&bytes).await.unwrap();
        send.finish().unwrap();
        // ACK confirms the complete response and FIN reached the peer before close.
        assert_eq!(send.stopped().await.unwrap(), None);
        pair.server
            .close(Code::H3_NO_ERROR.value() as u32, b"complete");
        driver.await.unwrap().unwrap();
        let response = response.await.unwrap();
        let body = response.into_body().collect().await.unwrap();
        assert_eq!(body.trailers().unwrap()["x-end"], "yes");
        assert_eq!(body.to_bytes(), "done");
        pair.close().await;
    })
    .await
    .unwrap();
}

#[tokio::test(start_paused = true)]
async fn memory_closed_connection_preserves_only_complete_successful_responses() {
    tokio::time::timeout(LIMIT, async {
        // All cases expose the headers before close, leaving the body buffered.
        for (finish, declared_length, close_code, abort_driver, local_close) in [
            (true, "4", Code::H3_NO_ERROR, false, false),
            (false, "4", Code::H3_NO_ERROR, false, false),
            (false, "4", Code::H3_NO_ERROR, false, true),
            (true, "5", Code::H3_NO_ERROR, false, false),
            (true, "4", Code::H3_GENERAL_PROTOCOL_ERROR, false, false),
            (true, "4", Code::H3_NO_ERROR, true, false),
        ] {
            let pair = Pair::in_memory(None, None).await;
            let (mut client, driver) = client::handshake::<Body, _>(
                pair.client.clone(),
                Config::default(),
                Executor::new(),
            )
            .unwrap();
            let driver = spawn(driver.run());
            client.ready().await.unwrap();
            let response = spawn(async move {
                client
                    .send_request(
                        Request::builder()
                            .uri("https://localhost/incomplete")
                            .body(Body::empty())
                            .unwrap(),
                    )
                    .await
                    .unwrap()
            });
            let (mut send, mut recv) = pair.server.accept_bi().await.unwrap();
            recv.read_to_end(4096).await.unwrap();
            let mut encoder = Encoder::new(EncoderConfig {
                max_table_capacity: 0,
                ..EncoderConfig::default()
            });
            let headers = encoder
                .encode(0, [(":status", "200"), ("content-length", declared_length)])
                .unwrap();
            let mut bytes = BytesMut::new();
            FrameHeader::new(FrameType::HEADERS, headers.len() as u64)
                .encode(&mut bytes)
                .unwrap();
            bytes.extend_from_slice(&headers);
            FrameHeader::new(FrameType::DATA, 4)
                .encode(&mut bytes)
                .unwrap();
            bytes.extend_from_slice(b"done");
            send.write_all(&bytes).await.unwrap();
            if finish {
                send.finish().unwrap();
                assert_eq!(send.stopped().await.unwrap(), None);
            }
            let response = response.await.unwrap();
            if abort_driver {
                driver.abort();
                assert!(driver.await.unwrap_err().is_cancelled());
            } else {
                let connection = if local_close {
                    &pair.client
                } else {
                    &pair.server
                };
                connection.close(close_code.value() as u32, b"test close");
                let result = driver.await.unwrap();
                assert_eq!(result.is_ok(), close_code == Code::H3_NO_ERROR);
            }
            let body = response.into_body().collect().await;
            assert_eq!(
                body.is_ok(),
                finish
                    && declared_length == "4"
                    && close_code == Code::H3_NO_ERROR
                    && !abort_driver
            );
            if !finish && close_code == Code::H3_NO_ERROR {
                let error = body.unwrap_err();
                let cause = error
                    .source()
                    .unwrap()
                    .source()
                    .unwrap()
                    .downcast_ref::<Error>()
                    .unwrap();
                assert_eq!(cause.code(), Code::H3_REQUEST_INCOMPLETE);
                assert_eq!(cause.is_remote_failure(), !local_close);
            }
            pair.close().await;
        }
    })
    .await
    .unwrap();
}

#[tokio::test(start_paused = true)]
async fn clean_close_decodes_available_qpack_without_waiting_for_missing_inserts() {
    tokio::time::timeout(LIMIT, async {
        let mut config = Config::default();
        config.decoder.max_decoder_stream_bytes = 10;
        let shared = Shared::new(config, Role::Client, Default::default()).unwrap();
        let mut encoder = Encoder::new(EncoderConfig::default());
        let bytes = encoder.encode(0, [("x-dynamic", "present")]).unwrap();
        assert!(
            !shared
                .feed_instructions(StreamType::QPACK_ENCODER, &encoder.take_encoder_stream())
                .unwrap()
        );
        shared.fail(Error::connection(Code::H3_NO_ERROR, "complete"));
        // Feedback is impossible after close, but known entries remain usable.
        for id in (0..400).step_by(4) {
            let fields = shared.decode(id, bytes.clone()).await.unwrap();
            assert_eq!(fields[0].value, "present");
        }
        let missing = encoder
            .encode(400, [("x-dynamic", "not received")])
            .unwrap();
        assert_eq!(
            shared.decode(400, missing).await.unwrap_err().code(),
            Code::H3_REQUEST_INCOMPLETE
        );
        // A protocol error discovered during draining must still poison other readers.
        shared.fail(Error::connection(
            Code::H3_FRAME_UNEXPECTED,
            "malformed buffered frame",
        ));
        assert_eq!(
            shared.receive_error().unwrap().code(),
            Code::H3_FRAME_UNEXPECTED
        );
        assert_eq!(
            shared.decode(404, bytes).await.unwrap_err().code(),
            Code::H3_FRAME_UNEXPECTED
        );
    })
    .await
    .unwrap();
}

#[tokio::test(start_paused = true)]
async fn memory_clean_peer_close_has_one_driver_result() {
    tokio::time::timeout(LIMIT, async {
        for _ in 0..32 {
            let pair = Pair::in_memory(None, None).await;
            let (mut client, driver) = client::handshake::<Body, _>(
                pair.client.clone(),
                Config::default(),
                Executor::new(),
            )
            .unwrap();
            let (server, server_driver) =
                server::handshake(pair.server.clone(), Config::default()).unwrap();
            let driver = spawn(driver.run());
            let server_driver = spawn(server_driver.run());
            client.ready().await.unwrap();
            pair.server
                .close(Code::H3_NO_ERROR.value() as u32, b"graceful peer close");
            driver.await.unwrap().unwrap();
            server_driver.await.unwrap().unwrap();
            drop(server);
            pair.close().await;
        }
    })
    .await
    .unwrap();
}

#[tokio::test(start_paused = true)]
async fn memory_drained_server_driver_drop_sends_no_error() {
    tokio::time::timeout(LIMIT, async {
        let pair = Pair::in_memory(None, None).await;
        let (mut client, driver) =
            client::handshake::<Body, _>(pair.client.clone(), Config::default(), Executor::new())
                .unwrap();
        let (mut server, server_driver) =
            server::handshake(pair.server.clone(), Config::default()).unwrap();
        let driver = spawn(driver.run());
        let server_driver = spawn(server_driver.run());
        client.ready().await.unwrap();
        server.shutdown().unwrap();
        server.drained().await.unwrap();
        server_driver.abort();
        assert!(server_driver.await.unwrap_err().is_cancelled());
        let reason = pair.client.closed().await;
        let rama_quic::ConnectionError::ApplicationClosed(close) = reason else {
            panic!("expected HTTP/3 application close: {reason:?}");
        };
        assert_eq!(close.error_code.into_inner(), Code::H3_NO_ERROR.value());
        driver.await.unwrap().unwrap();
        pair.close().await;
    })
    .await
    .unwrap();
}

#[tokio::test(start_paused = true)]
async fn memory_oversized_outgoing_trailers_preserve_connection() {
    tokio::time::timeout(LIMIT, async {
        let pair = Pair::in_memory(None, None).await;
        let mut config = Config::default();
        config.decoder.max_field_section_size = 256;
        config.max_pushes = 1;
        let (mut client, client_driver) =
            client::handshake::<Body, _>(pair.client.clone(), config, Executor::new()).unwrap();
        let (mut server, server_driver) = server::handshake(
            pair.server.clone(),
            Config {
                max_pushes: 1,
                ..Config::default()
            },
        )
        .unwrap();
        let client_driver = spawn(client_driver.run());
        let server_driver = spawn(server_driver.run());
        let serve = spawn(async move {
            let (request, response) = server.accept().await.unwrap().resolve().await.unwrap();
            request.into_body().collect().await.unwrap();
            // MAX_PUSH_ID follows SETTINGS on the control stream, providing a
            // wire-level barrier before we exercise the advertised field limit.
            response.ready_for_push().await.unwrap();
            let mut trailers = HeaderMap::new();
            trailers.insert("x-too-large", "a".repeat(256).parse().unwrap());
            let body = Body::from_frame_stream(stream::iter([
                Ok::<_, Infallible>(Frame::data(Bytes::from_static(b"prefix"))),
                Ok(Frame::trailers(trailers)),
            ]));
            let error = response
                .send_response(Response::new(body))
                .await
                .unwrap_err();
            assert_eq!(error.scope(), ErrorScope::Stream);
            assert_eq!(error.code(), Code::H3_MESSAGE_ERROR);
            let (request, response) = server.accept().await.unwrap().resolve().await.unwrap();
            request.into_body().collect().await.unwrap();
            response
                .send_response(Response::new(Body::from("survived")))
                .await
                .unwrap();
        });
        let request = || {
            Request::builder()
                .uri("https://localhost/")
                .body(Body::empty())
                .unwrap()
        };
        match client.send_request(request()).await {
            Ok(response) => {
                let error = response.into_body().collect().await.unwrap_err();
                let error = error
                    .source()
                    .unwrap()
                    .source()
                    .unwrap()
                    .downcast_ref::<Error>()
                    .unwrap();
                assert_eq!(error.code(), Code::H3_MESSAGE_ERROR);
            }
            Err(error) => {
                assert_eq!(error.scope(), ErrorScope::Stream);
                assert_eq!(error.code(), Code::H3_MESSAGE_ERROR);
            }
        }
        assert!(pair.client.close_reason().is_none());
        let response = client.send_request(request()).await.unwrap();
        assert_eq!(
            response.into_body().collect().await.unwrap().to_bytes(),
            "survived"
        );
        serve.await.unwrap();
        pair.client
            .close(Code::H3_NO_ERROR.value() as u32, b"complete");
        client_driver.await.unwrap().unwrap();
        server_driver.await.unwrap().unwrap();
        pair.close().await;
    })
    .await
    .unwrap();
}

#[tokio::test(start_paused = true)]
async fn memory_completed_post_does_not_send_stop_sending_when_body_is_dropped() {
    completed_post_body_drop(true).await;
}

#[tokio::test(start_paused = true)]
async fn memory_unread_completed_post_does_not_send_stop_sending() {
    completed_post_body_drop(false).await;
}

async fn completed_post_body_drop(read_body: bool) {
    tokio::time::timeout(LIMIT, async {
        let pair = Pair::in_memory(None, None).await;
        let (_client, client_driver) =
            client::handshake::<Body, _>(pair.client.clone(), Config::default(), Executor::new())
                .unwrap();
        let (mut server, server_driver) =
            server::handshake(pair.server.clone(), Config::default()).unwrap();
        let client_driver = spawn(client_driver.run());
        let server_driver = spawn(server_driver.run());
        let (send, mut recv) = pair.client.open_bi().await.unwrap();
        let mut writer = Writer::new(send);
        let mut encoder = Encoder::before_peer_settings(EncoderConfig::default());
        let fields = encoder
            .encode(
                0,
                [
                    (":method", "POST"),
                    (":scheme", "https"),
                    (":authority", "localhost"),
                    (":path", "/"),
                    ("content-length", "4"),
                ],
            )
            .unwrap();
        writer.queue(FrameType::HEADERS, fields).unwrap();
        poll_fn(|cx| writer.poll_flush(cx)).await.unwrap();
        writer
            .queue(FrameType::DATA, Bytes::from_static(b"body"))
            .unwrap();
        poll_fn(|cx| writer.poll_finish(cx)).await.unwrap();
        writer.acknowledged().await.unwrap();
        writer.mark_acknowledged();
        let (mut request, response) = server.accept().await.unwrap().resolve().await.unwrap();
        if read_body {
            // Consume exactly the body, without the extra poll that observes EOF.
            let frame = request.body_mut().frame().await.unwrap().unwrap();
            assert_eq!(frame.into_data().unwrap(), "body");
        }
        // Both an ignored complete body and a body read through FIN need no cancellation.
        drop(request);
        response
            .send_response(Response::new(Body::from("done")))
            .await
            .unwrap();
        let bytes = recv.read_to_end(1024).await.unwrap();
        assert!(bytes.ends_with(b"done"));
        assert_eq!(pair.server.stats().frame_tx.stop_sending, 0);
        pair.client
            .close(Code::H3_NO_ERROR.value() as u32, b"complete");
        client_driver.await.unwrap().unwrap();
        server_driver.await.unwrap().unwrap();
        pair.close().await;
    })
    .await
    .unwrap();
}

#[tokio::test(start_paused = true)]
async fn memory_unread_request_body_is_stopped_without_error() {
    tokio::time::timeout(LIMIT, async {
        let pair = Pair::in_memory(None, None).await;
        let (_client, client_driver) =
            client::handshake::<Body, _>(pair.client.clone(), Config::default(), Executor::new())
                .unwrap();
        let (mut server, server_driver) =
            server::handshake(pair.server.clone(), Config::default()).unwrap();
        let client_driver = spawn(client_driver.run());
        let server_driver = spawn(server_driver.run());
        let (send, mut recv) = pair.client.open_bi().await.unwrap();
        let stopped = send.stopped();
        let mut writer = Writer::new(send);
        let mut encoder = Encoder::before_peer_settings(EncoderConfig::default());
        let fields = encoder
            .encode(
                0,
                [
                    (":method", "POST"),
                    (":scheme", "https"),
                    (":authority", "localhost"),
                    (":path", "/"),
                    ("content-length", "100"),
                ],
            )
            .unwrap();
        writer.queue(FrameType::HEADERS, fields).unwrap();
        poll_fn(|cx| writer.poll_flush(cx)).await.unwrap();
        let (request, response) = server.accept().await.unwrap().resolve().await.unwrap();
        response
            .send_response(Response::new(Body::from("done")))
            .await
            .unwrap();
        drop(request);
        assert_eq!(
            stopped.await.unwrap().unwrap().into_inner(),
            Code::H3_NO_ERROR.value()
        );
        recv.read_to_end(1024).await.unwrap();
        assert!(pair.client.close_reason().is_none());
        pair.client
            .close(Code::H3_NO_ERROR.value() as u32, b"complete");
        client_driver.await.unwrap().unwrap();
        server_driver.await.unwrap().unwrap();
        pair.close().await;
    })
    .await
    .unwrap();
}

#[tokio::test(start_paused = true)]
async fn memory_malformed_request_body_and_trailers_abort_both_directions() {
    tokio::time::timeout(LIMIT, async {
        let pair = Pair::in_memory(None, None).await;
        let (_client, client_driver) = client::handshake::<Body, _>(
            pair.client.clone(), Config::default(), Executor::new()).unwrap();
        let (mut server, server_driver) = server::handshake(
            pair.server.clone(), Config::default()).unwrap();
        let client_driver = spawn(client_driver.run());
        let server_driver = spawn(server_driver.run());
        let mut encoder = Encoder::before_peer_settings(EncoderConfig::default());
        for malformed_trailers in [false, true] {
            let (send, mut recv) = pair.client.open_bi().await.unwrap();
            let id = u64::from(send.id());
            let stopped = send.stopped();
            let mut writer = Writer::new(send);
            let fields = encoder.encode(id, [
                (":method", "POST"), (":scheme", "https"), (":authority", "localhost"),
                (":path", "/"), ("content-length", "1"),
            ]).unwrap();
            writer.queue(FrameType::HEADERS, fields).unwrap();
            poll_fn(|cx| writer.poll_flush(cx)).await.unwrap();
            if malformed_trailers {
                let trailers = encoder.encode(id, [(":status", "200")]).unwrap();
                writer.queue(FrameType::HEADERS, trailers).unwrap();
            } else {
                writer.queue(FrameType::DATA, Bytes::from_static(b"too long")).unwrap();
            }
            poll_fn(|cx| writer.poll_flush(cx)).await.unwrap();
            let (request, response) = server.accept().await.unwrap().resolve().await.unwrap();
            request.into_body().collect().await.unwrap_err();
            assert_eq!(stopped.await.unwrap().unwrap().into_inner(), Code::H3_MESSAGE_ERROR.value());
            assert_matches!(
                recv.read_chunk(1024, true).await.unwrap_err(),
                rama_quic::ReadError::Reset(code) if code.into_inner() == Code::H3_MESSAGE_ERROR.value(),
            );
            // The send direction is reset immediately, even while its application
            // response handle remains alive in another task.
            drop(response);
            assert!(pair.client.close_reason().is_none());
        }
        pair.client.close(Code::H3_NO_ERROR.value() as u32, b"complete");
        client_driver.await.unwrap().unwrap();
        server_driver.await.unwrap().unwrap();
        pair.close().await;
    }).await.unwrap();
}

/// A request stream carries at most one trailer section (RFC 9114 §4.1).
#[tokio::test(start_paused = true)]
async fn memory_headers_after_trailers_are_a_connection_error() {
    tokio::time::timeout(LIMIT, async {
        let pair = Pair::in_memory(None, None).await;
        let (_client, client_driver) =
            client::handshake::<Body, _>(pair.client.clone(), Config::default(), Executor::new())
                .unwrap();
        let (mut server, server_driver) =
            server::handshake(pair.server.clone(), Config::default()).unwrap();
        let client_driver = spawn(client_driver.run());
        let server_driver = spawn(server_driver.run());
        let mut encoder = Encoder::before_peer_settings(EncoderConfig::default());
        let (send, _recv) = pair.client.open_bi().await.unwrap();
        let id = u64::from(send.id());
        let mut writer = Writer::new(send);
        let head = encoder
            .encode(
                id,
                [
                    (":method", "POST"),
                    (":scheme", "https"),
                    (":authority", "localhost"),
                    (":path", "/"),
                ],
            )
            .unwrap();
        writer.queue(FrameType::HEADERS, head).unwrap();
        poll_fn(|cx| writer.poll_flush(cx)).await.unwrap();
        for _ in 0..2 {
            let trailers = encoder.encode(id, [("x-checksum", "abc")]).unwrap();
            writer.queue(FrameType::HEADERS, trailers).unwrap();
            poll_fn(|cx| writer.poll_flush(cx)).await.unwrap();
        }
        let (request, _response) = server.accept().await.unwrap().resolve().await.unwrap();
        request.into_body().collect().await.unwrap_err();
        assert_eq!(
            server_driver.await.unwrap().unwrap_err().code(),
            Code::H3_FRAME_UNEXPECTED
        );
        assert_eq!(
            client_driver.await.unwrap().unwrap_err().code(),
            Code::H3_FRAME_UNEXPECTED
        );
        pair.close().await;
    })
    .await
    .unwrap();
}

#[tokio::test(start_paused = true)]
async fn memory_rejected_connect_retains_response_and_stops_without_error() {
    tokio::time::timeout(LIMIT, async {
        let pair = Pair::in_memory(None, None).await;
        let (mut client, client_driver) =
            client::handshake::<Body, _>(pair.client.clone(), Config::default(), Executor::new())
                .unwrap();
        let (mut server, server_driver) =
            server::handshake(pair.server.clone(), Config::default()).unwrap();
        let client_driver = spawn(client_driver.run());
        let server_driver = spawn(server_driver.run());
        let (send, mut recv) = pair.client.open_bi().await.unwrap();
        let stopped = send.stopped();
        let mut writer = Writer::new(send);
        let mut encoder = Encoder::before_peer_settings(EncoderConfig::default());
        writer
            .queue(
                FrameType::HEADERS,
                encoder
                    .encode(0, [(":method", "CONNECT"), (":authority", "localhost:443")])
                    .unwrap(),
            )
            .unwrap();
        poll_fn(|cx| writer.poll_flush(cx)).await.unwrap();
        let (_request, response) = server.accept().await.unwrap().resolve().await.unwrap();
        response
            .send_response(
                Response::builder()
                    .status(StatusCode::FORBIDDEN)
                    .body(Body::from("denied"))
                    .unwrap(),
            )
            .await
            .unwrap();
        assert_eq!(
            stopped.await.unwrap().unwrap().into_inner(),
            Code::H3_NO_ERROR.value()
        );
        recv.read_to_end(1024).await.unwrap();
        let serve = spawn(async move {
            let (_request, response) = server.accept().await.unwrap().resolve().await.unwrap();
            response
                .send_response(
                    Response::builder()
                        .status(StatusCode::FORBIDDEN)
                        .body(Body::from("denied"))
                        .unwrap(),
                )
                .await
                .unwrap();
        });
        let response = client
            .send_request(
                Request::builder()
                    .method(Method::CONNECT)
                    .uri(Uri::parse_http_request_target("localhost:443", true).unwrap())
                    .body(Body::empty())
                    .unwrap(),
            )
            .await
            .unwrap();
        assert_eq!(response.status(), StatusCode::FORBIDDEN);
        assert_eq!(
            response.into_body().collect().await.unwrap().to_bytes(),
            "denied"
        );
        serve.await.unwrap();
        assert!(pair.client.close_reason().is_none());
        pair.client
            .close(Code::H3_NO_ERROR.value() as u32, b"complete");
        client_driver.await.unwrap().unwrap();
        server_driver.await.unwrap().unwrap();
        pair.close().await;
    })
    .await
    .unwrap();
}

fn raw_response_frames(frames: &[(FrameType, Bytes)]) -> Bytes {
    let mut bytes = BytesMut::new();
    for (ty, payload) in frames {
        FrameHeader::new(*ty, payload.len() as u64)
            .encode(&mut bytes)
            .unwrap();
        bytes.extend_from_slice(payload);
    }
    bytes.freeze()
}

#[tokio::test(start_paused = true)]
async fn memory_clean_close_with_pending_upload_keeps_complete_response() {
    tokio::time::timeout(LIMIT, async {
        let pair = Pair::in_memory(None, None).await;
        let (mut client, driver) =
            client::handshake::<Body, _>(pair.client.clone(), Config::default(), Executor::new())
                .unwrap();
        let driver = spawn(driver.run());
        client.ready().await.unwrap();
        let (upload_guard, upload_dropped) = oneshot::channel::<()>();
        let response = spawn(async move {
            client
                .send_request(
                    Request::builder()
                        .method(Method::POST)
                        .uri("https://localhost/upload")
                        .body(Body::from_stream(stream::once(async move {
                            let _guard = upload_guard;
                            std::future::pending::<Result<Bytes, Infallible>>().await
                        })))
                        .unwrap(),
                )
                .await
        });
        let (mut send, mut recv) = pair.server.accept_bi().await.unwrap();
        recv.read_chunk(4096, true).await.unwrap();
        let mut encoder = Encoder::new(EncoderConfig {
            max_table_capacity: 0,
            ..EncoderConfig::default()
        });
        let bytes = raw_response_frames(&[
            (
                FrameType::HEADERS,
                encoder
                    .encode(0, [(":status", "200"), ("content-length", "4")])
                    .unwrap(),
            ),
            (FrameType::DATA, Bytes::from_static(b"done")),
        ]);
        send.write_all(&bytes).await.unwrap();
        send.finish().unwrap();
        assert_eq!(send.stopped().await.unwrap(), None);
        let response = response.await.unwrap().unwrap();
        pair.server
            .close(Code::H3_NO_ERROR.value() as u32, b"complete");
        driver.await.unwrap().unwrap();
        assert!(upload_dropped.await.is_err());
        let body = response.into_body().collect().await;
        assert!(body.is_ok(), "{body:?}");
        assert_eq!(body.unwrap().to_bytes(), "done");
        pair.close().await;
    })
    .await
    .unwrap();
}

#[tokio::test(start_paused = true)]
async fn memory_malformed_response_aborts_pending_upload() {
    tokio::time::timeout(LIMIT, async {
        let pair = Pair::in_memory(None, None).await;
        let (mut client, driver) =
            client::handshake::<Body, _>(pair.client.clone(), Config::default(), Executor::new())
                .unwrap();
        let driver = spawn(driver.run());
        client.ready().await.unwrap();
        let response = spawn(async move {
            let r = client
                .send_request(
                    Request::builder()
                        .method(Method::POST)
                        .uri("https://localhost/upload")
                        .body(Body::from_stream(stream::pending::<Result<Bytes, Infallible>>()))
                        .unwrap(),
                )
                .await;
            (client, r)
        });
        let (mut send, mut recv) = pair.server.accept_bi().await.unwrap();
        recv.read_chunk(4096, true).await.unwrap();
        let mut encoder = Encoder::new(EncoderConfig {
            max_table_capacity: 0,
            ..EncoderConfig::default()
        });
        let bytes = raw_response_frames(&[
            (
                FrameType::HEADERS,
                encoder
                    .encode(0, [(":status", "200"), ("content-length", "1")])
                    .unwrap(),
            ),
            (FrameType::DATA, Bytes::from_static(b"too long")),
        ]);
        send.write_all(&bytes).await.unwrap();
        let (_client, response) = response.await.unwrap();
        let response = response.unwrap();
        response.into_body().collect().await.unwrap_err();
        // Both directions must be aborted: the request upload is reset.
        let error = recv.read_chunk(1024, true).await.unwrap_err();
        assert_matches!(
            error,
            rama_quic::ReadError::Reset(code) if code.into_inner() == Code::H3_MESSAGE_ERROR.value(),
            "{error:?}",
        );
        assert!(pair.client.close_reason().is_none(), "{:?} / server {:?}", pair.client.close_reason(), pair.server.close_reason());
        pair.client
            .close(Code::H3_NO_ERROR.value() as u32, b"complete");
        _ = driver.await.unwrap();
        pair.close().await;
    })
    .await
    .unwrap();
}

#[tokio::test(start_paused = true)]
async fn memory_cancel_before_headers_releases_admission() {
    tokio::time::timeout(LIMIT, async {
        let pair = Pair::in_memory(None, None).await;
        let config = Config {
            max_requests: 1,
            ..Config::default()
        };
        let (client, client_driver) =
            client::handshake::<Body, _>(pair.client.clone(), config.clone(), Executor::new())
                .unwrap();
        let (mut server, server_driver) = server::handshake(pair.server.clone(), config).unwrap();
        let client_driver = spawn(client_driver.run());
        let server_driver = spawn(server_driver.run());
        let (held_tx, mut held_rx) = tokio::sync::mpsc::unbounded_channel();
        let serve = spawn(async move {
            for _ in 0..8 {
                let (request, response) = server.accept().await.unwrap().resolve().await.unwrap();
                request.into_body().collect().await.unwrap();
                // Never answer: the client cancels while waiting for HEADERS.
                held_tx.send(response).unwrap();
            }
            let (request, response) = server.accept().await.unwrap().resolve().await.unwrap();
            request.into_body().collect().await.unwrap();
            response
                .send_response(Response::new(Body::from("recovered")))
                .await
                .unwrap();
        });
        for _ in 0..8 {
            let mut client = client.clone();
            let pending = spawn(async move {
                client
                    .send_request(
                        Request::builder()
                            .uri("https://localhost/cancel")
                            .body(Body::empty())
                            .unwrap(),
                    )
                    .await
            });
            let held = held_rx.recv().await.unwrap();
            pending.abort();
            assert!(pending.await.unwrap_err().is_cancelled());
            drop(held);
        }
        let mut client = client.clone();
        let response = client
            .send_request(
                Request::builder()
                    .uri("https://localhost/recovered")
                    .body(Body::empty())
                    .unwrap(),
            )
            .await
            .unwrap();
        assert_eq!(
            response.into_body().collect().await.unwrap().to_bytes(),
            "recovered"
        );
        serve.await.unwrap();
        assert!(pair.client.close_reason().is_none());
        pair.client.close(0u32, b"test complete");
        _ = client_driver.await.unwrap();
        _ = server_driver.await.unwrap();
        pair.close().await;
    })
    .await
    .unwrap();
}

#[tokio::test(start_paused = true)]
async fn memory_goaway_before_clean_close_preserves_retryable_rejection() {
    tokio::time::timeout(LIMIT, async {
        for method in [Method::GET, Method::CONNECT] {
            let pair = Pair::in_memory(None, None).await;
            let (mut client, driver) = client::handshake::<Body, _>(
                pair.client.clone(),
                Config::default(),
                Executor::new(),
            )
            .unwrap();
            let driver = spawn(driver.run());
            client.ready().await.unwrap();
            // Hold the application future while the driver receives both GOAWAY
            // and CONNECTION_CLOSE. Both select branches are ready when resumed.
            let uri = if method == Method::CONNECT {
                Uri::parse_http_request_target("localhost:443", true).unwrap()
            } else {
                Uri::try_from("https://localhost/retry").unwrap()
            };
            let draining = client.closed_or_draining();
            let mut response = pin!(
                client.send_request(
                    Request::builder()
                        .method(method)
                        .uri(uri)
                        .body(Body::empty())
                        .unwrap()
                )
            );
            let initial = poll_fn(|cx| Poll::Ready(response.as_mut().poll(cx))).await;
            assert!(initial.is_pending(), "{initial:?}");
            let (_send, mut recv) = pair.server.accept_bi().await.unwrap();
            recv.read_chunk(4096, true).await.unwrap();
            let mut control = pair.server.open_uni().await.unwrap();
            let mut bytes = BytesMut::from(
                initial_control(&Config::default(), Role::Client, false)
                    .unwrap()
                    .as_ref(),
            );
            FrameHeader::new(FrameType::GOAWAY, 1)
                .encode(&mut bytes)
                .unwrap();
            VarInt::from_u32(0).encode(&mut bytes);
            control.write_all(&bytes).await.unwrap();
            assert_eq!(draining.await.code(), Code::H3_REQUEST_REJECTED);
            pair.server
                .close(Code::H3_NO_ERROR.value() as u32, b"graceful rejection");
            driver.await.unwrap().unwrap();
            assert_eq!(
                response.await.unwrap_err().code(),
                Code::H3_REQUEST_REJECTED
            );
            pair.close().await;
        }
    })
    .await
    .unwrap();
}

#[tokio::test(start_paused = true)]
async fn memory_server_rejects_unresolved_and_post_shutdown_requests() {
    tokio::time::timeout(LIMIT, async {
        let pair = Pair::in_memory(None, None).await;
        let (mut server, driver) = server::handshake(pair.server.clone(), Config::default()).unwrap();
        let driver = spawn(driver.run());
        for shutdown in [false, true] {
            if shutdown { server.shutdown().unwrap(); }
            let (mut send, mut recv) = pair.client.open_bi().await.unwrap();
            // An incomplete HEADERS frame makes the stream visible without
            // exposing any request to the application.
            send.write_all(&[FrameType::HEADERS.value() as u8]).await.unwrap();
            if !shutdown { drop(server.accept().await.unwrap()); }
            assert_eq!(send.stopped().await.unwrap().unwrap().into_inner(), Code::H3_REQUEST_REJECTED.value());
            assert_matches!(recv.read_chunk(1, true).await.unwrap_err(), rama_quic::ReadError::Reset(code) if code.into_inner() == Code::H3_REQUEST_REJECTED.value());
        }
        pair.client.close(Code::H3_NO_ERROR.value() as u32, b"complete");
        driver.await.unwrap().unwrap();
        pair.close().await;
    }).await.unwrap();
}

#[tokio::test(start_paused = true)]
async fn memory_blocked_field_storage_limit_resets_only_affected_request() {
    tokio::time::timeout(LIMIT, async {
        let pair = Pair::in_memory(None, None).await;
        let mut config = Config::default();
        config.decoder.max_blocked_bytes = 0;
        let (mut client, driver) =
            client::handshake::<Body, _>(pair.client.clone(), config, Executor::new()).unwrap();
        let driver = spawn(driver.run());
        client.ready().await.unwrap();
        let mut control = pair.server.open_uni().await.unwrap();
        control
            .write_all(&initial_control(&Config::default(), Role::Client, false).unwrap())
            .await
            .unwrap();
        let peer = pair.server.clone();
        let serve = spawn(async move {
            let (mut send, mut recv) = peer.accept_bi().await.unwrap();
            recv.read_chunk(4096, true).await.unwrap();
            let mut dynamic = Encoder::new(EncoderConfig::default());
            let section = dynamic
                .encode(0, [(":status", "200"), ("x-blocked", "waiting for insert")])
                .unwrap();
            // Deliberately withhold the encoder stream. This is legal under the
            // advertised blocked-stream count, but exceeds our local byte budget.
            assert!(!dynamic.take_encoder_stream().is_empty());
            send.write_all(&raw_response_frames(&[(FrameType::HEADERS, section)]))
                .await
                .unwrap();
            assert_eq!(
                send.stopped().await.unwrap().unwrap().into_inner(),
                Code::H3_EXCESSIVE_LOAD.value()
            );
            let (mut send, mut recv) = peer.accept_bi().await.unwrap();
            recv.read_chunk(4096, true).await.unwrap();
            let mut literal = Encoder::before_peer_settings(EncoderConfig::default());
            let section = literal.encode(4, [(":status", "200")]).unwrap();
            send.write_all(&raw_response_frames(&[
                (FrameType::HEADERS, section),
                (FrameType::DATA, Bytes::from_static(b"survived")),
            ]))
            .await
            .unwrap();
            send.finish().unwrap();
        });
        let request = || {
            Request::builder()
                .uri("https://localhost/")
                .body(Body::empty())
                .unwrap()
        };
        let error = client.send_request(request()).await.unwrap_err();
        assert_eq!(error.scope(), ErrorScope::Stream);
        assert_eq!(error.code(), Code::H3_EXCESSIVE_LOAD);
        let response = client.send_request(request()).await.unwrap();
        assert_eq!(
            response.into_body().collect().await.unwrap().to_bytes(),
            "survived"
        );
        serve.await.unwrap();
        driver.abort();
        _ = driver.await;
        pair.close().await;
    })
    .await
    .unwrap();
}

#[tokio::test(start_paused = true)]
async fn memory_stalled_response_reader_does_not_starve_other_requests() {
    tokio::time::timeout(LIMIT, async {
        let mut transport = TransportConfig::default();
        Config::default()
            .configure_transport(&mut transport)
            .unwrap();
        transport.set_stream_receive_window(VarInt::from_u32(1024));
        let pair = Pair::in_memory(Some(transport), None).await;
        let (mut client, client_driver) =
            client::handshake::<Body, _>(pair.client.clone(), Config::default(), Executor::new())
                .unwrap();
        let (mut server, server_driver) =
            server::handshake(pair.server.clone(), Config::default()).unwrap();
        let client_driver = spawn(client_driver.run());
        let server_driver = spawn(server_driver.run());
        let (stalled_tx, stalled_rx) = oneshot::channel();
        let serve = spawn(async move {
            let (request, response) = server.accept().await.unwrap().resolve().await.unwrap();
            request.into_body().collect().await.unwrap();
            let blocked = spawn(response.send_response(Response::new(Body::from(
                vec![b'a'; rama_utils::octets::mib(1)],
            ))));
            stalled_tx.send(blocked).unwrap();
            let (request, response) = server.accept().await.unwrap().resolve().await.unwrap();
            request.into_body().collect().await.unwrap();
            response
                .send_response(Response::new(Body::from("independent")))
                .await
                .unwrap();
        });
        let request = || {
            Request::builder()
                .uri("https://localhost/progress")
                .body(Body::empty())
                .unwrap()
        };
        let stalled = client.send_request(request()).await.unwrap();
        let blocked = stalled_rx.await.unwrap();
        let response = client.send_request(request()).await.unwrap();
        assert_eq!(
            response.into_body().collect().await.unwrap().to_bytes(),
            "independent"
        );
        assert!(
            !blocked.is_finished(),
            "large response must still await stream credit"
        );
        drop(stalled);
        assert!(blocked.await.unwrap().is_err());
        serve.await.unwrap();
        assert!(pair.client.close_reason().is_none());
        pair.client
            .close(Code::H3_NO_ERROR.value() as u32, b"complete");
        client_driver.await.unwrap().unwrap();
        server_driver.await.unwrap().unwrap();
        pair.close().await;
    })
    .await
    .unwrap();
}

#[tokio::test(start_paused = true)]
async fn memory_priority_update_cannot_exceed_advertised_stream_credit() {
    tokio::time::timeout(LIMIT, async {
        let pair = Pair::in_memory(None, None).await;
        let (mut server, driver) =
            server::handshake(pair.server.clone(), Config::default()).unwrap();
        let driver = spawn(driver.run());
        // A closed request remains a valid update target and must be ignored.
        let (mut send, _recv) = pair.client.open_bi().await.unwrap();
        send.write_all(&[FrameType::HEADERS.value() as u8])
            .await
            .unwrap();
        drop(server.accept().await.unwrap());
        let limit = pair.server.remote_stream_limit(Dir::Bi);
        let mut control = pair.client.open_uni().await.unwrap();
        control
            .write_all(&initial_control(&Config::default(), Role::Client, false).unwrap())
            .await
            .unwrap();
        for (id, value) in [(0, "u=1"), ((limit - 1) * 4, "u=1"), (limit * 4, "invalid")] {
            let mut payload = BytesMut::new();
            VarInt::from_u64(id).unwrap().encode(&mut payload);
            payload.extend_from_slice(value.as_bytes());
            control
                .write_all(&raw_response_frames(&[(
                    FrameType::PRIORITY_UPDATE_REQUEST,
                    payload.freeze(),
                )]))
                .await
                .unwrap();
        }
        assert_eq!(driver.await.unwrap().unwrap_err().code(), Code::H3_ID_ERROR);
        pair.close().await;
    })
    .await
    .unwrap();
}

#[tokio::test(start_paused = true)]
async fn memory_goaway_rejects_connect_waiting_for_request_send_credit() {
    tokio::time::timeout(LIMIT, async {
        let mut transport = TransportConfig::default();
        Config::default()
            .configure_transport(&mut transport)
            .unwrap();
        transport.set_stream_receive_window(VarInt::from_u32(0));
        let pair = Pair::in_memory(None, Some(transport)).await;
        let (mut client, driver) =
            client::handshake::<Body, _>(pair.client.clone(), Config::default(), Executor::new())
                .unwrap();
        let driver = spawn(driver.run());
        client.ready().await.unwrap();
        let draining = client.closed_or_draining();
        let mut response = pin!(
            client.send_request(
                Request::builder()
                    .method(Method::CONNECT)
                    .uri(Uri::parse_http_request_target("localhost:443", true).unwrap())
                    .body(Body::empty())
                    .unwrap()
            )
        );
        assert!(poll_fn(|cx| Poll::Ready(response.as_mut().poll(cx).is_pending())).await);
        let mut control = pair.server.open_uni().await.unwrap();
        let mut bytes = BytesMut::from(
            initial_control(&Config::default(), Role::Client, false)
                .unwrap()
                .as_ref(),
        );
        FrameHeader::new(FrameType::GOAWAY, 1)
            .encode(&mut bytes)
            .unwrap();
        VarInt::from_u32(0).encode(&mut bytes);
        control.write_all(&bytes).await.unwrap();
        assert_eq!(draining.await.code(), Code::H3_REQUEST_REJECTED);
        assert_eq!(
            response.await.unwrap_err().code(),
            Code::H3_REQUEST_REJECTED
        );
        pair.client
            .close(Code::H3_NO_ERROR.value() as u32, b"complete");
        driver.await.unwrap().unwrap();
        pair.close().await;
    })
    .await
    .unwrap();
}

#[tokio::test(start_paused = true)]
async fn memory_peer_exceeding_blocked_stream_setting_closes_connection() {
    tokio::time::timeout(LIMIT, async {
        let pair = Pair::in_memory(None, None).await;
        let mut config = Config::default();
        config.decoder.max_blocked_streams = 0;
        let (mut client, driver) =
            client::handshake::<Body, _>(pair.client.clone(), config, Executor::new()).unwrap();
        let driver = spawn(driver.run());
        client.ready().await.unwrap();
        let mut control = pair.server.open_uni().await.unwrap();
        control
            .write_all(&initial_control(&Config::default(), Role::Client, false).unwrap())
            .await
            .unwrap();
        let request = spawn(async move {
            client
                .send_request(
                    Request::builder()
                        .uri("https://localhost/")
                        .body(Body::empty())
                        .unwrap(),
                )
                .await
        });
        let (mut send, mut recv) = pair.server.accept_bi().await.unwrap();
        recv.read_chunk(4096, true).await.unwrap();
        // Unlike the local byte limit, exceeding the advertised blocked-stream
        // SETTINGS value is a peer protocol violation (RFC 9204 section 2.2.1).
        let mut encoder = Encoder::new(EncoderConfig::default());
        let section = encoder
            .encode(0, [(":status", "200"), ("x-blocked", "missing insert")])
            .unwrap();
        assert!(!encoder.take_encoder_stream().is_empty());
        send.write_all(&raw_response_frames(&[(FrameType::HEADERS, section)]))
            .await
            .unwrap();
        let error = request.await.unwrap().unwrap_err();
        assert_eq!(error.scope(), ErrorScope::Connection);
        assert_eq!(error.code(), Code::QPACK_DECOMPRESSION_FAILED);
        let error = driver.await.unwrap().unwrap_err();
        assert_eq!(error.code(), Code::QPACK_DECOMPRESSION_FAILED);
        let error = Error::from_transport(&pair.server.closed().await);
        assert_eq!(error.scope(), ErrorScope::Connection);
        assert_eq!(error.code(), Code::QPACK_DECOMPRESSION_FAILED);
        pair.close().await;
    })
    .await
    .unwrap();
}

#[tokio::test(start_paused = true)]
async fn memory_clean_close_upload_error_does_not_discard_response_behind_unknown_frames() {
    tokio::time::timeout(LIMIT, async {
        let pair = Pair::in_memory(None, None).await;
        let (mut client, driver) =
            client::handshake::<Body, _>(pair.client.clone(), Config::default(), Executor::new())
                .unwrap();
        let driver = spawn(driver.run());
        client.ready().await.unwrap();
        let (upload_guard, upload_dropped) = oneshot::channel::<()>();
        let body = Body::from_stream(stream::once(async move {
            // The unsent application body keeps the upload open until transport
            // closure. Dropping it proves the upload task observed that closure.
            let _guard = upload_guard;
            std::future::pending::<Result<Bytes, Infallible>>().await
        }));
        let mut response = pin!(
            client.send_request(
                Request::builder()
                    .method(Method::POST)
                    .uri("https://localhost/unknown-frames")
                    .body(body)
                    .unwrap()
            )
        );
        assert!(poll_fn(|cx| Poll::Ready(response.as_mut().poll(cx).is_pending())).await);
        let (mut send, mut recv) = pair.server.accept_bi().await.unwrap();
        recv.read_chunk(4096, true).await.unwrap();
        let mut encoder = Encoder::new(EncoderConfig {
            max_table_capacity: 0,
            ..EncoderConfig::default()
        });
        // Unknown frames are legal and must be skipped cooperatively. Buffered
        // final HEADERS need several polls, so the completed upload can win the
        // response select while the complete response is still being decoded.
        let mut frames = vec![(FrameType::new(0x21), Bytes::new()); 128];
        frames.push((
            FrameType::HEADERS,
            encoder.encode(0, [(":status", "200")]).unwrap(),
        ));
        frames.push((FrameType::DATA, Bytes::from_static(b"complete")));
        send.write_all(&raw_response_frames(&frames)).await.unwrap();
        send.finish().unwrap();
        assert_eq!(send.stopped().await.unwrap(), None);
        pair.server
            .close(Code::H3_NO_ERROR.value() as u32, b"complete");
        driver.await.unwrap().unwrap();
        assert!(upload_dropped.await.is_err());
        let response = response.await.unwrap();
        assert_eq!(
            response.into_body().collect().await.unwrap().to_bytes(),
            "complete"
        );
        pair.close().await;
    })
    .await
    .unwrap();
}

#[tokio::test(start_paused = true)]
async fn memory_long_lived_responses_preserve_the_last_reusable_stream_slot() {
    const RETAINED: usize = 15;
    const COMPLETED: usize = 16;

    tokio::time::timeout(LIMIT, async {
        let config = Config {
            max_requests: RETAINED + 1,
            ..Config::default()
        };
        let mut transport = TransportConfig::default();
        config.configure_transport(&mut transport).unwrap();
        let pair = Pair::in_memory(None, Some(transport)).await;
        let (mut client, client_driver) =
            client::handshake::<Body, _>(pair.client.clone(), config.clone(), Executor::new())
                .unwrap();
        let (mut server, server_driver) = server::handshake(pair.server.clone(), config).unwrap();
        let client_driver = spawn(client_driver.run());
        let server_driver = spawn(server_driver.run());
        let serve = spawn(async move {
            let mut held = Vec::with_capacity(RETAINED);
            for index in 0..RETAINED + COMPLETED {
                let (request, response) = server.accept().await.unwrap().resolve().await.unwrap();
                request.into_body().collect().await.unwrap();
                if index < RETAINED {
                    held.push(spawn(async move {
                        let body =
                            Body::from_stream(stream::pending::<Result<Bytes, Infallible>>());
                        let _result = response.send_response(Response::new(body)).await;
                    }));
                } else {
                    response
                        .send_response(Response::new(Body::from("reusable")))
                        .await
                        .unwrap();
                }
            }
            held
        });
        let mut held = Vec::with_capacity(RETAINED);
        for index in 0..RETAINED + COMPLETED {
            let response = client
                .send_request(
                    Request::builder()
                        .uri("https://localhost/stream-credit")
                        .body(Body::empty())
                        .unwrap(),
                )
                .await
                .unwrap();
            if index < RETAINED {
                held.push(response);
            } else {
                assert_eq!(
                    response.into_body().collect().await.unwrap().to_bytes(),
                    "reusable"
                );
            }
        }
        assert!(pair.client.close_reason().is_none());
        let senders = serve.await.unwrap();
        drop(held);
        for sender in senders {
            sender.abort();
            _ = sender.await;
        }
        pair.client
            .close(Code::H3_NO_ERROR.value() as u32, b"complete");
        _ = client_driver.await.unwrap();
        _ = server_driver.await.unwrap();
        pair.close().await;
    })
    .await
    .unwrap();
}

#[tokio::test(start_paused = true)]
async fn memory_driver_drop_preserves_recorded_protocol_failure() {
    tokio::time::timeout(LIMIT, async {
        let pair = Pair::in_memory(None, None).await;
        let shared =
            Shared::from_connection(Config::default(), Role::Server, &pair.server).unwrap();
        let driver = Driver::new(pair.server.clone(), shared.clone(), Role::Server);
        shared.fail(Error::connection(
            Code::QPACK_DECOMPRESSION_FAILED,
            "malformed field section",
        ));
        // Abort the owner before run() gets another poll to deliver the error.
        drop(driver);
        let reason = pair.client.closed().await;
        assert_matches!(
            reason,
            rama_quic::ConnectionError::ApplicationClosed(close)
            if close.error_code.into_inner() == Code::QPACK_DECOMPRESSION_FAILED.value(),
        );
        pair.close().await;
    })
    .await
    .unwrap();
}

#[tokio::test(start_paused = true)]
async fn memory_graceful_drain_delivers_queued_response_before_close() {
    check_graceful_drain_delivers_queued_response_before_close(true).await;
}

#[tokio::test]
async fn graceful_drain_delivers_queued_response_before_close() {
    check_graceful_drain_delivers_queued_response_before_close(false).await;
}

async fn check_graceful_drain_delivers_queued_response_before_close(in_memory: bool) {
    tokio::time::timeout(LIMIT, async {
        let pair = pair(None, None, in_memory).await;
        let payload = Bytes::from(vec![0x5a; kib(128)]);
        let (mut client, client_driver) =
            client::handshake::<Body, _>(pair.client.clone(), Config::default(), Executor::new())
                .unwrap();
        let (mut server, server_driver) =
            server::handshake(pair.server.clone(), Config::default()).unwrap();
        let client_driver = spawn(client_driver.run());
        let server_driver = spawn(server_driver.run());
        let expected = payload.clone();
        let serve = spawn(async move {
            let (request, response) = server.accept().await.unwrap().resolve().await.unwrap();
            request.into_body().collect().await.unwrap();
            server.shutdown().unwrap();
            response
                .send_response(Response::new(Body::from(payload)))
                .await
                .unwrap();
            server.drained().await.unwrap();
            // The backend closes its driver immediately after drain. Merely
            // queueing FIN lets this discard data still waiting for QUIC credit.
            server_driver.abort();
            assert!(server_driver.await.unwrap_err().is_cancelled());
        });
        let response = client
            .send_request(
                Request::builder()
                    .uri("https://localhost/drain")
                    .body(Body::empty())
                    .unwrap(),
            )
            .await
            .unwrap();
        let received = response.into_body().collect().await.unwrap().to_bytes();
        assert_eq!(received, expected);
        serve.await.unwrap();
        client_driver.await.unwrap().unwrap();
        pair.close().await;
    })
    .await
    .unwrap();
}

#[tokio::test(start_paused = true)]
async fn memory_rejected_connect_preserves_response_and_connection() {
    tokio::time::timeout(LIMIT, async {
        let pair = Pair::in_memory(None, None).await;
        let (mut client, driver) =
            client::handshake::<Body, _>(pair.client.clone(), Config::default(), Executor::new())
                .unwrap();
        let (mut server, server_driver) =
            server::handshake(pair.server.clone(), Config::default()).unwrap();
        let driver = spawn(driver.run());
        let server_driver = spawn(server_driver.run());
        let serve = spawn(async move {
            let (request, response) = server.accept().await.unwrap().resolve().await.unwrap();
            assert_eq!(request.method(), Method::CONNECT);
            drop(request);
            response
                .send_response(
                    Response::builder()
                        .status(StatusCode::FORBIDDEN)
                        .body(Body::from("denied"))
                        .unwrap(),
                )
                .await
                .unwrap();
            let (request, response) = server.accept().await.unwrap().resolve().await.unwrap();
            request.into_body().collect().await.unwrap();
            response
                .send_response(Response::new(Body::from("recovered")))
                .await
                .unwrap();
        });
        let response = client
            .send_request(
                Request::builder()
                    .method(Method::CONNECT)
                    .uri(Uri::parse_http_request_target("localhost:443", true).unwrap())
                    .body(Body::empty())
                    .unwrap(),
            )
            .await
            .unwrap();
        assert_eq!(response.status(), StatusCode::FORBIDDEN);
        assert_eq!(
            response.into_body().collect().await.unwrap().to_bytes(),
            "denied"
        );
        let response = client
            .send_request(
                Request::builder()
                    .uri("https://localhost/recovered")
                    .body(Body::empty())
                    .unwrap(),
            )
            .await
            .unwrap();
        assert_eq!(
            response.into_body().collect().await.unwrap().to_bytes(),
            "recovered"
        );
        serve.await.unwrap();
        pair.client.close(Code::H3_NO_ERROR.value() as u32, b"done");
        driver.await.unwrap().unwrap();
        server_driver.await.unwrap().unwrap();
        pair.close().await;
    })
    .await
    .unwrap();
}
