//! Construction of an endpoint's socket through Rama's shared UDP utilities.

use super::lifecycle::{configs, exchange, handshake};
use crate::{SocketCapacityError, driver::endpoint::*};
use rama_net::socket::SocketOptions;
use rama_udp::{
    DatagramError, DatagramFeature, DatagramSocket as _, UdpSocketConfig,
    test_utils::MemoryDatagramSocket,
};
use std::assert_matches;
use std::{
    net::{Ipv4Addr, Ipv6Addr, SocketAddr},
    num::NonZeroUsize,
    sync::Arc,
};

fn localhost_v4() -> SocketAddr {
    SocketAddr::new(Ipv4Addr::LOCALHOST.into(), 0)
}

/// Connect a client to a server and exchange a payload each way, so a binding is shown to carry
/// data rather than merely to have succeeded.
async fn exchange_both_ways(client: &Endpoint, server: &Endpoint, client_config: ClientConfig) {
    let server_addr = server.local_addr().unwrap();
    let connecting = client
        .connect_with(client_config, server_addr, "localhost")
        .unwrap();
    let incoming = tokio::time::timeout(Duration::from_secs(5), server.accept())
        .await
        .expect("the attempt arrives")
        .expect("the server is listening");
    let (c, s) = handshake(connecting, incoming).await;
    exchange(&c, &s, b"up").await;
    exchange(&s, &c, b"down").await;
    drop((c, s));
}

/// The default client and server bindings go through the shared factory and carry data.
#[tokio::test]
async fn default_bindings_carry_data() {
    let (client_config, server_config) = configs();
    let server = Endpoint::bind_server(
        rama_core::rt::Executor::new(),
        server_config,
        localhost_v4(),
    )
    .await
    .expect("the server binds");
    let client = Endpoint::bind_client(rama_core::rt::Executor::new(), localhost_v4())
        .await
        .expect("the client binds");
    assert!(server.local_addr().unwrap().port() != 0);
    exchange_both_ways(&client, &server, client_config).await;
    tokio::join!(client.shutdown(), server.shutdown());
}

/// A socket the caller prepared: the shared configuration wraps it, and the endpoint takes the
/// packet socket that comes out.
#[tokio::test]
async fn a_caller_prepared_socket_carries_data() {
    let (client_config, server_config) = configs();
    let config = UdpSocketConfig::default();
    let prepared = config
        .wrap_std(std::net::UdpSocket::bind(localhost_v4()).unwrap())
        .expect("the socket is wrapped");
    let server = Endpoint::new_server_with_packet_socket(
        rama_core::rt::Executor::new(),
        server_config,
        prepared,
    )
    .expect("the server takes the prepared socket");

    // The caller puts the socket in non-blocking mode and hands it to the runtime; registering
    // it does not do that. The wrapping only sets up the metadata this configuration asks for.
    let bound = std::net::UdpSocket::bind(localhost_v4()).unwrap();
    bound.set_nonblocking(true).unwrap();
    let prepared = config
        .wrap_tokio(rama_udp::UdpSocket::from_std(bound).unwrap())
        .expect("a registered socket is wrapped");
    let client = Endpoint::new_client_with_packet_socket(rama_core::rt::Executor::new(), prepared)
        .expect("the client takes the prepared socket");

    exchange_both_ways(&client, &server, client_config).await;
    tokio::join!(client.shutdown(), server.shutdown());
}

/// IPv6-level requests, strict or best effort, are skipped for IPv4 sockets.
#[tokio::test]
async fn ipv6_only_requests_strict_or_best_effort_skip_ipv4() {
    let mut options = SocketOptions::default_udp();
    options.only_v6 = Some(true);
    let strict = UdpSocketConfig::default().with_socket_options(options);
    let endpoint = Endpoint::build(rama_core::rt::Executor::new())
        .bind_address_with_socket_config(localhost_v4(), strict)
        .await
        .expect("a strict IPv6-level option does not apply to an IPv4 bind");
    let address = endpoint.local_addr().unwrap();
    assert_eq!(address.ip(), Ipv4Addr::LOCALHOST);
    assert_ne!(address.port(), 0);
    endpoint.shutdown().await;

    let mut options = SocketOptions::default_udp();
    options.only_v6_best_effort = Some(true);
    let best_effort = UdpSocketConfig::default().with_socket_options(options);
    let endpoint = Endpoint::build(rama_core::rt::Executor::new())
        .bind_address_with_socket_config(localhost_v4(), best_effort)
        .await
        .expect("a best-effort option does not fail an IPv4 bind");
    let address = endpoint.local_addr().unwrap();
    assert_eq!(address.ip(), Ipv4Addr::LOCALHOST);
    assert_ne!(address.port(), 0);
    endpoint.shutdown().await;
}

