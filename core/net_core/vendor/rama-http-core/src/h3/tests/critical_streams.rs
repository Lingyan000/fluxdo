//! Observe real peer streams, then exercise deferred compression in both directions.

use super::{LIMIT, Pair};
use crate::h3::{
    client,
    connection::{Config, initial_control},
    control::Role,
    observation::{H3Observer, SettingsObservation},
    server,
};
use rama_core::{
    bytes::Bytes,
    extensions::ExtensionsRef as _,
    rt::{Executor, spawn},
};
use rama_http_types::{
    Body, Request, Response,
    body::util::BodyExt as _,
    proto::h3::{
        Code, FrameType, PseudoHeader, StreamType,
        control::{ClientControlFrame, ClientControlPreferences},
        critical_streams::{Order, Preferences, Startup},
        observation::{FieldRepresentation, H3RequestObservation, ObservedEncoderInstruction},
        qpack::{
            FieldSectionBase,
            encoding::{FieldPreferences, HeaderPreferences, Representation},
        },
    },
};
use rama_quic::TransportConfig;
use rama_quic_proto::{Dir, Side, StreamId, VarInt};
use std::{
    collections::BTreeMap, future::poll_fn, pin::pin, sync::Arc, task::Poll, time::Duration,
};
use tokio::time::{Instant, timeout};

#[tokio::test(start_paused = true)]
async fn idle_prefixes_follow_startup_policy_and_reserved_stream_order() {
    for order in [Order::EncoderFirst, Order::DecoderFirst] {
        for (encoder, ordered_startup) in [
            (Startup::Immediate, false),
            (Startup::OnDemand, false),
            (Startup::Immediate, true),
            (Startup::OnDemand, true),
        ] {
            for decoder in [Startup::Immediate, Startup::OnDemand] {
                timeout(LIMIT, async {
                    let pair = Pair::in_memory(None, None).await;
                    let (_sender, driver) = client::handshake::<Body, _>(
                        pair.client.clone(),
                        Config {
                            critical_streams: Preferences {
                                order,
                                encoder,
                                decoder,
                                ordered_startup,
                            },
                            ..Config::default()
                        },
                        Executor::new(),
                    )
                    .unwrap();
                    let driver = spawn(driver.run());
                    let mut expected = BTreeMap::new();
                    expected.insert(
                        StreamId::new(Side::Client, Dir::Uni, 0),
                        StreamType::CONTROL.value(),
                    );
                    let entries = match order {
                        Order::EncoderFirst => [
                            (encoder, StreamType::QPACK_ENCODER),
                            (decoder, StreamType::QPACK_DECODER),
                        ],
                        Order::DecoderFirst => [
                            (decoder, StreamType::QPACK_DECODER),
                            (encoder, StreamType::QPACK_ENCODER),
                        ],
                    };
                    for (index, (startup, kind)) in entries.into_iter().enumerate() {
                        if startup == Startup::Immediate {
                            expected.insert(
                                StreamId::new(Side::Client, Dir::Uni, index as u64 + 1),
                                kind.value(),
                            );
                        }
                    }

                    let mut observed = BTreeMap::new();
                    let mut kept = Vec::new();
                    // A higher stream can implicitly open an earlier reserved ID.
                    // Keep those empty handles alive; accepting a handle alone is
                    // not evidence that its QPACK type was transmitted.
                    for index in 0..3 {
                        let incoming = if index == 0 {
                            Some(pair.server.accept_uni().await.unwrap())
                        } else {
                            timeout(Duration::from_millis(10), pair.server.accept_uni())
                                .await
                                .ok()
                                .map(Result::unwrap)
                        };
                        let Some(mut stream) = incoming else { break };
                        let mut kind = [0];
                        match timeout(Duration::from_millis(10), stream.read_exact(&mut kind)).await
                        {
                            Ok(Ok(())) => {
                                observed.insert(stream.id(), u64::from(kind[0]));
                            }
                            Ok(Err(error)) => {
                                panic!("critical stream ended before its type: {error:?}")
                            }
                            Err(_) => (),
                        }
                        kept.push(stream);
                    }
                    assert_eq!(observed, expected, "{order:?}/{encoder:?}/{decoder:?}");
                    pair.client.close(0u32, b"test complete");
                    _ = driver.await.unwrap();
                    drop(kept);
                    pair.close().await;
                })
                .await
                .unwrap();
            }
        }
    }
}

