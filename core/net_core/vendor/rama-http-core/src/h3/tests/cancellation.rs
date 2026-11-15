//! Cancellation across independent HTTP message directions and QPACK state.

use super::{LIMIT, Pair};
use crate::h3::{
    body, client,
    connection::{Config, Shared},
    control::Role,
    qpack::{Encoder, EncoderConfig},
    quic::Writer,
    server,
    stream::{Phase, Reader},
};
use rama_core::{
    bytes::{Bytes, BytesMut},
    futures::{FutureExt as _, stream},
    rt::{Executor, spawn},
};
use rama_http_types::{
    Body, Method, Request, Response, StatusCode,
    body::{Frame, util::BodyExt},
    proto::h3::{Code, FrameHeader, FrameType},
};
use rama_quic_proto::{TransportError, TransportErrorCode, VarInt};
use rama_utils::octets::kib;
use std::{convert::Infallible, future::poll_fn, sync::Arc, task::Poll, time::Duration};
use tokio::sync::{Semaphore, oneshot};

fn headers_frame(fields: &[u8]) -> Bytes {
    let mut wire = BytesMut::new();
    FrameHeader::new(FrameType::HEADERS, fields.len() as u64)
        .encode(&mut wire)
        .unwrap();
    wire.extend_from_slice(fields);
    wire.freeze()
}

#[tokio::test]
async fn abandoned_push_stream_releases_peer_qpack_sections_in_both_arrival_orders() {
    for cancel_before_stream in [false, true] {
        tokio::time::timeout(LIMIT, async {
            let pair = Pair::in_memory(None, None).await;
            let shared = Shared::new(Config::default(), Role::Client, Default::default()).unwrap();
            shared.pushes.lock().grant(0);
            let mut send = pair.server.open_uni().await.unwrap();
            let id = u64::from(send.id());
            let mut encoder = Encoder::new(EncoderConfig::default());
            let fields = encoder.encode(id, [("x-pushed", "retained")]).unwrap();
            assert_eq!(encoder.tracked_section_count(), 1);
            send.write_chunk(headers_frame(&fields)).await.unwrap();
            let recv = pair.client.accept_uni().await.unwrap();
            if cancel_before_stream {
                shared.cancel_push(0, true).unwrap();
            }
            shared.accept_push_stream(0, recv, Bytes::new()).unwrap();
            if !cancel_before_stream {
                shared.cancel_push(0, true).unwrap();
            }
            let feedback = shared.take_decoder_output().unwrap();
            assert!(!feedback.is_empty());
            encoder.feed_decoder_stream(&feedback).unwrap();
            assert_eq!(encoder.tracked_section_count(), 0);
            assert_eq!(
                send.stopped().await.unwrap().map(u64::from),
                Some(Code::H3_REQUEST_CANCELLED.value())
            );
            shared.cancel_push(0, true).unwrap();
            assert!(shared.take_decoder_output().unwrap().is_empty());
            pair.close().await;
        })
        .await
        .unwrap();
    }
}

/// A push stream must name a push this client granted (RFC 9114 §4.6), and only one stream may
/// carry each push.
#[tokio::test]
async fn push_streams_need_a_granted_unique_push_id() {
    tokio::time::timeout(LIMIT, async {
        let pair = Pair::in_memory(None, None).await;
        let shared = Shared::new(Config::default(), Role::Client, Default::default()).unwrap();
        shared.pushes.lock().grant(1);
        let mut streams = Vec::new();
        for _ in 0..3 {
            let send = pair.server.open_uni().await.unwrap();
            streams.push(send);
        }
        for send in &mut streams {
            send.write_chunk(Bytes::from_static(b"x")).await.unwrap();
        }
        let ungranted = pair.client.accept_uni().await.unwrap();
        let error = shared
            .accept_push_stream(2, ungranted, Bytes::new())
            .unwrap_err();
        assert_eq!(error.code(), Code::H3_ID_ERROR);
        let first = pair.client.accept_uni().await.unwrap();
        shared.accept_push_stream(1, first, Bytes::new()).unwrap();
        let duplicate = pair.client.accept_uni().await.unwrap();
        let error = shared
            .accept_push_stream(1, duplicate, Bytes::new())
            .unwrap_err();
        assert_eq!(error.code(), Code::H3_ID_ERROR);
        drop(streams);
        pair.close().await;
    })
    .await
    .unwrap();
}

