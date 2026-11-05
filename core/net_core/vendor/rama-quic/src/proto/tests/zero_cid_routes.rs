use std::{net::SocketAddr, sync::Arc};

use rama_quic_proto::{
    Version,
    profile::{ConnectionIdProfile, QuicProfile},
    version::ClientVersionPolicy,
};

use super::{
    ClientConfig, ConnectError, ConnectionError, Endpoint, EndpointConfig, Pair,
    cid_generator::RandomConnectionIdGenerator,
    shared::EndpointEvent,
    util::{IncomingConnectionBehavior, client_config, server_config},
};

fn zero_cid_endpoint() -> EndpointConfig {
    EndpointConfig::try_with_rand_key()
        .unwrap()
        .with_connection_id_generator_factory(Arc::new(|| {
            Box::new(RandomConnectionIdGenerator::new(0).unwrap())
        }))
}

#[test]
fn zero_cid_routes_reject_a_second_client_to_the_same_remote() {
    let mut pair = Pair::new(Arc::new(zero_cid_endpoint()), server_config());
    let (_client, _server) = pair.connect();
    let result =
        pair.client
            .endpoint
            .connect(pair.time, client_config(), pair.server.addr, "localhost");
    let Err(error) = result else {
        panic!("a second connection replaced a live zero-CID route");
    };
    assert_eq!(error, ConnectError::EndpointInUse);
    assert_eq!(pair.client.endpoint.open_connections(), 1);

    // Distinct remote addresses still provide an unambiguous route.
    let other = SocketAddr::new(pair.server.addr.ip(), pair.server.addr.port() + 1);
    pair.client
        .endpoint
        .connect(pair.time, client_config(), other, "localhost")
        .unwrap();
    assert_eq!(pair.client.endpoint.open_connections(), 2);
}

#[test]
fn zero_cid_routes_reject_client_server_overlap() {
    let mut pair = Pair::new(Arc::new(zero_cid_endpoint()), server_config());
    let (_client, _server) = pair.connect();
    let result =
        pair.server
            .endpoint
            .connect(pair.time, client_config(), pair.client.addr, "localhost");
    let Err(error) = result else {
        panic!("a client connection overlapped a server zero-CID route");
    };
    assert_eq!(error, ConnectError::EndpointInUse);
    assert_eq!(pair.server.endpoint.open_connections(), 1);
}

/// Zero-length IDs leave a server only the four-tuple (RFC 9000 §5.1): the first attempt
/// accepted from it keeps it, and a later one is refused, even one that started first.
#[test]
fn zero_cid_routes_keep_a_four_tuple_for_its_first_accept() {
    let client = Endpoint::new(
        Arc::new(EndpointConfig::try_with_rand_key().unwrap()),
        None,
        false,
        Some([1; 32]),
    );
    let server = Endpoint::new(
        Arc::new(zero_cid_endpoint()),
        Some(Arc::new(server_config())),
        false,
        Some([2; 32]),
    );
    let mut pair = Pair::new_from_endpoint(client, server);
    pair.server.handle_incoming = Box::new(|_| IncomingConnectionBehavior::Wait);
    let first_client = pair.begin_connect(client_config());
    pair.begin_connect(client_config());
    pair.drive_client();
    pair.drive_server();
    assert_eq!(pair.server.waiting_incoming.len(), 2);
    let second = pair.server.waiting_incoming.pop().unwrap();
    let first = pair.server.waiting_incoming.pop().unwrap();
    let mut buf = Vec::new();
    let first = pair
        .server
        .start_accept(first, pair.time, &mut buf, None)
        .unwrap();
    let second = pair
        .server
        .start_accept(second, pair.time, &mut buf, None)
        .unwrap();
    let established = pair.server.finish(first.accept()).unwrap();
    assert!(matches!(
        pair.server.finish(second.accept()),
        Err(ConnectionError::TransportError(_))
    ));
    assert_eq!(pair.server.endpoint.open_connections(), 1);
    // The first attempt completes its handshake over the addresses it kept.
    pair.drive();
    assert!(!pair.client_conn_mut(first_client).is_handshaking());
    assert!(!pair.server_conn_mut(established).is_handshaking());
}

