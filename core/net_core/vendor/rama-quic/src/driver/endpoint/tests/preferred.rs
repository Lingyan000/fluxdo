//! A server that advertises a preferred address, and the sockets it owns for it (RFC 9000 §9.6).

use super::lifecycle::{
    SegmentLog, block_segments_for, breakable_segmenting_socket, breakable_socket, close_receive,
    configs, endpoint_with, exchange, fail_receiver, handshake, open_receive, open_segment_hold,
    recording_socket, segmenting_socket_from, unblock_segments, uncredit_segments, wait_for,
};
use super::{DropObserver, TestSocket, probe_socket};
use crate::driver::connection::{MAX_TRANSMIT_SEGMENTS, Outcome, RETAINED_DESCRIPTORS};
use crate::driver::endpoint::*;
use rama_udp::UdpSocketConfig;
use std::assert_matches;
use std::net::{Ipv4Addr, Ipv6Addr, SocketAddr, SocketAddrV4, SocketAddrV6};
use std::sync::atomic::Ordering;

fn localhost_v4() -> SocketAddr {
    SocketAddr::new(Ipv4Addr::LOCALHOST.into(), 0)
}

/// A server bound to an initial address and advertising a preferred one, with the client's
/// configuration to reach it.
async fn preferring_server() -> (Endpoint, ClientConfig, SocketAddr, SocketAddr) {
    let (client_config, mut server_config) = configs();
    server_config.set_preferred_address_v4(SocketAddrV4::new(Ipv4Addr::LOCALHOST, 0));
    let server = Endpoint::bind_server(
        rama_core::rt::Executor::new(),
        server_config,
        localhost_v4(),
    )
    .await
    .expect("the server binds both addresses");
    let initial = server.local_addr().unwrap();
    let addrs = server.local_addrs();
    assert_eq!(addrs.len(), 2, "the endpoint owns both sockets: {addrs:?}");
    let preferred = addrs
        .into_iter()
        .find(|address| *address != initial)
        .expect("the advertised socket has an address of its own");
    assert_ne!(preferred.port(), 0, "with the port the platform assigned");
    (server, client_config, initial, preferred)
}

/// The client moves to the address the server advertised, and both sides carry data over it.
#[tokio::test]
async fn a_client_moves_to_the_advertised_address_and_data_flows() {
    let (server, client_config, initial, preferred) = preferring_server().await;
    let client = Endpoint::bind_client(rama_core::rt::Executor::new(), localhost_v4())
        .await
        .expect("the client binds");
    let connecting = client
        .connect_with(client_config, initial, "localhost")
        .unwrap();
    let incoming = tokio::time::timeout(Duration::from_secs(5), server.accept())
        .await
        .expect("the attempt arrives")
        .expect("the server is listening");
    let (c, s) = handshake(connecting, incoming).await;
    exchange(&c, &s, b"on the initial address").await;

    wait_for(
        "the client moved to the advertised address",
        Duration::from_secs(5),
        || c.remote_address() == preferred,
    )
    .await;

    // Exact bytes and the stream's end, both ways, over the new path.
    exchange(&c, &s, b"up over the preferred address").await;
    exchange(&s, &c, b"down over the preferred address").await;
    assert_eq!(c.remote_address(), preferred);
    drop((c, s));
    tokio::join!(client.shutdown(), server.shutdown());
}

/// The server's address a new connection from `client` ends on once a move would have happened.
async fn settled_remote(client: &Endpoint, server: &Endpoint, config: ClientConfig) -> SocketAddr {
    let initial = server.local_addr().unwrap();
    let connecting = client.connect_with(config, initial, "localhost").unwrap();
    let incoming = tokio::time::timeout(Duration::from_secs(5), server.accept())
        .await
        .expect("the attempt arrives")
        .expect("the server is listening");
    let (c, s) = handshake(connecting, incoming).await;
    exchange(&c, &s, b"on the initial address").await;
    // A move follows the handshake within milliseconds; one that has not happened by now won't.
    tokio::time::sleep(Duration::from_millis(500)).await;
    exchange(&c, &s, b"after the move window").await;
    let remote = c.remote_address();
    c.close(0u32, b"done");
    s.close(0u32, b"done");
    remote
}

fn connected_socket(peer: SocketAddr) -> std::net::UdpSocket {
    let socket = std::net::UdpSocket::bind(localhost_v4()).unwrap();
    socket.connect(peer).unwrap();
    socket
}

#[tokio::test]
async fn a_socket_fixed_to_one_peer_declines_the_advertised_address() {
    let (server, config, initial, _preferred) = preferring_server().await;
    let client = Endpoint::build(rama_core::rt::Executor::new())
        .with_std_socket(connected_socket(initial))
        .unwrap();
    assert_eq!(settled_remote(&client, &server, config).await, initial);
    tokio::join!(client.shutdown(), server.shutdown());
}

#[tokio::test]
async fn new_connections_follow_the_reach_of_the_socket_rebound_to() {
    let (server, config, initial, preferred) = preferring_server().await;
    let client = Endpoint::build(rama_core::rt::Executor::new())
        .with_std_socket(connected_socket(initial))
        .unwrap();
    client
        .rebind_std_socket(std::net::UdpSocket::bind(localhost_v4()).unwrap())
        .unwrap();
    let moved = settled_remote(&client, &server, config.clone()).await;
    assert_eq!(
        moved, preferred,
        "an unrestricted socket reaches the advertised address"
    );
    client.rebind_std_socket(connected_socket(initial)).unwrap();
    let stayed = settled_remote(&client, &server, config).await;
    assert_eq!(stayed, initial, "a socket fixed to one peer declines it");
    tokio::join!(client.shutdown(), server.shutdown());
}

/// A wildcard listener with a concrete advertised socket. Before the move the server answers from
/// the address the client sent to, which the wildcard socket covers; after it, from the advertised
/// socket. The client's view of the server's address is the source tuple its datagrams carried.
#[tokio::test]
async fn a_wildcard_listener_and_a_concrete_advertised_socket_keep_their_own_tuples() {
    let (client_config, mut server_config) = configs();
    let (advertised, advertised_log) = recording_socket();
    let preferred = advertised.local_addr();
    let SocketAddr::V4(preferred_v4) = preferred else {
        panic!("the fixture binds an IPv4 loopback socket");
    };
    // Handshake confirmation starts probing, so hold arrivals until the initial tuple has
    // been observed. Both sockets remain writable.
    close_receive(&advertised_log);
    server_config.set_preferred_address_v4(preferred_v4);
    let server = endpoint_with(
        EndpointConfig::try_with_rand_key().unwrap(),
        Some(server_config),
        Socket::from_std(
            std::net::UdpSocket::bind(SocketAddr::new(Ipv4Addr::UNSPECIFIED.into(), 0)).unwrap(),
        )
        .unwrap(),
    );
    server.advertise_abstract(advertised).unwrap();
    let listener = server.local_addr().unwrap();
    assert!(listener.ip().is_unspecified(), "the listener is a wildcard");

    // The client sends to a concrete address of ours that the wildcard listener receives on.
    let reachable = SocketAddr::new(Ipv4Addr::LOCALHOST.into(), listener.port());
    let client = Endpoint::bind_client(rama_core::rt::Executor::new(), localhost_v4())
        .await
        .expect("the client binds");
    let connecting = client
        .connect_with(client_config, reachable, "localhost")
        .unwrap();
    let incoming = tokio::time::timeout(Duration::from_secs(5), server.accept())
        .await
        .expect("the attempt arrives")
        .expect("the server is listening");
    let (c, s) = handshake(connecting, incoming).await;
    // Connection state, not a wire capture: the wire observation for socket selection is
    // `the_datagrams_of_each_path_leave_by_that_paths_socket`.
    assert_eq!(
        c.remote_address(),
        reachable,
        "the connection's peer address is the one the client sent to"
    );
    exchange(&c, &s, b"through the wildcard listener").await;
    open_receive(&advertised_log);

    wait_for(
        "the client moved to the advertised address",
        Duration::from_secs(5),
        || c.remote_address() == preferred,
    )
    .await;
    exchange(&c, &s, b"up from the advertised socket").await;
    wait_for(
        "the server sends from the advertised socket",
        Duration::from_secs(5),
        || s.sending_from() == Some(preferred),
    )
    .await;
    // The handle the move left behind is kept for the concrete path it was serving, not for the
    // wildcard address it is bound to: that address is not a path, and a datagram naming the old
    // path has to find it here rather than send the endpoint looking for a socket again.
    assert_eq!(
        s.sending_from(),
        Some(preferred),
        "the server sends from the advertised socket"
    );
    assert_eq!(
        s.aside_address(),
        Some(reachable),
        "and keeps the listener for the concrete path it was serving"
    );
    assert_ne!(reachable, listener, "which is not the wildcard bind");
    // What the listener covered is not inherited by the socket that replaced it: a coverage
    // record belongs to the socket it was established on, and this one is bound elsewhere.
    assert!(
        !s.sends_from_for(reachable),
        "the advertised socket does not send for the path the listener covered"
    );
    drop((c, s));
    tokio::join!(client.shutdown(), server.shutdown());
}

