//! The frames of an established packet: what each one means for this connection, and the
//! identifiers a NEW_CONNECTION_ID brings with it.

use std::net::SocketAddr;

use rama_core::telemetry::tracing::{debug, trace, trace_span};

use crate::proto::{
    Instant, StoredToken,
    cid_queue::{InsertError, Retired},
    connection::{
        Connection, ConnectionSide, Event, State,
        migration::{DeferredMigration, PrevCid},
        preferred::PreferredAddressState,
        timer::Timer,
    },
    shared::EndpointEventInner,
    token::bounded_token,
    transport_parameters,
};
use rama_quic_proto::{
    MAX_STREAM_COUNT, TransportError,
    frame::{self, Frame, NewToken},
    packet::{Packet, SpaceId},
};

impl Connection {
    /// Apply one NEW_CONNECTION_ID frame (RFC 9000 §5.1.1, §5.1.2, §9.5): give up the identifiers
    /// the frame retires, record the new one, and retire with the peer every sequence number that
    /// leaves this connection's hands.
    pub(super) fn handle_new_cid(
        &mut self,
        now: Instant,
        frame: frame::NewConnectionId,
    ) -> Result<(), TransportError> {
        let old_remote_cid = self.rem_cids.active();
        trace!(
            sequence = frame.sequence,
            id = %frame.id,
            retire_prior_to = frame.retire_prior_to,
        );
        if self.rem_cids.active().is_empty() {
            return Err(TransportError::PROTOCOL_VIOLATION(
                "NEW_CONNECTION_ID when CIDs aren't in use",
            ));
        }
        // RFC 9000 §19.15. The frame decoder refuses such a frame, so this covers
        // the ones built inside this crate.
        if frame.retire_prior_to > frame.sequence {
            return Err(TransportError::FRAME_ENCODING_ERROR(
                "NEW_CONNECTION_ID retiring unissued CIDs",
            ));
        }

        // Validate against every retained role before retirement can erase the
        // conflicting association or detach a path from its identifier.
        self.rem_cids
            .validate_identity(&frame)
            .map_err(|_identity_error| {
                TransportError::PROTOCOL_VIOLATION("conflicting NEW_CONNECTION_ID identity")
            })?;

        // Identifiers kept aside for a path (RFC 9000 §9.5) that the peer retires
        // now are given up first: a previous path then has no identifier of its own,
        // and a candidate path cannot go on with one it may not send.
        let aside = self.rem_cids.retire_aside(frame.retire_prior_to);
        for seq in aside.iter() {
            self.retire_rem_cid(seq)?;
        }
        // The numbers this frame retires that never reached us are retired too; the
        // peer holds them until RETIRE_CONNECTION_ID names them.
        self.retire_rem_cids(&Retired {
            previous: 0..0,
            skipped: aside.skipped,
        })?;
        for seq in &aside.bound {
            self.drop_path_cid(*seq);
        }
        let (held_retired, reserved_retired) = (aside.held, aside.reserved);
        if held_retired.is_some()
            && let Some(prev) = self.prev_path.as_mut()
            && prev.cid == PrevCid::Held
        {
            prev.cid = PrevCid::Gone;
        }
        if reserved_retired.is_some() {
            self.restart_candidate(now);
        }
        match self.rem_cids.insert(frame) {
            Ok(inserted) => {
                // Unused identifiers this frame retired are ours no longer; the peer
                // holds them until RETIRE_CONNECTION_ID names them.
                for seq in &inserted.dropped {
                    self.retire_rem_cid(*seq)?;
                }
                if let Some((retired, reset_token)) = inserted.switched {
                    self.retire_rem_cids(&retired)?;
                    self.set_reset_token(self.path.remote, reset_token);
                    self.qlog_remote_cid_updated(now, old_remote_cid);
                    self.reset_current_spin();
                    self.spin_cid_changed(
                        self.path.remote,
                        self.path.local,
                        self.rem_cids.active(),
                    );
                }
            }
            Err(InsertError::InconsistentIdentity) => {
                return Err(TransportError::PROTOCOL_VIOLATION(
                    "conflicting NEW_CONNECTION_ID identity",
                ));
            }
            Err(InsertError::ExceedsLimit) => {
                return Err(TransportError::CONNECTION_ID_LIMIT_ERROR(""));
            }
            Err(InsertError::Retired) => {
                trace!("discarding already-retired");
                // RETIRE_CONNECTION_ID might not have been previously sent if e.g. a
                // range of connection IDs larger than the active connection ID limit
                // was retired all at once via retire_prior_to. The bounded queue
                // keeps a peer that repeats retired identifiers from growing it.
                self.spaces[SpaceId::Data].pending.retire_cids_with_limit(
                    frame.sequence..frame.sequence + 1,
                    self.rem_cids.limit(),
                )?;
                return Ok(());
            }
        };
        // A repeated initial ID can introduce its first reset token. Publish
        // routes for addresses already used with it before sending again.
        self.announce_reset_routes(frame.sequence);

        // A peer move that waited for an unused connection ID (RFC 9000 §9.5) is
        // followed now, unless the path changed meanwhile or no ID is unused yet.
        if let Some(deferred) = self.deferred_migration.take()
            && deferred.generation == self.path_counter
        {
            trace!(
                remote = %deferred.remote,
                asked_by = deferred.number,
                "following the deferred peer move"
            );
            if !self.follow_peer_move(
                now,
                deferred.remote,
                deferred.local,
                deferred.received_dcid,
                false,
            )? {
                self.deferred_migration = Some(deferred);
            }
        }

        Ok(())
    }