/// The client asks for a dual-stack socket only where that means something, and never as a strict
/// option; a server asks for nothing beyond the platform's defaults.
#[test]
fn the_dual_stack_request_belongs_to_an_ipv6_client() {
    let v6 = client_socket_config(SocketAddress::new(Ipv6Addr::LOCALHOST.into(), 0));
    assert_eq!(v6.socket_options().only_v6_best_effort, Some(false));
    assert_eq!(v6.socket_options().only_v6, None);

    let v4 = client_socket_config(SocketAddress::new(Ipv4Addr::LOCALHOST.into(), 0));
    assert_eq!(v4.socket_options().only_v6_best_effort, None);
    assert_eq!(v4.socket_options().only_v6, None);

    let server = UdpSocketConfig::default();
    assert_eq!(server.socket_options().only_v6_best_effort, None);
    assert_eq!(server.socket_options().only_v6, None);
}

/// A required feature is refused when the socket cannot provide it and accepted when it can. What
/// a socket configured this way can do is asked of a socket built the same way, rather than
/// inferred from a default one: on Linux the original-destination options are set when requested,
/// so the feature can be available there.
#[tokio::test]
async fn a_required_feature_is_refused_only_when_the_socket_lacks_it() {
    let feature = DatagramFeature::ReceiveOriginalDestination;
    let probe = UdpSocketConfig::default().with_receive_original_destination(true);
    let probed = probe.wrap_std(std::net::UdpSocket::bind(localhost_v4()).unwrap());

    let config = UdpSocketConfig::default().with_required_feature(feature);
    let bound = Endpoint::build(rama_core::rt::Executor::new())
        .bind_address_with_socket_config(localhost_v4(), config)
        .await;
    match probed {
        Ok(socket) if socket.capabilities().supports(feature) => {
            let endpoint = bound.expect("the platform provides the feature when asked");
            endpoint.shutdown().await;
        }
        Ok(_) => {
            let error = bound.expect_err("the feature is not available on this socket");
            assert_matches!(
                error,
                DatagramError::Unsupported(refused) if refused == feature,
                "the refusal names the feature: {error:?}",
            );
        }
        Err(setup) => panic!(
            "an unexpected error: the metadata setup turns a refused socket option into a \
             capability the socket does not have, so this configuration either provides the \
             feature or is refused by name: {setup:?}, and the endpoint gave {bound:?}"
        ),
    }
}

/// An IPv6 client and server, bound through the same construction, carry data. The client's
/// dual-stack request is best effort, so a platform that refuses it leaves an endpoint that still
/// works over IPv6.
#[tokio::test]
async fn ipv6_bindings_carry_data() {
    let (client_config, server_config) = configs();
    let localhost_v6 = SocketAddr::new(Ipv6Addr::LOCALHOST.into(), 0);
    let server = Endpoint::bind_server(rama_core::rt::Executor::new(), server_config, localhost_v6)
        .await
        .expect("the server binds");
    let client = Endpoint::bind_client(rama_core::rt::Executor::new(), localhost_v6)
        .await
        .expect("the client binds");
    assert!(client.local_addr().unwrap().is_ipv6());
    assert!(server.local_addr().unwrap().is_ipv6());
    exchange_both_ways(&client, &server, client_config).await;
    tokio::join!(client.shutdown(), server.shutdown());
}

