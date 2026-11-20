//! Closing QUIC must not discard already received HTTP/3 control and QPACK state.

use super::{LIMIT, Pair};
use crate::h3::{
    Error, client,
    connection::{Config, Driver, Shared, initial_control},
    control::Role,
    observation::{FirstRequestObservation, H3Observer, SettingsObservation},
    qpack::{Encoder, EncoderConfig, ErrorScope},
};
use rama_core::{
    bytes::{Bytes, BytesMut},
    error::{BoxError, BoxErrorExt as _, error_chain},
    extensions::Extensions,
    futures::stream,
    rt::{Executor, spawn},
};
use rama_http::io::upgrade::handle_upgrade;
use rama_http_types::{
    Body, Method, Request,
    body::util::BodyExt as _,
    proto::h3::{Code, FrameHeader, FrameType, StreamType},
};
use rama_net::uri::Uri;
use rama_quic_proto::{MAX_STREAM_COUNT, VarInt, coding::Codec};
use std::{convert::Infallible, future::poll_fn, pin::pin, sync::Arc, task::Poll};
use tokio::time::Instant;
use tokio::{
    io::{AsyncReadExt as _, AsyncWriteExt as _},
    sync::oneshot,
};

#[tokio::test(start_paused = true)]
async fn memory_clean_close_drains_accepted_control_frames_before_terminal_notification() {
    for observation in [false, true] {
        for malformed in [false, true] {
            tokio::time::timeout(LIMIT, async {
                let pair = Pair::in_memory(None, None).await;
                let shared = Shared::from_connection(
                    Config {
                        observation: observation.then(Default::default),
                        ..Config::default()
                    },
                    Role::Client,
                    &pair.client,
                )
                .unwrap();
                let mut driver =
                    pin!(Driver::new(pair.client.clone(), shared.clone(), Role::Client).run());
                assert!(poll_fn(|cx| Poll::Ready(driver.as_mut().poll(cx).is_pending())).await);

                let mut control = pair.server.open_uni().await.unwrap();
                let mut bytes = BytesMut::from(
                    initial_control(&Config::default(), Role::Client, false)
                        .unwrap()
                        .as_ref(),
                );
                let first = VarInt::from_u64((MAX_STREAM_COUNT - 1) * 4).unwrap();
                FrameHeader::new(FrameType::GOAWAY, first.size() as u64)
                    .encode(&mut bytes)
                    .unwrap();
                first.encode(&mut bytes);
                control.write_all(&bytes).await.unwrap();
                // This barrier proves the driver accepted this control stream and owns
                // its parser before it is paused. A new accept cannot recreate it.
                poll_fn(|cx| {
                    assert!(driver.as_mut().poll(cx).is_pending());
                    if shared.goaway() == Some(first.into_inner()) {
                        Poll::Ready(())
                    } else {
                        Poll::Pending
                    }
                })
                .await;

                bytes.clear();
                for _ in 0..128 {
                    FrameHeader::new(FrameType::new(0x21), 0)
                        .encode(&mut bytes)
                        .unwrap();
                }
                if malformed {
                    FrameHeader::new(FrameType::DATA, 0)
                        .encode(&mut bytes)
                        .unwrap();
                } else {
                    FrameHeader::new(FrameType::GOAWAY, 1)
                        .encode(&mut bytes)
                        .unwrap();
                    VarInt::from_u32(0).encode(&mut bytes);
                }
                control.write_all(&bytes).await.unwrap();
                control.finish().unwrap();
                assert_eq!(control.stopped().await.unwrap(), None);
                // Leave a partially consumed chunk behind a cooperative yield.
                assert!(poll_fn(|cx| Poll::Ready(driver.as_mut().poll(cx).is_pending())).await);
                pair.server
                    .close(Code::H3_NO_ERROR.value() as u32, b"complete");
                pair.client.closed().await;
                let result = driver.await;
                if malformed {
                    let error = result.unwrap_err();
                    assert_eq!(error.code(), Code::H3_FRAME_UNEXPECTED);
                    assert!(error.is_remote_failure());
                } else {
                    result.unwrap();
                    assert_eq!(shared.goaway(), Some(0));
                    assert!(shared.rejected(Some(0)).await.is_rejected());
                }
                pair.close().await;
            })
            .await
            .unwrap();
        }
    }
}

