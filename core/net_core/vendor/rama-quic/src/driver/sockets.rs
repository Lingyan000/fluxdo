//! Bounded registry of the locally bound sockets one endpoint owns.
//!
//! One QUIC endpoint may own several sockets at once: the active one that new connections use,
//! and earlier ones that connections, queued connection attempts or queued stateless responses
//! still depend on after a rebind. Each socket has a stable [`SocketId`] that is never reused,
//! so a stale handle can never select a different socket. Every dependent holds an owned
//! [`Lease`] that is released exactly once, by value; an entry is retired only when no lease and
//! no queued response remains. The number of entries is bounded and a rebind that would exceed
//! the bound is refused without changing anything. Retired sockets are handed back to the caller
//! so their destructors run outside the endpoint lock.

use std::{io, task::Context};

use crate::driver::{
    Instant,
    udp::{ResponseProgress, Sender, Socket},
};
use crate::proto;

/// Stable identity of a socket owned by an endpoint. Never reused within one endpoint.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub(crate) struct SocketId(u64);

impl SocketId {
    /// The identity of a socket's own stateless-response sender; never a dependent.
    pub(crate) const RESPONSE: Self = Self(0);
}

/// Total sockets an endpoint retains at once: the active one plus retiring ones.
///
/// The bound caps retained datagram transports and their response queues. A native Apple
/// dual-stack transport owns two operating-system sockets, one per address family. Eight
/// leaves room for overlapping rebinds during interface churn while earlier paths drain,
/// without letting a rebind storm accumulate sockets. A rebind past the bound is refused and the previous state is kept. Exposing the bound
/// through `EndpointConfig` is facade work; the value is a constant until then.
pub(crate) const MAX_RETAINED_SOCKETS: usize = 8;

/// Stateless responses one endpoint poll sends across all its sockets before yielding.
pub(crate) const RESPONSE_WORK_LIMIT: usize = 32;

/// What holds a socket alive.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum Dependent {
    /// A connection driver's send handle created from the socket.
    Connection,
    /// A queued or application-held incoming connection attempt received on the socket.
    Attempt,
}

/// One dependent's hold on a socket. Released exactly once, by value, through
/// [`SocketRegistry::release`]; dropping it without releasing keeps the socket retained (a leak
/// is the fail-safe direction: a socket is never retired while an owner may still use it).
#[must_use = "a lease keeps its socket alive until it is released"]
#[derive(Debug)]
pub(crate) struct Lease {
    id: SocketId,
    kind: Dependent,
}

impl Lease {
    pub(crate) fn id(&self) -> SocketId {
        self.id
    }
}

#[derive(Debug)]
struct Entry {
    id: SocketId,
    socket: Socket,
    connections: usize,
    attempts: usize,
    /// The socket keeps receiving until this instant because a Retry sent from it authorised
    /// the peer to come back to it (see [`SocketRegistry::hold_route`]).
    route_until: Option<Instant>,
    /// The socket's receive or send path is unusable; it stays only while dependents remain.
    failed: bool,
    /// The connections holding this failed socket have been told to leave it.
    failure_announced: bool,
}

impl Entry {
    fn new(id: SocketId, socket: Socket) -> Self {
        Self {
            id,
            socket,
            connections: 0,
            attempts: 0,
            route_until: None,
            failed: false,
            failure_announced: false,
        }
    }

    /// Nothing depends on the socket at `now`: no lease, no queued response, no route hold.
    /// A hold ends at its instant: at `until` the socket may go, which is also the instant the
    /// endpoint's timer is scheduled for.
    fn idle(&self, now: Instant) -> bool {
        self.connections == 0
            && self.attempts == 0
            && !self.socket.has_responses()
            && self.route_until.is_none_or(|until| until <= now)
    }
}

/// Whether `entry` is a usable wildcard socket for the local address `local`.
fn covers(entry: &Entry, local: std::net::SocketAddr) -> bool {
    let bound = entry.socket.local_addr();
    !entry.failed
        && bound.ip().is_unspecified()
        && bound.port() == local.port()
        && (bound.is_ipv4() == local.is_ipv4()
            || (bound.is_ipv6() && local.is_ipv4() && entry.socket.received_ipv4()))
        && entry.socket.capabilities().send_source_ip
}

/// A rebind the registry refused; the caller gets its socket back to drop outside any lock.
#[derive(Debug)]
pub(crate) struct RebindRefused {
    pub(crate) error: io::Error,
    pub(crate) socket: Socket,
}

/// Counters of sockets that were already retired, folded in exactly once.
#[derive(Debug, Default, Clone, Copy)]
struct Retired {
    dropped_responses: u64,
    failed_responses: u64,
    sockets: u64,
}

/// Socket identities in polling order; fixed storage, no allocation per poll.
#[derive(Debug, Clone, Copy)]
pub(crate) struct Order {
    ids: [SocketId; MAX_RETAINED_SOCKETS],
    len: usize,
}

impl Order {
    fn new() -> Self {
        Self {
            ids: [SocketId::RESPONSE; MAX_RETAINED_SOCKETS],
            len: 0,
        }
    }

    fn push(&mut self, id: SocketId) {
        if let Some(slot) = self.ids.get_mut(self.len) {
            *slot = id;
            self.len += 1;
        }
    }

    fn rotated(self, start: usize) -> Self {
        let mut out = Self::new();
        if self.len == 0 {
            return out;
        }
        for i in 0..self.len {
            out.push(self.ids[(start + i) % self.len]);
        }
        out
    }

    pub(crate) fn iter(&self) -> impl Iterator<Item = SocketId> + '_ {
        self.ids[..self.len].iter().copied()
    }

    #[cfg(test)]
    fn to_vec(self) -> Vec<SocketId> {
        self.iter().collect()
    }
}

