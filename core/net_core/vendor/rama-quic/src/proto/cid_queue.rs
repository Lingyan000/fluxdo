use rama_quic_proto::{ConnectionId, ResetToken, TransportError, frame::NewConnectionId};
use rama_utils::collections::smallvec::{SmallVec, smallvec};
use std::net::SocketAddr;
use std::ops::Range;

/// A remote connection ID with its sequence number and, unless it is the initial one before the
/// peer's transport parameters arrived, its stateless reset token.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) struct RemCid {
    pub(crate) seq: u64,
    pub(crate) id: ConnectionId,
    pub(crate) reset_token: Option<ResetToken>,
    /// The addresses this identifier has a route to, least recently used first.
    ///
    /// RFC 9000 §10.3.1 ties recognition to the identifier and the address it was sent to, so
    /// this is a set rather than a flag. It lives with the identifier, so moving one between the
    /// active, held, reserved, bound and unused sets neither grants nor removes history;
    /// retirement drops the value and ends it. [`REMOTES`](Self::REMOTES) addresses are kept, and
    /// a further address displaces the oldest one no path role owns.
    sent_to: [Option<Association>; Self::REMOTES],
}

/// One route to this connection: an identifier at an address.
///
/// The generation names this installation, so an acknowledgement or a release that was in flight
/// cannot be applied to a later installation that happens to reuse the same identifier and
/// address.
#[derive(Debug, Copy, Clone, PartialEq, Eq)]
pub(crate) struct Association {
    pub(crate) remote: SocketAddr,
    /// Where this route stands with the endpoint. One value, so that learning a token, being
    /// confirmed and being replaced cannot disagree with each other.
    state: RouteState,
    /// Whether a datagram carrying this identifier has actually reached the network for `remote`.
    /// Independent of the route's state, and never taken away except by retirement: what has been
    /// sent has been sent, whatever happens to the route afterwards (RFC 9000 §10.3.1).
    sent: bool,
}

/// Where the route for one identifier at one address stands.
#[derive(Debug, Copy, Clone, PartialEq, Eq)]
enum RouteState {
    /// The peer has named no token for this identifier, so there is no route for a reset to
    /// arrive by and nothing to install or wait for. The handshake sends like this.
    NoneRequired,
    /// The endpoint has been asked to install this route and has not confirmed it. A datagram
    /// carrying this identifier waits: a reset answering it must not be able to arrive before
    /// there is anything to route it by.
    Pending(u64),
    /// The endpoint has confirmed this installation.
    Installed(u64),
}

/// Why a route could not be recorded. Both are unreachable while at most two path roles own an
/// identifier and three addresses are kept, so each is reported as a failure rather than handled
/// by eviction or ignored.
#[derive(Debug, Copy, Clone, PartialEq, Eq)]
pub(crate) enum RouteError {
    /// Every address is owned by a live path role, so there is nothing that may be displaced.
    NoRoom,
    /// The records are not packed as this code requires: one was found and then was not there.
    Unpacked,
}

impl RouteState {
    /// The installation this state names, if any.
    fn generation(self) -> Option<u64> {
        match self {
            Self::NoneRequired => None,
            Self::Pending(generation) | Self::Installed(generation) => Some(generation),
        }
    }
}

impl Association {
    /// The installation this route names, if any.
    pub(crate) fn generation(&self) -> Option<u64> {
        self.state.generation()
    }
}

/// What the endpoint's routing has to be told after a route was touched. Both fields empty means
/// nothing changed, which is the case for every ordinary send and every retry of one.
#[derive(Debug, Copy, Clone, PartialEq, Eq, Default)]
pub(crate) struct RouteDelta {
    /// A route the endpoint does not have yet.
    pub(crate) added: Option<Association>,
    /// A route displaced by `added`, whose address had gone longest without a send.
    pub(crate) released: Option<Association>,
}

impl RouteDelta {
    pub(crate) fn is_empty(&self) -> bool {
        self.added.is_none() && self.released.is_none()
    }
}

/// The addresses a path role currently owns for an identifier: the address the current path sends
/// to, and the one a retained previous or fallback path answers from.
///
/// Recency does not decide what is still live: moving off a path that was never validated keeps
/// the original as the fallback, so the intermediate address is the one no longer in use. An
/// association a role owns is never displaced.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub(crate) struct OwnedRemotes {
    pub(crate) current: Option<SocketAddr>,
    pub(crate) fallback: Option<SocketAddr>,
}

impl OwnedRemotes {
    pub(crate) fn owns(&self, remote: SocketAddr) -> bool {
        self.current == Some(remote) || self.fallback == Some(remote)
    }
}

impl RemCid {
    /// How many addresses one identifier can be recognised at, derived from the roles that can
    /// own it at once: the current path, a retained previous or fallback path, and one address
    /// that is neither but that a descriptor already accepted in part was sent to. A fourth would
    /// mean a role we do not have.
    pub(crate) const REMOTES: usize = 3;

    /// The token a stateless reset from `remote` must carry to reset us with this identifier, or
    /// `None` when nothing has gone out with it towards that address.
    pub(crate) fn used_reset_token(&self, remote: SocketAddr) -> Option<ResetToken> {
        self.reset_token.filter(|_| self.is_sent_to(remote))
    }

    #[cfg(test)]
    /// Whether a datagram carrying this identifier has gone out at all.
    pub(crate) fn is_sent(&self) -> bool {
        self.associations().any(|assoc| assoc.sent)
    }

    /// Whether a datagram carrying this identifier has gone out towards `remote`.
    pub(crate) fn is_sent_to(&self, remote: SocketAddr) -> bool {
        self.associations()
            .any(|assoc| assoc.remote == remote && assoc.sent)
    }

    /// How many of the slots hold a route. They are kept packed from the front, so this is also
    /// where the next one goes.
    fn filled(&self) -> usize {
        self.sent_to
            .iter()
            .position(Option::is_none)
            .unwrap_or(Self::REMOTES)
    }

    /// Whether this identifier may be sent to `remote`: the route has to exist first, and an
    /// identifier with no token has no route to wait for.
    pub(crate) fn is_installed_for(&self, remote: SocketAddr) -> bool {
        if self.reset_token.is_none() {
            // No token means no route for a reset to arrive by, so there is nothing to wait for.
            return true;
        }
        // With the token known, this address requires a route the endpoint has confirmed. No
        // record, a pending one, or one from before the token was known all fail this.
        self.sent_to
            .iter()
            .flatten()
            .find(|assoc| assoc.remote == remote)
            .is_some_and(|assoc| matches!(assoc.state, RouteState::Installed(_)))
    }

    /// The addresses this identifier is recognised at, least recently used first.
    pub(crate) fn associations(&self) -> impl Iterator<Item = Association> + '_ {
        self.sent_to.iter().flatten().copied()
    }

    /// Make sure this identifier has a route to `remote`, and say what the endpoint has to be
    /// told. `sent` records that a datagram has actually reached the network for it; installing a
    /// route does not, and cannot un-send what already has.
    ///
    /// `generation` names a new installation and is only consumed by one.
    /// `Err` when there was nowhere to record it, which the caller has to treat as a failure and
    /// not as nothing to do.
    fn route_to(
        &mut self,
        remote: SocketAddr,
        generation: u64,
        sent: bool,
        token_known: bool,
        owned: OwnedRemotes,
    ) -> Result<RouteDelta, RouteError> {
        if let Some(at) = self
            .sent_to
            .iter()
            .position(|slot| slot.is_some_and(|assoc| assoc.remote == remote))
        {
            // This address is in use, so it is the other one that is next to give way. Only the
            // filled slots rotate: they are kept packed, oldest first.
            let filled = self.filled();
            self.sent_to[at..filled].rotate_left(1);
            // The refreshed route is now the most recent of the filled slots.
            let Some(assoc) = self.sent_to.get_mut(filled - 1).and_then(Option::as_mut) else {
                // `at` named a filled slot, so rotating within the filled prefix has to leave one
                // there. A missing record is not a successful no-change.
                return Err(RouteError::Unpacked);
            };
            assoc.sent |= sent;
            if token_known && assoc.state == RouteState::NoneRequired {
                // The peer has named this identifier's token since this route was recorded. What
                // is new is the route, not the use: it goes to the endpoint now, it is *not*
                // installed until that is confirmed, and the history it already earned stays.
                assoc.state = RouteState::Pending(generation);
                return Ok(RouteDelta {
                    added: Some(*assoc),
                    released: None,
                });
            }
            return Ok(RouteDelta::default());
        }
        let added = Association {
            remote,
            sent,
            state: if token_known {
                RouteState::Pending(generation)
            } else {
                RouteState::NoneRequired
            },
        };
        let filled = self.filled();
        if let Some(slot) = self.sent_to.get_mut(filled) {
            *slot = Some(added);
            return Ok(RouteDelta {
                added: token_known.then_some(added),
                released: None,
            });
        }
        // Bounded: something has to give way, and it must not be an address a path role still
        // owns. The oldest unowned one goes, which is the address that stopped being relevant.
        //
        // At most two roles own an address at once and there are three slots, so an unowned one
        // always exists. If that ever stops holding, nothing is displaced and the caller is told,
        // rather than this quietly dropping a route a live path depends on.
        let Some(victim) = self
            .sent_to
            .iter()
            .position(|slot| slot.is_some_and(|assoc| !owned.owns(assoc.remote)))
        else {
            return Err(RouteError::NoRoom);
        };
        let released = self.sent_to[victim]
            .replace(added)
            // A route the endpoint was never told about has nothing to release.
            .filter(|released| released.state != RouteState::NoneRequired);
        // The new one is the most recent, and the rest keep their order.
        self.sent_to[victim..].rotate_left(1);
        Ok(RouteDelta {
            added: token_known.then_some(added),
            released,
        })
    }
}

/// Missing sequence numbers in a window bounded by the active CID limit (at most 64).
/// Kept as bits so retirement never needs a scratch allocation for disjoint runs.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) struct Skipped {
    start: u64,
    missing: u64,
}

impl Skipped {
    pub(crate) fn iter(self) -> impl Iterator<Item = Range<u64>> {
        let mut missing = self.missing;
        std::iter::from_fn(move || {
            if missing == 0 {
                return None;
            }
            let offset = missing.trailing_zeros();
            let length = (missing >> offset).trailing_ones();
            missing &= u64::MAX.checked_shl(offset + length).unwrap_or(0);
            Some(self.start + u64::from(offset)..self.start + u64::from(offset + length))
        })
    }
}

/// The identifiers a peer's retirement took out of the sets kept aside for paths.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct RetiredAside {
    /// The one kept for a previous path.
    pub(crate) held: Option<u64>,
    /// The one set aside for a candidate path.
    pub(crate) reserved: Option<u64>,
    /// The ones bound to a path of their own.
    pub(crate) bound: SmallVec<[u64; 8]>,
    /// Numbers the retirement covers that this connection never received. The peer holds them
    /// until RETIRE_CONNECTION_ID names them (RFC 9000 §5.1.2).
    pub(crate) skipped: Skipped,
}

impl RetiredAside {
    /// The ones kept for the previous and the candidate path, for assertions.
    #[cfg(test)]
    pub(crate) fn kept_aside(&self) -> [Option<u64>; 2] {
        assert!(
            self.bound.is_empty(),
            "an identifier bound to a path was retired: {:?}",
            self.bound
        );
        [self.held, self.reserved]
    }

    pub(crate) fn iter(&self) -> impl Iterator<Item = u64> + '_ {
        [self.held, self.reserved]
            .into_iter()
            .flatten()
            .chain(self.bound.iter().copied())
    }
}

