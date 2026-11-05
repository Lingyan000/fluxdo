use std::{assert_matches, task::Context};

use rama_quic_proto::{ConnectionId, Side, TransportError, TransportErrorCode, packet::SpaceId};

use super::*;

struct FailingClient(bool);
impl crypto::ClientConfig for FailingClient {
    fn start_session(
        self: Arc<Self>,
        _: Version,
        _: &str,
        _: &TransportParameters,
    ) -> Result<Box<dyn crypto::Session>, ConnectError> {
        if self.0 {
            Ok(Box::new(FailingInitialKeys))
        } else {
            Err(ConnectError::Crypto(failure()))
        }
    }
    fn supports_version_switch(&self) -> bool {
        false
    }
    fn resumable_version(&self, _: &str) -> Option<Version> {
        None
    }
}

struct FailingServer(Arc<dyn crypto::ServerConfig>, bool);
impl crypto::InitialServerConfig for FailingServer {
    fn initial_keys(
        &self,
        version: Version,
        cid: &ConnectionId,
    ) -> Result<crypto::Keys, crypto::InitialKeysError> {
        self.0.initial_keys(version, cid)
    }
    fn retry_tag(
        &self,
        version: Version,
        cid: &ConnectionId,
        packet: &[u8],
    ) -> Result<[u8; 16], rama_quic_proto::crypto::CryptoError> {
        self.0.retry_tag(version, cid, packet)
    }
}
impl crypto::ServerConfig for FailingServer {
    fn start_session(
        self: Arc<Self>,
        _: Version,
        _: &TransportParameters,
    ) -> Result<Box<dyn crypto::Session>, TransportError> {
        if self.1 {
            Ok(Box::new(FailingInitialKeys))
        } else {
            Err(failure())
        }
    }
    fn supports_compatible_negotiation(&self) -> bool {
        false
    }
    fn start_negotiated_session(
        self: Arc<Self>,
        _: Version,
        _: Version,
        _: &TransportParameters,
    ) -> Result<Box<dyn crypto::Session>, TransportError> {
        Err(failure())
    }
}

struct FailingInitialKeys;
impl crypto::Session for FailingInitialKeys {
    fn initial_keys(
        &self,
        _: Version,
        _: &ConnectionId,
        _: Side,
    ) -> Result<crypto::Keys, TransportError> {
        Err(failure())
    }
    fn switch_version(&mut self, _: Version) -> Result<(), crypto::UnsupportedVersion> {
        Err(crypto::UnsupportedVersion)
    }
    fn handshake_summary(&self) -> Option<crypto::NegotiatedTlsParameters> {
        None
    }
    fn negotiated_alpn(&self) -> Option<&[u8]> {
        None
    }
    fn negotiated_key_exchange_group(&self) -> Option<u16> {
        None
    }
    fn early_crypto(
        &self,
    ) -> Option<(
        Box<dyn rama_quic_proto::crypto::HeaderKey>,
        Box<dyn rama_quic_proto::crypto::PacketKey>,
    )> {
        None
    }
    fn early_data_accepted(&self) -> Option<bool> {
        None
    }
    fn is_handshaking(&self) -> bool {
        true
    }
    fn poll_pending_callbacks(
        &mut self,
        _: &mut Context<'_>,
    ) -> Result<Option<bool>, TransportError> {
        Ok(None)
    }

    fn cancel_pending_callbacks(&mut self) {}

    fn read_handshake(
        &mut self,
        _: rama_quic_proto::packet::SpaceId,
        _: &[u8],
    ) -> Result<bool, TransportError> {
        Err(failure())
    }
    fn transport_parameters(&self) -> Result<Option<TransportParameters>, TransportError> {
        Err(failure())
    }
    fn poll_handshake(&mut self) -> Result<Option<crypto::HandshakeEvent>, TransportError> {
        Err(failure())
    }
    fn next_1rtt_keys(
        &mut self,
    ) -> Result<Option<crypto::KeyPair<Box<dyn rama_quic_proto::crypto::PacketKey>>>, TransportError>
    {
        Err(failure())
    }
    fn is_valid_retry(&self, _: &ConnectionId, _: &[u8], _: &[u8]) -> bool {
        false
    }
    fn export_keying_material(
        &self,
        _: &mut [u8],
        _: &[u8],
        _: &[u8],
    ) -> Result<(), crypto::ExportKeyingMaterialError> {
        Err(crypto::ExportKeyingMaterialError)
    }
}

