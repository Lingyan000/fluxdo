use rama_core::telemetry::tracing::{debug, trace};

use rama_quic_proto::{
    RESET_TOKEN_SIZE, ResetToken, TransportError, Version,
    crypto::{HeaderKey, PacketKey},
    packet::{MAX_PACKET_NUMBER, Packet, PartialDecode, SpaceId},
};

use crate::proto::{
    Instant,
    connection::{qlog::drops::DropReason, spaces::PacketSpaces},
    crypto::{KeyPair, Keys},
};

/// Removes header protection of a packet, or returns the reason the packet was dropped
pub(super) fn unprotect_header(
    partial_decode: PartialDecode,
    spaces: &PacketSpaces,
    zero_rtt_crypto: Option<&ZeroRttCrypto>,
    original_initial: Option<(Version, &Keys)>,
    mut stateless_reset_tokens: impl Iterator<Item = ResetToken>,
) -> Result<UnprotectHeaderResult, DropReason> {
    let header_crypto = if partial_decode.is_0rtt() {
        if let Some(crypto) = zero_rtt_crypto {
            Some(&*crypto.header)
        } else {
            debug!("dropping unexpected 0-RTT packet");
            return Err(DropReason::KeyUnavailable);
        }
    } else if let Some((version, keys)) = original_initial
        && partial_decode.is_initial()
        && partial_decode.version() == Some(version)
    {
        // An Initial still in the client's first flight version (RFC 9369 §4.1).
        keys.remote.as_ref().map(|keys| &*keys.header)
    } else if let Some(space) = partial_decode.space() {
        if let Some(crypto) = spaces[space]
            .crypto
            .as_ref()
            .and_then(|keys| keys.remote.as_ref())
        {
            Some(&*crypto.header)
        } else {
            debug!(
                "discarding unexpected {:?} packet ({} bytes)",
                space,
                partial_decode.len(),
            );
            return Err(DropReason::KeyUnavailable);
        }
    } else {
        // Unprotected packet
        None
    };

    // A stateless reset carries the token of a connection ID we use (RFC 9000 §10.3.1); the
    // comparison leaks nothing about the token bytes.
    let packet = partial_decode.data();
    let stateless_reset = packet.len() >= RESET_TOKEN_SIZE + 5
        && stateless_reset_tokens.any(|token| {
            rama_quic_proto::constant_time::eq(&token, &packet[packet.len() - RESET_TOKEN_SIZE..])
        });

    let finished = match header_crypto {
        Some(key) => partial_decode.finish_protected(key),
        None => partial_decode.finish_unprotected(),
    };
    match finished {
        Ok(packet) => Ok(UnprotectHeaderResult {
            packet: Some(packet),
            stateless_reset,
        }),
        Err(_) if stateless_reset => Ok(UnprotectHeaderResult {
            packet: None,
            stateless_reset: true,
        }),
        Err(e) => {
            trace!("unable to complete packet decoding: {}", e);
            Err(DropReason::Invalid)
        }
    }
}

pub(super) struct UnprotectHeaderResult {
    /// The packet with the now unprotected header (`None` in the case of stateless reset packets
    /// that fail to be decoded)
    pub(super) packet: Option<Packet>,
    /// Whether the packet was a stateless reset packet
    pub(super) stateless_reset: bool,
}

