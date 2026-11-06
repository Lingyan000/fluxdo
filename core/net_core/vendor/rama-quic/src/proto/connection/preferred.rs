//! Moving to the address a server advertised: probing the candidate with the identifier
//! reserved for it, and giving up when it never answers.

use std::net::{IpAddr, SocketAddr};

use rama_core::telemetry::tracing::{debug, trace};

use rama_net::address::{SocketAddress, ip::IntoCanonicalIpAddr};

use rand::RngExt;

use crate::proto::{
    Duration, Instant, MIN_INITIAL_SIZE, SendPermit, Transmit,
    config::{PreferredAddressPolicy, ServerConfig},
    connection::{
        Connection, ConnectionSide, migration::PreviousPath, packet_builder::PacketBuilder,
        qlog::path::MigrationState, timer::Timer,
    },
};
use rama_quic_proto::{
    ConnectionId, TransportError, coding::BufMutExt, frame, packet::SpaceId,
    transport_parameters::PreferredAddress,
};

impl Connection {
    /// Whether `local` is the address this server advertised as preferred for its family.
    pub(super) fn is_preferred_local(config: &ServerConfig, local: Option<SocketAddr>) -> bool {
        match local {
            Some(SocketAddr::V4(local)) => config.preferred_address_v4 == Some(local),
            Some(SocketAddr::V6(local)) => config.preferred_address_v6 == Some(local),
            None => false,
        }
    }

    /// Note the address a server advertises as preferred for the family in use (RFC 9000 §9.6.2),
    /// unless this client declines it. Probing waits for handshake confirmation.
    pub(super) fn arm_preferred_address(&mut self, info: &PreferredAddress) {
        let policy = match &self.side {
            ConnectionSide::Client {
                preferred_address_policy,
                ..
            } => *preferred_address_policy,
            ConnectionSide::Server { .. } => return,
        };
        if policy == PreferredAddressPolicy::Decline {
            trace!("declining the server's preferred address");
            return;
        }
        // With connection IDs of our own the peer routes us by identifier; with none it routes us
        // by address, and a move would take us out of the tuple it knows (RFC 9000 §9).
        if self.local_cid_state.cid_len() == 0 {
            trace!("zero-length connection IDs: this connection cannot move");
            return;
        }
        // By the family of the address in use, canonically: an IPv4-mapped IPv6 address is an
        // IPv4 peer, and the address advertised for IPv4 is the one it can reach. Whether the
        // local socket can reach the chosen family is not knowable here; a family it cannot reach
        // ends as a failed probe, which leaves the connection where it is.
        let remote = SocketAddress::from(self.path.remote).into_canonical_ip_addr();
        let advertised = match remote.ip_addr {
            IpAddr::V4(_) => info.address_v4.map(SocketAddr::V4),
            IpAddr::V6(_) => info.address_v6.map(SocketAddr::V6),
        };
        match advertised {
            Some(remote) if remote != self.path.remote => {
                trace!(%remote, "the server prefers another address");
                self.preferred_address = Some(remote);
                self.preferred_state = PreferredAddressState::Armed;
            }
            Some(_) => trace!("the preferred address is the one in use"),
            None => trace!("no preferred address for the family in use"),
        }
    }

    /// Reserve an identifier for the candidate path and queue its first probe. The identifier the
    /// server bound to the address is used while it is unused; a `retire_prior_to` that took it
    /// leaves another unused one, and with none the attempt ends before anything is sent.
    pub(super) fn begin_candidate(&mut self) {
        let Some(remote) = self.preferred_address else {
            return;
        };
        let Some(cid) = self
            .rem_cids
            .reserve_seq(PREFERRED_ADDRESS_CID_SEQ)
            .or_else(|| self.rem_cids.reserve())
        else {
            debug!("no unused connection ID for the preferred address");
            self.preferred_state = PreferredAddressState::Failed;
            return;
        };
        // The endpoint routes a reset carrying this identifier's token to us from now on, so no
        // answer can race the association; whether we treat such a reset as ours waits for a
        // probe carrying the identifier to have gone out (RFC 9000 §10.3.1).
        self.install_reset_route(cid.seq, remote);
        self.candidate = Some(PreferredCandidate {
            remote,
            cid: cid.id,
            seq: cid.seq,
            sent: [0; MAX_PREFERRED_PROBES],
            transmitted: 0,
            pending: Some(self.rng.random()),
            in_flight: None,
            qlog_started: false,
        });
        self.spin_cid_changed(remote, self.path.local, cid.id);
        self.preferred_state = PreferredAddressState::Probing;
    }

