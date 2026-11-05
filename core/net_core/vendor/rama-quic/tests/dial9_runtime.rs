#![cfg(all(
    feature = "dial9",
    any(
        feature = "boring",
        all(feature = "rustls", any(feature = "aws-lc", feature = "ring"))
    )
))]
#![expect(
    clippy::unwrap_used,
    clippy::expect_used,
    reason = "an integration test's fixtures fail the test by panicking; the workspace allows this inside test functions and this file is one, but its helpers are not #[test] themselves"
)]
#![expect(
    clippy::print_stdout,
    reason = "what the recorder wrote is the observation this test exists to make, and an assertion only shows its message when it fails"
)]
//! An endpoint built through the public API on a runtime a dial9 recorder is attached to.
//!
//! What this establishes is that the public construction path spawns through the shared
//! utilities rather than around them: the endpoint's tasks are created inside the recorder's
//! session, and the recorder has something to show for it afterwards.

mod runtime;

use std::{
    collections::BTreeSet,
    net::{Ipv4Addr, SocketAddr},
};

use dial9::{analysis::analysis_events::Dial9Event, format::Decoder};

use rama_core::{
    rt::{Executor, OwnedRuntime},
    telemetry::dial9::{
        Dial9Handle, Dial9HandleTokioExt as _, DiskBuffer, TokioAttachOptions, recorder_or_disabled,
    },
};
use rama_quic::Endpoint;
use rama_utils::octets;

use runtime::{Identities, connect, exchange, serve_one};

#[test]
fn an_endpoint_built_on_a_recorded_runtime_is_traced() {
    let temp_dir = rama_utils::fs::tempdir().unwrap();
    let writer = DiskBuffer::builder()
        .base_path(temp_dir.path())
        .max_file_size(octets::mib_u64(1))
        .max_total_size(octets::mib_u64(4))
        .build();
    let recorder = recorder_or_disabled(writer).build();
    assert!(
        recorder.handle().is_enabled(),
        "expected an enabled recorder; is another recorder alive in this process?"
    );
    let mut builder = tokio::runtime::Builder::new_multi_thread();
    builder.worker_threads(2).enable_all();
    let tokio_runtime = recorder
        .handle()
        .attach_tokio_runtime(builder, TokioAttachOptions::default())
        .unwrap();
    let owned = OwnedRuntime::from_dial9((recorder, tokio_runtime));

    owned.block_on(async {
        assert!(
            Dial9Handle::current().is_enabled(),
            "the endpoints below are built inside the recorder's session"
        );
        let identities = Identities::new();
        let localhost = SocketAddr::new(Ipv4Addr::LOCALHOST.into(), 0);
        let server = Endpoint::build(Executor::new())
            .with_server_config(identities.server_config())
            .bind_address(localhost)
            .await
            .expect("the server binds");
        let addr = server.local_addr().unwrap();
        let client = Endpoint::build(Executor::new())
            .bind_address(localhost)
            .await
            .expect("the client binds");

        let serving = rama_core::rt::spawn({
            let server = server.clone();
            async move { serve_one(&server).await }
        });
        let connection = connect(&client, &identities, addr).await;
        exchange(&connection, b"recorded").await;
        drop(connection);
        serving.await.unwrap();
        tokio::join!(server.shutdown(), client.shutdown());
    });

    owned.shutdown_bounded(std::time::Duration::from_secs(5));
    let written: Vec<_> = std::fs::read_dir(temp_dir.path())
        .unwrap()
        .map(|entry| entry.unwrap())
        .collect();
    let bytes: u64 = written
        .iter()
        .map(|entry| entry.metadata().unwrap().len())
        .sum();
    assert!(
        !written.is_empty() && bytes > 0,
        "the recorder wrote trace data for the session: {} files, {bytes} bytes",
        written.len()
    );
    let mut driver_tasks = BTreeSet::new();
    let mut polled_tasks = BTreeSet::new();
    let mut parks = 0;
    let mut connections_started = 0;
    let mut handshakes_completed = 0;
    let mut connections_closed = 0;
    for entry in &written {
        let data = std::fs::read(entry.path()).unwrap();
        Decoder::new(&data)
            .expect("a valid trace header")
            .for_each_event(|raw| {
                match raw.name {
                    "QuicConnectionStarted" => connections_started += 1,
                    "QuicHandshakeCompleted" => handshakes_completed += 1,
                    "QuicConnectionClosed" => {
                        connections_closed += 1;
                        for (name, value) in raw.field_names().zip(raw.fields.iter()) {
                            if matches!(name, "bytes_sent" | "bytes_received") {
                                assert!(matches!(value, dial9_trace_format::types::FieldValueRef::Varint(value) if *value > 0));
                            }
                        }
                    }
                    _ => {}
                }
                match raw
                    .deserialize::<Dial9Event>()
                    .expect("a valid runtime event")
                {
                    Dial9Event::PollStartEvent(event) => {
                        polled_tasks.insert(event.task_id);
                        if event
                            .spawn_loc
                            .replace('\\', "/")
                            .contains("rama-quic/src/driver/")
                        {
                            driver_tasks.insert(event.task_id);
                        }
                    }
                    Dial9Event::TaskSpawnEvent(event) => {
                        if event
                            .spawn_loc
                            .replace('\\', "/")
                            .contains("rama-quic/src/driver/")
                        {
                            driver_tasks.insert(event.task_id);
                        }
                    }
                    Dial9Event::WorkerParkEvent(_) => parks += 1,
                    _ => {}
                }
            })
            .expect("the complete trace decodes");
    }
    assert!(parks > 0, "the runtime recorded worker park events");
    assert_eq!(connections_started, 2);
    assert_eq!(handshakes_completed, connections_started);
    assert_eq!(connections_closed, connections_started);
    assert!(
        driver_tasks.len() >= 4,
        "both endpoint and connection drivers were identified: {driver_tasks:?}"
    );
    assert!(
        driver_tasks.is_subset(&polled_tasks),
        "each recorded QUIC driver was polled"
    );
    println!(
        "dial9: {} QUIC drivers, {} polled tasks, {parks} worker parks, {bytes} bytes",
        driver_tasks.len(),
        polled_tasks.len()
    );
}