#[tokio::test]
async fn dropping_unread_request_body_cancels_peer_qpack_sections() {
    tokio::time::timeout(LIMIT, async {
        let pair = Pair::in_memory(None, None).await;
        let shared = Shared::new(Config::default(), Role::Server, Default::default()).unwrap();
        let (mut send, response) = pair.client.open_bi().await.unwrap();
        let id = u64::from(send.id());
        let mut encoder = Encoder::new(EncoderConfig::default());
        let trailers = encoder.encode(id, [("x-trailer", "unread")]).unwrap();
        assert_eq!(encoder.tracked_section_count(), 1);
        send.write_chunk(headers_frame(&trailers)).await.unwrap();
        let (response_send, recv) = pair.server.accept_bi().await.unwrap();
        let mut reader = Reader::new(recv, shared.clone(), id);
        reader.phase = Phase::Body;
        let permit = Arc::new(Arc::new(Semaphore::new(1)).acquire_owned().await.unwrap());
        drop(body::Body::new(reader, None, permit));
        let feedback = shared.take_decoder_output().unwrap();
        assert!(!feedback.is_empty());
        encoder.feed_decoder_stream(&feedback).unwrap();
        assert_eq!(encoder.tracked_section_count(), 0);
        assert_eq!(
            send.stopped().await.unwrap().map(u64::from),
            Some(Code::H3_REQUEST_CANCELLED.value())
        );
        drop((response, response_send));
        pair.close().await;
    })
    .await
    .unwrap();
}

#[tokio::test]
async fn consuming_early_response_keeps_request_upload_alive() {
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
            let (request, response) = server.accept().await.unwrap().resolve().await.unwrap();
            response
                .send_response(Response::new(Body::empty()))
                .await
                .unwrap();
            assert_eq!(
                request.into_body().collect().await.unwrap().to_bytes(),
                "late upload"
            );
        });
        let (release_upload, upload_ready) = oneshot::channel();
        let frames = stream::once(async move {
            upload_ready.await.unwrap();
            Ok::<_, Infallible>(Frame::data(Bytes::from_static(b"late upload")))
        });
        let response = client
            .send_request(
                Request::builder()
                    .method(Method::POST)
                    .uri("https://localhost/upload")
                    .body(Body::from_frame_stream(frames))
                    .unwrap(),
            )
            .await
            .unwrap();
        assert!(
            response
                .into_body()
                .collect()
                .await
                .unwrap()
                .to_bytes()
                .is_empty()
        );
        release_upload.send(()).unwrap();
        serve.await.unwrap();
        pair.client.close(Code::H3_NO_ERROR.value() as u32, b"done");
        _ = client_driver.await;
        _ = server_driver.await;
        pair.close().await;
    })
    .await
    .unwrap();
}

#[tokio::test(start_paused = true)]
async fn local_reset_while_waiting_for_fin_ack_resolves_as_failure() {
    tokio::time::timeout(LIMIT, async {
        let pair = Pair::in_memory(None, None).await;
        let faults = pair.datagram_faults.clone().unwrap();
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
        let fields = encoder
            .encode(
                id,
                [
                    (":method", "POST"),
                    (":scheme", "https"),
                    (":authority", "localhost"),
                    (":path", "/"),
                    ("content-length", "1"),
                ],
            )
            .unwrap();
        writer.queue(FrameType::HEADERS, fields).unwrap();
        poll_fn(|cx| writer.poll_flush(cx)).await.unwrap();
        writer
            .queue(FrameType::DATA, Bytes::from_static(b"too long"))
            .unwrap();
        poll_fn(|cx| writer.poll_flush(cx)).await.unwrap();
        let (request, response) = server.accept().await.unwrap().resolve().await.unwrap();
        // Withhold client ACKs so the response FIN stays unacknowledged.
        faults[0].drop_next(usize::MAX);
        let sending = spawn(
            response.send_response(
                Response::builder()
                    .status(StatusCode::NO_CONTENT)
                    .body(Body::empty())
                    .unwrap(),
            ),
        );
        tokio::time::sleep(Duration::from_millis(1)).await;
        assert!(!sending.is_finished());
        // The malformed request body resets both directions via the abort handle.
        request.into_body().collect().await.unwrap_err();
        faults[0].drop_next(0);
        let error = tokio::time::timeout(Duration::from_secs(5), sending)
            .await
            .expect("local reset must wake the FIN acknowledgement waiter")
            .unwrap()
            .unwrap_err();
        assert_eq!(error.code(), Code::H3_MESSAGE_ERROR);
        assert!(!error.is_remote_failure());
        pair.client
            .close(Code::H3_NO_ERROR.value() as u32, b"complete");
        _ = client_driver.await;
        _ = server_driver.await;
        pair.close().await;
    })
    .await
    .unwrap();
}