#[derive(Debug)]
pub(crate) struct SocketRegistry {
    /// The socket new connections use; structurally always present.
    active: Entry,
    /// Sockets bound to addresses this endpoint advertises as preferred (RFC 9000 §9.6). They
    /// receive from the moment they are bound, a rebind of the active socket leaves them alone,
    /// and they are released by endpoint shutdown or an explicit release.
    advertised: Vec<Entry>,
    /// Earlier sockets something still depends on.
    retiring: Vec<Entry>,
    next: u64,
    /// Rotation cursor so polling does not always start with the same socket.
    cursor: usize,
    /// Addresses of advertised sockets that failed, for the caller to stop advertising. Recorded
    /// when the failure is marked, before the entry can be retired and its address lost.
    withdrawn: Vec<std::net::SocketAddr>,
    retired: Retired,
}

/// Outcome of driving the queued stateless responses of every socket.
#[derive(Debug)]
pub(crate) struct ResponsesDriven {
    /// Runnable response work remains (the shared budget ended before it): poll again.
    pub(crate) keep_going: bool,
    /// Sockets retired by this pass; drop them outside the endpoint lock.
    pub(crate) retired: Vec<Socket>,
}

impl SocketRegistry {
    pub(crate) fn new(socket: Socket) -> Self {
        Self {
            active: Entry::new(SocketId(1), socket),
            advertised: Vec::new(),
            retiring: Vec::new(),
            next: 2,
            cursor: 0,
            withdrawn: Vec::new(),
            retired: Retired::default(),
        }
    }

    pub(crate) fn active_id(&self) -> SocketId {
        self.active.id
    }

    pub(crate) fn active(&self) -> &Socket {
        &self.active.socket
    }

    fn entries(&self) -> impl Iterator<Item = &Entry> {
        std::iter::once(&self.active)
            .chain(self.advertised.iter())
            .chain(self.retiring.iter())
    }

    fn entries_mut(&mut self) -> impl Iterator<Item = &mut Entry> {
        std::iter::once(&mut self.active)
            .chain(self.advertised.iter_mut())
            .chain(self.retiring.iter_mut())
    }

    fn entry_mut(&mut self, id: SocketId) -> Option<&mut Entry> {
        self.entries_mut().find(|e| e.id == id)
    }

    fn entry(&self, id: SocketId) -> Option<&Entry> {
        self.entries().find(|e| e.id == id)
    }

    /// Sockets currently retained (active, advertised and retiring).
    pub(crate) fn len(&self) -> usize {
        1 + self.advertised.len() + self.retiring.len()
    }

    /// Bind `socket` as an address this endpoint advertises. It starts receiving at once and is
    /// not retired by a rebind. Refused, handing `socket` back, when the retained set is already
    /// at [`MAX_RETAINED_SOCKETS`] or the identity space is exhausted.
    pub(crate) fn advertise(&mut self, socket: Socket) -> Result<SocketId, RebindRefused> {
        if self.len() >= MAX_RETAINED_SOCKETS {
            return Err(RebindRefused {
                error: io::Error::new(
                    io::ErrorKind::QuotaExceeded,
                    "too many QUIC sockets retained to add an advertised address",
                ),
                socket,
            });
        }
        let Some(next) = self.next.checked_add(1) else {
            return Err(RebindRefused {
                error: io::Error::new(
                    io::ErrorKind::QuotaExceeded,
                    "QUIC socket identity space exhausted",
                ),
                socket,
            });
        };
        let id = SocketId(self.next);
        self.next = next;
        self.advertised.push(Entry::new(id, socket));
        Ok(id)
    }

    /// The identity of the socket bound to exactly `local`, whichever role it has. A socket bound
    /// to a wildcard address is not a match: it receives datagrams addressed to many local
    /// addresses and its own is not one of them.
    pub(crate) fn id_for_local(&self, local: std::net::SocketAddr) -> Option<SocketId> {
        self.entries()
            .find(|entry| !entry.failed && entry.socket.local_addr() == local)
            .map(|entry| entry.id)
    }

    /// Whether the socket named `id` can carry the path whose local address is `local`: it is
    /// bound to a wildcard of the same port and family (or an IPv6 wildcard that has actually
    /// received IPv4), and it can select a source address per datagram. Without that capability the sender refuses such a datagram
    /// (`DatagramError::Unsupported(SendSourceIp)`), so a wildcard bind alone does not make the
    /// socket usable for that path.
    pub(crate) fn covers_local(&self, id: SocketId, local: std::net::SocketAddr) -> bool {
        self.entry(id).is_some_and(|entry| covers(entry, local))
    }

    /// The only retained socket that can carry the path whose local address is `local` by covering
    /// it, if exactly one can. Where several could, none is chosen: picking one of several
    /// overlapping wildcard sockets would put the datagram on an arbitrary one.
    pub(crate) fn only_cover_for(&self, local: std::net::SocketAddr) -> Option<SocketId> {
        let mut found = None;
        for entry in self.entries().filter(|entry| covers(entry, local)) {
            if found.is_some() {
                return None;
            }
            found = Some(entry.id);
        }
        found
    }