    pub(super) fn process_payload(
        &mut self,
        now: Instant,
        remote: SocketAddr,
        local: Option<SocketAddr>,
        number: u64,
        packet: Packet,
        received_bytes: Option<usize>,
    ) -> Result<(), TransportError> {
        let received_dcid = packet.header.dst_cid();
        let allocated = packet.allocated;
        let payload = packet.payload.freeze();
        let mut is_probing_packet = true;
        let mut close = None;
        let mut ack_eliciting = false;
        for result in frame::Iter::new(payload)? {
            let frame = result?;
            let span = match frame {
                Frame::Padding => continue,
                _ => Some(trace_span!("frame", ty = %frame.ty())),
            };

            self.stats.frame_rx.record(&frame);
            // Crypto, Stream and Datagram frames are special cased in order no pollute
            // the log with payload data
            match &frame {
                Frame::Crypto(f) => {
                    trace!(offset = f.offset, len = f.data.len(), "got crypto frame");
                }
                Frame::Stream(f) => {
                    trace!(id = %f.id, offset = f.offset, len = f.data.len(), fin = f.fin, "got stream frame");
                }
                Frame::Datagram(f) => {
                    trace!(len = f.datagram.data.len(), "got datagram frame");
                }
                f => {
                    trace!("got frame {:?}", f);
                }
            }

            let _guard = span.as_ref().map(|x| x.enter());
            // Reject frames forbidden at this encryption level before any frame-specific
            // dispatch can acknowledge packets, retire CIDs, store tokens or validate paths.
            if packet.header.is_0rtt() && !frame.is_allowed_in_0rtt() {
                let mut err = TransportError::PROTOCOL_VIOLATION("illegal frame type in 0-RTT");
                err.frame = Some(frame.ty());
                return Err(err);
            }
            ack_eliciting |= frame.is_ack_eliciting();

            // Check whether this could be a probing packet
            match frame {
                Frame::Padding
                | Frame::PathChallenge(_)
                | Frame::PathResponse(_)
                | Frame::NewConnectionId(_) => {}
                _ => {
                    is_probing_packet = false;
                }
            }
            match frame {
                Frame::Crypto(frame) => {
                    self.read_crypto(SpaceId::Data, &frame, allocated)?;
                }
                Frame::Stream(frame) => {
                    if self.streams.received(frame, allocated)?.should_transmit() {
                        self.spaces[SpaceId::Data].pending.max_data = true;
                    }
                }
                Frame::Ack(ack) => {
                    self.on_ack_received(now, SpaceId::Data, &ack)?;
                }
                Frame::Padding | Frame::Ping => {}
                Frame::Close(reason) => {
                    close = Some(reason);
                }
                Frame::PathChallenge(token) => {
                    self.path_responses.push(
                        number,
                        token,
                        remote,
                        local,
                        received_bytes.unwrap_or(0),
                    );
                    if remote == self.path.remote && self.same_local(local) {
                        // PATH_CHALLENGE on active path, possible off-path packet forwarding
                        // attack. Send a non-probing packet to recover the active path.
                        match self.peer_supports_ack_frequency() {
                            true => self.immediate_ack(),
                            false => self.ping(),
                        }
                    }
                }
                Frame::PathResponse(token) => {
                    // A response validates the path its challenge was sent on, whichever path it
                    // arrives on (RFC 9000 §8.2.3); data that matches nothing validates nothing
                    // and leaves an attempt in progress alone.
                    if self.candidate.as_ref().is_some_and(|c| c.matches(token)) {
                        self.take_preferred_address(now);
                    } else if self.on_server_preferred_response(now, token) {
                        // Promotion waits for a newest non-probing packet too.
                    } else if !self.on_path_response(now, token) {
                        debug!(token, "ignoring unmatched PATH_RESPONSE");
                    }
                }
                Frame::MaxData(bytes) => {
                    self.streams.received_max_data(bytes);
                }
                Frame::MaxStreamData { id, offset } => {
                    self.streams.received_max_stream_data(id, offset)?;
                }
                Frame::MaxStreams { dir, count } => {
                    self.streams.received_max_streams(dir, count)?;
                }
                Frame::ResetStream(frame) => {
                    if self.streams.received_reset(frame)?.should_transmit() {
                        self.spaces[SpaceId::Data].pending.max_data = true;
                    }
                }
                Frame::DataBlocked { offset } => {
                    debug!(offset, "peer claims to be blocked at connection level");
                }
                Frame::StreamDataBlocked { id, offset } => {
                    self.streams.received_stream_data_blocked(id)?;
                    debug!(
                        stream = %id,
                        offset, "peer claims to be blocked at stream level"
                    );
                }
                Frame::StreamsBlocked { dir, limit } => {
                    if limit > MAX_STREAM_COUNT {
                        return Err(TransportError::FRAME_ENCODING_ERROR(
                            "unrepresentable stream limit",
                        ));
                    }
                    self.streams.received_streams_blocked(
                        dir,
                        limit,
                        &mut self.spaces[SpaceId::Data].pending,
                    );
                    debug!(
                        "peer claims to be blocked opening more than {} {} streams",
                        limit, dir
                    );
                }
                Frame::StopSending(frame::StopSending { id, error_code }) => {
                    self.streams.received_stop_sending(id, error_code)?;
                }
                Frame::RetireConnectionId { sequence } => {
                    // A repeat retires nothing, so it tells the endpoint nothing either.
                    if let Some(allow_more_cids) = self.local_cid_state.on_cid_retirement(
                        sequence,
                        transport_parameters::issue_cids_limit(&self.peer_params),
                        received_dcid,
                    )? {
                        self.endpoint_events
                            .push_back(EndpointEventInner::RetireConnectionId(
                                now,
                                sequence,
                                allow_more_cids,
                            ));
                    }
                }
                Frame::NewConnectionId(frame) => self.handle_new_cid(now, frame)?,
                Frame::NewToken(NewToken { token }) => {
                    let ConnectionSide::Client {
                        token_store,
                        server_name,
                        time_source,
                        ..
                    } = &self.side
                    else {
                        return Err(TransportError::PROTOCOL_VIOLATION("client sent NEW_TOKEN"));
                    };
                    if token.is_empty() {
                        return Err(TransportError::FRAME_ENCODING_ERROR("empty token"));
                    }
                    let Some(token) = bounded_token(&token) else {
                        continue;
                    };
                    trace!("got new token");
                    let stored = StoredToken::new(token, time_source.now())
                        .with_peer_greasing_quic_bit(self.peer_params.grease_quic_bit);
                    token_store.insert(server_name, self.version(), stored);
                }
                Frame::Datagram(datagram) => {
                    if self.datagrams.received(datagram, allocated, &self.config)? {
                        self.events.push_back(Event::DatagramReceived);
                    }
                }
                Frame::AckFrequency(ack_frequency) => {
                    // This frame can only be sent in the Data space
                    let space = &mut self.spaces[SpaceId::Data];

                    if !self
                        .ack_frequency
                        .ack_frequency_received(&ack_frequency, &mut space.pending_acks)?
                    {
                        // The AckFrequency frame is stale (we have already received a more recent one)
                        continue;
                    }

                    // Our `max_ack_delay` has been updated, so we may need to adjust its associated
                    // timeout
                    if let Some(timeout) = space
                        .pending_acks
                        .max_ack_delay_timeout(self.ack_frequency.max_ack_delay)
                    {
                        self.timers.set(Timer::MaxAckDelay, timeout);
                    }
                }
                Frame::ImmediateAck => {
                    // This frame can only be sent in the Data space
                    self.spaces[SpaceId::Data]
                        .pending_acks
                        .set_immediate_ack_required();
                }
                Frame::HandshakeDone => {
                    if self.side.is_server() {
                        return Err(TransportError::PROTOCOL_VIOLATION(
                            "client sent HANDSHAKE_DONE",
                        ));
                    }
                    let confirmed_before = self.handshake_confirmed();
                    if self.spaces[SpaceId::Handshake].crypto.is_some() {
                        self.discard_space(now, SpaceId::Handshake);
                    }
                    // Confirmation happens once; a repeated frame changes nothing to report.
                    if !confirmed_before {
                        self.events.push_back(Event::HandshakeConfirmed);
                    }
                    self.qlog_observe_state(now);
                    trace!("handshake confirmed");
                    // Migration, the preferred address included, waits for confirmation
                    // (RFC 9000 §9).
                    if self.preferred_state == PreferredAddressState::Armed {
                        self.begin_candidate();
                    }
                }
            }
        }

        // Switch away from the handshake CID only after every frame in the
        // packet is applied. A peer can send NEW_CONNECTION_ID in descending
        // order; switching per frame would retire lower IDs not processed yet,
        // leaving no spare to answer its first preferred-address probe.
        if self.side.is_server() && self.rem_cids.active_seq() == 0 {
            self.update_rem_cid(now);
        }

        let space = &mut self.spaces[SpaceId::Data];
        if space
            .pending_acks
            .packet_received(now, number, ack_eliciting, &space.dedup)
        {
            self.timers
                .set(Timer::MaxAckDelay, now + self.ack_frequency.max_ack_delay);
            self.next_bundled_ack_time = Some(now);
        }

        // Issue stream ID credit due to ACKs of outgoing finish/resets and incoming finish/resets
        // on stopped streams. Incoming finishes/resets on open streams are not handled here as they
        // are only freed, and hence only issue credit, once the application has been notified
        // during a read on the stream.
        let pending = &mut self.spaces[SpaceId::Data].pending;
        self.streams.queue_max_stream_id(pending);

        if let Some(reason) = close {
            self.error = Some(reason.into());
            self.state = State::Draining;
            self.close = true;
        }

        // A non-probing packet from a new path (the peer's address changed, or it reached a
        // different local socket, such as the server's preferred address) moves the connection.
        let preferred_candidate = self.observe_server_preferred(
            now,
            remote,
            local,
            number,
            received_dcid,
            received_bytes.unwrap_or(0),
            !is_probing_packet,
        )?;
        let local_changed = !self.same_local(local);
        let on_current_path = remote == self.path.remote && !local_changed;
        // Once promoted, keep using the preferred address even if a peer's
        // in-flight ACKs or data still arrive at the original (RFC 9000 §9.6.2).
        // Source-address changes continue through ordinary migration handling.
        let old_preferred_path = local_changed
            && remote == self.path.remote
            && matches!(&self.side, ConnectionSide::Server { server_config } if Self::is_preferred_local(server_config, self.path.local));
        if on_current_path
            && !is_probing_packet
            && number == self.spaces[SpaceId::Data].rx_packet
            && self.deferred_migration.take().is_some()
        {
            // The peer is (still or again) on the current path: a move waiting for an unused
            // connection ID is obsolete.
            trace!("deferred peer move superseded by traffic on the current path");
        }
        if !on_current_path
            && !preferred_candidate
            && !old_preferred_path
            && !is_probing_packet
            && number == self.spaces[SpaceId::Data].rx_packet
        {
            let migration_allowed = match &self.side {
                // The peer reaching another of our own addresses with its own address unchanged
                // is not the active migration `disable_active_migration` forbids (RFC 9000
                // §18.2); a change of its address is, unless it is on the address advertised as
                // preferred (RFC 9000 §9.6.3).
                ConnectionSide::Server { .. } => {
                    Some(remote == self.path.remote || self.may_follow_peer_move(local))
                }
                ConnectionSide::Client { .. } => None,
            };
            if migration_allowed == Some(false) {
                // A deferred move resumed earlier in this packet can leave it arriving off the
                // current path from an address the policy does not let the connection follow.
                trace!(%remote, ?local, "ignoring a peer move the migration policy forbids");
            } else if migration_allowed == Some(true) {
                // RFC 9000 §9.5: a connection ID is never reused towards more than one destination.
                // The one exception is a peer whose address changed without changing the connection
                // ID it sends to us while we keep our local address (a NAT rebinding): then we may
                // keep using the current connection ID. Otherwise the new path needs an unused one;
                // without it the move is deferred until the peer issues more and we keep sending on
                // the current path meanwhile.
                let nat_rebinding = remote != self.path.remote
                    && !local_changed
                    && self.path.received_dcid == Some(received_dcid);
                if !self.follow_peer_move(now, remote, local, received_dcid, nat_rebinding)? {
                    trace!(%remote, ?local, "peer moved without an unused connection ID: deferred");
                    self.deferred_migration = Some(DeferredMigration {
                        remote,
                        local,
                        received_dcid,
                        number,
                        generation: self.path_counter,
                    });
                    self.stats.path.deferred_migrations =
                        self.stats.path.deferred_migrations.saturating_add(1);
                }
            } else {
                // A client follows no peer address change; traffic from elsewhere than the
                // current path is only accepted while that address is being probed.
                trace!(%remote, "ignoring a client-side off-path packet");
            }
        } else if on_current_path {
            self.qlog_local_cid_updated(now, self.path.received_dcid, received_dcid);
            self.path.received_dcid = Some(received_dcid);
        }

        Ok(())
    }
}

