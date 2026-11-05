//! A server probes its preferred local address without interrupting the original path.

use std::net::SocketAddr;

use rama_quic_proto::{
    ConnectionId, TransportError, coding::BufMutExt as _, frame, packet::SpaceId,
};
use rand::RngExt as _;

use super::{
    Connection, ConnectionSide,
    migration::{PrevCid, PreviousPath},
    packet_builder::PacketBuilder,
    paths::Challenge,
    qlog::path::MigrationState,
    timer::Timer,
};
use crate::proto::{Duration, Instant, MIN_INITIAL_SIZE, Transmit};

// A one-sided firewall must not consume a new peer CID on every delayed packet.
const MAX_CANDIDATE_ATTEMPTS: u8 = 3;

pub(super) struct ServerCandidate {
    pub(super) remote: SocketAddr,
    pub(super) local: Option<SocketAddr>,
    pub(super) cid: ConnectionId,
    pub(super) seq: u64,
    challenge: Option<Challenge>,
    generation: u64,
    received: u64,
    pub(super) sent: u64,
    validated: bool,
    mtu_validated: bool,
    /// A packet which was the newest non-probing packet when it reached this tuple.
    non_probing: Option<ConnectionId>,
    interval: Duration,
    deadline: Instant,
}

impl ServerCandidate {
    pub(super) fn send_capacity(&self) -> usize {
        if self.validated {
            return usize::from(MIN_INITIAL_SIZE);
        }
        self.received
            .saturating_mul(3)
            .saturating_sub(self.sent)
            .min(u64::from(MIN_INITIAL_SIZE)) as usize
    }
}

impl Connection {
    /// RFC 9000 §9.6.2: validation and a newest non-probing packet are both
    /// necessary before sending application traffic from the preferred address.
    /// Start probing even on PATH_CHALLENGE so both sides can validate in parallel.
    #[expect(clippy::too_many_arguments, reason = "authenticated packet provenance")]
    pub(super) fn observe_server_preferred(
        &mut self,
        now: Instant,
        remote: SocketAddr,
        local: Option<SocketAddr>,
        number: u64,
        dcid: ConnectionId,
        received: usize,
        non_probing: bool,
    ) -> Result<bool, TransportError> {
        let preferred = !self.same_local(local)
            && matches!(&self.side, ConnectionSide::Server { server_config }
                if Self::is_preferred_local(server_config, local));
        if preferred && !self.state.is_closed() {
            if self.server_candidate.is_none()
                && self.server_candidate_attempts < MAX_CANDIDATE_ATTEMPTS
                && let Some(cid) = self.rem_cids.reserve()
            {
                self.install_reset_route(cid.seq, remote);
                // A different local address can have a different RTT. Bound the
                // attempt with three conservative PTOs, independently of ACKs
                // and the congestion/recovery state on the original path.
                let interval = self.pto(SpaceId::Data).max(3 * self.config.initial_rtt);
                let deadline = now + 3 * interval;
                self.server_candidate_attempts += 1;
                self.server_candidate = Some(Box::new(ServerCandidate {
                    remote,
                    local,
                    cid: cid.id,
                    seq: cid.seq,
                    challenge: Some(Challenge::of_address(self.rng.random(), self.path_counter)),
                    generation: self.path_counter,
                    received: 0,
                    sent: 0,
                    validated: false,
                    mtu_validated: false,
                    non_probing: None,
                    interval,
                    deadline,
                }));
                self.spin_cid_changed(remote, local, cid.id);
                self.timers.set(Timer::PathProbe, deadline);
            }
            if let Some(candidate) = self.server_candidate.as_mut()
                && candidate.remote == remote
                && candidate.local == local
            {
                candidate.received = candidate.received.saturating_add(received as u64);
                if non_probing && number == self.spaces[SpaceId::Data].rx_packet {
                    candidate.non_probing = Some(dcid);
                }
            }
        }
        if self
            .server_candidate
            .as_ref()
            .is_some_and(|c| c.mtu_validated && c.non_probing.is_some())
        {
            self.promote_server_candidate(now)?;
        }
        // Even when no CID is available, keep the original sending path. A
        // subsequent packet can start the candidate once NEW_CONNECTION_ID arrives.
        Ok(preferred)
    }

    pub(super) fn send_server_candidate(
        &mut self,
        now: Instant,
        buf: &mut Vec<u8>,
    ) -> Option<Transmit> {
        if self.state.is_closed() || self.highest_space != SpaceId::Data {
            return None;
        }
        let candidate = self.server_candidate.as_ref()?;
        let capacity = candidate.send_capacity();
        let challenge = candidate
            .challenge
            .filter(|c| c.pending() && c.may_go_in(capacity >= usize::from(MIN_INITIAL_SIZE)))?;
        if capacity <= 1 + candidate.cid.len() + 4 + self.tag_len_1rtt() + 9 {
            return None;
        }
        let (remote, local, cid, seq) = (
            candidate.remote,
            candidate.local,
            candidate.cid,
            candidate.seq,
        );
        let mut builder = PacketBuilder::new(
            now,
            SpaceId::Data,
            cid,
            (remote, local),
            buf,
            capacity,
            0,
            false,
            self,
        )?;
        buf.write(frame::FrameType::PATH_CHALLENGE);
        buf.write(challenge.token());
        self.stats.frame_tx.path_challenge += 1;
        while buf.len() + 9 <= builder.max_size {
            let Some(token) = self.path_responses.pop_on_path(remote, local) else {
                break;
            };
            buf.write(frame::FrameType::PATH_RESPONSE);
            buf.write(token);
            self.stats.frame_tx.path_response += 1;
        }
        builder.pad_to(capacity as u16);
        builder.finish(self, now, buf)?;
        let candidate = self.server_candidate.as_mut()?;
        candidate.sent = candidate.sent.saturating_add(buf.len() as u64);
        if let Some(challenge) = candidate.challenge.as_mut() {
            challenge.note_sent(buf.len());
            challenge.written(now, candidate.interval);
            self.timers.set(
                Timer::PathProbe,
                challenge
                    .retry_at()
                    .unwrap_or(candidate.deadline)
                    .min(candidate.deadline),
            );
        }
        self.stats.udp_tx.on_sent(1, buf.len());
        Some(Transmit {
            destination: remote,
            local,
            size: buf.len(),
            ecn: None,
            segment_size: None,
            cid_used: Some(seq),
        })
    }