fn failure() -> TransportError {
    TransportError::INTERNAL_ERROR("injected TLS session failure")
        .with_cause(std::io::Error::from(std::io::ErrorKind::PermissionDenied))
}

#[test]
fn failed_client_session_releases_reserved_cid() {
    use std::error::Error as _;
    for initial_keys in [false, true] {
        let mut endpoint = Endpoint::new(
            Arc::new(EndpointConfig::try_with_rand_key().unwrap()),
            None,
            true,
            None,
        );
        let config = ClientConfig::new(Arc::new(FailingClient(initial_keys)));
        for _ in 0..3 {
            let error = endpoint
                .connect(
                    Instant::now(),
                    config.clone(),
                    "127.0.0.1:443".parse().unwrap(),
                    "localhost",
                )
                .err()
                .unwrap();
            let source = error
                .source()
                .unwrap()
                .source()
                .unwrap()
                .downcast_ref::<std::io::Error>()
                .unwrap();
            assert_eq!(source.kind(), std::io::ErrorKind::PermissionDenied);
            assert_eq!(endpoint.known_cids(), 0);
            assert_eq!(endpoint.open_connections(), 0);
        }
    }
}

#[test]
fn failed_server_session_releases_reserved_and_preferred_cids() {
    use std::error::Error as _;
    for initial_keys in [false, true] {
        let mut config = server_config();
        config.crypto = ServerCrypto::Fixed(Arc::new(FailingServer(
            config.crypto.into_fixed(),
            initial_keys,
        )));
        config.preferred_address_v4 = Some("127.0.0.1:444".parse().unwrap());
        let mut pair = Pair::new(
            Arc::new(EndpointConfig::try_with_rand_key().unwrap()),
            config,
        );
        for _ in 0..3 {
            let client = pair.begin_connect(client_config());
            pair.drive();
            let error = pair.server.assert_accept_error();
            let source = error
                .source()
                .unwrap()
                .source()
                .unwrap()
                .downcast_ref::<std::io::Error>()
                .unwrap();
            assert_eq!(source.kind(), std::io::ErrorKind::PermissionDenied);
            assert_eq!(pair.server.known_cids(), 0);
            assert_eq!(pair.server.open_connections(), 0);
            assert_matches!(
                    pair.client_conn_mut(client).poll(),
                    Some(Event::ConnectionLost {
                reason: ConnectionError::ConnectionClosed(error),
            }) if error.error_code == TransportErrorCode::INTERNAL_ERROR,
                );
        }
    }
}
#[test]
fn retired_keys_do_not_replace_acknowledgment_of_the_current_phase() {
    let mut pair = Pair::default();
    let (client, server) = pair.connect();
    pair.drive();
    let now = pair.time + Duration::from_secs(1);
    pair.client_conn_mut(client)
        .assert_key_retirement_does_not_authorize_an_update(now);
    pair.server_conn_mut(server)
        .assert_key_retirement_does_not_authorize_an_update(now);
}

#[test]
fn server_does_not_decrypt_one_rtt_before_client_finished() {
    let mut pair = Pair::default();
    pair.begin_connect(client_config());
    pair.drive_client();
    pair.drive_server();
    let server = pair.server.assert_accept();
    assert!(pair.server_conn_mut(server).is_handshaking());
    // Complete short header and protection sample, with an invalid AEAD tag.
    // Attempting decryption would increment the authentication failure counter.
    let mut packet = BytesMut::from(&[0x40][..]);
    packet.resize(41, 0);
    let now = pair.time;
    pair.server_conn_mut(server)
        .assert_early_packet_is_not_decrypted(now, packet);
}