    /// The addresses this endpoint advertises, in the order they were bound.
    pub(crate) fn advertised_addrs(&self) -> impl Iterator<Item = std::net::SocketAddr> + '_ {
        self.advertised
            .iter()
            .map(|entry| entry.socket.local_addr())
    }

    /// Identities of the retained sockets, active first.
    pub(crate) fn ids(&self) -> impl Iterator<Item = SocketId> + '_ {
        self.entries().map(|e| e.id)
    }

    pub(crate) fn local_addr(&self, id: SocketId) -> Option<std::net::SocketAddr> {
        self.entry(id).map(|e| e.socket.local_addr())
    }

    /// Whether `id` names a retained, usable socket.
    pub(crate) fn is_usable(&self, id: SocketId) -> bool {
        self.entry(id).is_some_and(|e| !e.failed)
    }

    /// Make `socket` the active one. The previous active socket is retired at once when nothing
    /// depends on it (returned for dropping outside the lock); otherwise it is kept until its
    /// dependents release it. Refused, without any change and handing `socket` back, when the
    /// retained set is already at [`MAX_RETAINED_SOCKETS`] or the identity space is exhausted.
    pub(crate) fn activate(
        &mut self,
        socket: Socket,
        now: Instant,
    ) -> Result<(SocketId, Option<Socket>), RebindRefused> {
        let previous_idle = self.active.idle(now);
        if !previous_idle && self.len() >= MAX_RETAINED_SOCKETS {
            return Err(RebindRefused {
                error: io::Error::new(
                    io::ErrorKind::QuotaExceeded,
                    "too many retiring QUIC sockets still in use; the previous socket is kept",
                ),
                socket,
            });
        }
        let Some(next) = self.next.checked_add(1) else {
            return Err(RebindRefused {
                error: io::Error::new(
                    io::ErrorKind::QuotaExceeded,
                    "QUIC socket identity space exhausted; the previous socket is kept",
                ),
                socket,
            });
        };
        let id = SocketId(self.next);
        self.next = next;
        let previous = std::mem::replace(&mut self.active, Entry::new(id, socket));
        if previous_idle {
            self.fold(&previous.socket);
            Ok((id, Some(previous.socket)))
        } else {
            self.retiring.push(previous);
            Ok((id, None))
        }
    }

    /// Keep socket `id` receiving until `until` (the hold ends at that instant): a Retry sent
    /// from it told the peer to come back to this address, and nothing else may depend on the
    /// socket by then. The hold expires on its own (see [`expire_routes`](Self::expire_routes));
    /// a later, longer hold extends it. A failed socket cannot receive, so no hold is placed on
    /// it.
    pub(crate) fn hold_route(&mut self, id: SocketId, until: Instant) {
        if let Some(entry) = self.entry_mut(id).filter(|entry| !entry.failed) {
            entry.route_until = Some(
                entry
                    .route_until
                    .map_or(until, |current| current.max(until)),
            );
        }
    }

    /// The earliest instant at which a route hold on a retiring socket expires.
    pub(crate) fn next_route_expiry(&self) -> Option<Instant> {
        self.retiring.iter().filter_map(|e| e.route_until).min()
    }

    /// Retire retiring sockets whose route hold has ended (`until <= now`) and that nothing else
    /// depends on.
    pub(crate) fn expire_routes(&mut self, now: Instant) -> Vec<Socket> {
        for entry in &mut self.retiring {
            if entry.route_until.is_some_and(|until| until <= now) {
                entry.route_until = None;
            }
        }
        self.retire_idle(now)
    }

    /// Create a send handle for `id`; the handle owns a connection lease on the socket. `None`
    /// when the socket is gone or unusable.
    pub(crate) fn sender(&mut self, id: SocketId) -> Option<Sender> {
        let entry = self.entry_mut(id)?;
        if entry.failed {
            return None;
        }
        entry.connections += 1;
        Some(entry.socket.sender_for(Lease {
            id,
            kind: Dependent::Connection,
        }))
    }

    /// Lease `id` for an attempt received on it. `None` when the socket is gone.
    pub(crate) fn acquire_attempt(&mut self, id: SocketId) -> Option<Lease> {
        let entry = self.entry_mut(id)?;
        entry.attempts += 1;
        Some(Lease {
            id,
            kind: Dependent::Attempt,
        })
    }

    /// Release a lease; the socket is retired (and returned for dropping outside the lock)
    /// when nothing depends on it any more. A lease on an already retired socket (shutdown) is
    /// simply consumed.
    #[expect(
        clippy::needless_pass_by_value,
        reason = "the lease is spent here, so it is taken rather than borrowed"
    )]
    pub(crate) fn release(&mut self, lease: Lease, now: Instant) -> Option<Socket> {
        let Lease { id, kind } = lease;
        let entry = self.entry_mut(id)?;
        match kind {
            Dependent::Connection => entry.connections = entry.connections.saturating_sub(1),
            Dependent::Attempt => entry.attempts = entry.attempts.saturating_sub(1),
        }
        self.retire_if_idle(id, now)
    }

    /// Queue a stateless response on the socket the triggering datagram arrived on. A response
    /// for a socket that is gone or unusable is dropped and counted: it must never leave from an
    /// unrelated local address.
    pub(crate) fn respond(&mut self, id: SocketId, transmit: proto::Transmit, buffer: &[u8]) {
        match self.entry_mut(id) {
            Some(entry) if !entry.failed => {
                entry.socket.queue_response(transmit, buffer);
            }
            _ => self.retired.dropped_responses += 1,
        }
    }

    /// The non-failed sockets to poll, in rotation order. The order advances on every call so a
    /// busy socket cannot always go first.
    pub(crate) fn receive_order(&mut self) -> Order {
        let live = self.live_order();
        if live.len == 0 {
            return live;
        }
        self.cursor = (self.cursor + 1) % live.len;
        live.rotated(self.cursor)
    }

    /// The next receive pass starts at `id`: the sockets a spent allowance left unvisited come
    /// first, so a busy socket earlier in the rotation cannot starve them.
    pub(crate) fn continue_receive_from(&mut self, id: SocketId) {
        let live = self.live_order();
        if let Some(pos) = live.iter().position(|live_id| live_id == id) {
            self.cursor = (pos + live.len - 1) % live.len;
        }
    }

    fn live_order(&self) -> Order {
        let mut order = Order::new();
        for entry in self.entries().filter(|e| !e.failed) {
            order.push(entry.id);
        }
        order
    }

    pub(crate) fn socket_mut(&mut self, id: SocketId) -> Option<&mut Socket> {
        self.entry_mut(id).map(|e| &mut e.socket)
    }

    /// A receive error on `id`: fatal for the active socket, otherwise the socket is marked
    /// failed (its queued responses dropped and counted, its route hold void) and retired if
    /// nothing depends on it. The caller tells the connections that depend on a failed socket.
    pub(crate) fn receive_failed(
        &mut self,
        id: SocketId,
        error: io::Error,
        now: Instant,
    ) -> io::Result<Option<Socket>> {
        if id == self.active.id {
            return Err(error);
        }
        Ok(self.mark_failed(id, now))
    }

    fn mark_failed(&mut self, id: SocketId, now: Instant) -> Option<Socket> {
        if let Some(entry) = self.entry_mut(id) {
            entry.failed = true;
            entry.route_until = None;
            self.retired.dropped_responses += entry.socket.discard_responses();
        }
        // A failed advertised socket is on its way out: its address is recorded for withdrawal
        // first, so the caller can stop advertising it whatever becomes of the entry, and it then
        // moves in with the retiring ones to be retired once its dependents have left rather than
        // holding a retained slot until the endpoint shuts down.
        if let Some(pos) = self.advertised.iter().position(|entry| entry.id == id) {
            let entry = self.advertised.remove(pos);
            self.withdrawn.push(entry.socket.local_addr());
            self.retiring.push(entry);
        }
        self.retire_if_idle(id, now)
    }

    /// Addresses this endpoint advertised and no longer has a usable socket for. Each is reported
    /// once, and the caller stops advertising it.
    pub(crate) fn take_withdrawn(&mut self) -> Vec<std::net::SocketAddr> {
        std::mem::take(&mut self.withdrawn)
    }

    /// Identities of the failed sockets whose dependents have not been told yet; each is
    /// reported once, and the endpoint releases the queued attempts and tells the connections
    /// to leave the dead path.
    pub(crate) fn take_failed_to_announce(&mut self) -> Order {
        let mut order = Order::new();
        for entry in self
            .retiring
            .iter_mut()
            .chain(self.advertised.iter_mut())
            .filter(|e| e.failed && !e.failure_announced)
        {
            entry.failure_announced = true;
            order.push(entry.id);
        }
        order
    }

    /// Drive queued stateless responses on every socket, in rotation order, under one shared
    /// per-poll budget. An unusable active socket is fatal; an unusable retiring socket is
    /// marked failed. `keep_going` is set only when runnable work remains: a socket whose budget
    /// share ran out with responses left, or a socket with responses the budget never reached.
    /// A socket whose sender returned `Pending` registered the task's waker and is not runnable.
    pub(crate) fn drive_responses(
        &mut self,
        cx: &mut Context<'_>,
        now: Instant,
    ) -> io::Result<ResponsesDriven> {
        let mut keep_going = false;
        let mut failed = Order::new();
        let active = self.active.id;
        let mut budget = RESPONSE_WORK_LIMIT;
        let order = self.live_order().rotated(self.cursor);
        for id in order.iter() {
            let Some(entry) = self.entry_mut(id) else {
                continue;
            };
            if budget == 0 {
                // Unvisited runnable work: only a poll can tell whether its sender is ready.
                keep_going |= entry.socket.has_responses();
                continue;
            }
            match entry.socket.drive_responses_within(cx, now, &mut budget) {
                Ok(ResponseProgress::Drained | ResponseProgress::Pending) => {}
                Ok(ResponseProgress::Exhausted) => keep_going = true,
                Err(error) if entry.id == active => return Err(error),
                Err(_) => failed.push(entry.id),
            }
        }
        let mut retired = Vec::new();
        for id in failed.iter() {
            retired.extend(self.mark_failed(id, now));
        }
        retired.extend(self.retire_idle(now));
        Ok(ResponsesDriven {
            keep_going,
            retired,
        })
    }

    fn retire_if_idle(&mut self, id: SocketId, now: Instant) -> Option<Socket> {
        let pos = self
            .retiring
            .iter()
            .position(|e| e.id == id && e.idle(now))?;
        let entry = self.retiring.remove(pos);
        self.fold(&entry.socket);
        Some(entry.socket)
    }

    /// Retire every retiring socket nothing depends on any more; returns them for dropping
    /// outside the lock.
    pub(crate) fn retire_idle(&mut self, now: Instant) -> Vec<Socket> {
        let mut retired = Vec::new();
        while let Some(pos) = self.retiring.iter().position(|e| e.idle(now)) {
            let entry = self.retiring.remove(pos);
            self.fold(&entry.socket);
            retired.push(entry.socket);
        }
        retired
    }

    fn fold(&mut self, socket: &Socket) {
        self.retired.dropped_responses = self
            .retired
            .dropped_responses
            .saturating_add(socket.dropped_responses());
        self.retired.failed_responses = self
            .retired
            .failed_responses
            .saturating_add(socket.failed_responses());
        self.retired.sockets += 1;
    }

    /// Consume the registry, yielding every socket and the number of sockets ever retired
    /// (including these).
    fn into_sockets(mut self) -> (Vec<Socket>, u64) {
        let retiring = std::mem::take(&mut self.retiring);
        let advertised = std::mem::take(&mut self.advertised);
        let mut sockets: Vec<Socket> = retiring
            .into_iter()
            .chain(advertised)
            .map(|e| e.socket)
            .collect();
        sockets.push(self.active.socket);
        let retired = self.retired.sockets + sockets.len() as u64;
        (sockets, retired)
    }

    /// Response counters over retired and retained sockets, each socket counted exactly once.
    pub(crate) fn dropped_responses(&self) -> u64 {
        self.entries()
            .fold(self.retired.dropped_responses, |acc, e| {
                acc.saturating_add(e.socket.dropped_responses())
            })
    }

    pub(crate) fn failed_responses(&self) -> u64 {
        self.entries()
            .fold(self.retired.failed_responses, |acc, e| {
                acc.saturating_add(e.socket.failed_responses())
            })
    }

    /// Sockets retired so far.
    pub(crate) fn retired_sockets(&self) -> u64 {
        self.retired.sockets
    }

    #[cfg(test)]
    pub(crate) fn dependents(&self, id: SocketId) -> Option<(usize, usize)> {
        self.entry(id).map(|e| (e.connections, e.attempts))
    }

    /// Test seam: pretend the identity counter is at `next`.
    #[cfg(test)]
    pub(crate) fn set_next_id(&mut self, next: u64) {
        self.next = next;
    }
}

