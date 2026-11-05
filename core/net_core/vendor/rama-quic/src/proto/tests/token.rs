//! Tests specifically for tokens

use std::assert_matches;

use rama_quic_proto::{
    packet::{FixedLengthConnectionIdParser, PartialDecode},
    version::ClientVersionPolicy,
};

use parking_lot::Mutex;
use rama_quic_proto::{
    ConnectionId, Dir, TransportError, TransportErrorCode, VarInt,
    crypto::CryptoError,
    packet::{Header, SpaceId},
};
#[cfg(all(target_family = "wasm", target_os = "unknown"))]
use wasm_bindgen_test::wasm_bindgen_test as test;

use super::*;
use crate::proto::crypto::{AeadKey, HandshakeTokenKey};

#[test]
fn stateless_retry() {
    let _guard = subscribe();
    let mut pair = Pair::default();
    pair.server.handle_incoming = Box::new(validate_incoming);
    let (client_ch, _server_ch) = pair.connect();
    // The Retry reset the client's Initial packets and the handshake discarded two packet
    // number spaces: loss recovery's in-flight count still equals what is outstanding.
    assert_eq!(
        pair.client_conn_mut(client_ch).loss_recovery_in_flight(),
        (0, 0)
    );
    pair.client.connections.get_mut(&client_ch).unwrap().close(
        pair.time,
        VarInt::from_u32(42),
        Bytes::new(),
    );
    pair.drive();
    assert_eq!(pair.client.known_connections(), 0);
    assert_eq!(pair.client.known_cids(), 0);
    assert_eq!(pair.server.known_connections(), 0);
    assert_eq!(pair.server.known_cids(), 0);
}

#[test]
fn retry_token_expired() {
    let _guard = subscribe();

    let fake_time = Arc::new(FakeTimeSource::new());
    let retry_token_lifetime = Duration::from_secs(1);

    let mut pair = Pair::default();
    pair.server.handle_incoming = Box::new(validate_incoming);

    let mut config = server_config();
    config
        .set_time_source(Arc::clone(&fake_time) as _)
        .set_retry_token_lifetime(retry_token_lifetime);
    pair.server.set_server_config(Some(Arc::new(config)));

    let client_ch = pair.begin_connect(client_config());
    pair.drive_client();
    pair.drive_server();
    pair.drive_client();

    // to expire retry token
    fake_time.advance(retry_token_lifetime + Duration::from_millis(1));

    pair.drive();
    match pair.client_conn_mut(client_ch).poll() {
        Some(Event::ConnectionLost {
            reason: ConnectionError::ConnectionClosed(err),
        }) if err.error_code == TransportErrorCode::INVALID_TOKEN => {}
        other => panic!(
            "assertion failed: `{other:?}` does not match `Some(Event::ConnectionLost {{ reason: ConnectionError::ConnectionClosed(err) }}) if err.error_code == TransportErrorCode::INVALID_TOKEN`"
        ),
    }

    assert_eq!(pair.client.known_connections(), 0);
    assert_eq!(pair.client.known_cids(), 0);
    assert_eq!(pair.server.known_connections(), 0);
    assert_eq!(pair.server.known_cids(), 0);
}

#[test]
fn use_token() {
    let _guard = subscribe();
    let mut pair = Pair::default();
    let client_config = client_config();
    let (client_ch, _server_ch) = pair.connect_with(client_config.clone());
    pair.client.connections.get_mut(&client_ch).unwrap().close(
        pair.time,
        VarInt::from_u32(42),
        Bytes::new(),
    );
    pair.drive();
    assert_eq!(pair.client.known_connections(), 0);
    assert_eq!(pair.client.known_cids(), 0);
    assert_eq!(pair.server.known_connections(), 0);
    assert_eq!(pair.server.known_cids(), 0);

    pair.server.handle_incoming = Box::new(|incoming| {
        assert!(incoming.remote_address_validated());
        assert!(incoming.may_retry());
        IncomingConnectionBehavior::Accept
    });
    let (client_ch_2, _server_ch_2) = pair.connect_with(client_config);
    pair.client
        .connections
        .get_mut(&client_ch_2)
        .unwrap()
        .close(pair.time, VarInt::from_u32(42), Bytes::new());
    pair.drive();
    assert_eq!(pair.client.known_connections(), 0);
    assert_eq!(pair.client.known_cids(), 0);
    assert_eq!(pair.server.known_connections(), 0);
    assert_eq!(pair.server.known_cids(), 0);
}

#[test]
fn retry_then_use_token() {
    let _guard = subscribe();
    let mut pair = Pair::default();
    let client_config = client_config();
    pair.server.handle_incoming = Box::new(validate_incoming);
    let (client_ch, _server_ch) = pair.connect_with(client_config.clone());
    pair.client.connections.get_mut(&client_ch).unwrap().close(
        pair.time,
        VarInt::from_u32(42),
        Bytes::new(),
    );
    pair.drive();
    assert_eq!(pair.client.known_connections(), 0);
    assert_eq!(pair.client.known_cids(), 0);
    assert_eq!(pair.server.known_connections(), 0);
    assert_eq!(pair.server.known_cids(), 0);

    pair.server.handle_incoming = Box::new(|incoming| {
        assert!(incoming.remote_address_validated());
        assert!(incoming.may_retry());
        IncomingConnectionBehavior::Accept
    });
    let (client_ch_2, _server_ch_2) = pair.connect_with(client_config);
    pair.client
        .connections
        .get_mut(&client_ch_2)
        .unwrap()
        .close(pair.time, VarInt::from_u32(42), Bytes::new());
    pair.drive();
    assert_eq!(pair.client.known_connections(), 0);
    assert_eq!(pair.client.known_cids(), 0);
    assert_eq!(pair.server.known_connections(), 0);
    assert_eq!(pair.server.known_cids(), 0);
}

#[test]
fn use_token_then_retry() {
    let _guard = subscribe();
    let mut pair = Pair::default();
    let client_config = client_config();
    let (client_ch, _server_ch) = pair.connect_with(client_config.clone());
    pair.client.connections.get_mut(&client_ch).unwrap().close(
        pair.time,
        VarInt::from_u32(42),
        Bytes::new(),
    );
    pair.drive();
    assert_eq!(pair.client.known_connections(), 0);
    assert_eq!(pair.client.known_cids(), 0);
    assert_eq!(pair.server.known_connections(), 0);
    assert_eq!(pair.server.known_cids(), 0);

    pair.server.handle_incoming = Box::new({
        let mut i = 0;
        move |incoming| {
            if i == 0 {
                assert!(incoming.remote_address_validated());
                assert!(incoming.may_retry());
                i += 1;
                IncomingConnectionBehavior::Retry
            } else if i == 1 {
                assert!(incoming.remote_address_validated());
                assert!(!incoming.may_retry());
                i += 1;
                IncomingConnectionBehavior::Accept
            } else {
                panic!("too many handle_incoming iterations")
            }
        }
    });
    let (client_ch_2, _server_ch_2) = pair.connect_with(client_config);
    pair.client
        .connections
        .get_mut(&client_ch_2)
        .unwrap()
        .close(pair.time, VarInt::from_u32(42), Bytes::new());
    pair.drive();
    assert_eq!(pair.client.known_connections(), 0);
    assert_eq!(pair.client.known_cids(), 0);
    assert_eq!(pair.server.known_connections(), 0);
    assert_eq!(pair.server.known_cids(), 0);
}