/// An address already in use fails the bind and the rebind with the platform's own error, once.
/// The endpoint that holds the address keeps working, and a rebind that failed leaves the endpoint
/// on the socket it had.
#[tokio::test]
async fn an_occupied_address_fails_once_and_changes_nothing() {
    let (client_config, server_config) = configs();
    let server = Endpoint::bind_server(
        rama_core::rt::Executor::new(),
        server_config,
        localhost_v4(),
    )
    .await
    .expect("the server binds");
    let occupied = server.local_addr().unwrap();

    let error = Endpoint::build(rama_core::rt::Executor::new())
        .bind_address_with_socket_config(occupied, UdpSocketConfig::default())
        .await
        .expect_err("the address is taken");
    assert_matches!(
        &error,
        DatagramError::Io(error) if error.kind() == io::ErrorKind::AddrInUse,
        "the platform's own error, not a retry's: {error:?}",
    );

    let client = Endpoint::bind_client(rama_core::rt::Executor::new(), localhost_v4())
        .await
        .expect("the client binds");
    // A connection is open across the failed rebind, so what survives it is observable.
    let connecting = client
        .connect_with(client_config.clone(), occupied, "localhost")
        .unwrap();
    let incoming = tokio::time::timeout(Duration::from_secs(5), server.accept())
        .await
        .expect("the attempt arrives")
        .expect("the server is listening");
    let (open_client, open_server) = handshake(connecting, incoming).await;
    exchange(&open_client, &open_server, b"before the failed rebind").await;

    let before = client.local_addr().unwrap();
    let error = client
        .rebind(occupied, UdpSocketConfig::default())
        .await
        .expect_err("the rebind cannot take that address either");
    assert_matches!(
        &error,
        DatagramError::Io(error) if error.kind() == io::ErrorKind::AddrInUse,
        "the same error: {error:?}",
    );
    assert_eq!(
        client.local_addr().unwrap(),
        before,
        "the endpoint stays on the socket it had"
    );

    // The connection that was open across the failed rebind still carries data, and a new one can
    // still be established.
    exchange(&open_client, &open_server, b"after the failed rebind").await;
    exchange(&open_server, &open_client, b"and back").await;
    drop((open_client, open_server));
    exchange_both_ways(&client, &server, client_config).await;
    tokio::join!(client.shutdown(), server.shutdown());
}

/// A rebind through the shared construction moves the endpoint to the new address, and the
/// connection that was already open keeps working.
#[tokio::test]
async fn a_rebind_through_the_shared_construction_keeps_the_connection() {
    let (client_config, server_config) = configs();
    let server = Endpoint::bind_server(
        rama_core::rt::Executor::new(),
        server_config,
        localhost_v4(),
    )
    .await
    .expect("the server binds");
    let client = Endpoint::bind_client(rama_core::rt::Executor::new(), localhost_v4())
        .await
        .expect("the client binds");
    let first = client.local_addr().unwrap();
    let server_addr = server.local_addr().unwrap();
    let connecting = client
        .connect_with(client_config, server_addr, "localhost")
        .unwrap();
    let incoming = tokio::time::timeout(Duration::from_secs(5), server.accept())
        .await
        .expect("the attempt arrives")
        .expect("the server is listening");
    let (c, s) = handshake(connecting, incoming).await;
    exchange(&c, &s, b"before").await;

    client
        .rebind(localhost_v4(), UdpSocketConfig::default())
        .await
        .expect("the rebind binds a new socket");
    let second = client.local_addr().unwrap();
    assert_ne!(first, second, "the endpoint sends from the new socket");
    exchange(&c, &s, b"after").await;
    exchange(&s, &c, b"back").await;

    drop((c, s));
    tokio::join!(client.shutdown(), server.shutdown());
}

