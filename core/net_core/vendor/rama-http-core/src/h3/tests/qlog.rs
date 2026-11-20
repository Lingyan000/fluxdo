//! HTTP/3 qlog events over in-memory QUIC peers.

use super::{LIMIT, Pair};
use crate::h3::{
    PriorityHandle, client,
    connection::{Config, Shared},
    control::Role,
    qlog::EVENT_SCHEMAS,
    qpack::{Decoder, DecoderConfig, Encoder, EncoderConfig},
    server,
};
use parking_lot::Mutex;
use rama_core::{
    bytes::{Bytes, BytesMut},
    extensions::ExtensionsRef as _,
    rt::{Executor, spawn},
};
use rama_http::headers::Priority;
use rama_http_types::{
    Body, Request, Response,
    body::util::BodyExt as _,
    proto::h3::{Code, SettingId, qpack::EncoderInstruction},
};
use rama_quic::{
    TransportConfig,
    qlog::{EventSchema, NamedQlogEventView, QlogConfig, QlogEventView, QlogSink, reader},
};
use rama_utils::octets::mib;
use serde_json::Value;
use std::{
    sync::{
        Arc,
        atomic::{AtomicBool, Ordering},
    },
    time::Duration,
};
use tokio::io::AsyncReadExt as _;

#[derive(Clone)]
pub(super) struct Sink {
    enabled: Arc<AtomicBool>,
    pub(super) events: Arc<Mutex<Vec<(&'static str, Value)>>>,
}

impl Sink {
    pub(super) fn new(enabled: bool) -> Self {
        Self {
            enabled: Arc::new(AtomicBool::new(enabled)),
            events: Arc::default(),
        }
    }
    pub(super) fn count(&self, name: &str) -> usize {
        self.events
            .lock()
            .iter()
            .filter(|(event, _)| *event == name)
            .count()
    }
}

impl QlogSink for Sink {
    fn is_enabled(&self) -> bool {
        self.enabled.load(Ordering::SeqCst)
    }
    fn emit(&self, _event: &QlogEventView<'_>) -> bool {
        true
    }
    fn accepts_named(&self, _schema: &EventSchema) -> bool {
        true
    }