#[test]
fn use_same_token_twice() {
    #[derive(Default)]
    struct EvilTokenStore(Mutex<Option<StoredToken>>);

    impl TokenStore for EvilTokenStore {
        fn insert(&self, _server_name: &str, _version: Version, token: StoredToken) {
            let mut lock = self.0.lock();
            if lock.is_none() {
                *lock = Some(token);
            }
        }

        fn take(&self, _server_name: &str, _version: Version) -> Option<StoredToken> {
            self.0.lock().clone()
        }
    }

    let _guard = subscribe();
    let mut pair = Pair::default();
    let mut client_config = client_config();
    client_config.set_token_store(Arc::new(EvilTokenStore::default()));
    let (client_ch, _server_ch) = pair.connect_with(client_config.clone());
    pair.client.connections.get_mut(&client_ch).unwrap().close(
        pair.time,
        VarInt::from_u32(42),
        Bytes::new(),
    );
    pair.drive();
    assert_eq!(pair.client.known_connections(), 0);
    assert_eq!(pair.client.known_cids(), 0);
    assert_eq!(pair.server.known_connections(), 0);
    assert_eq!(pair.server.known_cids(), 0);

    pair.server.handle_incoming = Box::new(|incoming| {
        assert!(incoming.remote_address_validated());
        assert!(incoming.may_retry());
        IncomingConnectionBehavior::Accept
    });
    let (client_ch_2, _server_ch_2) = pair.connect_with(client_config.clone());
    pair.client
        .connections
        .get_mut(&client_ch_2)
        .unwrap()
        .close(pair.time, VarInt::from_u32(42), Bytes::new());
    pair.drive();
    assert_eq!(pair.client.known_connections(), 0);
    assert_eq!(pair.client.known_cids(), 0);
    assert_eq!(pair.server.known_connections(), 0);
    assert_eq!(pair.server.known_cids(), 0);

    pair.server.handle_incoming = Box::new(|incoming| {
        assert!(!incoming.remote_address_validated());
        assert!(incoming.may_retry());
        IncomingConnectionBehavior::Accept
    });
    let (client_ch_3, _server_ch_3) = pair.connect_with(client_config);
    pair.client
        .connections
        .get_mut(&client_ch_3)
        .unwrap()
        .close(pair.time, VarInt::from_u32(42), Bytes::new());
    pair.drive();
    assert_eq!(pair.client.known_connections(), 0);
    assert_eq!(pair.client.known_cids(), 0);
    assert_eq!(pair.server.known_connections(), 0);
    assert_eq!(pair.server.known_cids(), 0);
}

#[test]
fn use_token_expired() {
    let _guard = subscribe();
    let fake_time = Arc::new(FakeTimeSource::new());
    let lifetime = Duration::from_secs(10000);
    let mut server_config = server_config();
    server_config
        .set_time_source(Arc::clone(&fake_time) as _)
        .validation_token
        .set_lifetime(lifetime);
    let mut pair = Pair::new(
        Arc::new(EndpointConfig::try_with_rand_key().unwrap()),
        server_config,
    );
    let client_config = client_config();
    let (client_ch, _server_ch) = pair.connect_with(client_config.clone());
    pair.client.connections.get_mut(&client_ch).unwrap().close(
        pair.time,
        VarInt::from_u32(42),
        Bytes::new(),
    );
    pair.drive();
    assert_eq!(pair.client.known_connections(), 0);
    assert_eq!(pair.client.known_cids(), 0);
    assert_eq!(pair.server.known_connections(), 0);
    assert_eq!(pair.server.known_cids(), 0);

    pair.server.handle_incoming = Box::new(|incoming| {
        assert!(incoming.remote_address_validated());
        assert!(incoming.may_retry());
        IncomingConnectionBehavior::Accept
    });
    let (client_ch_2, _server_ch_2) = pair.connect_with(client_config.clone());
    pair.client
        .connections
        .get_mut(&client_ch_2)
        .unwrap()
        .close(pair.time, VarInt::from_u32(42), Bytes::new());
    pair.drive();
    assert_eq!(pair.client.known_connections(), 0);
    assert_eq!(pair.client.known_cids(), 0);
    assert_eq!(pair.server.known_connections(), 0);
    assert_eq!(pair.server.known_cids(), 0);

    fake_time.advance(lifetime + Duration::from_secs(1));

    pair.server.handle_incoming = Box::new(|incoming| {
        assert!(!incoming.remote_address_validated());
        assert!(incoming.may_retry());
        IncomingConnectionBehavior::Accept
    });
    let (client_ch_3, _server_ch_3) = pair.connect_with(client_config);
    pair.client
        .connections
        .get_mut(&client_ch_3)
        .unwrap()
        .close(pair.time, VarInt::from_u32(42), Bytes::new());
    pair.drive();
    assert_eq!(pair.client.known_connections(), 0);
    assert_eq!(pair.client.known_cids(), 0);
    assert_eq!(pair.server.known_connections(), 0);
    assert_eq!(pair.server.known_cids(), 0);
}

pub(super) struct FakeTimeSource(Mutex<SystemTime>);

impl FakeTimeSource {
    pub(super) fn new() -> Self {
        Self(Mutex::new(SystemTime::now()))
    }

    /// A clock starting at a whole second: token issue times are encoded in whole seconds, so
    /// boundary tests need an issue time without a fractional part.
    pub(super) fn at_whole_second() -> Self {
        Self(Mutex::new(UNIX_EPOCH + Duration::from_secs(1_700_000_000)))
    }

    pub(super) fn advance(&self, dur: Duration) {
        *self.0.lock() += dur;
    }
}

impl TimeSource for FakeTimeSource {
    fn now(&self) -> SystemTime {
        *self.0.lock()
    }
}

/// Where a failing token-key provider gives up.
#[derive(Debug, Clone, Copy)]
enum ProviderFailure {
    /// `aead_from_hkdf` refuses to derive the per-token key.
    Derivation,
    /// Derivation succeeds; `seal` fails after having scribbled into its buffer.
    Sealing,
}

/// A token key whose provider fails at the configured stage.
struct FailingTokenKey(ProviderFailure);

impl HandshakeTokenKey for FailingTokenKey {
    fn aead_from_hkdf(&self, _random_bytes: &[u8]) -> Result<Box<dyn AeadKey>, CryptoError> {
        match self.0 {
            ProviderFailure::Derivation => Err(CryptoError::new()),
            ProviderFailure::Sealing => Ok(Box::new(SealFails)),
        }
    }
}