/// The endpoint's sockets: live while the endpoint driver runs, released afterwards so retained
/// application handles cannot keep ports bound.
#[derive(Debug)]
#[expect(
    clippy::large_enum_variant,
    reason = "one of these exists per endpoint, and the live registry is on the receive path"
)]
pub(crate) enum Sockets {
    Live(SocketRegistry),
    /// Every socket was dropped with the endpoint driver; only its counters remain.
    Released {
        dropped_responses: u64,
        failed_responses: u64,
        retired_sockets: u64,
    },
}

impl Sockets {
    pub(crate) fn live(&self) -> Option<&SocketRegistry> {
        match self {
            Self::Live(registry) => Some(registry),
            Self::Released { .. } => None,
        }
    }

    pub(crate) fn live_mut(&mut self) -> Option<&mut SocketRegistry> {
        match self {
            Self::Live(registry) => Some(registry),
            Self::Released { .. } => None,
        }
    }

    /// Drop every socket (the endpoint driver is gone), keeping the counters. Returns the
    /// sockets so the caller can drop them outside any lock; a second call returns nothing.
    pub(crate) fn release_all(&mut self) -> Vec<Socket> {
        let placeholder = Self::Released {
            dropped_responses: 0,
            failed_responses: 0,
            retired_sockets: 0,
        };
        match std::mem::replace(self, placeholder) {
            Self::Live(registry) => {
                let dropped_responses = registry.dropped_responses();
                let failed_responses = registry.failed_responses();
                let (sockets, retired_sockets) = registry.into_sockets();
                *self = Self::Released {
                    dropped_responses,
                    failed_responses,
                    retired_sockets,
                };
                sockets
            }
            released @ Self::Released { .. } => {
                *self = released;
                Vec::new()
            }
        }
    }

