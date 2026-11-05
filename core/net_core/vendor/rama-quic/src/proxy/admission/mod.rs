//! Admission shared by every producer of inspected QUIC associations: per-source and global
//! limits, an inspection-start rate, and counters for what was refused and why.

use std::{
    error::Error,
    fmt,
    num::NonZeroUsize,
    sync::{
        Arc,
        atomic::{AtomicU64, Ordering},
    },
    time::Duration,
};

use ahash::HashMap;
use parking_lot::Mutex;
use rama_core::{Layer, Service, error::BoxError};
use rama_net::{
    address::{SocketAddress, ip::IntoCanonicalIpAddr as _},
    stream::Socket,
};
use rama_udp::{DatagramFeature, DatagramPeekInput, DatagramSocket};
use tokio::time::Instant;

use super::{QuicPeekRejectedError, QuicPeekRejection};
use crate::proto::SourceKey;

/// The addresses an association is fixed to. Its egress target is not part of it: other
/// targets do not make the same incoming datagrams distinguishable.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub struct AssociationKey {
    /// Where the client's datagrams arrive.
    pub ingress: SocketAddress,
    /// The client sending them.
    pub peer: SocketAddress,
}

/// Bounds applied before any datagram of an association is inspected. A source is an IPv4
/// address or an IPv6 /64.
#[derive(Debug, Clone, Copy)]
pub struct AssociationLimits {
    /// Associations held at once, across all sources.
    pub active: NonZeroUsize,
    /// Associations held at once by one source.
    pub active_per_source: NonZeroUsize,
    /// Sources remembered for their active associations or start rate.
    pub sources: NonZeroUsize,
    /// Active and quarantined associations remembered.
    pub tuples: NonZeroUsize,
    /// Associations started per window, across all sources.
    pub starts_per_window: NonZeroUsize,
    /// Associations started per window by one source.
    pub starts_per_source_window: NonZeroUsize,
    /// The span start rates are counted over.
    pub window: Duration,
    /// How long a closed association's addresses cannot start a new one, so its delayed
    /// datagrams cannot.
    pub quarantine: Duration,
}

impl AssociationLimits {
    /// Limits no single source can exhaust for the others, and whose history never fills
    /// before the active and start caps refuse.
    fn validate(&self) -> Result<(), AdmissionError> {
        let now = Instant::now();
        if self.window.is_zero()
            || self.quarantine.is_zero()
            || now.checked_add(self.window).is_none()
            || now.checked_add(self.quarantine).is_none()
        {
            return Err(AdmissionError::InvalidLimits);
        }
        // Closed associations stay remembered for a quarantine, which spans this many start
        // windows (with the one in progress).
        let windows = usize::try_from(
            self.quarantine
                .as_nanos()
                .div_ceil(self.window.as_nanos())
                .saturating_add(1),
        )
        .unwrap_or(usize::MAX);
        // History must never fill before the active and start caps do, or it refuses everyone.
        let tuples_needed = windows
            .saturating_mul(self.starts_per_window.get())
            .saturating_add(self.active.get());
        // A source stays remembered for a window after its own start, into the next global
        // window: two windows of new sources, plus the active ones.
        let sources_needed = self
            .starts_per_window
            .get()
            .saturating_mul(2)
            .saturating_add(self.active.get());
        if self.active_per_source >= self.active
            || self.starts_per_source_window >= self.starts_per_window
            || self.sources.get() < sources_needed
            || self.tuples.get() < tuples_needed
        {
            return Err(AdmissionError::InvalidLimits);
        }
        Ok(())
    }
}

/// Why an association was not admitted. A refusal consumes no slot and no start.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum AdmissionError {
    /// The limits would let one source exhaust them, or a span is zero or unrepresentable.
    InvalidLimits,
    /// The association's socket lacks what inspection relies on.
    Capability(DatagramFeature),
    /// All associations are held.
    ActiveLimit,
    /// This source holds all its associations.
    SourceLimit,
    /// Source or association history is full.
    HistoryLimit,
    /// The source, or all sources together, started their window's associations.
    RateLimit,
    /// These addresses are held or quarantined.
    TupleInUse,
}

impl fmt::Display for AdmissionError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::InvalidLimits => f.write_str("QUIC association limits can starve sources"),
            Self::Capability(feature) => {
                write!(f, "QUIC association socket lacks {feature:?}")
            }
            Self::ActiveLimit => f.write_str("QUIC association limit reached"),
            Self::SourceLimit => f.write_str("QUIC association limit reached for its source"),
            Self::HistoryLimit => f.write_str("QUIC association history full"),
            Self::RateLimit => f.write_str("QUIC association start rate reached"),
            Self::TupleInUse => f.write_str("QUIC association addresses held or quarantined"),
        }
    }
}

