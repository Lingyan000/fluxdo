//! Endpoint management of [`SharedQuicEndpoint`] and [`QuicEndpointConnector`].

use std::{net::SocketAddr, num::NonZeroUsize, sync::Arc, time::Duration};

use parking_lot::Mutex;
use rama_core::{
    Service,
    extensions::ExtensionsRef,
    graceful::Shutdown,
    rt::{Executor, spawn},
};
use rama_net::{
    address::{HostWithPort, ProxyAddress, SocketAddress},
    client::{
        ConnectRequest, ConnectionError, ConnectorTarget, EstablishedClientConnection,
        EstablishedProxyRoute, ProxyRoute,
    },
};
use rama_quic_proto::{
    profile::{ConnectionIdProfile, ParameterOrder, QuicProfile, TransportLimits},
    transport_parameters::TransportParameterId,
};
use rama_tls::server::ServerAuthData;
use rama_udp::test_utils::MemoryDatagramSocket;
use tokio::{runtime::Runtime, sync::oneshot};

use super::connector::connector;
use crate::{
    Endpoint,
    client::{QuicEndpointConnector, SharedQuicEndpoint, endpoint::MAX_CACHED_PROFILE_ENDPOINTS},
    test_helpers::{identity, server},
};

/// The endpoint `shared` hands out for a request carrying `profile`.
async fn endpoint(
    shared: &SharedQuicEndpoint,
    profile: Option<&QuicProfile>,
) -> Result<Endpoint, ConnectionError> {
    let input = ConnectRequest::new(HostWithPort::local_ipv4(443));
    if let Some(profile) = profile {
        input.extensions().insert(profile.clone());
    }
    Ok(shared.serve(input).await?.conn.endpoint().clone())
}

fn zero_cid_profile() -> QuicProfile {
    QuicProfile::standard().with_connection_ids(
        ConnectionIdProfile::standard()
            .try_with_local_len(0)
            .unwrap(),
    )
}

#[test]
fn managed_endpoint_construction_needs_no_runtime() {
    let shared = SharedQuicEndpoint::managed(Executor::new());
    assert_eq!(shared.managed_state(), Some((false, 0)));
}

#[tokio::test]
async fn managed_endpoint_clones_share_concurrent_initialization() {
    let shared = SharedQuicEndpoint::managed(Executor::new());
    let clone = shared.clone();
    let (first, second) = tokio::join!(endpoint(&shared, None), endpoint(&clone, None));
    let first = first.unwrap();
    let second = second.unwrap();
    assert_eq!(first.local_addr().unwrap(), second.local_addr().unwrap());
    first.close(0u32, b"test complete");
    assert!(second.is_closed());
    first.shutdown().await;
}

#[test]
fn managed_endpoint_recovers_after_its_runtime_is_dropped() {
    let shared = SharedQuicEndpoint::managed(Executor::new());
    let runtime = Runtime::new().unwrap();
    let first = runtime.block_on(endpoint(&shared, None)).unwrap();
    assert!(!first.is_closed());
    drop(runtime);
    assert!(first.is_closed());

    let runtime = Runtime::new().unwrap();
    runtime.block_on(async {
        let recovered = endpoint(&shared, None).await.unwrap();
        assert!(!recovered.is_closed());
        assert!(first.is_closed());
        recovered.shutdown().await;
    });
}

#[tokio::test]
async fn cancelled_executor_does_not_initialize_an_endpoint() {
    let (cancel, cancelled) = oneshot::channel::<()>();
    let shutdown = Shutdown::new(async move {
        _ = cancelled.await;
    });
    let guard = shutdown.guard();
    let shared = SharedQuicEndpoint::managed(Executor::graceful(guard.clone()));
    cancel.send(()).unwrap();
    guard.cancelled().await;
    _ = endpoint(&shared, None).await.unwrap_err();
    _ = endpoint(&shared, Some(&QuicProfile::standard()))
        .await
        .unwrap_err();
    assert_eq!(shared.managed_state(), Some((false, 0)));
}

#[tokio::test]
async fn supplied_endpoint_is_not_replaced_after_shutdown() {
    let supplied = Endpoint::bind_client(Executor::new(), SocketAddress::local_ipv4(0))
        .await
        .unwrap();
    let shared = SharedQuicEndpoint::supplied(supplied.clone(), Executor::new());
    supplied.shutdown().await;
    assert!(endpoint(&shared, None).await.unwrap().is_closed());
    assert!(
        endpoint(&shared, Some(&QuicProfile::standard()))
            .await
            .unwrap()
            .is_closed()
    );
    assert_eq!(shared.managed_state(), None);
}