#[tokio::test(start_paused = true)]
async fn memory_buffered_duplicate_critical_stream_outranks_clean_close() {
    for observation in [false, true] {
        tokio::time::timeout(LIMIT, async {
            let pair = Pair::in_memory(None, None).await;
            let shared = Shared::from_connection(
                Config {
                    observation: observation.then(Default::default),
                    ..Config::default()
                },
                Role::Client,
                &pair.client,
            )
            .unwrap();
            let mut driver =
                pin!(Driver::new(pair.client.clone(), shared.clone(), Role::Client).run());
            assert!(poll_fn(|cx| Poll::Ready(driver.as_mut().poll(cx).is_pending())).await);
            let mut control = pair.server.open_uni().await.unwrap();
            let mut bytes = BytesMut::from(
                initial_control(&Config::default(), Role::Server, false)
                    .unwrap()
                    .as_ref(),
            );
            FrameHeader::new(FrameType::GOAWAY, 1)
                .encode(&mut bytes)
                .unwrap();
            VarInt::from_u32(0).encode(&mut bytes);
            control.write_all(&bytes).await.unwrap();
            poll_fn(|cx| {
                assert!(driver.as_mut().poll(cx).is_pending());
                if shared.goaway() == Some(0) {
                    Poll::Ready(())
                } else {
                    Poll::Pending
                }
            })
            .await;

            // QUIC accepts these bytes while the H3 receive owner is paused.
            let mut duplicate = pair.server.open_uni().await.unwrap();
            duplicate.write_all(&[0]).await.unwrap();
            duplicate.finish().unwrap();
            assert_eq!(duplicate.stopped().await.unwrap(), None);
            pair.server
                .close(Code::H3_NO_ERROR.value() as u32, b"complete");
            pair.client.closed().await;
            let error = driver.await.unwrap_err();
            assert_eq!(error.code(), Code::H3_STREAM_CREATION_ERROR);
            assert!(error.is_remote_failure());
            pair.close().await;
        })
        .await
        .unwrap();
    }
}

#[tokio::test(start_paused = true)]
async fn memory_clean_close_drains_qpack_before_failing_missing_insert_waiters() {
    tokio::time::timeout(LIMIT, async {
        const READY: usize = 80;
        let pair = Pair::in_memory(None, None).await;
        let mut config = Config::default();
        config.decoder.max_decoder_stream_bytes = 10;
        config.decoder.max_blocked_streams = READY as u64 + 1;
        let shared = Shared::from_connection(config, Role::Client, &pair.client).unwrap();
        let mut driver = pin!(Driver::new(pair.client.clone(), shared.clone(), Role::Client).run());
        assert!(poll_fn(|cx| Poll::Ready(driver.as_mut().poll(cx).is_pending())).await);
        let mut encoder = Encoder::new(EncoderConfig::default());
        let fields = encoder.encode(0, [("x-buffered", "ready")]).unwrap();
        let instructions = encoder.take_encoder_stream();
        let missing = encoder
            .encode((READY * 4) as u64, [("x-buffered", "missing")])
            .unwrap();
        assert!(!encoder.take_encoder_stream().is_empty());
        let mut waiting = Vec::with_capacity(READY);
        for index in 0..READY {
            let mut decode = Box::pin(shared.decode((index * 4) as u64, fields.clone()));
            assert!(poll_fn(|cx| Poll::Ready(decode.as_mut().poll(cx).is_pending())).await);
            waiting.push(decode);
        }
        let missing_after_close = missing.clone();
        let mut missing = pin!(shared.decode((READY * 4) as u64, missing));
        assert!(poll_fn(|cx| Poll::Ready(missing.as_mut().poll(cx).is_pending())).await);

        let mut stream = pair.server.open_uni().await.unwrap();
        let mut bytes = BytesMut::new();
        VarInt::from_u64(StreamType::QPACK_ENCODER.value())
            .unwrap()
            .encode(&mut bytes);
        // End inside the first encoder instruction. The accepted future must
        // retain its decoder state while the remaining bytes arrive with close.
        bytes.extend_from_slice(&instructions[..1]);
        stream.write_all(&bytes).await.unwrap();
        assert!(poll_fn(|cx| Poll::Ready(driver.as_mut().poll(cx).is_pending())).await);
        stream.write_all(&instructions[1..]).await.unwrap();
        stream.finish().unwrap();
        assert_eq!(stream.stopped().await.unwrap(), None);
        pair.server
            .close(Code::H3_NO_ERROR.value() as u32, b"complete");
        pair.client.closed().await;
        driver.await.unwrap();
        for decode in waiting {
            let fields = decode.await.unwrap();
            assert_eq!(fields[0].value, "ready");
        }
        let error = missing.await.unwrap_err();
        assert_eq!(error.code(), Code::H3_REQUEST_INCOMPLETE);
        assert_eq!(error.scope(), ErrorScope::Stream);
        assert!(error.is_remote_failure());
        let error = shared
            .decode(((READY + 1) * 4) as u64, missing_after_close)
            .await
            .unwrap_err();
        assert_eq!(error.code(), Code::H3_REQUEST_INCOMPLETE);
        assert!(error.is_remote_failure());
        pair.close().await;
    })
    .await
    .unwrap();
}

