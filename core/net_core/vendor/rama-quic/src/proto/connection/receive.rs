//! Taking a datagram apart: dispatch by space, decryption, the packets coalesced behind the
//! first, and what an authenticated packet settles.

use crate::qlog::event::negotiation::KeyChangeTrigger;
use rama_quic_proto::{
    EcnCodepoint, TransportError, TransportErrorCode, Version,
    frame::{self, Close, Frame},
    packet::{
        FixedLengthConnectionIdParser, Header, InitialHeader, LongType, Packet, PartialDecode,
        SpaceId,
    },
};
use std::net::SocketAddr;

use rama_core::{
    bytes::{Bytes, BytesMut},
    telemetry::tracing::{debug, trace, trace_span, warn},
};

use crate::proto::{
    Instant,
    connection::{
        Connection, ConnectionError, ConnectionSide, Event, State, packet_crypto,
        qlog::drops::{DropInfo, DropReason},
        spaces::{PacketSpace, Retransmits},
        state,
        timer::Timer,
    },
    shared::EndpointEventInner,
    token::bounded_token,
};

#[cfg(test)]
use crate::proto::shared::{ConnectionEvent, ConnectionEventInner, DatagramConnectionEvent};

impl Connection {
    pub(super) fn on_packet_authenticated(
        &mut self,
        now: Instant,
        space_id: SpaceId,
        ecn: Option<EcnCodepoint>,
        packet: Option<u64>,
        is_1rtt: bool,
    ) {
        self.total_authed_packets += 1;
        self.reset_keep_alive(now);
        self.reset_idle_timeout(now, space_id);
        self.permit_idle_reset = true;
        self.receiving_ecn |= ecn.is_some();
        if let Some(x) = ecn {
            let space = &mut self.spaces[space_id];
            space.ecn_counters += x;

            if x.is_ce() {
                space.pending_acks.set_immediate_ack_required();
            }
        }

        let Some(packet) = packet else { return };
        if self.side.is_server() {
            if self.spaces[SpaceId::Initial].crypto.is_some() && space_id == SpaceId::Handshake {
                // A server stops sending and processing Initial packets when it receives its first Handshake packet.
                self.discard_space(now, SpaceId::Initial);
            }
            if self.zero_rtt_crypto.is_some() && is_1rtt {
                // Discard 0-RTT keys soon after receiving a 1-RTT packet
                self.set_key_discard_timer(now, space_id)
            }
        }
        let space = &mut self.spaces[space_id];
        space.pending_acks.insert_one(packet, now);
        if packet >= space.rx_packet {
            space.rx_packet = packet;
        }
    }

    pub(super) fn handle_coalesced(
        &mut self,
        now: Instant,
        remote: SocketAddr,
        local: Option<SocketAddr>,
        ecn: Option<EcnCodepoint>,
        data: &[u8],
    ) {
        let received_bytes = data.len() as u64;
        // What followed the first packet still shares its datagram's allocation; one copy gives
        // it a buffer of its own, which each packet split from it is then charged against.
        let data = BytesMut::from(data);
        let allocated = data.len();
        let mut remaining = Some(data);
        while let Some(data) = remaining {
            match PartialDecode::new_within(
                data,
                allocated,
                &FixedLengthConnectionIdParser::new(self.local_cid_state.cid_len()),
                &self.decodable_versions(),
                self.endpoint_config.grease_quic_bit,
            ) {
                Ok((partial_decode, rest)) => {
                    remaining = rest;
                    self.handle_decode(now, remote, local, ecn, partial_decode);
                }
                Err(e) => {
                    trace!("malformed header: {}", e);
                    let reason = match e {
                        rama_quic_proto::packet::PacketDecodeError::UnsupportedVersion {
                            ..
                        } => DropReason::Unsupported,
                        rama_quic_proto::packet::PacketDecodeError::InvalidHeader(_) => {
                            DropReason::Invalid
                        }
                    };
                    self.qlog_packet_dropped(now, DropInfo::unknown(), reason);
                    return;
                }
            }
        }
        if remote == self.path.remote && self.same_local(local) {
            self.path.total_recvd = self.path.total_recvd.saturating_add(received_bytes);
        }
    }

    pub(super) fn handle_decode(
        &mut self,
        now: Instant,
        remote: SocketAddr,
        local: Option<SocketAddr>,
        ecn: Option<EcnCodepoint>,
        partial_decode: PartialDecode,
    ) {
        self.receive_packet(now, remote, local, ecn, partial_decode);
        self.replay_early_packets(now);
    }

