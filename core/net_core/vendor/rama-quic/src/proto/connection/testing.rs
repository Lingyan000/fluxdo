//! Accessors the tests reach for, kept out of the entry surface.
//!
//! Every item here is `cfg(test)`, so none of it is built into a release.

use std::{mem, net::SocketAddr};

use crate::proto::{
    Instant,
    connection::{
        Connection, ConnectionError, paths::Challenge, preferred::PreferredAddressState,
        spaces::PacketNumberFilter, timer::Timer,
    },
    crypto::{self},
};
use rama_quic_proto::{ConnectionId, crypto::PacketKey, packet::SpaceId};

impl Connection {
    pub(crate) fn server_candidate_pending(&self) -> bool {
        self.server_candidate.is_some()
    }

    pub(crate) fn server_candidate_id_for_test(&self) -> Option<(ConnectionId, u64)> {
        self.server_candidate.as_ref().map(|c| (c.cid, c.seq))
    }

    pub(crate) fn validation_timers_for_test(&self) -> (Option<Instant>, Option<Instant>) {
        (
            self.timers.get(Timer::PathChallenge),
            self.timers.get(Timer::PathProbe),
        )
    }

    pub(crate) fn pto_count_for_test(&self) -> u32 {
        self.pto_count
    }

    /// Decode our own packet without changing peer state, for assertions
    /// about which frames left each local socket before path validation.
    pub(crate) fn sent_frames_for_test(&self, bytes: &[u8]) -> Vec<rama_quic_proto::frame::Frame> {
        self.decode_sent_packet_for_test(bytes.into()).0
    }

    pub(crate) fn sent_datagram_frames_for_test(
        &self,
        bytes: &[u8],
    ) -> Vec<rama_quic_proto::frame::Frame> {
        let mut remaining = Some(bytes.into());
        let mut frames = Vec::new();
        while let Some(bytes) = remaining {
            let (packet, rest) = self.decode_sent_packet_for_test(bytes);
            frames.extend(packet);
            remaining = rest;
        }
        frames
    }

    fn decode_sent_packet_for_test(
        &self,
        bytes: rama_core::bytes::BytesMut,
    ) -> (
        Vec<rama_quic_proto::frame::Frame>,
        Option<rama_core::bytes::BytesMut>,
    ) {
        use rama_quic_proto::packet::{FixedLengthConnectionIdParser, PartialDecode};
        let (partial, rest) = PartialDecode::new(
            bytes,
            &FixedLengthConnectionIdParser::new(self.rem_cids.active().len()),
            &[self.version()],
            self.endpoint_config.grease_quic_bit,
        )
        .unwrap();
        let space = partial.space().unwrap();
        let keys = &self.spaces[space].crypto.as_ref().unwrap().local;
        let mut packet = partial.finish_protected(&*keys.header).unwrap();
        let number = packet
            .header
            .number()
            .unwrap()
            .expand(self.spaces[space].next_packet_number);
        // Early key updates fire after a random packet count, so a packet sent
        // before one is protected with the previous phase's keys.
        let packet_key = if space == SpaceId::Data && packet.header.key_phase() != self.key_phase {
            &*self
                .prev_crypto
                .as_ref()
                .expect("keys of the previous key phase")
                .crypto
                .local
        } else {
            &*keys.packet
        };
        packet_key
            .decrypt(number, &packet.header_data, &mut packet.payload)
            .unwrap();
        let frames = rama_quic_proto::frame::Iter::new(packet.payload.freeze())
            .unwrap()
            .map(Result::unwrap)
            .collect();
        (frames, rest)
    }

    /// A protected peer packet with deliberate frame/address choices. It spends
    /// a real packet number and encryption, so receive-path tests still exercise
    /// routing, authentication and duplicate detection.
    pub(crate) fn encode_peer_packet_for_test(
        &mut self,
        now: Instant,
        cid: ConnectionId,
        frames: &[u8],
    ) -> rama_core::bytes::BytesMut {
        self.encode_packet_in_space_for_test(now, SpaceId::Data, cid, frames)
    }

    pub(crate) fn initial_ping_for_test(&mut self, now: Instant) -> rama_core::bytes::BytesMut {
        self.encode_packet_in_space_for_test(now, SpaceId::Initial, self.rem_cids.active(), &[1])
    }

