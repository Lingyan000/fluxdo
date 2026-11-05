//! The qlog trace a connection writes (draft-ietf-quic-qlog), configured and read back through
//! the public API only.

mod common;

use std::{
    io,
    net::SocketAddr,
    pin::Pin,
    sync::Arc,
    task::{Context, Poll},
};

use common::*;
use parking_lot::Mutex;
use rama::{
    quic::{
        ClientConfig, Endpoint, TransportConfig,
        qlog::{QlogConfig, QlogRecorder},
    },
    utils::octets,
};
use serde_json::Value;
use tokio::io::AsyncWrite;

/// A writer a test can read back. qlog takes ownership of the writer, so what it wrote is read
/// through the shared buffer rather than the handle.
#[derive(Default)]
struct Trace {
    bytes: Arc<Mutex<Vec<u8>>>,
    recorders: Mutex<Vec<QlogRecorder>>,
}

impl Trace {
    async fn flush(&self) {
        let recorders = self.recorders.lock().clone();
        for recorder in recorders {
            step("the qlog recorder flushes", recorder.flush())
                .await
                .unwrap();
        }
    }

    fn written(&self) -> Vec<u8> {
        self.bytes.lock().clone()
    }
}

struct TraceWriter(Arc<Mutex<Vec<u8>>>);

impl AsyncWrite for TraceWriter {
    fn poll_write(
        self: Pin<&mut Self>,
        _: &mut Context<'_>,
        buffer: &[u8],
    ) -> Poll<io::Result<usize>> {
        self.0.lock().extend_from_slice(buffer);
        Poll::Ready(Ok(buffer.len()))
    }

    fn poll_flush(self: Pin<&mut Self>, _: &mut Context<'_>) -> Poll<io::Result<()>> {
        Poll::Ready(Ok(()))
    }

