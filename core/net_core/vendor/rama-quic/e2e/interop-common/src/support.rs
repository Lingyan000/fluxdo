//! Bounded waiting, task ownership and deterministic payloads, shared by every scenario.

use std::{
    future::{Future, IntoFuture},
    net::{IpAddr, Ipv4Addr, Ipv6Addr, SocketAddr, SocketAddrV6},
    time::Duration,
};

use sha2::{Digest, Sha256};
use tokio::time::Instant;

/// How long one scenario's protocol work may take. Every await inside a scenario shares this,
/// so a stall anywhere fails the scenario rather than extending it.
pub const SCENARIO_LIMIT: Duration = Duration::from_secs(20);

/// The QUIC idle timeout both peers advertise, kept well above every scenario's deadline. The
/// effective idle timeout is the minimum of the two ends, so a value under a deadline lets a
/// connection expire mid-exchange under load; the scenario's own deadline is the one bound.
pub const IDLE_TIMEOUT: Duration = Duration::from_secs(60);

/// One scenario's deadline, taken once and shared by every await under it.
#[derive(Debug, Clone, Copy)]
pub struct Deadline(Instant);

impl Deadline {
    /// A deadline of the usual length, starting now.
    #[must_use]
    pub fn new() -> Self {
        Self(Instant::now() + SCENARIO_LIMIT)
    }

    /// A deadline of the caller's own length, for a scenario that is about waiting.
    #[must_use]
    pub fn of(limit: Duration) -> Self {
        Self(Instant::now() + limit)
    }

    /// Await one step, naming it so a failure says which step ran out of the scenario's time.
    /// Anything awaitable is accepted, so a handle that becomes a future is bounded like one.
    pub async fn wait<F: IntoFuture>(self, what: &str, future: F) -> F::Output {
        match tokio::time::timeout_at(self.0, future.into_future()).await {
            Ok(value) => value,
            Err(_) => panic!("{what}: the scenario's deadline ran out"),
        }
    }

    /// Await one step, answering `None` when the deadline passes rather than failing.
    pub async fn try_wait<F: IntoFuture>(self, future: F) -> Option<F::Output> {
        tokio::time::timeout_at(self.0, future.into_future())
            .await
            .ok()
    }

    /// What is left of the scenario's time.
    #[must_use]
    pub fn remaining(self) -> Duration {
        self.0.saturating_duration_since(Instant::now())
    }

    /// The moment the scenario must be finished by, for a peer that waits on it directly.
    #[must_use]
    pub fn at(self) -> Instant {
        self.0
    }

    #[must_use]
    pub fn passed(self) -> bool {
        Instant::now() >= self.0
    }

    /// The soonest of this deadline and a timer a peer's own connection asked for. A driver
    /// that owns no sockets needs this to know how long it may sleep.
    #[must_use]
    pub fn next_wake(self, timer: Option<Duration>) -> Instant {
        match timer {
            Some(timer) => self
                .0
                .min(Instant::now() + timer.max(Duration::from_millis(1))),
            None => self.0.min(Instant::now() + Duration::from_millis(5)),
        }
    }

    /// Fail now if the scenario is already out of time.
    pub fn expect(self, what: &str) {
        assert!(!self.passed(), "{what}: the scenario's deadline ran out");
    }
}

impl Default for Deadline {
    fn default() -> Self {
        Self::new()
    }
}

/// A spawned peer. The guard owns its handle for as long as it exists, including while a wait on
/// it is in progress, so a wait that is itself cancelled leaves the task with the guard. Dropping
/// the guard aborts the task; it does not wait for the task to unwind.
#[derive(Debug)]
pub struct Peer<T = ()>(Option<tokio::task::JoinHandle<T>>);

impl<T: Send + 'static> Peer<T> {
    pub fn spawn(task: impl Future<Output = T> + Send + 'static) -> Self {
        Self(Some(tokio::spawn(task)))
    }

    /// Whether the guard still owns the task, which is what keeps a cancelled wait from
    /// leaving it detached.
    #[must_use]
    pub fn owns_it(&self) -> bool {
        self.0.is_some()
    }

    /// Wait for the task and take what it produced, failing the scenario if it does not finish.
    pub async fn join(mut self, what: &str, deadline: Deadline) -> T {
        match self.try_join(deadline).await {
            Ok(value) => value,
            Err(reason) => panic!("{what}: {reason}"),
        }
    }

    /// Wait for the task, with the handle staying in the guard throughout. Awaiting it by value
    /// would drop it on a timeout, leaving the task detached; taking it out first would do the
    /// same if this wait were cancelled.
    pub async fn try_join(&mut self, deadline: Deadline) -> Result<T, String> {
        let handle = self.0.as_mut().expect("waited on once");
        let outcome = match tokio::time::timeout(deadline.remaining(), handle).await {
            Ok(Ok(value)) => Ok(value),
            Ok(Err(error)) if error.is_panic() => Err(format!("panicked: {error}")),
            Ok(Err(error)) => Err(format!("ended: {error}")),
            Err(_) => {
                let handle = self.0.as_mut().expect("still here");
                handle.abort();
                let _ = handle.await;
                Err("the scenario's deadline ran out".to_owned())
            }
        };
        // Whatever happened, the task is finished and the guard has nothing left to abort.
        self.0 = None;
        outcome
    }
}

impl<T> Drop for Peer<T> {
    fn drop(&mut self) {
        if let Some(handle) = self.0.take() {
            handle.abort();
        }
    }
}

#[must_use]
pub fn localhost() -> SocketAddr {
    SocketAddr::new(Ipv4Addr::LOCALHOST.into(), 0)
}

/// The same on the other socket family, for the cases that run over both.
#[must_use]
pub fn localhost_v6() -> SocketAddr {
    SocketAddr::new(Ipv6Addr::LOCALHOST.into(), 0)
}

/// The same endpoint however a peer holds it: a dual-stack socket reports an IPv4 peer as a
/// v4-mapped IPv6 address, which is the same endpoint as the IPv4 one it maps.
#[must_use]
pub fn same_endpoint(addr: SocketAddr) -> SocketAddr {
    match addr.ip() {
        IpAddr::V6(ip) => match ip.to_ipv4_mapped() {
            Some(ip) => SocketAddr::new(ip.into(), addr.port()),
            None => addr,
        },
        IpAddr::V4(_) => addr,
    }
}

/// An endpoint as a peer spells it. `SocketAddr`'s own parser takes no `%scope`, so an IPv6
/// address that carries one is put together here.
///
/// # Panics
/// If `text` is not an endpoint this understands.
#[must_use]
pub fn parse_endpoint(text: &str) -> SocketAddr {
    let Some((host, rest)) = text.strip_prefix('[').and_then(|it| it.split_once(']')) else {
        return text.parse().expect("an address that parses");
    };
    let (host, scope) = match host.split_once('%') {
        Some((host, scope)) => (host, scope.parse().expect("a scope that is a number")),
        None => (host, 0),
    };
    let port = rest
        .strip_prefix(':')
        .expect("a port after the address")
        .parse()
        .expect("a port that is a number");
    SocketAddrV6::new(
        host.parse().expect("an ipv6 address that parses"),
        port,
        0,
        scope,
    )
    .into()
}

#[must_use]
pub fn digest(payload: &[u8]) -> [u8; 32] {
    Sha256::digest(payload).into()
}

/// A payload whose every byte follows from its seed and position, so both ends can state what
/// they expect without carrying the bytes between them.
#[must_use]
pub fn payload(seed: u8, len: usize) -> Vec<u8> {
    (0..len).map(|i| (i as u8) ^ seed).collect()
}