    pub(super) fn receive_packet(
        &mut self,
        now: Instant,
        remote: SocketAddr,
        local: Option<SocketAddr>,
        ecn: Option<EcnCodepoint>,
        partial_decode: PartialDecode,
    ) {
        let info = DropInfo::partial(&partial_decode);
        if self.state.is_drained() {
            // Nothing is left to do with a packet, and one that failed to authenticate would be
            // counted against a limit that already ended the connection (RFC 9001 §6.6).
            self.qlog_packet_dropped(now, info, DropReason::Rejected);
            return;
        }
        let reject_early_data = self.side.is_client() && partial_decode.is_0rtt();
        let partial_decode = if reject_early_data {
            partial_decode
        } else {
            match self.try_hold_early_packet(now, remote, local, ecn, partial_decode) {
                Some(partial_decode) => partial_decode,
                None => return,
            }
        };
        // Established is entered only after TLS completion. Only an aborted
        // handshake in a closed state needs a backend query on this path.
        let reject_short = !partial_decode.has_long_header()
            && (self.state.is_handshake()
                || (self.state.is_closed() && self.crypto.is_handshaking()));
        if reject_early_data || reject_short {
            // RFC 9001 §§5.6–5.7: clients never decrypt received 0-RTT, and
            // neither role decrypts 1-RTT before TLS completion. Discard before
            // header/body protection or duplicate tracking changes any state.
            let reason = if reject_short && self.spaces[SpaceId::Data].crypto.is_none() {
                DropReason::KeyUnavailable
            } else {
                DropReason::Rejected
            };
            self.qlog_packet_dropped(now, info, reason);
            return;
        }
        if let Some(version) = partial_decode.version()
            && version != self.version()
            && !self.accept_other_version(now, version, &partial_decode)
        {
            self.qlog_packet_dropped(now, info, DropReason::Unsupported);
            return;
        }
        match packet_crypto::unprotect_header(
            partial_decode,
            &self.spaces,
            self.zero_rtt_crypto.as_ref(),
            self.original_initial_keys(),
            // A reset is only ours when it comes from an address this identifier was sent to.
            self.used_reset_tokens(remote),
        ) {
            Ok(decoded) => self.handle_packet(
                now,
                remote,
                local,
                ecn,
                decoded.packet,
                decoded.stateless_reset,
            ),
            Err(reason) => self.qlog_packet_dropped(now, info, reason),
        }
        self.qlog_observe_state(now);
    }