#[tokio::test(start_paused = true)]
async fn memory_unknown_connection_codes_are_clean_and_keep_raw_diagnostics() {
    tokio::time::timeout(LIMIT, async {
        for code in [0, 0x21, 0x40, 0xdead] {
            let pair = Pair::in_memory(None, None).await;
            let shared =
                Shared::from_connection(Config::default(), Role::Client, &pair.client).unwrap();
            let mut driver =
                pin!(Driver::new(pair.client.clone(), shared.clone(), Role::Client).run());
            assert!(poll_fn(|cx| Poll::Ready(driver.as_mut().poll(cx).is_pending())).await);
            pair.server
                .close(VarInt::from_u32(code), b"extension close code");
            pair.client.closed().await;
            driver.await.unwrap();
            let error = shared.error().unwrap();
            assert_eq!(error.code(), Code::H3_NO_ERROR);
            assert_eq!(error.raw_code().value(), u64::from(code));
            assert!(!error.is_remote_failure());
            assert!(!error.is_rejected());
            pair.close().await;
        }
    })
    .await
    .unwrap();
}

#[tokio::test(start_paused = true)]
async fn memory_response_close_waits_for_buffered_goaway_before_classifying_rejection() {
    for method in [Method::GET, Method::POST, Method::CONNECT] {
        tokio::time::timeout(LIMIT, async {
            let pair = Pair::in_memory(None, None).await;
            let (mut client, driver) = client::handshake::<Body, _>(
                pair.client.clone(),
                Config::default(),
                Executor::new(),
            )
            .unwrap();
            let mut driver = pin!(driver.run());
            assert!(poll_fn(|cx| Poll::Ready(driver.as_mut().poll(cx).is_pending())).await);
            let uri = if method == Method::CONNECT {
                Uri::parse_http_request_target("localhost:443", true).unwrap()
            } else {
                Uri::try_from("https://localhost/rejected").unwrap()
            };
            let (body, upload_dropped) = if method == Method::POST {
                let (guard, dropped) = oneshot::channel::<()>();
                let body = Body::from_stream(stream::once(async move {
                    let _guard = guard;
                    std::future::pending::<Result<Bytes, Infallible>>().await
                }));
                (body, Some(dropped))
            } else {
                (Body::empty(), None)
            };
            let mut response = pin!(
                client.send_request(
                    Request::builder()
                        .method(method)
                        .uri(uri)
                        .body(body)
                        .unwrap()
                )
            );
            assert!(poll_fn(|cx| Poll::Ready(response.as_mut().poll(cx).is_pending())).await);
            let (_send, mut recv) = pair.server.accept_bi().await.unwrap();
            recv.read_chunk(4096, true).await.unwrap();
            let mut control = pair.server.open_uni().await.unwrap();
            let mut bytes = BytesMut::from(
                initial_control(&Config::default(), Role::Client, false)
                    .unwrap()
                    .as_ref(),
            );
            for _ in 0..128 {
                FrameHeader::new(FrameType::new(0x21), 0)
                    .encode(&mut bytes)
                    .unwrap();
            }
            FrameHeader::new(FrameType::GOAWAY, 1)
                .encode(&mut bytes)
                .unwrap();
            VarInt::from_u32(0).encode(&mut bytes);
            control.write_all(&bytes).await.unwrap();
            control.finish().unwrap();
            assert_eq!(control.stopped().await.unwrap(), None);
            pair.server
                .close(Code::H3_NO_ERROR.value() as u32, b"rejected all requests");
            pair.client.closed().await;
            if let Some(dropped) = upload_dropped {
                assert!(dropped.await.is_err());
            }
            // Let the request observe transport closure before its driver can
            // drain the control stream. It must wait rather than lose GOAWAY.
            assert!(poll_fn(|cx| Poll::Ready(response.as_mut().poll(cx).is_pending())).await);
            driver.await.unwrap();
            let error = response.await.unwrap_err();
            assert!(error.is_rejected());
            assert_eq!(error.scope(), ErrorScope::Stream);
            pair.close().await;
        })
        .await
        .unwrap();
    }
}