    pub(crate) fn dropped_responses(&self) -> u64 {
        match self {
            Self::Live(r) => r.dropped_responses(),
            Self::Released {
                dropped_responses, ..
            } => *dropped_responses,
        }
    }

    pub(crate) fn failed_responses(&self) -> u64 {
        match self {
            Self::Live(r) => r.failed_responses(),
            Self::Released {
                failed_responses, ..
            } => *failed_responses,
        }
    }

    pub(crate) fn retired_sockets(&self) -> u64 {
        match self {
            Self::Live(r) => r.retired_sockets(),
            Self::Released {
                retired_sockets, ..
            } => *retired_sockets,
        }
    }

    pub(crate) fn retained_sockets(&self) -> usize {
        match self {
            Self::Live(r) => r.len(),
            Self::Released { .. } => 0,
        }
    }

    /// Release a lease; returns the retired socket, if any, for dropping outside the lock. A
    /// lease outliving the sockets is consumed as a no-op.
    pub(crate) fn release(&mut self, lease: Lease, now: Instant) -> Option<Socket> {
        match self {
            Self::Live(registry) => registry.release(lease, now),
            Self::Released { .. } => None,
        }
    }

    /// Queue a response on the socket the datagram arrived on; dropped and counted when gone.
    pub(crate) fn respond(&mut self, id: SocketId, transmit: proto::Transmit, buffer: &[u8]) {
        match self {
            Self::Live(registry) => registry.respond(id, transmit, buffer),
            Self::Released {
                dropped_responses, ..
            } => *dropped_responses += 1,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::driver::{Duration, now};
    use rama_net::address::SocketAddress;
    use rama_udp::{
        DatagramCapabilities, DatagramError, DatagramMetadata, DatagramSender, DatagramSocket,
        SendDatagram,
    };
    use std::{
        io::IoSliceMut,
        sync::{
            Arc,
            atomic::{AtomicUsize, Ordering},
        },
        task::{Poll, Waker},
    };

    /// Receives nothing; sends succeed and are counted while `ready`, else stay pending.
    #[derive(Debug)]
    struct NullSocket {
        port: u16,
        sent: Arc<AtomicUsize>,
        ready: Arc<std::sync::atomic::AtomicBool>,
    }

    impl rama_net::stream::Socket for NullSocket {
        fn local_addr(&self) -> io::Result<SocketAddress> {
            Ok(([127, 0, 0, 1], self.port).into())
        }
        fn peer_addr(&self) -> io::Result<SocketAddress> {
            Err(io::ErrorKind::NotConnected.into())
        }
    }

    impl DatagramSocket for NullSocket {
        type Sender = NullSender;
        fn create_sender(&self) -> NullSender {
            NullSender(self.sent.clone(), self.ready.clone())
        }
        fn poll_recv(
            &mut self,
            _cx: &mut Context<'_>,
            _buffers: &mut [IoSliceMut<'_>],
            _metadata: &mut [DatagramMetadata],
        ) -> Poll<Result<usize, DatagramError>> {
            Poll::Pending
        }
        fn capabilities(&self) -> DatagramCapabilities {
            DatagramCapabilities::default()
        }
    }

    #[derive(Debug)]
    struct NullSender(Arc<AtomicUsize>, Arc<std::sync::atomic::AtomicBool>);

    impl DatagramSender for NullSender {
        fn poll_send(
            &mut self,
            _cx: &mut Context<'_>,
            _datagram: &SendDatagram<'_>,
        ) -> Poll<Result<(), DatagramError>> {
            if !self.1.load(Ordering::SeqCst) {
                return Poll::Pending;
            }
            self.0.fetch_add(1, Ordering::Relaxed);
            Poll::Ready(Ok(()))
        }
        fn capabilities(&self) -> DatagramCapabilities {
            DatagramCapabilities::default()
        }
    }

    fn socket(port: u16) -> (Socket, Arc<AtomicUsize>) {
        let (socket, _ready, sent) = gated_socket(port);
        _ready.store(true, Ordering::SeqCst);
        (socket, sent)
    }

    fn gated_socket(port: u16) -> (Socket, Arc<std::sync::atomic::AtomicBool>, Arc<AtomicUsize>) {
        let sent = Arc::new(AtomicUsize::new(0));
        let ready = Arc::new(std::sync::atomic::AtomicBool::new(false));
        (
            Socket::new(NullSocket {
                port,
                sent: sent.clone(),
                ready: ready.clone(),
            })
            .unwrap(),
            ready,
            sent,
        )
    }

    fn transmit() -> proto::Transmit {
        proto::Transmit {
            destination: ([127, 0, 0, 2], 5555).into(),
            ecn: None,
            size: 1,
            segment_size: None,
            local: None,
            cid_used: None,
        }
    }

    #[test]
    fn identities_are_never_reused_and_an_idle_previous_socket_retires_at_once() {
        let mut registry = SocketRegistry::new(socket(1).0);
        let first = registry.active_id();
        let (second, retired) = registry.activate(socket(2).0, now()).unwrap();
        assert_ne!(first, second);
        assert!(
            retired.is_some(),
            "an idle previous socket is handed back at once"
        );
        assert_eq!(registry.len(), 1);
        assert_eq!(registry.retired_sockets(), 1);
        assert!(!registry.is_usable(first));
        let (third, _) = registry.activate(socket(3).0, now()).unwrap();
        assert!(
            third != first && third != second,
            "ids are monotonic, never recycled"
        );
        assert_eq!(registry.local_addr(third).unwrap().port(), 3);
    }

    #[test]
    fn identity_exhaustion_is_refused_before_any_change() {
        let mut registry = SocketRegistry::new(socket(1).0);
        let lease = registry.acquire_attempt(registry.active_id()).unwrap();
        // The last assignable identity is `u64::MAX - 1`: assigning it leaves no successor.
        registry.set_next_id(u64::MAX - 1);
        let (last, _) = registry.activate(socket(2).0, now()).unwrap();
        assert_eq!(registry.len(), 2);
        let error = registry.activate(socket(3).0, now()).unwrap_err();
        assert_eq!(error.error.kind(), io::ErrorKind::QuotaExceeded);
        assert_eq!(registry.active_id(), last, "nothing changed on refusal");
        assert_eq!(registry.len(), 2);
        drop(registry.release(lease, now()));
    }

    #[test]
    fn leases_keep_a_socket_and_the_last_release_retires_it() {
        let mut registry = SocketRegistry::new(socket(1).0);
        let a = registry.active_id();
        let sender = registry.sender(a).unwrap();
        let attempt = registry.acquire_attempt(a).unwrap();
        let (b, retired) = registry.activate(socket(2).0, now()).unwrap();
        assert!(retired.is_none(), "a socket with leases is retained");
        assert_eq!(registry.len(), 2);
        assert_eq!(registry.dependents(a), Some((1, 1)));
        assert!(
            registry.release(attempt, now()).is_none(),
            "the sender still holds it"
        );
        assert_eq!(registry.len(), 2);
        let mut sender = sender;
        let retired = registry.release(sender.take_lease().unwrap(), now());
        assert!(
            retired.is_some(),
            "retired after the last lease, handed back for dropping"
        );
        assert_eq!(registry.len(), 1);
        assert_eq!(registry.active_id(), b);
        assert!(
            registry.sender(a).is_none(),
            "a retired socket hands out no sender"
        );
        assert!(registry.acquire_attempt(a).is_none());
    }

    #[test]
    fn queued_responses_keep_a_retiring_socket_until_sent() {
        let mut registry = SocketRegistry::new(socket(1).0);
        let a = registry.active_id();
        registry.respond(a, transmit(), &[0]);
        let (_, retired) = registry.activate(socket(2).0, now()).unwrap();
        assert!(retired.is_none(), "a queued response is a dependency");
        assert_eq!(registry.len(), 2);
        let mut cx = Context::from_waker(Waker::noop());
        let driven = registry.drive_responses(&mut cx, Instant::now()).unwrap();
        assert!(!driven.keep_going);
        assert_eq!(driven.retired.len(), 1, "retired once its response left");
        assert_eq!(registry.len(), 1);
        // A response for a socket that is gone is dropped and counted, never re-routed.
        registry.respond(a, transmit(), &[0]);
        assert_eq!(registry.dropped_responses(), 1);
    }

    #[test]
    fn the_retained_bound_refuses_without_changing_anything() {
        let mut registry = SocketRegistry::new(socket(1).0);
        let mut held = Vec::new();
        for port in 2..=(MAX_RETAINED_SOCKETS as u16) {
            held.push(registry.sender(registry.active_id()).unwrap());
            registry.activate(socket(port).0, now()).unwrap();
        }
        assert_eq!(registry.len(), MAX_RETAINED_SOCKETS);
        let active = registry.active_id();
        held.push(registry.sender(active).unwrap());
        let error = registry.activate(socket(99).0, now()).unwrap_err();
        assert_eq!(error.error.kind(), io::ErrorKind::QuotaExceeded);
        assert_eq!(
            registry.active_id(),
            active,
            "the refused rebind changed nothing"
        );
        assert_eq!(registry.len(), MAX_RETAINED_SOCKETS);
        // Releasing one earlier lease makes room again.
        let mut first = held.remove(0);
        assert!(
            registry
                .release(first.take_lease().unwrap(), now())
                .is_some()
        );
        assert_eq!(registry.len(), MAX_RETAINED_SOCKETS - 1);
        registry.activate(socket(99).0, now()).unwrap();
        assert_eq!(
            registry.local_addr(registry.active_id()).unwrap().port(),
            99
        );
    }

    #[test]
    fn a_failed_retiring_socket_drops_its_responses_and_leaves_with_its_dependents() {
        let mut registry = SocketRegistry::new(socket(1).0);
        let a = registry.active_id();
        let attempt = registry.acquire_attempt(a).unwrap();
        registry.respond(a, transmit(), &[0]);
        registry.respond(a, transmit(), &[0]);
        registry.activate(socket(2).0, now()).unwrap();
        let retired = registry
            .receive_failed(a, io::Error::other("stale"), now())
            .expect("a retiring socket's failure is not fatal");
        assert!(retired.is_none(), "kept while the attempt depends on it");
        assert!(!registry.is_usable(a));
        assert_eq!(
            registry.dropped_responses(),
            2,
            "its queued responses are dropped"
        );
        assert_eq!(registry.len(), 2);
        assert!(registry.sender(a).is_none());
        assert!(registry.release(attempt, now()).is_some());
        assert_eq!(registry.len(), 1);
        // The active socket's failure is fatal for the caller.
        let active = registry.active_id();
        registry
            .receive_failed(active, io::Error::other("fatal"), now())
            .expect_err("the active socket's failure reaches the caller");
    }

    #[test]
    fn receive_order_rotates_and_skips_failed_sockets() {
        let mut registry = SocketRegistry::new(socket(1).0);
        let a = registry.active_id();
        let _la = registry.acquire_attempt(a).unwrap();
        let (b, _) = registry.activate(socket(2).0, now()).unwrap();
        let _lb = registry.acquire_attempt(b).unwrap();
        let (c, _) = registry.activate(socket(3).0, now()).unwrap();
        let first = registry.receive_order().to_vec();
        let second = registry.receive_order().to_vec();
        assert_eq!(first.len(), 3);
        assert_ne!(first, second, "the starting socket rotates");
        assert_eq!(first[0], second[2], "rotation, not a shuffle");
        registry
            .receive_failed(b, io::Error::other("x"), now())
            .unwrap();
        let order = registry.receive_order().to_vec();
        assert!(!order.contains(&b));
        assert!(order.contains(&a) && order.contains(&c));
    }

    #[test]
    fn response_budget_is_shared_across_sockets_and_requests_continuation() {
        let mut registry = SocketRegistry::new(socket(1).0);
        let a = registry.active_id();
        let _la = registry.acquire_attempt(a).unwrap();
        for _ in 0..RESPONSE_WORK_LIMIT {
            registry.respond(a, transmit(), &[0]);
        }
        let (b_socket, sent_b) = socket(2);
        let (b, _) = registry.activate(b_socket, now()).unwrap();
        for _ in 0..4 {
            registry.respond(b, transmit(), &[0]);
        }
        let mut cx = Context::from_waker(Waker::noop());
        let driven = registry.drive_responses(&mut cx, Instant::now()).unwrap();
        assert!(
            driven.keep_going,
            "one budget cannot drain both sockets; the driver must be polled again"
        );
        let driven = registry.drive_responses(&mut cx, Instant::now()).unwrap();
        assert!(!driven.keep_going, "the second pass finishes the rest");
        assert_eq!(sent_b.load(Ordering::Relaxed), 4);
    }

    #[test]
    fn a_pending_sender_parks_instead_of_requesting_continuation() {
        let mut registry = SocketRegistry::new(socket(1).0);
        let (blocked, ready, _) = gated_socket(2);
        let (b, _) = registry.activate(blocked, now()).unwrap();
        registry.respond(b, transmit(), &[0]);
        registry.respond(b, transmit(), &[0]);
        let mut cx = Context::from_waker(Waker::noop());
        let driven = registry.drive_responses(&mut cx, Instant::now()).unwrap();
        assert!(
            !driven.keep_going,
            "a sender that returned Pending registered the waker; no self re-poll"
        );
        // Other sockets with runnable work still ask for continuation while one is parked.
        let a_id = registry.ids().find(|id| *id != b);
        assert!(
            a_id.is_none(),
            "the idle first socket was retired on activation"
        );
        ready.store(true, Ordering::SeqCst);
        let driven = registry.drive_responses(&mut cx, Instant::now()).unwrap();
        assert!(!driven.keep_going);
        assert!(
            !registry.active().has_responses(),
            "both responses left once ready"
        );
    }

    #[test]
    fn releasing_everything_keeps_the_counters_exactly_once() {
        let mut sockets = Sockets::Live(SocketRegistry::new(socket(1).0));
        let registry = sockets.live_mut().unwrap();
        let a = registry.active_id();
        let lease = registry.acquire_attempt(a).unwrap();
        let mut oversized = transmit();
        oversized.size = 100_000; // over the byte limit: dropped and counted on socket 1
        registry.respond(a, oversized, &[0; 100_000]);
        registry.activate(socket(2).0, now()).unwrap();
        assert_eq!(registry.dropped_responses(), 1);
        let dropped = sockets.release_all();
        assert_eq!(
            dropped.len(),
            2,
            "both sockets are handed back for dropping"
        );
        assert_eq!(sockets.dropped_responses(), 1);
        assert_eq!(sockets.retired_sockets(), 2);
        assert_eq!(sockets.retained_sockets(), 0);
        assert!(
            sockets.release_all().is_empty(),
            "a second release yields nothing"
        );
        // Late releases and responses are counted, never routed.
        assert!(sockets.release(lease, now()).is_none());
        sockets.respond(a, transmit(), &[0]);
        assert_eq!(sockets.dropped_responses(), 2);
    }
    #[test]
    fn a_route_hold_keeps_a_replaced_socket_until_it_expires() {
        let start = now();
        let mut registry = SocketRegistry::new(socket(1).0);
        let a = registry.active_id();
        registry.hold_route(a, start + Duration::from_secs(1));
        // A shorter hold never shortens the existing one.
        registry.hold_route(a, start + Duration::from_millis(100));
        let (_, retired) = registry.activate(socket(2).0, start).unwrap();
        assert!(retired.is_none(), "the route hold keeps A");
        assert_eq!(registry.len(), 2);
        assert_eq!(
            registry.next_route_expiry(),
            Some(start + Duration::from_secs(1))
        );
        assert!(
            registry
                .expire_routes(
                    (start + Duration::from_secs(1))
                        .checked_sub(Duration::from_nanos(1))
                        .expect("a second past the start is past the epoch"),
                )
                .is_empty(),
            "the hold lasts until its instant"
        );
        assert_eq!(registry.len(), 2);
        let retired = registry.expire_routes(start + Duration::from_secs(1));
        assert_eq!(retired.len(), 1, "and ends exactly there");
        assert_eq!(retired[0].local_addr().port(), 1);
        assert_eq!(registry.len(), 1);
        assert_eq!(registry.next_route_expiry(), None);
        assert_eq!(registry.retired_sockets(), 1);
    }

    #[test]
    fn a_route_hold_on_an_unknown_or_failed_socket_is_ignored() {
        let start = now();
        let mut registry = SocketRegistry::new(socket(1).0);
        let a = registry.active_id();
        let _lease = registry.acquire_attempt(a).unwrap();
        registry.activate(socket(2).0, start).unwrap();
        registry
            .receive_failed(a, io::Error::other("dead"), start)
            .unwrap();
        registry.hold_route(a, start + Duration::from_secs(5));
        assert_eq!(
            registry.next_route_expiry(),
            None,
            "a failed socket cannot receive, so no route is held on it"
        );
        registry.hold_route(SocketId(77), start + Duration::from_secs(5));
        assert_eq!(registry.next_route_expiry(), None);
    }

    #[test]
    fn route_holds_count_against_the_retained_bound_and_a_refused_rebind_hands_back_the_socket() {
        let start = now();
        let mut registry = SocketRegistry::new(socket(1).0);
        for port in 2..=MAX_RETAINED_SOCKETS as u16 {
            registry.hold_route(registry.active_id(), start + Duration::from_secs(1));
            registry.activate(socket(port).0, start).unwrap();
        }
        assert_eq!(registry.len(), MAX_RETAINED_SOCKETS);
        registry.hold_route(registry.active_id(), start + Duration::from_secs(1));
        let refused = registry.activate(socket(99).0, start).unwrap_err();
        assert_eq!(refused.error.kind(), io::ErrorKind::QuotaExceeded);
        assert_eq!(
            refused.socket.local_addr().port(),
            99,
            "the rejected socket comes back to the caller"
        );
        assert_eq!(registry.len(), MAX_RETAINED_SOCKETS);
        assert_eq!(registry.retire_idle(start).len(), 0);
        // Expiry frees the whole set but the active socket, and rebinding works again.
        assert_eq!(
            registry.expire_routes(start + Duration::from_secs(2)).len(),
            MAX_RETAINED_SOCKETS - 1
        );
        registry.activate(refused.socket, start).unwrap();
        assert_eq!(registry.active().local_addr().port(), 99);
    }

    #[test]
    fn identity_exhaustion_is_refused_with_the_socket_returned_and_nothing_changed() {
        let start = now();
        let mut registry = SocketRegistry::new(socket(1).0);
        registry.set_next_id(u64::MAX - 1);
        let (id, retired) = registry.activate(socket(2).0, start).unwrap();
        assert_eq!(id, SocketId(u64::MAX - 1));
        assert!(retired.is_some());
        let refused = registry.activate(socket(3).0, start).unwrap_err();
        assert_eq!(refused.error.kind(), io::ErrorKind::QuotaExceeded);
        assert_eq!(refused.socket.local_addr().port(), 3);
        assert_eq!(registry.active_id(), id);
        assert_eq!(registry.len(), 1);
    }

    #[test]
    fn failed_sockets_are_announced_exactly_once() {
        let start = now();
        let mut registry = SocketRegistry::new(socket(1).0);
        let a = registry.active_id();
        let sender_a = registry.sender(a).unwrap();
        let (b, _) = registry.activate(socket(2).0, start).unwrap();
        let _attempt_b = registry.acquire_attempt(b).unwrap();
        let (_c, _) = registry.activate(socket(3).0, start).unwrap();
        assert!(registry.take_failed_to_announce().to_vec().is_empty());
        registry
            .receive_failed(a, io::Error::other("dead"), start)
            .unwrap();
        registry
            .receive_failed(b, io::Error::other("dead"), start)
            .unwrap();
        assert_eq!(
            registry.take_failed_to_announce().to_vec(),
            vec![a, b],
            "every failed socket with dependents is announced, in retirement order"
        );
        assert!(
            registry.take_failed_to_announce().to_vec().is_empty(),
            "announced once"
        );
        // A late response to the failed socket is dropped and counted, never queued.
        registry.respond(a, transmit(), b"x");
        assert_eq!(registry.dropped_responses(), 1);
        assert!(!registry.socket_mut(a).unwrap().has_responses());
        assert!(
            registry.sender(a).is_none(),
            "no new senders on a failed socket"
        );
        let mut sender_a = sender_a;
        assert!(
            registry
                .release(sender_a.take_lease().unwrap(), start)
                .is_some(),
            "the failed socket retires with its last lease"
        );
        assert_eq!(registry.len(), 2);
    }

    #[test]
    fn a_spent_allowance_continues_from_the_first_unvisited_socket() {
        let start = now();
        let mut registry = SocketRegistry::new(socket(1).0);
        let a = registry.active_id();
        let _la = registry.acquire_attempt(a).unwrap();
        let (b, _) = registry.activate(socket(2).0, start).unwrap();
        let _lb = registry.acquire_attempt(b).unwrap();
        let (c, _) = registry.activate(socket(3).0, start).unwrap();
        for _ in 0..4 {
            let order = registry.receive_order().to_vec();
            // The pass served two sockets and stopped before the third; the next pass starts
            // there (a plain one-step rotation would start at the second instead).
            registry.continue_receive_from(order[2]);
            let next = registry.receive_order().to_vec();
            assert_eq!(next[0], order[2]);
            assert_eq!(next[1], order[0]);
            assert_eq!(next.len(), 3);
        }
        registry.continue_receive_from(SocketId(999));
        assert_eq!(
            registry.receive_order().to_vec().len(),
            3,
            "an unknown id changes nothing"
        );
        assert!(
            [a, b, c]
                .iter()
                .all(|id| registry.receive_order().to_vec().contains(id))
        );
    }
}