#[cfg(all(
    test,
    any(
        feature = "boring",
        all(feature = "rustls", any(feature = "aws-lc", feature = "ring"))
    )
))]
mod tests {
    use super::*;
    use crate::proto::{TokenStore, tests::Pair};
    use parking_lot::Mutex;
    use rama_core::bytes::Bytes;
    use rama_quic_proto::{
        ConnectionId, Dir, RESET_TOKEN_SIZE, ResetToken, Side, StreamId, TransportErrorCode,
        VarInt, Version,
        coding::Codec,
        packet::{Header, LongType, PacketNumber},
    };
    use std::{
        net::{Ipv6Addr, SocketAddrV6},
        sync::Arc,
    };

    #[derive(Default)]
    struct ObservedTokens(Mutex<Vec<StoredToken>>);

    impl TokenStore for ObservedTokens {
        fn insert(&self, _: &str, _: Version, token: StoredToken) {
            self.0.lock().push(token);
        }

        fn take(&self, _: &str, _: Version) -> Option<StoredToken> {
            self.0.lock().pop()
        }
    }

    /// A received 1-RTT packet of `allocated` bytes: `frames`, then PADDING, in one allocation
    /// as the driver hands a datagram over. Returns the packet and its backing address range.
    fn padded_packet(
        dst_cid: rama_quic_proto::ConnectionId,
        frames: &[u8],
        allocated: usize,
    ) -> (Packet, std::ops::Range<usize>) {
        let mut payload = frames.to_vec();
        payload.resize(allocated, 0);
        let backing = rama_core::bytes::BytesMut::from(payload.as_slice());
        let start = backing.as_ptr() as usize;
        let packet = Packet {
            header: Header::Short {
                spin: false,
                key_phase: false,
                dst_cid,
                number: PacketNumber::U8(0),
            },
            header_data: Bytes::new(),
            payload: backing,
            allocated,
        };
        (packet, start..start + allocated)
    }