#[tokio::test]
async fn supplied_zero_cid_endpoint_serves_one_attempt_at_a_time() {
    let supplied = Endpoint::bind_client(Executor::new(), SocketAddress::local_ipv4(0))
        .await
        .unwrap();
    let shared = SharedQuicEndpoint::supplied(supplied.clone(), Executor::new());
    let request = |profile: QuicProfile| {
        let input = ConnectRequest::new(HostWithPort::local_ipv4(443));
        input.extensions().insert(profile);
        input
    };
    // Endpoints with connection IDs tell connections apart and are held concurrently.
    let first = shared
        .serve(request(QuicProfile::standard()))
        .await
        .unwrap();
    let second = shared
        .serve(request(QuicProfile::standard()))
        .await
        .unwrap();
    drop((first, second));

    let held = shared.serve(request(zero_cid_profile())).await.unwrap();
    let mut waiting = Box::pin(shared.serve(request(zero_cid_profile())));
    _ = tokio::time::timeout(Duration::from_millis(50), &mut waiting)
        .await
        .unwrap_err();
    drop(held);
    let next = tokio::time::timeout(Duration::from_secs(5), waiting)
        .await
        .unwrap()
        .unwrap();
    assert_eq!(
        next.conn.endpoint().local_addr().unwrap(),
        supplied.local_addr().unwrap()
    );
    supplied.shutdown().await;
}

#[tokio::test]
async fn profile_endpoints_cache_only_endpoint_wide_policy() {
    let shared = SharedQuicEndpoint::managed(Executor::new());
    let profile = QuicProfile::standard();
    let first = endpoint(&shared, Some(&profile)).await.unwrap();
    let reordered = profile.clone().with_transport_parameters(
        profile
            .transport_parameters()
            .clone()
            .try_with_order(ParameterOrder::fixed(vec![
                TransportParameterId::MaxIdleTimeout,
            ]))
            .unwrap(),
    );
    let same = endpoint(&shared, Some(&reordered)).await.unwrap();
    assert_eq!(first.local_addr().unwrap(), same.local_addr().unwrap());
    let changes = [
        profile.clone().with_grease_quic_bit(false),
        profile
            .clone()
            .with_connection_ids((*profile.connection_ids()).try_with_local_len(3).unwrap()),
        profile
            .clone()
            .try_with_limits(TransportLimits {
                max_udp_payload_size: 1400,
                ..profile.limits().clone()
            })
            .unwrap(),
    ];
    let mut addresses = vec![first.local_addr().unwrap()];
    let mut endpoints = vec![first];
    for changed in changes {
        let different = endpoint(&shared, Some(&changed)).await.unwrap();
        let address = different.local_addr().unwrap();
        assert!(!addresses.contains(&address));
        addresses.push(address);
        endpoints.push(different);
    }
    for endpoint in endpoints {
        endpoint.shutdown().await;
    }
}

#[tokio::test]
async fn profile_endpoints_zero_cids_never_share_a_bound_socket() {
    let shared = SharedQuicEndpoint::managed(Executor::new());
    let profile = zero_cid_profile();
    let (first, second) = tokio::join!(
        endpoint(&shared, Some(&profile)),
        endpoint(&shared, Some(&profile)),
    );
    let first = first.unwrap();
    let second = second.unwrap();
    assert_ne!(first.local_addr().unwrap(), second.local_addr().unwrap());
    assert_eq!(shared.managed_state(), Some((false, 0)));
    first.shutdown().await;
    second.shutdown().await;
}

#[tokio::test]
async fn profile_endpoints_cache_has_a_finite_bound() {
    let shared = SharedQuicEndpoint::managed(Executor::new());
    for len in 1..=(MAX_CACHED_PROFILE_ENDPOINTS + 1) {
        let profile = QuicProfile::standard().with_connection_ids(
            ConnectionIdProfile::standard()
                .try_with_local_len(u8::try_from(len).unwrap())
                .unwrap(),
        );
        let _endpoint = endpoint(&shared, Some(&profile)).await.unwrap();
    }
    assert_eq!(
        shared.managed_state(),
        Some((false, MAX_CACHED_PROFILE_ENDPOINTS))
    );
}

/// Hands out each prepared socket once, as a datagram connector establishing a tunnel would.
#[derive(Debug, Clone, Default)]
struct PreparedSockets(Arc<Mutex<Vec<MemoryDatagramSocket>>>);

impl Service<ConnectRequest> for PreparedSockets {
    type Output = EstablishedClientConnection<MemoryDatagramSocket, ConnectRequest>;
    type Error = ConnectionError;

    async fn serve(&self, input: ConnectRequest) -> Result<Self::Output, Self::Error> {
        let conn = self.0.lock().pop().unwrap();
        Ok(EstablishedClientConnection { input, conn })
    }
}

/// A server endpoint on one side of an in-memory pair; the other side is the client's socket.
fn memory_path(identity: &ServerAuthData) -> (MemoryDatagramSocket, SocketAddr, Endpoint) {
    let client = SocketAddr::from(([10, 0, 0, 1], 50_000));
    let peer = SocketAddr::from(([10, 0, 0, 2], 4433));
    let (socket, remote) = MemoryDatagramSocket::pair(client, peer, NonZeroUsize::new(64).unwrap());
    let server = Endpoint::build(Executor::new())
        .with_server_config(server(identity))
        .with_datagram_socket(remote)
        .unwrap();
    (socket, peer, server)
}