#[tokio::test]
async fn dropping_complete_unpolled_bodyless_response_keeps_upload_alive() {
    tokio::time::timeout(LIMIT, async {
        let pair = Pair::in_memory(None, None).await;
        let (mut client, client_driver) =
            client::handshake::<Body, _>(pair.client.clone(), Config::default(), Executor::new())
                .unwrap();
        let (mut server, server_driver) =
            server::handshake(pair.server.clone(), Config::default()).unwrap();
        let client_driver = spawn(client_driver.run());
        let server_driver = spawn(server_driver.run());
        let (response_complete, response_acknowledged) = oneshot::channel();
        let serve = spawn(async move {
            let (request, response) = server.accept().await.unwrap().resolve().await.unwrap();
            response
                .send_response(
                    Response::builder()
                        .status(StatusCode::NO_CONTENT)
                        .body(Body::empty())
                        .unwrap(),
                )
                .await
                .unwrap();
            response_complete.send(()).unwrap();
            request
                .into_body()
                .collect()
                .await
                .map(|body| body.to_bytes())
        });
        let (release_upload, upload_ready) = oneshot::channel();
        let frames = stream::once(async move {
            upload_ready.await.unwrap();
            Ok::<_, Infallible>(Frame::data(Bytes::from_static(b"late upload")))
        });
        let response = client
            .send_request(
                Request::builder()
                    .method(Method::POST)
                    .uri("https://localhost/upload")
                    .body(Body::from_frame_stream(frames))
                    .unwrap(),
            )
            .await
            .unwrap();
        assert_eq!(response.status(), StatusCode::NO_CONTENT);
        // FIN acknowledgement proves arrival without consuming the response body.
        response_acknowledged.await.unwrap();
        drop(response);
        _ = release_upload.send(());
        let upload = serve.await.unwrap();
        pair.client.close(Code::H3_NO_ERROR.value() as u32, b"done");
        _ = client_driver.await;
        _ = server_driver.await;
        pair.close().await;
        assert_eq!(upload.unwrap(), "late upload");
    })
    .await
    .unwrap();
}

#[tokio::test(start_paused = true)]
async fn transport_no_error_preserves_finished_response_but_rejects_missing_fin() {
    for finish in [false, true] {
        tokio::time::timeout(LIMIT, async {
            let pair = Pair::in_memory(None, None).await;
            let (mut client, driver) = client::handshake::<Body, _>(
                pair.client.clone(),
                Config::default(),
                Executor::new(),
            )
            .unwrap();
            let driver = spawn(driver.run());
            let request = spawn(async move {
                client
                    .send_request(
                        Request::builder()
                            .uri("https://localhost/")
                            .body(Body::empty())
                            .unwrap(),
                    )
                    .await
                    .unwrap()
            });
            let (mut send, mut recv) = pair.server.accept_bi().await.unwrap();
            recv.read_to_end(kib(4)).await.unwrap();
            let mut encoder = Encoder::before_peer_settings(EncoderConfig::default());
            let fields = encoder
                .encode(0, [(":status", "200"), ("content-length", "4")])
                .unwrap();
            let mut bytes = BytesMut::new();
            bytes.extend_from_slice(&headers_frame(&fields));
            FrameHeader::new(FrameType::DATA, 4)
                .encode(&mut bytes)
                .unwrap();
            bytes.extend_from_slice(b"done");
            send.write_all(&bytes).await.unwrap();
            if finish {
                send.finish().unwrap();
                assert_eq!(send.stopped().await.unwrap(), None);
            }
            let response = request.await.unwrap();
            pair.server.close_transport(TransportError::new(
                TransportErrorCode::NO_ERROR,
                "complete",
            ));
            driver.await.unwrap().unwrap();
            let body = response.into_body().collect().await;
            if finish {
                assert_eq!(body.unwrap().to_bytes(), "done");
            } else {
                assert!(
                    body.is_err(),
                    "a clean transport close cannot substitute for FIN"
                );
            }
            pair.close().await;
        })
        .await
        .unwrap();
    }
}