/// Sequence numbers to retire after a switch of the active connection ID.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct Retired {
    /// The identifier that was active (empty when it is kept aside instead).
    pub(crate) previous: Range<u64>,
    /// Numbers skipped on the way to the new active one: never received and not retired before,
    /// in runs around the identifiers the connection still holds.
    pub(crate) skipped: Skipped,
}

impl Retired {
    pub(crate) fn iter(&self) -> impl Iterator<Item = Range<u64>> {
        std::iter::once(self.previous.clone())
            .chain(self.skipped.iter())
            .filter(|range| !range.is_empty())
    }

    /// Whether nothing is retired.
    #[cfg(test)]
    pub(crate) fn is_empty(&self) -> bool {
        self.iter().next().is_none()
    }

    /// The skipped numbers, for assertions.
    #[cfg(test)]
    pub(crate) fn skipped(&self) -> Vec<u64> {
        self.skipped.iter().flatten().collect()
    }
}

/// The remote connection IDs the peer issued and we have not retired (RFC 9000 §5.1).
///
/// Every identifier is bound to at most one path: the active one is sent on the current path,
/// a held one stays with the previous path while the current one is validated, a reserved one is
/// set aside for a candidate path, and the unused ones wait for their turn. All of them count
/// towards the limit we advertised to the peer, and only those: a sequence number we never
/// received costs nothing, so a peer that leaves gaps as paths come and go does not shrink the
/// window it may fill.
#[derive(Debug)]
pub(crate) struct CidQueue {
    /// The limit advertised on this connection, independently of storage capacity.
    limit: usize,
    active: RemCid,
    held: Option<RemCid>,
    reserved: Option<RemCid>,
    /// Identifiers bound to a path of their own, so that an answer on a path this connection does
    /// not otherwise send on carries an identifier that is not sent anywhere else (RFC 9000 §9.5).
    bound: SmallVec<[Option<RemCid>; 8]>,
    /// Bounded by the limit: the active identifier takes one of the peer's slots.
    unused: SmallVec<[Option<RemCid>; 8]>,
    /// Every sequence number below this one is either present here or retired.
    floor: u64,
}

impl CidQueue {
    pub(crate) fn new(cid: ConnectionId, limit: u64) -> Result<Self, TransportError> {
        if !(2..=Self::LIMIT).contains(&limit) {
            return Err(TransportError::INTERNAL_ERROR(
                "unsupported local active CID limit",
            ));
        }
        Ok(Self {
            limit: limit as usize,
            active: RemCid {
                seq: 0,
                id: cid,
                reset_token: None,
                // The handshake sends with this one before the peer has named a token for it, so
                // its history begins when the first datagram is reported, like any other.
                sent_to: [None; RemCid::REMOTES],
            },
            held: None,
            reserved: None,
            bound: smallvec![None; (limit as usize).min(Self::INLINE_LIMIT)],
            unused: smallvec![None; (limit as usize).min(Self::INLINE_LIMIT)],
            floor: 0,
        })
    }