/// A client connecting after another moved away still reaches the listener, and the two
/// connections keep their own paths: the second declines the advertised address, so the two paths
/// are different for as long as both live and each carries its own bytes.
#[tokio::test]
async fn the_listener_still_admits_clients_after_a_move_and_paths_stay_apart() {
    let (client_config, server, initial, preferred) = preferring_server_with_config().await;
    let first = Endpoint::bind_client(rama_core::rt::Executor::new(), localhost_v4())
        .await
        .unwrap();
    let (fc, fs) = connect_through(&first, &server, client_config.clone(), initial).await;
    wait_for("the first client moved", Duration::from_secs(5), || {
        fc.remote_address() == preferred
    })
    .await;

    // A second client connects through the original listener, which the move left alone, and
    // declines the advertised address so it stays there.
    let mut declining = client_config;
    declining.set_preferred_address_policy(crate::proto::PreferredAddressPolicy::Decline);
    let second = Endpoint::bind_client(rama_core::rt::Executor::new(), localhost_v4())
        .await
        .unwrap();
    let (sc, ss) = connect_through(&second, &server, declining, initial).await;
    assert_eq!(
        sc.remote_address(),
        initial,
        "the second client is answered from the listener"
    );

    // Both carry their own bytes over their own paths, in both directions.
    exchange(&fc, &fs, b"first on the advertised path").await;
    exchange(&fs, &fc, b"back on the advertised path").await;
    exchange(&sc, &ss, b"second on the listener").await;
    exchange(&ss, &sc, b"back on the listener").await;
    assert_eq!(fc.remote_address(), preferred);
    assert_eq!(
        sc.remote_address(),
        initial,
        "the second was never dragged onto the first's path"
    );
    drop((fc, fs, sc, ss));
    tokio::join!(first.shutdown(), second.shutdown(), server.shutdown());
}

/// An IPv6 server advertising an IPv6 preferred address, with an IPv6 client.
#[tokio::test]
async fn an_ipv6_server_advertises_an_ipv6_address() {
    let (client_config, mut server_config) = configs();
    server_config.set_preferred_address_v6(SocketAddrV6::new(Ipv6Addr::LOCALHOST, 0, 0, 0));
    let server = Endpoint::bind_server(
        rama_core::rt::Executor::new(),
        server_config,
        SocketAddr::new(Ipv6Addr::LOCALHOST.into(), 0),
    )
    .await
    .expect("both IPv6 sockets bind");
    let initial = server.local_addr().unwrap();
    let preferred = server
        .local_addrs()
        .into_iter()
        .find(|address| *address != initial)
        .expect("the advertised socket has its own address");
    assert!(preferred.is_ipv6());

    let client = Endpoint::bind_client(
        rama_core::rt::Executor::new(),
        SocketAddr::new(Ipv6Addr::LOCALHOST.into(), 0),
    )
    .await
    .unwrap();
    let (c, s) = connect_through(&client, &server, client_config, initial).await;
    wait_for("the client moved", Duration::from_secs(5), || {
        c.remote_address() == preferred
    })
    .await;
    exchange(&c, &s, b"over IPv6").await;
    exchange(&s, &c, b"and back").await;
    drop((c, s));
    tokio::join!(client.shutdown(), server.shutdown());
}

/// A wildcard preferred address is refused: resolving its port leaves an address no peer can be
/// sent to.
#[tokio::test]
async fn a_wildcard_preferred_address_is_refused() {
    let (_client_config, mut server_config) = configs();
    server_config.set_preferred_address_v4(SocketAddrV4::new(Ipv4Addr::UNSPECIFIED, 0));
    let error = Endpoint::bind_server(
        rama_core::rt::Executor::new(),
        server_config,
        localhost_v4(),
    )
    .await
    .expect_err("a wildcard cannot be advertised");
    assert_matches!(
        &error,
        rama_udp::DatagramError::Io(error)
            if error.kind() == io::ErrorKind::InvalidInput,
        "refused as an invalid configuration: {error:?}",
    );
}

/// Shutting down drops the sockets the endpoint owns, the advertised one included.
#[tokio::test]
async fn shutdown_drops_the_advertised_socket() {
    let (client_config, server_config) = configs();
    let server = Endpoint::bind_server(
        rama_core::rt::Executor::new(),
        server_config,
        localhost_v4(),
    )
    .await
    .expect("the server binds");
    let observer = Arc::new(DropObserver::default());
    server
        .advertise_abstract(probe_socket(&observer, TestSocket::default()))
        .expect("the endpoint takes the advertised socket");
    assert_eq!(server.local_addrs().len(), 2, "it owns both");

    let client = Endpoint::bind_client(rama_core::rt::Executor::new(), localhost_v4())
        .await
        .unwrap();
    let initial = server.local_addr().unwrap();
    let (c, s) = connect_through(&client, &server, client_config, initial).await;
    exchange(&c, &s, b"before the shutdown").await;
    drop((c, s));

    tokio::join!(client.shutdown(), server.shutdown());
    assert_eq!(
        observer.drops.load(Ordering::SeqCst),
        1,
        "the advertised socket was dropped"
    );
    assert_eq!(
        observer.under_lock.load(Ordering::SeqCst),
        0,
        "and not while the endpoint lock was held"
    );
}

/// A server bound with no preferred address owns one socket.
#[tokio::test]
async fn a_server_without_a_preferred_address_owns_one_socket() {
    let (_client_config, server_config) = configs();
    let server = Endpoint::bind_server(
        rama_core::rt::Executor::new(),
        server_config,
        localhost_v4(),
    )
    .await
    .expect("the server binds");
    assert_eq!(server.local_addrs().len(), 1);
    server.shutdown().await;
}

/// The server and the client configuration for it, plus its two addresses.
async fn preferring_server_with_config() -> (ClientConfig, Endpoint, SocketAddr, SocketAddr) {
    let (server, client_config, initial, preferred) = preferring_server().await;
    (client_config, server, initial, preferred)
}

/// Connect `client` to `server` at `address` and complete the handshake.
async fn connect_through(
    client: &Endpoint,
    server: &Endpoint,
    config: ClientConfig,
    address: SocketAddr,
) -> (
    crate::driver::connection::Connection,
    crate::driver::connection::Connection,
) {
    let connecting = client.connect_with(config, address, "localhost").unwrap();
    let incoming = tokio::time::timeout(Duration::from_secs(5), server.accept())
        .await
        .expect("the attempt arrives")
        .expect("the server is listening");
    handshake(connecting, incoming).await
}