#[tokio::test(start_paused = true)]
async fn memory_response_failure_provenance_separates_peer_reset_from_application_body() {
    tokio::time::timeout(LIMIT, async {
        let pair = Pair::in_memory(None, None).await;
        let (mut client, driver) =
            client::handshake::<Body, _>(pair.client.clone(), Config::default(), Executor::new())
                .unwrap();
        let driver = spawn(driver.run());
        let remote_failure = spawn({
            let mut client = client.clone();
            async move {
                client
                    .send_request(
                        Request::builder()
                            .uri("https://localhost/reset")
                            .body(Body::empty())
                            .unwrap(),
                    )
                    .await
                    .unwrap_err()
            }
        });
        let (mut send, mut recv) = pair.server.accept_bi().await.unwrap();
        recv.read_to_end(4096).await.unwrap();
        send.reset(VarInt::from_u32(Code::H3_REQUEST_CANCELLED.value() as u32))
            .unwrap();
        let error = remote_failure.await.unwrap();
        assert_eq!(error.scope(), ErrorScope::Stream);
        assert!(error.is_remote_failure());

        let late_reset = spawn({
            let mut client = client.clone();
            async move {
                client
                    .send_request(
                        Request::builder()
                            .uri("https://localhost/late-reset")
                            .body(Body::empty())
                            .unwrap(),
                    )
                    .await
                    .unwrap()
            }
        });
        let (mut send, mut recv) = pair.server.accept_bi().await.unwrap();
        recv.read_to_end(4096).await.unwrap();
        let id = u64::from(send.id());
        let mut encoder = Encoder::new(EncoderConfig {
            max_table_capacity: 0,
            ..EncoderConfig::default()
        });
        let fields = encoder.encode(id, [(":status", "200")]).unwrap();
        let mut bytes = BytesMut::new();
        FrameHeader::new(FrameType::HEADERS, fields.len() as u64)
            .encode(&mut bytes)
            .unwrap();
        bytes.extend_from_slice(&fields);
        send.write_all(&bytes).await.unwrap();
        let mut body = late_reset.await.unwrap().into_body();
        send.reset(VarInt::from_u32(Code::H3_REQUEST_CANCELLED.value() as u32))
            .unwrap();
        let error = body.frame().await.unwrap().unwrap_err();
        let cause = error_chain(&error)
            .find_map(|cause| cause.downcast_ref::<Error>())
            .unwrap();
        assert_eq!(cause.scope(), ErrorScope::Stream);
        assert!(cause.is_remote_failure());

        let body = Body::from_stream(stream::once(async {
            Err::<Bytes, _>(BoxError::from_static_str("application body failed"))
        }));
        let error = client
            .send_request(
                Request::builder()
                    .method(Method::POST)
                    .uri("https://localhost/local-error")
                    .body(body)
                    .unwrap(),
            )
            .await
            .unwrap_err();
        assert_eq!(error.code(), Code::H3_INTERNAL_ERROR);
        assert!(!error.is_remote_failure());
        assert!(pair.client.close_reason().is_none());
        pair.client
            .close(Code::H3_NO_ERROR.value() as u32, b"complete");
        driver.await.unwrap().unwrap();
        pair.close().await;
    })
    .await
    .unwrap();
}