    fn present(&self) -> impl Iterator<Item = RemCid> + '_ {
        [Some(self.active), self.held, self.reserved]
            .into_iter()
            .chain(self.bound.iter().copied())
            .chain(self.unused.iter().copied())
            .flatten()
    }

    fn present_mut(&mut self) -> impl Iterator<Item = &mut RemCid> + '_ {
        [&mut self.active]
            .into_iter()
            .chain(self.held.iter_mut())
            .chain(self.reserved.iter_mut())
            .chain(self.bound.iter_mut().flatten())
            .chain(self.unused.iter_mut().flatten())
    }

    fn lowest_unused(&self) -> Option<(usize, RemCid)> {
        self.unused
            .iter()
            .enumerate()
            .filter_map(|(i, c)| c.map(|c| (i, c)))
            .min_by_key(|(_, c)| c.seq)
    }

    /// The never-received, not yet retired numbers between `previous` (exclusive) and `next`
    /// (exclusive): everything from the floor on, minus the identifiers kept aside.
    fn skipped_between(&self, previous: u64, next: u64) -> Skipped {
        self.skipped_from(previous, next, self.floor)
    }

    /// The same, from a floor the caller chooses. A frame that raises the floor still has to name
    /// the numbers below the new one it retires.
    fn skipped_from(&self, previous: u64, next: u64, floor: u64) -> Skipped {
        self.absent_runs((previous + 1).max(floor), next)
    }

    /// How far past `previous` the never-received numbers are named. A peer may issue a sequence
    /// number far beyond the last one, and naming every number in between would exceed any
    /// bounded retirement queue; the numbers past the bound are refused if they arrive, which is
    /// what retires them then.
    fn bounded_end(&self, previous: u64, end: u64) -> u64 {
        end.min(previous.saturating_add(self.limit as u64))
    }

    /// The numbers in `start..end` this queue does not hold, in runs around the ones it does.
    fn absent_runs(&self, start: u64, end: u64) -> Skipped {
        let width = end.saturating_sub(start);
        debug_assert!(width <= self.limit as u64);
        if width == 0 {
            return Skipped { start, missing: 0 };
        }
        // Every caller bounds this window by the negotiated limit (at most 64).
        // A bitset avoids both sorting scratch storage and repeated queue scans.
        let mut missing = u64::MAX >> (64 - width);
        for cid in self.present() {
            if (start..end).contains(&cid.seq) {
                missing &= !(1 << (cid.seq - start));
            }
        }
        Skipped { start, missing }
    }

    /// Everything below `seq` inclusive is now present or retired.
    fn retired_up_to(&mut self, seq: u64) {
        self.floor = self.floor.max(seq + 1);
    }

    /// Check identities before applying the frame's retirement side effects.
    /// RFC 9000 §19.15 permits rejecting conflicting reuse. Check only retained
    /// identifiers: remembering every retired value would allow unbounded growth.
    pub(crate) fn validate_identity(&self, cid: &NewConnectionId) -> Result<(), InsertError> {
        for previous in self.present() {
            if previous.seq == cid.sequence {
                if previous.id != cid.id
                    || previous
                        .reset_token
                        .is_some_and(|token| token != cid.reset_token)
                {
                    return Err(InsertError::InconsistentIdentity);
                }
            } else if previous.id == cid.id {
                return Err(InsertError::InconsistentIdentity);
            }
        }
        Ok(())
    }

    /// Handle a `NEW_CONNECTION_ID` frame
    ///
    /// Returns a non-empty range of retired sequence numbers and the reset token of the new active
    /// CID iff the frame retired the active one. An ID kept aside whose sequence the frame retires
    /// must be let go by the caller before this call ([`retire_aside`](Self::retire_aside)).
    pub(crate) fn insert(&mut self, cid: NewConnectionId) -> Result<Inserted, InsertError> {
        self.validate_identity(&cid)?;
        // A retransmitted or reordered copy of an identifier we hold still carries its
        // `retire_prior_to`; one we let go of already is refused.
        let floor_before = self.floor;
        let duplicate = self.present().any(|c| c.seq == cid.sequence);
        if !duplicate && cid.sequence < self.floor {
            return Err(InsertError::Retired);
        }
        // The peer may not leave us holding more identifiers than the limit we advertised. What
        // this frame retires does not count, and neither does a number we never received: a
        // connection that retires identifiers one at a time, as paths come and go, leaves gaps
        // that say nothing about how many the peer considers active. Counting what we hold is
        // what bounds us, and it is arithmetic that cannot wrap.
        let retire_prior_to = cid.retire_prior_to;
        let kept = self
            .present()
            .filter(|held| held.seq >= retire_prior_to && held.seq != cid.sequence)
            .count();
        if kept + 1 > self.limit {
            return Err(InsertError::ExceedsLimit);
        }

        // The initial identifier may not yet have a token from transport parameters.
        // Remember the first token so later repeats cannot silently change it.
        if duplicate {
            for previous in self.present_mut() {
                if previous.seq == cid.sequence && previous.reset_token.is_none() {
                    previous.reset_token = Some(cid.reset_token);
                }
            }
        }

        // Discard retired unused CIDs, if any. Which ones goes back to the caller: the peer
        // holds them until RETIRE_CONNECTION_ID names them. Report every removed identifier.
        let mut dropped = SmallVec::new();
        for slot in &mut self.unused {
            if let Some(cid) = slot.take_if(|c| c.seq < retire_prior_to) {
                dropped.push(cid.seq);
            }
        }
        // Record the new CID
        if !duplicate {
            let new = RemCid {
                seq: cid.sequence,
                id: cid.id,
                reset_token: Some(cid.reset_token),
                sent_to: [None; RemCid::REMOTES],
            };
            if self.unused.iter().all(Option::is_some) && self.unused.len() < self.limit {
                self.unused.push(None);
            }
            if let Some(slot) = self.unused.iter_mut().find(|slot| slot.is_none()) {
                *slot = Some(new);
            } else {
                // The bound above admits at most `limit` identifiers, one of them active.
                return Err(InsertError::ExceedsLimit);
            }
        }
        self.floor = self.floor.max(retire_prior_to);

        if self.active.seq >= retire_prior_to {
            return Ok(Inserted {
                dropped,
                switched: None,
            });
        }
        // The active CID was retired: switch to the lowest identifier at or past
        // `retire_prior_to` (at least the one just recorded is), and tell the caller which
        // sequence numbers that retires. Numbers never received beyond `limit` past the old active
        // one are left alone: had the peer issued them we would have hit the limit; should they
        // arrive later they are refused as retired then.
        let previous = self.active.seq;
        let Some((index, next)) = self.lowest_unused() else {
            return Err(InsertError::ExceedsLimit);
        };
        self.unused[index] = None;
        self.active = next;
        self.floor = self.floor.max(next.seq);
        let token = next.reset_token.ok_or(InsertError::ExceedsLimit)?;
        // Numbers never received beyond `limit` past the old active one are left alone; had the peer
        // issued them the limit would have been reached, and a late arrival is refused as retired.
        // Identifiers kept aside in that span are still ours and are not named as retired
        // (RFC 9000 §5.1.2).
        let end = self.bounded_end(previous, next.seq);
        let retired = Retired {
            previous: previous..previous + 1,
            skipped: self.skipped_from(previous, end, floor_before),
        };
        Ok(Inserted {
            dropped,
            switched: Some((retired, token)),
        })
    }

    /// Make the lowest unused identifier active; `keep_previous` puts the one that was active
    /// aside as held instead of retiring it.
    fn switch(&mut self, keep_previous: bool) -> Option<(ResetToken, Retired)> {
        if keep_previous && self.held.is_some() {
            return None;
        }
        let (index, next) = self.lowest_unused()?;
        let token = next.reset_token?;
        self.unused[index] = None;
        let previous = std::mem::replace(&mut self.active, next);
        // Numbers never received are named up to `limit` past the one that was active, as a frame's
        // retirement is: a distant identifier would otherwise name a span no retirement queue can
        // hold. Identifiers this connection holds are not in these runs at all, so nothing it
        // received is left unnamed, and a late arrival past the bound is refused as retired.
        let skipped = self.skipped_between(previous.seq, self.bounded_end(previous.seq, next.seq));
        let retired = Retired {
            previous: if keep_previous {
                self.held = Some(previous);
                previous.seq..previous.seq
            } else {
                previous.seq..previous.seq + 1
            },
            skipped,
        };
        self.retired_up_to(next.seq - 1);
        Some((token, retired))
    }

    /// Switch to next active CID if possible, return
    /// 1) the corresponding ResetToken and 2) the sequence numbers to retire
    pub(crate) fn next(&mut self) -> Option<(ResetToken, Retired)> {
        self.switch(false)
    }

    /// Switch to the next active CID while keeping the current one aside for the path it was used
    /// on. Fails when nothing is unused or an identifier is held already.
    pub(crate) fn next_holding(&mut self) -> Option<(ResetToken, Retired)> {
        self.switch(true)
    }

    /// The previously active ID kept for its path, if any.
    pub(crate) fn held(&self) -> Option<RemCid> {
        self.held
    }

    /// Let go of the held ID; the caller retires the returned sequence number.
    pub(crate) fn retire_held(&mut self) -> Option<u64> {
        let seq = self.held.take()?.seq;
        self.retired_up_to(seq);
        Some(seq)
    }

    /// Make the held ID active again (its path is current once more) and drop the ID that was
    /// active, which the caller retires: it was used towards a path now abandoned.
    pub(crate) fn restore_held(&mut self) -> Option<u64> {
        let held = self.held.take()?;
        let abandoned = std::mem::replace(&mut self.active, held);
        self.retired_up_to(abandoned.seq);
        Some(abandoned.seq)
    }

    /// Set the lowest unused ID aside for a candidate path. Fails when none is unused or one is
    /// already reserved.
    pub(crate) fn reserve(&mut self) -> Option<RemCid> {
        if self.reserved.is_some() {
            return None;
        }
        let (index, next) = self.lowest_unused()?;
        self.unused[index] = None;
        self.reserved = Some(next);
        Some(next)
    }

    /// Set the identifier with this sequence number aside for a candidate path, if it is still
    /// unused and nothing is reserved yet.
    pub(crate) fn reserve_seq(&mut self, seq: u64) -> Option<RemCid> {
        if self.reserved.is_some() {
            return None;
        }
        let index = self
            .unused
            .iter()
            .position(|c| c.is_some_and(|c| c.seq == seq))?;
        let cid = self.unused[index].take()?;
        self.reserved = Some(cid);
        Some(cid)
    }

    /// The ID reserved for a candidate path, if any.
    pub(crate) fn reserved(&self) -> Option<RemCid> {
        self.reserved
    }

    /// Give the reservation up; the caller retires the returned sequence number.
    pub(crate) fn release_reserved(&mut self) -> Option<u64> {
        let seq = self.reserved.take()?.seq;
        self.retired_up_to(seq);
        Some(seq)
    }

    /// Make the reserved ID the active one (its candidate path became the current path). Returns
    /// its reset token and the sequence numbers to retire: the ID that was active, and the
    /// never-received numbers between it and the promoted one.
    pub(crate) fn promote_reserved(&mut self) -> Option<(ResetToken, Retired)> {
        self.promote_reservation(false)
    }

    /// Promote a validated candidate while retaining the previous path's ID
    /// for the old-path check required by RFC 9000 §9.3.3.
    pub(crate) fn promote_reserved_holding(&mut self) -> Option<(ResetToken, Retired)> {
        self.promote_reservation(true)
    }

    fn promote_reservation(&mut self, keep_previous: bool) -> Option<(ResetToken, Retired)> {
        if keep_previous && self.held.is_some() {
            return None;
        }
        // A failed promotion must leave the reservation available for cleanup.
        let reserved = self.reserved?;
        let token = reserved.reset_token?;
        self.reserved = None;
        let previous = std::mem::replace(&mut self.active, reserved);
        // A reservation the ring has moved past leaves nothing in between, which the run
        // computation says by itself. Bounded like a switch.
        let skipped =
            self.skipped_between(previous.seq, self.bounded_end(previous.seq, reserved.seq));
        let retired = Retired {
            previous: if keep_previous {
                self.held = Some(previous);
                previous.seq..previous.seq
            } else {
                previous.seq..previous.seq + 1
            },
            skipped,
        };
        self.retired_up_to(previous.seq);
        self.retired_up_to(reserved.seq.saturating_sub(1));
        Some((token, retired))
    }

    /// Drop the aside IDs whose sequence a NEW_CONNECTION_ID frame retires (`retire_prior_to`),
    /// returning their sequence numbers for the caller to retire.
    pub(crate) fn retire_aside(&mut self, retire_prior_to: u64) -> RetiredAside {
        // What the retirement covers and this connection never received, computed before anything
        // is let go: the release below raises the floor over those numbers. Bounded like the
        // switch in `insert`: a peer that jumps its sequence numbers far ahead has the numbers
        // nearest the floor named, and a late arrival past that is refused as retired, which is
        // what retires it then. Naming the whole span instead would exceed the connection's
        // bounded retirement queue and close a connection over identifiers it never held.
        let end = self.bounded_end(self.floor, retire_prior_to);
        let skipped = self.absent_runs(self.floor, end);
        let held = self
            .held
            .take_if(|c| c.seq < retire_prior_to)
            .map(|c| c.seq);
        let reserved = self
            .reserved
            .take_if(|c| c.seq < retire_prior_to)
            .map(|c| c.seq);
        let mut bound = SmallVec::new();
        for slot in &mut self.bound {
            if let Some(cid) = slot.take_if(|c| c.seq < retire_prior_to) {
                bound.push(cid.seq);
            }
        }
        let aside = RetiredAside {
            held,
            reserved,
            bound,
            skipped,
        };
        for seq in aside.iter() {
            self.retired_up_to(seq);
        }
        // Everything the frame retires is now present, retired, or a number never received past
        // the bound above, which is refused if it arrives.
        self.floor = self.floor.max(retire_prior_to);
        aside
    }

    /// Take an unused identifier for a path of its own, leaving `keep` of them unused. It stops
    /// being unused and stays present, so it keeps counting towards the limit until it is
    /// retired; leaving some behind is what stops a path this connection does not send on from
    /// spending the identifiers a move of its own will need.
    pub(crate) fn bind_unused(&mut self, keep: usize) -> Option<RemCid> {
        if self.unused.iter().flatten().count() <= keep {
            return None;
        }
        if self.bound.iter().all(Option::is_some) && self.bound.len() < self.limit {
            self.bound.push(None);
        }
        let slot = self.bound.iter().position(Option::is_none)?;
        let (index, cid) = self.lowest_unused()?;
        self.unused[index] = None;
        self.bound[slot] = Some(cid);
        Some(cid)
    }

    /// Whether the identifier numbered `seq` is bound to a path of its own. A binding lasts until
    /// the peer retires the identifier ([`retire_aside`](Self::retire_aside)); nothing else lets
    /// it go, which is what keeps it from being sent from a second local address.
    pub(crate) fn is_bound(&self, seq: u64) -> bool {
        self.bound.iter().flatten().any(|c| c.seq == seq)
    }

    /// Replace the initial CID
    pub(crate) fn update_initial_cid(&mut self, cid: ConnectionId) {
        debug_assert_eq!(self.active.seq, 0);
        self.active.id = cid;
    }

    /// Record the reset token the peer's transport parameters gave for the initial CID.
    pub(crate) fn set_initial_reset_token(&mut self, token: ResetToken) {
        if self.active.seq == 0 {
            self.active.reset_token = Some(token);
        }
    }

    /// Whether a connection ID beyond the active one is available to switch to.
    pub(crate) fn has_unused(&self) -> bool {
        self.unused.iter().any(Option::is_some)
    }

    /// The unused identifiers, for assertions.
    #[cfg(test)]
    pub(crate) fn unused(&self) -> Vec<RemCid> {
        self.unused.iter().flatten().copied().collect()
    }

    /// Return active remote CID itself
    pub(crate) fn active(&self) -> ConnectionId {
        self.active.id
    }

    /// The reset token of the active remote CID, once known.
    pub(crate) fn active_reset_token(&self) -> Option<ResetToken> {
        self.active.reset_token
    }

    /// The reset tokens of the identifiers in use: the active one and the one held for the
    /// previous path. A reset carrying any of them is ours (RFC 9000 §10.3.1); the tokens of
    /// unused identifiers are not checked.
    /// The tokens that can reset this connection: one for every identifier a datagram has
    /// actually gone out with and that is not retired (RFC 9000 §10.3.1). An identifier that only
    /// changed role, or one moved aside before anything was sent with it, is not among them.
    pub(crate) fn used_reset_tokens(
        &self,
        remote: SocketAddr,
    ) -> impl Iterator<Item = ResetToken> + '_ {
        self.present()
            .filter_map(move |cid| cid.used_reset_token(remote))
    }

    pub(crate) fn limit(&self) -> usize {
        self.limit
    }

    /// How many associations this queue holds, which is what the endpoint's routing table has to
    /// be able to hold at once.
    #[cfg(test)]
    pub(crate) fn live_associations(&self) -> usize {
        self.present().map(|cid| cid.associations().count()).sum()
    }

    /// The endpoint has installed the route for `seq` at `remote`, when that is still the
    /// installation `generation` names. An acknowledgement for anything else is stale and does
    /// nothing: it cannot revive a retired identifier, nor open one a newer installation owns.
    pub(crate) fn route_installed(&mut self, seq: u64, remote: SocketAddr, generation: u64) {
        let Some(cid) = self.present_mut().find(|cid| cid.seq == seq) else {
            return;
        };
        for assoc in cid.sent_to.iter_mut().flatten() {
            // Only the installation that was asked for: an acknowledgement naming an older one
            // cannot open a route a newer installation owns, and one for an identifier that has
            // since been retired finds nothing at all.
            if assoc.remote == remote && assoc.state == RouteState::Pending(generation) {
                assoc.state = RouteState::Installed(generation);
            }
        }
    }

    /// The endpoint could not install the route for `seq` at `remote`. `true` when that was the
    /// installation still being waited on, which is a failure the connection has to act on; a
    /// refusal naming anything else is stale and is ignored.
    pub(crate) fn route_refused(&mut self, seq: u64, remote: SocketAddr, generation: u64) -> bool {
        let Some(cid) = self.present_mut().find(|cid| cid.seq == seq) else {
            return false;
        };
        cid.sent_to
            .iter()
            .flatten()
            .any(|assoc| assoc.remote == remote && assoc.state == RouteState::Pending(generation))
    }

    /// Whether a datagram carrying the identifier numbered `seq` may go to `remote` yet.
    pub(crate) fn is_installed(&self, seq: u64, remote: SocketAddr) -> bool {
        self.present()
            .find(|cid| cid.seq == seq)
            .is_some_and(|cid| cid.is_installed_for(remote))
    }

    /// Record that the sender has put a datagram carrying the identifier numbered `seq` on the
    /// network towards `remote`, wherever that identifier currently sits, and report what the
    /// endpoint's routing has to be told. `generation` names this installation.
    ///
    /// Nothing is reported for a send that changes nothing, so an ordinary send and a retried one
    /// publish nothing and allocate nothing.
    pub(crate) fn mark_sent(
        &mut self,
        seq: u64,
        remote: SocketAddr,
        generation: u64,
        owned: OwnedRemotes,
    ) -> Result<Option<(RouteDelta, ResetToken)>, RouteError> {
        self.route(seq, remote, generation, true, owned)
    }

    /// Every address the identifier numbered `seq` has a route to that the endpoint has not been
    /// told about, moved to pending under a generation of its own, starting at `generation`.
    ///
    /// This is what learning a token does: each address the identifier has already been sent to
    /// needs its route installed, not only the one in use, and none of them may be treated as
    /// installed until the endpoint says so.
    pub(crate) fn announce_routes(
        &mut self,
        seq: u64,
        mut generation: u64,
    ) -> ([Option<Association>; RemCid::REMOTES], Option<ResetToken>) {
        let mut announced = [None; RemCid::REMOTES];
        let Some(cid) = self.present_mut().find(|cid| cid.seq == seq) else {
            return (announced, None);
        };
        let Some(token) = cid.reset_token else {
            return (announced, None);
        };
        for (slot, assoc) in announced.iter_mut().zip(cid.sent_to.iter_mut().flatten()) {
            if assoc.state == RouteState::NoneRequired {
                assoc.state = RouteState::Pending(generation);
                *slot = Some(*assoc);
                generation = generation.wrapping_add(1);
            }
        }
        (announced, Some(token))
    }

    /// Install a route to `remote` for the identifier numbered `seq` without claiming anything
    /// has been sent with it, so that a reset cannot arrive before the endpoint can place it.
    pub(crate) fn install_route(
        &mut self,
        seq: u64,
        remote: SocketAddr,
        generation: u64,
        owned: OwnedRemotes,
    ) -> Result<Option<(RouteDelta, ResetToken)>, RouteError> {
        self.route(seq, remote, generation, false, owned)
    }

    fn route(
        &mut self,
        seq: u64,
        remote: SocketAddr,
        generation: u64,
        sent: bool,
        owned: OwnedRemotes,
    ) -> Result<Option<(RouteDelta, ResetToken)>, RouteError> {
        let Some(cid) = self.present_mut().find(|cid| cid.seq == seq) else {
            // Not an identifier we hold: retired, or never received. Nothing to record.
            return Ok(None);
        };
        let token = cid.reset_token;
        // An identifier whose token the peer has not named yet has no route to install; the
        // record is kept, so the route follows when the token arrives.
        let delta = cid.route_to(remote, generation, sent, token.is_some(), owned)?;
        match token {
            // Nothing for the endpoint to do, either because nothing changed or because there is
            // no token to route by yet.
            _ if delta.is_empty() => Ok(None),
            None => Ok(None),
            Some(token) => Ok(Some((delta, token))),
        }
    }

    #[cfg(test)]
    /// Whether a datagram carrying the identifier numbered `seq` has gone out. An identifier we do
    /// not hold has no history to report.
    pub(crate) fn is_sent(&self, seq: u64) -> bool {
        self.present().any(|cid| cid.seq == seq && cid.is_sent())
    }

    #[cfg(test)]
    /// Whether a datagram carrying the identifier numbered `seq` has gone out towards `remote`.
    pub(crate) fn is_sent_to(&self, seq: u64, remote: SocketAddr) -> bool {
        self.present()
            .any(|cid| cid.seq == seq && cid.is_sent_to(remote))
    }

    /// Return the sequence number of active remote CID
    pub(crate) fn active_seq(&self) -> u64 {
        self.active.seq
    }

    /// Maximum number of active remote connection IDs retained at once.
    ///
    /// Safari advertises 64. Storage stays inline for ordinary limits up to
    /// eight; larger profiles grow on demand as identifiers are retained.
    pub(crate) const LIMIT: u64 = 64;
    #[cfg(test)]
    pub(crate) const LEN: usize = Self::LIMIT as usize;

    /// Preserve the pre-Safari inline capacity for ordinary connections.
    pub(crate) const INLINE_LIMIT: usize = 8;
    pub(crate) const INLINE_PRESENT: usize = Self::INLINE_LIMIT;
}