    fn encode_packet_in_space_for_test(
        &mut self,
        now: Instant,
        space: SpaceId,
        cid: ConnectionId,
        frames: &[u8],
    ) -> rama_core::bytes::BytesMut {
        let mut buf = Vec::with_capacity(1200);
        let mut builder = super::packet_builder::PacketBuilder::new(
            now,
            space,
            cid,
            (self.path.remote, self.path.local),
            &mut buf,
            1200,
            0,
            false,
            self,
        )
        .unwrap();
        buf.extend_from_slice(frames);
        builder.pad_to(1200);
        builder.finish(self, now, &mut buf).unwrap();
        buf.as_slice().into()
    }

    pub(crate) fn exhaust_congestion_window_for_probe(&mut self) {
        self.path.in_flight.bytes = self.path.congestion.window();
    }
}

#[cfg(test)]
#[derive(Debug, Clone, Copy)]
pub(crate) struct EmissionState {
    pub mtu: u16,
    pub loss_probes: u32,
}

impl Connection {
    #[cfg(test)]
    pub(crate) fn emission_state(&self) -> EmissionState {
        EmissionState {
            mtu: self.path.current_mtu(),
            loss_probes: self.spaces[SpaceId::Data].loss_probes,
        }
    }

    /// Tests: hand the connection a PATH_RESPONSE naming `token`, as a duplicate or a
    /// delayed copy would arrive.
    #[cfg(test)]
    pub(crate) fn replay_path_response(&mut self, now: Instant, token: u64) -> bool {
        self.on_path_response(now, token)
    }

    /// Tests: why this connection ended, when something ended it.
    #[cfg(test)]
    pub(crate) fn ended_because(&self) -> Option<ConnectionError> {
        self.error.clone()
    }

    /// Tests: the address of the path kept as a fallback, if one is kept.
    #[cfg(test)]
    pub(crate) fn previous_path_remote(&self) -> Option<SocketAddr> {
        self.prev_path.as_ref().map(|it| it.path.remote)
    }

    /// Tests: install a validation on the current path directly, for a case that drives the
    /// packet builder rather than a whole pass.
    #[cfg(test)]
    pub(crate) fn set_challenge(&mut self, token: u64) {
        let generation = self.path.generation();
        self.path.challenge = Some(Challenge::of_address(token, generation));
    }

    /// Tests: install the validation that must prove the minimum MTU, which is only ever
    /// written into a datagram that can reach `MIN_INITIAL_SIZE`.
    #[cfg(test)]
    pub(crate) fn set_mtu_challenge(&mut self, token: u64) {
        let generation = self.path.generation();
        self.path.challenge = Some(Challenge::of_mtu(token, generation));
    }

    /// Tests: write the frames a packet would carry, saying whether the datagram it goes in
    /// can still reach `MIN_INITIAL_SIZE`.
    #[cfg(test)]
    pub(crate) fn populate_for_tests(
        &mut self,
        now: Instant,
        buf: &mut Vec<u8>,
        max_size: usize,
        expands: bool,
    ) {
        let pn = self.spaces[SpaceId::Data].next_packet_number;
        self.populate_packet(now, SpaceId::Data, buf, max_size, pn, expands);
    }

    /// Tests: the current path's generation, for building a validation that belongs to it.
    #[cfg(test)]
    pub(crate) fn path_generation(&self) -> u64 {
        self.path.generation()
    }

    /// Tests: whether the outstanding validation would prove the path's minimum MTU.
    #[cfg(test)]
    pub(crate) fn challenge_proves_mtu(&self) -> bool {
        self.path.challenge.is_some_and(|it| it.proves_mtu())
    }

    /// Tests: when the path validation deadline is set, if it is.
    #[cfg(test)]
    pub(crate) fn path_validation_deadline(&self) -> Option<Instant> {
        self.timers.get(Timer::PathValidation)
    }

    /// Tests: abandon the fallback the way a completed validation does, retiring the
    /// identifier kept for it, so what follows has nowhere to fall back to.
    #[cfg(test)]
    pub(crate) fn abandon_the_fallback(&mut self) {
        self.drop_previous_path();
    }

