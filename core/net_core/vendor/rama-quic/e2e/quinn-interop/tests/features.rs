//! What the transport offers beyond streams, exercised through the public API against the
//! upstream Quinn stack: exported keying material, a key update with traffic either side of
//! it, what the handshake settles, and the counters and knobs a consumer reaches for.
//!
//! Datagrams are in `datagram_cases.rs`, where they run from the shared registry.

mod common;

use std::{
    sync::Arc,
    time::{Duration, Instant},
};

use common::*;
use interop_common::{keys::ask_when_ready, support::Deadline};
use rama::{extensions::ExtensionsRef as _, quic::NegotiatedTlsParameters};
use rama::{
    net::tls::ApplicationProtocol,
    quic::{
        AddressTokenKey, CongestionControl, Connection, ConnectionIdGenerator, ConnectionStats,
        DriverStats, Endpoint, EndpointConfig, EndpointStats, FrameStats,
        HashedConnectionIdGenerator, KEY_MATERIAL_SIZE, MIN_INITIAL_CONGESTION_WINDOW,
        PacketQueueStats, RandomConnectionIdGenerator, ReceiveQueueLimits, RetryRefused,
        ServerConfig, StatelessResetKey, TransportConfig, ValidationTokenConfig,
        proto::{ConnectionId, InvalidCid, MAX_CID_SIZE, Side},
    },
    udp::UdpSocketConfig,
    utils::octets,
};

/// Both ends derive the same keying material for one label and context. A different context
/// gives different bytes, as does a different label (RFC 8446 §7.5).
#[tokio::test]
async fn both_ends_export_the_same_keying_material() {
    let auth = identity();
    let anchor = auth.cert_chain.last().expect("a chain").clone();

    let server = quinn::Endpoint::server(quinn_server_config(&auth), localhost())
        .expect("the quinn server binds");
    let server_addr = server.local_addr().expect("its address");

    let (told, heard) = tokio::sync::oneshot::channel::<[u8; 32]>();
    let peer = Peer::spawn(async move {
        let conn = step("the quinn server accepts", server.accept())
            .await
            .expect("an attempt arrives")
            .await
            .expect("the handshake completes");
        let mut theirs = [0u8; 32];
        conn.export_keying_material(&mut theirs, b"rama-interop", b"context")
            .expect("the server exports");
        let _ = told.send(theirs);
        step("the quinn connection closes", conn.closed()).await;
        step("the quinn server goes idle", server.wait_idle()).await;
    });

    let client = step(
        "rama binds",
        Endpoint::bind_client(rama::rt::Executor::new(), localhost()),
    )
    .await
    .expect("the client binds");
    let conn = step(
        "the rama client connects",
        client
            .connect_with(rama_client_config(anchor), server_addr, "localhost")
            .expect("the attempt starts"),
    )
    .await
    .expect("the handshake completes");

    let mut ours = [0u8; 32];
    conn.export_keying_material(&mut ours, b"rama-interop", b"context")
        .expect("the client exports");
    let mut other_context = [0u8; 32];
    conn.export_keying_material(&mut other_context, b"rama-interop", b"another context")
        .expect("the client exports again");
    assert_ne!(
        ours, other_context,
        "a different context gives different material"
    );
    let mut other_label = [0u8; 32];
    conn.export_keying_material(&mut other_label, b"rama-interop-2", b"context")
        .expect("the client exports again");
    assert_ne!(ours, other_label, "so does a different label");

    let theirs = step("the peer's material", heard)
        .await
        .expect("the peer exported");
    assert_eq!(ours, theirs, "both ends derived the same bytes");

    conn.close(0u32, b"done");
    step("rama's shutdown", client.wait_idle()).await;
    peer.join("the quinn peer").await;
}