/// An AEAD whose seal fails after partially writing, so any escaped output is detectable.
struct SealFails;

impl AeadKey for SealFails {
    fn seal(&self, data: &mut Vec<u8>, _additional_data: &[u8]) -> Result<(), CryptoError> {
        data.extend_from_slice(b"PARTIAL-TAG-MUST-NOT-ESCAPE");
        Err(CryptoError::new())
    }

    fn open<'a>(
        &self,
        _data: &'a mut [u8],
        _additional_data: &[u8],
    ) -> Result<&'a mut [u8], CryptoError> {
        Err(CryptoError::new())
    }
}

#[test]
fn retry_with_a_failing_token_key_hands_the_attempt_back_intact() {
    for failure in [ProviderFailure::Derivation, ProviderFailure::Sealing] {
        retry_with_failing_key(failure);
    }
}

struct FailingRetryIntegrity(Arc<dyn crypto::ServerConfig>);
impl crypto::InitialServerConfig for FailingRetryIntegrity {
    fn initial_keys(
        &self,
        version: Version,
        cid: &ConnectionId,
    ) -> Result<crypto::Keys, crypto::InitialKeysError> {
        self.0.initial_keys(version, cid)
    }
    fn retry_tag(
        &self,
        _: Version,
        _: &ConnectionId,
        _: &[u8],
    ) -> Result<[u8; 16], rama_quic_proto::crypto::CryptoError> {
        Err(rama_quic_proto::crypto::CryptoError::new())
    }
}
impl crypto::ServerConfig for FailingRetryIntegrity {
    fn start_session(
        self: Arc<Self>,
        version: Version,
        params: &TransportParameters,
    ) -> Result<Box<dyn crypto::Session>, TransportError> {
        self.0.clone().start_session(version, params)
    }
    fn supports_compatible_negotiation(&self) -> bool {
        self.0.supports_compatible_negotiation()
    }
    fn start_negotiated_session(
        self: Arc<Self>,
        original: Version,
        negotiated: Version,
        params: &TransportParameters,
    ) -> Result<Box<dyn crypto::Session>, TransportError> {
        self.0
            .clone()
            .start_negotiated_session(original, negotiated, params)
    }
}

#[test]
fn failed_retry_integrity_preserves_the_attempt_and_callers_buffer() {
    let mut pair = Pair::default();
    let mut config = server_config();
    config.crypto =
        ServerCrypto::Fixed(Arc::new(FailingRetryIntegrity(config.crypto.into_fixed())));
    pair.server.set_server_config(Some(Arc::new(config)));
    pair.server.handle_incoming = Box::new(|_| IncomingConnectionBehavior::Wait);
    let client = pair.begin_connect(client_config());
    pair.drive_client();
    pair.drive_server();
    let incoming = pair.server.waiting_incoming.pop().unwrap();
    let mut buffer = b"caller-owned".to_vec();
    let error = pair
        .server
        .endpoint
        .retry(incoming, &mut buffer)
        .unwrap_err();
    assert_eq!(error.reason(), RetryRefused::IntegrityProtection);
    assert_eq!(buffer, b"caller-owned");
    let incoming = error.into_incoming();
    assert!(incoming.may_retry());
    let server = pair.server.try_accept(incoming, pair.time).unwrap();
    pair.drive();
    assert!(!pair.client_conn_mut(client).is_handshaking());
    assert!(!pair.server_conn_mut(server).is_closed());
    assert_eq!(pair.server.known_connections(), 1);
}

fn retry_with_failing_key(failure: ProviderFailure) {
    let _guard = subscribe();
    let mut pair = Pair::default();
    let mut config = server_config();
    config.token_key(Arc::new(FailingTokenKey(failure)));
    pair.server.set_server_config(Some(Arc::new(config)));
    pair.server.handle_incoming = Box::new(|_| IncomingConnectionBehavior::Wait);

    let client_ch = pair.begin_connect(client_config());
    pair.drive_client();
    pair.drive_server();
    let incoming = pair
        .server
        .waiting_incoming
        .pop()
        .expect("the Initial produced an attempt");
    assert!(incoming.may_retry());

    // The caller's buffer already holds unrelated bytes; a failed Retry must leave it as is.
    let mut buf = b"caller-owned".to_vec();
    let error = pair
        .server
        .endpoint
        .retry(incoming, &mut buf)
        .expect_err("a provider that cannot seal must not produce a Retry");
    assert_eq!(error.reason(), RetryRefused::TokenSealing, "{failure:?}");
    assert_eq!(
        buf, b"caller-owned",
        "{failure:?}: nothing was written for the failed Retry"
    );
    // The attempt is untouched: it can still be accepted and the handshake completes.
    let incoming = error.into_incoming();
    assert!(incoming.may_retry());
    let server_ch = pair.server.try_accept(incoming, pair.time).unwrap();
    pair.drive();
    assert!(!pair.client_conn_mut(client_ch).is_handshaking());
    assert!(!pair.server_conn_mut(server_ch).is_closed());
    assert_eq!(pair.server.known_connections(), 1);
}

#[test]
fn new_token_with_a_failing_token_key_is_skipped_without_harming_the_connection() {
    let _guard = subscribe();
    // Control: a working key sends the configured NEW_TOKEN frames.
    let mut control = Pair::default();
    let (_, control_server_ch) = control.connect();
    control.drive();
    assert!(
        control
            .server_conn_mut(control_server_ch)
            .stats()
            .frame_tx
            .new_token
            > 0
    );

    for failure in [ProviderFailure::Derivation, ProviderFailure::Sealing] {
        new_token_with_failing_key(failure);
    }
}

fn new_token_with_failing_key(failure: ProviderFailure) {
    let mut pair = Pair::default();
    let mut config = server_config();
    config.token_key(Arc::new(FailingTokenKey(failure)));
    pair.server.set_server_config(Some(Arc::new(config)));
    let (client_ch, server_ch) = pair.connect();
    pair.drive();
    let stats = pair.server_conn_mut(server_ch).stats();
    assert_eq!(
        stats.frame_tx.new_token, 0,
        "{failure:?}: no fabricated token goes out"
    );
    assert!(
        stats.frame_tx.new_token_failed >= 1,
        "{failure:?}: the skipped frames are observable"
    );
    assert_eq!(
        pair.client_conn_mut(client_ch).stats().frame_rx.new_token,
        0,
        "{failure:?}: the client received no token"
    );
    assert!(!pair.server_conn_mut(server_ch).is_closed());
    assert!(!pair.client_conn_mut(client_ch).is_closed());
    // The client can still open a stream: the connection is fully usable.
    let s = pair.client_streams(client_ch).open(Dir::Bi).unwrap();
    pair.client_send(client_ch, s).write(b"ping").unwrap();
    pair.drive();
    assert_matches!(
        pair.server_conn_mut(server_ch).poll(),
        Some(Event::Stream(StreamEvent::Opened { dir: Dir::Bi })),
    );
}