    fn emit_named(&self, event: &NamedQlogEventView<'_>) {
        self.events
            .lock()
            .push((event.name(), serde_json::from_slice(event.data()).unwrap()));
    }
}

fn config(role: Role) -> Config {
    let mut config = Config {
        datagrams: None,
        ..Config::default()
    };
    let mut settings = config.local_settings(role, false).unwrap();
    settings.set(SettingId::new(0xface), 17).unwrap();
    config.settings_profile = Some(Arc::new(settings));
    assert!(config.observation.is_none());
    config
}

#[tokio::test]
async fn accepted_native_settings_are_logged_once_with_or_without_readiness_handoff() {
    tokio::time::timeout(LIMIT, async {
        for staged in [false, true] {
            let client_log = Sink::new(true);
            let server_log = Sink::new(true);
            let pair = Pair::in_memory(
                Some(TransportConfig::default().with_qlog_sink(Arc::new(client_log.clone()))),
                Some(TransportConfig::default().with_qlog_sink(Arc::new(server_log.clone()))),
            )
            .await;
            let (client, client_driver) = client::handshake::<Body, _>(
                pair.client.clone(),
                config(Role::Client),
                Executor::new(),
            )
            .unwrap();
            spawn(client_driver.run());
            let (server, server_driver) = if staged {
                server::receive_settings(pair.server.clone(), &config(Role::Server))
                    .await
                    .unwrap()
                    .into_connection(config(Role::Server))
                    .unwrap()
            } else {
                server::handshake(pair.server.clone(), config(Role::Server)).unwrap()
            };
            spawn(server_driver.run());
            client.peer_settings().await.unwrap();
            server.peer_settings().await.unwrap();
            for log in [&client_log, &server_log] {
                assert_eq!(log.count("http3:parameters_set"), 2);
                let rows = log.events.lock();
                let parameters: Vec<_> = rows
                    .iter()
                    .filter(|(name, _)| *name == "http3:parameters_set")
                    .map(|(_, data)| data["initiator"].as_str().unwrap())
                    .collect();
                assert_eq!(
                    parameters.iter().filter(|value| **value == "local").count(),
                    1
                );
                assert_eq!(
                    parameters
                        .iter()
                        .filter(|value| **value == "remote")
                        .count(),
                    1
                );
                let settings: Vec<_> = rows
                    .iter()
                    .filter(|(name, data)| {
                        matches!(*name, "http3:frame_created" | "http3:frame_parsed")
                            && data["frame"]["frame_type"] == "settings"
                    })
                    .collect();
                assert_eq!(settings.len(), 2);
                for (_, frame) in settings {
                    assert!(frame["frame"]["settings"].as_array().unwrap().iter().any(
                        |entry| entry["name"] == "unknown"
                            && entry["name_bytes"] == 0xface
                            && entry["value"] == 17
                    ));
                }
            }
            pair.close().await;
        }
    })
    .await
    .unwrap();
}

#[tokio::test]
async fn actual_transport_binding_retains_disabled_handle_and_does_not_enable_capture() {
    tokio::time::timeout(LIMIT, async {
        let pair = Pair::in_memory(None, None).await;
        let shared =
            Shared::from_connection(Config::default(), Role::Client, &pair.client).unwrap();
        assert!(shared.qlog.is_none());
        assert!(shared.config.observation.is_none());
        pair.close().await;
        let log = Sink::new(false);
        let pair = Pair::in_memory(
            Some(TransportConfig::default().with_qlog_sink(Arc::new(log.clone()))),
            None,
        )
        .await;
        let shared =
            Shared::from_connection(Config::default(), Role::Client, &pair.client).unwrap();
        assert!(shared.qlog.is_some());
        assert!(shared.config.observation.is_none());
        let (client, driver) = client::handshake::<Body, _>(
            pair.client.clone(),
            config(Role::Client),
            Executor::new(),
        )
        .unwrap();
        assert_eq!(log.count("http3:parameters_set"), 0);
        log.enabled.store(true, Ordering::SeqCst);
        spawn(driver.run());
        let (server, driver) =
            server::handshake(pair.server.clone(), config(Role::Server)).unwrap();
        spawn(driver.run());
        client.peer_settings().await.unwrap();
        server.peer_settings().await.unwrap();
        assert_eq!(log.count("http3:parameters_set"), 2);
        pair.close().await;
    })
    .await
    .unwrap();
}

#[tokio::test]
async fn request_stream_metadata_never_retains_http_names_paths_or_bodies() {
    tokio::time::timeout(LIMIT, async {
        let log = Sink::new(true);
        let pair = Pair::in_memory(
            Some(TransportConfig::default().with_qlog_sink(Arc::new(log.clone()))),
            None,
        )
        .await;
        let (mut client, driver) = client::handshake::<Body, _>(
            pair.client.clone(),
            config(Role::Client),
            Executor::new(),
        )
        .unwrap();
        spawn(driver.run());
        let (mut server, driver) =
            server::handshake(pair.server.clone(), config(Role::Server)).unwrap();
        spawn(driver.run());
        let service = spawn(async move {
            for _ in 0..2 {
                let (request, response) = server.accept().await.unwrap().resolve().await.unwrap();
                assert_eq!(
                    request.into_body().collect().await.unwrap().to_bytes(),
                    "request-body-sentinel"
                );
                response
                    .send_response(Response::new(Body::from("response-body-sentinel")))
                    .await
                    .unwrap();
            }
        });
        for _ in 0..2 {
            let response = client
                .send_request(
                    Request::post("https://localhost/private-path-sentinel")
                        .header("x-private-name-sentinel", "credential-value-sentinel")
                        .body(Body::from("request-body-sentinel"))
                        .unwrap(),
                )
                .await
                .unwrap();
            assert_eq!(
                response.into_body().collect().await.unwrap().to_bytes(),
                "response-body-sentinel"
            );
        }
        service.await.unwrap();
        assert_eq!(log.count("rama_qpack:field_section_created"), 2);
        assert_eq!(log.count("rama_qpack:field_section_decoded"), 2);
        let rows = log.events.lock().clone();
        let requests: Vec<_> = rows
            .iter()
            .filter(|(name, data)| {
                *name == "http3:stream_type_set" && data["stream_type"] == "request"
            })
            .map(|(_, data)| data["stream_id"].as_u64().unwrap())
            .collect();
        assert_eq!(requests, [0, 4]);
        let encoded = serde_json::to_string(&rows).unwrap();
        for sentinel in [
            "private-path-sentinel",
            "x-private-name-sentinel",
            "credential-value-sentinel",
            "request-body-sentinel",
            "response-body-sentinel",
        ] {
            assert!(!encoded.contains(sentinel));
        }
        pair.close().await;
    })
    .await
    .unwrap();
}

#[tokio::test]
async fn invalid_second_settings_does_not_publish_a_second_accepted_event() {
    tokio::time::timeout(LIMIT, async {
        let log = Sink::new(true);
        let pair = Pair::in_memory(
            None,
            Some(TransportConfig::default().with_qlog_sink(Arc::new(log.clone()))),
        )
        .await;
        let (_server, driver) =
            server::handshake(pair.server.clone(), config(Role::Server)).unwrap();
        let driver = spawn(driver.run());
        let mut control = pair.client.open_uni().await.unwrap();
        // Native foreign input: control type, one valid SETTINGS, then a forbidden repeat.
        control
            .write_all(&[0x00, 0x04, 0x02, 0x01, 0x00, 0x04, 0x00])
            .await
            .unwrap();
        let error = driver.await.unwrap().unwrap_err();
        assert_eq!(error.code(), Code::H3_FRAME_UNEXPECTED);
        let rows = log.events.lock().clone();
        assert_eq!(
            rows.iter()
                .filter(
                    |(name, data)| *name == "http3:parameters_set" && data["initiator"] == "remote"
                )
                .count(),
            1
        );
        assert_eq!(
            rows.iter()
                .filter(|(name, data)| *name == "http3:frame_parsed"
                    && data["frame"]["frame_type"] == "settings")
                .count(),
            1
        );
        pair.close().await;
    })
    .await
    .unwrap();
}

#[tokio::test]
async fn real_qpack_instructions_block_resume_feedback_without_retaining_literals() {
    tokio::time::timeout(LIMIT, async {
        let log = Sink::new(true);
        let pair = Pair::in_memory(
            Some(TransportConfig::default().with_qlog_sink(Arc::new(log.clone()))),
            Some(TransportConfig::default().with_qlog_sink(Arc::new(log.clone()))),
        )
        .await;
        let mut encoded = Encoder::new(EncoderConfig::default());
        encoded.set_qlog(pair.client.qlog_control());
        let mut decoded = Decoder::new(DecoderConfig::default());
        decoded.set_qlog(pair.server.qlog_control());
        let mut absent_encoder = Encoder::new(EncoderConfig::default());
        let fields = [(
            b"x-secret-name-sentinel".as_slice(),
            b"private-qpack-value-sentinel".as_slice(),
        )];
        let bytes = encoded.encode(4, fields).unwrap();
        assert_eq!(bytes, absent_encoder.encode(4, fields).unwrap());
        let instructions = encoded.take_encoder_stream();
        assert_eq!(instructions, absent_encoder.take_encoder_stream());
        assert!(
            encoded.insert_count() > 0,
            "this must exercise real dynamic compression"
        );
        assert!(decoded.decode_field_section(4, bytes).unwrap().is_none());
        assert_eq!(log.count("rama_qpack:field_section_blocked"), 1);
        for byte in instructions.chunks(1) {
            decoded.feed_encoder_stream(byte).unwrap();
        }
        let (stream, result) = decoded.resume_next().unwrap();
        assert_eq!(stream, 4);
        let fields = result.unwrap();
        assert_eq!(&fields[0].name[..], b"x-secret-name-sentinel");
        assert_eq!(&fields[0].value[..], b"private-qpack-value-sentinel");
        assert_eq!(log.count("rama_qpack:field_section_unblocked"), 1);
        assert_eq!(log.count("rama_qpack:field_section_decoded"), 1);
        let feedback = decoded.take_decoder_stream();
        for byte in feedback.chunks(1) {
            encoded.feed_decoder_stream(byte).unwrap();
        }
        assert_eq!(encoded.tracked_section_count(), 0);
        decoded.cancel_stream(4).unwrap();
        encoded
            .feed_decoder_stream(&decoded.take_decoder_stream())
            .unwrap();
        let rows = log.events.lock().clone();
        let parsed: Vec<_> = rows
            .iter()
            .filter(|(name, _)| *name == "rama_qpack:instruction_parsed")
            .map(|(_, data)| data["instruction"]["kind"].as_str().unwrap())
            .collect();
        for class in [
            "set_capacity",
            "insert_literal_name",
            "insert_count_increment",
            "section_acknowledgment",
            "stream_cancellation",
        ] {
            assert!(parsed.contains(&class), "missing native {class}");
        }
        let serialized = serde_json::to_string(&rows).unwrap();
        assert!(!serialized.contains("x-secret-name-sentinel"));
        assert!(!serialized.contains("private-qpack-value-sentinel"));
        pair.close().await;
    })
    .await
    .unwrap();
}

#[tokio::test]
async fn partial_qpack_instruction_has_no_event_and_invalid_suffix_keeps_only_valid_prefix() {
    tokio::time::timeout(LIMIT, async {
        let log = Sink::new(true);
        let pair = Pair::in_memory(
            None,
            Some(TransportConfig::default().with_qlog_sink(Arc::new(log.clone()))),
        )
        .await;
        let mut decoder = Decoder::new(DecoderConfig::default());
        decoder.set_qlog(pair.server.qlog_control());
        let mut instruction = BytesMut::new();
        EncoderInstruction::SetDynamicTableCapacity { capacity: 128 }.encode(&mut instruction);
        decoder
            .feed_encoder_stream(&instruction[..instruction.len() - 1])
            .unwrap();
        assert_eq!(log.count("rama_qpack:instruction_parsed"), 0);
        decoder
            .feed_encoder_stream(&instruction[instruction.len() - 1..])
            .unwrap();
        assert_eq!(log.count("rama_qpack:instruction_parsed"), 1);
        let mut invalid = BytesMut::new();
        EncoderInstruction::SetDynamicTableCapacity { capacity: 64 }.encode(&mut invalid);
        EncoderInstruction::SetDynamicTableCapacity {
            capacity: DecoderConfig::default().max_table_capacity + 1,
        }
        .encode(&mut invalid);
        assert!(decoder.feed_encoder_stream(&invalid).is_err());
        assert_eq!(
            log.count("rama_qpack:instruction_parsed"),
            2,
            "valid instruction before invalid suffix stays applied and observed"
        );
        let mut decoder = Decoder::new(DecoderConfig::default());
        decoder.set_qlog(pair.server.qlog_control());
        let mut oversized = BytesMut::new();
        EncoderInstruction::SetDynamicTableCapacity { capacity: 64 }.encode(&mut oversized);
        EncoderInstruction::InsertWithLiteralName {
            name: Bytes::from_static(b"x-oversized-name-20b"),
            name_huffman: false,
            value: Bytes::from_static(b"twenty-bytes-value!!"),
            value_huffman: false,
        }
        .encode(&mut oversized);
        assert!(decoder.feed_encoder_stream(&oversized).is_err());
        assert_eq!(
            log.count("rama_qpack:instruction_parsed"),
            3,
            "a rejected insertion is not observed"
        );
        pair.close().await;
    })
    .await
    .unwrap();
}

#[tokio::test]
async fn recorder_writes_http3_events_only_for_declared_schemas() {
    tokio::time::timeout(LIMIT, async {
        for declared in [false, true] {
            let (writer, mut output) = tokio::io::duplex(mib(1));
            let mut qlog = QlogConfig::default().with_writer(writer);
            if declared {
                qlog.set_event_schemas(EVENT_SCHEMAS);
            }
            let recorder = qlog.start().unwrap();
            let pair = Pair::in_memory(
                Some(TransportConfig::default().with_qlog_recorder(recorder.clone())),
                None,
            )
            .await;
            let (client, driver) = client::handshake::<Body, _>(
                pair.client.clone(),
                config(Role::Client),
                Executor::new(),
            )
            .unwrap();
            spawn(driver.run());
            let (server, driver) =
                server::handshake(pair.server.clone(), config(Role::Server)).unwrap();
            spawn(driver.run());
            client.peer_settings().await.unwrap();
            server.peer_settings().await.unwrap();
            pair.close().await;
            recorder.shutdown().await.unwrap();

            let mut bytes = Vec::new();
            output.read_to_end(&mut bytes).await.unwrap();
            let file = reader::read(&bytes).unwrap();
            let trace = &file.traces[0];
            assert_eq!(trace.event_schemas.len(), if declared { 5 } else { 1 });
            let parameters = trace
                .events
                .iter()
                .filter(|event| event.name == "http3:parameters_set")
                .count();
            assert_eq!(parameters, if declared { 2 } else { 0 });
        }
    })
    .await
    .unwrap();
}

fn frames(log: &Sink, name: &str, frame_type: &str) -> Vec<Value> {
    log.events
        .lock()
        .iter()
        .filter(|(event, data)| *event == name && data["frame"]["frame_type"] == frame_type)
        .map(|(_, data)| data.clone())
        .collect()
}

async fn eventually(log: &Sink, name: &str, frame_type: &str) -> Vec<Value> {
    loop {
        let found = frames(log, name, frame_type);
        if !found.is_empty() {
            return found;
        }
        tokio::time::sleep(Duration::from_millis(1)).await;
    }
}

#[tokio::test]
async fn local_and_peer_control_frames_are_logged() {
    tokio::time::timeout(LIMIT, async {
        let client_log = Sink::new(true);
        let server_log = Sink::new(true);
        let pair = Pair::in_memory(
            Some(TransportConfig::default().with_qlog_sink(Arc::new(client_log.clone()))),
            Some(TransportConfig::default().with_qlog_sink(Arc::new(server_log.clone()))),
        )
        .await;
        let mut client_config = config(Role::Client);
        client_config.max_pushes = 2;
        let (mut client, driver) =
            client::handshake::<Body, _>(pair.client.clone(), client_config, Executor::new())
                .unwrap();
        spawn(driver.run());
        let (mut server, driver) =
            server::handshake(pair.server.clone(), config(Role::Server)).unwrap();
        spawn(driver.run());
        let service = spawn(async move {
            let (_request, response) = server.accept().await.unwrap().resolve().await.unwrap();
            response
                .send_response(Response::new(Body::empty()))
                .await
                .unwrap();
            server
        });
        let response = client
            .send_request(
                Request::get("https://localhost/")
                    .body(Body::empty())
                    .unwrap(),
            )
            .await
            .unwrap();
        let mut server = service.await.unwrap();
        response
            .extensions()
            .get_ref::<PriorityHandle>()
            .unwrap()
            .update(Priority::new(1, true).unwrap())
            .unwrap();
        server.shutdown().unwrap();

        let created = eventually(&client_log, "http3:frame_created", "max_push_id").await;
        assert_eq!(created[0]["frame"]["push_id"], 1);
        let parsed = eventually(&server_log, "http3:frame_parsed", "max_push_id").await;
        assert_eq!(parsed[0]["frame"]["push_id"], 1);
        for (log, name) in [
            (&client_log, "http3:frame_created"),
            (&server_log, "http3:frame_parsed"),
        ] {
            let update = eventually(log, name, "priority_update").await;
            assert_eq!(update[0]["frame"]["stream_id"], 0);
            assert_eq!(update[0]["frame"]["priority_field_value"], "u=1, i");
        }
        eventually(&server_log, "http3:frame_created", "goaway").await;
        let goaway = eventually(&client_log, "http3:frame_parsed", "goaway").await;
        assert_eq!(goaway[0]["frame"]["id"], 4);
        pair.close().await;
    })
    .await
    .unwrap();
}

#[tokio::test]
async fn reserved_types_are_logged_as_reserved() {
    tokio::time::timeout(LIMIT, async {
        let log = Sink::new(true);
        let pair = Pair::in_memory(
            None,
            Some(TransportConfig::default().with_qlog_sink(Arc::new(log.clone()))),
        )
        .await;
        let (_server, driver) =
            server::handshake(pair.server.clone(), config(Role::Server)).unwrap();
        spawn(driver.run());
        let mut control = pair.client.open_uni().await.unwrap();
        // Control stream with SETTINGS {0x21: 1}, then an empty reserved frame of type 0x21.
        control
            .write_all(&[0x00, 0x04, 0x02, 0x21, 0x01, 0x21, 0x00])
            .await
            .unwrap();
        let mut grease = pair.client.open_uni().await.unwrap();
        grease.write_all(&[0x21, 0xff]).await.unwrap();
        let reserved = eventually(&log, "http3:frame_parsed", "reserved").await;
        assert_eq!(reserved[0]["frame"]["frame_type_bytes"], 0x21);
        assert_eq!(reserved[0]["raw"]["payload_length"], 0);
        let settings = eventually(&log, "http3:frame_parsed", "settings").await;
        assert_eq!(
            settings[0]["frame"]["settings"],
            serde_json::json!([{ "name": "reserved", "value": 1 }])
        );
        loop {
            let streams: Vec<_> = log
                .events
                .lock()
                .iter()
                .filter(|(name, data)| {
                    *name == "http3:stream_type_set" && data["stream_type"] == "reserved"
                })
                .map(|(_, data)| data.clone())
                .collect();
            if let Some(stream) = streams.first() {
                assert_eq!(stream["stream_id"], 6);
                assert!(stream.get("stream_type_bytes").is_none());
                break;
            }
            tokio::time::sleep(Duration::from_millis(1)).await;
        }
        pair.close().await;
    })
    .await
    .unwrap();
}

fn suppressed(log: &Sink, events: &str) -> usize {
    log.events
        .lock()
        .iter()
        .filter(|(name, data)| *name == "rama_h3:events_suppressed" && data["events"] == events)
        .count()
}

#[tokio::test]
async fn peer_ignored_frames_have_a_bounded_qlog_budget() {
    tokio::time::timeout(LIMIT, async {
        let log = Sink::new(true);
        let pair = Pair::in_memory(
            None,
            Some(TransportConfig::default().with_qlog_sink(Arc::new(log.clone()))),
        )
        .await;
        let (_server, driver) =
            server::handshake(pair.server.clone(), config(Role::Server)).unwrap();
        spawn(driver.run());
        let mut control = pair.client.open_uni().await.unwrap();
        // Control stream with empty SETTINGS, then many empty reserved frames of type 0x21.
        let mut bytes = vec![0x00, 0x04, 0x00];
        let extra = 10;
        for _ in 0..crate::h3::qlog::IGNORED_FRAME_EVENTS + extra {
            bytes.extend_from_slice(&[0x21, 0x00]);
        }
        control.write_all(&bytes).await.unwrap();
        while suppressed(&log, "ignored_frames") == 0 {
            tokio::time::sleep(Duration::from_millis(1)).await;
        }
        // A frame after the budget is exhausted proves the earlier ones were all processed.
        control.write_all(&[0x21, 0x00]).await.unwrap();
        tokio::time::sleep(Duration::from_millis(20)).await;
        assert_eq!(
            frames(&log, "http3:frame_parsed", "reserved").len(),
            crate::h3::qlog::IGNORED_FRAME_EVENTS as usize
        );
        assert_eq!(suppressed(&log, "ignored_frames"), 1);
        pair.close().await;
    })
    .await
    .unwrap();
}

#[tokio::test]
async fn peer_qpack_instructions_have_a_bounded_qlog_budget() {
    tokio::time::timeout(LIMIT, async {
        let log = Sink::new(true);
        let pair = Pair::in_memory(
            None,
            Some(TransportConfig::default().with_qlog_sink(Arc::new(log.clone()))),
        )
        .await;
        let mut decoder = Decoder::new(DecoderConfig::default());
        decoder.set_qlog(pair.server.qlog_control());
        let mut instructions = BytesMut::new();
        let limit = crate::h3::qlog::QPACK_INSTRUCTION_EVENTS;
        for _ in 0..limit + 10 {
            EncoderInstruction::SetDynamicTableCapacity { capacity: 0 }.encode(&mut instructions);
        }
        decoder.feed_encoder_stream(&instructions).unwrap();
        assert_eq!(log.count("rama_qpack:instruction_parsed"), limit as usize);
        assert_eq!(suppressed(&log, "qpack_instructions"), 1);
        pair.close().await;
    })
    .await
    .unwrap();
}