    /// Tests: whether this path has shown it carries a datagram of `MIN_INITIAL_SIZE`.
    #[cfg(test)]
    pub(crate) fn mtu_validated(&self) -> bool {
        self.path.mtu_validated
    }

    /// Tests: say whether the path has proven its minimum MTU, leaving everything else as it
    /// is, for the cases about what waits on that condition alone.
    #[cfg(test)]
    pub(crate) fn set_mtu_validated(&mut self, proven: bool) {
        self.path.mtu_validated = proven;
    }

    /// Tests: the token of the validation outstanding on the current path, if any.
    #[cfg(test)]
    pub(crate) fn challenge_token(&self) -> Option<u64> {
        self.path.challenge.map(|it| it.token())
    }

    /// Tests: whether the outstanding validation is the one that must prove the minimum MTU.
    #[cfg(test)]
    pub(crate) fn challenge_is_for_mtu(&self) -> bool {
        self.path.challenge.is_some_and(|it| it.is_for_mtu())
    }

    /// Tests: how many expanded validations this path has spent.
    #[cfg(test)]
    pub(crate) fn mtu_validations(&self) -> u8 {
        self.path.mtu_validations
    }

    /// Whether the loss-detection (PTO) timer is armed (tests).
    #[cfg(test)]
    pub(crate) fn loss_detection_armed(&self) -> bool {
        self.timers.get(Timer::LossDetection).is_some()
    }

    /// Tests: the destination connection ID kept aside for the previous path, if any.
    #[cfg(test)]
    pub(crate) fn held_rem_cid(&self) -> Option<ConnectionId> {
        self.rem_cids.held().map(|c| c.id)
    }

    /// Tests: whether a datagram carrying the active connection ID has gone out (RFC 9000
    /// §10.3.1: until one has, that identifier is not one we have used).
    #[cfg(test)]
    pub(crate) fn active_cid_confirmed(&self) -> bool {
        self.rem_cids.is_sent(self.rem_cids.active_seq())
    }

    /// Tests: the sequence number of the identifier kept for the previous path.
    #[cfg(test)]
    pub(crate) fn held_rem_cid_seq(&self) -> u64 {
        self.rem_cids.held().expect("an identifier is held").seq
    }

    /// Tests: whether a datagram carrying the identifier numbered `seq` has gone out.
    #[cfg(test)]
    pub(crate) fn cid_confirmed(&self, seq: u64) -> bool {
        self.rem_cids.is_sent(seq)
    }

    /// Tests: how many times a datagram has been reported as having reached the network.
    #[cfg(test)]
    pub(crate) fn cid_sent_calls(&self) -> u64 {
        self.cid_sent_calls
    }

    /// Tests: whether a datagram carrying the identifier numbered `seq` has gone out towards
    /// `remote`.
    #[cfg(test)]
    pub(crate) fn cid_confirmed_to(&self, seq: u64, remote: SocketAddr) -> bool {
        self.rem_cids.is_sent_to(seq, remote)
    }

    /// Tests: owe the peer an ACK in `space` for each of `packets`, as if they had arrived.
    #[cfg(test)]
    pub(crate) fn owe_acks(
        &mut self,
        now: Instant,
        space: SpaceId,
        packets: impl IntoIterator<Item = u64>,
    ) {
        let space = &mut self.spaces[space];
        for packet in packets {
            space.pending_acks.insert_one(packet, now);
            space.dedup.insert(packet);
            space
                .pending_acks
                .packet_received(now, packet, true, &space.dedup);
        }
    }

    /// Tests: put the 1-RTT keys' packet count where the caller wants it, so the confidentiality
    /// limit is reachable without sending as many packets as the AEAD allows.
    #[cfg(test)]
    pub(crate) fn set_packets_sent_with_keys(&mut self, sent: u64) {
        self.spaces[SpaceId::Data].sent_with_keys = sent;
    }

    /// Tests: when the idle timer fires, if it is armed.
    #[cfg(test)]
    pub(crate) fn idle_timer(&self) -> Option<Instant> {
        self.timers.get(Timer::Idle)
    }