impl Error for AdmissionError {}

/// What a [`QuicAssociationAdmission`] refused, and how inspection of admitted associations
/// ended when it was refused too, since it was created.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct AdmissionStats {
    pub refused_capability: u64,
    pub refused_active: u64,
    pub refused_source: u64,
    pub refused_history: u64,
    pub refused_rate: u64,
    pub refused_tuple: u64,
    pub rejected_not_quic: u64,
    pub rejected_unsupported_version: u64,
    pub rejected_malformed: u64,
    pub rejected_budget: u64,
    pub rejected_deadline: u64,
    /// Datagrams a producer dropped instead of queueing them for an association.
    pub dropped_datagrams: u64,
}

#[derive(Debug, Default)]
struct Counters {
    refused: [AtomicU64; 6],
    rejected: [AtomicU64; 5],
    dropped: AtomicU64,
}

impl Counters {
    fn refused(&self, error: AdmissionError) {
        let index = match error {
            AdmissionError::InvalidLimits => return,
            AdmissionError::Capability(_) => 0,
            AdmissionError::ActiveLimit => 1,
            AdmissionError::SourceLimit => 2,
            AdmissionError::HistoryLimit => 3,
            AdmissionError::RateLimit => 4,
            AdmissionError::TupleInUse => 5,
        };
        self.refused[index].fetch_add(1, Ordering::Relaxed);
    }

    fn rejected(&self, rejection: QuicPeekRejection) {
        let index = match rejection {
            QuicPeekRejection::NotQuic => 0,
            QuicPeekRejection::UnsupportedVersion => 1,
            QuicPeekRejection::Malformed => 2,
            QuicPeekRejection::Budget => 3,
            QuicPeekRejection::Deadline => 4,
        };
        self.rejected[index].fetch_add(1, Ordering::Relaxed);
    }
}

/// Admission shared, by cloning, by every producer and listener of one policy domain.
#[derive(Debug, Clone)]
pub struct QuicAssociationAdmission(Arc<Inner>);

#[derive(Debug)]
struct Inner {
    limits: AssociationLimits,
    state: Mutex<State>,
    counters: Counters,
}

#[derive(Debug)]
struct State {
    active: usize,
    global: Rate,
    sources: HashMap<SourceKey, Source>,
    tuples: HashMap<AssociationKey, Option<Instant>>,
}

#[derive(Debug)]
struct Source {
    active: usize,
    rate: Rate,
}

#[derive(Debug)]
struct Rate {
    since: Instant,
    used: usize,
}

impl Rate {
    fn refresh(&mut self, now: Instant, window: Duration) {
        if now.saturating_duration_since(self.since) >= window {
            self.since = now;
            self.used = 0;
        }
    }
}

impl QuicAssociationAdmission {
    /// Admission under `limits`, which must not let one source exhaust them.
    pub fn try_new(limits: AssociationLimits) -> Result<Self, AdmissionError> {
        limits.validate()?;
        Ok(Self(Arc::new(Inner {
            limits,
            state: Mutex::new(State {
                active: 0,
                global: Rate {
                    since: Instant::now(),
                    used: 0,
                },
                sources: HashMap::default(),
                tuples: HashMap::default(),
            }),
            counters: Counters::default(),
        })))
    }

    /// Admit the association at `key`, held until the permit is dropped. IPv4-mapped IPv6
    /// addresses count as their IPv4 form.
    pub fn try_acquire(&self, key: AssociationKey) -> Result<AssociationPermit, AdmissionError> {
        self.acquire(key)
            .inspect_err(|error| self.0.counters.refused(*error))
    }

    fn acquire(&self, key: AssociationKey) -> Result<AssociationPermit, AdmissionError> {
        let key = AssociationKey {
            ingress: key.ingress.into_canonical_ip_addr(),
            peer: key.peer.into_canonical_ip_addr(),
        };
        let source_key = SourceKey::of(key.peer.ip_addr);
        let now = Instant::now();
        let limits = self.0.limits;
        let mut state = self.0.state.lock();
        state.global.refresh(now, limits.window);
        // Both history maps are capped, so pruning them never grows with lifetime traffic.
        state
            .tuples
            .retain(|_, expires| expires.is_none_or(|expires| now < expires));
        state.sources.retain(|_, source| {
            source.rate.refresh(now, limits.window);
            source.active != 0 || source.rate.used != 0
        });
        if state.tuples.contains_key(&key) {
            return Err(AdmissionError::TupleInUse);
        }
        if state.active >= limits.active.get() {
            return Err(AdmissionError::ActiveLimit);
        }
        let source = state.sources.get(&source_key);
        if source.is_some_and(|source| source.active >= limits.active_per_source.get()) {
            return Err(AdmissionError::SourceLimit);
        }
        if state.tuples.len() >= limits.tuples.get()
            || (source.is_none() && state.sources.len() >= limits.sources.get())
        {
            return Err(AdmissionError::HistoryLimit);
        }
        if state.global.used >= limits.starts_per_window.get()
            || source
                .is_some_and(|source| source.rate.used >= limits.starts_per_source_window.get())
        {
            return Err(AdmissionError::RateLimit);
        }

        state.active += 1;
        state.global.used += 1;
        let source = state.sources.entry(source_key).or_insert(Source {
            active: 0,
            rate: Rate {
                since: now,
                used: 0,
            },
        });
        source.active += 1;
        source.rate.used += 1;
        state.tuples.insert(key, None);
        Ok(AssociationPermit {
            owner: self.0.clone(),
            key,
            source: source_key,
        })
    }