/// What a NEW_CONNECTION_ID frame did to the queue.
#[derive(Debug, Default, Eq, PartialEq)]
pub(crate) struct Inserted {
    /// Unused identifiers the frame's `retire_prior_to` retired, for the caller to retire with the
    /// peer (RFC 9000 §5.1.2). A range cannot name them, since a promoted reservation leaves unused
    /// identifiers below the active one and only some of those are retired.
    pub(crate) dropped: SmallVec<[u64; 8]>,
    /// Set when the frame retired the active identifier: the sequence numbers that retires, and
    /// the reset token of the identifier that took its place.
    pub(crate) switched: Option<(Retired, ResetToken)>,
}

#[derive(Debug, Copy, Clone, Eq, PartialEq)]
pub(crate) enum InsertError {
    /// A retained identifier, sequence or reset-token association was reused inconsistently.
    InconsistentIdentity,
    /// CID was already retired
    Retired,
    /// Simultaneously retained identifiers exceed the advertised limit
    ExceedsLimit,
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::assert_matches;
    use std::collections::BTreeSet;

    fn cid(sequence: u64, retire_prior_to: u64) -> NewConnectionId {
        NewConnectionId {
            sequence,
            id: ConnectionId::new(&sequence.to_be_bytes()),
            reset_token: ResetToken::from([0xCD; rama_quic_proto::RESET_TOKEN_SIZE]),
            retire_prior_to,
        }
    }

    #[test]
    fn cid_identity_rejects_conflicting_repeats_before_retirement() {
        for role in 0..5 {
            for mutation in 0..3 {
                let mut queue = CidQueue::new(initial_cid(), CidQueue::LIMIT).unwrap();
                let original = cid_token(1, 0);
                queue.insert(original).unwrap();
                queue.insert(cid_token(2, 0)).unwrap();
                match role {
                    0 => {} // Still unused.
                    1 => {
                        queue.next().unwrap();
                    }
                    2 => {
                        queue.next().unwrap();
                        queue.next_holding().unwrap();
                    }
                    3 => {
                        assert_eq!(queue.reserve().unwrap().seq, 1);
                    }
                    _ => {
                        assert_eq!(queue.bind_unused(0).unwrap().seq, 1);
                    }
                }
                let before: Vec<_> = queue
                    .present()
                    .map(|cid| (cid.seq, cid.id, cid.reset_token))
                    .collect();
                let mut conflict = original;
                match mutation {
                    0 => conflict.id = ConnectionId::new(&[33; 8]),
                    1 => conflict.reset_token = token(33),
                    _ => conflict.sequence = 3,
                }
                // The conflicting frame also tries to discard the evidence.
                conflict.retire_prior_to = conflict.sequence;
                assert_eq!(
                    queue.insert(conflict),
                    Err(InsertError::InconsistentIdentity)
                );
                assert_eq!(
                    queue
                        .present()
                        .map(|cid| (cid.seq, cid.id, cid.reset_token))
                        .collect::<Vec<_>>(),
                    before
                );
                queue.insert(original).unwrap();
                assert_eq!(
                    queue
                        .present()
                        .map(|cid| (cid.seq, cid.id, cid.reset_token))
                        .collect::<Vec<_>>(),
                    before
                );
            }
        }

        let mut queue = CidQueue::new(initial_cid(), CidQueue::LIMIT).unwrap();
        let original = NewConnectionId {
            sequence: 0,
            retire_prior_to: 0,
            id: initial_cid(),
            reset_token: token(4),
        };
        queue.insert(original).unwrap();
        assert_eq!(queue.active_reset_token(), Some(token(4)));
        queue.insert(original).unwrap();
        assert_eq!(
            queue.insert(NewConnectionId {
                reset_token: token(5),
                ..original
            }),
            Err(InsertError::InconsistentIdentity)
        );
    }

    #[test]
    fn advertised_cid_limits_bound_retained_identifiers() {
        for limit in 2..=CidQueue::LIMIT {
            let mut queue = CidQueue::new(initial_cid(), limit).unwrap();
            for sequence in 1..limit {
                queue.insert(cid_token(sequence, 0)).unwrap();
            }
            // Retransmission consumes no extra slot. A new identifier does.
            queue.insert(cid_token(limit - 1, 0)).unwrap();
            assert_matches!(
                queue.insert(cid_token(limit, 0)),
                Err(InsertError::ExceedsLimit)
            );
            assert_eq!(queue.present().count(), limit as usize);

            // Retirement in the same frame releases a slot before its new CID
            // is counted, including replacement of the active identifier.
            queue.insert(cid_token(limit, 1)).unwrap();
            assert_eq!(queue.present().count(), limit as usize);
        }
        for unsupported in [0, 1, CidQueue::LIMIT + 1, u64::MAX] {
            CidQueue::new(initial_cid(), unsupported).unwrap_err();
        }
    }

    /// The sequence numbers a switch says to retire, in order.
    fn retired_seqs(retired: &Retired) -> Vec<u64> {
        // One past the bound is collected and the bound is asserted, so an oversized report fails
        // here instead of exhausting memory or being silently trimmed.
        let bound = CidQueue::LEN * 4;
        let mut seqs: Vec<u64> = retired.iter().flatten().take(bound + 1).collect();
        assert!(
            seqs.len() <= bound,
            "more than {bound} sequence numbers were named for retirement"
        );
        seqs.sort_unstable();
        seqs
    }

    fn initial_cid() -> ConnectionId {
        // Sequence zero must name the same identifier in duplicate-frame fixtures.
        ConnectionId::new(&0_u64.to_be_bytes())
    }

    /// A token distinguishable per identifier, so a test can say which one would reset us.
    fn token(n: u8) -> ResetToken {
        ResetToken::from([n; rama_quic_proto::RESET_TOKEN_SIZE])
    }

    /// A `NEW_CONNECTION_ID` whose token names its sequence number.
    fn cid_token(sequence: u64, retire_prior_to: u64) -> NewConnectionId {
        NewConnectionId {
            sequence,
            id: ConnectionId::new(&sequence.to_be_bytes()),
            reset_token: token(sequence as u8),
            retire_prior_to,
        }
    }

    /// One thing a connection does to the queue.
    #[derive(Debug, Clone, Copy)]
    enum Op {
        /// A NEW_CONNECTION_ID for the next sequence number.
        Issue,
        /// One that leaves a gap, so a number is never received.
        IssueSkipping,
        /// One that retires everything below the highest number issued.
        IssueRetiring,
        /// Switch to the lowest unused identifier.
        Switch,
        /// Switch, keeping the one in use for the path it was used on.
        SwitchHolding,
        /// Let the identifier kept for the previous path go.
        RetireHeld,
        /// Take it back into use.
        RestoreHeld,
        /// Set the lowest unused identifier aside for a candidate path.
        Reserve,
        /// Give that reservation up.
        ReleaseReserved,
        /// Make the reservation the identifier in use.
        PromoteReserved,
        /// Bind an unused identifier to a path of its own.
        Bind,
    }

    impl Op {
        const ALL: [Self; 11] = [
            Self::Issue,
            Self::IssueSkipping,
            Self::IssueRetiring,
            Self::Switch,
            Self::SwitchHolding,
            Self::RetireHeld,
            Self::RestoreHeld,
            Self::Reserve,
            Self::ReleaseReserved,
            Self::PromoteReserved,
            Self::Bind,
        ];
    }

    /// A ledger of what the queue told the caller, not a second implementation of it: the
    /// identifiers the caller received, the ones the queue named for retirement, and the next
    /// number the peer would issue. It says whether identifiers are conserved between the two,
    /// and predicts neither which operations succeed nor the exact retirement set; the scenario
    /// tests above are the oracles for those.
    #[derive(Debug)]
    struct Model {
        delivered: BTreeSet<u64>,
        retired: BTreeSet<u64>,
        next: u64,
    }

    impl Default for Model {
        fn default() -> Self {
            Self {
                // The handshake identifier is in use from the start, so losing it silently is
                // covered like any other.
                delivered: BTreeSet::from([0]),
                retired: BTreeSet::default(),
                next: 0,
            }
        }
    }