#[test]
fn client_does_not_decrypt_zero_rtt_while_resuming() {
    let mut pair = Pair::default();
    let config = client_config();
    pair.connect_with(config.clone());
    pair.drive();
    let client = pair.begin_connect(config);
    assert!(pair.client_conn_mut(client).has_0rtt());
    // 0-RTT long header: version 1, eight-byte destination ID, no source ID,
    // and 32 bytes of protected packet number/payload/tag.
    let mut packet = BytesMut::from(&[0xd0, 0, 0, 0, 1, 8][..]);
    packet.extend_from_slice(&[0; 8]);
    packet.extend_from_slice(&[0, 32]);
    packet.resize(48, 0);
    let now = pair.time;
    pair.client_conn_mut(client)
        .assert_early_packet_is_not_decrypted(now, packet);
}

/// RFC 9001 §6: TLS KeyUpdate has no place in QUIC, where keys change through the key phase
/// bit instead. A session that is handed one, at the level it would arrive at, refuses it with
/// the `unexpected_message` alert as a crypto error (0x010a), on both sides and whichever
/// backend is behind the session.
#[test]
fn a_tls_key_update_message_is_refused_as_an_unexpected_message() {
    let _guard = subscribe();
    let mut pair = Pair::default();
    let (client, server) = pair.connect();
    pair.drive();
    // HandshakeType key_update (24), three-byte length, KeyUpdateRequest update_not_requested.
    const KEY_UPDATE: [u8; 5] = [0x18, 0x00, 0x00, 0x01, 0x00];
    let client_error = pair
        .client_conn_mut(client)
        .crypto_session_mut()
        .read_handshake(SpaceId::Data, &KEY_UPDATE)
        .expect_err("the client session refuses a KeyUpdate");
    let server_error = pair
        .server_conn_mut(server)
        .crypto_session_mut()
        .read_handshake(SpaceId::Data, &KEY_UPDATE)
        .expect_err("the server session refuses a KeyUpdate");
    for (side, error) in [("client", client_error), ("server", server_error)] {
        assert_eq!(
            error.code(),
            TransportErrorCode::crypto(10),
            "{side}: unexpected_message, as a crypto error: {error}"
        );
        assert_eq!(error.code().as_u64(), 0x010a, "{side}");
    }
}

#[test]
fn failed_fresh_handshake_preserves_established_zero_cid_route() {
    for initial_keys in [false, true] {
        let mut endpoint = EndpointConfig::try_with_rand_key().unwrap();
        endpoint.set_cid_generator(Arc::new(|| {
            Box::new(RandomConnectionIdGenerator::new(0).unwrap())
        }));
        let mut pair = Pair::new(Arc::new(endpoint), server_config());
        let (client, server) = pair.connect();
        let mut failing = server_config();
        failing.crypto = ServerCrypto::Fixed(Arc::new(FailingServer(
            failing.crypto.into_fixed(),
            initial_keys,
        )));
        pair.server.set_server_config(Some(Arc::new(failing)));
        pair.fresh_attempt_from_client_address(client_config());
        pair.drive_server();
        // Refused before its TLS runs: the addresses belong to the established connection.
        assert_matches!(
            pair.server.assert_accept_error(),
            ConnectionError::EndpointInUse
        );
        assert_eq!(pair.server.open_connections(), 1);
        assert_eq!(pair.server.pending_incoming(), 0);
        assert_eq!(pair.server.admission_load(pair.time).0, 0);

        // One-way traffic avoids relying on the client's overwritten zero-CID route: this
        // checks that rejecting a fresh attempt preserved the established server route.
        let data = Bytes::from_static(b"established route survived");
        pair.client_datagrams(client)
            .send(data.clone(), true)
            .unwrap();
        pair.drive_client();
        pair.drive_server();
        assert_eq!(pair.server_datagrams(server).recv(), Some(data));
    }
}