/// The null log refuses every validation token in the real admission path: a client that
/// presents a token it was given is treated as unvalidated.
#[test]
fn none_token_log_refuses_presented_validation_tokens() {
    let _guard = subscribe();
    let mut pair = Pair::default();
    let mut config = server_config();
    config
        .validation_token
        .set_log(Arc::new(crate::proto::NoneTokenLog))
        .set_sent(1);
    pair.server.set_server_config(Some(Arc::new(config)));
    let client_config = client_config();
    let (client_ch, server_ch) = pair.connect_with(client_config.clone());
    pair.drive();
    assert!(
        pair.server_conn_mut(server_ch).stats().frame_tx.new_token > 0,
        "a token was issued to the client"
    );
    pair.client.connections.get_mut(&client_ch).unwrap().close(
        pair.time,
        VarInt::from_u32(42),
        Bytes::new(),
    );
    pair.drive();

    let seen = Arc::new(Mutex::new(None));
    pair.server.handle_incoming = Box::new({
        let seen = seen.clone();
        move |incoming| {
            *seen.lock() = Some(incoming.remote_address_validated());
            IncomingConnectionBehavior::Accept
        }
    });
    let (_client_ch_2, _server_ch_2) = pair.connect_with(client_config);
    assert_eq!(
        *seen.lock(),
        Some(false),
        "the presented token was refused by the null log"
    );
}

/// The null store keeps nothing: the next connection has no token to present even though the
/// server issued one.
#[test]
fn none_token_store_presents_no_token() {
    let _guard = subscribe();
    let mut pair = Pair::default();
    let mut client_config = client_config();
    client_config.set_token_store(Arc::new(crate::proto::NoneTokenStore));
    let (client_ch, server_ch) = pair.connect_with(client_config.clone());
    pair.drive();
    assert!(pair.server_conn_mut(server_ch).stats().frame_tx.new_token > 0);
    pair.client.connections.get_mut(&client_ch).unwrap().close(
        pair.time,
        VarInt::from_u32(42),
        Bytes::new(),
    );
    pair.drive();

    let seen = Arc::new(Mutex::new(None));
    pair.server.handle_incoming = Box::new({
        let seen = seen.clone();
        move |incoming| {
            *seen.lock() = Some(incoming.remote_address_validated());
            IncomingConnectionBehavior::Accept
        }
    });
    let (_client_ch_2, _server_ch_2) = pair.connect_with(client_config);
    assert_eq!(*seen.lock(), Some(false));
}

/// A lifetime the wall clock cannot add to the issue time never validates a token: the checked
/// arithmetic rejects it (INVALID_TOKEN) instead of overflowing.
#[test]
fn retry_token_lifetime_beyond_the_clock_rejects_the_token() {
    let _guard = subscribe();
    let fake_time = Arc::new(FakeTimeSource::at_whole_second());
    let mut pair = Pair::default();
    pair.server.handle_incoming = Box::new(validate_incoming);
    let mut config = server_config();
    config
        .set_time_source(Arc::clone(&fake_time) as _)
        .set_retry_token_lifetime(Duration::MAX);
    pair.server.set_server_config(Some(Arc::new(config)));

    let client_ch = pair.begin_connect(client_config());
    pair.drive_client();
    pair.drive_server();
    pair.drive_client();
    pair.drive();
    assert_matches!(
        pair.client_conn_mut(client_ch).poll(),
        Some(Event::ConnectionLost {
            reason: ConnectionError::ConnectionClosed(err),
        }) if err.error_code == TransportErrorCode::INVALID_TOKEN,
    );
    assert_eq!(pair.server.known_connections(), 0);
}

/// Retry tokens are valid up to and including `issued + lifetime` and invalid one step later
/// (inclusive policy; RFC 9000 §8.1.3 leaves the lifetime to the server). Only the issue time is
/// encoded in whole seconds; the comparison itself has the time source's resolution.
#[test]
fn retry_token_lifetime_boundary_is_inclusive() {
    let _guard = subscribe();
    let lifetime = Duration::from_secs(1);
    // Immediately before, exactly at and immediately after the lifetime. Issue times are encoded
    // in whole seconds (hence the whole-second fake clock); the comparison itself is exact.
    for (elapsed, expect_connected) in [
        (lifetime.saturating_sub(Duration::from_millis(1)), true),
        (lifetime, true),
        (lifetime + Duration::from_millis(1), false),
    ] {
        let fake_time = Arc::new(FakeTimeSource::at_whole_second());
        let mut pair = Pair::default();
        pair.server.handle_incoming = Box::new(validate_incoming);
        let mut config = server_config();
        config
            .set_time_source(Arc::clone(&fake_time) as _)
            .set_retry_token_lifetime(lifetime);
        pair.server.set_server_config(Some(Arc::new(config)));

        let client_ch = pair.begin_connect(client_config());
        pair.drive_client();
        pair.drive_server(); // Retry issued at T0
        pair.drive_client(); // Initial with the retry token queued for the server
        fake_time.advance(elapsed);
        pair.drive();
        let lost = matches!(
            pair.client_conn_mut(client_ch).poll(),
            Some(Event::ConnectionLost {
                reason: ConnectionError::ConnectionClosed(err),
            }) if err.error_code == TransportErrorCode::INVALID_TOKEN
        );
        assert_eq!(
            !lost, expect_connected,
            "elapsed {elapsed:?}: expected connected={expect_connected}"
        );
        if expect_connected {
            assert!(!pair.client_conn_mut(client_ch).is_handshaking());
            assert_eq!(pair.server.known_connections(), 1);
        }
    }
}

/// Validation (NEW_TOKEN) tokens are accepted immediately before and exactly at
/// `issued + lifetime`, and treated as absent immediately after. Issue times are encoded in
/// whole seconds (hence the whole-second fake clock); the comparison itself is exact.
#[test]
fn validation_token_lifetime_boundary_is_inclusive() {
    let _guard = subscribe();
    let lifetime = Duration::from_secs(60);
    for (elapsed, expect_validated) in [
        (lifetime.saturating_sub(Duration::from_millis(1)), true),
        (lifetime, true),
        (lifetime + Duration::from_millis(1), false),
    ] {
        let fake_time = Arc::new(FakeTimeSource::at_whole_second());
        let mut pair = Pair::default();
        let mut config = server_config();
        config.set_time_source(Arc::clone(&fake_time) as _);
        config.validation_token.set_lifetime(lifetime).set_sent(1);
        pair.server.set_server_config(Some(Arc::new(config)));
        let client_config = client_config();
        let seen = Arc::new(Mutex::new(None));
        pair.server.handle_incoming = Box::new({
            let seen = seen.clone();
            move |incoming| {
                *seen.lock() = Some(incoming.remote_address_validated());
                IncomingConnectionBehavior::Accept
            }
        });
        // Token issued at T0 (a whole second).
        let (ch, server_ch) = pair.connect_with(client_config.clone());
        pair.drive();
        assert!(pair.server_conn_mut(server_ch).stats().frame_tx.new_token > 0);
        pair.client.connections.get_mut(&ch).unwrap().close(
            pair.time,
            VarInt::from_u32(42),
            Bytes::new(),
        );
        pair.drive();
        fake_time.advance(elapsed);
        let (_ch, _) = pair.connect_with(client_config);
        assert_eq!(
            *seen.lock(),
            Some(expect_validated),
            "elapsed {elapsed:?}: expected validated={expect_validated}"
        );
    }
}