    /// A deferred move to the preferred address can be resumed by a NEW_CONNECTION_ID inside a
    /// packet that arrives on the old path; that packet then comes from an address the policy
    /// does not let the server follow, and the server keeps the path it moved to.
    #[test]
    fn a_resumed_deferred_move_leaves_a_forbidden_move_unfollowed() {
        let alt_v6 = SocketAddrV6::new(Ipv6Addr::LOCALHOST, 47_311, 0, 0);
        let alt = SocketAddr::V6(alt_v6);
        let mut config = crate::proto::tests::util::server_config();
        config.set_preferred_address_v6(alt_v6);
        config.set_migration(false);
        let mut pair = Pair::new(
            Arc::new(crate::proto::EndpointConfig::try_with_rand_key().expect("an endpoint key")),
            config,
        );
        pair.server.alt_addr = Some(alt);
        let (_, server) = pair.connect();
        let now = pair.time;
        // The address the handshake used, which the policy does not let the peer move to.
        let handshake_local = Some(pair.server.addr);
        let conn = pair.server_conn_mut(server);
        // Exhaust the identifiers already supplied by the handshake. A deferred
        // move waits for a genuinely new ID, not a conflicting rewrite of the
        // sequence immediately after the active one.
        while conn.update_rem_cid(now) {}

        let original = conn.path.remote;
        let moved = SocketAddr::V6(SocketAddrV6::new(Ipv6Addr::LOCALHOST, 47_312, 0, 0));
        let number = conn.spaces[SpaceId::Data].rx_packet;
        conn.deferred_migration = Some(DeferredMigration {
            remote: moved,
            local: Some(alt),
            received_dcid: conn.handshake_cid,
            number,
            generation: conn.path_counter,
        });
        let mut frames = Vec::new();
        // A new identifier: the unused one a deferred move waits for.
        frame::NewConnectionId {
            sequence: conn.rem_cids.active_seq() + 1,
            retire_prior_to: 0,
            id: rama_quic_proto::ConnectionId::new(&[9; 8]),
            reset_token: rama_quic_proto::ResetToken::from([9; rama_quic_proto::RESET_TOKEN_SIZE]),
        }
        .encode(&mut frames);
        frame::FrameType::PING.encode(&mut frames);
        let (packet, _) = padded_packet(conn.handshake_cid, &frames, frames.len());
        conn.process_payload(now, original, handshake_local, number, packet, None)
            .expect("the packet is processed");
        assert_eq!(
            conn.path.remote, moved,
            "the move the policy allows was followed"
        );
        assert!(!conn.is_closed());
    }