#[tokio::test]
async fn quic_endpoint_connector_adopts_the_socket_peer_and_extensions() {
    let (socket, peer, server) = memory_path(&identity());
    let proxy: ProxyAddress = "masque://proxy.example:443".parse().unwrap();
    socket
        .extensions()
        .insert(EstablishedProxyRoute::Tunnel(proxy.clone()));
    let sockets = PreparedSockets::default();
    sockets.0.lock().push(socket);
    let established = QuicEndpointConnector::new(sockets, Executor::new())
        .serve(ConnectRequest::new(HostWithPort::local_ipv4(443)))
        .await
        .unwrap();
    assert_eq!(established.conn.peer(), Some(peer));
    assert_eq!(
        established
            .conn
            .extensions()
            .get_ref::<EstablishedProxyRoute>()
            .and_then(EstablishedProxyRoute::proxy_address),
        Some(&proxy)
    );
    server.close(0u32, b"test complete");
}

#[tokio::test]
async fn quic_endpoint_connector_dials_the_socket_peer() {
    tokio::time::timeout(Duration::from_secs(10), async {
        let identity = identity();
        let (socket, peer, server) = memory_path(&identity);
        let sockets = PreparedSockets::default();
        sockets.0.lock().push(socket);
        let accept = server.clone();
        let serve = spawn(async move { accept.accept().await.unwrap().await.unwrap() });
        let quic = connector(
            QuicEndpointConnector::new(sockets, Executor::new()),
            &identity,
        );
        let input = ConnectRequest::new(HostWithPort::localhost_domain_with_port(443));
        // The race address is not the socket's peer: the connection follows the socket.
        input
            .extensions()
            .insert(ConnectorTarget(HostWithPort::local_ipv4(9)));
        let connection = quic.serve(input).await.unwrap().conn;
        assert_eq!(connection.remote_address(), peer);
        let accepted = serve.await.unwrap();
        connection.close(0u32, b"test complete");
        accepted.close(0u32, b"test complete");
        server.close(0u32, b"test complete");
    })
    .await
    .unwrap();
}

#[tokio::test]
async fn a_profile_dials_over_a_socket_smaller_than_its_receive_size() {
    tokio::time::timeout(Duration::from_secs(10), async {
        let identity = identity();
        let (socket, _peer, server) = memory_path(&identity);
        // A tunnel carrying 1400 bytes, below the profile's advertised receive size.
        socket.set_max_send_segments(NonZeroUsize::MIN);
        socket.set_max_payload(1400);
        let sockets = PreparedSockets::default();
        sockets.0.lock().push(socket);
        let accept = server.clone();
        let serve = spawn(async move { accept.accept().await.unwrap().await.unwrap() });
        let quic = connector(
            QuicEndpointConnector::new(sockets, Executor::new()),
            &identity,
        );
        let profile = QuicProfile::standard();
        let profile = profile
            .clone()
            .with_versions(profile.versions().clone().narrowed_public())
            .try_with_limits(TransportLimits {
                max_udp_payload_size: 65_527,
                ..profile.limits().clone()
            })
            .unwrap();
        let input = ConnectRequest::new(HostWithPort::localhost_domain_with_port(443));
        input.extensions().insert(profile);
        input
            .extensions()
            .insert(ConnectorTarget(HostWithPort::local_ipv4(9)));
        let connection = quic.serve(input).await.unwrap().conn;
        let accepted = serve.await.unwrap();
        connection.close(0u32, b"test complete");
        accepted.close(0u32, b"test complete");
        server.close(0u32, b"test complete");
    })
    .await
    .unwrap();
}

#[tokio::test]
async fn quic_endpoint_connector_serves_the_proxy_route_its_socket_establishes() {
    tokio::time::timeout(Duration::from_secs(10), async {
        let identity = identity();
        let (socket, peer, server) = memory_path(&identity);
        let proxy: ProxyAddress = "masque://proxy.example:443".parse().unwrap();
        socket
            .extensions()
            .insert(EstablishedProxyRoute::Tunnel(proxy.clone()));
        let sockets = PreparedSockets::default();
        sockets.0.lock().push(socket);
        let accept = server.clone();
        let serve = spawn(async move { accept.accept().await.unwrap().await.unwrap() });
        let quic = connector(
            QuicEndpointConnector::new(sockets, Executor::new()),
            &identity,
        );
        let input = ConnectRequest::new(HostWithPort::localhost_domain_with_port(443));
        input.extensions().insert(ProxyRoute::Proxy(proxy.clone()));
        let connection = quic.serve(input).await.unwrap().conn;
        assert_eq!(connection.remote_address(), peer);
        assert_eq!(
            connection
                .extensions()
                .get_ref::<EstablishedProxyRoute>()
                .and_then(EstablishedProxyRoute::proxy_address),
            Some(&proxy)
        );
        let accepted = serve.await.unwrap();
        connection.close(0u32, b"test complete");
        accepted.close(0u32, b"test complete");
        server.close(0u32, b"test complete");
    })
    .await
    .unwrap();
}