/// Traffic keys updated mid-connection after the initial random key phase is settled. The peer
/// confirms the first payload before the measured update, and the second payload crosses
/// exactly that update: an update that never happened or extra updates fail this.
#[tokio::test]
async fn a_key_update_does_not_disturb_the_traffic_around_it() {
    let auth = identity();
    let anchor = auth.cert_chain.last().expect("a chain").clone();

    let server = quinn::Endpoint::server(quinn_server_config(&auth), localhost())
        .expect("the quinn server binds");
    let server_addr = server.local_addr().expect("its address");

    let before = payload(0x21, octets::kib(8));
    let after = payload(0x22, octets::kib(8));
    let (before_hash, after_hash) = (digest(&before), digest(&after));

    let (report, mut seen) = tokio::sync::mpsc::channel::<()>(2);
    let peer = Peer::spawn(async move {
        let incoming = step("the quinn server takes the attempt", server.accept())
            .await
            .expect("an attempt arrives");
        let conn = step(
            "the quinn server completes the handshake",
            incoming.accept().expect("the attempt is accepted"),
        )
        .await
        .expect("the handshake completes");
        for expected in [before_hash, after_hash] {
            let mut uni = step("the quinn server takes a stream", conn.accept_uni())
                .await
                .expect("a stream arrives");
            let heard = step("the quinn server reads it", uni.read_to_end(octets::mib(1)))
                .await
                .expect("it completes");
            assert_eq!(
                digest(&heard),
                expected,
                "the payload arrived as it was sent"
            );
            let _ = report.send(()).await;
        }
        step("the quinn connection closes", conn.closed()).await;
        step("the quinn server goes idle", server.wait_idle()).await;
    });

    let client = step(
        "rama binds",
        Endpoint::bind_client(rama::rt::Executor::new(), localhost()),
    )
    .await
    .expect("the client binds");
    let conn = step(
        "the rama client connects",
        client
            .connect_with(rama_client_config(anchor), server_addr, "localhost")
            .expect("the attempt starts"),
    )
    .await
    .expect("the handshake completes");

    // Both stacks start with a small random first key-phase budget. Retire that phase
    // before measuring: the first payload below carries this warm-up update to Quinn,
    // so both peers have their normal confidentiality-limit budgets at the baseline.
    ask_when_ready("settle the initial key phase", Deadline::of(LIMIT), &conn).await;

    let mut first = step("a stream before the update", conn.open_uni())
        .await
        .expect("a stream");
    step("writing before the update", first.write_all(&before))
        .await
        .expect("it is written");
    first.finish().expect("it ends");
    // The peer has the first payload before the keys change, so the second one is the only
    // traffic on the far side of the update.
    step("the peer has the first payload", seen.recv())
        .await
        .expect("the peer reported it");

    let updates = conn.stats().key_updates;
    // The warm-up may still be awaiting acknowledgement or old-key retirement. Neither
    // peer can exhaust its settled phase while this waits for the public update gate.
    ask_when_ready("the client can update its keys", Deadline::of(LIMIT), &conn).await;
    assert_eq!(
        conn.stats().key_updates,
        updates + 1,
        "the connection counts the update it just made"
    );

    let mut second = step("a stream after the update", conn.open_uni())
        .await
        .expect("a stream");
    step("writing after the update", second.write_all(&after))
        .await
        .expect("it is written");
    second.finish().expect("it ends");

    // The second payload is read before the connection goes; closing first would end that
    // stream and the test would be about the close.
    step("the peer has the second payload", seen.recv())
        .await
        .expect("the peer reported it");
    assert_eq!(
        conn.stats().key_updates,
        updates + 1,
        "the second payload crossed exactly the requested update"
    );
    conn.close(0u32, b"done");
    step("rama's shutdown", client.wait_idle()).await;
    peer.join("the quinn peer").await;
}