    /// Tests: put the next 1-RTT packet number `distance` past the largest acknowledged one, so
    /// the encoding limit is reachable without sending billions of packets.
    #[cfg(test)]
    pub(crate) fn set_packet_number_distance(&mut self, distance: u64) {
        let space = &mut self.spaces[SpaceId::Data];
        space.next_packet_number = space.largest_acked_packet.unwrap_or(0) + distance;
    }

    /// Tests: arrange for the next 1-RTT packet number to be one the filter passes over, which
    /// is otherwise chosen at random.
    #[cfg(test)]
    pub(crate) fn skip_next_packet_number(&mut self) {
        let next = self.spaces[SpaceId::Data].next_packet_number;
        self.packet_number_filter.skip_next(next);
    }

    /// Tests: pass over no packet number, so a test about what one pass spends is not decided
    /// by where the filter's first randomly chosen skip landed.
    #[cfg(test)]
    pub(crate) fn skip_no_packet_number(&mut self) {
        self.packet_number_filter = PacketNumberFilter::disabled();
    }

    /// Tests: the packet number most recently passed over, and the number the next packet
    /// will take.
    #[cfg(test)]
    pub(crate) fn packet_numbers(&self) -> (Option<u64>, u64) {
        (
            self.packet_number_filter.last_skipped(),
            self.spaces[SpaceId::Data].next_packet_number,
        )
    }

    /// Tests: how much input the next close response costs, which doubles with each one sent.
    #[cfg(test)]
    pub(crate) fn close_response_gap(&self) -> u32 {
        self.close_responses.gap.get()
    }

    /// Tests: the space whose close is due next.
    #[cfg(test)]
    pub(crate) fn close_due_from(&self) -> usize {
        self.close_from as usize
    }

    /// Tests: how many packet number spaces a close would be written into, which is more than
    /// one before the handshake is confirmed.
    #[cfg(test)]
    pub(crate) fn spaces_with_close_keys(&self) -> usize {
        SpaceId::iter()
            .take_while(|&space| space <= self.highest_space)
            .filter(|&space| self.spaces[space].crypto.is_some())
            .count()
    }

    /// Tests: how many packets the 1-RTT keys in use have sent.
    #[cfg(test)]
    pub(crate) fn packets_sent_with_keys(&self) -> u64 {
        self.spaces[SpaceId::Data].sent_with_keys
    }

    /// Tests: the confidentiality limit of the keys this connection sends 1-RTT packets with.
    #[cfg(test)]
    pub(crate) fn confidentiality_limit(&self) -> u64 {
        self.spaces[SpaceId::Data]
            .crypto
            .as_ref()
            .map_or_else(
                || &self.zero_rtt_crypto.as_ref().unwrap().packet,
                |keys| &keys.local.packet,
            )
            .confidentiality_limit()
    }

    /// Tests: keep the key phase from being retired, so the limit is met with the keys in use.
    #[cfg(test)]
    pub(crate) fn set_key_phase_size(&mut self, packets: u64) {
        self.key_phase_size = packets;
    }

    /// Tests: wrap the 1-RTT packet keys in use and those prepared for the next phase, so a
    /// limit of the test's choosing stands in for the AEAD's own.
    #[cfg(test)]
    pub(crate) fn wrap_one_rtt_packet_keys(
        &mut self,
        wrap: &dyn Fn(Box<dyn PacketKey>) -> Box<dyn PacketKey>,
    ) {
        struct Absent;
        impl PacketKey for Absent {
            fn encrypt(
                &self,
                _: u64,
                _: &mut [u8],
                _: usize,
            ) -> Result<(), rama_quic_proto::crypto::CryptoError> {
                Err(rama_quic_proto::crypto::CryptoError::new())
            }
            fn decrypt(
                &self,
                _: u64,
                _: &[u8],
                _: &mut rama_core::bytes::BytesMut,
            ) -> Result<(), rama_quic_proto::crypto::CryptoError> {
                Err(rama_quic_proto::crypto::CryptoError::new())
            }
            fn tag_len(&self) -> usize {
                16
            }
            fn confidentiality_limit(&self) -> u64 {
                0
            }
            fn integrity_limit(&self) -> u64 {
                0
            }
        }
        fn swap(
            slot: &mut Box<dyn PacketKey>,
            wrap: &dyn Fn(Box<dyn PacketKey>) -> Box<dyn PacketKey>,
        ) {
            let key = mem::replace(slot, Box::new(Absent));
            *slot = wrap(key);
        }
        let keys = self.spaces[SpaceId::Data]
            .crypto
            .as_mut()
            .expect("1-RTT keys are installed");
        swap(&mut keys.local.packet, wrap);
        if let Some(remote) = keys.remote.as_mut() {
            swap(&mut remote.packet, wrap);
        }
        if let Some(next) = self.next_crypto.as_mut() {
            swap(&mut next.local, wrap);
            swap(&mut next.remote, wrap);
        }
    }