#[tokio::test(start_paused = true)]
async fn deferred_encoder_and_decoder_prefixes_follow_real_compression_work() {
    for order in [Order::EncoderFirst, Order::DecoderFirst] {
        timeout(LIMIT, async {
            let pair = Pair::in_memory(None, None).await;
            let config = Config {
                observation: Some(Default::default()),
                critical_streams: Preferences {
                    order,
                    encoder: Startup::OnDemand,
                    decoder: Startup::OnDemand,
                    ..Preferences::default()
                },
                ..Config::default()
            };
            let (mut server, driver) =
                server::handshake(pair.server.clone(), config.clone()).unwrap();
            let server_driver = spawn(driver.run());
            let (mut client, driver) =
                client::handshake::<Body, _>(pair.client.clone(), config, Executor::new()).unwrap();
            let client_driver = spawn(driver.run());
            client.peer_settings().await.unwrap();
            let serve = spawn(async move {
                let (request, response) = server.accept().await.unwrap().resolve().await.unwrap();
                assert_eq!(
                    request.headers()["x-profile-request"],
                    "dynamic request field"
                );
                let observer = request
                    .extensions()
                    .get_ref::<H3Observer>()
                    .unwrap()
                    .clone();
                assert!(matches!(
                    observer
                        .settings(Instant::now() + Duration::from_secs(1))
                        .await,
                    SettingsObservation::Received(_)
                ));
                let snapshot = observer.snapshot();
                assert!(
                    !snapshot.encoder_instructions.is_empty(),
                    "a static-only fallback must not make this test pass"
                );
                response
                    .send_response(
                        Response::builder()
                            .header("x-profile-reply", "dynamic response field")
                            .body(Body::from("reply"))
                            .unwrap(),
                    )
                    .await
                    .unwrap();
                observer
            });
            let response = client
                .send_request(
                    Request::builder()
                        .uri("https://localhost/profile")
                        .header("x-profile-request", "dynamic request field")
                        .body(Body::empty())
                        .unwrap(),
                )
                .await
                .unwrap();
            assert_eq!(
                response.headers()["x-profile-reply"],
                "dynamic response field"
            );
            assert_eq!(
                response.into_body().collect().await.unwrap().to_bytes(),
                "reply"
            );
            assert!(client.dynamic_insert_count() > 0);
            let observer = serve.await.unwrap();
            let snapshot = loop {
                let snapshot = observer.snapshot();
                if snapshot
                    .streams
                    .iter()
                    .any(|stream| stream.stream_type == StreamType::QPACK_DECODER.value())
                {
                    break snapshot;
                }
                tokio::time::sleep(Duration::from_millis(1)).await;
            };
            let (encoder_index, decoder_index) = match order {
                Order::EncoderFirst => (1, 2),
                Order::DecoderFirst => (2, 1),
            };
            for (kind, index) in [
                (StreamType::QPACK_ENCODER, encoder_index),
                (StreamType::QPACK_DECODER, decoder_index),
            ] {
                assert!(
                    snapshot
                        .streams
                        .iter()
                        .any(|stream| stream.stream_type == kind.value()
                            && stream.stream_id
                                == u64::from(StreamId::new(Side::Client, Dir::Uni, index)))
                );
            }
            pair.client.close(0u32, b"test complete");
            _ = client_driver.await.unwrap();
            _ = server_driver.await.unwrap();
            pair.close().await;
        })
        .await
        .unwrap();
    }
}

#[tokio::test(start_paused = true)]
async fn startup_priority_targets_respect_cumulative_peer_credit() {
    timeout(LIMIT, async {
        for limit in [1u32, 2] {
            let mut transport = TransportConfig::default();
            Config::default()
                .configure_transport(&mut transport)
                .unwrap();
            transport.set_max_concurrent_bidi_streams(limit);
            let pair = Pair::in_memory(None, Some(transport)).await;
            // An existing stream consumes opening credit, not the cumulative limit.
            let held = pair.client.open_bi().await.unwrap();
            assert_eq!(pair.client.available_streams(Dir::Bi), u64::from(limit - 1));
            let config = Config {
                client_control: Some(Arc::new(ClientControlPreferences {
                    frames: vec![ClientControlFrame::RequestPriority {
                        request: StreamId::new(Side::Client, Dir::Bi, 1),
                        value: Bytes::from_static(b"u=1"),
                    }]
                    .into(),
                })),
                ..Config::default()
            };
            let result = client::handshake::<Body, _>(pair.client.clone(), config, Executor::new());
            if limit == 1 {
                let error = result.unwrap_err();
                assert_eq!(error.code(), Code::H3_ID_ERROR);
            } else {
                let (_sender, _driver) = result.unwrap();
            }
            drop(held);
            pair.close().await;
        }
    })
    .await
    .unwrap();
}

