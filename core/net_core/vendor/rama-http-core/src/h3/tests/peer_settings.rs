use std::{pin::pin, sync::Arc, time::Duration};

use rama_core::{
    extensions::ExtensionsRef as _,
    rt::{Executor, spawn},
};
use rama_http_types::{
    Body, Request, Response,
    proto::h3::{
        Code, FrameHeader, FrameType, SettingId, Settings, StreamType,
        qpack::instruction::EncoderInstruction,
    },
};

use super::{LIMIT, Pair};
use crate::h3::{
    Error, client,
    connection::{Config, initial_control},
    control::Role,
    observation::{H3Observer, SettingsObservation},
    server,
};
use rama_quic::{Connection as QuicConnection, StoppedError};
use rama_quic_proto::{VarInt, coding::Codec as _};
use tokio::time::Instant;

fn config() -> Config {
    let mut config = Config::default();
    let mut settings = Settings::new();
    for (id, value) in [
        (SettingId::FIRST_RESERVED, 17),
        (
            SettingId::QPACK_BLOCKED_STREAMS,
            config.decoder.max_blocked_streams,
        ),
        (SettingId::new(0xface), 29),
        (SettingId::H3_DATAGRAM, 1),
        (
            SettingId::QPACK_MAX_TABLE_CAPACITY,
            config.decoder.max_table_capacity,
        ),
    ] {
        settings.set(id, value).unwrap();
    }
    config.settings_profile = Some(Arc::new(settings));
    config
}

async fn read(
    server_waits: bool,
    client: &client::SendRequest<Body, QuicConnection>,
    server: &server::Connection<QuicConnection>,
) -> Result<Settings, Error> {
    if server_waits {
        server.peer_settings().await
    } else {
        client.peer_settings().await
    }
}

#[tokio::test(start_paused = true)]
async fn peer_settings_snapshot_waits_preserves_order_and_survives_cancelled_waiter() {
    tokio::time::timeout(LIMIT, async {
        for server_waits in [false, true] {
            let pair = Pair::in_memory(None, None).await;
            let config = config();
            assert!(config.observation.is_none());
            let expected = config.settings_profile.as_ref().unwrap().entries().to_vec();
            let (client, client_driver) =
                client::handshake::<Body, _>(pair.client.clone(), config.clone(), Executor::new())
                    .unwrap();
            let (server, server_driver) = server::handshake(pair.server.clone(), config).unwrap();
            let (local, peer) = if server_waits {
                (server_driver, client_driver)
            } else {
                (client_driver, server_driver)
            };
            spawn(local.run());
            tokio::time::timeout(
                Duration::from_millis(1),
                read(server_waits, &client, &server),
            )
            .await
            .unwrap_err();
            spawn(peer.run());
            let (first, second) = tokio::join!(
                read(server_waits, &client, &server),
                read(server_waits, &client, &server),
            );
            assert_eq!(first.unwrap().entries(), expected);
            assert_eq!(second.unwrap().entries(), expected);
            pair.close().await;
        }
    })
    .await
    .unwrap();
}

#[tokio::test(start_paused = true)]
async fn peer_settings_snapshot_wakes_on_close_before_settings() {
    tokio::time::timeout(LIMIT, async {
        for server_waits in [false, true] {
            let pair = Pair::in_memory(None, None).await;
            let (client, client_driver) = client::handshake::<Body, _>(
                pair.client.clone(),
                Config::default(),
                Executor::new(),
            )
            .unwrap();
            let (server, server_driver) =
                server::handshake(pair.server.clone(), Config::default()).unwrap();
            if server_waits {
                spawn(server_driver.run());
                pair.client.close(0u32, b"no settings");
                drop(client_driver);
            } else {
                spawn(client_driver.run());
                pair.server.close(0u32, b"no settings");
                drop(server_driver);
            }
            read(server_waits, &client, &server).await.unwrap_err();
            pair.close().await;
        }
    })
    .await
    .unwrap();
}

#[tokio::test(start_paused = true)]
async fn receive_settings_unpolled_future_and_unfinished_owner_close_the_native_peer() {
    tokio::time::timeout(LIMIT, async {
        for read_first in [false, true] {
            let pair = Pair::in_memory(None, None).await;
            let config = Config {
                datagrams: None,
                ..Config::default()
            };
            let future = server::receive_settings(pair.server.clone(), &config);
            let mut client_owner = None;
            if read_first {
                let (client, driver) = client::handshake::<Body, _>(
                    pair.client.clone(),
                    config.clone(),
                    Executor::new(),
                )
                .unwrap();
                client_owner = Some(client);
                spawn(driver.run());
                drop(future.await.unwrap());
            } else {
                // Constructing then dropping must arm cleanup without polling.
                drop(future);
            }
            let closed = tokio::time::timeout(Duration::from_secs(1), pair.client.closed()).await;
            assert!(
                closed.is_ok(),
                "dropping readiness did not close the actual native peer"
            );
            assert_eq!(
                Error::from_transport(&closed.unwrap()).code(),
                Code::H3_INTERNAL_ERROR
            );
            drop(client_owner);
            pair.close().await;
        }
    })
    .await
    .unwrap();
}