/// Which socket a datagram left by, observed on the wire rather than inferred from the
/// connection's own view of its path. The server's listener and its advertised socket each record
/// what they send, and the advertised one is blocked until the initial leg has been observed, so
/// the move cannot race ahead of it.
#[tokio::test]
async fn the_datagrams_of_each_path_leave_by_that_paths_socket() {
    let (client_config, mut server_config) = configs();
    let (listener, listener_log) = recording_socket();
    let (advertised, advertised_log) = recording_socket();
    let advertised_addr = advertised.local_addr();
    let SocketAddr::V4(advertised_v4) = advertised_addr else {
        panic!("the fixture binds an IPv4 loopback socket");
    };
    server_config.set_preferred_address_v4(advertised_v4);
    let server = endpoint_with(
        EndpointConfig::try_with_rand_key().unwrap(),
        Some(server_config),
        listener,
    );
    let initial = server.local_addr().unwrap();
    server
        .advertise_abstract(advertised)
        .expect("the endpoint takes the advertised socket");

    let client = Endpoint::bind_client(rama_core::rt::Executor::new(), localhost_v4())
        .await
        .expect("the client binds");
    let client_addr = client.local_addr().unwrap();
    // Nothing leaves the advertised socket until this test lets it, so the initial leg is not a
    // race against the move.
    block_segments_for(&advertised_log, SocketAddress::from(client_addr));

    let (c, s) = connect_through(&client, &server, client_config, initial).await;
    exchange(&c, &s, b"on the initial path").await;
    let to_client = |log: &Mutex<SegmentLog>| {
        log.lock()
            .sent
            .iter()
            .filter(|datagram| datagram.destination == SocketAddress::from(client_addr))
            .count()
    };
    assert!(
        to_client(&listener_log) > 0,
        "the listener sent to the client"
    );
    assert_eq!(
        to_client(&advertised_log),
        0,
        "and the advertised socket sent nothing while it was blocked"
    );

    // Let the advertised socket answer: the client's probe is answered from there and it moves.
    unblock_segments(&advertised_log);
    wait_for("the client moved", Duration::from_secs(5), || {
        c.remote_address() == advertised_addr
    })
    .await;
    assert!(
        to_client(&advertised_log) > 0,
        "the advertised socket answered on its own path"
    );
    exchange(&c, &s, b"up over the advertised path").await;
    wait_for(
        "the server sends from the advertised socket",
        Duration::from_secs(5),
        || s.sending_from() == Some(advertised_addr),
    )
    .await;

    // Capture the exact descriptor offered on the new path. Old-path control traffic can
    // still leave by the listener; it cannot stand in for this descriptor's placement.
    block_segments_for(&advertised_log, SocketAddress::from(client_addr));
    let payload = b"down over the advertised path";
    let mut stream = s.open_uni().await.unwrap();
    stream.write_all(payload).await.unwrap();
    stream.finish().unwrap();
    wait_for(
        "a descriptor waits on the advertised socket",
        Duration::from_secs(5),
        || s.held_transmit().is_some(),
    )
    .await;
    let (waiting, destination, _) = s.held_transmit().expect("the descriptor is held");
    assert_eq!(destination, client_addr);
    unblock_segments(&advertised_log);
    wait_for(
        "the exact descriptor leaves by the advertised socket",
        Duration::from_secs(5),
        || {
            advertised_log.lock().sent.iter().any(|datagram| {
                datagram.destination == SocketAddress::from(client_addr)
                    && datagram.bytes == waiting
            })
        },
    )
    .await;
    let mut incoming = tokio::time::timeout(Duration::from_secs(5), c.accept_uni())
        .await
        .expect("the stream arrives")
        .expect("the connection is alive");
    let received = tokio::time::timeout(
        Duration::from_secs(5),
        incoming.read_to_end(payload.len() + 1),
    )
    .await
    .expect("the stream completes")
    .expect("it is not truncated");
    assert_eq!(received, payload);
    assert!(
        !listener_log.lock().sent.iter().any(|datagram| {
            datagram.destination == SocketAddress::from(client_addr) && datagram.bytes == waiting
        }),
        "the descriptor offered on the advertised path never left by the listener"
    );
    drop((c, s));
    tokio::join!(client.shutdown(), server.shutdown());
}

/// A wildcard client keeps working across a replacement of the socket it sends from. What the
/// coverage record is keyed on is checked where it can be observed exactly, at the registry, by
/// `a_coverage_record_belongs_to_the_socket_it_was_established_on`; this case is the end-to-end
/// one and does not discriminate the keying by itself.
#[tokio::test]
async fn a_wildcard_client_keeps_working_across_a_replacement() {
    let (client_config, server_config) = configs();
    let server = Endpoint::bind_server(
        rama_core::rt::Executor::new(),
        server_config,
        localhost_v4(),
    )
    .await
    .expect("the server binds");
    let initial = server.local_addr().unwrap();

    // The client sends from a wildcard socket, so its path's local address is a concrete address
    // the socket covers rather than the address the socket is bound to.
    let client = Endpoint::build(rama_core::rt::Executor::new())
        .bind_address_with_socket_config(
            SocketAddr::new(Ipv4Addr::UNSPECIFIED.into(), 0),
            UdpSocketConfig::default(),
        )
        .await
        .expect("the wildcard client binds");
    let (c, s) = connect_through(&client, &server, client_config, initial).await;
    exchange(&c, &s, b"from the wildcard socket").await;

    // A concrete socket replaces it. The coverage recorded for the old socket says nothing about
    // this one, and the connection keeps working.
    client
        .rebind(localhost_v4(), UdpSocketConfig::default())
        .await
        .expect("the rebind binds");
    exchange(&c, &s, b"after the replacement").await;
    exchange(&s, &c, b"and back").await;
    drop((c, s));
    tokio::join!(client.shutdown(), server.shutdown());
}

/// A socket the endpoint advertised that then fails is not offered to connections still to come,
/// and the connections on it are told to leave it while the listener keeps working.
#[tokio::test]
async fn a_failed_advertised_socket_stops_being_advertised() {
    let (client_config, mut server_config) = configs();
    let (listener, _listener_log) = recording_socket();
    let (advertised, _gate, fault, sent_by_advertised) = breakable_socket(None);
    let advertised_addr = advertised.local_addr();
    let SocketAddr::V4(advertised_v4) = advertised_addr else {
        panic!("the fixture binds an IPv4 loopback socket");
    };
    server_config.set_preferred_address_v4(advertised_v4);
    let server = endpoint_with(
        EndpointConfig::try_with_rand_key().unwrap(),
        Some(server_config),
        listener,
    );
    let initial = server.local_addr().unwrap();
    server.advertise_abstract(advertised).unwrap();
    assert_eq!(
        server.advertised_preferred(),
        vec![advertised_addr],
        "the address is advertised while its socket is usable"
    );

    // Its receive path fails. The endpoint keeps its listener and stops offering the address.
    let sent_before = sent_by_advertised.load(Ordering::SeqCst);
    fail_receiver(&server, &fault);
    wait_for(
        "the advertised address is withdrawn",
        Duration::from_secs(5),
        || server.advertised_preferred().is_empty(),
    )
    .await;
    assert_eq!(
        server.local_addr().unwrap(),
        initial,
        "the listener is untouched"
    );
    wait_for(
        "the failed socket is retired once nothing depends on it",
        Duration::from_secs(5),
        || server.stats().retained_sockets == 1,
    )
    .await;
    assert!(
        !server.local_addrs().contains(&advertised_addr),
        "and the endpoint no longer owns it"
    );

    // A client connecting now is never told about it, so it stays on the listener.
    let client = Endpoint::bind_client(rama_core::rt::Executor::new(), localhost_v4())
        .await
        .unwrap();
    let (c, s) = connect_through(&client, &server, client_config, initial).await;
    exchange(&c, &s, b"only the listener").await;
    exchange(&s, &c, b"and back").await;
    assert_eq!(c.remote_address(), initial);
    assert_eq!(
        sent_by_advertised.load(Ordering::SeqCst),
        sent_before,
        "nothing left by the failed socket"
    );
    drop((c, s));
    tokio::join!(client.shutdown(), server.shutdown());
}