#[tokio::test(start_paused = true)]
async fn memory_received_body_length_and_trailer_errors_are_remote() {
    tokio::time::timeout(LIMIT, async {
        let pair = Pair::in_memory(None, None).await;
        let (client, driver) =
            client::handshake::<Body, _>(pair.client.clone(), Config::default(), Executor::new())
                .unwrap();
        let driver = spawn(driver.run());
        for (declared, bad_trailer) in [("0", false), ("2", false), ("1", true)] {
            let response = spawn({
                let mut client = client.clone();
                async move {
                    client
                        .send_request(
                            Request::builder()
                                .uri("https://localhost/malformed-body")
                                .body(Body::empty())
                                .unwrap(),
                        )
                        .await
                        .unwrap()
                }
            });
            let (mut send, mut recv) = pair.server.accept_bi().await.unwrap();
            recv.read_to_end(4096).await.unwrap();
            let id = u64::from(send.id());
            let mut encoder = Encoder::new(EncoderConfig {
                max_table_capacity: 0,
                ..EncoderConfig::default()
            });
            let fields = encoder
                .encode(id, [(":status", "200"), ("content-length", declared)])
                .unwrap();
            let mut bytes = BytesMut::new();
            FrameHeader::new(FrameType::HEADERS, fields.len() as u64)
                .encode(&mut bytes)
                .unwrap();
            bytes.extend_from_slice(&fields);
            FrameHeader::new(FrameType::DATA, 1)
                .encode(&mut bytes)
                .unwrap();
            bytes.extend_from_slice(b"x");
            if bad_trailer {
                let fields = encoder.encode(id, [("content-length", "0")]).unwrap();
                FrameHeader::new(FrameType::HEADERS, fields.len() as u64)
                    .encode(&mut bytes)
                    .unwrap();
                bytes.extend_from_slice(&fields);
            }
            send.write_all(&bytes).await.unwrap();
            send.finish().unwrap();
            assert_eq!(send.stopped().await.unwrap(), None);
            let error = response
                .await
                .unwrap()
                .into_body()
                .collect()
                .await
                .unwrap_err();
            let cause = error_chain(&error)
                .find_map(|cause| cause.downcast_ref::<Error>())
                .unwrap();
            assert_eq!(cause.code(), Code::H3_MESSAGE_ERROR);
            assert!(cause.is_remote_failure());
            assert!(pair.client.close_reason().is_none());
        }
        pair.client
            .close(Code::H3_NO_ERROR.value() as u32, b"complete");
        driver.await.unwrap().unwrap();
        pair.close().await;
    })
    .await
    .unwrap();
}

/// Trailers after fewer DATA bytes than the declared content-length end a malformed message: a
/// consumer that stops at the trailers, as a forwarding proxy does, must still see the error.
#[tokio::test(start_paused = true)]
async fn memory_trailers_after_a_short_body_are_malformed() {
    tokio::time::timeout(LIMIT, async {
        let pair = Pair::in_memory(None, None).await;
        let (client, driver) =
            client::handshake::<Body, _>(pair.client.clone(), Config::default(), Executor::new())
                .unwrap();
        let driver = spawn(driver.run());
        let response = spawn({
            let mut client = client.clone();
            async move {
                client
                    .send_request(
                        Request::builder()
                            .uri("https://localhost/short-body-trailers")
                            .body(Body::empty())
                            .unwrap(),
                    )
                    .await
                    .unwrap()
            }
        });
        let (mut send, mut recv) = pair.server.accept_bi().await.unwrap();
        recv.read_to_end(4096).await.unwrap();
        let id = u64::from(send.id());
        let mut encoder = Encoder::new(EncoderConfig {
            max_table_capacity: 0,
            ..EncoderConfig::default()
        });
        let fields = encoder
            .encode(id, [(":status", "200"), ("content-length", "2")])
            .unwrap();
        let mut bytes = BytesMut::new();
        FrameHeader::new(FrameType::HEADERS, fields.len() as u64)
            .encode(&mut bytes)
            .unwrap();
        bytes.extend_from_slice(&fields);
        FrameHeader::new(FrameType::DATA, 1)
            .encode(&mut bytes)
            .unwrap();
        bytes.extend_from_slice(b"x");
        let trailers = encoder.encode(id, [("x-checksum", "1")]).unwrap();
        FrameHeader::new(FrameType::HEADERS, trailers.len() as u64)
            .encode(&mut bytes)
            .unwrap();
        bytes.extend_from_slice(&trailers);
        send.write_all(&bytes).await.unwrap();
        send.finish().unwrap();

        let mut body = response.await.unwrap().into_body();
        let data = body.frame().await.unwrap().unwrap();
        assert_eq!(data.into_data().unwrap(), b"x"[..]);
        let error = body.frame().await.unwrap().unwrap_err();
        let cause = error_chain(&error)
            .find_map(|cause| cause.downcast_ref::<Error>())
            .unwrap();
        assert_eq!(cause.code(), Code::H3_MESSAGE_ERROR);
        assert!(cause.is_remote_failure());
        assert!(pair.client.close_reason().is_none());
        pair.client
            .close(Code::H3_NO_ERROR.value() as u32, b"complete");
        driver.await.unwrap().unwrap();
        pair.close().await;
    })
    .await
    .unwrap();
}