#[tokio::test(start_paused = true)]
async fn receive_settings_defers_output_and_finishes_with_one_observed_settings_event() {
    tokio::time::timeout(LIMIT, async {
        let pair = Pair::in_memory(None, None).await;
        let config = Config {
            datagrams: None,
            observation: Some(Default::default()),
            ..Config::default()
        };
        let mut literal = Settings::new();
        literal.set(SettingId::FIRST_RESERVED, 17).unwrap();
        literal
            .set(SettingId::MAX_FIELD_SECTION_SIZE, 65536)
            .unwrap();
        literal.set(SettingId::QPACK_BLOCKED_STREAMS, 16).unwrap();
        literal
            .set(SettingId::QPACK_MAX_TABLE_CAPACITY, 4096)
            .unwrap();
        let client_config = config
            .try_with_client_settings(Arc::new(literal.clone()))
            .unwrap();
        let (mut client, driver) =
            client::handshake::<Body, _>(pair.client.clone(), client_config, Executor::new())
                .unwrap();
        spawn(driver.run());
        let received = server::receive_settings(pair.server.clone(), &config)
            .await
            .unwrap();
        assert_eq!(received.peer_settings(), &literal);
        assert!(
            tokio::time::timeout(Duration::from_millis(1), client.peer_settings())
                .await
                .is_err(),
            "staged server emitted local SETTINGS before final configuration"
        );
        let mut final_config = config;
        final_config.decoder.max_field_section_size = 1024;
        let (mut server, driver) = received.into_connection(final_config).unwrap();
        spawn(driver.run());
        assert_eq!(
            client
                .peer_settings()
                .await
                .unwrap()
                .max_field_section_size(),
            Some(1024)
        );
        let serving = spawn(async move {
            let (request, response) = server.accept().await.unwrap().resolve().await.unwrap();
            let observer = request.extensions().get_ref::<H3Observer>().unwrap();
            let SettingsObservation::Received(snapshot) = observer
                .settings(Instant::now() + Duration::from_secs(1))
                .await
            else {
                panic!("staged settings observation unavailable");
            };
            assert_eq!(snapshot.settings.as_ref().unwrap().len(), literal.len());
            assert_eq!(
                snapshot
                    .control
                    .iter()
                    .filter(|event| event.frame_type == FrameType::SETTINGS.value())
                    .count(),
                1,
                "staged peer SETTINGS must be observed once"
            );
            response
                .send_response(Response::new(Body::empty()))
                .await
                .unwrap();
        });
        client
            .send_request(
                Request::builder()
                    .uri("https://localhost/")
                    .body(Body::empty())
                    .unwrap(),
            )
            .await
            .unwrap();
        serving.await.unwrap();
        pair.close().await;
    })
    .await
    .unwrap();
}

#[tokio::test(start_paused = true)]
async fn receive_settings_retains_partial_type_and_buffered_duplicate_settings() {
    tokio::time::timeout(LIMIT, async {
        let pair = Pair::in_memory(None, None).await;
        let config = Config {
            datagrams: None,
            ..Config::default()
        };
        let mut encoder = pair.client.open_uni().await.unwrap();
        // A valid nonminimal two-byte QPACK stream type, split before its last byte.
        encoder.write_all(&[0x40]).await.unwrap();
        let mut decoder = pair.client.open_uni().await.unwrap();
        decoder
            .write_all(&[StreamType::QPACK_DECODER.value() as u8])
            .await
            .unwrap();
        let mut control = pair.client.open_uni().await.unwrap();
        let mut bytes = initial_control(&config, Role::Client, false)
            .unwrap()
            .to_vec();
        let duplicate = FrameHeader::new(FrameType::SETTINGS, 0);
        duplicate.encode(&mut bytes).unwrap();
        let sending = spawn(async move {
            control.write_all(&bytes[..2]).await.unwrap();
            control.write_all(&bytes[2..]).await.unwrap();
            // Retain the stream until the server has diagnosed duplicate SETTINGS.
            control.stopped().await
        });
        let received = server::receive_settings(pair.server.clone(), &config)
            .await
            .unwrap();
        assert!(
            tokio::time::timeout(Duration::from_millis(1), pair.client.accept_uni())
                .await
                .is_err(),
            "pre-read emitted a native local critical stream"
        );
        let (_server, driver) = received.into_connection(config).unwrap();
        spawn(driver.run());
        let closed = tokio::time::timeout(Duration::from_secs(1), pair.client.closed()).await;
        assert!(
            closed.is_ok(),
            "buffered duplicate SETTINGS disappeared at native handoff"
        );
        assert_eq!(
            Error::from_transport(&closed.unwrap()).code(),
            Code::H3_FRAME_UNEXPECTED
        );
        let _stopped = sending.await.unwrap();
        pair.close().await;
    })
    .await
    .unwrap();
}