#[tokio::test(start_paused = true)]
async fn bodyless_responses_retain_admission_until_fin_is_acknowledged() {
    for (method, status) in [
        (Method::HEAD, StatusCode::OK),
        (Method::GET, StatusCode::NO_CONTENT),
        (Method::GET, StatusCode::NOT_MODIFIED),
    ] {
        tokio::time::timeout(LIMIT, async {
            let pair = Pair::in_memory(None, None).await;
            let faults = pair.datagram_faults.clone().unwrap();
            let (mut client, client_driver) = client::handshake::<Body, _>(
                pair.client.clone(),
                Config::default(),
                Executor::new(),
            )
            .unwrap();
            let (mut server, server_driver) =
                server::handshake(pair.server.clone(), Config::default()).unwrap();
            let client_driver = spawn(client_driver.run());
            let server_driver = spawn(server_driver.run());
            let request = spawn(async move {
                client
                    .send_request(
                        Request::builder()
                            .method(method)
                            .uri("https://localhost/")
                            .body(Body::empty())
                            .unwrap(),
                    )
                    .await
                    .unwrap()
            });
            let (received, response) = server.accept().await.unwrap().resolve().await.unwrap();
            received.into_body().collect().await.unwrap();
            faults[0].drop_next(usize::MAX);
            let mut sending = Box::pin(
                response.send_response(
                    Response::builder()
                        .status(status)
                        .body(Body::empty())
                        .unwrap(),
                ),
            );
            assert!(poll_fn(|cx| Poll::Ready(sending.as_mut().poll(cx).is_pending())).await);
            let response = request.await.unwrap();
            // The client received the response, but none of its ACKs can reach the server.
            assert!(poll_fn(|cx| Poll::Ready(sending.as_mut().poll(cx).is_pending())).await);
            server.shutdown().unwrap();
            assert!(server.drained().now_or_never().is_none());
            faults[0].drop_next(0);
            sending.await.unwrap();
            server.drained().await.unwrap();
            drop(response);
            pair.client.close(Code::H3_NO_ERROR.value() as u32, b"done");
            _ = client_driver.await;
            _ = server_driver.await;
            pair.close().await;
        })
        .await
        .unwrap();
    }
}

#[tokio::test(start_paused = true)]
async fn explicit_response_reset_stops_upload_while_application_holds_body() {
    tokio::time::timeout(LIMIT, async {
        for code in [
            Code::H3_REQUEST_REJECTED,
            Code::H3_REQUEST_CANCELLED,
            Code::new(VarInt::MAX.into_inner()),
        ] {
            let pair = Pair::in_memory(None, None).await;
            let (mut server, driver) =
                server::handshake(pair.server.clone(), Config::default()).unwrap();
            spawn(driver.run());
            // Keep both upload and body open: dropping either must not be what
            // eventually delivers STOP_SENDING to the client.
            let (mut send, mut recv) = pair.client.open_bi().await.unwrap();
            let mut encoder = Encoder::before_peer_settings(EncoderConfig::default());
            let fields = encoder
                .encode(
                    u64::from(send.id()),
                    [
                        (":method", "POST"),
                        (":scheme", "https"),
                        (":authority", "localhost"),
                        (":path", "/reset"),
                    ],
                )
                .unwrap();
            send.write_chunk(headers_frame(&fields)).await.unwrap();
            let (request, response) = server.accept().await.unwrap().resolve().await.unwrap();
            response.reset(code).unwrap();
            assert_eq!(
                send.stopped().await.unwrap().map(u64::from),
                Some(code.value())
            );
            assert_eq!(
                recv.received_reset().await.unwrap().map(u64::from),
                Some(code.value())
            );
            assert!(pair.client.close_reason().is_none());
            drop(request);
            pair.close().await;
        }
    })
    .await
    .unwrap();
}