/// A socket advertised after the endpoint has parked is polled: traffic that arrives only there
/// wakes the driver, with nothing on the listener to rescue it.
#[tokio::test]
async fn a_socket_advertised_after_the_driver_parked_is_polled() {
    let (client_config, mut server_config) = configs();
    // The advertised socket is bound first, so its address can be advertised from the start while
    // the endpoint takes it only later, once its driver has parked.
    let advertised = std::net::UdpSocket::bind((Ipv4Addr::LOCALHOST, 0)).unwrap();
    let advertised_addr = advertised.local_addr().unwrap();
    let SocketAddr::V4(advertised_v4) = advertised_addr else {
        panic!("bound on IPv4 loopback");
    };
    server_config.set_preferred_address_v4(advertised_v4);
    let (listener, _listener_log) = recording_socket();
    let server = endpoint_with(
        EndpointConfig::try_with_rand_key().unwrap(),
        Some(server_config),
        listener,
    );
    let initial = server.local_addr().unwrap();

    // Let the endpoint settle with nothing to do, so its driver is parked before the socket
    // arrives.
    tokio::time::sleep(Duration::from_millis(50)).await;
    server
        .advertise_abstract(Socket::from_std(advertised).unwrap())
        .expect("the endpoint takes it");

    // The client reaches the advertised address and nothing else: its handshake is answered only
    // if that socket is being polled.
    let client = Endpoint::bind_client(rama_core::rt::Executor::new(), localhost_v4())
        .await
        .unwrap();
    let (c, s) = connect_through(&client, &server, client_config, advertised_addr).await;
    exchange(&c, &s, b"only through the socket added late").await;
    exchange(&s, &c, b"and back").await;
    assert_eq!(
        c.remote_address(),
        advertised_addr,
        "the connection was established through the socket added after the park"
    );
    let _ = initial;
    drop((c, s));
    tokio::join!(client.shutdown(), server.shutdown());
}

/// A server whose advertised socket records what it sends and whose listener does the same, with
/// the advertised socket refusing to take anything for the client until the test says otherwise.
async fn preferring_server_with_a_stuck_candidate() -> (
    Endpoint,
    Endpoint,
    crate::driver::connection::Connection,
    crate::driver::connection::Connection,
    SocketAddr,
    Arc<Mutex<SegmentLog>>,
    SocketAddr,
    Arc<Mutex<SegmentLog>>,
) {
    let (client_config, mut server_config) = configs();
    let (listener, listener_log) = recording_socket();
    let (advertised, advertised_log) = recording_socket();
    let advertised_addr = advertised.local_addr();
    let SocketAddr::V4(advertised_v4) = advertised_addr else {
        panic!("the fixture binds an IPv4 loopback socket");
    };
    server_config.set_preferred_address_v4(advertised_v4);
    let server = endpoint_with(
        EndpointConfig::try_with_rand_key().unwrap(),
        Some(server_config),
        listener,
    );
    let initial = server.local_addr().unwrap();
    server
        .advertise_abstract(advertised)
        .expect("the endpoint takes the advertised socket");

    let client = Endpoint::bind_client(rama_core::rt::Executor::new(), localhost_v4())
        .await
        .expect("the client binds");
    let client_addr = client.local_addr().unwrap();
    // The advertised socket keeps this task's waker instead of taking anything for the client, so
    // the candidate path is stuck rather than failing.
    block_segments_for(&advertised_log, SocketAddress::from(client_addr));

    let (c, s) = connect_through(&client, &server, client_config, initial).await;
    (
        client,
        server,
        c,
        s,
        advertised_addr,
        advertised_log,
        client_addr,
        listener_log,
    )
}

/// How many datagrams a socket sent to the client.
fn sent_to(log: &Mutex<SegmentLog>, client: SocketAddr) -> usize {
    log.lock()
        .sent
        .iter()
        .filter(|datagram| datagram.destination == SocketAddress::from(client))
        .count()
}

/// A candidate path whose socket never takes a datagram does not stop the path in use: the
/// datagram waits on that path's own handle while the path in use carries exact bytes and the
/// stream's end both ways, and shutdown stays bounded.
#[tokio::test]
async fn a_candidate_socket_that_never_takes_a_datagram_leaves_the_path_in_use_alone() {
    let (client, server, c, s, advertised_addr, advertised_log, client_addr, _listener_log) =
        preferring_server_with_a_stuck_candidate().await;
    let initial = c.remote_address();
    assert_ne!(initial, advertised_addr);

    wait_for(
        "the candidate path's datagram waits on that path's handle",
        Duration::from_secs(5),
        || s.aside_transmit().is_some(),
    )
    .await;
    let (serves, _, _) = s.aside_transmit().expect("it waits there");
    assert_eq!(
        serves, advertised_addr,
        "on the handle for the address the endpoint advertised"
    );

    // The path in use carries exact bytes and the stream's end, in both directions, while that
    // datagram is still waiting.
    exchange(&c, &s, b"up while the candidate is stuck").await;
    exchange(&s, &c, b"down while the candidate is stuck").await;
    assert_eq!(
        sent_to(&advertised_log, client_addr),
        0,
        "and nothing left by the socket that takes nothing"
    );
    assert_eq!(
        c.remote_address(),
        initial,
        "the client stays on the path it has"
    );
    assert!(
        s.aside_transmit().is_some(),
        "the candidate path's datagram is still waiting on its own handle"
    );

    drop((c, s));
    tokio::time::timeout(Duration::from_secs(10), async {
        tokio::join!(client.shutdown(), server.shutdown())
    })
    .await
    .expect("shutdown does not wait for the stuck candidate");
}

/// The datagram waiting on a candidate path's handle is offered again when that socket is ready,
/// without the engine producing anything new: the exact bytes that waited are the ones that
/// leave, and the handle is free afterwards.
#[tokio::test]
async fn a_datagram_waiting_on_a_candidate_handle_leaves_when_that_socket_is_ready() {
    let (client, server, c, s, advertised_addr, advertised_log, client_addr, _listener_log) =
        preferring_server_with_a_stuck_candidate().await;

    wait_for(
        "the candidate path's datagram waits on that path's handle",
        Duration::from_secs(5),
        || s.aside_transmit().is_some(),
    )
    .await;
    let (serves, waiting, _) = s.aside_transmit().expect("it waits there");
    assert_eq!(serves, advertised_addr);
    assert_eq!(
        sent_to(&advertised_log, client_addr),
        0,
        "nothing has left that socket yet"
    );

    // Nothing is written on either side: the only reason to send from that socket is the datagram
    // that already waits on its handle.
    unblock_segments(&advertised_log);
    wait_for(
        "the datagram that waited is the one that left",
        Duration::from_secs(5),
        || {
            advertised_log
                .lock()
                .sent
                .iter()
                .any(|datagram| datagram.bytes == waiting)
        },
    )
    .await;

    drop((c, s));
    tokio::join!(client.shutdown(), server.shutdown());
}