#[tokio::test(start_paused = true)]
async fn receive_settings_rejects_changed_parser_envelope_before_local_output() {
    tokio::time::timeout(LIMIT, async {
        for changed in ["chunk", "frame", "pending"] {
            let pair = Pair::in_memory(None, None).await;
            let config = Config {
                datagrams: None,
                ..Config::default()
            };
            let (client, driver) =
                client::handshake::<Body, _>(pair.client.clone(), config.clone(), Executor::new())
                    .unwrap();
            spawn(driver.run());
            let received = server::receive_settings(pair.server.clone(), &config)
                .await
                .unwrap();
            let mut incompatible = config;
            match changed {
                "chunk" => incompatible.read_chunk_size /= 2,
                "frame" => incompatible.max_frame_size /= 2,
                "pending" => incompatible.max_pending_uni_streams /= 2,
                _ => unreachable!(),
            }
            assert!(
                received.into_connection(incompatible).is_err(),
                "accepted changed {changed} parser envelope"
            );
            assert_eq!(
                Error::from_transport(&pair.client.closed().await).code(),
                Code::H3_INTERNAL_ERROR
            );
            assert!(
                pair.client.accept_uni().await.is_err(),
                "failed finish emitted local SETTINGS"
            );
            drop(client);
            pair.close().await;
        }
    })
    .await
    .unwrap();
}

#[tokio::test(start_paused = true)]
async fn receive_settings_retains_a_partially_read_critical_stream_type() {
    tokio::time::timeout(LIMIT, async {
        let pair = Pair::in_memory(None, None).await;
        let config = Config {
            datagrams: None,
            ..Config::default()
        };
        let mut encoder = pair.client.open_uni().await.unwrap();
        // Preserve the first half of a four-byte encoding of stream type 2.
        encoder.write_all(&[0x80, 0]).await.unwrap();
        let mut control = pair.client.open_uni().await.unwrap();
        let bytes = initial_control(&config, Role::Client, false).unwrap();
        let sending = spawn(async move {
            control.write_all(&bytes).await.unwrap();
            control.stopped().await
        });
        let received = server::receive_settings(pair.server.clone(), &config)
            .await
            .unwrap();
        let oversized_capacity = config.decoder.max_table_capacity + 1;
        let (_server, driver) = received.into_connection(config).unwrap();
        spawn(driver.run());
        let mut suffix = vec![0, StreamType::QPACK_ENCODER.value() as u8];
        EncoderInstruction::SetDynamicTableCapacity {
            capacity: oversized_capacity,
        }
        .encode(&mut suffix);
        let written = encoder.write_all(&suffix).await;
        assert!(
            written.is_ok(),
            "staged QPACK stream was stopped instead of resumed"
        );
        let closed = tokio::time::timeout(Duration::from_secs(1), pair.client.closed()).await;
        assert!(
            closed.is_ok(),
            "partial QPACK prefix or following instruction disappeared at handoff"
        );
        assert_eq!(
            Error::from_transport(&closed.unwrap()).code(),
            Code::QPACK_ENCODER_STREAM_ERROR,
            "a retained prefix must reach the QPACK decoder, not become a duplicate CONTROL stream"
        );
        let _stopped = sending.await.unwrap();
        pair.close().await;
    })
    .await
    .unwrap();
}