/// Every path that registers a socket with the runtime reports the absence of one rather than
/// panicking inside Tokio: the endpoint's own bound-socket entry, the shared wrapping, and the
/// binding future when it is polled outside a runtime.
#[test]
fn registering_a_socket_outside_a_runtime_is_refused() {
    let socket = std::net::UdpSocket::bind(localhost_v4()).unwrap();
    let error = Endpoint::build(rama_core::rt::Executor::new())
        .with_std_socket(socket)
        .expect_err("there is no runtime to register the socket with");
    assert_matches!(error, DatagramError::Io(ref error) if error.kind() == io::ErrorKind::Other);

    let socket = std::net::UdpSocket::bind(localhost_v4()).unwrap();
    let error = UdpSocketConfig::default()
        .wrap_std(socket)
        .expect_err("the shared wrapping registers the socket too");
    assert_matches!(
        &error,
        DatagramError::Io(error) if error.kind() == io::ErrorKind::Other,
        "the error carries its cause: {error:?}",
    );

    let mut binding = std::pin::pin!(
        Endpoint::build(rama_core::rt::Executor::new())
            .bind_address_with_socket_config(localhost_v4(), UdpSocketConfig::default())
    );
    let mut cx = Context::from_waker(Waker::noop());
    match binding.as_mut().poll(&mut cx) {
        Poll::Ready(Err(DatagramError::Io(error))) => {
            assert_eq!(error.kind(), io::ErrorKind::Other);
        }
        other => panic!("the binding resolves with that error: {other:?}"),
    }
}

/// The server's path uses the canonical IPv4 destination reported by a dual-stack
/// receiver even though the socket itself is bound to the IPv6 wildcard.
#[tokio::test]
async fn a_dual_stack_wildcard_server_answers_an_ipv4_client() {
    let (client_config, server_config) = configs();
    let mut options = SocketOptions::default_udp();
    options.only_v6 = Some(false);
    let server = Endpoint::build(rama_core::rt::Executor::new())
        .with_server_config(server_config)
        .with_shutdown_budget(Duration::from_millis(100))
        .bind_address_with_socket_config(
            SocketAddr::new(Ipv6Addr::UNSPECIFIED.into(), 0),
            UdpSocketConfig::default().with_socket_options(options),
        )
        .await
        .expect("the explicit dual-stack listener binds");
    let bound = server.local_addr().unwrap();
    assert!(bound.is_ipv6() && bound.ip().is_unspecified());
    let client = Endpoint::build(rama_core::rt::Executor::new())
        .with_shutdown_budget(Duration::from_millis(100))
        .bind_address(localhost_v4())
        .await
        .unwrap();
    let connecting = client
        .connect_with(
            client_config,
            SocketAddr::new(Ipv4Addr::LOCALHOST.into(), bound.port()),
            "localhost",
        )
        .unwrap();
    let incoming = tokio::time::timeout(Duration::from_secs(2), server.accept())
        .await
        .expect("the IPv4 Initial reaches the dual-stack listener")
        .unwrap();
    assert_eq!(incoming.local_ip(), Some(Ipv4Addr::LOCALHOST.into()));
    let transfer = tokio::time::timeout(Duration::from_secs(3), async {
        let accepted = incoming.accept().unwrap();
        let (client_connection, server_connection) = tokio::join!(connecting, accepted);
        let (c, s) = (client_connection.unwrap(), server_connection.unwrap());
        exchange(&c, &s, b"IPv4 through an IPv6 wildcard").await;
        exchange(&s, &c, b"and back from the same socket").await;
    })
    .await;
    tokio::time::timeout(Duration::from_secs(2), async {
        tokio::join!(client.shutdown(), server.shutdown());
    })
    .await
    .expect("the endpoints release their drivers");
    transfer.expect("the dual-stack server sends its handshake and application data");
}

/// Receiving ordinary IPv6 traffic never lets an IPv6-only wildcard socket cover IPv4.
#[tokio::test]
async fn an_ipv6_only_wildcard_receiver_does_not_cover_ipv4() {
    let mut options = SocketOptions::default_udp();
    options.only_v6 = Some(true);
    let packet = UdpSocketFactory::new(UdpSocketConfig::default().with_socket_options(options))
        .bind(SocketAddr::new(Ipv6Addr::UNSPECIFIED.into(), 0))
        .await
        .unwrap();
    let mut socket = Socket::new(packet).unwrap();
    let port = socket.local_addr().port();
    let peer = tokio::net::UdpSocket::bind(SocketAddr::new(Ipv6Addr::LOCALHOST.into(), 0))
        .await
        .unwrap();
    peer.send_to(b"ipv6", SocketAddr::new(Ipv6Addr::LOCALHOST.into(), port))
        .await
        .unwrap();
    let mut buffer = [0; 32];
    let mut buffers = [IoSliceMut::new(&mut buffer)];
    let mut metadata = [DatagramMetadata::empty()];
    let received = tokio::time::timeout(
        Duration::from_secs(2),
        std::future::poll_fn(|cx| socket.poll_recv(cx, &mut buffers, &mut metadata)),
    )
    .await
    .unwrap()
    .unwrap();
    assert_eq!(received, 1);
    assert_eq!(metadata[0].peer.ip_addr, Ipv6Addr::LOCALHOST);
    let registry = SocketRegistry::new(socket);
    let ipv4 = SocketAddr::new(Ipv4Addr::LOCALHOST.into(), port);
    assert!(!registry.covers_local(registry.active_id(), ipv4));
    assert_eq!(registry.only_cover_for(ipv4), None);
}