/// A descriptor the handle in use took a prefix of, while the path moves to another socket. Both
/// senders stay writable; what is gated is delivery to the advertised socket, so the descriptor
/// is proved part-sent before the move can complete. The prefix left from the address it was
/// offered on, so the remainder stays with that handle rather than being spliced onto the new
/// one, and the stream arrives whole.
#[tokio::test]
async fn a_part_sent_descriptor_stays_with_its_handle_when_the_path_moves() {
    let (client_config, mut server_config) = configs();
    server_config.set_transport_config(Arc::new(
        crate::TransportConfig::default()
            .try_with_initial_congestion_window(u64::from(u32::MAX) + 1)
            .unwrap(),
    ));
    let (listener, listener_log, segments) = segmenting_socket_from(
        std::net::UdpSocket::bind((Ipv4Addr::UNSPECIFIED, 0)).unwrap(),
        1,
    );
    let (advertised, advertised_log) = recording_socket();
    let advertised_addr = advertised.local_addr();
    let SocketAddr::V4(advertised_v4) = advertised_addr else {
        panic!("the fixture binds an IPv4 loopback socket");
    };
    // Nothing reaches the endpoint through the advertised socket until this test opens it, so the
    // client's probes cannot be answered and the move waits. Its sender stays writable throughout.
    close_receive(&advertised_log);
    server_config.set_preferred_address_v4(advertised_v4);
    let server = endpoint_with(
        EndpointConfig::try_with_rand_key().unwrap(),
        Some(server_config),
        listener,
    );
    let initial = SocketAddr::new(
        Ipv4Addr::LOCALHOST.into(),
        server.local_addr().unwrap().port(),
    );
    server.advertise_abstract(advertised).unwrap();

    let client = Endpoint::bind_client(rama_core::rt::Executor::new(), localhost_v4())
        .await
        .unwrap();
    let (c, s) = connect_through(&client, &server, client_config.clone(), initial).await;
    exchange(&s, &c, b"before").await;
    assert!(
        s.sends_from_for(initial),
        "the wildcard handle covers the concrete path"
    );
    // Receiving application data does not imply that NEW_CONNECTION_ID arrived. The server
    // replaces CID 0 when it does; settle that transition before holding a descriptor for a move.
    wait_for(
        "the server replaced its handshake destination CID",
        Duration::from_secs(5),
        || s.active_dcid_seq() != 0,
    )
    .await;
    listener_log.lock().hold_destination = Some(SocketAddress::from(client.local_addr().unwrap()));
    segments.arm();

    // A payload offered as one segmented descriptor, held after one accepted segment.
    let payload: Vec<u8> = (0..octets::kib(16)).map(|i| (i % 251) as u8).collect();
    let mut stream = s.open_uni().await.unwrap();
    stream.write_all(&payload).await.unwrap();
    stream.finish().unwrap();
    wait_for(
        "a segment of the descriptor was accepted and the rest held",
        Duration::from_secs(20),
        || {
            let log = listener_log.lock();
            log.rejected.is_some() && !log.fallback().is_empty()
        },
    )
    .await;
    let accepted_before: Vec<Vec<u8>> = listener_log
        .lock()
        .sent
        .iter()
        .map(|datagram| datagram.bytes.clone())
        .collect();
    let peer = client.local_addr().unwrap();
    let (held_bytes, _, held_cid) = s
        .held_transmit()
        .expect("the part-sent descriptor waits on the handle that took its prefix");
    assert_eq!(
        held_bytes,
        listener_log.lock().rejected.as_ref().unwrap().0.bytes,
        "the held descriptor is the one whose prefix the socket accepted"
    );
    assert!(
        s.descriptors().iter().any(|descriptor| {
            descriptor.bytes == held_bytes
                && descriptor.outcome == Outcome::Pending
                && descriptor.reported
        }),
        "the partial send itself reported its CID before the descriptor completed"
    );
    {
        let log = listener_log.lock();
        let prefix = &log.fallback()[0];
        assert_eq!(
            prefix.source,
            Some(initial.ip()),
            "the wildcard sender uses the concrete source"
        );
        assert_eq!(prefix.destination, SocketAddress::from(peer));
        assert!(log.segmented_offers.iter().any(|count| *count >= 3));
    }
    let retained = s.retained_send_bytes();
    let widest = s.max_datagram_payload();
    assert!(retained.buffer <= 2 * MAX_TRANSMIT_SEGMENTS * widest);
    assert!(retained.owned <= (RETAINED_DESCRIPTORS - 1) * MAX_TRANSMIT_SEGMENTS * widest);
    let carried = held_cid.expect("it carries an identifier");
    // The prefix that left carries this descriptor's own identifier, and it is reported as used
    // towards the peer at that moment (RFC 9000 §10.3.1) — before the move, while the queue can
    // still be asked about it.
    assert!(
        s.cid_confirmed_to(carried, peer),
        "the prefix that left reported the identifier it carried"
    );

    // A second connection on the same endpoint progresses while the first suffix is held.
    let other = Endpoint::bind_client(rama_core::rt::Executor::new(), localhost_v4())
        .await
        .unwrap();
    let (other_client, other_server) =
        connect_through(&other, &server, client_config, initial).await;
    exchange(&other_client, &other_server, b"independent client traffic").await;
    exchange(&other_server, &other_client, b"independent server traffic").await;
    assert_eq!(
        listener_log
            .lock()
            .fallback()
            .iter()
            .filter(|packet| packet.destination == SocketAddress::from(peer))
            .count(),
        1,
        "the original suffix has not been released"
    );
    assert_eq!(
        server.stats().retained_sockets,
        2,
        "listener and advertised socket remain bounded"
    );
    assert!(
        s.held_transmit().is_some_and(|held| held.0 == held_bytes)
            || s.aside_transmit().is_some_and(|held| held.1 == held_bytes),
        "the original descriptor remains retained during the independent exchanges"
    );

    // Now the probes are delivered and the move completes while that descriptor is still waiting
    // on the handle that took part of it.
    open_receive(&advertised_log);
    wait_for(
        "the candidate path was answered while the handle in use was stuck",
        Duration::from_secs(20),
        || !advertised_log.lock().sent.is_empty(),
    )
    .await;
    assert!(
        s.held_transmit().is_some() || s.sending_from() == Some(advertised_addr),
        "the descriptor the listener took a prefix of was still waiting on it"
    );
    uncredit_segments(&listener_log);
    open_segment_hold(&listener_log);
    wait_for("the connection moved", Duration::from_secs(20), || {
        s.sending_from() == Some(advertised_addr)
    })
    .await;

    // The stream arrives whole and in order: nothing was spliced onto another sender.
    let mut incoming = tokio::time::timeout(Duration::from_secs(20), c.accept_uni())
        .await
        .expect("the stream arrives")
        .expect("the connection is alive");
    let received = tokio::time::timeout(
        Duration::from_secs(20),
        incoming.read_to_end(payload.len() + 1),
    )
    .await
    .expect("the stream completes")
    .expect("it is not truncated");
    assert_eq!(received, payload, "every byte, in order");

    // No datagram repeats one the listener had already accepted.
    let after: Vec<Vec<u8>> = listener_log
        .lock()
        .sent
        .iter()
        .map(|datagram| datagram.bytes.clone())
        .collect();
    for (i, datagram) in after.iter().enumerate().skip(accepted_before.len()) {
        assert!(
            !accepted_before.contains(datagram),
            "datagram {i} repeats one already accepted"
        );
    }
    // The move retires that identifier, and a retired one is gone from the queue: it may never
    // be sent again and the queue no longer answers for what was sent with it. So the report
    // above is the observation that counts, and asking again here would prove nothing. The
    // retirement lands with the peer's frames that follow the move, so it is waited for.
    wait_for(
        "the identifier the prefix carried is retired by the move",
        Duration::from_secs(20),
        || s.send_permit(carried, peer) == crate::proto::SendPermit::Obsolete,
    )
    .await;
    assert!(
        !s.cid_confirmed_to(carried, peer),
        "and the queue no longer answers for it"
    );
    // The path the connection sends on now has its own identifier, and what left on it is
    // reported the same way.
    let now_active = s.active_dcid_seq();
    assert!(
        s.cid_confirmed_to(now_active, peer),
        "the identifier the connection sends with now is used towards the peer"
    );
    assert_eq!(
        s.unowned_paths(),
        0,
        "no datagram wanted a socket the endpoint did not have"
    );
    exchange(&c, &s, b"after the pending move").await;
    wait_for(
        "the partial descriptor drained",
        Duration::from_secs(5),
        || s.retained_send_bytes().slots == 0,
    )
    .await;
    drop((c, s, other_client, other_server));
    tokio::join!(client.shutdown(), other.shutdown(), server.shutdown());
}