/// A client that names an IP address sends no SNI (RFC 6066 §3), so the server sees none. The
/// protocol is still settled, which distinguishes "no name" from "no handshake data".
#[tokio::test]
async fn a_client_connecting_to_an_address_sends_no_server_name() {
    let auth = address_identity();
    let anchor = auth.cert_chain.last().expect("a chain").clone();

    let server = step(
        "the rama server binds",
        Endpoint::bind_server(
            rama::rt::Executor::new(),
            rama_server_config(&auth),
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
            let incoming = step("the rama server takes the attempt", server.accept())
                .await
                .expect("an attempt arrives");
            let conn = step(
                "the rama server completes the handshake",
                incoming.accept().expect("the attempt is accepted"),
            )
            .await
            .expect("the handshake completes");
            let settled = conn
                .extensions()
                .get_ref::<NegotiatedTlsParameters>()
                .cloned()
                .expect("the handshake settled something");
            let _ = told.send(settled);
            step("the rama connection closes", conn.closed()).await;
        }
    });

    // The identity is valid for the loopback address, so naming the address verifies.
    let mut client = quinn::Endpoint::client(localhost()).expect("quinn binds");
    client.set_default_client_config(quinn_client_config(anchor));
    let conn = step(
        "the quinn client connects to an address",
        client
            .connect(server_addr, "127.0.0.1")
            .expect("the attempt starts"),
    )
    .await
    .expect("the handshake completes");

    let settled = step("what the server saw", heard)
        .await
        .expect("the server reported it");
    assert_eq!(
        settled.server_name, None,
        "a client naming an address sends no server name"
    );
    assert_eq!(
        settled.application_layer_protocol,
        Some(ApplicationProtocol::from(ALPN)),
        "and the protocol is settled all the same"
    );

    conn.close(0u32.into(), b"done");
    step("quinn's shutdown", client.wait_idle()).await;
    served.join("the rama peer").await;
    step("rama's shutdown", server.shutdown()).await;
}

/// The counters a connection publishes, read the way a consumer of the crate reads them: each
/// snapshot held in the public type that names it, and every field reached by name.
#[tokio::test]
async fn a_consumer_reads_the_counters_through_their_public_types() {
    let auth = identity();
    let anchor = auth.cert_chain.last().expect("a chain").clone();

    let server = quinn::Endpoint::server(quinn_server_config(&auth), localhost())
        .expect("the quinn server binds");
    let server_addr = server.local_addr().expect("its address");

    let up = payload(0x5a, octets::kib(32));
    let up_hash = digest(&up);
    let peer = Peer::spawn(async move {
        let conn = step("the quinn server accepts", server.accept())
            .await
            .expect("an attempt arrives")
            .await
            .expect("the handshake completes");
        let mut stream = step("the stream arrives", conn.accept_uni())
            .await
            .expect("it opens");
        let received = step("the payload", stream.read_to_end(octets::mib(1)))
            .await
            .expect("it is read whole");
        assert_eq!(digest(&received), up_hash, "every byte, unchanged");
        step("the quinn connection closes", conn.closed()).await;
        step("the quinn server goes idle", server.wait_idle()).await;
    });

    let client = step(
        "rama binds",
        Endpoint::bind_client(rama::rt::Executor::new(), localhost()),
    )
    .await
    .expect("the client binds");
    let conn = step(
        "the rama client connects",
        client
            .connect_with(rama_client_config(anchor), server_addr, "localhost")
            .expect("the attempt starts"),
    )
    .await
    .expect("the handshake completes");
    let mut stream = step("the stream opens", conn.open_uni())
        .await
        .expect("it opens");
    step("the payload is written", stream.write_all(&up))
        .await
        .expect("it is written");
    stream.finish().expect("the stream is finished");
    step("the peer has it", stream.stopped())
        .await
        .expect("the peer did not reset it");

    let stats: ConnectionStats = conn.stats();
    let sent: FrameStats = stats.frame_tx;
    let received: FrameStats = stats.frame_rx;
    assert!(sent.stream > 0, "stream frames were sent for the payload");
    assert!(sent.crypto > 0, "and crypto frames for the handshake");
    assert!(received.acks > 0, "the peer acknowledged them");
    assert!(
        stats.udp_tx.datagrams > 0 && stats.udp_rx.datagrams > 0,
        "datagrams crossed in both directions"
    );

    let driver: DriverStats = conn.driver_stats();
    let queue: PacketQueueStats = driver.receive_queue;
    assert_eq!(
        queue.dropped_datagrams, 0,
        "nothing was refused for want of room"
    );
    assert!(
        queue.peak_datagrams >= queue.queued_datagrams && queue.peak_bytes >= queue.queued_bytes,
        "the peaks stand at or above what is held now: {queue:?}"
    );
    assert!(
        queue.peak_datagrams > 0 && queue.peak_bytes > 0,
        "and the queue did hold something along the way: {queue:?}"
    );
    assert!(
        driver.receive_queue_capacity > 0,
        "the queue keeps storage for entries"
    );
    assert_eq!(
        driver.send_failures, 0,
        "the socket took every datagram offered"
    );
    assert_eq!(driver.oversized_sends, 0, "and none was too large for it");

    let endpoint: EndpointStats = client.stats();
    let endpoint_queue: PacketQueueStats = endpoint.receive_queue;
    assert_eq!(
        endpoint_queue.dropped_datagrams, 0,
        "the endpoint-wide budget refused nothing either"
    );
    assert!(
        endpoint_queue.peak_bytes >= endpoint_queue.queued_bytes,
        "and its peak stands at or above what is held now: {endpoint_queue:?}"
    );
    assert_eq!(
        endpoint.outgoing_handshakes, 1,
        "one handshake left this endpoint"
    );

    conn.close(0u32, b"done");
    step("rama's shutdown", client.wait_idle()).await;
    peer.join("the quinn peer").await;
}