    pub(super) fn on_server_preferred_response(&mut self, now: Instant, token: u64) -> bool {
        let Some(candidate) = self.server_candidate.as_mut() else {
            return false;
        };
        let Some(challenge) = candidate
            .challenge
            .filter(|c| c.is_answered_by(token, candidate.generation))
        else {
            return false;
        };
        candidate.validated = true;
        if challenge.proves_mtu() {
            candidate.mtu_validated = true;
            candidate.challenge = None;
        } else {
            // A small probe proves the address, but a fresh expanded one must
            // prove the minimum MTU before the candidate can carry traffic.
            candidate.challenge = Some(Challenge::of_mtu(self.rng.random(), candidate.generation));
            candidate.deadline = now + 3 * candidate.interval;
        }
        self.timers.set(Timer::PathProbe, candidate.deadline);
        true
    }

    pub(super) fn on_server_candidate_timeout(&mut self, now: Instant) {
        if self
            .server_candidate
            .as_ref()
            .is_some_and(|c| now >= c.deadline)
        {
            self.discard_server_candidate();
        } else if let Some(candidate) = self.server_candidate.as_mut() {
            if let Some(challenge) = candidate.challenge.as_mut() {
                challenge.rearm(now);
            }
            self.timers.set(Timer::PathProbe, candidate.deadline);
        }
    }

    pub(super) fn discard_server_candidate(&mut self) {
        let Some(candidate) = self.server_candidate.take() else {
            return;
        };
        self.timers.stop(Timer::PathProbe);
        // Queued responses shared this candidate's allowance. Do not revive
        // their old per-packet credit after abandoning the aggregate ledger.
        while self
            .path_responses
            .pop_on_path(candidate.remote, candidate.local)
            .is_some()
        {}
        if let Some(seq) = self.rem_cids.release_reserved()
            && let Err(error) = self.retire_rem_cid(seq)
        {
            self.defer_error(error);
        }
    }

    fn promote_server_candidate(&mut self, now: Instant) -> Result<(), TransportError> {
        let Some(candidate) = self.server_candidate.as_ref() else {
            return Ok(());
        };
        // Check every fallible promotion precondition before dropping a usable
        // fallback. Retirement normally cancels the candidate as it arrives.
        if !self
            .rem_cids
            .reserved()
            .is_some_and(|cid| cid.seq == candidate.seq && cid.reset_token.is_some())
            || (self.rem_cids.held().is_some()
                && !self
                    .prev_path
                    .as_ref()
                    .is_some_and(|prev| prev.cid == PrevCid::Held))
        {
            self.discard_server_candidate();
            return Err(TransportError::INTERNAL_ERROR(
                "preferred path lost its reserved identifier",
            ));
        }
        let old_cid = self.rem_cids.active();
        let remote_changed = candidate.remote != self.path.remote;
        self.drop_previous_path();
        let promoted = if remote_changed {
            self.rem_cids.promote_reserved_holding()
        } else {
            self.rem_cids.promote_reserved()
        };
        let Some((token, retired)) = promoted else {
            self.discard_server_candidate();
            return Err(TransportError::INTERNAL_ERROR(
                "preferred path identifier promotion failed",
            ));
        };
        let Some(candidate) = self.server_candidate.take() else {
            return Err(TransportError::INTERNAL_ERROR(
                "preferred candidate disappeared during promotion",
            ));
        };
        self.timers.stop(Timer::PathProbe);
        self.retire_rem_cids(&retired)?;
        self.qlog_remote_cid_updated(now, old_cid);
        // §9.3.3's old-path challenge protects against a forwarded source-address
        // change. A local-only transition needs no such check; a simultaneous
        // peer move still challenges the original using its retained identifier.
        self.migrate(
            now,
            candidate.remote,
            candidate.local,
            if remote_changed {
                PreviousPath::Keep(PrevCid::Held)
            } else {
                PreviousPath::Discard
            },
        );
        self.path.challenge = None;
        self.path.validated = true;
        self.path.mtu_validated = true;
        self.path.received_dcid = candidate.non_probing;
        self.path.total_recvd = candidate.received;
        self.path.total_sent = candidate.sent;
        if !remote_changed {
            self.timers.stop(Timer::PathValidation);
        }
        self.arm_path_challenge_timer();
        self.set_reset_token(candidate.remote, token);
        self.qlog_migration_state(now, MigrationState::MigrationComplete);
        Ok(())
    }
}