/// The identifier gate holds on the candidate path as it does on the path in use. The answer to a
/// challenge that arrived on another path carries the identifier bound to that path, and nothing
/// of it reaches the wire until the endpoint has installed the route by which a stateless reset
/// answering it would come back (RFC 9000 §10.3.1). The socket for that path is writable
/// throughout: what holds the datagram is the gate.
#[tokio::test]
async fn a_candidate_paths_answer_waits_for_its_route_with_nothing_on_the_wire() {
    let (client_config, mut server_config) = configs();
    let (listener, _listener_log) = recording_socket();
    let (advertised, advertised_log) = recording_socket();
    let advertised_addr = advertised.local_addr();
    let SocketAddr::V4(advertised_v4) = advertised_addr else {
        panic!("the fixture binds an IPv4 loopback socket");
    };
    server_config.set_preferred_address_v4(advertised_v4);
    // Nothing arrives through the advertised socket until the hold is in place, so the challenge
    // cannot be answered before the gate under test exists.
    close_receive(&advertised_log);
    let server = endpoint_with(
        EndpointConfig::try_with_rand_key().unwrap(),
        Some(server_config),
        listener,
    );
    let initial = server.local_addr().unwrap();
    server.advertise_abstract(advertised).unwrap();

    let client = Endpoint::bind_client(rama_core::rt::Executor::new(), localhost_v4())
        .await
        .unwrap();
    let peer = client.local_addr().unwrap();
    let (c, s) = connect_through(&client, &server, client_config, initial).await;
    exchange(&c, &s, b"on the initial path").await;

    server.inner.hold_route_installs();
    open_receive(&advertised_log);
    wait_for(
        "the answer waits on the candidate path's handle",
        Duration::from_secs(5),
        || s.aside_transmit().is_some(),
    )
    .await;
    let (serves, _, carried) = s.aside_transmit().expect("it waits there");
    assert_eq!(serves, advertised_addr);
    let carried = carried.expect("the answer carries an identifier");
    assert_eq!(
        s.send_permit(carried, peer),
        crate::proto::SendPermit::AwaitingInstallation,
        "and it is the route, not the socket, that is holding it"
    );
    assert!(
        advertised_log.lock().sent.is_empty(),
        "nothing reached the wire from the candidate path's socket"
    );
    // The path in use is not held up by any of this.
    exchange(&c, &s, b"while the answer waits").await;
    exchange(&s, &c, b"and back").await;

    server.inner.release_route_installs();
    wait_for(
        "the answer leaves once its route is installed",
        Duration::from_secs(5),
        || !advertised_log.lock().sent.is_empty(),
    )
    .await;
    drop((c, s));
    tokio::join!(client.shutdown(), server.shutdown());
}

/// The same gate, answered with a refusal: a route that will never exist means the identifier may
/// never be sent, so the answer is given up with the accounting a dropped datagram needs and
/// still nothing reaches that socket's wire (RFC 9000 §9.5).
#[tokio::test]
async fn a_candidate_paths_answer_is_given_up_when_its_route_is_refused() {
    let (client_config, mut server_config) = configs();
    let (listener, _listener_log) = recording_socket();
    let (advertised, advertised_log) = recording_socket();
    let advertised_addr = advertised.local_addr();
    let SocketAddr::V4(advertised_v4) = advertised_addr else {
        panic!("the fixture binds an IPv4 loopback socket");
    };
    server_config.set_preferred_address_v4(advertised_v4);
    close_receive(&advertised_log);
    let server = endpoint_with(
        EndpointConfig::try_with_rand_key().unwrap(),
        Some(server_config),
        listener,
    );
    let initial = server.local_addr().unwrap();
    server.advertise_abstract(advertised).unwrap();

    let client = Endpoint::bind_client(rama_core::rt::Executor::new(), localhost_v4())
        .await
        .unwrap();
    let (c, s) = connect_through(&client, &server, client_config, initial).await;
    exchange(&c, &s, b"on the initial path").await;

    server.inner.hold_route_installs();
    open_receive(&advertised_log);
    wait_for(
        "the answer waits on the candidate path's handle",
        Duration::from_secs(5),
        || s.aside_transmit().is_some(),
    )
    .await;
    let given_up = s.stale_transmits();

    server.inner.refuse_route_installs();
    wait_for("the answer is given up", Duration::from_secs(5), || {
        s.stale_transmits() > given_up
    })
    .await;
    assert!(
        advertised_log.lock().sent.is_empty(),
        "and nothing carrying that identifier reached the wire"
    );
    drop((c, s));
    tokio::join!(client.shutdown(), server.shutdown());
}

/// Sustained pressure from a path that takes nothing, against a path that does. The candidate
/// socket keeps the waker and never accepts, so what the engine produces for that path piles up
/// against a handle that is already occupied; with the pass allowance lowered, that pressure
/// crosses more than one poll's worth of work. The path in use carries exchange after exchange
/// throughout, and nothing of the candidate path's traffic reaches the wire.
#[tokio::test]
async fn a_path_that_takes_nothing_does_not_starve_the_one_that_does() {
    let (client, server, c, s, advertised_addr, advertised_log, client_addr, _listener_log) =
        preferring_server_with_a_stuck_candidate().await;

    wait_for(
        "the candidate path's datagram waits on that path's handle",
        Duration::from_secs(5),
        || s.aside_transmit().is_some(),
    )
    .await;
    // Two datagrams a pass, so the work below is many passes' worth rather than one.
    s.set_pass_allowance(2);
    let passes_before = s.send_passes();

    for round in 0..10u8 {
        let up = [b'u', round];
        let down = [b'd', round];
        exchange(&c, &s, &up).await;
        exchange(&s, &c, &down).await;
    }

    assert!(
        s.send_passes() - passes_before > 10,
        "the exchanges took many passes, not one"
    );
    assert_eq!(
        sent_to(&advertised_log, client_addr),
        0,
        "and nothing left the socket that takes nothing"
    );
    assert!(
        s.aside_transmit().is_some(),
        "whose datagram is still waiting on its own handle"
    );
    assert_eq!(
        s.aside_address(),
        Some(advertised_addr),
        "which is still the handle for that path"
    );
    assert_eq!(
        s.unowned_paths(),
        0,
        "no datagram wanted a socket the endpoint did not have"
    );

    drop((c, s));
    tokio::time::timeout(Duration::from_secs(10), async {
        tokio::join!(client.shutdown(), server.shutdown())
    })
    .await
    .expect("shutdown does not wait for the stuck candidate");
}

/// A descriptor whose bytes are gone from the send buffer is retired, never offered: one left
/// pointing at that buffer would carry the next descriptor's bytes to the address the old one
/// named. One ownership attempt is made to find nothing, and the descriptor is given up once,
/// never sent, while the connection goes on.
#[tokio::test]
async fn a_descriptor_whose_bytes_are_gone_is_retired_rather_than_carried() {
    let (client_config, mut server_config) = configs();
    let (listener, _listener_log) = recording_socket();
    let (advertised, advertised_log) = recording_socket();
    // Keep the first candidate probe unread until the ownership fault is armed.
    close_receive(&advertised_log);
    let advertised_addr = advertised.local_addr();
    let SocketAddr::V4(advertised_v4) = advertised_addr else {
        panic!("the fixture binds an IPv4 loopback socket");
    };
    server_config.set_preferred_address_v4(advertised_v4);
    let server = endpoint_with(
        EndpointConfig::try_with_rand_key().unwrap(),
        Some(server_config),
        listener,
    );
    let initial = server.local_addr().unwrap();
    server
        .advertise_abstract(advertised)
        .expect("the endpoint takes the advertised socket");

    let client = Endpoint::bind_client(rama_core::rt::Executor::new(), localhost_v4())
        .await
        .expect("the client binds");
    let client_addr = client.local_addr().unwrap();
    // The advertised socket takes nothing, so the candidate path's datagram is kept across
    // passes: it is the descriptor that has to own its bytes.
    block_segments_for(&advertised_log, SocketAddress::from(client_addr));

    let (c, s) = connect_through(&client, &server, client_config, initial).await;

    // From here, the next attempt to take a descriptor's bytes finds nothing where they were.
    assert!(s.aside_transmit().is_none());
    s.fail_next_ownership();
    open_receive(&advertised_log);

    // Traffic on the path in use, so the engine keeps writing into the same buffer.
    exchange(&c, &s, b"while a descriptor loses its bytes").await;
    exchange(&s, &c, b"and the engine writes more").await;
    wait_for(
        "the armed ownership attempt retires its descriptor",
        Duration::from_secs(5),
        || s.stale_transmits() != 0,
    )
    .await;
    assert_eq!(
        s.stale_transmits(),
        1,
        "exactly the descriptor whose bytes were gone is given up"
    );

    let offered = s.descriptors();
    let retired = offered
        .iter()
        .find(|descriptor| descriptor.outcome == Outcome::Obsolete)
        .expect("the retirement is recorded");
    assert!(
        !offered.iter().any(|descriptor| {
            descriptor.id == retired.id && descriptor.outcome == Outcome::Sent
        }),
        "and it is never offered as sent"
    );
    assert!(
        !offered
            .iter()
            .any(|descriptor| descriptor.id == retired.id && descriptor.bytes != retired.bytes),
        "nor with any bytes other than the ones it was retired with"
    );
    assert_eq!(
        sent_to(&advertised_log, client_addr),
        0,
        "nothing left by the socket that takes nothing"
    );

    // The connection goes on, and the candidate path is probed again.
    exchange(&c, &s, b"after the retirement").await;
    assert_ne!(c.remote_address(), advertised_addr, "the path is unchanged");
    wait_for(
        "the candidate path is probed again",
        Duration::from_secs(10),
        || s.aside_transmit().is_some(),
    )
    .await;

    drop((c, s));
    tokio::time::timeout(Duration::from_secs(10), async {
        tokio::join!(client.shutdown(), server.shutdown())
    })
    .await
    .expect("shutdown stays bounded");
}