/// The configuration a consumer of the crate reaches for when it runs more than one endpoint:
/// the two key types, the validation-token settings and the receive-queue bounds, all named
/// from outside and all installed through the public setters before a peer connects.
#[tokio::test]
async fn a_consumer_configures_keys_and_budgets_by_name() {
    let auth = identity();
    let anchor = auth.cert_chain.last().expect("a chain").clone();

    let reset_key: StatelessResetKey = StatelessResetKey::from_seed(&[0x31; KEY_MATERIAL_SIZE]);
    let token_key: AddressTokenKey =
        AddressTokenKey::try_from_bytes(&[0x62; KEY_MATERIAL_SIZE * 2])
            .expect("material of two seeds is long enough");
    assert_eq!(
        format!("{reset_key:?}"),
        "StatelessResetKey",
        "the material is not in the debug output"
    );

    let validation: ValidationTokenConfig = ValidationTokenConfig::default()
        .with_lifetime(Duration::from_secs(600))
        .with_sent(3);
    let per_connection = ReceiveQueueLimits::new(64, octets::mib(1)).expect("both are nonzero");
    let per_endpoint = ReceiveQueueLimits::new(1024, octets::mib(8)).expect("both are nonzero");

    let endpoint_config: EndpointConfig = EndpointConfig::new(
        rama::crypto::hmac::HmacSha2::try_rand_256().expect("random reset key"),
    )
    .with_stateless_reset_key(reset_key)
    .with_receive_queue_limits(per_connection, per_endpoint);
    let server_config: ServerConfig = rama_server_config(&auth)
        .with_address_token_key(token_key)
        .with_validation_token_config(validation)
        .with_incoming_buffer_size_total(u64::try_from(octets::mib(32)).expect("it fits"));

    let server = step(
        "the rama server binds with the configuration",
        Endpoint::build(rama::rt::Executor::new())
            .with_config(endpoint_config)
            .maybe_with_server_config(Some(server_config))
            .bind_address_with_socket_config(localhost(), UdpSocketConfig::default()),
    )
    .await
    .expect("it binds");
    let server_addr = server.local_addr().expect("its address");

    let payload = payload(0x9c, octets::kib(8));
    let hash = digest(&payload);
    let (read_it, was_read) = tokio::sync::oneshot::channel::<()>();
    let served = Peer::spawn({
        let server = server.clone();
        async move {
            let conn = step("the rama server accepts", server.accept())
                .await
                .expect("an attempt arrives")
                .accept()
                .expect("it is accepted")
                .await
                .expect("the handshake completes");
            let mut uni = step("the stream arrives", conn.accept_uni())
                .await
                .expect("it opens");
            let received = step("the payload", uni.read_to_end(octets::mib(1)))
                .await
                .expect("it is read whole");
            assert_eq!(digest(&received), hash, "every byte, unchanged");
            let _ = read_it.send(());
            step("the connection closes", conn.closed()).await;
        }
    });

    let mut client = quinn::Endpoint::client(localhost()).expect("quinn binds");
    client.set_default_client_config(quinn_client_config(anchor));
    let conn = step(
        "the quinn client connects",
        client
            .connect(server_addr, "localhost")
            .expect("the attempt starts"),
    )
    .await
    .expect("the handshake completes");
    let mut stream = step("the stream opens", conn.open_uni())
        .await
        .expect("it opens");
    step("the payload is written", stream.write_all(&payload))
        .await
        .expect("it is written");
    stream.finish().expect("the stream is finished");
    step("the peer read it", was_read)
        .await
        .expect("the peer reported");
    conn.close(0u32.into(), b"done");
    step("quinn's shutdown", client.wait_idle()).await;
    served.join("the rama peer").await;
    step("rama's shutdown", server.shutdown()).await;
}