    /// Tests: how many received packets have failed authentication over the connection's life.
    #[cfg(test)]
    pub(crate) fn authentication_failures(&self) -> u64 {
        self.authentication_failures
    }

    /// Tests: how many received packets have authenticated.
    #[cfg(test)]
    pub(crate) fn authenticated_packets(&self) -> u64 {
        self.total_authed_packets
    }

    /// Tests: the TLS session, to hand it what the peer's CRYPTO frames would carry.
    #[cfg(test)]
    pub(crate) fn crypto_session_mut(&mut self) -> &mut dyn crypto::Session {
        &mut *self.crypto
    }

    /// Tests: how far this client got with the server's preferred address.
    #[cfg(test)]
    pub(crate) fn preferred_address_state(&self) -> PreferredAddressState {
        self.preferred_state
    }

    /// Tests: the destination connection ID reserved for a candidate path, if any.
    #[cfg(test)]
    pub(crate) fn reserved_rem_cid(&self) -> Option<ConnectionId> {
        self.rem_cids.reserved().map(|c| c.id)
    }

    /// Tests: the destination connection IDs the peer issued that we have not used yet.
    #[cfg(test)]
    pub(crate) fn unused_rem_cids(&self) -> Vec<ConnectionId> {
        self.rem_cids.unused().into_iter().map(|c| c.id).collect()
    }

    /// Tests: the sequence numbers of those identifiers.
    #[cfg(test)]
    pub(crate) fn unused_rem_cid_seqs(&self) -> Vec<u64> {
        self.rem_cids.unused().into_iter().map(|c| c.seq).collect()
    }

    pub(crate) fn send_pending_cids_descending(&mut self) -> Vec<(u64, ConnectionId)> {
        let pending = &mut self.spaces[SpaceId::Data].pending.new_cids;
        pending.sort_by_key(|cid| cid.sequence);
        pending.iter().map(|cid| (cid.sequence, cid.id)).collect()
    }

    /// Ack-eliciting packets in flight on the current path only (tests): the congestion view that
    /// a path swap resets, as opposed to the connection-wide outstanding set.
    #[cfg(test)]
    pub(crate) fn current_path_in_flight_ack_eliciting(&self) -> u64 {
        self.path.in_flight.ack_eliciting
    }

    /// Whether ack-driven time-threshold loss detection is pending in some packet number space
    /// (tests): a packet older than the largest acknowledged one is waiting to be declared lost.
    #[cfg(test)]
    pub(crate) fn loss_time_pending(&self) -> bool {
        SpaceId::iter().any(|space| self.spaces[space].loss_time.is_some())
    }

    /// Tests: the ack-eliciting in-flight count that loss recovery decides on, and the number of
    /// ack-eliciting packets actually outstanding in the packet number spaces. They must agree,
    /// whatever happened to the paths those packets were sent on.
    #[cfg(test)]
    pub(crate) fn loss_recovery_in_flight(&self) -> (u64, u64) {
        let outstanding = SpaceId::iter()
            .map(|space| {
                self.spaces[space]
                    .sent_packets
                    .values()
                    .filter(|packet| packet.ack_eliciting)
                    .count() as u64
            })
            .sum();
        (self.in_flight_ack_eliciting(), outstanding)
    }

    /// The active remote connection ID (tests observe it on the wire).
    #[cfg(test)]
    pub(crate) fn active_rem_cid(&self) -> ConnectionId {
        self.rem_cids.active()
    }

    /// The number of received bytes in the current path
    #[cfg(test)]
    pub(crate) fn total_recvd(&self) -> u64 {
        self.path.total_recvd
    }
}