#[tokio::test(start_paused = true)]
async fn request_base_preferences_reach_the_peer_without_changing_connection_defaults() {
    timeout(LIMIT, async {
        let pair = Pair::in_memory(None, None).await;
        let (mut server, driver) = server::handshake(
            pair.server.clone(),
            Config {
                observation: Some(Default::default()),
                ..Config::default()
            },
        )
        .unwrap();
        let server_driver = spawn(driver.run());
        let (mut client, driver) =
            client::handshake::<Body, _>(pair.client.clone(), Config::default(), Executor::new())
                .unwrap();
        let client_driver = spawn(driver.run());
        client.peer_settings().await.unwrap();
        let serve = spawn(async move {
            let mut representations = Vec::new();
            for _ in 0..2 {
                let (request, response) = server.accept().await.unwrap().resolve().await.unwrap();
                let observed = request
                    .extensions()
                    .get_ref::<H3RequestObservation>()
                    .unwrap();
                assert!(observed.fields_complete);
                representations.push(observed.fields.last().unwrap().representation);
                assert!(request.headers().contains_key("x-base-probe"));
                response
                    .send_response(Response::new(Body::empty()))
                    .await
                    .unwrap();
            }
            representations
        });
        for (index, value) in ["first value", "second value"].into_iter().enumerate() {
            let request = Request::builder()
                .uri("https://localhost/")
                .header("x-base-probe", value)
                .body(Body::empty())
                .unwrap();
            if index == 0 {
                request
                    .extensions()
                    .insert(FieldSectionBase::RequiredInsertCount);
            }
            client
                .send_request(request)
                .await
                .unwrap()
                .into_body()
                .collect()
                .await
                .unwrap();
        }
        let representations = serve.await.unwrap();
        pair.client.close(0u32, b"test complete");
        _ = client_driver.await.unwrap();
        _ = server_driver.await.unwrap();
        pair.close().await;
        assert_eq!(
            representations,
            [
                FieldRepresentation::DynamicIndex,
                FieldRepresentation::DynamicPostBaseIndex
            ]
        );
    })
    .await
    .unwrap();
}

#[tokio::test(start_paused = true)]
async fn field_preferences_reach_the_peer_and_do_not_leak_into_later_requests() {
    timeout(LIMIT, async {
        let pair = Pair::in_memory(None, None).await;
        let config = Config {
            observation: Some(Default::default()),
            ..Config::default()
        };
        let (mut server, driver) = server::handshake(pair.server.clone(), config).unwrap();
        let server_driver = spawn(driver.run());
        let (mut client, driver) =
            client::handshake::<Body, _>(pair.client.clone(), Config::default(), Executor::new())
                .unwrap();
        let client_driver = spawn(driver.run());
        client.peer_settings().await.unwrap();
        let plain = FieldPreferences {
            representation: Representation::LiteralName,
            name_huffman: Some(false),
            value_huffman: Some(false),
            ..FieldPreferences::default()
        };
        let serve = spawn(async move {
            let mut observations = Vec::new();
            for _ in 0..2 {
                let (request, sender) = server.accept().await.unwrap().resolve().await.unwrap();
                let observed = request
                    .extensions()
                    .get_ref::<H3RequestObservation>()
                    .unwrap();
                observations.push((
                    observed.fields.clone(),
                    request
                        .headers()
                        .get_all("x-policy")
                        .iter()
                        .map(|value| value.is_sensitive())
                        .collect::<Vec<_>>(),
                ));
                let response = Response::builder()
                    .header("x-reply-policy", "reply")
                    .body(Body::empty())
                    .unwrap();
                let mut preferences = HeaderPreferences::default();
                preferences.headers.append(
                    "x-reply-policy",
                    FieldPreferences {
                        never_index: true,
                        ..plain
                    },
                );
                response.extensions().insert(preferences);
                sender.send_response(response).await.unwrap();
            }
            observations
        });
        let mut responses = Vec::new();
        for index in 0..2 {
            let request = Request::builder()
                .uri("https://localhost/")
                .header("x-policy", "aaaaaaaaaaaa")
                .header("x-policy", "bbbbbbbbbbbb")
                .body(Body::empty())
                .unwrap();
            if index == 0 {
                let mut preferences = HeaderPreferences::default();
                preferences.pseudo_headers.insert(
                    PseudoHeader::Method,
                    FieldPreferences {
                        never_index: true,
                        ..plain
                    },
                );
                preferences.headers.append("x-policy", plain);
                preferences.headers.append(
                    "x-policy",
                    FieldPreferences {
                        value_huffman: Some(true),
                        never_index: true,
                        ..plain
                    },
                );
                request.extensions().insert(preferences);
            }
            let response = client.send_request(request).await.unwrap();
            responses.push(response.headers()["x-reply-policy"].is_sensitive());
            response.into_body().collect().await.unwrap();
        }
        let observations = serve.await.unwrap();
        pair.client.close(0u32, b"test complete");
        _ = client_driver.await.unwrap();
        _ = server_driver.await.unwrap();
        pair.close().await;
        assert_eq!(responses, [true, true]);
        let (first, sensitivity) = &observations[0];
        assert_eq!(sensitivity, &[false, true]);
        assert!(first[0].never_index);
        assert_eq!(first[0].representation, FieldRepresentation::LiteralName);
        let fields = &first[first.len() - 2..];
        assert!(
            fields
                .iter()
                .all(|f| f.representation == FieldRepresentation::LiteralName && !f.name_huffman)
        );
        assert!(!fields[0].value_huffman && fields[1].value_huffman);
        let (second, sensitivity) = &observations[1];
        assert_eq!(sensitivity, &[false, false]);
        assert_eq!(second[0].representation, FieldRepresentation::StaticIndex);
        assert!(!second[0].never_index);
        assert!(matches!(
            second.last().unwrap().representation,
            FieldRepresentation::DynamicIndex | FieldRepresentation::DynamicPostBaseIndex
        ));
    })
    .await
    .unwrap();
}