#[test]
fn zero_cid_routes_reject_server_client_overlap() {
    let client = Endpoint::new(
        Arc::new(EndpointConfig::try_with_rand_key().unwrap()),
        None,
        false,
        Some([1; 32]),
    );
    let server = Endpoint::new(
        Arc::new(zero_cid_endpoint()),
        Some(Arc::new(server_config())),
        false,
        Some([2; 32]),
    );
    let mut pair = Pair::new_from_endpoint(client, server);
    let _outgoing = pair
        .server
        .endpoint
        .connect(pair.time, client_config(), pair.client.addr, "localhost")
        .unwrap();
    pair.server.handle_incoming = Box::new(|_| IncomingConnectionBehavior::Wait);
    pair.begin_connect(client_config());
    pair.drive_client();
    pair.drive_server();
    let incoming = pair.server.waiting_incoming.pop().unwrap();
    let error = pair.server.try_accept(incoming, pair.time).unwrap_err();
    assert!(matches!(error, ConnectionError::EndpointInUse));
    assert_eq!(pair.server.endpoint.open_connections(), 1);
}

fn dedicated_profile() -> QuicProfile {
    QuicProfile::standard()
        .with_versions(ClientVersionPolicy::new(Version::V1).unwrap())
        .with_connection_ids(
            ConnectionIdProfile::standard()
                .try_with_local_len(0)
                .unwrap(),
        )
}

fn dedicated_client() -> ClientConfig {
    let mut config = client_config();
    config.apply_quic_profile(&dedicated_profile()).unwrap();
    config
}

fn dedicated_pair() -> Pair {
    let mut endpoint = zero_cid_endpoint();
    endpoint.apply_quic_profile(&dedicated_profile()).unwrap();
    Pair::new(Arc::new(endpoint), server_config())
}

#[test]
fn zero_cid_profile_reserves_endpoint_until_drained() {
    let mut pair = dedicated_pair();
    let address = pair.server.addr;
    let other = SocketAddr::new(address.ip(), address.port() + 1);
    let (handle, _connection) = pair
        .client
        .endpoint
        .connect(pair.time, dedicated_client(), address, "localhost")
        .unwrap();

    for config in [client_config(), dedicated_client()] {
        assert!(matches!(
            pair.client
                .endpoint
                .connect(pair.time, config, other, "localhost"),
            Err(ConnectError::EndpointInUse)
        ));
    }
    assert_eq!(pair.client.endpoint.open_connections(), 1);

    pair.client
        .endpoint
        .handle_event(handle, EndpointEvent::drained());
    pair.client
        .endpoint
        .connect(pair.time, dedicated_client(), other, "localhost")
        .unwrap();
    assert_eq!(pair.client.endpoint.open_connections(), 1);
}

#[test]
fn zero_cid_profile_cannot_take_an_occupied_endpoint() {
    let mut pair = dedicated_pair();
    let address = pair.server.addr;
    let other = SocketAddr::new(address.ip(), address.port() + 1);
    pair.client
        .endpoint
        .connect(pair.time, client_config(), address, "localhost")
        .unwrap();
    assert!(matches!(
        pair.client
            .endpoint
            .connect(pair.time, dedicated_client(), other, "localhost"),
        Err(ConnectError::EndpointInUse)
    ));
    assert_eq!(pair.client.endpoint.open_connections(), 1);
}

#[test]
fn zero_cid_profile_failed_setup_does_not_reserve_endpoint() {
    let mut pair = dedicated_pair();
    let address = pair.server.addr;
    let Err(_error) = pair.client.endpoint.connect(
        pair.time,
        dedicated_client(),
        address,
        "invalid server name!",
    ) else {
        panic!("invalid TLS server name was accepted");
    };
    assert_eq!(pair.client.endpoint.open_connections(), 0);
    pair.client
        .endpoint
        .connect(pair.time, dedicated_client(), address, "localhost")
        .unwrap();
    assert_eq!(pair.client.endpoint.open_connections(), 1);
}