/// A Retry token is sealed with the server's address token key. A server holding the same
/// material reads the token another sealed and the connection completes, carrying a payload; a
/// server holding other material cannot read it, counts it as no token and asks for validation
/// again. The two configurations are built separately from the same seed, which is the case a
/// service run as several servers depends on.
#[test]
fn a_retry_token_is_read_only_under_the_key_that_sealed_it() {
    const SEED: [u8; KEY_MATERIAL_SIZE] = [0x27; KEY_MATERIAL_SIZE];
    const OTHER_SEED: [u8; KEY_MATERIAL_SIZE] = [0x74; KEY_MATERIAL_SIZE];
    const MESSAGE: &[u8] = b"through the second server";

    // The same material, configured twice: the token crosses from one server to the other.
    let (mut pair, client_ch) = retry_across_keys(SEED, SEED);
    assert_eq!(
        pair.server.retries_sent, 1,
        "the token was read, so no second validation was asked for"
    );
    let server_ch = pair.server.assert_accept();

    // Established, not merely alive: a stream opened now arrives with its payload.
    let stream = pair
        .client_streams(client_ch)
        .open(Dir::Bi)
        .expect("a stream opens");
    pair.client_send(client_ch, stream)
        .write(MESSAGE)
        .expect("the write is queued");
    pair.drive();
    assert_eq!(
        pair.server_streams(server_ch).accept(Dir::Bi),
        Some(stream),
        "the server sees the stream"
    );
    let mut received = pair.server_recv(server_ch, stream);
    let mut chunks = received.read(true).expect("the stream is readable");
    let chunk = chunks
        .next(MESSAGE.len())
        .expect("a chunk arrives")
        .expect("with the payload");
    assert_eq!(&chunk.bytes[..], MESSAGE, "the payload arrives as sent");
    let _transmit = chunks.finalize();

    // Other material: the token is unreadable, so it counts as no token (RFC 9000 §8.1.3) and
    // the server asks for validation again. The client discards a Retry once it has accepted
    // one (§17.2.5.2), so within the exchange this drives no connection is established and the
    // client is still trying rather than refused.
    let (mut pair, client_ch) = retry_across_keys(SEED, OTHER_SEED);
    assert!(
        pair.server.retries_sent > 1,
        "the token was not read, so validation was asked for again: {} retries",
        pair.server.retries_sent
    );
    assert_eq!(
        pair.server.known_connections(),
        0,
        "and no connection is established under a key that cannot read the token"
    );
    assert!(
        !pair.client_conn_mut(client_ch).is_closed(),
        "the client was not refused; its attempt simply never validated"
    );
}

/// Issue a Retry under `issuing`, then hand the client's token-bearing Initial to a server
/// configured separately from `reading`, and drive that one packet exchange.
fn retry_across_keys(
    issuing: [u8; KEY_MATERIAL_SIZE],
    reading: [u8; KEY_MATERIAL_SIZE],
) -> (Pair, ConnectionHandle) {
    let _guard = subscribe();
    let mut pair = Pair::default();
    pair.server.handle_incoming = Box::new(validate_incoming);

    let mut issuing_config = server_config();
    issuing_config.set_address_token_key(AddressTokenKey::from_seed(&issuing));
    pair.server
        .set_server_config(Some(Arc::new(issuing_config)));

    let client_ch = pair.begin_connect(client_config());
    pair.drive_client();
    pair.drive_server();
    pair.drive_client();

    let mut reading_config = server_config();
    reading_config.set_address_token_key(AddressTokenKey::from_seed(&reading));
    pair.server
        .set_server_config(Some(Arc::new(reading_config)));
    pair.drive();
    (pair, client_ch)
}

/// A copy of an Initial that already produced an attempt, arriving after that attempt was
/// answered with a Retry or refused, is routed like any other first packet rather than to
/// endpoint state that is gone. Both orders are covered: the original before the token, and
/// the token-bearing Initial itself while its attempt is refused.
#[test]
fn a_duplicate_initial_after_retry_or_refusal_is_a_fresh_attempt() {
    let _guard = subscribe();
    let mut pair = Pair::default();
    pair.server.handle_incoming = Box::new(validate_incoming);
    let client_ch = pair.begin_connect(client_config());
    pair.drive_client();
    let first_initial = pair
        .server
        .inbound
        .front()
        .expect("the client's first Initial is on the wire")
        .clone();

    // The first Initial has no token: the server answers with a Retry.
    pair.drive_server();
    assert_eq!(pair.server.retries_sent, 1);

    // The same Initial again, as a duplicate or a replay would arrive.
    let now = pair.time;
    pair.server.inbound.push_back(Inbound {
        at: now,
        ..first_initial
    });
    pair.drive_server();
    assert_eq!(
        pair.server.retries_sent, 2,
        "the duplicate is a new attempt without a token, answered with another Retry"
    );
    assert_eq!(pair.server.known_connections(), 0);

    // The client acts on the first Retry only (RFC 9000 §17.2.5.2) and completes the handshake.
    pair.drive();
    let server_ch = pair.server.assert_accept();
    assert!(!pair.client_conn_mut(client_ch).is_handshaking());
    assert_eq!(pair.server.retries_sent, 2);
    assert!(!pair.server_conn_mut(server_ch).is_closed());
    let now = pair.time;
    pair.client_conn_mut(client_ch)
        .close(now, VarInt::from_u32(0), Bytes::new());
    pair.drive();

    // Now the token-bearing Initial: its attempt is held, its duplicate arrives, and the attempt
    // is refused. The duplicate presents the same token and becomes an attempt of its own.
    let mut pair = Pair::default();
    pair.server.handle_incoming = Box::new(|incoming| {
        if incoming.remote_address_validated() {
            IncomingConnectionBehavior::Wait
        } else {
            IncomingConnectionBehavior::Retry
        }
    });
    let client_ch = pair.begin_connect(client_config());
    pair.drive_client();
    pair.drive_server();
    assert_eq!(pair.server.retries_sent, 1);
    // The client takes in the Retry; pacing holds the Initial it calls for until its slot.
    pair.drive_client();
    for _ in 0..8 {
        if !pair.server.inbound.is_empty() {
            break;
        }
        let at = pair
            .client
            .next_wakeup()
            .expect("the client has a send pending");
        pair.time = pair.time.max(at);
        pair.drive_client();
    }
    let with_token = pair
        .server
        .inbound
        .front()
        .expect("the client's Initial with the Retry token is on the wire")
        .clone();
    pair.drive_server();
    assert_eq!(pair.server.waiting_incoming.len(), 1, "the attempt is held");

    let now = pair.time;
    pair.server.inbound.push_back(Inbound {
        at: now,
        ..with_token
    });
    let held = pair.server.waiting_incoming.remove(0);
    pair.server.reject(held);
    pair.drive_server();
    assert_eq!(
        pair.server.waiting_incoming.len(),
        1,
        "the duplicate is an attempt of its own once the first is gone"
    );
    let duplicate = pair.server.waiting_incoming.remove(0);
    assert!(duplicate.remote_address_validated());
    pair.server.reject(duplicate);
    pair.drive();

    assert_eq!(pair.server.known_connections(), 0);
    assert_eq!(pair.server.known_cids(), 0);
    let mut told = None;
    while let Some(event) = pair.client_conn_mut(client_ch).poll() {
        if let Event::ConnectionLost { reason } = event {
            told = Some(reason);
        }
    }
    match told {
        Some(ConnectionError::ConnectionClosed(close))
            if close.error_code == TransportErrorCode::CONNECTION_REFUSED => {}
        other => panic!("the client learns it was refused, not {other:?}"),
    }
}