#[tokio::test(start_paused = true)]
async fn ordered_startup_records_control_then_immediate_prefixes_for_initial_fields() {
    for (order, dynamic) in [
        (Order::EncoderFirst, true),
        (Order::DecoderFirst, true),
        (Order::EncoderFirst, false),
        (Order::DecoderFirst, false),
    ] {
        timeout(LIMIT, async {
            let pair = Pair::in_memory(None, None).await;
            let startup = Preferences {
                order,
                ordered_startup: true,
                ..Preferences::default()
            };
            let (mut server, driver) = server::handshake(
                pair.server.clone(),
                Config {
                    observation: Some(Default::default()),
                    critical_streams: startup,
                    ..Config::default()
                },
            )
            .unwrap();
            let server_driver = spawn(driver.run());
            let (mut client, driver) = client::handshake::<Body, _>(
                pair.client.clone(),
                Config {
                    critical_streams: startup,
                    client_control: Some(Arc::new(ClientControlPreferences {
                        frames: vec![ClientControlFrame::Ignored {
                            frame_type: FrameType::FIRST_RESERVED,
                            payload: Bytes::from_static(b"test"),
                        }]
                        .into(),
                    })),
                    ..Config::default()
                },
                Executor::new(),
            )
            .unwrap();
            let client_driver = spawn(driver.run());
            let serve = spawn(async move {
                let (request, response) = server.accept().await.unwrap().resolve().await.unwrap();
                assert_eq!(request.headers()["x-startup"], "current request value");
                let observer = request.extensions().get_ref::<H3Observer>().unwrap();
                let snapshot = observer.snapshot();
                let types = match order {
                    Order::EncoderFirst => [
                        StreamType::CONTROL,
                        StreamType::QPACK_ENCODER,
                        StreamType::QPACK_DECODER,
                    ],
                    Order::DecoderFirst => [
                        StreamType::CONTROL,
                        StreamType::QPACK_DECODER,
                        StreamType::QPACK_ENCODER,
                    ],
                };
                // This asserts recorder processing order only. The separate raw
                // QUIC/tshark regression must establish actual transmission order.
                assert_eq!(snapshot.streams.len(), 3, "all immediate critical prefixes");
                for (index, (stream, kind)) in snapshot.streams.iter().zip(types).enumerate() {
                    assert_eq!(stream.stream_id, 2 + index as u64 * 4);
                    assert_eq!(stream.stream_type, kind.value());
                }
                assert_eq!(snapshot.control.len(), 2);
                assert_eq!(snapshot.control[0].frame_type, FrameType::SETTINGS.value());
                assert_eq!(
                    snapshot.control[1].frame_type,
                    FrameType::FIRST_RESERVED.value()
                );
                assert_eq!(snapshot.control[1].length, 4);
                assert!(snapshot.streams[0].sequence < snapshot.control[0].sequence);
                assert!(snapshot.control[0].sequence < snapshot.control[1].sequence);
                assert!(snapshot.control[1].sequence < snapshot.streams[1].sequence);
                assert!(snapshot.streams[1].sequence < snapshot.streams[2].sequence);
                if dynamic {
                    assert!(matches!(snapshot.encoder_instructions.first(), Some(ObservedEncoderInstruction::Capacity {capacity}) if *capacity == Config::default().encoder.max_table_capacity), "first encoder instruction must be the configured capacity, not a duplicate type prefix");
                } else {
                    assert!(snapshot.encoder_instructions.is_empty(), "literal first head must not insert fields");
                }
                response
                    .send_response(Response::new(Body::empty()))
                    .await
                    .unwrap();
            });
            let request = Request::builder()
                .uri("https://localhost/startup")
                .header("x-startup", "current request value")
                .body(Body::empty())
                .unwrap();
            let mut fields = HeaderPreferences::default();
            fields.headers.append(
                "x-startup",
                FieldPreferences {
                    representation: if dynamic { Representation::DynamicIndexBeforeBase } else { Representation::LiteralName },
                    ..FieldPreferences::default()
                },
            );
            for pseudo in [PseudoHeader::Method, PseudoHeader::Scheme, PseudoHeader::Authority, PseudoHeader::Path] {
                fields.pseudo_headers.insert(pseudo, FieldPreferences {representation: Representation::LiteralName, ..FieldPreferences::default()});
            }
            request.extensions().insert(fields);
            request
                .extensions()
                .insert(FieldSectionBase::FromFieldPreferences);
            client
                .send_request(request)
                .await
                .unwrap()
                .into_body()
                .collect()
                .await
                .unwrap();
            serve.await.unwrap();
            pair.client.close(0u32, b"test complete");
            _ = client_driver.await.unwrap();
            _ = server_driver.await.unwrap();
            pair.close().await;
        })
        .await
        .unwrap();
    }
}

