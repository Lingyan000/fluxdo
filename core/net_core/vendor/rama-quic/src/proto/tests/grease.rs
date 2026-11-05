//! RFC 9287: greasing the QUIC bit. The transport parameter and the post-parameter greasing
//! come from the fork; these cover the client's early greasing on the strength of a token.

use std::time::SystemTime;

use parking_lot::Mutex;

use super::*;
use crate::proto::{StoredToken, TimeSource, UNIX_EPOCH, token::TokenStore};
use rama_quic_proto::{VarInt, Version, packet};

/// A clock a test moves by hand.
struct Clock(Mutex<SystemTime>);

impl Clock {
    fn new() -> Arc<Self> {
        Arc::new(Self(Mutex::new(
            UNIX_EPOCH + Duration::from_secs(1_700_000_000),
        )))
    }
    fn advance(&self, by: Duration) {
        *self.0.lock() += by;
    }
}

impl TimeSource for Clock {
    fn now(&self) -> SystemTime {
        *self.0.lock()
    }
}

/// Connect once so the server hands out a token, then start again with the same client.
fn reconnect(pair: &mut Pair, config: &ClientConfig) -> ConnectionHandle {
    let (client_ch, _) = pair.connect_with(config.clone());
    let now = pair.time;
    pair.client_conn_mut(client_ch)
        .close(now, VarInt::from_u32(0), [][..].into());
    pair.drive();
    pair.client.addr = SocketAddr::new(
        Ipv6Addr::LOCALHOST.into(),
        CLIENT_PORTS.lock().next().unwrap(),
    );
    pair.begin_connect(config.clone())
}

#[test]
fn a_recent_token_from_a_greasing_server_lets_a_client_grease_early() {
    let _guard = subscribe();
    let mut pair = Pair::default();
    let clock = Clock::new();
    let mut config = client_config();
    config.set_time_source(clock.clone());
    let (first, _) = pair.connect_with(config.clone());
    assert!(!pair.client_conn_mut(first).greases_quic_bit_early());
    let now = pair.time;
    pair.client_conn_mut(first)
        .close(now, VarInt::from_u32(0), [][..].into());
    pair.drive();

    // Six days later the token still qualifies.
    clock.advance(Duration::from_secs(6 * 86_400));
    pair.client.addr = SocketAddr::new(
        Ipv6Addr::LOCALHOST.into(),
        CLIENT_PORTS.lock().next().unwrap(),
    );
    let client_ch = pair.begin_connect(config.clone());
    assert!(pair.client_conn_mut(client_ch).greases_quic_bit_early());
    assert!(pair.client_conn_mut(client_ch).may_grease_quic_bit());
    // Once the server's parameters are in, its own parameter decides.
    pair.drive();
    pair.server.assert_accept();
    assert!(pair.client_conn_mut(client_ch).may_grease_quic_bit());
}

#[test]
fn a_token_older_than_seven_days_does_not() {
    let _guard = subscribe();
    let mut pair = Pair::default();
    let clock = Clock::new();
    let mut config = client_config();
    config.set_time_source(clock.clone());
    let (first, _) = pair.connect_with(config.clone());
    let now = pair.time;
    pair.client_conn_mut(first)
        .close(now, VarInt::from_u32(0), [][..].into());
    pair.drive();

    clock.advance(Duration::from_secs(7 * 86_400));
    pair.client.addr = SocketAddr::new(
        Ipv6Addr::LOCALHOST.into(),
        CLIENT_PORTS.lock().next().unwrap(),
    );
    let client_ch = pair.begin_connect(config);
    assert!(!pair.client_conn_mut(client_ch).greases_quic_bit_early());
}