    fn poll_shutdown(self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<io::Result<()>> {
        self.poll_flush(cx)
    }
}

/// One event of a qlog trace: what happened, and which connection it belongs to.
#[derive(Debug)]
struct Recorded {
    name: String,
    group: Option<String>,
}

/// A connection configured with a qlog writer records what it sends and receives. A second
/// connection whose configuration had that same writer and then had it cleared records
/// nothing more into it.
#[tokio::test]
async fn a_configured_qlog_writer_receives_the_connection_s_trace() {
    let auth = identity();
    let anchor = auth.cert_chain.last().expect("a chain").clone();
    let (server, server_addr, accepting) = peer_taking(2, &auth);

    let client = step(
        "rama binds",
        Endpoint::bind_client(rama::rt::Executor::new(), localhost()),
    )
    .await
    .expect("the client binds");

    // Configured: the writer receives this connection's trace.
    let trace = Trace::default();
    let traced = rama_client_config(anchor.clone()).with_transport_config(Arc::new(
        TransportConfig::default().with_qlog_recorder(writer(&trace)),
    ));
    exchange(
        &client,
        server_addr,
        traced,
        &payload(0x4d, octets::kib(16)),
    )
    .await;
    step("the traced connection is done with", client.wait_idle()).await;

    trace.flush().await;
    let (headers, events) = parse(&trace.written());
    assert_eq!(
        headers
            .iter()
            .map(|header| header.get("serialization_format").and_then(Value::as_str))
            .collect::<Vec<_>>(),
        vec![Some("application/qlog+json-seq")],
        "the stream opens with one header, and it says what the format is"
    );
    assert_eq!(
        headers[0]["file_schema"],
        "urn:ietf:params:qlog:file:sequential"
    );
    assert_eq!(
        headers[0]["trace"]["event_schemas"],
        serde_json::json!(["urn:ietf:params:qlog:events:quic-13"])
    );
    let common = &headers[0]["trace"]["common_fields"];
    assert_eq!(common["reference_time"]["clock_type"], "monotonic");
    assert_eq!(common["reference_time"]["epoch"], "unknown");
    assert_eq!(common["time_format"], "relative_to_epoch");
    for name in [
        "quic:packet_sent",
        "quic:packet_received",
        "quic:recovery_metrics_updated",
        "quic:connection_started",
        "quic:connection_closed",
        "quic:connection_state_updated",
        "quic:version_information",
        "quic:alpn_information",
        "quic:parameters_set",
        "quic:key_updated",
        "quic:key_discarded",
        "quic:recovery_parameters_set",
        "quic:tuple_assigned",
    ] {
        assert!(
            events.iter().any(|event| event.name == name),
            "the writer received this connection's {name} records: {events:?}"
        );
    }
    assert!(
        events.iter().all(|event| event.group.is_some()),
        "every event says which connection it belongs to"
    );
    let after_the_first = trace.written().len();

    // Cleared through the same option: the configuration carried that writer and no longer
    // does. Clearing it after it was set writes the header of a trace that then stays empty,
    // so what is compared afterwards is the size once this connection has finished.
    let cleared = rama_client_config(anchor).with_transport_config(Arc::new(
        TransportConfig::default()
            .with_qlog_recorder(writer(&trace))
            .without_qlog_sink(),
    ));
    trace.flush().await;
    let opened_a_second_trace = trace.written().len();
    exchange(
        &client,
        server_addr,
        cleared,
        &payload(0x77, octets::kib(24)),
    )
    .await;
    step("the cleared connection is done with", client.wait_idle()).await;
    trace.flush().await;

    assert!(
        opened_a_second_trace > after_the_first,
        "starting and flushing the recorder writes its trace header"
    );
    assert_eq!(
        trace.written().len(),
        opened_a_second_trace,
        "and a configuration whose writer was cleared records no events"
    );
    let (_, after_clearing) = parse(&trace.written());
    assert_eq!(
        after_clearing.len(),
        events.len(),
        "the events are the first connection's alone"
    );

    server.close(0u32.into(), b"done");
    step("the quinn server goes idle", server.wait_idle()).await;
    accepting.join("the quinn peer").await;
}

/// Two connections configured with the same writer, as they are when a server shares one
/// transport configuration: their events go to one stream and each carries its own group, so
/// nothing in it is unattributed and the two do not merge.
#[tokio::test]
async fn connections_sharing_a_writer_keep_their_own_group() {
    let auth = identity();
    let anchor = auth.cert_chain.last().expect("a chain").clone();
    let (server, server_addr, accepting) = peer_taking(2, &auth);

    let client = step(
        "rama binds",
        Endpoint::bind_client(rama::rt::Executor::new(), localhost()),
    )
    .await
    .expect("the client binds");
    let trace = Trace::default();
    let shared = Arc::new(TransportConfig::default().with_qlog_recorder(writer(&trace)));

    for seed in [0x11, 0x22] {
        let config = rama_client_config(anchor.clone()).with_transport_config(shared.clone());
        exchange(&client, server_addr, config, &payload(seed, octets::kib(8))).await;
    }
    step("both connections are done with", client.wait_idle()).await;

    trace.flush().await;
    let (_, events) = parse(&trace.written());
    let mut groups: Vec<&str> = events
        .iter()
        .map(|event| {
            event
                .group
                .as_deref()
                .expect("every event says which connection it belongs to")
        })
        .collect();
    groups.sort_unstable();
    groups.dedup();
    assert_eq!(
        groups.len(),
        2,
        "one group per connection, in the one stream they share: {groups:?}"
    );

    server.close(0u32.into(), b"done");
    step("the quinn server goes idle", server.wait_idle()).await;
    accepting.join("the quinn peer").await;
}

/// A qlog configuration writing into `trace`.
fn writer(trace: &Trace) -> QlogRecorder {
    let recorder = QlogConfig::default()
        .with_writer(Box::new(TraceWriter(trace.bytes.clone())))
        .start()
        .expect("the qlog recorder starts");
    trace.recorders.lock().push(recorder.clone());
    recorder
}

/// A quinn server that takes `attempts` connections, reads a stream from each, and waits for
/// each to close.
fn peer_taking(
    attempts: usize,
    auth: &rama::tls::server::ServerAuthData,
) -> (quinn::Endpoint, SocketAddr, Peer) {
    let server =
        quinn::Endpoint::server(quinn_server_config(auth), localhost()).expect("quinn binds");
    let server_addr = server.local_addr().expect("its address");
    let accepting = Peer::spawn({
        let server = server.clone();
        async move {
            for _ in 0..attempts {
                let Some(incoming) = server.accept().await else {
                    return;
                };
                let Ok(conn) = incoming.await else { return };
                let mut uni = step("the stream arrives", conn.accept_uni())
                    .await
                    .expect("it opens");
                let _ = step("the payload", uni.read_to_end(octets::kib(64)))
                    .await
                    .expect("it is read whole");
                step("the connection closes", conn.closed()).await;
            }
        }
    });
    (server, server_addr, accepting)
}

/// The header and the events of a qlog stream, which is JSON text sequences (RFC 7464): a
/// record separator before each record, one JSON value in each. A record that is not JSON, or
/// an event without a name, fails the test rather than being skipped.
fn parse(written: &[u8]) -> (Vec<Value>, Vec<Recorded>) {
    let text = String::from_utf8(written.to_vec()).expect("a qlog stream is text");
    let mut headers = Vec::new();
    let mut events = Vec::new();
    for record in text
        .split('\u{1e}')
        .map(str::trim)
        .filter(|record| !record.is_empty())
    {
        let value: Value = serde_json::from_str(record)
            .unwrap_or_else(|error| panic!("a record is not JSON: {error}: {record}"));
        // A stream opens with a header, and a second configuration writing into the same one
        // opens another. Anything else is an event and must name itself.
        if value.get("serialization_format").is_some() {
            headers.push(value);
            continue;
        }
        events.push(Recorded {
            name: value
                .get("name")
                .and_then(Value::as_str)
                .unwrap_or_else(|| panic!("a record has no event name: {record}"))
                .to_owned(),
            group: value
                .get("group_id")
                .and_then(Value::as_str)
                .map(str::to_owned),
        });
    }
    (headers, events)
}

/// One connection carrying `payload` on a unidirectional stream, closed cleanly.
async fn exchange(
    client: &Endpoint,
    server_addr: SocketAddr,
    config: ClientConfig,
    payload: &[u8],
) {
    let conn = step(
        "the rama client connects",
        client
            .connect_with(config, server_addr, "localhost")
            .expect("the attempt starts"),
    )
    .await
    .expect("the handshake completes");
    let mut stream = step("the stream opens", conn.open_uni())
        .await
        .expect("it opens");
    step("the payload is written", stream.write_all(payload))
        .await
        .expect("it is written");
    stream.finish().expect("the stream is finished");
    step("the peer has it", stream.stopped())
        .await
        .expect("the peer did not reset it");
    conn.close(0u32, b"done");
    step("the connection ends", conn.closed()).await;
}

/// Both ends of one connection name it the same way in a trace, and still do when the server
/// sends a Retry first: the identifier is the destination of the very first Initial, which a
/// Retry does not change. Each end's records carry its own connection's group.
#[tokio::test]
async fn both_ends_group_a_retried_connection_the_same_way() {
    let auth = identity();
    let anchor = auth.cert_chain.last().expect("a chain").clone();

    let server_trace = Trace::default();
    let server = step(
        "the rama server binds",
        Endpoint::bind_server(
            rama::rt::Executor::new(),
            rama_server_config(&auth).with_transport_config(Arc::new(
                TransportConfig::default().with_qlog_recorder(writer(&server_trace)),
            )),
            localhost(),
        ),
    )
    .await
    .expect("it binds");
    let server_addr = server.local_addr().expect("its address");

    let (told, heard) = tokio::sync::oneshot::channel();
    let served = Peer::spawn({
        let server = server.clone();
        async move {
            // The first attempt is sent back for address validation, so the second carries a
            // token and a destination the Retry chose.
            let first = step("the first attempt", server.accept())
                .await
                .expect("an attempt arrives");
            first.retry().expect("a first Retry is allowed");
            // An Initial of the first flight can still arrive after the Retry, as an attempt
            // of its own without a token: only the one that carries the token is accepted.
            let validated = loop {
                let attempt = step("the validated attempt", server.accept())
                    .await
                    .expect("it comes back");
                if attempt.remote_address_validated() {
                    break attempt;
                }
                attempt.ignore();
            };
            let conn = validated
                .accept()
                .expect("it is accepted")
                .await
                .expect("the handshake completes");
            let _ = told.send(conn.trace_id());
            step("the connection closes", conn.closed()).await;
        }
    });

    let client_trace = Trace::default();
    let client = step(
        "rama binds",
        Endpoint::bind_client(rama::rt::Executor::new(), localhost()),
    )
    .await
    .expect("the client binds");
    let config = rama_client_config(anchor).with_transport_config(Arc::new(
        TransportConfig::default().with_qlog_recorder(writer(&client_trace)),
    ));
    let conn = step(
        "the rama client connects",
        client
            .connect_with(config, server_addr, "localhost")
            .expect("the attempt starts"),
    )
    .await
    .expect("the handshake completes through the Retry");
    let client_id = conn.trace_id();
    let server_id = step("the server's identifier", heard)
        .await
        .expect("the server reported it");
    assert_eq!(
        client_id, server_id,
        "both ends name the connection by the destination of the first Initial"
    );

    conn.close(0u32, b"done");
    step("the connection ends", conn.closed()).await;
    step("rama's shutdown", client.wait_idle()).await;
    served.join("the rama peer").await;
    step("the server's shutdown", server.shutdown()).await;

    // Each end's records are its own connection's, under the identifier that end reports.
    for (side, trace, id) in [
        ("client", &client_trace, client_id),
        ("server", &server_trace, server_id),
    ] {
        trace.flush().await;
        let (_, events) = parse(&trace.written());
        assert!(!events.is_empty(), "the {side} recorded its connection");
        let groups: Vec<&str> = events
            .iter()
            .map(|event| {
                event
                    .group
                    .as_deref()
                    .expect("every event says which connection it belongs to")
            })
            .collect();
        assert!(
            groups.iter().all(|group| *group == id.to_string()),
            "every {side} record is grouped by what trace_id reports: {id}"
        );
    }
}