#[tokio::test(start_paused = true)]
async fn receive_settings_preserves_native_role_frame_and_pending_stream_errors() {
    tokio::time::timeout(LIMIT, async {
        for (case, expected) in [
            ("duplicate control", Code::H3_STREAM_CREATION_ERROR),
            ("client push", Code::H3_STREAM_CREATION_ERROR),
            ("invalid boolean", Code::H3_SETTINGS_ERROR),
            ("frame budget", Code::H3_EXCESSIVE_LOAD),
            ("settings count", Code::H3_EXCESSIVE_LOAD),
            ("pending stream budget", Code::H3_EXCESSIVE_LOAD),
        ] {
            let pair = Pair::in_memory(None, None).await;
            let mut config = Config {
                datagrams: None,
                ..Config::default()
            };
            let mut streams = Vec::new();
            match case {
                "duplicate control" => {
                    for _ in 0..2 {
                        let mut stream = pair.client.open_uni().await.unwrap();
                        stream
                            .write_all(&[StreamType::CONTROL.value() as u8])
                            .await
                            .unwrap();
                        streams.push(stream);
                    }
                }
                "client push" => {
                    let mut stream = pair.client.open_uni().await.unwrap();
                    stream
                        .write_all(&[StreamType::PUSH.value() as u8])
                        .await
                        .unwrap();
                    streams.push(stream);
                }
                "pending stream budget" => {
                    config.max_pending_uni_streams = 3;
                    for _ in 0..4 {
                        let mut stream = pair.client.open_uni().await.unwrap();
                        // Start an eight-byte type without completing it.
                        stream.write_all(&[0xc0]).await.unwrap();
                        streams.push(stream);
                    }
                }
                _ => {
                    let mut bytes = vec![StreamType::CONTROL.value() as u8];
                    let mut payload = Vec::new();
                    if case == "invalid boolean" {
                        VarInt::from_u32(SettingId::ENABLE_CONNECT_PROTOCOL.value() as u32)
                            .encode(&mut payload);
                        VarInt::from_u32(2).encode(&mut payload);
                    } else {
                        let mut settings = Settings::new();
                        let count = if case == "settings count" { 33 } else { 2 };
                        for ordinal in 0..count {
                            settings.set(SettingId::reserved(ordinal), 1).unwrap();
                        }
                        settings.encode_payload(&mut payload).unwrap();
                        if case == "frame budget" {
                            config.max_frame_size = 1;
                        }
                    }
                    FrameHeader::new(FrameType::SETTINGS, payload.len() as u64)
                        .encode(&mut bytes)
                        .unwrap();
                    bytes.extend_from_slice(&payload);
                    let mut stream = pair.client.open_uni().await.unwrap();
                    stream.write_all(&bytes).await.unwrap();
                    streams.push(stream);
                }
            }
            let readiness = tokio::time::timeout(
                Duration::from_secs(1),
                server::receive_settings(pair.server.clone(), &config),
            )
            .await;
            assert!(
                readiness.is_ok(),
                "invalid {case} was not diagnosed within readiness"
            );
            let error = readiness.unwrap().unwrap_err();
            assert_eq!(
                error.code(),
                expected,
                "wrong native readiness error for {case}"
            );
            assert_eq!(
                Error::from_transport(&pair.client.closed().await).code(),
                expected,
                "peer close lost the native readiness error for {case}"
            );
            assert!(
                pair.client.accept_uni().await.is_err(),
                "invalid {case} emitted local HTTP/3 output"
            );
            drop(streams);
            pair.close().await;
        }
    })
    .await
    .unwrap();
}

#[tokio::test(start_paused = true)]
async fn receive_settings_cancellation_closes_before_stopping_partial_control() {
    tokio::time::timeout(LIMIT, async {
        let pair = Pair::in_memory(None, None).await;
        let config = Config { datagrams: None, ..Config::default() };
        let mut control = pair.client.open_uni().await.unwrap();
        let bytes = initial_control(&config, Role::Client, false).unwrap();
        // Deliver CONTROL and the SETTINGS type, withholding its length/payload.
        control.write_all(&bytes[..2]).await.unwrap();
        {
            let mut reading = pin!(server::receive_settings(pair.server.clone(), &config));
            let stalled = tokio::time::timeout(Duration::from_millis(1), reading.as_mut()).await;
            assert!(stalled.is_err(), "partial CONTROL unexpectedly completed SETTINGS");
        }
        let closed = tokio::time::timeout(Duration::from_secs(1), pair.client.closed()).await;
        assert!(closed.is_ok(), "cancelling partial CONTROL left its connection alive");
        assert_eq!(Error::from_transport(&closed.unwrap()).code(), Code::H3_INTERNAL_ERROR);
        let stopped = control.stopped().await;
        assert!(matches!(stopped, Err(StoppedError::ConnectionLost(_))),
            "partial CONTROL was independently stopped instead of ending with its connection: {stopped:?}");
        pair.close().await;
    }).await.unwrap();
}