/// The transport settings and connection facts a consumer reaches for by name: which congestion
/// controller a connection starts with, which side it is, and what the path has measured.
#[tokio::test]
async fn a_consumer_chooses_congestion_control_and_reads_connection_facts() {
    let auth = identity();
    let anchor = auth.cert_chain.last().expect("a chain").clone();

    let server = quinn::Endpoint::server(quinn_server_config(&auth), localhost())
        .expect("the quinn server binds");
    let server_addr = server.local_addr().expect("its address");
    let peer = Peer::spawn(async move {
        let conn = step("the quinn server accepts", server.accept())
            .await
            .expect("an attempt arrives")
            .await
            .expect("the handshake completes");
        step("the quinn connection closes", conn.closed()).await;
        step("the quinn server goes idle", server.wait_idle()).await;
    });

    let window = octets::mib_u64(1);
    assert!(
        TransportConfig::default()
            .try_with_initial_congestion_window(0)
            .is_err(),
        "a window of no bytes is refused rather than stalling the connection"
    );
    assert!(
        TransportConfig::default()
            .try_with_initial_congestion_window(MIN_INITIAL_CONGESTION_WINDOW - 1)
            .is_err(),
        "and so is one below the documented minimum"
    );
    let transport: TransportConfig = TransportConfig::default()
        .with_congestion_control(CongestionControl::Bbr)
        .try_with_initial_congestion_window(window)
        .expect("a mebibyte is above the minimum");
    let config = rama_client_config(anchor).with_transport_config(Arc::new(transport));

    let client = step(
        "rama binds",
        Endpoint::bind_client(rama::rt::Executor::new(), localhost()),
    )
    .await
    .expect("the client binds");
    assert!(
        client.advertised_addrs().is_empty(),
        "a client advertises no preferred address"
    );
    let conn = step(
        "the rama client connects",
        client
            .connect_with(config, server_addr, "localhost")
            .expect("the attempt starts"),
    )
    .await
    .expect("the handshake completes");

    assert_eq!(conn.side(), Side::Client, "this end opened the connection");
    assert!(
        conn.stats().path.cwnd >= window,
        "the path starts from the window that was configured: {}",
        conn.stats().path.cwnd
    );
    assert!(
        conn.min_rtt() <= conn.rtt(),
        "the minimum is at or below the current estimate: {:?} against {:?}",
        conn.min_rtt(),
        conn.rtt()
    );
    conn.set_send_window(octets::mib_u64(2));

    conn.close(0u32, b"done");
    step("rama's shutdown", client.wait_idle()).await;
    peer.join("the quinn peer").await;
}