    #[test]
    fn stream_control_limits_are_checked_during_packet_dispatch() {
        for side in [Side::Client, Side::Server] {
            for stop in [false, true] {
                let mut pair = Pair::default();
                let (now, conn) = connected(&mut pair, side);
                let limit = conn.config.max_concurrent_bidi_streams.into_inner();
                let id = StreamId::new(!side, Dir::Bi, limit);
                let mut frames = Vec::new();
                if stop {
                    frame::StopSending {
                        id,
                        error_code: VarInt::from_u32(1),
                    }
                    .encode(&mut frames);
                } else {
                    frame::FrameType::STREAM_DATA_BLOCKED.encode(&mut frames);
                    id.encode(&mut frames);
                    VarInt::from_u32(0).encode(&mut frames);
                }
                let (packet, _) = padded_packet(conn.handshake_cid, &frames, frames.len());
                let number = conn.spaces[SpaceId::Data].rx_packet;
                let error = conn
                    .process_payload(now, conn.path.remote, conn.path.local, number, packet, None)
                    .unwrap_err();
                assert_eq!(error.code, TransportErrorCode::STREAM_LIMIT_ERROR);
            }
        }
    }

    #[test]
    fn cid_retirement_dispatch_rejects_own_destination_for_both_roles() {
        for side in [Side::Client, Side::Server] {
            let mut pair = Pair::default();
            let (client, server) = pair.connect();
            let now = pair.time;
            // The handshake identifier may already be retired. Use the destination
            // the peer actually selected, with its matching sequence number.
            let peer = match side {
                Side::Client => pair.server_conn_mut(server),
                Side::Server => pair.client_conn_mut(client),
            };
            let destination = peer.rem_cids.active();
            let sequence = peer.rem_cids.active_seq();
            let conn = match side {
                Side::Client => pair.client_conn_mut(client),
                Side::Server => pair.server_conn_mut(server),
            };
            let before = conn.endpoint_events.len();
            let mut frames = Vec::new();
            frame::FrameType::RETIRE_CONNECTION_ID.encode(&mut frames);
            VarInt::from_u64(sequence).unwrap().encode(&mut frames);
            let (packet, _) = padded_packet(destination, &frames, frames.len());
            let error = conn
                .process_payload(now, conn.path.remote, conn.path.local, 0, packet, None)
                .unwrap_err();
            assert_eq!(error.code, TransportErrorCode::PROTOCOL_VIOLATION);
            assert_eq!(conn.endpoint_events.len(), before);
        }
    }