#[test]
fn zero_cid_profile_prevents_accept_on_another_route() {
    let mut pair = dedicated_pair();
    let other = SocketAddr::new(pair.client.addr.ip(), pair.client.addr.port() + 1);
    let (handle, _connection) = pair
        .server
        .endpoint
        .connect(pair.time, dedicated_client(), other, "localhost")
        .unwrap();
    pair.server.handle_incoming = Box::new(|_| IncomingConnectionBehavior::Wait);
    pair.begin_connect(client_config());
    pair.drive_client();
    let datagram = pair.server.inbound.front().unwrap().clone();
    pair.drive_server();
    let incoming = pair.server.waiting_incoming.pop().unwrap();
    assert!(matches!(
        pair.server.try_accept(incoming, pair.time),
        Err(ConnectionError::EndpointInUse)
    ));
    assert_eq!(pair.server.endpoint.open_connections(), 1);

    // Refusal must release the pending Initial route as well as its byte budget.
    pair.server
        .endpoint
        .handle_event(handle, EndpointEvent::drained());
    pair.server.inbound.push_back(datagram);
    pair.drive_server();
    let incoming = pair.server.waiting_incoming.pop().unwrap();
    pair.server.try_accept(incoming, pair.time).unwrap();
    assert_eq!(pair.server.endpoint.open_connections(), 1);
}

#[test]
fn cid_retirement_keeps_established_zero_cid_routes_until_drained() {
    let mut pair = dedicated_pair();
    let (client, server) = pair.connect_with(dedicated_client());
    let now = pair.time;
    pair.server_conn_mut(server)
        .close(now, 0_u32.into(), Default::default());
    pair.drive_server();
    pair.drive_client();

    assert_eq!(pair.time, now, "no drain timeout has elapsed");
    assert!(pair.client_conn_mut(client).is_closed());
    assert!(!pair.client_conn_mut(client).is_drained());
    assert_eq!(pair.client.endpoint.open_connections(), 1);
    let address = pair.server.addr;
    assert_eq!(
        pair.client
            .endpoint
            .connect(now, dedicated_client(), address, "localhost")
            .err(),
        Some(ConnectError::EndpointInUse)
    );
}

#[test]
fn cid_retirement_keeps_nonzero_cid_handshake_draining() {
    let mut pair = Pair::default();
    pair.server.handle_incoming = Box::new(|_| IncomingConnectionBehavior::Reject);
    let client = pair.begin_connect(client_config());
    let now = pair.time;
    pair.drive_client();
    pair.drive_server();
    pair.drive_client();

    assert_eq!(pair.time, now, "no drain timeout has elapsed");
    assert!(pair.client_conn_mut(client).is_closed());
    assert!(!pair.client_conn_mut(client).is_drained());
    assert_eq!(pair.client.endpoint.open_connections(), 1);
}

/// Running out of IDs is exhaustion, not an endpoint in use: a longer ID space is the remedy.
#[test]
fn a_full_cid_space_is_reported_exhausted_not_in_use() {
    let endpoint = EndpointConfig::try_with_rand_key()
        .unwrap()
        .with_connection_id_generator_factory(Arc::new(|| {
            Box::new(RandomConnectionIdGenerator::new(1).unwrap())
        }));
    let mut pair = Pair::new(Arc::new(endpoint), server_config());
    let address = pair.server.addr;
    let error = (1..=256)
        .find_map(|port| {
            let remote = SocketAddr::new(address.ip(), port);
            pair.client
                .endpoint
                .connect(pair.time, client_config(), remote, "localhost")
                .err()
        })
        .expect("a 1-byte ID space runs out");
    assert_eq!(error, ConnectError::CidsExhausted);
}
