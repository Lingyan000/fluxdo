//! The handshake: crypto progression, the packet spaces and keys it installs and discards,
//! the peer's transport parameters, and 0-RTT.

#[cfg(all(
    test,
    any(
        feature = "boring",
        all(feature = "rustls", any(feature = "aws-lc", feature = "ring"))
    )
))]
mod failure_tests;

use crate::qlog::event::negotiation::KeyChangeTrigger;
use rama_quic_proto::{
    EcnCodepoint, TransportError, VarInt, Version, frame,
    packet::{InitialPacket, SpaceId},
    transport_parameters::TransportParameters,
    version::VersionInformation,
};
use std::{cmp, mem, net::SocketAddr, task::Context};

use rama_core::{
    bytes::{Bytes, BytesMut},
    telemetry::tracing::{debug, error, trace, trace_span, warn},
};

use crate::proto::{
    Duration, Instant,
    connection::{
        Connection, ConnectionError, ConnectionSide, Event, State,
        packet_crypto::{PrevCrypto, ZeroRttCrypto},
        timer::Timer,
    },
    crypto::{self, HandshakeEvent, KeyPair, Keys},
};

impl Connection {
    /// The negotiated TLS key exchange group, if the session exposes it (test observation point)
    #[cfg(test)]
    pub(crate) fn negotiated_key_exchange_group(&self) -> Option<u16> {
        self.crypto.negotiated_key_exchange_group()
    }

    /// Enforce the handshake lifetime before processing queued packets in the async driver.
    pub(crate) fn expire_handshake(&mut self, now: Instant) {
        if self.timers.is_expired(Timer::Handshake, now) {
            self.qlog_handshake_timeout(now);
            self.kill(now, ConnectionError::TimedOut);
        }
    }

    /// Update traffic keys now. Answers whether an update was started.
    ///
    /// An update is initiated only once the handshake is confirmed (RFC 9001 §6.1) and only when
    /// no update is in flight (§6). Answering the peer's update is a different path and is not
    /// bound by the first of those.
    pub(crate) fn force_key_update(&mut self, now: Instant) -> bool {
        if !self.state.is_established() {
            debug!("ignoring forced key update in illegal state");
            return false;
        }
        if !self.handshake_confirmed() {
            debug!("ignoring forced key update before the handshake is confirmed");
            return false;
        }
        if self.prev_crypto.is_some() {
            // We already just updated, or are currently updating, the keys. Concurrent key updates
            // are illegal.
            debug!("ignoring redundant forced key update");
            return false;
        }
        if self.key_update_start_packet.is_some_and(|start| {
            self.spaces[SpaceId::Data]
                .largest_acked_packet
                .is_none_or(|acked| acked < start)
        }) {
            debug!("ignoring key update before a current-phase packet is acknowledged");
            return false;
        }
        match self.update_keys(now, None, false) {
            Ok(()) => true,
            Err(error) => {
                self.kill(now, error.into());
                false
            }
        }
    }

    /// Get a session reference
    pub(crate) fn crypto_session(&self) -> &dyn crypto::Session {
        &*self.crypto
    }

    /// Whether the connection is in the process of being established
    ///
    /// If this returns `false`, the connection may be either established or closed, signaled by the
    /// emission of a `Connected` or `ConnectionLost` message respectively.
    pub(crate) fn is_handshaking(&self) -> bool {
        self.state.is_handshake()
    }

    /// Whether the handshake is confirmed (RFC 9001 §4.1.2): the server confirms it on
    /// completion, the client once HANDSHAKE_DONE arrived and its Handshake keys are gone.
    /// Active migration is only allowed from then on (RFC 9000 §9).
    pub(crate) fn handshake_confirmed(&self) -> bool {
        !self.state.is_handshake()
            && (self.side.is_server() || self.spaces[SpaceId::Handshake].crypto.is_none())
    }

    /// For clients, if the peer accepted the 0-RTT data packets
    ///
    /// The value is meaningless until after the handshake completes.
    pub(crate) fn accepted_0rtt(&self) -> bool {
        self.early_data == Some(true)
    }

    /// The early-data decision, set atomically with leaving the handshake (clients only).
    pub(crate) fn early_data_decision(&self) -> Option<bool> {
        self.early_data
    }

    /// Whether 0-RTT is/was possible during the handshake
    pub(crate) fn has_0rtt(&self) -> bool {
        self.zero_rtt_enabled
    }