#[test]
fn oversized_cached_initial_token() {
    let _guard = subscribe();
    for version in [Version::V1, Version::V2] {
        for (token_len, mtu, fits) in [
            (0, 1200, true),
            (1080, 1200, true),
            (1118, 1200, true),
            (1119, 1200, true),
            (1120, 1200, false),
            (1140, 1200, false),
            (1200, 1200, false),
            (1200, 1500, true),
        ] {
            let mut config = client_config();
            config
                .set_versions(ClientVersionPolicy::new(version).unwrap())
                .unwrap();
            Arc::get_mut(&mut config.transport)
                .unwrap()
                .set_initial_mtu(mtu);
            config.token_store.insert(
                "localhost",
                version,
                StoredToken::new(vec![0; token_len].into(), UNIX_EPOCH),
            );
            let mut endpoint = Endpoint::new(
                Arc::new(EndpointConfig::try_with_rand_key().unwrap()),
                None,
                true,
                None,
            );
            let now = Instant::now();
            let (_, mut conn) = endpoint
                .connect(now, config, "[::1]:4433".parse().unwrap(), "localhost")
                .unwrap();
            // A token from an earlier connection is optional (RFC 9000 §8.1.3): one that leaves
            // no room is left out, and the first flight goes without it.
            let mut buf = Vec::new();
            assert!(
                conn.poll_transmit(now, 1, &mut buf).is_some(),
                "token {token_len}, MTU {mtu}"
            );
            assert!(buf.len() <= mtu as usize);
            assert!(conn.stats().frame_tx.crypto > 0);
            assert!(conn.poll().is_none(), "token {token_len}, MTU {mtu}");
            let dcid_len = usize::from(buf[5]);
            let scid_len = usize::from(buf[6 + dcid_len]);
            let token_len_at = 7 + dcid_len + scid_len;
            let width = 1usize << (buf[token_len_at] >> 6);
            let mut sent_len = u64::from(buf[token_len_at] & 0x3f);
            for &byte in &buf[token_len_at + 1..token_len_at + width] {
                sent_len = (sent_len << 8) | u64::from(byte);
            }
            assert_eq!(
                sent_len,
                if fits { token_len as u64 } else { 0 },
                "token {token_len}, MTU {mtu}"
            );
        }
    }
}

/// A client connection that sent its first Initial and then received a Retry, with a valid tag,
/// carrying a `token_len`-byte token and a 20-byte source connection ID.
fn retried_client(version: Version, token_len: usize) -> (Connection, Instant) {
    let (conn, retried_at, _) = retried_client_after(version, token_len, Duration::ZERO);
    (conn, retried_at + Duration::from_secs(1))
}

/// As [`retried_client`], with the Retry arriving `delay` after the first Initial; also returns
/// when it arrived and the idle deadline just before it.
fn retried_client_after(
    version: Version,
    token_len: usize,
    delay: Duration,
) -> (Connection, Instant, Option<Instant>) {
    let address = "[::1]:4433".parse().unwrap();
    let mut endpoint = Endpoint::new(
        Arc::new(EndpointConfig::try_with_rand_key().unwrap()),
        None,
        true,
        None,
    );
    let now = Instant::now();
    let mut config = client_config();
    config
        .set_versions(ClientVersionPolicy::new(version).unwrap())
        .unwrap();
    let (_, mut conn) = endpoint.connect(now, config, address, "localhost").unwrap();
    let mut buf = Vec::new();
    let _transmit = conn.poll_transmit(now, 1, &mut buf).unwrap();
    let idle_before = conn.idle_timer();
    let now = now + delay;
    let (packet, _) = PartialDecode::new(
        buf.as_slice().into(),
        &FixedLengthConnectionIdParser::new(0),
        DEFAULT_SUPPORTED_VERSIONS,
        false,
    )
    .unwrap();
    let initial = packet.initial_header().unwrap();
    let header = Header::Retry {
        src_cid: ConnectionId::new(&[1; 20]),
        dst_cid: initial.src_cid,
        version: initial.version,
    };
    let mut retry = Vec::new();
    header.encode(&mut retry);
    retry.resize(retry.len() + token_len, 0);
    let tag = server_config()
        .crypto
        .initial()
        .retry_tag(initial.version.into(), &initial.dst_cid, &retry)
        .unwrap();
    retry.extend_from_slice(&tag);
    let Some(DatagramEvent::ConnectionEvent(_, event)) = endpoint.handle(
        now,
        address,
        None,
        None,
        BytesMut::from(&retry[..]),
        &mut buf,
    ) else {
        panic!("Retry must be routed to the client connection")
    };
    conn.handle_event(event);
    (conn, now, idle_before)
}

/// A Retry that validates is a packet processed successfully, so it restarts the idle timer
/// (RFC 9000 §10.1), as any other packet from the peer does.
#[test]
fn a_valid_retry_restarts_the_idle_timer() {
    let _guard = subscribe();
    for version in [Version::V1, Version::V2] {
        let delay = Duration::from_secs(3);
        let (conn, _, idle_before) = retried_client_after(version, 64, delay);
        let idle_before = idle_before.expect("an idle timer is armed after the first Initial");
        assert_eq!(conn.idle_timer(), Some(idle_before + delay), "{version:?}");
    }
}

/// A Retry token is required to go on, so one that leaves the Initial no room ends the attempt
/// cleanly instead of reaching an unbuildable packet.
fn assert_retry_ends_the_attempt(mut conn: Connection, now: Instant, case: &str) {
    let mut buf = Vec::new();
    assert!(conn.poll_transmit(now, 1, &mut buf).is_none(), "{case}");
    assert!(buf.is_empty(), "{case}");
    assert_matches!(
        conn.poll(),
        Some(Event::ConnectionLost { reason: ConnectionError::TransportError(err) })
        if err.code == TransportErrorCode::PROTOCOL_VIOLATION,
        "{case}"
    );
}