    #[test]
    fn cid_identity_dispatch_rejects_conflicts_without_retirement_events() {
        for side in [Side::Client, Side::Server] {
            for change_token in [false, true] {
                let mut pair = Pair::default();
                let (now, conn) = connected(&mut pair, side);
                let sequence = conn.rem_cids.active_seq();
                let original = conn.rem_cids.active();
                let token = conn
                    .rem_cids
                    .active_reset_token()
                    .unwrap_or_else(|| ResetToken::from([77; RESET_TOKEN_SIZE]));
                let initial = frame::NewConnectionId {
                    sequence,
                    retire_prior_to: sequence,
                    id: original,
                    reset_token: token,
                };
                conn.handle_new_cid(now, initial).unwrap();
                let before = conn.endpoint_events.len();
                let mut conflict = initial;
                if change_token {
                    let mut bytes = [0; RESET_TOKEN_SIZE];
                    bytes.copy_from_slice(&token);
                    bytes[0] ^= 1;
                    conflict.reset_token = ResetToken::from(bytes);
                } else {
                    conflict.id = ConnectionId::new(&[44; 8]);
                    assert_ne!(conflict.id, original);
                }
                let mut frames = Vec::new();
                conflict.encode(&mut frames);
                assert_eq!(
                    receive(conn, now, &frames).unwrap_err().code,
                    TransportErrorCode::PROTOCOL_VIOLATION
                );
                assert_eq!(conn.rem_cids.active(), original);
                assert_eq!(conn.endpoint_events.len(), before);
            }
        }
    }

    #[test]
    fn cid_identity_dispatch_checks_held_ids_before_retiring_them() {
        for side in [Side::Client, Side::Server] {
            let mut pair = Pair::default();
            let (now, conn) = connected(&mut pair, side);
            conn.rem_cids.next_holding().unwrap();
            let held = conn.rem_cids.held().unwrap();
            let before = conn.endpoint_events.len();
            let sequence = conn.rem_cids.active_seq() + 1;
            let conflict = frame::NewConnectionId {
                sequence,
                retire_prior_to: sequence,
                id: held.id,
                reset_token: held
                    .reset_token
                    .unwrap_or_else(|| ResetToken::from([77; RESET_TOKEN_SIZE])),
            };
            let mut frames = Vec::new();
            conflict.encode(&mut frames);
            assert_eq!(
                receive(conn, now, &frames).unwrap_err().code,
                TransportErrorCode::PROTOCOL_VIOLATION
            );
            assert_eq!(conn.rem_cids.held().unwrap().id, held.id);
            assert_eq!(conn.endpoint_events.len(), before);
        }
    }

    /// A frame repeated many times in one packet changes state at most once, so it queues at
    /// most one event: a peer cannot grow the event queues by repeating itself.
    #[test]
    fn repeated_frames_queue_one_event() {
        const REPEATS: usize = 500;
        for side in [Side::Server, Side::Client] {
            // RETIRE_CONNECTION_ID for the same sequence.
            let mut pair = Pair::default();
            let (now, conn) = connected(&mut pair, side);
            let before = conn.endpoint_events.len();
            let mut frames = Vec::new();
            for _ in 0..REPEATS {
                frame::FrameType::RETIRE_CONNECTION_ID.encode(&mut frames);
                VarInt::from_u32(1).encode(&mut frames);
            }
            receive(conn, now, &frames).expect("the packet is processed");
            assert!(conn.endpoint_events.len() - before <= 1, "{side:?}");

            // Empty STREAM frames on a stream the peer opened.
            let mut pair = Pair::default();
            let (now, conn) = connected(&mut pair, side);
            let id = StreamId::new(!side, Dir::Uni, 0);
            let mut frames = Vec::new();
            frame::StreamMeta {
                id,
                offsets: 0..1,
                fin: false,
            }
            .encode(true, &mut frames);
            frames.push(5);
            for _ in 0..REPEATS {
                frame::StreamMeta {
                    id,
                    offsets: 1..1,
                    fin: false,
                }
                .encode(true, &mut frames);
            }
            receive(conn, now, &frames).expect("the packet is processed");
            let mut readable = 0;
            while let Some(event) = conn.streams.poll() {
                readable +=
                    usize::from(matches!(event, crate::proto::StreamEvent::Readable { .. }));
            }
            assert!(readable <= 1, "{side:?}: {readable} readable events");

            // MAX_STREAMS raising the unidirectional limit one at a time.
            let mut pair = Pair::default();
            let (now, conn) = connected(&mut pair, side);
            while conn.streams.poll().is_some() {}
            let mut frames = Vec::new();
            for count in 0..REPEATS as u32 {
                frame::FrameType::MAX_STREAMS_UNI.encode(&mut frames);
                VarInt::from_u32(1_000 + count).encode(&mut frames);
            }
            receive(conn, now, &frames).expect("the packet is processed");
            let mut available = 0;
            while let Some(event) = conn.streams.poll() {
                available +=
                    usize::from(matches!(event, crate::proto::StreamEvent::Available { .. }));
            }
            assert_eq!(available, 1, "{side:?}: {available} available events");
        }

        // HANDSHAKE_DONE, at a client whose handshake is confirmed already (only servers send it).
        let mut pair = Pair::default();
        let (now, conn) = connected(&mut pair, Side::Client);
        while conn.poll().is_some() {}
        receive(conn, now, &[0x1e_u8; REPEATS]).expect("the packet is processed");
        assert!(conn.events.is_empty(), "{:?}", conn.events.len());
    }

    fn connected(pair: &mut Pair, side: Side) -> (Instant, &mut Connection) {
        let (client, server) = pair.connect();
        let now = pair.time;
        match side {
            Side::Client => (now, pair.client_conn_mut(client)),
            Side::Server => (now, pair.server_conn_mut(server)),
        }
    }

    fn receive(conn: &mut Connection, now: Instant, frames: &[u8]) -> Result<(), TransportError> {
        let (packet, _) = padded_packet(conn.handshake_cid, frames, frames.len());
        conn.process_payload(now, conn.path.remote, conn.path.local, 0, packet, None)
    }