    /// Count datagrams a producer dropped instead of queueing them for an association.
    pub fn record_dropped_datagrams(&self, count: u64) {
        self.0.counters.dropped.fetch_add(count, Ordering::Relaxed);
    }

    /// What was refused and rejected so far.
    #[must_use]
    pub fn stats(&self) -> AdmissionStats {
        let counters = &self.0.counters;
        let refused = |index: usize| counters.refused[index].load(Ordering::Relaxed);
        let rejected = |index: usize| counters.rejected[index].load(Ordering::Relaxed);
        AdmissionStats {
            refused_capability: refused(0),
            refused_active: refused(1),
            refused_source: refused(2),
            refused_history: refused(3),
            refused_rate: refused(4),
            refused_tuple: refused(5),
            rejected_not_quic: rejected(0),
            rejected_unsupported_version: rejected(1),
            rejected_malformed: rejected(2),
            rejected_budget: rejected(3),
            rejected_deadline: rejected(4),
            dropped_datagrams: counters.dropped.load(Ordering::Relaxed),
        }
    }
}

/// An admitted association. Dropping it releases its slot and quarantines its addresses;
/// its start stays counted.
#[derive(Debug)]
pub struct AssociationPermit {
    owner: Arc<Inner>,
    key: AssociationKey,
    source: SourceKey,
}

impl Drop for AssociationPermit {
    fn drop(&mut self) {
        let mut state = self.owner.state.lock();
        state.active -= 1;
        if let Some(source) = state.sources.get_mut(&self.source) {
            source.active -= 1;
        }
        // Representable by construction; at the clock's limit the addresses stay held.
        state.tuples.insert(
            self.key,
            Instant::now().checked_add(self.owner.limits.quarantine),
        );
    }
}

/// Admits each association before its inner service, usually a
/// [`PeekQuicClientHelloService`](super::PeekQuicClientHelloService), inspects it, and
/// holds the permit until that service is done.
#[derive(Debug, Clone)]
pub struct QuicAdmissionLayer {
    admission: QuicAssociationAdmission,
}

impl QuicAdmissionLayer {
    #[must_use]
    pub fn new(admission: QuicAssociationAdmission) -> Self {
        Self { admission }
    }
}

impl<S> Layer<S> for QuicAdmissionLayer {
    type Service = QuicAdmissionService<S>;

    fn layer(&self, inner: S) -> Self::Service {
        QuicAdmissionService {
            admission: self.admission.clone(),
            inner,
        }
    }

    fn into_layer(self, inner: S) -> Self::Service {
        QuicAdmissionService {
            admission: self.admission,
            inner,
        }
    }
}

/// The service a [`QuicAdmissionLayer`] produces.
#[derive(Debug, Clone)]
pub struct QuicAdmissionService<S> {
    admission: QuicAssociationAdmission,
    inner: S,
}

impl<I, S> Service<I> for QuicAdmissionService<S>
where
    I: DatagramPeekInput<Socket: Socket>,
    S: Service<I, Error: Into<BoxError>>,
{
    type Output = S::Output;
    type Error = BoxError;

    async fn serve(&self, mut input: I) -> Result<S::Output, BoxError> {
        let socket = input.peek_socket_mut();
        // Inspection cannot tell a cut datagram from a whole one without this.
        if !socket.capabilities().receive_truncation {
            let error = AdmissionError::Capability(DatagramFeature::ReceiveTruncation);
            self.admission.0.counters.refused(error);
            return Err(error.into());
        }
        let key = AssociationKey {
            ingress: socket.local_addr()?,
            peer: socket.peer_addr()?,
        };
        let permit = self.admission.try_acquire(key)?;
        let result = self.inner.serve(input).await.map_err(Into::into);
        if let Err(error) = &result
            && let Some(QuicPeekRejectedError(rejection)) = error.downcast_ref()
        {
            self.admission.0.counters.rejected(*rejection);
        }
        drop(permit);
        result
    }
}

#[cfg(test)]
mod tests;