    fn handle_packet(
        &mut self,
        now: Instant,
        remote: SocketAddr,
        local: Option<SocketAddr>,
        ecn: Option<EcnCodepoint>,
        packet: Option<Packet>,
        stateless_reset: bool,
    ) {
        let info = packet
            .as_ref()
            .map(DropInfo::packet)
            .unwrap_or_else(DropInfo::unknown);
        self.stats.udp_rx.ios += 1;
        if let Some(ref packet) = packet {
            trace!(
                "got {:?} packet ({} bytes) from {} using id {}",
                packet.header.space(),
                packet.payload.len() + packet.header_data.len(),
                remote,
                packet.header.dst_cid(),
            );
        }

        if self.is_handshaking() && remote != self.path.remote {
            debug!("discarding packet with unexpected remote during handshake");
            self.qlog_packet_dropped(now, info, DropReason::Rejected);
            return;
        }

        let was_handshaking = self.is_handshaking();
        let was_closed = self.state.is_closed();
        let was_drained = self.state.is_drained();

        let decrypted = match packet {
            None => Err(None),
            Some(mut packet) => self
                .decrypt_packet(now, &mut packet)
                .map(move |number| (packet, number)),
        };
        let result = match decrypted {
            _ if stateless_reset => {
                debug!("got stateless reset");
                Err(ConnectionError::Reset)
            }
            Err(Some(e)) => {
                warn!("illegal packet: {}", e);
                self.qlog_packet_dropped(now, info, DropReason::Invalid);
                Err(e.into())
            }
            Err(None) => {
                debug!("failed to authenticate packet");
                self.qlog_packet_dropped(now, info, DropReason::DecryptionFailure);
                self.authentication_failures += 1;
                #[expect(
                    clippy::unwrap_used,
                    reason = "a packet can only fail authentication after keys for `highest_space` were installed; earlier packets are dropped as undecryptable"
                )]
                let integrity_limit = self.spaces[self.highest_space]
                    .crypto
                    .as_ref()
                    .unwrap()
                    .local
                    .packet
                    .integrity_limit();
                if self.authentication_failures > integrity_limit {
                    Err(TransportError::AEAD_LIMIT_REACHED("integrity limit violated").into())
                } else {
                    return;
                }
            }
            Ok((packet, number)) => {
                let span = if let Some(pn) = number {
                    trace_span!("recv", space = ?packet.header.space(), pn)
                } else {
                    trace_span!("recv", space = ?packet.header.space())
                };
                let _guard = span.enter();

                if let Some(observation) = &mut self.observation
                    && let Some(number) = number
                {
                    let token_valid = match (&packet.header, &self.state) {
                        (Header::Initial(header), State::Handshake(hs)) => {
                            header.token == hs.expected_token
                        }
                        _ => true,
                    };
                    if token_valid {
                        observation.packet(&packet, number);
                    }
                }
                let is_duplicate = |n| self.spaces[packet.header.space()].dedup.insert(n);
                if number.is_some_and(is_duplicate) {
                    debug!("discarding possible duplicate packet");
                    self.qlog_packet_dropped(now, info.with_number(number), DropReason::Duplicate);
                    return;
                } else {
                    if let Header::Initial(InitialHeader { ref token, .. }) = packet.header
                        && let State::Handshake(ref hs) = self.state
                        && self.side.is_server()
                        && token != &hs.expected_token
                    {
                        // Clients must send the same retry token in every Initial. Initial
                        // packets can be spoofed, so we discard rather than killing the
                        // connection.
                        warn!("discarding Initial with invalid retry token");
                        self.qlog_packet_dropped(
                            now,
                            info.with_number(number),
                            DropReason::Invalid,
                        );
                        return;
                    }

                    if packet.header.space() == SpaceId::Handshake && self.state.is_handshake() {
                        self.qlog_handshake_started(now);
                    }
                    // Only a packet that passed packet protection carries a number; Retry and
                    // Version Negotiation are unprotected and must not count as the peer's.
                    if !self.state.is_closed() && number.is_some() {
                        self.on_packet_authenticated(
                            now,
                            packet.header.space(),
                            ecn,
                            number,
                            packet.header.is_1rtt(),
                        );
                        if let Some(number) = number {
                            self.qlog_sink.emit_packet_received(
                                number,
                                info.length,
                                packet.header.space(),
                                !packet.header.is_1rtt(),
                                now,
                                self.trace_cid,
                            );
                        }
                    }

                    let spin = match packet.header {
                        Header::Short { spin, .. } => number.map(|n| (n, spin)),
                        _ => None,
                    };
                    let info = info.with_number(number);
                    let result =
                        self.process_decrypted_packet_with_info(now, remote, local, packet, info);
                    if result.is_ok()
                        && !self.state.is_closed()
                        && let Some((number, spin)) = spin
                    {
                        self.receive_spin(remote, local, number, spin);
                    }
                    if matches!(result, Err(ConnectionError::TransportError(_))) {
                        self.qlog_packet_dropped(now, info, DropReason::Invalid);
                    }
                    result
                }
            }
        };

        // State transitions for error cases
        if let Err(conn_err) = result {
            // A late reset can end draining, but the first close already owns
            // the application notification, even when it has been polled.
            if !was_closed {
                self.error = Some(conn_err.clone());
            }
            self.state = match conn_err {
                ConnectionError::ApplicationClosed(reason) => State::closed(reason),
                ConnectionError::ConnectionClosed(reason) => State::closed(reason),
                // Version Negotiation abandons this Initial attempt. There is no
                // authenticated connection to drain, and its route must be free
                // before the client retries on the same zero-CID socket.
                ConnectionError::Reset
                | ConnectionError::VersionMismatch { .. }
                | ConnectionError::TransportError(TransportError {
                    code: TransportErrorCode::AEAD_LIMIT_REACHED,
                    ..
                }) => State::Drained,
                #[expect(
                    clippy::unreachable,
                    reason = "`conn_err` was produced by processing one received packet, which only yields peer-driven errors (transport error, close frames, version mismatch, reset)"
                )]
                ConnectionError::TimedOut => {
                    unreachable!("timeouts aren't generated by packet processing");
                }
                ConnectionError::TransportError(err) => {
                    debug!("closing connection due to transport error: {}", err);
                    State::closed(err)
                }
                #[expect(
                    clippy::unreachable,
                    reason = "`conn_err` was produced by processing one received packet, which only yields peer-driven errors (transport error, close frames, version mismatch, reset)"
                )]
                ConnectionError::LocallyClosed => {
                    unreachable!("LocallyClosed isn't generated by packet processing");
                }
                #[expect(
                    clippy::unreachable,
                    reason = "`conn_err` was produced by processing one received packet, which only yields peer-driven errors (transport error, close frames, version mismatch, reset)"
                )]
                ConnectionError::CidsExhausted | ConnectionError::EndpointInUse => {
                    unreachable!("endpoint refusals aren't generated by packet processing");
                }
            };
        }

        // A refused zero-CID client attempt cannot share its route with a retry.
        // RFC 9000 §10.2 permits leaving draining early. No close response is
        // required after the peer's close, and a zero-CID endpoint cannot send
        // a stateless reset for a late packet. Release only this failed attempt;
        // established connections and locally initiated closing keep their timers.
        if was_handshaking
            && self.side.is_client()
            && self.local_cid_state.cid_len() == 0
            && matches!(self.state, State::Draining)
        {
            self.state = State::Drained;
        }

        if !was_closed && self.state.is_closed() {
            self.close_common();
            if !self.state.is_drained() {
                self.set_close_timer(now);
            }
        }
        if !was_drained && self.state.is_drained() {
            self.endpoint_events.push_back(EndpointEventInner::Drained);
            // Close timer may have been started previously, e.g. if we sent a close and got a
            // stateless reset in response
            self.timers.stop(Timer::Close);
        }

        // Answer with CONNECTION_CLOSE if this packet has earned one. A close already waiting
        // to be sent stays waiting, and only packets on this connection's own path count
        // towards the next one.
        if let State::Closed(_) = self.state
            && remote == self.path.remote
            && !self.close
            && self.close_responses.arrived()
        {
            self.close = true;
        }
    }

    pub(super) fn process_decrypted_packet(
        &mut self,
        now: Instant,
        remote: SocketAddr,
        local: Option<SocketAddr>,
        number: Option<u64>,
        packet: Packet,
    ) -> Result<(), ConnectionError> {
        // The accepting endpoint has already decrypted the first Initial; its ciphertext
        // length is unavailable here, so omit it rather than report a plaintext length.
        let info = DropInfo::decrypted(&packet, number);
        self.process_decrypted_packet_with_info(now, remote, local, packet, info)
            .inspect_err(|error| {
                if matches!(error, ConnectionError::TransportError(_)) {
                    self.qlog_packet_dropped(now, info, DropReason::Invalid);
                }
            })
    }

    #[expect(
        clippy::unwrap_used,
        reason = "this branch is inside `if self.side.is_client()`, and the rustls client session always reports whether early data was accepted; 0-RTT long headers carry a packet number, so `decrypt_packet` yields `Some`"
    )]
    fn process_decrypted_packet_with_info(
        &mut self,
        now: Instant,
        remote: SocketAddr,
        local: Option<SocketAddr>,
        packet: Packet,
        info: DropInfo,
    ) -> Result<(), ConnectionError> {
        let number = info.number;
        let state = match self.state {
            State::Established => {
                match packet.header.space() {
                    #[expect(
                        clippy::unwrap_used,
                        reason = "0-RTT and 1-RTT headers always carry a packet number and `decrypt_packet` returns it for exactly those"
                    )]
                    SpaceId::Data => self.process_payload(
                        now,
                        remote,
                        local,
                        number.unwrap(),
                        packet,
                        info.length,
                    )?,
                    _ if packet.header.has_frames() => self.process_early_payload(now, packet)?,
                    _ => {
                        trace!("discarding unexpected pre-handshake packet");
                        self.qlog_packet_dropped(now, info, DropReason::Rejected);
                    }
                }
                return Ok(());
            }
            State::Closed(_) => {
                for result in frame::Iter::new(packet.payload.freeze())? {
                    let frame = match result {
                        Ok(frame) => frame,
                        Err(err) => {
                            debug!("frame decoding error: {err:?}");
                            continue;
                        }
                    };

                    if matches!(frame, Frame::Padding) {
                        continue;
                    };

                    self.stats.frame_rx.record(&frame);

                    if let Frame::Close(_) = frame {
                        trace!("draining");
                        self.state = State::Draining;
                        break;
                    }
                }
                return Ok(());
            }
            State::Draining | State::Drained => {
                self.qlog_packet_dropped(now, info, DropReason::Rejected);
                return Ok(());
            }
            State::Handshake(ref mut state) => state,
        };

        match packet.header {
            Header::Retry {
                src_cid: rem_cid, ..
            } => {
                // Anyone can spoof an unprotected Retry, so a server drops one rather than
                // letting it end the connection.
                if self.side.is_server() {
                    trace!("discarding Retry sent to a server");
                    self.qlog_packet_dropped(now, info, DropReason::Rejected);
                    return Ok(());
                }

                if self.total_authed_packets > 0
                            || self.retry_src_cid.is_some()
                            || packet.payload.len() <= 16 // token + 16 byte tag
                            || rem_cid == self.initial_dst_cid
                            || !self.crypto.is_valid_retry(
                                &self.rem_cids.active(),
                                &packet.header_data,
                                &packet.payload,
                            )
                {
                    trace!("discarding invalid Retry");
                    self.qlog_packet_dropped(now, info, DropReason::Invalid);
                    // - After the client has received and processed an Initial or Retry
                    //   packet from the server, it MUST discard any subsequent Retry
                    //   packets that it receives.
                    // - A client MUST discard a Retry packet with a zero-length Retry Token
                    //   field.
                    // - A client MUST discard a Retry packet whose Source Connection ID is
                    //   the Destination Connection ID of its first Initial.
                    // - Clients MUST discard Retry packets that have a Retry Integrity Tag
                    //   that cannot be validated
                    return Ok(());
                }

                trace!("retrying with CID {}", rem_cid);
                #[expect(
                    clippy::unwrap_used,
                    reason = "a second Retry is discarded above (`retry_src_cid` is set), so `client_hello` has not been taken yet"
                )]
                let client_hello = state.client_hello.take().unwrap();
                // Retry integrity is checked here; unauthenticated packets never reset timers.
                self.on_packet_authenticated(now, SpaceId::Initial, None, None, false);
                self.retry_src_cid = Some(rem_cid);
                // A Retry that validates is a packet processed successfully (RFC 9000 §10.1).
                self.reset_idle_timeout(now, SpaceId::Initial);
                self.reset_keep_alive(now);
                let old_remote_cid = self.rem_cids.active();
                self.rem_cids.update_initial_cid(rem_cid);
                self.qlog_remote_cid_updated(now, old_remote_cid);
                self.rem_handshake_cid = rem_cid;

                let space = &mut self.spaces[SpaceId::Initial];
                if let Some(info) = space.take(0) {
                    self.on_packet_acked(now, info);
                };

                self.discard_space(now, SpaceId::Initial); // Make sure we clean up after any retransmitted Initials
                self.initial_keys_cid = rem_cid;
                self.spaces[SpaceId::Initial] = PacketSpace {
                    crypto: Some(self.crypto.initial_keys(
                        self.version(),
                        &rem_cid,
                        self.side.side(),
                    )?),
                    next_packet_number: self.spaces[SpaceId::Initial].next_packet_number,
                    crypto_offset: client_hello.len() as u64,
                    ..PacketSpace::new(now)
                };
                self.qlog_key_change(now, SpaceId::Initial, false, Some(KeyChangeTrigger::Tls));
                self.spaces[SpaceId::Initial]
                    .pending
                    .crypto
                    .push_back(frame::Crypto {
                        offset: 0,
                        data: client_hello,
                    });

                // Retransmit all 0-RTT data
                let zero_rtt = self.spaces[SpaceId::Data].take_sent_packets();
                for info in zero_rtt.into_values() {
                    self.remove_in_flight(&info);
                    self.spaces[SpaceId::Data].pending |= info.retransmits;
                }
                self.streams.retransmit_all_for_0rtt();

                let token_len = packet.payload.len() - 16;
                #[expect(
                    clippy::unreachable,
                    reason = "servers returned `PROTOCOL_VIOLATION` for a Retry at the top of this arm"
                )]
                let ConnectionSide::Client { ref mut token, .. } = self.side else {
                    unreachable!("we already short-circuited if we're server");
                };
                *token = bounded_token(&packet.payload[..token_len]).ok_or_else(|| {
                    TransportError::PROTOCOL_VIOLATION("Retry token exceeds retention limit")
                })?;
                self.state = State::Handshake(state::Handshake {
                    expected_token: Bytes::new(),
                    rem_cid_set: false,
                    client_hello: None,
                });
                Ok(())
            }
            Header::Long {
                ty: LongType::Handshake,
                src_cid: rem_cid,
                ..
            } => {
                if rem_cid != self.rem_handshake_cid {
                    debug!(
                        "discarding packet with mismatched remote CID: {} != {}",
                        self.rem_handshake_cid, rem_cid
                    );
                    self.qlog_packet_dropped(now, info, DropReason::Invalid);
                    return Ok(());
                }
                self.on_path_validated();

                self.process_early_payload(now, packet)?;
                if self.state.is_closed() {
                    return Ok(());
                }

                self.finish_handshake(now)?;
                Ok(())
            }
            Header::Initial(InitialHeader {
                src_cid: rem_cid, ..
            }) => {
                if !state.rem_cid_set {
                    trace!("switching remote CID to {}", rem_cid);
                    let mut state = state.clone();
                    let old_remote_cid = self.rem_cids.active();
                    self.rem_cids.update_initial_cid(rem_cid);
                    self.qlog_remote_cid_updated(now, old_remote_cid);
                    self.rem_handshake_cid = rem_cid;
                    self.orig_rem_cid = rem_cid;
                    state.rem_cid_set = true;
                    self.state = State::Handshake(state);
                } else if rem_cid != self.rem_handshake_cid {
                    debug!(
                        "discarding packet with mismatched remote CID: {} != {}",
                        self.rem_handshake_cid, rem_cid
                    );
                    self.qlog_packet_dropped(now, info, DropReason::Invalid);
                    return Ok(());
                }

                let starting_space = self.highest_space;
                self.process_early_payload(now, packet)?;

                if self.side.is_server()
                    && starting_space == SpaceId::Initial
                    && self.highest_space != SpaceId::Initial
                {
                    let params = self.crypto.transport_parameters()?.ok_or_else(|| {
                        TransportError::new(
                            TransportErrorCode::crypto(0x6d),
                            "transport parameters missing",
                        )
                    })?;
                    self.handle_peer_params(now, params)?;
                    self.issue_first_cids(now);
                    self.init_0rtt(now);
                }
                Ok(())
            }
            Header::Long {
                ty: LongType::ZeroRtt,
                ..
            } => {
                self.process_payload(now, remote, local, number.unwrap(), packet, info.length)?;
                Ok(())
            }
            Header::VersionNegotiate { .. } => {
                // An attempt that already reacted to one ignores any other (RFC 9368 §4).
                let reacted = matches!(
                    self.side,
                    ConnectionSide::Client {
                        negotiation_offer: Some(_),
                        ..
                    }
                );
                // RFC 9000 §6.2: discarded once any other packet was processed, a Retry included.
                if self.total_authed_packets > 0 || self.retry_src_cid.is_some() || reacted {
                    self.qlog_packet_dropped(now, info, DropReason::Rejected);
                    return Ok(());
                }
                let offered: Vec<Version> = packet
                    .payload
                    .as_chunks::<4>()
                    .0
                    .iter()
                    .map(|bytes| Version::from_be_bytes(*bytes))
                    .collect();
                // One that lists the version we sent is forged or stale (RFC 9368 §2.1).
                if offered.contains(&self.original_version()) {
                    self.qlog_packet_dropped(now, info, DropReason::Invalid);
                    return Ok(());
                }
                self.qlog_version_negotiated(now, &packet.payload);
                debug!("remote doesn't support our version");
                Err(ConnectionError::VersionMismatch { offered })
            }
            #[expect(
                clippy::unreachable,
                reason = "`handle_packet` drops short-header packets while handshaking before dispatching here"
            )]
            Header::Short { .. } => unreachable!(
                "short packets received during handshake are discarded in handle_packet"
            ),
        }
    }

    /// Process an Initial or Handshake packet payload
    fn process_early_payload(
        &mut self,
        now: Instant,
        packet: Packet,
    ) -> Result<(), TransportError> {
        debug_assert_ne!(packet.header.space(), SpaceId::Data);
        let allocated = packet.allocated;
        let mut ack_eliciting = false;
        for result in frame::Iter::new(packet.payload.freeze())? {
            let frame = result?;
            let span = match frame {
                Frame::Padding => continue,
                _ => Some(trace_span!("frame", ty = %frame.ty())),
            };

            self.stats.frame_rx.record(&frame);

            let _guard = span.as_ref().map(|x| x.enter());
            ack_eliciting |= frame.is_ack_eliciting();

            // Process frames
            match frame {
                Frame::Padding | Frame::Ping => {}
                Frame::Crypto(frame) => {
                    self.read_crypto(packet.header.space(), &frame, allocated)?;
                }
                Frame::Ack(ack) => {
                    self.on_ack_received(now, packet.header.space(), &ack)?;
                }
                // Per RFC 9000 §12.4 Table 3, only a CONNECTION_CLOSE frame of type 0x1c may
                // appear in Initial or Handshake packets. An application close (0x1d) falls
                // through to the catch-all arm below.
                Frame::Close(reason @ Close::Connection(_)) => {
                    self.error = Some(reason.into());
                    self.state = State::Draining;
                    return Ok(());
                }
                _ => {
                    let mut err =
                        TransportError::PROTOCOL_VIOLATION("illegal frame type in handshake");
                    err.frame = Some(frame.ty());
                    return Err(err);
                }
            }
        }

        if ack_eliciting {
            // In the initial and handshake spaces, ACKs must be sent immediately
            self.spaces[packet.header.space()]
                .pending_acks
                .set_immediate_ack_required();
        }

        self.write_crypto(now);
        Ok(())
    }

    fn decrypt_packet(
        &mut self,
        now: Instant,
        packet: &mut Packet,
    ) -> Result<Option<u64>, Option<TransportError>> {
        let result = packet_crypto::decrypt_packet_body(
            packet,
            &self.spaces,
            self.zero_rtt_crypto.as_ref(),
            self.original_initial_keys(),
            self.key_phase,
            self.prev_crypto.as_ref(),
            self.next_crypto.as_ref(),
        )?;

        let Some(result) = result else {
            return Ok(None);
        };

        if result.outgoing_key_update_acked
            && let Some(prev) = self.prev_crypto.as_mut()
        {
            prev.end_packet = Some((result.number, now));
            self.set_key_discard_timer(now, packet.header.space());
        }

        if result.incoming_key_update {
            trace!("key update authenticated");
            self.update_keys(now, Some((result.number, now)), true)
                .map_err(Some)?;
            self.set_key_discard_timer(now, packet.header.space());
        }

        Ok(Some(result.number))
    }

    /// The versions a received long header may carry: the connection's, and the client's
    /// original one while the two differ (RFC 9369 §4.1).
    fn decodable_versions(&self) -> [Version; 2] {
        [self.version(), self.original_version()]
    }

    /// The Initial keys of the original version, keyed by that version, while they are kept.
    fn original_initial_keys(&self) -> Option<(Version, &crate::proto::crypto::Keys)> {
        if self.wire_version == self.original_wire_version
            || self.spaces[SpaceId::Initial].crypto.is_none()
        {
            return None;
        }
        self.original_initial_crypto
            .as_ref()
            .map(|keys| (self.original_version(), keys))
    }

    /// A long header in a version other than the connection's: either the original version,
    /// which Initial and 0-RTT packets may still carry, or a compatible version the server is
    /// moving a client to (RFC 9368 §2.3, RFC 9369 §4.1). Returns whether to go on decoding.
    fn accept_other_version(
        &mut self,
        now: Instant,
        version: Version,
        partial_decode: &PartialDecode,
    ) -> bool {
        if version == self.original_version() {
            // Handshake and 1-RTT packets only exist in the negotiated version.
            return partial_decode.is_initial() || partial_decode.is_0rtt();
        }
        let ConnectionSide::Client { versions, .. } = &self.side else {
            return false;
        };
        if !self.state.is_handshake()
            || self.wire_version != self.original_wire_version
            || !versions.compatible().contains(&version)
            || !(partial_decode.is_initial() || partial_decode.space() == Some(SpaceId::Handshake))
        {
            return false;
        }
        // RFC 9368 §2.3: only move to the server's version once a packet in it authenticates.
        // A forged or corrupt long header must never flip the connection's version or keys, so
        // decrypt the trigger with candidate keys first and commit nothing until it succeeds.
        if !self.authenticates_version_switch(version, partial_decode) {
            return false;
        }
        match self.switch_version(now, version) {
            Ok(()) => true,
            Err(error) => {
                self.kill(now, error.into());
                false
            }
        }
    }

    /// Whether `partial_decode` decrypts under `version`'s Initial keys, derived without mutating
    /// any connection state. Only an Initial can authenticate before Handshake keys exist, which
    /// is the packet that legitimately drives a compatible-version switch (RFC 9369 §4.1).
    fn authenticates_version_switch(
        &self,
        version: Version,
        partial_decode: &PartialDecode,
    ) -> bool {
        let Ok(candidate) =
            self.crypto
                .initial_keys(version, &self.initial_keys_cid, self.side.side())
        else {
            return false;
        };
        let candidate = Some((version, &candidate));
        // A stateless reset never drives a version switch, so no reset tokens are offered.
        let Ok(result) = packet_crypto::unprotect_header(
            partial_decode.clone(),
            &self.spaces,
            self.zero_rtt_crypto.as_ref(),
            candidate,
            std::iter::empty(),
        ) else {
            return false;
        };
        let Some(mut packet) = result.packet else {
            return false;
        };
        matches!(
            packet_crypto::decrypt_packet_body(
                &mut packet,
                &self.spaces,
                self.zero_rtt_crypto.as_ref(),
                candidate,
                self.key_phase,
                self.prev_crypto.as_ref(),
                self.next_crypto.as_ref(),
            ),
            Ok(Some(_))
        )
    }

    /// Move a client to the version the server picked, before any Handshake key exists
    /// (RFC 9369 §4.1): keys from here on are labelled with it, and the Initial keys of the
    /// original version stay readable for what the server sent before it switched.
    fn switch_version(&mut self, now: Instant, version: Version) -> Result<(), TransportError> {
        self.crypto.switch_version(version).map_err(|_error| {
            TransportError::INTERNAL_ERROR("TLS session cannot change QUIC version")
        })?;

        let keys = self
            .crypto
            .initial_keys(version, &self.initial_keys_cid, self.side.side())?;
        self.original_initial_crypto = self.spaces[SpaceId::Initial].crypto.replace(keys);

        debug!(from = %self.wire_version, to = %version, "compatible version negotiation");
        // `version` is one of `versions.compatible()`, which this crate implements.
        self.wire_version = version.to_wire().ok_or_else(|| {
            TransportError::INTERNAL_ERROR("switched to an unimplemented QUIC version")
        })?;
        self.qlog_init_negotiation(now);

        Ok(())
    }

    /// Send an IMMEDIATE_ACK frame to the remote endpoint
    ///
    /// According to the spec, this will result in an error if the remote endpoint does not support
    /// the Acknowledgement Frequency extension
    pub(crate) fn immediate_ack(&mut self) {
        self.spaces[self.highest_space].immediate_ack_pending = true;
    }

    /// Decodes a packet, returning its decrypted payload, so it can be inspected in tests
    #[cfg(test)]
    pub(crate) fn decode_packet(&self, event: &ConnectionEvent) -> Option<Vec<u8>> {
        let ConnectionEventInner::Datagram(DatagramConnectionEvent {
            first_decode,
            remaining,
            ..
        }) = &event.0
        else {
            return None;
        };

        if remaining.is_some() {
            panic!("Packets should never be coalesced in tests");
        }

        let decrypted_header = packet_crypto::unprotect_header(
            first_decode.clone(),
            &self.spaces,
            self.zero_rtt_crypto.as_ref(),
            self.original_initial_keys(),
            self.used_reset_tokens(self.path.remote),
        )
        .ok()?;

        let mut packet = decrypted_header.packet?;
        packet_crypto::decrypt_packet_body(
            &mut packet,
            &self.spaces,
            self.zero_rtt_crypto.as_ref(),
            self.original_initial_keys(),
            self.key_phase,
            self.prev_crypto.as_ref(),
            self.next_crypto.as_ref(),
        )
        .ok()?;

        Some(packet.payload.to_vec())
    }
}