    #[test]
    fn small_received_datagrams_do_not_keep_their_packet_allocated() {
        const WIRE_LEN: usize = 1200;
        for server_receives in [true, false] {
            for (len, detached) in [(0, true), (1, true), (64, true), (1100, false)] {
                let mut pair = Pair::default();
                let (client, server) = pair.connect();
                let now = pair.time;
                let conn = if server_receives {
                    pair.server_conn_mut(server)
                } else {
                    pair.client_conn_mut(client)
                };
                let mut frames = Vec::new();
                frame::Datagram {
                    data: Bytes::from(vec![9; len]),
                }
                .encode(true, &mut frames);
                let (packet, backing) = padded_packet(conn.handshake_cid, &frames, WIRE_LEN);
                conn.process_payload(now, conn.path.remote, conn.path.local, 0, packet, None)
                    .unwrap();
                let data = conn.datagrams.recv().expect("the datagram is queued");
                assert_eq!(data.as_ref(), vec![9; len]);
                let at = data.as_ptr() as usize;
                assert_eq!(
                    !backing.contains(&at),
                    detached || len == 0,
                    "{len}-byte datagram, server receives: {server_receives}"
                );
            }
        }
    }

    #[test]
    fn small_received_stream_data_does_not_keep_its_packet_allocated() {
        const WIRE_LEN: usize = 1200;
        for server_receives in [true, false] {
            for (len, detached) in [(1, true), (64, true), (1100, false)] {
                let mut pair = Pair::default();
                let (client, server) = pair.connect();
                let now = pair.time;
                let (conn, initiator) = if server_receives {
                    (pair.server_conn_mut(server), rama_quic_proto::Side::Client)
                } else {
                    (pair.client_conn_mut(client), rama_quic_proto::Side::Server)
                };
                let id = rama_quic_proto::StreamId::new(initiator, Dir::Uni, 0);
                let mut frames = Vec::new();
                frame::StreamMeta {
                    id,
                    offsets: 0..len as u64,
                    fin: false,
                }
                .encode(true, &mut frames);
                frames.extend(std::iter::repeat_n(5, len));
                let (packet, backing) = padded_packet(conn.handshake_cid, &frames, WIRE_LEN);
                conn.process_payload(now, conn.path.remote, conn.path.local, 0, packet, None)
                    .unwrap();
                let mut stream = conn.recv_stream(id);
                let mut chunks = stream.read(true).unwrap();
                let chunk = chunks
                    .next(usize::MAX)
                    .unwrap()
                    .expect("the data is buffered");
                let _transmit = chunks.finalize();
                assert_eq!(chunk.bytes.as_ref(), vec![5; len]);
                let at = chunk.bytes.as_ptr() as usize;
                assert_eq!(
                    !backing.contains(&at),
                    detached,
                    "{len}-byte stream frame, server receives: {server_receives}"
                );
            }
        }
    }

    #[test]
    fn received_tokens_are_bounded_and_detached_before_storage() {
        for length in [
            64,
            usize::from(crate::proto::MAX_UDP_PAYLOAD),
            usize::from(crate::proto::MAX_UDP_PAYLOAD) + 1,
        ] {
            let mut pair = Pair::default();
            let (client, _) = pair.connect();
            let now = pair.time;
            let conn = pair.client_conn_mut(client);
            let store = Arc::new(ObservedTokens::default());
            let ConnectionSide::Client { token_store, .. } = &mut conn.side else {
                panic!("client")
            };
            *token_store = store.clone();
            let mut encoded = Vec::new();
            frame::NewToken {
                token: Bytes::from(vec![7; length]),
            }
            .encode(&mut encoded);
            let backing = rama_core::bytes::BytesMut::from(encoded.as_slice());
            let start = backing.as_ptr() as usize;
            let end = start + backing.len();
            let packet = Packet {
                header: Header::Short {
                    spin: false,
                    key_phase: false,
                    dst_cid: conn.handshake_cid,
                    number: PacketNumber::U8(0),
                },
                header_data: Bytes::new(),
                allocated: backing.len(),
                payload: backing,
            };
            conn.process_payload(now, conn.path.remote, conn.path.local, 0, packet, None)
                .unwrap();
            let tokens = store.0.lock();
            if length > usize::from(crate::proto::MAX_UDP_PAYLOAD) {
                assert!(tokens.is_empty());
            } else {
                assert_eq!(tokens.len(), 1);
                assert_eq!(tokens[0].token().as_ref(), vec![7; length]);
                let retained = tokens[0].token().as_ptr() as usize;
                assert!(retained < start || retained >= end);
            }
        }
    }