    /// Write one PATH_CHALLENGE towards the preferred address with the identifier reserved for it.
    /// The probe counts, and its identifier becomes one this connection has used, only when the
    /// sender reports the datagram gone ([`cid_sent`](Self::cid_sent)); the deadline is armed
    /// here, so a probe that cannot leave is bounded by the same interval as an unanswered one.
    pub(super) fn send_preferred_probe(
        &mut self,
        now: Instant,
        buf: &mut Vec<u8>,
    ) -> Option<Transmit> {
        let candidate = self.candidate.as_ref()?;
        let token = candidate.pending?;
        let destination = candidate.remote;
        let cid = candidate.cid;
        if self.highest_space != SpaceId::Data {
            return None;
        }
        if self.timers.get(Timer::PathProbe).is_none() {
            self.timers
                .set(Timer::PathProbe, now + self.probe_interval());
        }
        buf.reserve(MIN_INITIAL_SIZE as usize);
        let buf_capacity = buf.capacity();
        let mut builder = PacketBuilder::new(
            now,
            SpaceId::Data,
            cid,
            (destination, self.path.local),
            buf,
            buf_capacity,
            0,
            false,
            self,
        )?;
        trace!(%destination, "probing the preferred address with PATH_CHALLENGE {:08x}", token);
        buf.write(frame::FrameType::PATH_CHALLENGE);
        buf.write(token);
        self.stats.frame_tx.path_challenge += 1;
        // An endpoint expands a datagram carrying a PATH_CHALLENGE to the smallest allowed
        // maximum datagram size.
        builder.pad_to(MIN_INITIAL_SIZE);
        builder.finish(self, now, buf)?;
        self.stats.udp_tx.on_sent(1, buf.len());
        let local = self.path.local;
        let candidate = self.candidate.as_mut()?;
        candidate.pending = None;
        candidate.in_flight = Some(token);
        let seq = candidate.seq;
        let started = std::mem::replace(&mut candidate.qlog_started, true);
        if !started {
            self.qlog_candidate_state(now, seq, destination, MigrationState::ProbingStarted);
        }
        self.timers
            .set(Timer::PathProbe, now + self.probe_interval());
        Some(Transmit {
            destination,
            size: buf.len(),
            ecn: None,
            segment_size: None,
            local,
            cid_used: Some(seq),
        })
    }

    /// Whether the peer's connection ID with this sequence number is still one this connection
    /// may put on the wire. A datagram written before the identifier was retired, or before the
    /// attempt it belonged to was given up, must not go out afterwards (RFC 9000 §9.5).
    pub(crate) fn may_send_cid(&self, seq: u64, destination: SocketAddr) -> SendPermit {
        let known = seq == self.rem_cids.active_seq()
            || self.rem_cids.held().is_some_and(|held| held.seq == seq)
            || self.rem_cids.is_bound(seq)
            || self
                .server_candidate
                .as_ref()
                .is_some_and(|c| c.seq == seq && c.remote == destination)
            || self
                .candidate
                .as_ref()
                .is_some_and(|candidate| candidate.seq == seq && candidate.in_flight.is_some());
        if !known {
            // Retired, or bound to a path this datagram is not for: there is nothing to wait for.
            return SendPermit::Obsolete;
        }
        if self.rem_cids.is_installed(seq, destination) {
            return SendPermit::Sendable;
        }
        // The route is on its way to the endpoint. The datagram waits rather than going out
        // ahead of the way a reset answering it would come back (RFC 9000 §10.3.1).
        SendPermit::AwaitingInstallation
    }

