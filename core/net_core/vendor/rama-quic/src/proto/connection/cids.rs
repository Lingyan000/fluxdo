//! Connection identifiers and the reset tokens bound to them: issuing this side's, retiring
//! the peer's, and keeping the endpoint's routing table in step with both.

use std::{net::SocketAddr, ops::Range};

use rama_core::telemetry::tracing::debug;

use crate::proto::{
    Instant,
    cid_queue::{OwnedRemotes, Retired, RouteDelta},
    connection::{Connection, ConnectionError, ConnectionSide},
    shared::EndpointEventInner,
    transport_parameters,
};
use rama_quic_proto::{ConnectionId, ResetToken, TransportError, frame::Close, packet::SpaceId};

#[cfg(test)]
use rama_quic_proto::frame;

impl Connection {
    /// The identifier this endpoint's generator made for the handshake. Later ones are issued
    /// as the connection runs and this one is eventually retired, so it names the connection
    /// rather than saying what a peer sends to now.
    pub(crate) fn initial_local_id(&self) -> ConnectionId {
        self.handshake_cid
    }

    /// The reset tokens that can reset this connection: the identifiers it sends with, which are
    /// the active one, one kept for a previous path, and one a probe has already gone out with
    /// (RFC 9000 §10.3.1).
    pub(super) fn used_reset_tokens(
        &self,
        remote: SocketAddr,
    ) -> impl Iterator<Item = ResetToken> + '_ {
        // Every identifier carries its own history, per address it was sent to, so this is simply
        // the ones a datagram has gone out with towards `remote`. A change of role neither grants
        // nor erases that, and a token used only at another address is not ours here
        // (RFC 9000 §10.3.1).
        self.rem_cids.used_reset_tokens(remote)
    }

    pub(crate) fn remote_cid_limit(&self) -> usize {
        self.rem_cids.limit()
    }

    /// Queue RETIRE_CONNECTION_ID for the identifiers in `retired` and forget their reset tokens,
    /// through the bounded queue: a peer that keeps us retiring cannot make it grow without end,
    /// and the connection fails with the protocol's own error when the bound is reached.
    pub(super) fn retire_rem_cids(&mut self, retired: &Retired) -> Result<(), TransportError> {
        for range in retired.iter() {
            self.spaces[SpaceId::Data]
                .pending
                .retire_cids_with_limit(range.clone(), self.rem_cids.limit())?;
            self.note_retired(range);
        }
        Ok(())
    }

    /// The same for the one identifier a path change lets go of.
    pub(super) fn retire_rem_cid(&mut self, seq: u64) -> Result<(), TransportError> {
        self.spaces[SpaceId::Data]
            .pending
            .retire_cids_with_limit(seq..seq + 1, self.rem_cids.limit())?;
        self.note_retired(seq..seq + 1);
        Ok(())
    }

    /// Close with a protocol error raised where the caller could not return one.
    ///
    /// This does not depend on there being a datagram to build: a connection whose send is held
    /// waiting for a route that will never exist has to close with its cause all the same, so the
    /// driver calls this every time it runs, before it retries anything it has buffered.
    pub(crate) fn settle_deferred_error(&mut self, now: Instant) {
        let Some(error) = self.deferred_error.take() else {
            return;
        };
        // The peer is told with the frame this error names, and the application is told the cause:
        // closing locally must not leave the connection to be reported later as an engine that
        // drained without a reason.
        let reason = ConnectionError::TransportError(error.clone());
        self.close_inner(now, Close::Connection(error.into()));
        if self.error.is_none() {
            self.error = Some(reason);
        }
    }

    /// Tests: refuse a retirement too wide to queue and carry the error the way every production
    /// site does, so the notification path can be exercised without arranging a full queue.
    #[cfg(test)]
    pub(crate) fn overflow_retirement_queue(&mut self) {
        if let Err(error) = self.spaces[SpaceId::Data].pending.retire_cids(0..u64::MAX) {
            self.defer_error(error);
        } else {
            panic!("a retirement of every sequence number should not be queued");
        }
    }

    /// Carry a protocol error out of a path that cannot return one; the first one wins, and the
    /// connection closes with it at the next transmit rather than losing what produced it.
    pub(super) fn defer_error(&mut self, error: TransportError) {
        debug!(%error, "deferring a protocol error to the next transmit");
        if self.deferred_error.is_none() {
            self.deferred_error = Some(error);
        }
    }

    /// Tell the endpoint that the reset tokens of these retired identifiers no longer count.
    fn note_retired(&mut self, retired: Range<u64>) {
        if !retired.is_empty() {
            self.endpoint_events
                .push_back(EndpointEventInner::ResetTokensRetired(retired));
        }
    }

    /// Tests: apply one NEW_CONNECTION_ID as if it had arrived in a packet, so the path from the
    /// frame through the identifiers it retires to the retirement queue runs as it does then.
    #[cfg(test)]
    pub(crate) fn apply_new_cid(
        &mut self,
        now: Instant,
        frame: frame::NewConnectionId,
    ) -> Result<(), TransportError> {
        self.handle_new_cid(now, frame)
    }

    /// Tests: the sequence numbers waiting to be sent as RETIRE_CONNECTION_ID.
    #[cfg(test)]
    pub(crate) fn pending_retirements(&self) -> Vec<u64> {
        self.spaces[SpaceId::Data].pending.retire_cids.clone()
    }

    /// Switch to a previously unused remote connection ID, if possible; `false` when none is
    /// available (nothing changes).
    pub(super) fn update_rem_cid(&mut self, now: Instant) -> bool {
        let old = self.rem_cids.active();
        let Some((reset_token, retired)) = self.rem_cids.next() else {
            return false;
        };

        // Retire the current remote CID and any CIDs we had to skip.
        if let Err(error) = self.retire_rem_cids(&retired) {
            self.defer_error(error);
        }
        self.active_cid_left();
        self.set_reset_token(self.path.remote, reset_token);
        self.qlog_remote_cid_updated(now, old);
        self.reset_current_spin();
        self.spin_cid_changed(self.path.remote, self.path.local, self.rem_cids.active());
        true
    }

    /// The active remote connection ID is now sent to `remote`: a stateless reset from there
    /// carrying `reset_token` is ours.
    pub(super) fn set_reset_token(&mut self, remote: SocketAddr, reset_token: ResetToken) {
        let seq = self.rem_cids.active_seq();
        // The endpoint routes a reset carrying this token to us from now on; whether we treat it
        // as ours waits for a datagram with this identifier to have gone out, which the identifier
        // itself records.
        self.install_reset_route(seq, remote);
        self.peer_params.stateless_reset_token = Some(reset_token);
    }

    /// Tell the endpoint that the identifier with this sequence number is being sent to `remote`,
    /// so a stateless reset from there carrying its token reaches this connection.
    /// Install the route a reset for the identifier numbered `seq` at `remote` would arrive by,
    /// before anything is sent with it.
    pub(super) fn install_reset_route(&mut self, seq: u64, remote: SocketAddr) {
        let generation = self.reset_generation;
        let owned = self.owned_remotes();
        match self.rem_cids.install_route(seq, remote, generation, owned) {
            Ok(Some((delta, token))) => self.apply_route_delta(seq, token, delta, generation),
            Ok(None) => {}
            Err(_) => self.defer_error(TransportError::INTERNAL_ERROR(
                "no room to record a connection ID's route",
            )),
        }
    }

    /// The peer has named this identifier's token: every address it has already been sent to needs
    /// its route installed, and none of them counts as installed until the endpoint says so.
    pub(super) fn announce_reset_routes(&mut self, seq: u64) {
        let (announced, token) = self.rem_cids.announce_routes(seq, self.reset_generation);
        let Some(token) = token else {
            return;
        };
        for assoc in announced.into_iter().flatten() {
            if let Some(installation) = assoc.generation() {
                self.note_reset_token(assoc.remote, seq, token, installation);
                // One name per installation, counted the same way everywhere else.
                self.reset_generation = self.reset_generation.wrapping_add(1);
            }
        }
    }

    /// The addresses a path role owns right now: where the current path sends, and where a
    /// retained previous or fallback path answers from. Nothing else is protected from being
    /// displaced by a newer address.
    pub(super) fn owned_remotes(&self) -> OwnedRemotes {
        OwnedRemotes {
            current: Some(self.path.remote),
            fallback: self.prev_path.as_ref().map(|prev| prev.path.remote),
        }
    }

    /// Tell the endpoint what changed about one identifier's routes: the route it stopped using
    /// goes before the one that displaced it arrives, so the endpoint never holds more than the
    /// engine does.
    pub(super) fn apply_route_delta(
        &mut self,
        seq: u64,
        token: ResetToken,
        delta: RouteDelta,
        generation: u64,
    ) {
        if let Some(released) = delta.released
            && let Some(installed) = released.generation()
        {
            self.release_reset_token(released.remote, seq, token, installed);
        }
        if let Some(added) = delta.added
            && let Some(installation) = added.generation()
        {
            self.note_reset_token(added.remote, seq, token, installation);
            if installation == generation {
                self.reset_generation = generation.wrapping_add(1);
            }
        }
    }

    fn note_reset_token(
        &mut self,
        remote: SocketAddr,
        seq: u64,
        reset_token: ResetToken,
        generation: u64,
    ) {
        self.endpoint_events
            .push_back(EndpointEventInner::ResetTokenUsed(
                remote,
                seq,
                reset_token,
                generation,
            ));
    }

    /// Tell the endpoint an association is no longer ours, naming the installation it belongs to
    /// so a newer one that reuses the same identifier and address is left alone.
    fn release_reset_token(
        &mut self,
        remote: SocketAddr,
        seq: u64,
        reset_token: ResetToken,
        generation: u64,
    ) {
        self.endpoint_events
            .push_back(EndpointEventInner::ResetTokenReleased(
                remote,
                seq,
                reset_token,
                generation,
            ));
    }

    /// Issue an initial set of connection IDs to the peer upon connection
    pub(super) fn issue_first_cids(&mut self, now: Instant) {
        if self.local_cid_state.cid_len() == 0 {
            return;
        }

        // Subtract 1 to account for the CID we supplied while handshaking
        let mut n = transport_parameters::issue_cids_limit(&self.peer_params) - 1;
        if let ConnectionSide::Server { server_config } = &self.side
            && server_config.has_preferred_address()
        {
            // We also sent a CID in the transport parameters
            n -= 1;
        }
        self.endpoint_events
            .push_back(EndpointEventInner::NeedIdentifiers(now, n));
    }

    #[cfg(test)]
    pub(crate) fn active_local_cid_seq(&self) -> (u64, u64) {
        self.local_cid_state.active_seq()
    }

    /// Instruct the peer to replace previously issued CIDs by sending a NEW_CONNECTION_ID frame
    /// with updated `retire_prior_to` field set to `v`
    #[cfg(test)]
    pub(crate) fn rotate_local_cid(&mut self, v: u64, now: Instant) {
        let n = self.local_cid_state.assign_retire_seq(v);
        self.endpoint_events
            .push_back(EndpointEventInner::NeedIdentifiers(now, n));
    }

    /// Check the current active remote CID sequence
    #[cfg(test)]
    pub(crate) fn active_rem_cid_seq(&self) -> u64 {
        self.rem_cids.active_seq()
    }
}