    impl Model {
        fn retire(&mut self, retired: &Retired) {
            // Each run is checked before it is walked, so an oversized report fails here rather
            // than exhausting memory or being trimmed into a ledger that looks correct.
            let bound = CidQueue::LEN as u64 * 4;
            for run in retired.iter() {
                let width = run.end.saturating_sub(run.start);
                assert!(
                    width <= bound,
                    "a run of {width} numbers was named for retirement, past the bound {bound}: \
                     {run:?}"
                );
                self.retired.extend(run);
            }
        }
    }

    /// Apply `op`, recording in `model` what the queue reported retiring. An operation the queue
    /// refuses changes nothing and is not an error; the model asks only for what a connection
    /// asks for, in orders a connection may reach.
    fn apply(q: &mut CidQueue, model: &mut Model, op: Op) {
        match op {
            Op::Issue | Op::IssueSkipping | Op::IssueRetiring => {
                if matches!(op, Op::IssueSkipping) {
                    // The skipped number is never received; the queue reports what becomes of it
                    // when it is passed.
                    model.next += 1;
                }
                let retire_prior_to = match op {
                    Op::IssueRetiring => model.next,
                    _ => 0,
                };
                model.next += 1;
                let sequence = model.next;
                // A connection lets identifiers kept aside go before the frame is applied.
                let aside = q.retire_aside(retire_prior_to);
                model.retired.extend(aside.iter());
                for run in aside.skipped.iter() {
                    model.retired.extend(run);
                }
                if let Ok(inserted) = q.insert(cid_token(sequence, retire_prior_to)) {
                    model.delivered.insert(sequence);
                    model.retired.extend(inserted.dropped.iter());
                    if let Some((retired, _)) = &inserted.switched {
                        model.retire(retired);
                    }
                }
            }
            Op::Switch => {
                if let Some((_, retired)) = q.next() {
                    model.retire(&retired);
                }
            }
            Op::SwitchHolding => {
                if let Some((_, retired)) = q.next_holding() {
                    model.retire(&retired);
                }
            }
            Op::RetireHeld => {
                if let Some(seq) = q.retire_held() {
                    model.retired.insert(seq);
                }
            }
            Op::RestoreHeld => {
                // The identifier that was in use is given up: its path is abandoned.
                if let Some(seq) = q.restore_held() {
                    model.retired.insert(seq);
                }
            }
            Op::Reserve => {
                q.reserve();
            }
            Op::ReleaseReserved => {
                if let Some(seq) = q.release_reserved() {
                    model.retired.insert(seq);
                }
            }
            Op::PromoteReserved => {
                if let Some((_, retired)) = q.promote_reserved() {
                    model.retire(&retired);
                }
            }
            Op::Bind => {
                q.bind_unused(1);
            }
        }
    }

    /// What must hold of the queue after every operation, whatever the order.
    fn check(q: &mut CidQueue, model: &Model, history: &[Op]) {
        let present: Vec<u64> = q.present().map(|cid| cid.seq).collect();
        let mut distinct = present.clone();
        distinct.sort_unstable();
        distinct.dedup();
        assert_eq!(
            distinct.len(),
            present.len(),
            "one sequence number is held twice: {present:?} after {history:?}"
        );
        for seq in &present {
            assert!(
                !model.retired.contains(seq),
                "{seq} was retired and is held again: {present:?} after {history:?}"
            );
        }
        // Every identifier that reached this connection is either still held or named for
        // retirement: one the queue threw away silently would stay counted by the peer for ever
        // (RFC 9000 §5.1.2).
        for seq in &model.delivered {
            assert!(
                present.contains(seq) || model.retired.contains(seq),
                "{seq} was received and is now neither held nor retired: {present:?}, \
                 retired {:?}, after {history:?}",
                model.retired
            );
        }
        // A number below the floor is one of those, or one that never arrived: such a number is
        // refused if it arrives late, which is what retires it then (see the probe below).
        for seq in 0..q.floor {
            assert!(
                present.contains(&seq)
                    || model.retired.contains(&seq)
                    || !model.delivered.contains(&seq),
                "{seq} is below the floor {} yet neither held nor retired: {present:?}, \
                 retired {:?}, after {history:?}",
                q.floor,
                model.retired
            );
        }
        assert!(
            present.len() <= CidQueue::LEN,
            "more identifiers than the limit allows: {present:?} after {history:?}"
        );
        assert!(
            present.contains(&q.active_seq()),
            "the identifier in use is not held: {present:?} after {history:?}"
        );
        for cid in q.bound.iter().flatten() {
            assert!(
                q.is_bound(cid.seq),
                "a bound identifier does not say so: {} after {history:?}",
                cid.seq
            );
            assert!(
                !q.unused().iter().any(|unused| unused.seq == cid.seq),
                "a bound identifier is offered as unused: {} after {history:?}",
                cid.seq
            );
        }
        // Nothing below the floor becomes ours again, whatever the peer sends: a number retired
        // here and one that never arrived are both refused, and the refusal is what retires a
        // late arrival with the peer. Refusal changes nothing, so this probe leaves the queue as
        // it was.
        for seq in 0..q.floor {
            if present.contains(&seq) {
                continue;
            }
            assert_eq!(
                q.insert(cid_token(seq, 0)),
                Err(InsertError::Retired),
                "{seq} is below the floor {} and was taken back after {history:?}",
                q.floor
            );
        }
    }

    /// Every order of four operations, with the ledger checked after each one. The point is the
    /// orders a single scenario does not reach: a reservation promoted over unused identifiers, a
    /// held identifier restored after the frame that would have retired it, a binding taken while
    /// a switch is pending. Deterministic and bounded: the same 14641 sequences every run.
    #[test]
    fn a_bounded_sequence_of_operations_keeps_the_queue_consistent() {
        let ops = Op::ALL;
        for a in ops {
            for b in ops {
                for c in ops {
                    for d in ops {
                        let history = [a, b, c, d];
                        let mut q = CidQueue::new(initial_cid(), CidQueue::LIMIT).unwrap();
                        let mut model = Model::default();
                        check(&mut q, &model, &[]);
                        for (i, op) in history.iter().enumerate() {
                            apply(&mut q, &mut model, *op);
                            check(&mut q, &model, &history[..=i]);
                        }
                    }
                }
            }
        }
    }

    /// A frame's `retire_prior_to` also covers numbers that never arrived. They are named for
    /// retirement together with the identifiers the queue holds, so the peer's slots are freed
    /// without waiting for an identifier that may never come (RFC 9000 §5.1.2). Between them, the
    /// release and the frame name every number the frame retires exactly once.
    #[test]
    fn numbers_a_frame_retires_that_never_arrived_are_named() {
        let mut q = CidQueue::new(initial_cid(), CidQueue::LIMIT).unwrap();
        // 1 and 2 were issued by the peer and never reached us; 3 did.
        q.insert(cid_token(3, 0)).unwrap();

        let aside = q.retire_aside(3);
        assert_eq!(
            aside.skipped.iter().flatten().collect::<Vec<_>>(),
            vec![1, 2],
            "the numbers the frame retires that never arrived"
        );
        assert_eq!(aside.kept_aside(), [None, None], "nothing was set aside");

        let (retired, _) = q
            .insert(cid_token(4, 3))
            .unwrap()
            .switched
            .expect("the identifier in use was retired");
        assert_eq!(
            retired_seqs(&retired),
            vec![0],
            "and the identifier that was in use, named once"
        );
        assert_eq!(q.active_seq(), 3);
    }

    /// A frame's `retire_prior_to` may retire identifiers this queue holds unused below the
    /// active one, which a promoted reservation leaves behind. Retiring them without telling the
    /// caller would leave the peer holding identifiers RETIRE_CONNECTION_ID never names
    /// (RFC 9000 §5.1.2).
    #[test]
    fn unused_identifiers_a_frame_retires_are_reported_to_the_caller() {
        let mut q = CidQueue::new(initial_cid(), CidQueue::LIMIT).unwrap();
        for seq in [1, 2, 3] {
            q.insert(cid_token(seq, 0)).unwrap();
        }
        // A candidate path takes the third identifier and becomes the current path, so the two
        // below it stay unused.
        assert!(q.reserve_seq(3).is_some());
        let (_, retired) = q.promote_reserved().expect("the reservation is promoted");
        assert_eq!(q.active_seq(), 3);
        assert_eq!(retired.previous, 0..1);
        assert_eq!(
            q.unused().iter().map(|c| c.seq).collect::<Vec<_>>(),
            vec![1, 2],
            "the identifiers below the promoted one are still unused"
        );

        // The peer now retires everything below 3. The two unused ones go; the caller has to
        // learn their sequence numbers to retire them.
        let inserted = q.insert(cid_token(4, 3)).unwrap();
        assert_eq!(q.active_seq(), 3, "the active identifier is not retired");
        assert!(
            q.unused().iter().all(|c| c.seq >= 3),
            "the retired ones are gone from the queue: {:?}",
            q.unused()
        );
        let mut reported: Vec<u64> = inserted.dropped.iter().copied().collect();
        reported.sort_unstable();
        assert_eq!(
            reported,
            vec![1, 2],
            "both are reported for the caller to retire"
        );
        assert!(inserted.switched.is_none());
    }

    #[test]
    fn next_dense() {
        let mut q = CidQueue::new(initial_cid(), CidQueue::LIMIT).unwrap();
        assert!(q.next().is_none());
        assert!(q.next().is_none());

        for i in 1..CidQueue::LEN as u64 {
            q.insert(cid(i, 0)).unwrap();
        }
        for i in 1..CidQueue::LEN as u64 {
            let (_, retire) = q.next().unwrap();
            assert_eq!(q.active_seq(), i);
            assert_eq!(retire.previous, i - 1..i);
            assert!(retire.skipped().is_empty());
        }
        assert!(q.next().is_none());
    }

    #[test]
    fn next_sparse() {
        let mut q = CidQueue::new(initial_cid(), CidQueue::LIMIT).unwrap();
        let seqs = (1..CidQueue::LEN as u64).filter(|x| x % 2 == 0);
        for i in seqs.clone() {
            q.insert(cid(i, 0)).unwrap();
        }
        for i in seqs {
            let (_, retire) = q.next().unwrap();
            assert_eq!(q.active_seq(), i);
            // The identifier that was active and the never-received one between are retired.
            assert_eq!(retire.previous, i - 2..i - 1);
            assert_eq!(retire.skipped(), vec![i - 1]);
        }
        assert!(q.next().is_none());
    }

    #[test]
    fn wrap() {
        let mut q = CidQueue::new(initial_cid(), CidQueue::LIMIT).unwrap();

        for i in 1..CidQueue::LEN as u64 {
            q.insert(cid(i, 0)).unwrap();
        }
        for _ in 1..(CidQueue::LEN as u64 - 1) {
            q.next().unwrap();
        }
        for i in CidQueue::LEN as u64..(CidQueue::LEN as u64 + 3) {
            q.insert(cid(i, 0)).unwrap();
        }
        for i in (CidQueue::LEN as u64 - 1)..(CidQueue::LEN as u64 + 3) {
            q.next().unwrap();
            assert_eq!(q.active_seq(), i);
        }
        assert!(q.next().is_none());
    }

    #[test]
    fn retire_dense() {
        let mut q = CidQueue::new(initial_cid(), CidQueue::LIMIT).unwrap();

        for i in 1..CidQueue::LEN as u64 {
            q.insert(cid(i, 0)).unwrap();
        }
        assert_eq!(q.active_seq(), 0);

        assert_eq!(
            retired_seqs(&q.insert(cid(4, 2)).unwrap().switched.unwrap().0),
            vec![0, 1]
        );
        assert_eq!(q.active_seq(), 2);
        assert_eq!(q.insert(cid(4, 2)), Ok(Inserted::default()));

        for i in 2..(CidQueue::LEN as u64 - 1) {
            let _ = q.next().unwrap();
            assert_eq!(q.active_seq(), i + 1);
            assert_eq!(q.insert(cid(i + 1, i + 1)), Ok(Inserted::default()));
        }

        assert!(q.next().is_none());
    }

