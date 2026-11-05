use std::{assert_matches, task::Context};

use rama_quic_proto::{
    ConnectionId, Side, TransportErrorCode, Version,
    crypto::{HeaderKey, PacketKey},
};

use super::*;
use crate::proto::{
    crypto::{ExportKeyingMaterialError, Session},
    tests::Pair,
};

struct FailedKeyUpdate {
    missing: bool,
}

impl Session for FailedKeyUpdate {
    fn initial_keys(&self, _: Version, _: &ConnectionId, _: Side) -> Result<Keys, TransportError> {
        Err(TransportError::INTERNAL_ERROR(
            "injected Initial key derivation failure",
        ))
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
    fn early_crypto(&self) -> Option<(Box<dyn HeaderKey>, Box<dyn PacketKey>)> {
        None
    }
    fn early_data_accepted(&self) -> Option<bool> {
        Some(false)
    }
    fn is_handshaking(&self) -> bool {
        false
    }
    fn poll_pending_callbacks(
        &mut self,
        _: &mut Context<'_>,
    ) -> Result<Option<bool>, TransportError> {
        Ok(None)
    }

    fn cancel_pending_callbacks(&mut self) {}

    #[expect(
        clippy::panic,
        reason = "the test injects only a post-handshake key update failure"
    )]
    fn read_handshake(&mut self, _: SpaceId, _: &[u8]) -> Result<bool, TransportError> {
        panic!("failure is injected after handshake completion")
    }
    fn transport_parameters(&self) -> Result<Option<TransportParameters>, TransportError> {
        Ok(None)
    }
    fn poll_handshake(&mut self) -> Result<Option<crypto::HandshakeEvent>, TransportError> {
        Ok(None)
    }
    fn next_1rtt_keys(&mut self) -> Result<Option<KeyPair<Box<dyn PacketKey>>>, TransportError> {
        if self.missing {
            Ok(None)
        } else {
            Err(TransportError::INTERNAL_ERROR(
                "injected key derivation failure",
            ))
        }
    }
    fn is_valid_retry(&self, _: &ConnectionId, _: &[u8], _: &[u8]) -> bool {
        false
    }
    fn export_keying_material(
        &self,
        _: &mut [u8],
        _: &[u8],
        _: &[u8],
    ) -> Result<(), ExportKeyingMaterialError> {
        Err(ExportKeyingMaterialError)
    }
}

#[test]
fn failed_key_derivation_closes_without_rotating_or_counting_an_update() {
    for missing in [false, true] {
        let mut pair = Pair::default();
        let (client, _) = pair.connect();
        let now = pair.time;
        let connection = pair.client_conn_mut(client);
        connection.crypto = Box::new(FailedKeyUpdate { missing });
        let phase = connection.key_phase;
        let sent = connection.spaces[SpaceId::Data].sent_with_keys;
        let updates = connection.stats.key_updates;
        assert!(!connection.force_key_update(now));
        assert_eq!(connection.key_phase, phase);
        assert_eq!(connection.spaces[SpaceId::Data].sent_with_keys, sent);
        assert_eq!(connection.stats.key_updates, updates);
        assert!(connection.prev_crypto.is_none());
        assert_matches!(
            connection.ended_because(),
            Some(ConnectionError::TransportError(error))
            if error.code == TransportErrorCode::INTERNAL_ERROR,
        );
    }
}

struct FailedEncryption;

impl PacketKey for FailedEncryption {
    fn encrypt(
        &self,
        _: u64,
        buffer: &mut [u8],
        _: usize,
    ) -> Result<(), rama_quic_proto::crypto::CryptoError> {
        buffer.fill(0x42);
        Err(rama_quic_proto::crypto::CryptoError::new())
    }
    fn decrypt(
        &self,
        _: u64,
        _: &[u8],
        _: &mut BytesMut,
    ) -> Result<(), rama_quic_proto::crypto::CryptoError> {
        Err(rama_quic_proto::crypto::CryptoError::new())
    }
    fn tag_len(&self) -> usize {
        16
    }
    fn confidentiality_limit(&self) -> u64 {
        u64::MAX
    }
    fn integrity_limit(&self) -> u64 {
        u64::MAX
    }
}

#[test]
fn failed_packet_encryption_does_not_emit_or_track_plaintext() {
    let mut pair = Pair::default();
    let (client, _) = pair.connect();
    let now = pair.time + Duration::from_millis(20);
    let connection = pair.client_conn_mut(client);
    // Drain whatever the just-completed handshake still owes (a Handshake-space ACK, HANDSHAKE_DONE
    // acknowledgement, and so on) before the failed key goes in. Those go out under real keys, so a
    // leftover one would make `poll_transmit` below return `Some` and the assertion flaky; the only
    // packet this test means to provoke is the ping it encrypts with `FailedEncryption`.
    let mut drain = Vec::new();
    while connection.poll_transmit(now, 4, &mut drain).is_some() {
        drain.clear();
    }
    // Keep the injected key installed: the randomized early key-update threshold
    // can otherwise rotate it out for a working key when the ping is built.
    connection.key_phase_size = u64::MAX;
    let updates = connection.stats.key_updates;
    connection.spaces[SpaceId::Data]
        .crypto
        .as_mut()
        .unwrap()
        .local
        .packet = Box::new(FailedEncryption);
    let sent = connection.stats.path.sent_packets;
    let datagrams = connection.stats.udp_tx.datagrams;
    connection.ping();
    let mut buffer = Vec::new();
    assert!(connection.poll_transmit(now, 1, &mut buffer).is_none());
    assert!(buffer.is_empty());
    assert_eq!(connection.stats.key_updates, updates);
    assert_eq!(connection.stats.path.sent_packets, sent);
    assert_eq!(connection.stats.udp_tx.datagrams, datagrams);
    assert_matches!(
        connection.ended_because(),
        Some(ConnectionError::TransportError(error))
        if error.code == TransportErrorCode::INTERNAL_ERROR,
    );
}