impl Connection {
    /// Establish the connection once TLS completed, by a peer packet or by asynchronous
    /// callback work that finished on its own.
    pub(super) fn finish_handshake(&mut self, now: Instant) -> Result<(), TransportError> {
        if !self.state.is_handshake() {
            return Ok(());
        }
        if self.crypto.is_handshaking() {
            trace!("handshake ongoing");
            return Ok(());
        }

        if self.side.is_client() {
            // Client-only because server params were set from the client's Initial
            let params = self.crypto.transport_parameters()?.ok_or_else(|| {
                TransportError::new(
                    TransportErrorCode::crypto(0x6d),
                    "transport parameters missing",
                )
            })?;

            if self.has_0rtt() {
                let accepted = self.crypto.early_data_accepted().ok_or_else(|| {
                    TransportError::INTERNAL_ERROR("TLS completed without early-data disposition")
                })?;
                if !accepted {
                    debug_assert!(self.side.is_client());
                    debug!("0-RTT rejected");
                    self.early_data = Some(false);
                    self.streams.zero_rtt_rejected([
                        self.config.max_concurrent_bidi_streams,
                        self.config.max_concurrent_uni_streams,
                    ]);

                    // Discard already-queued frames
                    self.spaces[SpaceId::Data].pending = Retransmits::default();

                    // Discard 0-RTT packets
                    let sent_packets = self.spaces[SpaceId::Data].take_sent_packets();
                    for packet in sent_packets.into_values() {
                        self.remove_in_flight(&packet);
                    }
                } else {
                    self.early_data = Some(true);
                    params.validate_resumption_from(&self.peer_params)?;
                }
            }
            if let Some(token) = params.stateless_reset_token {
                self.rem_cids.set_initial_reset_token(token);
                self.set_reset_token(self.path.remote, token);
                // Every address this identifier has already been sent to needs a route
                // now, not just the one in use.
                let seq = self.rem_cids.active_seq();
                self.announce_reset_routes(seq);
            }
            self.handle_peer_params(now, params)?;
            self.issue_first_cids(now);
        } else {
            // Server-only
            self.queue_handshake_done();
            self.discard_space(now, SpaceId::Handshake);
            self.events.push_back(Event::HandshakeConfirmed);
            trace!("handshake confirmed");
        }

        self.timers.stop(Timer::Handshake);
        self.events.push_back(Event::Connected);
        self.state = State::Established;
        trace!("established");
        Ok(())
    }
}