#[test]
fn oversized_retry_token() {
    let _guard = subscribe();
    for version in [Version::V1, Version::V2] {
        for (token_len, fits) in [
            (64, true),
            (1118, true),
            (1119, true),
            (1120, false),
            (1140, false),
            (1200, false),
        ] {
            let (mut conn, now) = retried_client(version, token_len);
            if fits {
                let crypto_before = conn.stats().frame_tx.crypto;
                let mut buf = Vec::new();
                assert!(conn.poll_transmit(now, 1, &mut buf).is_some());
                assert!(conn.stats().frame_tx.crypto > crypto_before);
                assert!(buf.len() <= 1200);
            } else {
                assert_retry_ends_the_attempt(conn, now, &format!("{version:?} {token_len}"));
            }
        }
    }
}

/// The shape GHSA-wppq-2f6r-wfvm reported: a Retry whose token and source connection ID total
/// at least 1162 bytes. The next transmission must neither assert nor size a packet from it.
#[test]
fn retry_token_and_scid_of_the_reported_size_end_the_attempt() {
    let _guard = subscribe();
    for version in [Version::V1, Version::V2] {
        for token_len in [1162 - 20, 1200, 4096] {
            let (conn, now) = retried_client(version, token_len);
            assert_retry_ends_the_attempt(conn, now, &format!("{version:?} {token_len}"));
        }
    }
}

#[test]
fn retry_source_must_change_the_initial_destination() {
    for version in [Version::V1, Version::V2] {
        for same_cid in [true, false] {
            let address = "[::1]:4433".parse().unwrap();
            let mut endpoint = Endpoint::new(
                Arc::new(EndpointConfig::try_with_rand_key().unwrap()),
                None,
                true,
                None,
            );
            let now = Instant::now();
            let mut config = client_config();
            config
                .set_versions(ClientVersionPolicy::new(version).unwrap())
                .unwrap();
            let (_, mut conn) = endpoint.connect(now, config, address, "localhost").unwrap();
            let mut buf = Vec::new();
            let _transmit = conn.poll_transmit(now, 1, &mut buf).unwrap();
            let (packet, _) = PartialDecode::new(
                buf.as_slice().into(),
                &FixedLengthConnectionIdParser::new(0),
                DEFAULT_SUPPORTED_VERSIONS,
                false,
            )
            .unwrap();
            let initial = packet.initial_header().unwrap();
            let mut changed = initial.dst_cid.to_vec();
            changed[0] ^= 1;
            let source = if same_cid {
                initial.dst_cid
            } else {
                ConnectionId::new(&changed)
            };
            let mut retry = Vec::new();
            Header::Retry {
                src_cid: source,
                dst_cid: initial.src_cid,
                version: initial.version,
            }
            .encode(&mut retry);
            retry.extend_from_slice(&[7; 8]);
            let tag = server_config()
                .crypto
                .initial()
                .retry_tag(initial.version.into(), &initial.dst_cid, &retry)
                .unwrap();
            retry.extend_from_slice(&tag);
            let Some(DatagramEvent::ConnectionEvent(_, event)) = endpoint.handle(
                now,
                address,
                None,
                None,
                BytesMut::from(&retry[..]),
                &mut buf,
            ) else {
                panic!("Retry must be routed to the client connection");
            };
            conn.handle_event(event);
            buf.clear();
            let transmitted = conn.poll_transmit(now + Duration::from_secs(1), 1, &mut buf);
            assert_eq!(
                transmitted.is_some(),
                !same_cid,
                "version {version:?}, same CID {same_cid}"
            );
            if !same_cid {
                let (packet, _) = PartialDecode::new(
                    buf.as_slice().into(),
                    &FixedLengthConnectionIdParser::new(0),
                    DEFAULT_SUPPORTED_VERSIONS,
                    false,
                )
                .unwrap();
                let retried = packet.initial_header().unwrap();
                assert_eq!(retried.dst_cid, source);
                assert_eq!(&buf[retried.token_pos.clone()], &[7; 8]);
            }
        }
    }
}

/// A Retry whose integrity tag does not verify is anyone's to send. It must not use up the one
/// Retry a client acts on, so the server's real Retry behind it still moves the handshake on.
#[test]
fn a_forged_retry_does_not_use_up_the_clients_retry() {
    let _guard = subscribe();
    let mut pair = Pair::default();
    pair.server.handle_incoming = Box::new(validate_incoming);
    let client_ch = pair.begin_connect(client_config());
    pair.drive_client();
    pair.drive_server();
    let mut forged = pair
        .client
        .inbound
        .front()
        .expect("the server answers with a Retry")
        .clone();
    assert_eq!(forged.packet[0] & 0xf0, 0xf0, "a v1 Retry");
    let last = forged.packet.len() - 1;
    forged.packet[last] ^= 0xff;
    pair.client.inbound.push_front(forged);
    pair.drive_bounded();
    assert_eq!(pair.server.retries_sent, 1);
    assert!(
        pair.client_conn_mut(client_ch).handshake_confirmed(),
        "the real Retry was acted on"
    );
}

/// Servers never receive a Retry, and one can be spoofed by anyone who knows the connection's
/// identifier, so a server drops it instead of closing a handshake in progress.
#[test]
fn a_retry_sent_to_a_server_does_not_end_its_handshake() {
    let _guard = subscribe();
    let mut pair = Pair::default();
    let client_ch = pair.begin_connect(client_config());
    pair.drive_client();
    pair.drive_server();
    let first = &pair
        .client
        .inbound
        .front()
        .expect("the server answers")
        .packet;
    let dcid_len = usize::from(first[5]);
    let scid_len = usize::from(first[6 + dcid_len]);
    let server_cid = first[7 + dcid_len..7 + dcid_len + scid_len].to_vec();
    let mut retry = vec![0xf0, 0, 0, 0, 1, server_cid.len() as u8];
    retry.extend_from_slice(&server_cid);
    retry.push(8);
    retry.extend_from_slice(&[7; 8]);
    retry.extend_from_slice(&[1; 32]);
    pair.server.inbound.push_front(Inbound {
        at: pair.time,
        ecn: None,
        packet: retry.as_slice().into(),
        from: None,
        to: None,
    });
    pair.drive_bounded();
    let server_ch = pair.server.assert_accept();
    assert!(!pair.server_conn_mut(server_ch).is_closed());
    assert!(pair.client_conn_mut(client_ch).handshake_confirmed());
}

/// Hands out a single token of a chosen length, as an earlier server's NEW_TOKEN could have
/// left behind.
struct OneToken(Mutex<Option<StoredToken>>);

impl OneToken {
    fn of_len(len: usize) -> Self {
        let token = StoredToken::new(Bytes::from(vec![0xab; len]), SystemTime::now());
        Self(Mutex::new(Some(token)))
    }
}

impl TokenStore for OneToken {
    fn insert(&self, _: &str, _: Version, _: StoredToken) {}

    fn take(&self, _: &str, _: Version) -> Option<StoredToken> {
        self.0.lock().take()
    }
}