/// What a consumer can do with a Retry it could not send: read why, and take the attempt back
/// to answer it another way. A second Retry is refused because the attempt already carries the
/// token from the first (RFC 9000 §8.1.2), and the attempt handed back still completes.
#[tokio::test]
async fn a_refused_retry_says_why_and_hands_the_attempt_back() {
    let auth = identity();
    let anchor = auth.cert_chain.last().expect("a chain").clone();

    let server = step(
        "the rama server binds",
        Endpoint::bind_server(
            rama::rt::Executor::new(),
            rama_server_config(&auth),
            localhost(),
        ),
    )
    .await
    .expect("it binds");
    let server_addr = server.local_addr().expect("its address");

    let served = Peer::spawn({
        let server = server.clone();
        async move {
            // The first attempt is sent back for address validation.
            let first = step("the first attempt", server.accept())
                .await
                .expect("an attempt arrives");
            assert!(!first.remote_address_validated(), "it carries no token yet");
            first.retry().expect("a first Retry is allowed");

            // The second carries the token, so a Retry is refused; the reason says which case
            // it is, and the attempt comes back to be accepted instead.
            let second = step("the validated attempt", server.accept())
                .await
                .expect("it comes back with the token");
            assert!(second.remote_address_validated(), "the token validated it");
            let refused = second.retry().expect_err("a second Retry is refused");
            assert_eq!(
                refused.reason(),
                RetryRefused::AlreadyRetried,
                "and says the attempt already bears a token"
            );
            let conn = refused
                .into_incoming()
                .accept()
                .expect("the attempt handed back is still ours to accept")
                .await
                .expect("the handshake completes");
            step("the connection closes", conn.closed()).await;
        }
    });

    let mut client = quinn::Endpoint::client(localhost()).expect("quinn binds");
    client.set_default_client_config(quinn_client_config(anchor));
    let conn = step(
        "the quinn client connects",
        client
            .connect(server_addr, "localhost")
            .expect("the attempt starts"),
    )
    .await
    .expect("the handshake completes through the Retry");
    conn.close(0u32.into(), b"done");
    step("quinn's shutdown", client.wait_idle()).await;
    served.join("the rama peer").await;
    step("rama's shutdown", server.shutdown()).await;
}