/// Both handles held at once, with the pass allowance spent. The candidate's socket never takes
/// anything and the path in use stops taking anything either, so a pass that spends its
/// allowance has placed nothing, given up nothing and produced nothing. It asks for no further
/// turn: the wakers it left behind are what bring the connection back. When the path in use
/// opens, the waiting bytes arrive and shutdown stays bounded.
///
/// While both are held, each descriptor's bytes are its own, so this is also where the retained
/// storage of the waiting descriptors is measured and where its release is observed.
#[tokio::test]
async fn a_spent_allowance_with_both_handles_held_asks_for_no_further_turn() {
    let (client, server, c, s, advertised_addr, advertised_log, client_addr, listener_log) =
        preferring_server_with_a_stuck_candidate().await;

    wait_for(
        "the candidate path's datagram waits on that path's handle",
        Duration::from_secs(5),
        || s.aside_transmit().is_some(),
    )
    .await;
    assert_eq!(
        s.aside_address(),
        Some(advertised_addr),
        "the handle held aside is the candidate path's"
    );

    // One datagram spends the allowance, so a pass reaches the end of its budget on the first
    // offer rather than after twenty.
    s.set_pass_allowance(1);
    block_segments_for(&listener_log, SocketAddress::from(client_addr));
    let payload = b"held on both handles";
    let mut stream = s.open_uni().await.unwrap();
    stream.write_all(payload).await.unwrap();
    stream.finish().unwrap();
    wait_for(
        "the path in use holds a datagram of its own",
        Duration::from_secs(5),
        || s.held_transmit().is_some(),
    )
    .await;

    let (held, _, _) = s.held_transmit().expect("the path in use holds one");
    assert!(!held.is_empty(), "and it is a datagram, not an empty offer");
    assert!(
        s.aside_transmit().is_some(),
        "while the candidate's still waits"
    );

    // Arrivals are held back from here on, so what the connection does next is its own.
    close_receive(&listener_log);
    let parked_before = s.allowance_parked_without_progress();
    let passes_before = s.send_passes();
    let stale_before = s.stale_transmits();

    // The branch under test: a pass spends its allowance with both handles held and asks for no
    // further turn.
    wait_for(
        "a pass spent its allowance without advancing",
        Duration::from_secs(5),
        || s.allowance_parked_without_progress() > parked_before,
    )
    .await;
    assert!(
        s.held_transmit().is_some() && s.aside_transmit().is_some(),
        "both handles are still held, so the pass had nowhere to place anything"
    );
    assert_eq!(
        s.stale_transmits(),
        stale_before,
        "nothing was given up while waiting"
    );

    // Both waiting descriptors carry their own bytes; that storage is bounded and released.
    let widest = s.max_datagram_payload();
    let waiting = s.retained_send_bytes();
    assert!(
        waiting.slots > 0 && waiting.owned > 0,
        "the waiting descriptors hold bytes of their own: {waiting:?}"
    );
    assert!(
        waiting.slots < RETAINED_DESCRIPTORS,
        "and fewer than the buffer's own share of the slots: {waiting:?}"
    );
    assert!(
        waiting.owned <= (RETAINED_DESCRIPTORS - 1) * MAX_TRANSMIT_SEGMENTS * widest,
        "owned {} over the bound for a payload of {widest}",
        waiting.owned
    );
    assert!(
        waiting.buffer <= 2 * MAX_TRANSMIT_SEGMENTS * widest,
        "buffer {} over the bound for a payload of {widest}",
        waiting.buffer
    );

    // A finite ceiling on the passes taken while nothing can be sent. Loss-recovery timers keep
    // firing, so this is a sanity bound rather than the proof above.
    tokio::time::sleep(Duration::from_millis(100)).await;
    assert!(
        s.send_passes() - passes_before < 100,
        "the passes taken while both handles were held stay finite: {}",
        s.send_passes() - passes_before
    );

    // Opening the path in use releases its descriptor: the bytes arrive and the passes resume.
    let passes_at_unblock = s.send_passes();
    open_receive(&listener_log);
    unblock_segments(&listener_log);
    let mut incoming = tokio::time::timeout(Duration::from_secs(10), c.accept_uni())
        .await
        .expect("the stream arrives once the path in use opens")
        .expect("the connection is alive");
    let received = tokio::time::timeout(
        Duration::from_secs(10),
        incoming.read_to_end(payload.len() + 1),
    )
    .await
    .expect("the stream completes")
    .expect("it is not truncated");
    assert_eq!(received, payload, "every byte the writer offered");
    assert!(
        s.send_passes() > passes_at_unblock,
        "the connection ran again once a handle opened"
    );
    // Traffic keeps flowing on the path in use while the candidate takes nothing at all. The
    // storage held for the waiting descriptors is bounded throughout rather than accumulating.
    for round in 0..10u8 {
        exchange(&s, &c, &[b'p', round]).await;
        let held = s.retained_send_bytes();
        assert!(
            held.slots <= RETAINED_DESCRIPTORS
                && held.owned <= (RETAINED_DESCRIPTORS - 1) * MAX_TRANSMIT_SEGMENTS * widest
                && held.buffer <= 2 * MAX_TRANSMIT_SEGMENTS * widest,
            "round {round} holds {held:?} for a payload of {widest}"
        );
    }
    assert!(
        s.aside_transmit().is_some(),
        "the candidate's descriptor is still there, since its socket still takes nothing"
    );

    // Letting the candidate's socket take its datagram releases the last of that storage.
    unblock_segments(&advertised_log);
    wait_for(
        "every waiting descriptor released its bytes",
        Duration::from_secs(10),
        || s.retained_send_bytes().slots == 0,
    )
    .await;
    assert_eq!(
        s.retained_send_bytes().owned,
        0,
        "and none of that storage is still held"
    );

    drop((c, s));
    tokio::time::timeout(Duration::from_secs(10), async {
        tokio::join!(client.shutdown(), server.shutdown())
    })
    .await
    .expect("shutdown does not wait for the stuck candidate");
}