#[tokio::test(start_paused = true)]
async fn ordered_startup_keeps_peer_settings_live_and_cancellation_before_request_open() {
    for (ordered_startup, dynamic) in [(true, true), (true, false), (false, false)] {
        timeout(LIMIT, async {
            let mut remote = TransportConfig::default();
            Config::default().configure_transport(&mut remote).unwrap();
            remote.set_stream_receive_window(VarInt::from_u32(32));
            let pair = Pair::in_memory(None, Some(remote)).await;
            let (mut client, driver) = client::handshake::<Body, _>(
                pair.client.clone(),
                Config {
                    critical_streams: Preferences { ordered_startup, ..Preferences::default() },
                    client_control: Some(Arc::new(ClientControlPreferences {
                        frames: vec![ClientControlFrame::Ignored {
                            frame_type: FrameType::FIRST_RESERVED,
                            payload: Bytes::from(vec![0; 256]),
                        }].into(),
                    })),
                    ..Config::default()
                },
                Executor::new(),
            ).unwrap();
            let driver = spawn(driver.run());
            // Leave our CONTROL unread: its 32-byte transport credit holds
            // ordered initialization while independent peer SETTINGS arrive.
            let mut peer_control = pair.server.open_uni().await.unwrap();
            peer_control.write_all(&initial_control(&Config::default(), Role::Server, false).unwrap()).await.unwrap();
            client.peer_settings().await.unwrap();
            {
                let request = Request::builder().uri("https://localhost/startup").header("x-startup", "current").body(Body::empty()).unwrap();
                let literal = FieldPreferences {representation: Representation::LiteralName, ..FieldPreferences::default()};
                let mut preferences = HeaderPreferences::default();
                preferences.headers.append("x-startup", if dynamic {FieldPreferences {representation: Representation::DynamicIndexBeforeBase, ..FieldPreferences::default()}} else {literal});
                for pseudo in [PseudoHeader::Method, PseudoHeader::Scheme, PseudoHeader::Authority, PseudoHeader::Path] {
                    preferences.pseudo_headers.insert(pseudo, literal);
                }
                request.extensions().insert(preferences);
                request.extensions().insert(FieldSectionBase::FromFieldPreferences);
                let mut sending = pin!(client.send_request(request));
                poll_fn(|cx| { assert!(sending.as_mut().poll(cx).is_pending()); Poll::Ready(()) }).await;
                let opened = timeout(Duration::from_millis(10), pair.server.accept_bi()).await;
                if ordered_startup {
                    assert!(opened.is_err(), "ordered request must not open before local startup completes; dynamic={dynamic}");
                } else {
                    assert!(opened.is_ok(), "default literal admission must retain its independent pre-startup behavior");
                }
                // Dropping the pending send cancels admission; opted-in cases
                // have not opened a request stream or consumed its peer credit.
            }
            pair.client.close(0u32, b"test cancellation");
            _ = driver.await.unwrap();
            drop(peer_control);
            pair.close().await;
        }).await.unwrap();
    }
}