/// A client that has just put its first Initial on the wire, and what that Initial named.
struct FreshClient {
    endpoint: Endpoint,
    conn: Connection,
    server: SocketAddr,
    version: Version,
    initial_dst_cid: ConnectionId,
    client_cid: ConnectionId,
}

impl FreshClient {
    fn new(config: ClientConfig, now: Instant) -> Self {
        let server = SocketAddr::new(Ipv6Addr::LOCALHOST.into(), 4433);
        let mut endpoint = Endpoint::new(
            Arc::new(EndpointConfig::try_with_rand_key().unwrap()),
            None,
            true,
            None,
        );
        let (_, mut conn) = endpoint.connect(now, config, server, "localhost").unwrap();
        let mut buf = Vec::new();
        let transmit = conn
            .poll_transmit(now, 1, &mut buf)
            .expect("the client sends its first Initial");
        let initial = &buf[..transmit.size];
        // Long header: flags(1) version(4) dcid_len(1) dcid scid_len(1) scid ...
        let version = Version::from_be_bytes(initial[1..5].try_into().unwrap());
        let dcid_len = initial[5] as usize;
        let initial_dst_cid = ConnectionId::new(&initial[6..6 + dcid_len]);
        let scid_len = initial[6 + dcid_len] as usize;
        let client_cid = ConnectionId::new(&initial[7 + dcid_len..7 + dcid_len + scid_len]);
        Self {
            endpoint,
            conn,
            server,
            version,
            initial_dst_cid,
            client_cid,
        }
    }

    /// Hand the client a Retry from `src_cid` carrying a `token_len`-byte token, with a valid
    /// integrity tag: anyone who saw the first Initial can build one.
    fn retry(&mut self, now: Instant, src_cid: ConnectionId, token_len: usize) {
        let mut retry = Vec::new();
        Header::Retry {
            dst_cid: self.client_cid,
            src_cid,
            version: self.version.to_wire().unwrap(),
        }
        .encode(&mut retry);
        retry.resize(retry.len() + token_len, 0xab);
        let tag = server_config()
            .crypto
            .initial()
            .retry_tag(self.version, &self.initial_dst_cid, &retry)
            .unwrap();
        retry.extend_from_slice(&tag);
        let mut buf = Vec::new();
        let Some(DatagramEvent::ConnectionEvent(_, event)) = self.endpoint.handle(
            now,
            self.server,
            None,
            None,
            BytesMut::from(&retry[..]),
            &mut buf,
        ) else {
            panic!("a Retry is routed to the client connection");
        };
        self.conn.handle_event(event);
    }
}

/// RFC 9000 §17.2.5.2: a client discards a Retry whose Source Connection ID is the Destination
/// Connection ID of its first Initial, and follows one from any other identifier.
#[test]
fn retry_naming_the_initial_destination_is_discarded() {
    let _guard = subscribe();
    for echoed in [true, false] {
        let now = Instant::now();
        let mut client = FreshClient::new(client_config(), now);
        let src_cid = match echoed {
            true => client.initial_dst_cid,
            false => ConnectionId::new(&[1; 20]),
        };
        client.retry(now, src_cid, 64);
        let mut buf = Vec::new();
        let sent = client
            .conn
            .poll_transmit(now + Duration::from_secs(1), 1, &mut buf);
        if echoed {
            assert!(
                sent.is_none(),
                "the Retry was dropped, so nothing new is due"
            );
            assert!(!client.conn.is_closed());
        } else {
            assert!(sent.is_some(), "a Retry restarts the handshake at once");
            let dcid_len = buf[5] as usize;
            assert_eq!(
                &buf[6..6 + dcid_len],
                &src_cid[..],
                "towards the Retry's source"
            );
        }
    }
}

/// Closing while ACKs are owed in an Initial packet whose token leaves little room: the ACK
/// yields, so the close still goes out within the datagram limit.
#[test]
fn large_initial_token_leaves_room_for_close() {
    let _guard = subscribe();
    for token_len in (960..=1_216).step_by(4) {
        let case = format!("token {token_len}");
        let mut config = client_config();
        config.set_token_store(Arc::new(OneToken::of_len(token_len)));
        let mut endpoint = Endpoint::new(
            Arc::new(EndpointConfig::try_with_rand_key().unwrap()),
            None,
            true,
            None,
        );
        let now = Instant::now();
        let (_, mut conn) = endpoint
            .connect(
                now,
                config,
                SocketAddr::new(Ipv6Addr::LOCALHOST.into(), 4433),
                "localhost",
            )
            .unwrap();
        // Every other packet number, so the ACK frame carries many ranges.
        conn.owe_acks(now, SpaceId::Initial, (0..32).step_by(2));
        conn.close(now, VarInt::from_u32(0), Bytes::new());
        let mut buf = Vec::new();
        // A cached token is optional, so one leaving no room is dropped rather than the close.
        let transmit = conn
            .poll_transmit(now, 1, &mut buf)
            .unwrap_or_else(|| panic!("{case}: the close is sent"));
        assert!(
            transmit.size <= usize::from(INITIAL_MTU),
            "{case}: {} bytes",
            transmit.size
        );
        assert_eq!(conn.stats().frame_tx.connection_close, 1, "{case}");
    }
}

#[test]
fn invalid_retry_or_version_negotiation_cannot_prevent_a_valid_retry() {
    for version_negotiation in [false, true] {
        let mut pair = Pair::default();
        pair.server.handle_incoming = Box::new(validate_incoming);
        let client = pair.begin_connect(client_config());
        pair.drive_client();
        pair.drive_server();
        let retry = pair.client.inbound.pop_front().expect("server sends Retry");
        let mut corrupt = retry.clone();
        if version_negotiation {
            let mut packet = Vec::new();
            Header::VersionNegotiate {
                random: 0,
                src_cid: ConnectionId::new(&[0x44; 8]),
                dst_cid: pair.client.cids_routing_to(client)[0],
            }
            .encode(&mut packet);
            packet.extend_from_slice(&pair.client_conn_mut(client).version().to_be_bytes());
            corrupt.packet = packet.as_slice().into();
        } else {
            *corrupt.packet.last_mut().unwrap() ^= 1;
        }
        pair.client.inbound.push_back(corrupt);
        pair.drive_client();
        assert!(pair.client_conn_mut(client).is_handshaking());
        assert_eq!(pair.client_conn_mut(client).authenticated_packets(), 0);
        pair.client.inbound.push_back(retry.clone());
        pair.drive_client();
        assert_eq!(pair.client_conn_mut(client).authenticated_packets(), 1);
        // The first authenticated Retry changes Initial keys; replaying it must have no effect.
        for _ in 0..3 {
            pair.client.inbound.push_back(retry.clone());
        }
        pair.drive();
        let server = pair.server.assert_accept();
        assert!(!pair.client_conn_mut(client).is_handshaking());
        assert!(!pair.server_conn_mut(server).is_handshaking());
        assert_eq!(pair.server.retries_sent, 1);
    }
}