/// The connection identifiers an endpoint issues, configured from outside: a hashed generator
/// with a key of the consumer's own, whose identifiers that key recognises and another key
/// does not, and a random generator of a chosen length whose identifiers are that length.
#[tokio::test]
async fn a_consumer_chooses_how_connection_identifiers_are_made() {
    const KEY: u64 = 0x5ea1_5ea1_5ea1_5ea1;
    const OTHER_KEY: u64 = 0x0b0b_0b0b_0b0b_0b0b;
    const LENGTH: usize = 12;

    assert!(
        RandomConnectionIdGenerator::new(MAX_CID_SIZE + 1).is_err(),
        "a length QUIC has no room for is refused"
    );

    let auth = identity();
    let anchor = auth.cert_chain.last().expect("a chain").clone();
    let server = step(
        "the rama server binds",
        Endpoint::build(rama::rt::Executor::new())
            .with_config(
                EndpointConfig::new(
                    rama::crypto::hmac::HmacSha2::try_rand_256().expect("random reset key"),
                )
                .with_cid_generator(Arc::new(|| {
                    Box::new(HashedConnectionIdGenerator::from_key(KEY))
                })),
            )
            .maybe_with_server_config(Some(rama_server_config(&auth)))
            .bind_address_with_socket_config(localhost(), UdpSocketConfig::default()),
    )
    .await
    .expect("it binds");
    let server_addr = server.local_addr().expect("its address");
    let served = Peer::spawn({
        let server = server.clone();
        async move {
            let conn = step("the rama server accepts", server.accept())
                .await
                .expect("an attempt arrives")
                .accept()
                .expect("it is accepted")
                .await
                .expect("the handshake completes");

            // The identifier peers send to on this connection is one the configured generator
            // made: the key it was built with recognises it, another key does not.
            let issued = conn.initial_local_id();
            assert_eq!(
                issued.len(),
                HashedConnectionIdGenerator::from_key(KEY).cid_len(),
                "the length that generator issues"
            );
            assert!(
                HashedConnectionIdGenerator::from_key(KEY)
                    .validate(&issued)
                    .is_ok(),
                "the key the endpoint was configured with recognises what it issued"
            );
            assert!(
                HashedConnectionIdGenerator::from_key(OTHER_KEY)
                    .validate(&issued)
                    .is_err(),
                "and another key does not"
            );
            step("the connection closes", conn.closed()).await;
        }
    });

    // The client's own identifiers are the ones the peer sends to, so they are the length this
    // client asked for.
    let client_generator = RandomConnectionIdGenerator::new(LENGTH)
        .expect("twelve bytes is within the maximum")
        .with_lifetime(Duration::from_secs(30));
    assert_eq!(client_generator.cid_len(), LENGTH);
    assert_eq!(
        client_generator.cid_lifetime(),
        Some(Duration::from_secs(30))
    );
    let client = step(
        "rama binds",
        Endpoint::build(rama::rt::Executor::new())
            .with_config(
                EndpointConfig::new(
                    rama::crypto::hmac::HmacSha2::try_rand_256().expect("random reset key"),
                )
                .with_cid_generator(Arc::new(move || Box::new(client_generator))),
            )
            .bind_address_with_socket_config(localhost(), UdpSocketConfig::default()),
    )
    .await
    .expect("the client binds");
    let conn = step(
        "the rama client connects",
        client
            .connect_with(rama_client_config(anchor), server_addr, "localhost")
            .expect("the attempt starts"),
    )
    .await
    .expect("the handshake completes");

    // The client's own identifiers are the length its generator was configured with, and the
    // trace identifier is the one a qlog reader groups this connection by.
    assert_eq!(
        conn.initial_local_id().len(),
        LENGTH,
        "the client issues identifiers of the length it asked for"
    );
    assert_eq!(
        conn.trace_id().len(),
        MAX_CID_SIZE,
        "and names itself in a trace by the destination it chose for its first Initial"
    );

    conn.close(0u32, b"done");
    step("rama's shutdown", client.wait_idle()).await;
    served.join("the rama peer").await;
    step("the server's shutdown", server.shutdown()).await;
}