    /// Handle the already-decrypted first packet from the client
    ///
    /// Decrypting the first packet in the `Endpoint` allows stateless packet handling to be more
    /// efficient.
    pub(crate) fn handle_first_packet(
        &mut self,
        now: Instant,
        remote: SocketAddr,
        local: Option<SocketAddr>,
        ecn: Option<EcnCodepoint>,
        packet_number: u64,
        packet: InitialPacket,
        remaining: Option<BytesMut>,
    ) -> Result<(), ConnectionError> {
        let span = trace_span!("first recv");
        let _guard = span.enter();
        debug_assert!(self.side.is_server());
        // What bounds the response is what arrived on the wire, and the decrypted payload is
        // shorter than the ciphertext by the AEAD tag (RFC 9000 §8.1).
        let tag_len = self.spaces[SpaceId::Initial]
            .crypto
            .as_ref()
            .and_then(|crypto| crypto.remote.as_ref())
            .map_or(0, |crypto| crypto.packet.tag_len());
        let len = packet.header_data.len() + packet.payload.len() + tag_len;
        self.path.total_recvd = len as u64;

        match self.state {
            State::Handshake(ref mut state) => {
                state.expected_token = packet.header.token.clone();
            }
            #[expect(
                clippy::unreachable,
                reason = "the first-packet handling runs from `Connection::new`, whose state is `Handshake` until a packet is processed"
            )]
            _ => unreachable!("first packet must be delivered in Handshake state"),
        }

        self.on_packet_authenticated(now, SpaceId::Initial, ecn, Some(packet_number), false);

        self.qlog_sink.emit_packet_received(
            packet_number,
            Some(len),
            SpaceId::Initial,
            false,
            now,
            self.trace_cid,
        );

        let packet = packet.into();
        if let Some(observation) = &mut self.observation {
            observation.packet(&packet, packet_number);
        }
        self.process_decrypted_packet(now, remote, local, Some(packet_number), packet)
            .inspect_err(|error| {
                self.qlog_connection_error(now, error);
                self.qlog_discarded(now);
            })?;
        self.qlog_observe_state(now);
        if let Some(data) = remaining {
            self.handle_coalesced(now, remote, local, ecn, &data);
        }
        if let Some(observation) = &mut self.observation {
            observation.end_datagram();
        }

        self.qlog_sink
            .emit_recovery_metrics(self.pto_count, &mut self.path, now, self.trace_cid);

        Ok(())
    }

    pub(super) fn init_0rtt(&mut self, now: Instant) {
        let Some((header, packet)) = self.crypto.early_crypto() else {
            return;
        };
        if self.side.is_client() {
            match self.crypto.transport_parameters() {
                Ok(params) => {
                    #[expect(
                        clippy::expect_used,
                        reason = "rustls only offers a resumption ticket after the handshake supplied the peer transport parameters (`transport_parameters()` is `Ok(Some)` then)"
                    )]
                    let params = params
                        .expect("crypto layer didn't supply transport parameters with ticket");
                    // Certain values must not be cached
                    let params = TransportParameters {
                        initial_src_cid: None,
                        original_dst_cid: None,
                        preferred_address: None,
                        retry_src_cid: None,
                        stateless_reset_token: None,
                        min_ack_delay: None,
                        ack_delay_exponent: TransportParameters::default().ack_delay_exponent,
                        max_ack_delay: TransportParameters::default().max_ack_delay,
                        ..params
                    };
                    self.qlog_restored_parameters(now, &params);
                    self.set_peer_params(now, params);
                }
                Err(e) => {
                    error!("session ticket has malformed transport parameters: {}", e);
                    return;
                }
            }
        }
        trace!("0-RTT enabled");
        self.zero_rtt_enabled = true;
        self.zero_rtt_crypto = Some(ZeroRttCrypto { header, packet });
        self.qlog_zero_rtt_key(now, false);
    }

    pub(super) fn read_crypto(
        &mut self,
        space: SpaceId,
        crypto: &frame::Crypto,
        allocated: usize,
    ) -> Result<(), TransportError> {
        let expected = if !self.state.is_handshake() {
            SpaceId::Data
        } else if self.highest_space == SpaceId::Initial {
            SpaceId::Initial
        } else {
            // On the server, self.highest_space can be Data after receiving the client's first
            // flight, but we expect Handshake CRYPTO until the handshake is complete.
            SpaceId::Handshake
        };
        // We can't decrypt Handshake packets when highest_space is Initial, CRYPTO frames in 0-RTT
        // packets are illegal, and we don't process 1-RTT packets until the handshake is
        // complete. Therefore, we will never see CRYPTO data from a later-than-expected space.
        debug_assert!(space <= expected, "received out-of-order CRYPTO data");

        let end = crypto.offset + crypto.data.len() as u64;
        // Repeated peer handshake data can signal a lost response; recover it with the ACK.
        // After confirmation, servers instead use their ACK / HANDSHAKE_DONE paths.
        let early_recovery =
            (self.side.is_server() && self.state.is_handshake() && space == SpaceId::Initial)
                || (self.side.is_client()
                    && self.state.is_established()
                    && !self.handshake_confirmed()
                    && space == SpaceId::Handshake
                    && self.spaces[space].crypto.is_some());
        let duplicate_handshake_crypto = early_recovery
            && !crypto.data.is_empty()
            && end <= self.spaces[space].crypto_stream.bytes_read();
        if space < expected && end > self.spaces[space].crypto_stream.bytes_read() {
            warn!(
                "received new {:?} CRYPTO data when expecting {:?}",
                space, expected
            );
            return Err(TransportError::PROTOCOL_VIOLATION(
                "new data at unexpected encryption level",
            ));
        }

        let level = space;
        let space = &mut self.spaces[space];
        let max = end.saturating_sub(space.crypto_stream.bytes_read());
        if max > self.config.crypto_buffer_size as u64 {
            return Err(TransportError::CRYPTO_BUFFER_EXCEEDED(""));
        }

        // As above: the assembler reports only that it holds too many spans.
        if space
            .crypto_stream
            .insert(crypto.offset, crypto.data.clone(), allocated)
            .is_err()
        {
            return Err(TransportError::INTERNAL_ERROR(
                "too many gaps in crypto stream buffer",
            ));
        }

        while let Some(chunk) = space.crypto_stream.read(usize::MAX, true) {
            trace!("consumed {} CRYPTO bytes", chunk.bytes.len());
            if self.crypto.read_handshake(level, &chunk.bytes)? {
                self.events.push_back(Event::HandshakeDataReady);
            }
        }

        if duplicate_handshake_crypto {
            space.maybe_queue_early_crypto();
        }

        Ok(())
    }

    pub(super) fn write_crypto(&mut self, now: Instant) {
        loop {
            let event = match self.crypto.poll_handshake() {
                Ok(Some(event)) => event,
                Ok(None) => break,
                Err(error) => {
                    self.kill(now, error.into());
                    break;
                }
            };
            let (space, outgoing) = match event {
                HandshakeEvent::Data(space, bytes) => (space, bytes),
                HandshakeEvent::Keys(space, keys) => {
                    self.upgrade_crypto(now, space, keys);
                    continue;
                }
                HandshakeEvent::ReadKeys(space, keys) => {
                    let Some(crypto) = self.spaces[space].crypto.as_mut() else {
                        self.kill(
                            now,
                            TransportError::INTERNAL_ERROR("read keys before write keys").into(),
                        );
                        break;
                    };
                    if crypto.remote.is_some() {
                        self.kill(
                            now,
                            TransportError::INTERNAL_ERROR("duplicate read keys").into(),
                        );
                        break;
                    }
                    crypto.remote = Some(keys);
                    self.qlog_directional_key_change(
                        now,
                        space,
                        !self.side.is_client(),
                        false,
                        Some(KeyChangeTrigger::Tls),
                    );
                    if space == SpaceId::Data
                        && let Err(error) = self.prepare_key_update()
                    {
                        self.kill(now, error.into());
                        break;
                    }
                    continue;
                }
            };
            let offset = self.spaces[space].crypto_offset;
            let outgoing = Bytes::from(outgoing);
            if let State::Handshake(ref mut state) = self.state
                && space == SpaceId::Initial
                && offset == 0
                && self.side.is_client()
            {
                state.client_hello = Some(outgoing.clone());
            }
            self.spaces[space].crypto_offset += outgoing.len() as u64;
            trace!("wrote {} {:?} CRYPTO bytes", outgoing.len(), space);
            self.spaces[space].pending.crypto.push_back(frame::Crypto {
                offset,
                data: outgoing,
            });
        }
    }

    /// Switch to stronger cryptography during handshake
    fn upgrade_crypto(&mut self, now: Instant, space: SpaceId, crypto: Keys) {
        debug_assert!(
            self.spaces[space].crypto.is_none(),
            "already reached packet space {space:?}"
        );
        trace!("{:?} keys ready", space);
        if space == SpaceId::Data
            && crypto.remote.is_some()
            && let Err(error) = self.prepare_key_update()
        {
            self.kill(now, error.into());
            return;
        }

        if space == SpaceId::Data && !self.config.early_key_update {
            // No early update: the first phase ends near the limit, as later ones do.
            self.key_phase_size = crypto
                .local
                .packet
                .confidentiality_limit()
                .saturating_sub(KEY_UPDATE_MARGIN);
        }
        let has_remote = crypto.remote.is_some();
        self.spaces[space].crypto = Some(crypto);
        self.qlog_directional_key_change(
            now,
            space,
            self.side.is_client(),
            false,
            Some(KeyChangeTrigger::Tls),
        );
        if has_remote {
            self.qlog_directional_key_change(
                now,
                space,
                !self.side.is_client(),
                false,
                Some(KeyChangeTrigger::Tls),
            );
        }
        if space == SpaceId::Data {
            self.qlog_negotiated_alpn(now);
        }
        debug_assert!(space as usize > self.highest_space as usize);
        self.highest_space = space;
        if space == SpaceId::Data && self.side.is_client() {
            // Discard 0-RTT keys because 1-RTT keys are available.
            if self.zero_rtt_crypto.take().is_some() {
                self.qlog_zero_rtt_key(now, true);
            }
        }
    }

    pub(super) fn discard_space(&mut self, now: Instant, space_id: SpaceId) {
        debug_assert!(space_id != SpaceId::Data);
        trace!("discarding {:?} keys", space_id);
        if space_id == SpaceId::Initial {
            if let Some(observation) = &mut self.observation {
                observation.finish();
            }
            // No longer needed
            if let ConnectionSide::Client { token, .. } = &mut self.side {
                *token = Bytes::new();
            }
        }
        if self.spaces[space_id].crypto.take().is_some() {
            self.qlog_key_change(now, space_id, true, Some(KeyChangeTrigger::Tls));
        }
        let space = &mut self.spaces[space_id];
        space.time_of_last_ack_eliciting_packet = None;
        space.loss_time = None;
        let sent_packets = space.take_sent_packets();
        for packet in sent_packets.into_values() {
            self.remove_in_flight(&packet);
        }
        // Key discard is forward progress: do not carry Initial/Handshake PTO
        // backoff into the next packet number space (RFC 9002 §6.2.2, A.11).
        self.pto_count = 0;
        self.set_loss_detection_timer(now)
    }

    /// Tests: hold HANDSHAKE_DONE back before it has been sent, so the peer stays complete but
    /// unconfirmed; clearing it queues the frame again for the next transmit.
    ///
    /// The fixture covers that phase only. It takes the frame out of the pending set rather than
    /// suppressing the write, so nothing announces a frame it will not write; it cannot recall one
    /// that has already gone, and a later loss requeues that one through retransmission like any
    /// other frame.
    #[cfg(test)]
    pub(crate) fn hold_handshake_done(&mut self, hold: bool) {
        self.hold_handshake_done = hold;
        if hold {
            self.withheld_handshake_done |=
                mem::take(&mut self.spaces[SpaceId::Data].pending.handshake_done);
        } else if mem::take(&mut self.withheld_handshake_done) {
            self.spaces[SpaceId::Data].pending.handshake_done = true;
        }
    }

    /// Queue HANDSHAKE_DONE for the peer. Withholding it keeps it out of the pending set: a frame
    /// that will not be written must not announce that there is something to send.
    pub(super) fn queue_handshake_done(&mut self) {
        #[cfg(test)]
        if self.hold_handshake_done {
            self.withheld_handshake_done = true;
            return;
        }
        self.spaces[SpaceId::Data].pending.handshake_done = true;
    }

    /// Handle transport parameters received from the peer
    pub(super) fn handle_peer_params(
        &mut self,
        now: Instant,
        params: TransportParameters,
    ) -> Result<(), TransportError> {
        if Some(self.orig_rem_cid) != params.initial_src_cid
            || (self.side.is_client()
                && (Some(self.initial_dst_cid) != params.original_dst_cid
                    || self.retry_src_cid != params.retry_src_cid))
        {
            return Err(TransportError::TRANSPORT_PARAMETER_ERROR(
                "CID authentication failure",
            ));
        }
        self.validate_peer_versions(&params)?;

        self.qlog_remote_parameters(now, &params);
        self.set_peer_params(now, params);
        self.peer_params_received = true;

        Ok(())
    }

    /// RFC 9368 §4: the peer's `version_information` must agree with the version in use, and
    /// a client that reacted to a Version Negotiation packet checks that the server's list
    /// would have led it to the same version.
    fn validate_peer_versions(&self, params: &TransportParameters) -> Result<(), TransportError> {
        match &self.side {
            ConnectionSide::Server { .. } => {
                if params
                    .version_information
                    .as_ref()
                    .is_some_and(|info| info.chosen() != self.original_version())
                {
                    return Err(TransportError::VERSION_NEGOTIATION_ERROR(
                        "client's chosen version differs from its first flight",
                    ));
                }
                Ok(())
            }
            ConnectionSide::Client {
                versions,
                negotiation_offer,
                ..
            } => {
                let info = match (&params.version_information, negotiation_offer) {
                    (Some(info), _) => info.clone(),
                    (None, None) => return Ok(()),
                    // A server that only speaks v1 predates version negotiation (RFC 9368 §8).
                    (None, Some(_)) if self.version() == Version::V1 => {
                        VersionInformation::new(Version::V1, vec![Version::V1])
                    }
                    (None, Some(_)) => {
                        return Err(TransportError::VERSION_NEGOTIATION_ERROR(
                            "server sent no version_information after Version Negotiation",
                        ));
                    }
                };
                if info.chosen() != self.version() {
                    return Err(TransportError::VERSION_NEGOTIATION_ERROR(
                        "server's chosen version differs from the negotiated version",
                    ));
                }
                if negotiation_offer.is_some() {
                    if info.available().is_empty() {
                        // RFC 9368 §4: an empty Available Versions list cannot justify the version
                        // the client was moved to, so a reacted-to Version Negotiation with one is
                        // indistinguishable from a downgrade attack.
                        return Err(TransportError::VERSION_NEGOTIATION_ERROR(
                            "server's Available Versions is empty after Version Negotiation",
                        ));
                    }
                    let mut would_see = info.available().to_vec();
                    would_see.push(self.version());
                    if versions.select(&would_see) != Some(self.version()) {
                        return Err(TransportError::VERSION_NEGOTIATION_ERROR(
                            "Version Negotiation led to a version the server's list does not justify",
                        ));
                    }
                }
                Ok(())
            }
        }
    }

    fn set_peer_params(&mut self, now: Instant, params: TransportParameters) {
        self.streams.set_params(&params);
        self.idle_timeout =
            negotiate_max_idle_timeout(self.config.max_idle_timeout, Some(params.max_idle_timeout));
        trace!("negotiated max idle timeout {:?}", self.idle_timeout);
        if let Some(ref info) = params.preferred_address {
            #[expect(clippy::expect_used, reason = "`set_peer_params` runs once, right after the handshake, when the CID queue only holds sequence 0, so sequence 1 always fits")]
            self.rem_cids.insert(frame::NewConnectionId {
                sequence: 1,
                id: info.connection_id,
                reset_token: info.stateless_reset_token,
                retire_prior_to: 0,
            }).expect("preferred address CID is the first received, and hence is guaranteed to be legal");
            self.arm_preferred_address(info);
        }
        self.ack_frequency.peer_max_ack_delay = get_max_ack_delay(&params);
        self.peer_params = params;
        let old_mtu = self.path.current_mtu();
        self.path.mtud.on_peer_max_udp_payload_size_received(
            u16::try_from(self.peer_params.max_udp_payload_size.into_inner()).unwrap_or(u16::MAX),
        );
        self.qlog_mtu_updated(now, old_mtu);
    }

    fn prepare_key_update(&mut self) -> Result<(), TransportError> {
        self.next_crypto = Some(self.crypto.next_1rtt_keys()?.ok_or_else(|| {
            TransportError::INTERNAL_ERROR("TLS did not provide key update secrets")
        })?);
        Ok(())
    }

    pub(super) fn update_keys(
        &mut self,
        now: Instant,
        end_packet: Option<(u64, Instant)>,
        remote: bool,
    ) -> Result<(), TransportError> {
        trace!("executing key update");
        // Generate keys for the key phase after the one we're switching to, store them in
        // `next_crypto`, make the contents of `next_crypto` current, and move the current keys into
        // `prev_crypto`.
        let new = self.crypto.next_1rtt_keys()?.ok_or_else(|| {
            TransportError::INTERNAL_ERROR("TLS did not provide key update secrets")
        })?;
        let key_phase_size = new
            .local
            .confidentiality_limit()
            .saturating_sub(KEY_UPDATE_MARGIN);
        let missing_keys =
            || TransportError::INTERNAL_ERROR("key update before directional keys are installed");
        let keys = self.spaces[SpaceId::Data]
            .crypto
            .as_mut()
            .ok_or_else(missing_keys)?;
        let read_keys = keys.remote.as_mut().ok_or_else(missing_keys)?;
        let next = self.next_crypto.as_mut().ok_or_else(missing_keys)?;
        let replacement = mem::replace(next, new);
        let old = KeyPair {
            local: mem::replace(&mut keys.local.packet, replacement.local),
            remote: mem::replace(&mut read_keys.packet, replacement.remote),
        };
        self.qlog_discard_previous_keys(now);
        self.stats.key_updates = self.stats.key_updates.saturating_add(1);
        self.key_phase_size = key_phase_size;
        self.spaces[SpaceId::Data].sent_with_keys = 0;
        self.key_update_start_packet = Some(self.spaces[SpaceId::Data].next_packet_number);
        self.prev_crypto = Some(PrevCrypto {
            crypto: old,
            end_packet,
            update_unacked: remote,
        });
        self.key_phase = !self.key_phase;
        self.qlog_key_change(
            now,
            SpaceId::Data,
            false,
            Some(if remote {
                KeyChangeTrigger::RemoteUpdate
            } else {
                KeyChangeTrigger::LocalUpdate
            }),
        );
        Ok(())
    }

    pub(super) fn peer_supports_ack_frequency(&self) -> bool {
        self.peer_params.min_ack_delay.is_some()
    }
}