#[test]
fn a_token_from_a_server_that_does_not_grease_does_not() {
    let _guard = subscribe();
    let mut server_endpoint = EndpointConfig::try_with_rand_key().unwrap();
    server_endpoint.set_grease_quic_bit(false);
    let server = Endpoint::new(
        Arc::new(server_endpoint),
        Some(Arc::new(server_config())),
        true,
        None,
    );
    let client = Endpoint::new(
        Arc::new(EndpointConfig::try_with_rand_key().unwrap()),
        None,
        true,
        None,
    );
    let mut pair = Pair::new_from_endpoint(client, server);
    let config = client_config();
    let client_ch = reconnect(&mut pair, &config);
    assert!(!pair.client_conn_mut(client_ch).greases_quic_bit_early());
    pair.drive();
    assert!(!pair.client_conn_mut(client_ch).may_grease_quic_bit());
}

#[test]
fn a_client_that_does_not_grease_never_clears_the_bit() {
    let _guard = subscribe();
    let mut client_endpoint = EndpointConfig::try_with_rand_key().unwrap();
    client_endpoint.set_grease_quic_bit(false);
    let client = Endpoint::new(Arc::new(client_endpoint), None, true, None);
    let server = Endpoint::new(
        Arc::new(EndpointConfig::try_with_rand_key().unwrap()),
        Some(Arc::new(server_config())),
        true,
        None,
    );
    let mut pair = Pair::new_from_endpoint(client, server);
    let config = client_config();
    let client_ch = reconnect(&mut pair, &config);
    // The token qualifies, but this endpoint does not grease at all.
    assert!(pair.client_conn_mut(client_ch).greases_quic_bit_early());
    assert!(!pair.client_conn_mut(client_ch).may_grease_quic_bit());
    pair.drive();
    assert!(!pair.client_conn_mut(client_ch).may_grease_quic_bit());
    for sent in &pair.client_sent {
        assert_ne!(
            sent.first_byte & packet::FIXED_BIT,
            0,
            "the fixed bit stays set"
        );
    }
}

/// The store keeps what early greasing needs: when the token came and whether the server
/// greased.
#[test]
fn a_stored_token_remembers_its_provenance() {
    let received = UNIX_EPOCH + Duration::from_secs(1_000);
    let plain = StoredToken::new(Bytes::from_static(b"t"), received);
    assert!(!plain.allows_early_quic_bit_grease(received));
    let greased = plain.with_peer_greasing_quic_bit(true);
    assert!(greased.allows_early_quic_bit_grease(received));
    assert!(greased.allows_early_quic_bit_grease(received + Duration::from_secs(604_799)));
    assert!(!greased.allows_early_quic_bit_grease(received + Duration::from_secs(604_800)));
    // A clock that went backwards proves nothing about recency.
    assert!(!greased.allows_early_quic_bit_grease(received - Duration::from_secs(1)));
    let store = crate::proto::TokenMemoryCache::default();
    store.insert("a", Version::V1, greased.clone());
    assert_eq!(store.take("a", Version::V1), Some(greased));
}

/// Parameters remembered for 0-RTT do not justify clearing the bit before the server answers
/// (RFC 9287 §3.1): only a qualifying token does.
#[test]
fn remembered_parameters_alone_do_not_allow_early_greasing() {
    let _guard = subscribe();
    let mut pair = Pair::default();
    pair.server.handle_incoming = Box::new(validate_incoming);
    let config = client_config();
    let client_ch = reconnect(&mut pair, &config);
    assert!(pair.client_conn_mut(client_ch).has_0rtt());
    // The default store kept the token, so early greasing is allowed through it...
    assert!(pair.client_conn_mut(client_ch).may_grease_quic_bit());

    // ...but with the token store emptied, the remembered parameters are not enough.
    let mut pair = Pair::default();
    pair.server.handle_incoming = Box::new(validate_incoming);
    let mut config = client_config();
    config.set_token_store(Arc::new(crate::proto::NoneTokenStore));
    let client_ch = reconnect(&mut pair, &config);
    assert!(pair.client_conn_mut(client_ch).has_0rtt());
    assert!(!pair.client_conn_mut(client_ch).may_grease_quic_bit());
    pair.drive();
    pair.server.assert_accept();
    assert!(pair.client_conn_mut(client_ch).may_grease_quic_bit());
}