/// Decrypts a packet's body in-place
#[expect(
    clippy::unwrap_used,
    reason = "`Connection::decrypt_packet` routes 0-RTT packets here only with 0-RTT keys, Initial/Handshake packets only while their space keeps keys, and a Data key-phase mismatch only after `next_crypto` was precomputed with the 1-RTT keys"
)]
pub(super) fn decrypt_packet_body(
    packet: &mut Packet,
    spaces: &PacketSpaces,
    zero_rtt_crypto: Option<&ZeroRttCrypto>,
    original_initial: Option<(Version, &Keys)>,
    conn_key_phase: bool,
    prev_crypto: Option<&PrevCrypto>,
    next_crypto: Option<&KeyPair<Box<dyn PacketKey>>>,
) -> Result<Option<DecryptPacketResult>, Option<TransportError>> {
    if !packet.header.is_protected() {
        // Unprotected packets also don't have packet numbers
        return Ok(None);
    }
    let space = packet.header.space();
    let rx_packet = spaces[space].rx_packet;
    let number = packet.header.number().ok_or(None)?.expand(rx_packet + 1);
    // No packet number exceeds 2^62 - 1 (RFC 9000 §12.3). This runs before authentication, so
    // such a packet is dropped like any other that does not open, rather than closing anything.
    if number > MAX_PACKET_NUMBER {
        return Err(None);
    }
    let packet_key_phase = packet.header.key_phase();

    let mut crypto_update = false;
    let crypto = if packet.header.is_0rtt() {
        &zero_rtt_crypto.unwrap().packet
    } else if let Some((version, keys)) = original_initial
        && space == SpaceId::Initial
        && packet.header.version() == Some(version)
    {
        &keys.remote.as_ref().ok_or(None)?.packet
    } else if packet_key_phase == conn_key_phase || space != SpaceId::Data {
        &spaces[space]
            .crypto
            .as_ref()
            .ok_or(None)?
            .remote
            .as_ref()
            .ok_or(None)?
            .packet
    } else if let Some(prev) = prev_crypto.filter(|&crypto|
        // Use the previous keys if this packet comes prior to acknowledgment of the
        // key update by the peer; otherwise, this must be a remotely-initiated key
        // update, so fall through to the final case.
        crypto.end_packet.is_none_or(|(pn, _)| number < pn))
    {
        &prev.crypto.remote
    } else {
        // We're in the Data space with a key phase mismatch and either there is no locally
        // initiated key update or the locally initiated key update was acknowledged by a
        // lower-numbered packet. The key phase mismatch must therefore represent a new
        // remotely-initiated key update.
        crypto_update = true;
        &next_crypto.unwrap().remote
    };

    // The AEAD says only that the packet did not authenticate, and such a packet is dropped
    // without telling the peer, so there is nothing to carry.
    if crypto
        .decrypt(number, &packet.header_data, &mut packet.payload)
        .is_err()
    {
        trace!("decryption failed with packet number {}", number);
        return Err(None);
    }

    if !packet.reserved_bits_valid() {
        return Err(Some(TransportError::PROTOCOL_VIOLATION(
            "reserved bits set",
        )));
    }

    let mut outgoing_key_update_acked = false;
    if let Some(prev) = prev_crypto
        && prev.end_packet.is_none()
        && packet_key_phase == conn_key_phase
    {
        outgoing_key_update_acked = true;
    }

    if crypto_update {
        // Validate incoming key update
        if number <= rx_packet || prev_crypto.is_some_and(|x| x.update_unacked) {
            return Err(Some(TransportError::KEY_UPDATE_ERROR("")));
        }
    }

    Ok(Some(DecryptPacketResult {
        number,
        outgoing_key_update_acked,
        incoming_key_update: crypto_update,
    }))
}

pub(super) struct DecryptPacketResult {
    /// The packet number
    pub(super) number: u64,
    /// Whether a locally initiated key update has been acknowledged by the peer
    pub(super) outgoing_key_update_acked: bool,
    /// Whether the peer has initiated a key update
    pub(super) incoming_key_update: bool,
}

pub(super) struct PrevCrypto {
    /// The keys used for the previous key phase, temporarily retained to decrypt packets sent by
    /// the peer prior to its own key update.
    pub(super) crypto: KeyPair<Box<dyn PacketKey>>,
    /// The incoming packet that ends the interval for which these keys are applicable, and the time
    /// of its receipt.
    ///
    /// Incoming packets should be decrypted using these keys iff this is `None` or their packet
    /// number is lower. `None` indicates that we have not yet received a packet using newer keys,
    /// which implies that the update was locally initiated.
    pub(super) end_packet: Option<(u64, Instant)>,
    /// Whether the following key phase is from a remotely initiated update that we haven't acked
    pub(super) update_unacked: bool,
}

pub(super) struct ZeroRttCrypto {
    pub(super) header: Box<dyn HeaderKey>,
    pub(super) packet: Box<dyn PacketKey>,
}