    /// The sender has handed a datagram carrying the peer's connection ID with this sequence
    /// number to the network, so that identifier is one this connection has used and a stateless
    /// reset carrying its token belongs to us (RFC 9000 §10.3.1). A probe also counts here, and
    /// only here, against its attempt's bound.
    pub(crate) fn cid_sent(&mut self, seq: u64, destination: SocketAddr) {
        #[cfg(test)]
        {
            self.cid_sent_calls += 1;
        }
        // Only what changed is published: an ordinary send, and a retry of one that was already
        // recorded, tell the endpoint nothing and allocate nothing.
        let generation = self.reset_generation;
        let owned = self.owned_remotes();
        match self.rem_cids.mark_sent(seq, destination, generation, owned) {
            Ok(Some((delta, token))) => self.apply_route_delta(seq, token, delta, generation),
            Ok(None) => {}
            // Nowhere to record where this datagram went, so a reset answering it could not be
            // recognised. That is ours to fail on, not to ignore.
            Err(_) => self.defer_error(TransportError::INTERNAL_ERROR(
                "no room to record where a connection ID was sent",
            )),
        }
        let Some(candidate) = self.candidate.as_mut().filter(|c| c.seq == seq) else {
            return;
        };
        let Some(token) = candidate.in_flight.take() else {
            return;
        };
        if let Some(slot) = candidate.sent.get_mut(candidate.transmitted) {
            *slot = token;
            candidate.transmitted += 1;
        }
        self.stats.path.preferred_address_probes += 1;
    }

    /// How long one preferred-address probe may go unanswered.
    fn probe_interval(&self) -> Duration {
        3 * self.pto(SpaceId::Data)
    }

    /// A probe went unanswered, or could not be sent within its own interval.
    pub(super) fn on_probe_timeout(&mut self, now: Instant) {
        if self.server_candidate.is_some() {
            self.on_server_candidate_timeout(now);
            return;
        }
        let Some((waiting, transmitted)) = self
            .candidate
            .as_ref()
            .map(|c| (c.outstanding(), c.transmitted))
        else {
            return;
        };
        if waiting {
            debug!("a preferred-address probe could not be sent in time");
            self.give_up_preferred_address(now);
            return;
        }
        if transmitted >= MAX_PREFERRED_PROBES {
            debug!("the preferred address did not answer");
            self.give_up_preferred_address(now);
            return;
        }
        // Each probe carries fresh data; the earlier ones stay valid until the attempt ends. This
        // is the only place a further probe is armed, which is what keeps the count at the bound.
        let token = self.rng.random();
        if let Some(candidate) = self.candidate.as_mut() {
            candidate.pending = Some(token);
        }
        self.timers
            .set(Timer::PathProbe, now + self.probe_interval());
    }

    /// Start the preferred-address attempt over: the identifier set aside for it is given up
    /// along with its challenge data, so nothing written with it can validate anything or go out,
    /// and a fresh identifier is reserved. Without one the attempt ends.
    pub(super) fn restart_candidate(&mut self, now: Instant) {
        self.discard_server_candidate();
        let Some(candidate) = self.candidate.take() else {
            return;
        };
        if candidate.qlog_started {
            self.qlog_candidate_state(
                now,
                candidate.seq,
                candidate.remote,
                MigrationState::ProbingAbandoned,
            );
        }
        self.timers.stop(Timer::PathProbe);
        if let Some(seq) = self.rem_cids.release_reserved()
            && let Err(error) = self.retire_rem_cid(seq)
        {
            self.defer_error(error);
        }
        trace!("the candidate path's identifier is gone: starting over");
        self.begin_candidate();
    }

    /// End the attempt: the reserved identifier is retired and the connection stays where it is.
    fn give_up_preferred_address(&mut self, now: Instant) {
        if let Some(candidate) = self.candidate.take()
            && candidate.qlog_started
        {
            self.qlog_candidate_state(
                now,
                candidate.seq,
                candidate.remote,
                MigrationState::ProbingAbandoned,
            );
        }
        self.timers.stop(Timer::PathProbe);
        if let Some(seq) = self.rem_cids.release_reserved()
            && let Err(error) = self.retire_rem_cid(seq)
        {
            self.defer_error(error);
        }
        self.preferred_state = PreferredAddressState::Failed;
    }