    #[test]
    fn retire_sparse() {
        // Retiring CID 0 when CID 1 is not known should retire CID 1 as we move to CID 2
        let mut q = CidQueue::new(initial_cid(), CidQueue::LIMIT).unwrap();
        q.insert(cid(2, 0)).unwrap();
        assert_eq!(
            retired_seqs(&q.insert(cid(3, 1)).unwrap().switched.unwrap().0),
            vec![0, 1]
        );
        assert_eq!(q.active_seq(), 2);
    }

    /// Switching while holding keeps the old ID aside: it stays out of the ring, the peer's
    /// window still starts at it, and restoring it makes it active again while the ID used
    /// meanwhile is the one to retire.
    #[test]
    fn a_held_id_is_restored_and_the_one_used_meanwhile_retired() {
        let mut q = CidQueue::new(initial_cid(), CidQueue::LIMIT).unwrap();
        for i in 1..CidQueue::LEN as u64 {
            q.insert(cid(i, 0)).unwrap();
        }
        let (_, retired) = q.next_holding().unwrap();
        assert!(
            retired.is_empty(),
            "nothing retired: 0 is held, 1 follows it"
        );
        assert_eq!(q.active_seq(), 1);
        assert_eq!(q.held().unwrap().seq, 0);
        assert_eq!(q.held().unwrap().id, initial_cid());
        // The held ID still counts against the peer's limit: LEN identifiers are present.
        assert_eq!(
            q.insert(cid(CidQueue::LEN as u64, 0)),
            Err(InsertError::ExceedsLimit)
        );
        assert_eq!(q.restore_held(), Some(1));
        assert_eq!(q.active_seq(), 0);
        assert_eq!(q.active(), initial_cid());
        assert!(q.held().is_none());
        // 1 is gone (refused as retired should it come again); 2 is the next unused.
        assert_eq!(q.insert(cid(1, 0)), Err(InsertError::Retired));
        let (_, retired) = q.next().unwrap();
        assert_eq!(retired.previous, 0..1);
        assert!(retired.skipped().is_empty(), "1 was retired already");
        assert_eq!(q.active_seq(), 2);
    }

    /// An identifier kept aside counts against the limit like any other, and letting it go makes
    /// room for one more.
    #[test]
    fn a_held_id_counts_against_the_limit_until_it_is_let_go() {
        let mut q = CidQueue::new(initial_cid(), CidQueue::LIMIT).unwrap();
        for i in 1..CidQueue::LEN as u64 {
            q.insert(cid(i, 0)).unwrap();
        }
        q.next_holding().unwrap(); // held 0, active 1, unused 2..4: five in hand
        assert_eq!(
            q.insert(cid(CidQueue::LEN as u64, 0)),
            Err(InsertError::ExceedsLimit),
            "a sixth identifier is more than we advertised"
        );
        assert_eq!(q.retire_held(), Some(0));
        assert_eq!(
            q.insert(cid(CidQueue::LEN as u64, 0)),
            Ok(Inserted::default())
        );
        assert!(q.next_holding().is_some(), "holding is possible again");
    }

    /// A retire_prior_to that covers an aside ID takes it away before the frame is applied.
    #[test]
    fn retire_prior_to_takes_aside_ids() {
        let mut q = CidQueue::new(initial_cid(), CidQueue::LIMIT).unwrap();
        for i in 1..4 {
            q.insert(cid(i, 0)).unwrap();
        }
        q.next_holding().unwrap(); // held 0, active 1
        let reserved = q.reserve().unwrap(); // reserved 2
        assert_eq!(reserved.seq, 2);
        assert_eq!(q.retire_aside(2).kept_aside(), [Some(0), None]);
        assert_eq!(q.retire_aside(3).kept_aside(), [None, Some(2)]);
        assert!(q.held().is_none() && q.reserved().is_none());
        // 2 was retired by the release above, so the switch names only the identifier that was
        // active: what the caller retires is named once.
        let (retired, _) = q.insert(cid(4, 3)).unwrap().switched.unwrap();
        assert_eq!(retired_seqs(&retired), vec![1]);
        assert_eq!(q.active_seq(), 3);
    }

    /// A reserved ID is invisible to `next` and `has_unused`, and promoting it retires the active
    /// ID and every ID in between.
    #[test]
    fn a_reserved_id_is_skipped_until_promoted() {
        let mut q = CidQueue::new(initial_cid(), CidQueue::LIMIT).unwrap();
        q.insert(cid(1, 0)).unwrap();
        let reserved = q.reserve().unwrap();
        assert_eq!(reserved.seq, 1);
        assert!(!q.has_unused());
        assert!(q.next().is_none());
        assert!(q.reserve().is_none(), "one reservation at a time");
        q.insert(cid(2, 0)).unwrap();
        assert!(q.has_unused());
        let (_, retired) = q.promote_reserved().unwrap();
        assert_eq!(retired.previous, 0..1);
        assert!(retired.skipped().is_empty());
        assert_eq!(q.active_seq(), 1);
        assert_eq!(q.reserved(), None);
        // 2 is still there to switch to.
        let (_, retired) = q.next().unwrap();
        assert_eq!(retired.previous, 1..2);
    }

    /// Promoting after the ring moved past the reservation puts it back in front; the released
    /// alternative just drops it.
    #[test]
    fn a_reservation_survives_switches_and_can_be_released() {
        let mut q = CidQueue::new(initial_cid(), CidQueue::LIMIT).unwrap();
        for i in 1..4 {
            q.insert(cid(i, 0)).unwrap();
        }
        let reserved = q.reserve().unwrap(); // 1
        let (_, retired) = q.next().unwrap(); // active 2
        assert_eq!(retired.previous, 0..1);
        assert!(
            retired.skipped().is_empty(),
            "the reserved 1 is not skipped, it is kept"
        );
        assert_eq!(q.active_seq(), 2);
        assert_eq!(q.reserved(), Some(reserved));
        let (_, retired) = q.promote_reserved().unwrap();
        assert_eq!(retired.previous, 2..3);
        assert!(retired.skipped().is_empty());
        assert_eq!(q.active_seq(), 1);
        assert_eq!(q.active(), reserved.id);
        // 3 remains unused after it; 2 was retired already.
        let (_, retired) = q.next().unwrap();
        assert_eq!(retired.previous, 1..2);
        assert!(retired.skipped().is_empty());
        assert_eq!(q.active_seq(), 3);

        let mut q = CidQueue::new(initial_cid(), CidQueue::LIMIT).unwrap();
        q.insert(cid(1, 0)).unwrap();
        q.reserve().unwrap();
        assert_eq!(q.release_reserved(), Some(1));
        assert!(!q.has_unused());
        assert_eq!(
            q.insert(cid(1, 0)),
            Err(InsertError::Retired),
            "a released reservation is retired for good"
        );
        assert_eq!(
            q.insert(cid(2, 0)),
            Ok(Inserted::default()),
            "its slot goes to the next one"
        );
        assert!(q.has_unused());
    }

    /// Numbers never received between two active identifiers are retired, except those kept
    /// aside (held or reserved), which stay bound to their paths.
    #[test]
    fn skipped_numbers_leave_out_the_aside_ones() {
        let mut q = CidQueue::new(initial_cid(), CidQueue::LIMIT).unwrap();
        q.insert(cid(1, 0)).unwrap();
        q.insert(cid(4, 0)).unwrap();
        q.next_holding().unwrap(); // held 0, active 1
        q.insert(cid(2, 0)).unwrap();
        q.reserve().unwrap(); // reserved 2 (the lowest unused)
        let (_, retired) = q.next().unwrap(); // active 4
        assert_eq!(retired.previous, 1..2);
        assert_eq!(
            retired.skipped(),
            vec![3],
            "2 is reserved, 3 was never received"
        );
        assert_eq!(q.held().unwrap().seq, 0);
        assert_eq!(q.reserved().unwrap().seq, 2);
        // Late arrival of 3: already retired.
        assert_eq!(q.insert(cid(3, 0)), Err(InsertError::Retired));
    }

    /// Numbers on both sides of an identifier the connection keeps are retired, in the two runs
    /// around it.
    #[test]
    fn skipped_runs_go_around_a_kept_id() {
        let mut q = CidQueue::new(initial_cid(), CidQueue::LIMIT).unwrap();
        q.insert(cid(2, 0)).unwrap();
        q.next_holding().unwrap(); // held 0, active 2, 1 retired
        assert_eq!(q.retire_held(), Some(0));
        q.insert(cid(4, 0)).unwrap();
        q.reserve_seq(4).expect("4 is unused");
        q.insert(cid(6, 0)).unwrap();
        let (_, retired) = q.next_holding().unwrap(); // held 2, active 6
        assert!(retired.previous.is_empty(), "2 is kept, not retired");
        assert_eq!(
            retired.skipped(),
            vec![3, 5],
            "4 is reserved; 3 and 5 were never received and sit on either side of it"
        );
        assert_eq!(q.held().map(|c| c.seq), Some(2));
        assert_eq!(q.reserved().map(|c| c.seq), Some(4));
    }

    /// A specific unused identifier can be set aside, not only the lowest one.
    #[test]
    fn a_named_sequence_can_be_reserved() {
        let mut q = CidQueue::new(initial_cid(), CidQueue::LIMIT).unwrap();
        q.insert(cid(1, 0)).unwrap();
        q.insert(cid(2, 0)).unwrap();
        let reserved = q.reserve_seq(2).expect("2 is unused");
        assert_eq!(reserved.seq, 2);
        assert!(q.reserve_seq(2).is_none(), "one reservation at a time");
        // 1 is still there to switch to.
        let (_, retired) = q.next().unwrap();
        assert_eq!(q.active_seq(), 1);
        assert_eq!(retired.previous, 0..1);
        assert!(retired.skipped().is_empty());
        assert!(
            q.reserve_seq(9).is_none(),
            "an unknown sequence is not unused"
        );
    }

    /// Promoting a reservation past never-received numbers retires those as well as the identifier
    /// that was active.
    #[test]
    fn promoting_forward_retires_what_it_passes() {
        let mut q = CidQueue::new(initial_cid(), CidQueue::LIMIT).unwrap();
        q.insert(cid(1, 0)).unwrap();
        q.insert(cid(4, 0)).unwrap();
        let reserved = q.reserve_seq(4).expect("4 is unused");
        assert_eq!(reserved.seq, 4);
        let (_, retired) = q.promote_reserved().unwrap();
        assert_eq!(q.active_seq(), 4);
        assert_eq!(retired.previous, 0..1);
        assert_eq!(
            retired.skipped(),
            vec![2, 3],
            "1 is still ours, only the numbers we never received are retired"
        );
        assert!(q.has_unused(), "the identifier we hold stays usable");
        let (_, retired) = q.next().unwrap();
        assert_eq!(q.active_seq(), 1, "and it can still be switched to");
        assert_eq!(retired.previous, 4..5);
        assert!(retired.skipped().is_empty());
    }

