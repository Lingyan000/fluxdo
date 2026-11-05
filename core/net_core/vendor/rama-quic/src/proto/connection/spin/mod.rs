//! Optional, passive latency signaling (RFC 9000 §17.4), independent of recovery.

use std::net::SocketAddr;

use rama_net::address::ip::IntoCanonicalIpAddr as _;
use rama_quic_proto::ConnectionId;
use rand::RngExt as _;

use super::Connection;

#[cfg(test)]
#[cfg(any(
    feature = "boring",
    all(feature = "rustls", any(feature = "ring", feature = "aws-lc"))
))]
mod tests;

/// A path keeps its packet-number watermark across CID changes. Resetting that watermark
/// would let a reordered packet restore the signal that the CID change just cleared.
#[derive(Debug, Default)]
pub(super) struct Spin {
    pub(super) value: bool,
    highest: Option<u64>,
    sent_cid: Option<ConnectionId>,
}

impl Spin {
    fn receive(&mut self, number: u64, spin: bool, invert: bool) {
        if self.highest.is_some_and(|highest| number <= highest) {
            return;
        }
        self.highest = Some(number);
        self.value = invert ^ spin;
    }

    fn change_cid(&mut self, cid: ConnectionId) {
        if self.sent_cid.is_some_and(|previous| previous != cid) {
            self.value = false;
        }
        self.sent_cid = Some(cid);
    }

    fn send(&mut self, cid: ConnectionId) -> bool {
        if self.sent_cid.is_some_and(|previous| previous != cid) {
            self.change_cid(cid);
        }
        self.sent_cid = Some(cid);
        self.value
    }
}

#[derive(Debug)]
pub(super) struct PathSpin {
    remote: SocketAddr,
    local: Option<SocketAddr>,
    state: Spin,
}

impl PathSpin {
    fn matches(&self, remote: SocketAddr, local: Option<SocketAddr>) -> bool {
        self.remote == remote && self.local == local
    }
}

/// A wildcard-bound sender still identifies its local port. Preserve that information so
/// a delayed packet from a replaced socket cannot update the replacement's signal.
fn same_local(known: Option<SocketAddr>, reported: Option<SocketAddr>) -> bool {
    match (known, reported) {
        (Some(known), Some(reported)) => {
            known == reported
                || (known.ip().is_unspecified()
                    && known.port() == reported.port()
                    && (known.is_ipv6() || reported.is_ipv4()))
        }
        _ => true,
    }
}

impl Connection {
    #[cfg(any(
        feature = "test-utils",
        all(
            test,
            any(
                feature = "boring",
                all(feature = "rustls", any(feature = "ring", feature = "aws-lc"))
            )
        )
    ))]
    pub(crate) fn spin_enabled_for_test(&self) -> bool {
        self.spin_enabled
    }

    /// Sender provenance for clients whose transport path has no local address. This is
    /// deliberately separate from routing, path validation and recovery state.
    pub(crate) fn set_spin_local_address(&mut self, local: Option<SocketAddr>) {
        self.spin_local = local.map(|address| address.into_canonical_ip_addr());
    }

    pub(super) fn spin_cid_changed(
        &mut self,
        remote: SocketAddr,
        local: Option<SocketAddr>,
        cid: ConnectionId,
    ) {
        if self.spin_enabled {
            self.spin_path(remote, local).change_cid(cid);
        }
    }

    pub(super) fn reset_current_spin(&mut self) {
        if self.spin_enabled {
            self.spin_path(self.path.remote, self.path.local).value = false;
        }
    }

    /// Only live paths retain state: current, previous, either candidate, bound off-path
    /// CIDs, and queued PATH_RESPONSE destinations. Those collections already have fixed
    /// bounds (at most 22 distinct paths); a packet being handled can add one more.
    /// Unknown local addresses match the transport's `same_local` convention.
    fn spin_path(&mut self, remote: SocketAddr, local: Option<SocketAddr>) -> &mut Spin {
        // Use the transport's canonical local address for an owned path. In particular,
        // an abstract socket with no local-address provenance must not turn each reported
        // address into another retained entry matching the same unknown current path.
        let current_local = self.path.local.or(self.spin_local);
        let local = if remote == self.path.remote && same_local(current_local, local) {
            current_local
        } else if let Some(prev) = self.prev_path.as_ref()
            && prev.path.remote == remote
            && same_local(prev.path.local, local)
        {
            prev.path.local
        } else if self
            .candidate
            .as_ref()
            .is_some_and(|candidate| candidate.remote == remote)
            && same_local(current_local, local)
        {
            current_local
        } else {
            local
        };
        self.spins.retain(|path| {
            path.matches(remote, local)
                || path.matches(self.path.remote, current_local)
                || self
                    .prev_path
                    .as_ref()
                    .is_some_and(|prev| path.matches(prev.path.remote, prev.path.local))
                || self
                    .candidate
                    .as_ref()
                    .is_some_and(|candidate| path.matches(candidate.remote, current_local))
                || self
                    .server_candidate
                    .as_ref()
                    .is_some_and(|candidate| path.matches(candidate.remote, candidate.local))
                || self
                    .path_cids
                    .iter()
                    .flatten()
                    .any(|bound| path.matches(bound.remote, bound.local))
                || self.path_responses.contains_path(path.remote, path.local)
        });
        let index = if let Some(index) = self
            .spins
            .iter()
            .position(|path| path.matches(remote, local))
        {
            index
        } else {
            let index = self.spins.len();
            self.spins.push(PathSpin {
                remote,
                local,
                state: Spin::default(),
            });
            debug_assert!(
                self.spins.len() <= 23,
                "spin paths follow bounded transport roles"
            );
            index
        };
        &mut self.spins[index].state
    }

    /// Called only for authenticated, nonduplicate 1-RTT packets accepted by frame dispatch.
    pub(super) fn receive_spin(
        &mut self,
        remote: SocketAddr,
        local: Option<SocketAddr>,
        number: u64,
        spin: bool,
    ) {
        if !self.spin_enabled {
            return;
        }
        let invert = self.side.is_client();
        self.spin_path(remote, local).receive(number, spin, invert);
    }

    /// The comparison is a final guard for off-path sending roles. Active and reserved CID
    /// changes also reset eagerly, before a subsequent reception can update the signal.
    pub(super) fn send_spin(
        &mut self,
        remote: SocketAddr,
        local: Option<SocketAddr>,
        cid: ConnectionId,
    ) -> bool {
        if !self.spin_enabled {
            return self.rng.random();
        }
        self.spin_path(remote, local).send(cid)
    }
}