/// A wildcard listener does not own the concrete address the path names, so the connection
/// records that this socket covers it, and the handle in use answers for it. The covered
/// address is answered while another concrete address on the same port is not, and neither is
/// the address the handle is bound to.
///
/// That the record stops answering once the socket it names is gone is
/// `a_wildcard_listener_and_a_concrete_advertised_socket_keep_their_own_tuples`.
#[tokio::test]
async fn a_covered_address_is_answered_by_the_handle_that_covers_it() {
    let (client_config, server_config) = configs();
    let server = Endpoint::bind_server(
        rama_core::rt::Executor::new(),
        server_config,
        SocketAddr::new(Ipv4Addr::UNSPECIFIED.into(), 0),
    )
    .await
    .expect("the wildcard listener binds");
    let listener = server.local_addr().unwrap();
    assert!(listener.ip().is_unspecified(), "the listener is a wildcard");

    // The client sends to a concrete address of ours that the wildcard listener receives on, so
    // that address, and not the bind, is what the server's path names.
    let reachable = SocketAddr::new(Ipv4Addr::LOCALHOST.into(), listener.port());
    let elsewhere = SocketAddr::new(Ipv4Addr::new(127, 0, 0, 2).into(), listener.port());
    let client = Endpoint::bind_client(rama_core::rt::Executor::new(), localhost_v4())
        .await
        .expect("the client binds");
    let (c, s) = connect_through(&client, &server, client_config, reachable).await;
    exchange(&c, &s, b"through the wildcard listener").await;
    assert_eq!(
        s.sending_from(),
        Some(listener),
        "the handle in use is the wildcard one"
    );
    assert_ne!(
        reachable, listener,
        "and the path's address is not the one it is bound to"
    );

    wait_for(
        "the endpoint told the connection its socket covers the path's address",
        Duration::from_secs(5),
        || s.sends_from_for(reachable),
    )
    .await;
    assert!(
        !s.sends_from_for(elsewhere),
        "another concrete address on the same port is not covered: {elsewhere}"
    );
    // Both directions keep working over the covered path.
    exchange(&s, &c, b"and back over the covered path").await;

    drop((c, s));
    tokio::join!(client.shutdown(), server.shutdown());
}

/// A descriptor the socket took a prefix of, while that socket then fails for a reason of its
/// own. The prefix that left carries this descriptor's identifier and is accounted once, at the
/// moment it left. The failure retires the socket; the connection continues on the one that
/// replaced it, the suffix is never offered to that replacement, and the stream arrives whole
/// because loss recovery resends what the failed socket never delivered.
#[tokio::test]
async fn a_part_sent_descriptor_is_accounted_once_when_its_socket_then_fails() {
    let (client_config, server_config) = configs();
    let server = endpoint_with(
        EndpointConfig::try_with_rand_key().unwrap(),
        Some(server_config),
        Socket::from_std(std::net::UdpSocket::bind((Ipv4Addr::LOCALHOST, 0)).unwrap()).unwrap(),
    );
    let (socket_a, log_a, segments, fault_a) = breakable_segmenting_socket(1);
    let client = endpoint_with(EndpointConfig::try_with_rand_key().unwrap(), None, socket_a);
    let addr_a = client.local_addr().unwrap();
    let (socket_b, log_b) = recording_socket();

    let (c, s) = connect_through(
        &client,
        &server,
        client_config,
        server.local_addr().unwrap(),
    )
    .await;
    exchange(&c, &s, b"before").await;
    segments.arm();

    // One segmented descriptor, held after a prefix of it was accepted.
    let payload: Vec<u8> = (0..octets::kib(16)).map(|i| (i % 251) as u8).collect();
    let mut stream = c.open_uni().await.unwrap();
    stream.write_all(&payload).await.unwrap();
    stream.finish().unwrap();
    wait_for(
        "a segment of the descriptor was accepted and the rest held",
        Duration::from_secs(20),
        || {
            let log = log_a.lock();
            log.rejected.is_some() && !log.fallback().is_empty()
        },
    )
    .await;
    let accepted_by_a: Vec<Vec<u8>> = log_a
        .lock()
        .sent
        .iter()
        .map(|datagram| datagram.bytes.clone())
        .collect();
    let peer = server.local_addr().unwrap();
    let (held_bytes, _, held_cid) = c
        .held_transmit()
        .expect("the part-sent descriptor waits on the handle that took its prefix");
    let carried = held_cid.expect("it carries an identifier");
    assert!(
        c.cid_confirmed_to(carried, peer),
        "the prefix that left reported the identifier it carried"
    );
    let stale_before = c.stale_transmits();

    // A replacement is bound, then the socket holding the suffix fails for its own reason.
    client.rebind_abstract(socket_b).unwrap();
    let addr_b = client.local_addr().unwrap();
    assert_ne!(addr_b, addr_a, "the replacement is a different socket");
    fail_receiver(&client, &fault_a);
    wait_for("the failed socket retires", Duration::from_secs(10), || {
        client.stats().retained_sockets == 1
    })
    .await;
    assert_eq!(client.stats().retired_sockets, 1);
    assert!(
        c.close_reason().is_none(),
        "a socket failing is not the connection failing"
    );

    // The stream still arrives whole: what the failed socket never delivered is resent.
    let mut incoming = tokio::time::timeout(Duration::from_secs(20), s.accept_uni())
        .await
        .expect("the stream arrives")
        .expect("the connection is alive");
    let received = tokio::time::timeout(
        Duration::from_secs(20),
        incoming.read_to_end(payload.len() + 1),
    )
    .await
    .expect("the stream completes")
    .expect("it is not truncated");
    assert_eq!(received, payload, "every byte, in order");

    // Nothing the failed socket had already accepted is offered to the replacement.
    let sent_on_b: Vec<Vec<u8>> = log_b
        .lock()
        .sent
        .iter()
        .map(|datagram| datagram.bytes.clone())
        .collect();
    for (i, datagram) in sent_on_b.iter().enumerate() {
        assert!(
            !accepted_by_a.contains(datagram),
            "datagram {i} on the replacement repeats one the failed socket had accepted"
        );
        assert!(
            !held_bytes
                .windows(datagram.len().max(1))
                .any(|window| window == datagram.as_slice()),
            "datagram {i} on the replacement carries bytes of the suffix the failed socket held"
        );
    }
    assert!(
        log_b.lock().rejected.is_none(),
        "and the replacement was never offered that segmented descriptor at all"
    );
    assert!(
        !sent_on_b.is_empty(),
        "and the replacement did carry the connection's traffic"
    );
    // The descriptor was offered again while its socket held it, and given up exactly once
    // when that socket failed. Its identifier stays accounted as one that reached the network,
    // because a prefix of it did.
    let offers: Vec<_> = c
        .descriptors()
        .into_iter()
        .filter(|descriptor| descriptor.segment_size.is_some())
        .collect();
    assert!(
        offers.len() > 1,
        "the held descriptor was offered again while its socket kept it: {}",
        offers.len()
    );
    let given_up: Vec<_> = offers
        .iter()
        .filter(|descriptor| descriptor.outcome == Outcome::Obsolete)
        .collect();
    assert_eq!(given_up.len(), 1, "and given up once, not once per offer");
    assert!(
        given_up[0].reported,
        "given up where the prefix it left behind is accounted, not quietly later"
    );
    assert_eq!(
        c.stale_transmits(),
        stale_before + 1,
        "one datagram was given up: the suffix that socket still held"
    );
    // The identifier the prefix carried was reported when the prefix left, which is the
    // observation that counts and is asserted above. Moving to the replacement retires it, and
    // a retired identifier is gone from the queue, so asking again here says nothing about the
    // report.
    assert_eq!(
        c.send_permit(carried, peer),
        crate::proto::SendPermit::Obsolete,
        "the identifier the prefix carried is retired with the socket that took it"
    );
    let now_active = c.active_dcid_seq();
    assert!(
        c.cid_confirmed_to(now_active, peer),
        "and the identifier the connection sends with now is used towards the peer"
    );
    assert_eq!(
        c.unowned_paths(),
        0,
        "no datagram wanted a socket the endpoint did not have"
    );

    exchange(&c, &s, b"after the failure").await;
    drop((c, s));
    tokio::time::timeout(Duration::from_secs(10), async {
        tokio::join!(client.shutdown(), server.shutdown())
    })
    .await
    .expect("shutdown stays bounded after the failure");
}