    /// `retire_prior_to` retires the numbers below it and leaves the one at it in place.
    #[test]
    fn retire_prior_to_keeps_the_id_at_its_own_number() {
        let mut q = CidQueue::new(initial_cid(), CidQueue::LIMIT).unwrap();
        q.insert(cid(1, 0)).unwrap();
        q.insert(cid(2, 0)).unwrap();
        q.next_holding().unwrap(); // held 0, active 1
        let reserved = q.reserve().unwrap(); // reserved 2
        assert_eq!(reserved.seq, 2);
        assert_eq!(
            q.retire_aside(0).kept_aside(),
            [None, None],
            "nothing is below zero"
        );
        assert_eq!(
            q.retire_aside(1).kept_aside(),
            [Some(0), None],
            "0 goes, 2 stays"
        );
        assert_eq!(q.reserved().map(|c| c.seq), Some(2));
        let mut q = CidQueue::new(initial_cid(), CidQueue::LIMIT).unwrap();
        q.insert(cid(1, 0)).unwrap();
        q.insert(cid(2, 0)).unwrap();
        q.next().unwrap(); // active 1
        q.reserve_seq(2).unwrap();
        assert_eq!(
            q.retire_aside(2).kept_aside(),
            [None, None],
            "the identifier at the bound stays"
        );
        assert_eq!(q.reserved().map(|c| c.seq), Some(2));
    }

    /// RFC 9000 §10.3.1 as an invariant of the identifier rather than of the connection: what a
    /// datagram has gone out with stays sent through every change of role, what has not been sent
    /// gains nothing by being moved, and retirement ends it.
    #[test]
    fn send_history_travels_with_the_identifier_and_no_role_change_invents_it() {
        let mut q = CidQueue::new(initial_cid(), CidQueue::LIMIT).unwrap();
        for i in 1..5 {
            q.insert(cid_token(i, 0)).unwrap();
        }
        q.set_initial_reset_token(token(0));
        let here = SocketAddr::from((std::net::Ipv4Addr::LOCALHOST, 4433));
        let there = SocketAddr::from((std::net::Ipv4Addr::LOCALHOST, 4434));
        let used = |q: &CidQueue, remote: SocketAddr| -> Vec<ResetToken> {
            q.used_reset_tokens(remote).collect()
        };
        sent(&mut q, 0, here, 1, OwnedRemotes::default());
        assert_eq!(
            used(&q, here),
            vec![token(0)],
            "only the identifier the handshake sent with"
        );
        assert!(
            used(&q, there).is_empty(),
            "and only towards the address it was sent to"
        );

        // Switching to an unused identifier is not sending with it.
        q.next().expect("an unused identifier");
        assert_eq!(q.active_seq(), 1);
        assert!(!q.is_sent(1), "nothing has gone out with it yet");
        assert!(used(&q, here).is_empty(), "so nothing can reset us");
        sent(&mut q, 1, here, 2, OwnedRemotes::default());
        assert_eq!(used(&q, here), vec![token(1)]);

        // Held: the one in use goes aside with its history, the replacement arrives without one.
        // An unconditional `held` would invent a history here.
        q.next_holding()
            .expect("an unused identifier, keeping the current");
        assert_eq!(q.held().map(|c| c.seq), Some(1));
        assert_eq!(q.active_seq(), 2);
        assert!(q.is_sent(1), "the one put aside had been sent");
        assert!(!q.is_sent(2), "the replacement had not");
        assert_eq!(
            used(&q, here),
            vec![token(1)],
            "the replacement's token resets nothing until it is sent"
        );

        // Restoring keeps each side of that straight.
        q.restore_held();
        assert_eq!(q.active_seq(), 1);
        assert!(q.is_sent(1));
        assert!(!q.is_sent(2) || q.held().is_none(), "2 gained no history");

        // Reserve then promote: a reservation is unsent when it becomes active.
        let reserved = q.reserve().expect("an unused identifier");
        assert!(!q.is_sent(reserved.seq));
        q.promote_reserved();
        assert_eq!(q.active_seq(), reserved.seq);
        assert!(!q.is_sent(reserved.seq), "promotion is not sending");
        assert!(!used(&q, here).contains(&token(reserved.seq as u8)));
        sent(&mut q, reserved.seq, here, 3, OwnedRemotes::default());
        assert!(used(&q, here).contains(&token(reserved.seq as u8)));

        // Binding to a path of its own: same rule, and retirement ends it.
        q.insert(cid_token(7, 0)).unwrap();
        let bound = q.bind_unused(0).expect("an unused identifier");
        assert!(!q.is_sent(bound.seq));
        sent(&mut q, bound.seq, there, 4, OwnedRemotes::default());
        assert!(q.is_sent(bound.seq));
        assert!(
            used(&q, there).contains(&token(bound.seq as u8)),
            "the address it was bound to recognises it"
        );
        assert!(
            !used(&q, here).contains(&token(bound.seq as u8)),
            "the address it was never sent to does not"
        );
        let aside = q.retire_aside(bound.seq + 1);
        assert!(
            aside.bound.contains(&bound.seq),
            "the peer's retirement covered it"
        );
        assert!(!q.is_sent(bound.seq), "a retired identifier has no history");
        assert!(
            !used(&q, there).contains(&token(bound.seq as u8)),
            "and its token is no longer ours"
        );
    }

    fn addr(last: u8) -> SocketAddr {
        SocketAddr::from(([127, 0, 0, last], 4433))
    }

    /// `mark_sent` in a test: every one of these scenarios has room to record the address, so a
    /// refusal is a bug in the test rather than something to handle.
    fn sent(
        q: &mut CidQueue,
        seq: u64,
        remote: SocketAddr,
        generation: u64,
        owned: OwnedRemotes,
    ) -> Option<(RouteDelta, ResetToken)> {
        q.mark_sent(seq, remote, generation, owned)
            .expect("there is room to record it")
    }

    /// The roles that own an address for an identifier at one moment.
    fn roles(current: SocketAddr, fallback: Option<SocketAddr>) -> OwnedRemotes {
        OwnedRemotes {
            current: Some(current),
            fallback,
        }
    }

    /// One identifier sent to a sequence of addresses, keeping a route for each until something
    /// has to give way. Returns the queue and the identifier's sequence number.
    fn queue_with_one_used_cid() -> (CidQueue, u64) {
        let mut q = CidQueue::new(initial_cid(), CidQueue::LIMIT).unwrap();
        q.insert(cid_token(1, 0)).unwrap();
        q.next().expect("an unused identifier");
        (q, 1)
    }

    /// The identifier the handshake sends with has no token, so nothing gates it and its sends
    /// are recorded. When the peer finally names its token there *is* a route to install, and the
    /// gate closes until the endpoint confirms it, and the recorded history is retained.
    /// Learning a token must not leave the gate open on an unconfirmed route.
    #[test]
    fn learning_a_token_closes_the_gate_until_the_route_is_confirmed() {
        let mut q = CidQueue::new(initial_cid(), CidQueue::LIMIT).unwrap();
        let here = SocketAddr::from((std::net::Ipv4Addr::LOCALHOST, 4433));

        // No token yet: nothing to route, so the handshake sends freely.
        assert!(
            q.is_installed(0, here),
            "no token means nothing to wait for"
        );
        assert!(sent(&mut q, 0, here, 1, OwnedRemotes::default()).is_none());
        assert!(q.is_sent(0), "and the send is on record");
        assert!(q.is_installed(0, here));

        // Installing a route for an identifier nothing has gone out with does not make it sent:
        // the route is there so a reset can be placed, not because we used it.
        q.insert(cid_token(1, 0)).unwrap();
        let unused = q.reserve().expect("an unused identifier");
        q.install_route(unused.seq, here, 2, OwnedRemotes::default())
            .expect("there is room")
            .expect("a route to install");
        assert!(
            !q.is_sent(unused.seq),
            "installing a route is not sending with the identifier"
        );
        assert!(
            !q.used_reset_tokens(here).any(|t| t == token(1)),
            "so a reset carrying its token is not ours"
        );
        q.route_installed(unused.seq, here, 2);
        assert!(
            !q.is_sent(unused.seq),
            "and confirming the route is not sending either"
        );
        assert!(!q.used_reset_tokens(here).any(|t| t == token(1)));

        // The peer names the token. Now a route exists to install, and until the endpoint says it
        // is in place this identifier may not be sent to this address.
        q.set_initial_reset_token(token(0));
        let (delta, installed_token) = q
            .install_route(0, here, 7, OwnedRemotes::default())
            .expect("there is room")
            .expect("the route has to be installed now");
        assert_eq!(installed_token, token(0));
        assert_eq!(
            delta.added.and_then(|a| a.generation()),
            Some(7),
            "installed under the generation that asked for it"
        );
        assert!(
            !q.is_installed(0, here),
            "the gate is shut until the endpoint confirms it"
        );
        assert!(q.is_sent(0), "and the history it earned is untouched");

        // An acknowledgement for another installation, address or identifier opens nothing.
        q.route_installed(0, here, 6);
        assert!(!q.is_installed(0, here), "a stale generation opens nothing");
        q.route_installed(
            0,
            SocketAddr::from((std::net::Ipv4Addr::LOCALHOST, 9999)),
            7,
        );
        assert!(!q.is_installed(0, here), "another address opens nothing");
        q.route_installed(9, here, 7);
        assert!(!q.is_installed(0, here), "another identifier opens nothing");

        // The one that was asked for does.
        q.route_installed(0, here, 7);
        assert!(q.is_installed(0, here));
        assert_eq!(
            q.used_reset_tokens(here).count(),
            1,
            "and a reset from there is ours, because a datagram did go out with it"
        );
    }

    /// An identifier sent to more than one address before its token was known needs a route for
    /// **each** of them once it is, each named separately, and none of them counts as installed
    /// until the endpoint says so. What it has sent to each address survives.
    #[test]
    fn learning_a_token_arranges_every_address_the_identifier_has_used() {
        let mut q = CidQueue::new(initial_cid(), CidQueue::LIMIT).unwrap();
        let (a, b) = (addr(1), addr(2));

        // The handshake identifier has no token yet, so it sends to two addresses ungated.
        assert!(sent(&mut q, 0, a, 1, roles(a, None)).is_none());
        assert!(sent(&mut q, 0, b, 2, roles(b, Some(a))).is_none());
        assert!(q.is_sent_to(0, a) && q.is_sent_to(0, b));
        assert!(q.is_installed(0, a) && q.is_installed(0, b));

        // The peer names the token. Both addresses need a route, under names of their own.
        q.set_initial_reset_token(token(0));
        let (announced, announced_token) = q.announce_routes(0, 40);
        assert_eq!(announced_token, Some(token(0)));
        let named: Vec<_> = announced
            .iter()
            .flatten()
            .map(|assoc| (assoc.remote, assoc.generation()))
            .collect();
        assert_eq!(named.len(), 2, "both addresses were announced: {named:?}");
        assert_eq!(
            named
                .iter()
                .filter_map(|(_, generation)| *generation)
                .collect::<std::collections::BTreeSet<_>>()
                .len(),
            2,
            "each under its own name: {named:?}"
        );
        assert!(
            !q.is_installed(0, a) && !q.is_installed(0, b),
            "and neither is installed until the endpoint confirms it"
        );
        assert!(
            q.is_sent_to(0, a) && q.is_sent_to(0, b),
            "while what was sent to each stays sent"
        );

        // Each is confirmed on its own name; confirming one does not open the other.
        let generation_of = |remote: SocketAddr| {
            named
                .iter()
                .find(|(r, _)| *r == remote)
                .and_then(|(_, generation)| *generation)
                .expect("it was announced")
        };
        q.route_installed(0, a, generation_of(a));
        assert!(q.is_installed(0, a));
        assert!(!q.is_installed(0, b), "b is still waiting for its own");
        q.route_installed(0, b, generation_of(a));
        assert!(!q.is_installed(0, b), "and not on a's name");
        q.route_installed(0, b, generation_of(b));
        assert!(q.is_installed(0, b));

        // Announcing again has nothing left to do.
        let (again, _) = q.announce_routes(0, 90);
        assert!(again.iter().all(Option::is_none));
    }