/// A retained CONNECT tunnel whose peer ended its stream, by FIN or by a reset without error,
/// and whose own end was acknowledged, frees its connection's only request slot.
#[tokio::test(start_paused = true)]
async fn memory_tunnels_ended_in_order_free_their_request_slot() {
    for reset in [false, true] {
        tokio::time::timeout(LIMIT, async {
            let pair = Pair::in_memory(None, None).await;
            let (client, driver) = client::handshake::<Body, _>(
                pair.client.clone(),
                Config {
                    max_requests: 1,
                    ..Config::default()
                },
                Executor::new(),
            )
            .unwrap();
            let driver = spawn(driver.run());
            let admission = client.connection_admission();
            let response = spawn({
                let mut client = client.clone();
                async move {
                    client
                        .send_request(
                            Request::builder()
                                .method(Method::CONNECT)
                                .uri(Uri::parse_authority_form("localhost:443").unwrap())
                                .body(Body::empty())
                                .unwrap(),
                        )
                        .await
                        .unwrap()
                }
            });
            let (mut send, mut recv) = pair.server.accept_bi().await.unwrap();
            let id = u64::from(send.id());
            let mut encoder = Encoder::new(EncoderConfig {
                max_table_capacity: 0,
                ..EncoderConfig::default()
            });
            let fields = encoder.encode(id, [(":status", "200")]).unwrap();
            let mut bytes = BytesMut::new();
            FrameHeader::new(FrameType::HEADERS, fields.len() as u64)
                .encode(&mut bytes)
                .unwrap();
            bytes.extend_from_slice(&fields);
            send.write_all(&bytes).await.unwrap();
            let response = response.await.unwrap();
            let mut tunnel = handle_upgrade(response).await.unwrap();
            assert!(admission.in_use(), "reset={reset}");
            // The 200 was delivered before the stream ends, so a reset cannot discard it.
            if reset {
                send.reset(VarInt::from_u32(Code::H3_NO_ERROR.value() as u32))
                    .unwrap();
            } else {
                send.finish().unwrap();
            }
            let mut rest = Vec::new();
            tunnel.read_to_end(&mut rest).await.unwrap();
            assert!(rest.is_empty(), "reset={reset}");
            tunnel.shutdown().await.unwrap();
            recv.read_to_end(4096).await.unwrap();
            assert!(!admission.in_use(), "reset={reset}");
            assert!(
                admission.try_acquire(&Extensions::new()).unwrap().is_some(),
                "reset={reset}: the next request is admitted"
            );
            drop(tunnel);
            drop(client);
            pair.close().await;
            _ = driver.await;
        })
        .await
        .unwrap();
    }
}

#[tokio::test(start_paused = true)]
async fn observation_settings_arriving_in_clean_close_drain_are_received() {
    tokio::time::timeout(LIMIT, async {
        let pair = Pair::in_memory(None, None).await;
        let shared = Shared::from_connection(
            Config {
                observation: Some(Default::default()),
                ..Config::default()
            },
            Role::Client,
            &pair.client,
        )
        .unwrap();
        let observer = H3Observer::new(&shared, Arc::new(Default::default()));
        let mut driver = pin!(Driver::new(pair.client.clone(), shared.clone(), Role::Client).run());
        assert!(poll_fn(|cx| Poll::Ready(driver.as_mut().poll(cx).is_pending())).await);
        let mut control = pair.server.open_uni().await.unwrap();
        control.write_all(&[0]).await.unwrap();
        poll_fn(|cx| {
            assert!(driver.as_mut().poll(cx).is_pending());
            if !observer.snapshot().streams.is_empty() {
                Poll::Ready(())
            } else {
                Poll::Pending
            }
        })
        .await;
        let mut waiting = pin!(observer.settings(Instant::now() + LIMIT));
        assert!(poll_fn(|cx| Poll::Ready(waiting.as_mut().poll(cx).is_pending())).await);
        control.write_all(&[4, 0]).await.unwrap();
        control.finish().unwrap();
        assert_eq!(control.stopped().await.unwrap(), None);
        pair.server.close(0u32, b"complete");
        pair.client.closed().await;
        let (result, observed) = tokio::join!(&mut driver, &mut waiting);
        result.unwrap();
        let SettingsObservation::Received(snapshot) = observed else {
            panic!("received SETTINGS must win the drain");
        };
        assert!(snapshot.completeness.settings);
        pair.close().await;
    })
    .await
    .unwrap();
}