/// One wildcard client keeps a usable local port in both families even when IPv4-only sockets
/// occupy part of the ephemeral namespace. Both handshakes and application data use that port.
#[cfg(target_vendor = "apple")]
#[tokio::test]
async fn a_dual_stack_client_carries_both_families_with_occupied_ipv4_ports() {
    let held: Vec<_> = (0..64)
        .map(|_| std::net::UdpSocket::bind(SocketAddr::from(SocketAddress::local_ipv4(0))).unwrap())
        .collect();
    let (client_config, server_config) = configs();
    let server_v4 = Endpoint::bind_server(
        rama_core::rt::Executor::new(),
        server_config.clone(),
        SocketAddress::local_ipv4(0),
    )
    .await
    .unwrap();
    let server_v6 = Endpoint::bind_server(
        rama_core::rt::Executor::new(),
        server_config,
        SocketAddress::local_ipv6(0),
    )
    .await
    .unwrap();
    for _ in 0..4 {
        let client = Endpoint::bind_client(
            rama_core::rt::Executor::new(),
            SocketAddress::default_ipv6(0),
        )
        .await
        .unwrap();
        let port = client.local_addr().unwrap().port();
        assert!(
            held.iter()
                .all(|socket| socket.local_addr().unwrap().port() != port)
        );
        tokio::time::timeout(Duration::from_secs(10), async {
            tokio::join!(
                exchange_both_ways(&client, &server_v4, client_config.clone()),
                exchange_both_ways(&client, &server_v6, client_config.clone()),
            );
        })
        .await
        .expect("the same client completes IPv4 and IPv6 handshakes and data transfer");
        client.shutdown().await;
    }
    tokio::join!(server_v4.shutdown(), server_v6.shutdown());
}