    /// Recency is not proof that an address stopped being relevant. Moving off a path that was
    /// never validated keeps the *original* as the fallback, so the address in the middle is the
    /// one displaced, and never one a path role owns.
    #[test]
    fn a_role_owned_address_is_never_displaced_by_transient_history() {
        let (mut q, seq) = queue_with_one_used_cid();
        let (a, b, c, d) = (addr(1), addr(2), addr(3), addr(4));

        // A, then an unvalidated move to B, then on to C: A is still the fallback throughout.
        sent(&mut q, seq, a, 1, roles(a, None));
        sent(&mut q, seq, b, 2, roles(b, Some(a)));
        sent(&mut q, seq, c, 3, roles(c, Some(a)));
        for remote in [a, b, c] {
            assert!(q.is_sent_to(seq, remote), "{remote} is recognised");
        }

        // A fourth address has to displace something. B is the one no role owns.
        let (delta, _) = sent(&mut q, seq, d, 4, roles(d, Some(a))).expect("a route to install");
        assert_eq!(
            delta.released.map(|r| r.remote),
            Some(b),
            "the address that stopped being relevant gives way"
        );
        assert!(
            q.is_sent_to(seq, a),
            "the fallback keeps its route: it is still live"
        );
        assert!(q.is_sent_to(seq, d), "and the address now in use has one");
        assert!(!q.is_sent_to(seq, b), "the one in between does not");
        assert_eq!(q.live_associations(), RemCid::REMOTES);
    }

    /// The small recency case: an address returned to is in use again, so the one that has gone
    /// longest without a send is the one that gives way.
    #[test]
    fn a_returning_address_keeps_its_route_and_the_idle_one_goes() {
        let (mut q, seq) = queue_with_one_used_cid();
        let (a, b, c, d) = (addr(1), addr(2), addr(3), addr(4));
        sent(&mut q, seq, a, 1, roles(a, None));
        sent(&mut q, seq, b, 2, roles(b, Some(a)));
        // Back to A: it is in use again, so B is now the idle one.
        sent(&mut q, seq, a, 3, roles(a, Some(b)));
        sent(&mut q, seq, c, 4, roles(c, Some(a)));
        let (delta, _) = sent(&mut q, seq, d, 5, roles(d, Some(a))).expect("a route to install");
        assert_eq!(
            delta.released.map(|r| r.remote),
            Some(b),
            "B went longest without a send and no role owns it"
        );
        assert!(
            q.is_sent_to(seq, a),
            "A was used after B and is the fallback"
        );
        assert!(q.is_sent_to(seq, c));
        assert!(q.is_sent_to(seq, d));
    }

    /// However many times the peer moves, one identifier never holds more routes than the roles
    /// that can own it, and every displacement is reported so the endpoint can follow.
    #[test]
    fn many_moves_never_leave_more_routes_than_the_roles_can_own() {
        let (mut q, seq) = queue_with_one_used_cid();
        let home = addr(1);
        let mut installed = 0i64;
        sent(&mut q, seq, home, 0, roles(home, None));
        installed += 1;
        for step in 0..40u8 {
            let remote = addr(10 + step);
            let owned = roles(remote, Some(home));
            let Some((delta, _)) = sent(&mut q, seq, remote, step as u64 + 1, owned) else {
                continue;
            };
            installed += i64::from(delta.added.is_some());
            installed -= i64::from(delta.released.is_some());
            assert!(
                q.live_associations() <= RemCid::REMOTES,
                "step {step} left {} routes",
                q.live_associations()
            );
            assert!(
                q.is_sent_to(seq, home),
                "step {step} dropped the fallback nobody replaced"
            );
        }
        assert_eq!(
            installed,
            q.live_associations() as i64,
            "what was published matches what is held, so the endpoint cannot accumulate"
        );
    }

    /// A switch retires the numbers it skipped, up to `limit` past the identifier that was active:
    /// a peer that jumps to the highest legal sequence number would otherwise name a 2^62-wide
    /// run, which no retirement queue can hold. The identifier that was active is still named, and
    /// the numbers past the bound are refused if they arrive, which is what retires them then.
    #[test]
    fn a_distant_sequence_number_is_skipped_up_to_the_bound() {
        let mut q = CidQueue::new(initial_cid(), CidQueue::LIMIT).unwrap();
        let far = (1u64 << 62) - 1;
        q.insert(cid(far, 0)).expect("a distant number is legal");
        let (_, retired) = q.next().expect("the connection switches to it");
        assert_eq!(q.active_seq(), far);
        let named = retired_seqs(&retired);
        assert_eq!(
            named,
            (0..CidQueue::LEN as u64).collect::<Vec<_>>(),
            "the identifier that was active and the numbers up to the bound"
        );
        // Everything below the new active identifier is refused from now on, which is the floor's
        // work, and that refusal is what retires a late arrival.
        assert_matches!(q.insert(cid(far / 2, 0)), Err(InsertError::Retired));
    }

    /// Giving up a reservation at the highest sequence the peer has issued must not make a
    /// retransmission of an identifier we still hold fail: the limit is pinned by what we hold,
    /// not by a floor that has moved past the newest number.
    #[test]
    fn a_released_top_reservation_leaves_earlier_ids_insertable() {
        let mut q = CidQueue::new(initial_cid(), CidQueue::LIMIT).unwrap();
        for i in 1..CidQueue::LEN as u64 {
            q.insert(cid(i, 0)).unwrap();
        }
        let highest = CidQueue::LEN as u64 - 1;
        let reserved = q.reserve_seq(highest).expect("the highest id is unused");
        assert_eq!(reserved.seq, highest);
        assert_eq!(q.release_reserved(), Some(highest));
        // A retransmitted NEW_CONNECTION_ID for an identifier we still hold.
        assert_eq!(q.insert(cid(1, 0)), Ok(Inserted::default()));
        assert_eq!(q.active_seq(), 0);
        assert!(q.has_unused());
        // And one we let go of stays gone.
        assert_eq!(q.insert(cid(highest, 0)), Err(InsertError::Retired));
    }

    /// The same shape with the highest identifier held rather than reserved, and with the active
    /// one restored from a held slot: neither makes a later insert fail or panic.
    #[test]
    fn a_restored_hold_leaves_the_window_pinned_by_what_we_hold() {
        let mut q = CidQueue::new(initial_cid(), CidQueue::LIMIT).unwrap();
        for i in 1..CidQueue::LEN as u64 {
            q.insert(cid(i, 0)).unwrap();
        }
        q.next_holding().unwrap(); // held 0, active 1
        assert_eq!(q.restore_held(), Some(1));
        assert_eq!(q.active_seq(), 0);
        assert_eq!(
            q.insert(cid(2, 0)),
            Ok(Inserted::default()),
            "2 is still ours"
        );
        assert_eq!(q.insert(cid(1, 0)), Err(InsertError::Retired));
        // We hold every slot except the retired 1: one more fits, a second does not.
        assert_eq!(
            q.insert(cid(CidQueue::LEN as u64, 0)),
            Ok(Inserted::default())
        );
        assert_eq!(
            q.insert(cid(CidQueue::LEN as u64 + 1, 0)),
            Err(InsertError::ExceedsLimit)
        );
    }

    #[test]
    fn retire_many() {
        let mut q = CidQueue::new(initial_cid(), CidQueue::LIMIT).unwrap();
        q.insert(cid(2, 0)).unwrap();
        assert_eq!(
            retired_seqs(
                &q.insert(cid(1_000_000, 1_000_000))
                    .unwrap()
                    .switched
                    .unwrap()
                    .0
            ),
            (0..CidQueue::LEN as u64).collect::<Vec<_>>(),
        );
        assert_eq!(q.active_seq(), 1_000_000);
    }

    #[test]
    fn insert_limit() {
        let mut q = CidQueue::new(initial_cid(), CidQueue::LIMIT).unwrap();
        for i in 1..CidQueue::LEN as u64 {
            assert_eq!(q.insert(cid(i, 0)), Ok(Inserted::default()));
        }
        // The active one plus `LEN - 1` unused ones is the whole allowance.
        assert_eq!(
            q.insert(cid(CidQueue::LEN as u64, 0)),
            Err(InsertError::ExceedsLimit)
        );
        // Retiring one makes room again, and a frame that retires makes room for itself.
        q.next().unwrap();
        assert_eq!(
            q.insert(cid(CidQueue::LEN as u64, 0)),
            Ok(Inserted::default())
        );
    }

    #[test]
    fn insert_duplicate() {
        let mut q = CidQueue::new(initial_cid(), CidQueue::LIMIT).unwrap();
        q.insert(cid(0, 0)).unwrap();
        q.insert(cid(0, 0)).unwrap();
    }

    #[test]
    fn insert_retired() {
        let mut q = CidQueue::new(initial_cid(), CidQueue::LIMIT).unwrap();
        assert_eq!(
            q.insert(cid(0, 0)),
            Ok(Inserted::default()),
            "reinserting active CID succeeds"
        );
        assert!(q.next().is_none(), "active CID isn't requeued");
        q.insert(cid(1, 0)).unwrap();
        q.next().unwrap();
        assert_eq!(
            q.insert(cid(0, 0)),
            Err(InsertError::Retired),
            "previous active CID is already retired"
        );
    }

    #[test]
    fn retire_then_insert_next() {
        let mut q = CidQueue::new(initial_cid(), CidQueue::LIMIT).unwrap();
        for i in 1..CidQueue::LEN as u64 {
            q.insert(cid(i, 0)).unwrap();
        }
        q.next().unwrap();
        q.insert(cid(CidQueue::LEN as u64, 0)).unwrap();
        assert_eq!(
            q.insert(cid(CidQueue::LEN as u64 + 1, 0)),
            Err(InsertError::ExceedsLimit)
        );
    }

    #[test]
    fn always_valid() {
        let mut q = CidQueue::new(initial_cid(), CidQueue::LIMIT).unwrap();
        assert!(q.next().is_none());
        assert_eq!(q.active(), initial_cid());
        assert_eq!(q.active_seq(), 0);
    }
}

#[cfg(test)]
mod storage_tests {
    use super::*;
    #[test]
    fn default_limit_retirement_storage_stays_inline() {
        for limit in [2, 5, 8, 64] {
            let queue = CidQueue::new(ConnectionId::new(&[0; 8]), limit).unwrap();
            assert!(!queue.bound.spilled() && !queue.unused.spilled());
        }
        let mut queue = CidQueue::new(ConnectionId::new(&[0; 8]), 8).unwrap();
        for sequence in 1..8 {
            let result = queue
                .insert(NewConnectionId {
                    sequence,
                    retire_prior_to: 0,
                    id: ConnectionId::new(&[sequence as u8; 8]),
                    reset_token: ResetToken::from([sequence as u8; 16]),
                })
                .unwrap();
            assert!(!result.dropped.spilled());
        }
        let result = queue
            .insert(NewConnectionId {
                sequence: 8,
                retire_prior_to: 8,
                id: ConnectionId::new(&[8; 8]),
                reset_token: ResetToken::from([8; 16]),
            })
            .unwrap();
        assert!(!result.dropped.spilled());
        assert_eq!(std::mem::size_of::<Skipped>(), 16);
        let retired = queue.retire_aside(8);
        assert!(!retired.bound.spilled());
    }
}