#[tokio::test(start_paused = true)]
async fn memory_clean_close_publishes_buffered_first_request_before_terminal_notification() {
    tokio::time::timeout(LIMIT, async {
        let pair = Pair::in_memory(None, None).await;
        let shared = Shared::from_connection(
            Config {
                observation: Some(Default::default()),
                ..Config::default()
            },
            Role::Server,
            &pair.server,
        )
        .unwrap();
        let mut driver = pin!(Driver::new(pair.server.clone(), shared.clone(), Role::Server).run());
        assert!(poll_fn(|cx| Poll::Ready(driver.as_mut().poll(cx).is_pending())).await);
        let mut control = pair.client.open_uni().await.unwrap();
        let mut bytes = BytesMut::from(
            initial_control(&Config::default(), Role::Client, false)
                .unwrap()
                .as_ref(),
        );
        for _ in 0..128 {
            FrameHeader::new(FrameType::new(0x21), 0)
                .encode(&mut bytes)
                .unwrap();
        }
        control.write_all(&bytes).await.unwrap();
        control.finish().unwrap();
        // QUIC acknowledgment establishes that the full buffered prefix exists
        // before the paused HTTP/3 driver receives the terminal transport signal.
        assert_eq!(control.stopped().await.unwrap(), None);
        let (observer, first) = shared.request_observation(0, &[]).unwrap();
        assert!(first.first_request.get().is_none());
        let mut waiting = pin!(observer.first_request(Instant::now() + LIMIT));
        assert!(poll_fn(|cx| Poll::Ready(waiting.as_mut().poll(cx).is_pending())).await);
        pair.client.close(
            Code::H3_NO_ERROR.value() as u32,
            b"buffered prefix complete",
        );
        pair.server.closed().await;
        driver.await.unwrap();
        let FirstRequestObservation::Ready(snapshot) = waiting.await else {
            panic!("clean-close draining must publish buffered facts before final closure")
        };
        assert!(snapshot.settings_received && snapshot.completeness.control);
        assert_eq!(snapshot.control.len(), 129);
        assert!(Arc::ptr_eq(first.first_request.get().unwrap(), &snapshot));
        pair.close().await;
    })
    .await
    .unwrap();
}

#[tokio::test(start_paused = true)]
async fn buffered_server_request_racing_clean_close_is_rejected() {
    for request in [false, true] {
        for _ in 0..40 {
            tokio::time::timeout(LIMIT, async {
                let pair = Pair::in_memory(None, None).await;
                let shared =
                    Shared::from_connection(Config::default(), Role::Client, &pair.client).unwrap();
                let mut driver =
                    pin!(Driver::new(pair.client.clone(), shared.clone(), Role::Client).run());
                assert!(poll_fn(|cx| Poll::Ready(driver.as_mut().poll(cx).is_pending())).await);
                let mut control = pair.server.open_uni().await.unwrap();
                control
                    .write_all(&initial_control(&Config::default(), Role::Server, false).unwrap())
                    .await
                    .unwrap();
                let request_stream = if request {
                    let (mut send, recv) = pair.server.open_bi().await.unwrap();
                    send.write_all(b"request").await.unwrap();
                    send.finish().unwrap();
                    assert_eq!(send.stopped().await.unwrap(), None);
                    Some((send, recv))
                } else {
                    None
                };
                pair.server.close(Code::H3_NO_ERROR.value() as u32, b"done");
                pair.client.closed().await;
                let result = driver.await;
                if request {
                    assert_eq!(result.unwrap_err().code(), Code::H3_STREAM_CREATION_ERROR);
                } else {
                    result.unwrap();
                }
                drop(request_stream);
                pair.close().await;
            })
            .await
            .unwrap();
        }
    }
}