pub(super) fn get_max_ack_delay(params: &TransportParameters) -> Duration {
    Duration::from_micros(params.max_ack_delay * 1000)
}

/// Perform key updates this many packets before the AEAD confidentiality limit.
///
/// Chosen arbitrarily, intended to be large enough to prevent spurious connection loss.
const KEY_UPDATE_MARGIN: u64 = 10_000;

/// Compute the negotiated idle timeout based on local and remote max_idle_timeout transport parameters.
///
/// According to the definition of max_idle_timeout, a value of `0` means the timeout is disabled; see <https://www.rfc-editor.org/rfc/rfc9000#section-18.2-4.4.1.>
///
/// According to the negotiation procedure, either the minimum of the timeouts or one specified is used as the negotiated value; see <https://www.rfc-editor.org/rfc/rfc9000#section-10.1-2.>
///
/// Returns the negotiated idle timeout as a `Duration`, or `None` when both endpoints have opted out of idle timeout.
pub(super) fn negotiate_max_idle_timeout(x: Option<VarInt>, y: Option<VarInt>) -> Option<Duration> {
    // A zero or absent value means "no timeout"; otherwise the lower of the two wins.
    let x = x.map(VarInt::into_inner).filter(|&v| v != 0);
    let y = y.map(VarInt::into_inner).filter(|&v| v != 0);
    match (x, y) {
        (None, None) => None,
        (Some(v), None) | (None, Some(v)) => Some(Duration::from_millis(v)),
        (Some(a), Some(b)) => Some(Duration::from_millis(cmp::min(a, b))),
    }
}

impl Connection {
    /// Resume TLS callback work that waits asynchronously, such as a relay answering a
    /// CertificateRequest later. A session without such work returns at once, and the
    /// clock is read only when something resumed.
    pub(crate) fn poll_pending_callbacks(
        &mut self,
        now: impl FnOnce() -> Instant,
        cx: &mut Context<'_>,
    ) {
        if !self.state.is_handshake() {
            return;
        }
        let metadata_ready = match self.crypto.poll_pending_callbacks(cx) {
            Ok(None) => return,
            Ok(Some(ready)) => ready,
            Err(error) => {
                self.kill(now(), error.into());
                return;
            }
        };
        let now = now();
        if metadata_ready {
            self.events.push_back(Event::HandshakeDataReady);
        }
        self.write_crypto(now);
        if let Err(error) = self.finish_handshake(now) {
            self.kill(now, error.into());
        }
    }

    /// Drop pending TLS callback work: nothing may resume once the connection closed.
    pub(crate) fn cancel_pending_callbacks(&mut self) {
        self.crypto.cancel_pending_callbacks();
    }
}

#[cfg(test)]
mod tests;