    #[test]
    fn zero_rtt_rejects_one_rtt_only_frames_before_dispatch() {
        let mut mismatches = Vec::new();
        for side in [Side::Client, Side::Server] {
            for (ty, payload) in [
                (frame::FrameType::ACK, vec![0; 4]),
                (frame::FrameType::ACK_ECN, vec![0; 7]),
                (frame::FrameType::CRYPTO, vec![0; 2]),
                (frame::FrameType::NEW_TOKEN, vec![1, 42]),
                (frame::FrameType::PATH_RESPONSE, vec![0; 8]),
                (frame::FrameType::HANDSHAKE_DONE, vec![]),
                (frame::FrameType::ACK_FREQUENCY, vec![0, 1, 0, 1]),
                (frame::FrameType::IMMEDIATE_ACK, vec![]),
            ] {
                let mut pair = Pair::default();
                let (now, conn) = connected(&mut pair, side);
                let mut wire = Vec::new();
                ty.encode(&mut wire);
                wire.extend_from_slice(&payload);
                // Test decoded-packet admission directly. Production rejects
                // server-originated 0-RTT before decryption; that independent
                // role guard must not substitute for this frame-level check.
                let packet = Packet {
                    header: Header::Long {
                        ty: LongType::ZeroRtt,
                        dst_cid: conn.handshake_cid,
                        src_cid: conn.orig_rem_cid,
                        number: PacketNumber::U8(0),
                        version: Version::V1.to_wire().unwrap(),
                    },
                    header_data: Default::default(),
                    payload: wire.as_slice().into(),
                    allocated: wire.len(),
                };
                let result =
                    conn.process_payload(now, conn.path.remote, conn.path.local, 0, packet, None);
                if !result.as_ref().is_err_and(|error| {
                    error.code == TransportErrorCode::PROTOCOL_VIOLATION
                        && error.reason == "illegal frame type in 0-RTT"
                }) {
                    mismatches.push((side, ty, result));
                }
            }
        }
        assert!(mismatches.is_empty(), "{mismatches:?}");
    }

    #[test]
    fn ack_frequency_frames_require_one_rtt() {
        for immediate in [false, true] {
            for early in [true, false] {
                let mut pair = Pair::default();
                let (_, server) = pair.connect();
                let now = pair.time;
                let conn = pair.server_conn_mut(server);
                let mut payload = Vec::new();
                if immediate {
                    frame::FrameType::IMMEDIATE_ACK.encode(&mut payload);
                } else {
                    frame::AckFrequency {
                        sequence: VarInt::from_u32(1_000),
                        ack_eliciting_threshold: VarInt::from_u32(1),
                        request_max_ack_delay: VarInt::from_u32(25_000),
                        reordering_threshold: VarInt::from_u32(1),
                    }
                    .encode(&mut payload);
                }
                // Exercise the decoded-packet dispatch boundary; keys and packet-number
                // deduplication are checked before this method in production.
                let header = if early {
                    Header::Long {
                        ty: LongType::ZeroRtt,
                        dst_cid: conn.handshake_cid,
                        src_cid: conn.orig_rem_cid,
                        number: PacketNumber::U8(0),
                        version: Version::V1.to_wire().unwrap(),
                    }
                } else {
                    Header::Short {
                        spin: false,
                        key_phase: false,
                        dst_cid: conn.handshake_cid,
                        number: PacketNumber::U8(0),
                    }
                };
                let packet = Packet {
                    header,
                    header_data: Default::default(),
                    payload: payload.as_slice().into(),
                    allocated: payload.len(),
                };
                let result =
                    conn.process_payload(now, conn.path.remote, conn.path.local, 0, packet, None);
                if early {
                    let error = result.unwrap_err();
                    assert_eq!(error.code, TransportErrorCode::PROTOCOL_VIOLATION);
                    assert_eq!(error.reason, "illegal frame type in 0-RTT");
                } else {
                    result.unwrap();
                }
            }
        }
    }

    #[test]
    fn zero_rtt_frames_follow_the_packet_type_table() {
        // (encoded frame, whether a 0-RTT packet may carry it)
        let cases: [(&[u8], bool); 8] = [
            (&[0x02, 0x00, 0x00, 0x00, 0x00], false), // ACK
            (&[0x06, 0x00, 0x00], false),             // CRYPTO
            (&[0x07, 0x01, 0xaa], false),             // NEW_TOKEN
            (&[0x19, 0x00], false),                   // RETIRE_CONNECTION_ID
            (&[0x1b, 1, 2, 3, 4, 5, 6, 7, 8], false), // PATH_RESPONSE
            (&[0x1e], false),                         // HANDSHAKE_DONE
            (&[0x01], true),                          // PING
            (&[0x1a, 1, 2, 3, 4, 5, 6, 7, 8], true),  // PATH_CHALLENGE
        ];
        for (payload, permitted) in cases {
            let mut pair = Pair::default();
            let (_, server) = pair.connect();
            let now = pair.time;
            let conn = pair.server_conn_mut(server);
            let packet = Packet {
                header: Header::Long {
                    ty: LongType::ZeroRtt,
                    dst_cid: conn.handshake_cid,
                    src_cid: conn.orig_rem_cid,
                    number: PacketNumber::U8(0),
                    version: Version::V1.to_wire().unwrap(),
                },
                header_data: Default::default(),
                payload: payload.into(),
                allocated: payload.len(),
            };
            let result =
                conn.process_payload(now, conn.path.remote, conn.path.local, 0, packet, None);
            if permitted {
                result.unwrap();
            } else {
                let error = result.unwrap_err();
                assert_eq!(error.code, TransportErrorCode::PROTOCOL_VIOLATION);
                assert_eq!(
                    error.reason, "illegal frame type in 0-RTT",
                    "{payload:02x?}"
                );
                assert!(error.frame.is_some(), "{payload:02x?}");
            }
        }
    }
}