/// The capacity error behind `error`, wherever an I/O error carries it.
fn capacity_error(error: &(dyn std::error::Error + 'static)) -> Option<SocketCapacityError> {
    let mut next = Some(error);
    while let Some(error) = next {
        if let Some(io) = error.downcast_ref::<std::io::Error>()
            && let Some(capacity) = io
                .get_ref()
                .and_then(|inner| inner.downcast_ref::<SocketCapacityError>())
        {
            return Some(*capacity);
        }
        next = error.source();
    }
    None
}

/// A socket that cannot carry a QUIC packet, such as a UDP tunnel through too small a path.
#[tokio::test]
async fn a_socket_too_small_for_quic_is_refused_before_any_handshake() {
    let (socket, _peer) = MemoryDatagramSocket::pair(
        localhost_v4(),
        SocketAddr::new(Ipv4Addr::LOCALHOST.into(), 443),
        NonZeroUsize::new(8).unwrap(),
    );
    socket.set_max_payload(1199);
    let Err(DatagramError::Io(error)) =
        Endpoint::build(rama_core::rt::Executor::new()).with_datagram_socket(socket)
    else {
        panic!("a 1199-byte socket must be refused");
    };
    assert_eq!(
        capacity_error(&error),
        Some(SocketCapacityError { max_payload: 1199 })
    );
}

/// A path that shrinks but still carries QUIC's minimum recovers like any lost packet; one
/// that falls below it ends the connection with the capacity error at once.
#[tokio::test]
async fn a_shrinking_socket_recovers_above_quic_minimum_and_fails_typed_below() {
    let address = |port| SocketAddr::new(Ipv4Addr::LOCALHOST.into(), port);
    let (client_socket, server_socket) = MemoryDatagramSocket::pair(
        address(41000),
        address(41001),
        NonZeroUsize::new(64).unwrap(),
    );
    // Like a UDP tunnel: no segmented sends, and a payload limit that can change.
    client_socket.set_max_send_segments(NonZeroUsize::MIN);
    let path = client_socket.fault_control();
    let (mut client_config, server_config) = configs();
    let mut transport = crate::TransportConfig::default();
    transport.maybe_set_mtu_discovery_config(None);
    transport.set_initial_mtu(1300);
    client_config.set_transport_config(Arc::new(transport));
    let server = Endpoint::build(rama_core::rt::Executor::new())
        .with_server_config(server_config)
        .with_datagram_socket(server_socket)
        .unwrap();
    let client = Endpoint::build(rama_core::rt::Executor::new())
        .with_datagram_socket(client_socket)
        .unwrap();
    let connecting = client
        .connect_with(client_config, address(41001), "localhost")
        .unwrap();
    let incoming = tokio::time::timeout(Duration::from_secs(5), server.accept())
        .await
        .unwrap()
        .unwrap();
    let (c, s) = handshake(connecting, incoming).await;
    exchange(&c, &s, &[1; 20_000]).await;

    path.set_max_payload(1250);
    exchange(&c, &s, &[2; 20_000]).await;
    exchange(&s, &c, &[3; 20_000]).await;
    assert!(c.close_reason().is_none());

    path.set_max_payload(1150);
    let mut stream = c.open_uni().await.unwrap();
    _ = stream.write_all(&[4; 20_000]).await;
    let closed = tokio::time::timeout(Duration::from_secs(5), c.closed())
        .await
        .expect("a socket below the minimum ends the connection promptly");
    assert_eq!(
        capacity_error(&closed),
        Some(SocketCapacityError { max_payload: 1150 })
    );
}

/// A transport whose own minimum is above QUIC's still falls back to 1200 on a tunnel, and
/// still fails typed below it.
#[tokio::test]
async fn a_tunnel_shrink_recovers_even_with_a_higher_configured_minimum() {
    let address = |port| SocketAddr::new(Ipv4Addr::LOCALHOST.into(), port);
    let (client_socket, server_socket) = MemoryDatagramSocket::pair(
        address(41010),
        address(41011),
        NonZeroUsize::new(64).unwrap(),
    );
    client_socket.set_max_send_segments(NonZeroUsize::MIN);
    client_socket.set_max_payload(1400);
    let path = client_socket.fault_control();
    let (mut client_config, server_config) = configs();
    let mut transport = crate::TransportConfig::default();
    transport.maybe_set_mtu_discovery_config(None);
    transport.set_min_mtu(1300);
    transport.set_initial_mtu(1300);
    client_config.set_transport_config(Arc::new(transport));
    let server = Endpoint::build(rama_core::rt::Executor::new())
        .with_server_config(server_config)
        .with_datagram_socket(server_socket)
        .unwrap();
    let client = Endpoint::build(rama_core::rt::Executor::new())
        .with_datagram_socket(client_socket)
        .unwrap();
    let connecting = client
        .connect_with(client_config, address(41011), "localhost")
        .unwrap();
    let incoming = tokio::time::timeout(Duration::from_secs(5), server.accept())
        .await
        .unwrap()
        .unwrap();
    let (c, s) = handshake(connecting, incoming).await;
    exchange(&c, &s, &[1; 20_000]).await;
    path.set_max_payload(1250);
    exchange(&c, &s, &[2; 20_000]).await;
    exchange(&s, &c, &[3; 20_000]).await;
    assert!(c.close_reason().is_none());

    path.set_max_payload(1150);
    let mut stream = c.open_uni().await.unwrap();
    _ = stream.write_all(&[4; 20_000]).await;
    let closed = tokio::time::timeout(Duration::from_secs(5), c.closed())
        .await
        .expect("a socket below the minimum ends the connection promptly");
    assert_eq!(
        capacity_error(&closed),
        Some(SocketCapacityError { max_payload: 1150 })
    );
}