    /// A probe was answered: move to the preferred address with the identifier reserved for it
    /// (RFC 9000 §9.6.2). The path left behind is not kept, so its identifier is retired.
    pub(super) fn take_preferred_address(&mut self, now: Instant) {
        let Some(candidate) = self.candidate.take() else {
            return;
        };
        self.timers.stop(Timer::PathProbe);
        let old_cid = self.rem_cids.active();
        let Some((token, retired)) = self.rem_cids.promote_reserved() else {
            if candidate.qlog_started {
                self.qlog_candidate_state(
                    now,
                    candidate.seq,
                    candidate.remote,
                    MigrationState::ProbingAbandoned,
                );
            }
            debug!("the preferred address answered, but its connection ID is gone");
            self.preferred_state = PreferredAddressState::Failed;
            return;
        };
        if let Err(error) = self.retire_rem_cids(&retired) {
            self.defer_error(error);
        }
        self.qlog_remote_cid_updated(now, old_cid);
        self.qlog_candidate_state(
            now,
            candidate.seq,
            candidate.remote,
            MigrationState::ProbingSuccessful,
        );
        let local = self.path.local;
        self.migrate(now, candidate.remote, local, PreviousPath::Discard);
        // The candidate answered our challenge, so the path it stands for needs no validation.
        self.path.challenge = None;
        self.path.validated = true;
        // The probe that was answered is padded to `MIN_INITIAL_SIZE`, so this address has
        // shown it carries one.
        self.path.mtu_validated = true;
        self.timers.stop(Timer::PathValidation);
        self.set_reset_token(candidate.remote, token);
        self.preferred_state = PreferredAddressState::Validated;
        self.qlog_migration_state(now, MigrationState::MigrationComplete);
        debug!(remote = %candidate.remote, "moved to the server's preferred address");
    }
}

/// The sequence number a server binds to its preferred address (RFC 9000 §5.1.1).
const PREFERRED_ADDRESS_CID_SEQ: u64 = 1;

/// How many PATH_CHALLENGE probes are transmitted towards a preferred address before the attempt
/// is given up.
const MAX_PREFERRED_PROBES: usize = 3;

/// What became of the address a server advertised as preferred (RFC 9000 §9.6).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum PreferredAddressState {
    /// None was advertised for the family in use, it is the address already in use, or the client
    /// declined it.
    Unused,
    /// Advertised; probing starts once the handshake is confirmed.
    Armed,
    /// A probe is outstanding.
    Probing,
    /// A probe was answered and the connection moved there.
    Validated,
    /// The attempt ended without a usable path; the connection stays where it was.
    Failed,
}

/// A client's attempt at the server's preferred address (RFC 9000 §9.6.2): a path of its own,
/// probed with an identifier no other path is sent with.
pub(super) struct PreferredCandidate {
    pub(super) remote: SocketAddr,
    /// The identifier reserved for this path.
    cid: ConnectionId,
    /// Its sequence number. The token that resets this connection from this path once a probe
    /// has been transmitted (RFC 9000 §10.3.1) is kept with the identifier itself.
    seq: u64,
    /// Challenge data of the probes the network has taken, and how many that is.
    sent: [u64; MAX_PREFERRED_PROBES],
    transmitted: usize,
    /// Challenge data waiting for a datagram.
    pub(super) pending: Option<u64>,
    /// Challenge data written into a datagram the sender has not taken yet. It counts, and its
    /// identifier becomes one we have used, only once the sender reports it gone.
    in_flight: Option<u64>,
    /// Whether the first probe has been handed to the sender.
    qlog_started: bool,
}

impl PreferredCandidate {
    /// Whether this response's data belongs to one of our probes. A response validates the path
    /// its challenge went out on, whichever path it arrives on (RFC 9000 §8.2.3). A probe the
    /// sender has not reported counts here: an answer to it is proof enough that it went out.
    pub(super) fn matches(&self, token: u64) -> bool {
        self.in_flight == Some(token)
            || self
                .sent
                .get(..self.transmitted)
                .is_some_and(|sent| sent.contains(&token))
    }

    /// Whether a probe is waiting for a datagram or for the sender to take one.
    fn outstanding(&self) -> bool {
        self.pending.is_some() || self.in_flight.is_some()
    }
}