/// A generator written outside this crate, building its identifiers from bytes, and the
/// identifier a connection reports for itself staying the same while the connection rotates
/// through new ones.
#[tokio::test]
async fn a_generator_of_ones_own_issues_identifiers_that_outlast_rotation() {
    /// Identifiers that carry a fixed prefix, as something in front of the endpoint might
    /// read, and eight bytes of counter behind it.
    #[derive(Debug)]
    struct Tagged {
        tag: [u8; 4],
        next: u64,
    }

    impl ConnectionIdGenerator for Tagged {
        fn generate_cid(&mut self) -> ConnectionId {
            self.next += 1;
            let mut bytes = self.tag.to_vec();
            bytes.extend_from_slice(&self.next.to_be_bytes());
            ConnectionId::try_from_bytes(&bytes).expect("twelve bytes is within the maximum")
        }

        fn validate(&self, cid: &ConnectionId) -> Result<(), InvalidCid> {
            match cid.len() == 12 && cid[..4] == self.tag {
                true => Ok(()),
                false => Err(InvalidCid::new()),
            }
        }

        fn cid_len(&self) -> usize {
            12
        }

        fn cid_lifetime(&self) -> Option<Duration> {
            // Short, so the connection retires and replaces its identifiers while it runs.
            Some(Duration::from_millis(100))
        }
    }

    const TAG: [u8; 4] = *b"rama";

    let auth = identity();
    let anchor = auth.cert_chain.last().expect("a chain").clone();
    let server = step(
        "the rama server binds",
        Endpoint::build(rama::rt::Executor::new())
            .with_config(
                EndpointConfig::new(
                    rama::crypto::hmac::HmacSha2::try_rand_256().expect("random reset key"),
                )
                .with_cid_generator(Arc::new(|| Box::new(Tagged { tag: TAG, next: 0 }))),
            )
            .maybe_with_server_config(Some(rama_server_config(&auth)))
            .bind_address_with_socket_config(localhost(), UdpSocketConfig::default()),
    )
    .await
    .expect("it binds");
    let server_addr = server.local_addr().expect("its address");
    let (rotated, wait_for_it) = tokio::sync::oneshot::channel();
    let served = Peer::spawn({
        let server = server.clone();
        async move {
            let conn = step("the rama server accepts", server.accept())
                .await
                .expect("an attempt arrives")
                .accept()
                .expect("it is accepted")
                .await
                .expect("the handshake completes");
            let named = conn.initial_local_id();
            assert_eq!(named.len(), 12, "the generator's own length");
            assert_eq!(&named[..4], &TAG, "carrying the tag it was built with");

            // Identifiers are retired and replaced as the connection runs; what the connection
            // is called does not change with them. The client holds the connection open until
            // this has been seen.
            wait_for_rotation(&conn, named).await;
            let _ = rotated.send(());
            step("the connection closes", conn.closed()).await;
        }
    });

    let client = step(
        "rama binds",
        Endpoint::bind_client(rama::rt::Executor::new(), localhost()),
    )
    .await
    .expect("the client binds");
    let conn = step(
        "the rama client connects",
        client
            .connect_with(rama_client_config(anchor), server_addr, "localhost")
            .expect("the attempt starts"),
    )
    .await
    .expect("the handshake completes");
    // Traffic, so the identifiers have reason to turn over.
    for round in 0..4u8 {
        let mut stream = step("a stream opens", conn.open_uni())
            .await
            .expect("it opens");
        step(
            "the payload",
            stream.write_all(&payload(round, octets::kib(4))),
        )
        .await
        .expect("it is written");
        stream.finish().expect("the stream is finished");
        step("the peer has it", stream.stopped())
            .await
            .expect("the peer did not reset it");
    }

    step("the identifiers turn over", wait_for_it)
        .await
        .expect("the server saw them turn over");
    conn.close(0u32, b"done");
    step("rama's shutdown", client.wait_idle()).await;
    served.join("the rama peer").await;
    step("the server's shutdown", server.shutdown()).await;
}

/// Wait until this endpoint's own identifiers have turned over: it issued new ones and the
/// peer retired the old ones, both past where the handshake left the counters. Then check the
/// identifier the connection is named by has not moved with them.
async fn wait_for_rotation(conn: &Connection, named: ConnectionId) {
    let settled = conn.stats();
    let issued_at_first = settled.frame_tx.new_connection_id;
    let retired_at_first = settled.frame_rx.retire_connection_id;

    let deadline = Instant::now() + Duration::from_secs(10);
    loop {
        let now = conn.stats();
        let issued = now.frame_tx.new_connection_id;
        let retired = now.frame_rx.retire_connection_id;
        if issued > issued_at_first && retired > retired_at_first {
            break;
        }
        assert!(
            Instant::now() < deadline,
            "the identifiers never turned over: issued {issued_at_first} then {issued}, \
             retired {retired_at_first} then {retired}"
        );
        tokio::time::sleep(Duration::from_millis(50)).await;
    }

    assert_eq!(
        conn.initial_local_id(),
        named,
        "the identifier the connection is named by is the one it started with"
    );
}
