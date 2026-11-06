//! Load-adaptive admission of incoming connection attempts.
//!
//! The controller is a pure state machine fed the current time; the endpoint driver shares it
//! with the leases its admitted attempts carry, so each attempt is released exactly once,
//! wherever it ends.

use std::{
    net::{IpAddr, Ipv6Addr},
    num::NonZeroUsize,
    sync::Arc,
};

use ahash::HashMap;
use parking_lot::Mutex;

use crate::proto::{Duration, Instant};

/// How a server admits incoming connection attempts while it is under load.
///
/// An attempt is in progress from the moment it is admitted until its handshake completes,
/// fails, times out or is abandoned, whether it waits for the application or is already being
/// accepted. While few attempts are in progress every attempt is accepted at once. Past the
/// retry threshold, an attempt from an address that has not proven it receives what is sent
/// there (no valid Retry or NEW_TOKEN token) is answered with a Retry (RFC 9000 §8.1.2): it is
/// stateless and cheap, so a flood from spoofed addresses costs no handshake work, while a real
/// client returns the token one round trip later and is admitted. At the limit every attempt is
/// refused with CONNECTION_REFUSED, so clients fall back at once.
///
/// The retry threshold follows what the endpoint actually completes: the handshakes it
/// finished in about the last second, smoothed (quick to rise, slow to fall), kept between
/// [`Self::set_retry_threshold_min`] and [`Self::set_retry_threshold_max`]. Once crossed,
/// Retry stays on until the attempts in progress fall below three quarters of the threshold,
/// so the endpoint does not flap at the boundary.
#[derive(Debug, Clone)]
pub struct AdmissionConfig {
    pub(crate) retry_threshold_min: usize,
    pub(crate) retry_threshold_max: usize,
    pub(crate) max_in_progress: usize,
    pub(crate) max_in_progress_per_source: Option<NonZeroUsize>,
}

impl AdmissionConfig {
    rama_utils::macros::generate_set_and_with! {
        /// The retry threshold when the endpoint completes few handshakes.
        ///
        /// Defaults to 256: a burst that large is accepted without an extra round trip even on
        /// an idle endpoint. A minimum and maximum of zero answer every unvalidated attempt with a
        /// Retry; a minimum above the maximum fixes the threshold at the minimum.
        pub fn retry_threshold_min(mut self, value: usize) -> Self {
            self.retry_threshold_min = value;
            self
        }
    }

    rama_utils::macros::generate_set_and_with! {
        /// The highest the retry threshold rises, however many handshakes the endpoint completes.
        ///
        /// Defaults to 4096. It bounds the handshake work a spoofed flood can cause before Retry
        /// starts, right after a busy period raised the threshold.
        pub fn retry_threshold_max(mut self, value: usize) -> Self {
            self.retry_threshold_max = value;
            self
        }
    }

    rama_utils::macros::generate_set_and_with! {
        /// The most attempts in progress at once; beyond it every attempt is refused.
        ///
        /// Defaults to 16384. Only attempts from validated addresses can reach it, since Retry
        /// holds the others at the threshold; it bounds what clients that complete address
        /// validation can make the endpoint hold. It also caps the retry threshold.
        pub fn max_in_progress(mut self, value: usize) -> Self {
            self.max_in_progress = value;
            self
        }
    }

    rama_utils::macros::generate_set_and_with! {
        /// The most attempts in progress from one validated source: an IPv4 address, or an IPv6
        /// /64 prefix, the block a subscriber is usually assigned. A validated attempt beyond it
        /// is refused.
        ///
        /// Only attempts from validated addresses are counted: an unvalidated source address can
        /// be spoofed to exhaust another host's share, so those attempts are bounded by the
        /// retry threshold instead. Defaults to 4096, a quarter of the attempts in progress: far
        /// above what carrier-grade or enterprise NAT puts behind one address, yet one validated
        /// host stalling its handshakes cannot take every slot.
        pub fn max_in_progress_per_source(mut self, value: Option<NonZeroUsize>) -> Self {
            self.max_in_progress_per_source = value;
            self
        }
    }

    /// The retry threshold for a smoothed completion rate.
    fn threshold(&self, completions_per_window: u64) -> usize {
        let ceiling = self.retry_threshold_max.max(self.retry_threshold_min);
        usize::try_from(completions_per_window)
            .unwrap_or(usize::MAX)
            .clamp(self.retry_threshold_min, ceiling)
            .min(self.max_in_progress)
    }
}

impl Default for AdmissionConfig {
    fn default() -> Self {
        Self {
            retry_threshold_min: 256,
            retry_threshold_max: 4096,
            max_in_progress: 16_384,
            max_in_progress_per_source: NonZeroUsize::new(4_096),
        }
    }
}

/// What admission decided for an arriving attempt.
#[derive(Debug)]
pub(crate) enum Decision<T> {
    /// Accept it; `T` is held until the attempt completes or is abandoned.
    Admit(T),
    /// Answer with a Retry: its address is unvalidated while the endpoint is under load.
    Retry,
    /// Refuse it with CONNECTION_REFUSED.
    Refuse(Refusal),
}

/// Why admission refused an attempt.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum Refusal {
    /// The endpoint holds as many attempts in progress as it allows.
    Limit,
    /// The attempt's source holds as many attempts in progress as it may.
    Source,
}

/// One admitted attempt, until it is completed or abandoned. Neither `Copy` nor `Clone`, so
/// an attempt is released at most once.
#[derive(Debug)]
pub(crate) struct Ticket {
    source: Option<SourceKey>,
}

/// The unit attempts are counted per: an IPv4 address or an IPv6 /64 prefix.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub(crate) enum SourceKey {
    V4([u8; 4]),
    V6([u8; 8]),
}

impl SourceKey {
    pub(crate) fn of(ip: IpAddr) -> Self {
        match ip {
            IpAddr::V4(ip) => Self::V4(ip.octets()),
            IpAddr::V6(ip) => match ip.to_ipv4_mapped() {
                Some(ip) => Self::V4(ip.octets()),
                None => Self::V6(prefix64(ip)),
            },
        }
    }
}

fn prefix64(ip: Ipv6Addr) -> [u8; 8] {
    let [a, b, c, d, e, f, g, h, ..] = ip.octets();
    [a, b, c, d, e, f, g, h]
}

/// The span completions are counted over: the threshold is about what one window completes.
const WINDOW: Duration = Duration::from_secs(1);
/// Fixed-point scale of the smoothed rate, so slow decay keeps fractions.
const SCALE_SHIFT: u32 = 4;
/// The rate moves half way to a higher sample at once,
const RISE_SHIFT: u32 = 1;
/// and an eighth of the way to a lower one.
const DECAY_SHIFT: u32 = 3;

/// Handshakes completed per window, smoothed.
#[derive(Debug, Default)]
struct CompletionRate {
    /// Smoothed completions per window, scaled by `1 << SCALE_SHIFT`.
    smoothed: u64,
    window_start: Option<Instant>,
    in_window: u64,
}

impl CompletionRate {
    /// Fold the windows that ended by `now` into the smoothed rate.
    fn advance(&mut self, now: Instant) {
        let Some(start) = self.window_start else {
            self.window_start = Some(now);
            return;
        };
        let elapsed = now.saturating_duration_since(start);
        let windows = elapsed.as_nanos() / WINDOW.as_nanos();
        if windows == 0 {
            return;
        }
        self.fold(self.in_window.saturating_mul(1 << SCALE_SHIFT));
        self.in_window = 0;
        // Idle windows decay the rate until it is too small to decay further, which bounds
        // this loop by the bits of the rate rather than by the length of the gap.
        for _ in 1..windows {
            if self.smoothed < 1 << DECAY_SHIFT {
                break;
            }
            self.fold(0);
        }
        let into_window = elapsed.as_nanos() % WINDOW.as_nanos();
        let into_window = Duration::from_nanos(u64::try_from(into_window).unwrap_or(0));
        self.window_start = Some(now.checked_sub(into_window).unwrap_or(now));
    }

    fn fold(&mut self, sample: u64) {
        self.smoothed = if sample >= self.smoothed {
            self.smoothed + ((sample - self.smoothed) >> RISE_SHIFT)
        } else {
            self.smoothed - ((self.smoothed - sample) >> DECAY_SHIFT)
        };
    }

    fn record(&mut self, now: Instant) {
        self.advance(now);
        self.in_window = self.in_window.saturating_add(1);
    }

    fn per_window(&self) -> u64 {
        self.smoothed >> SCALE_SHIFT
    }
}

/// Counts attempts in progress and decides, per arriving attempt, whether to accept, retry or
/// refuse it. Every admitted [`Ticket`] must come back through [`Self::complete`] or
/// [`Self::abandon`].
#[derive(Debug, Default)]
pub(crate) struct AdmissionController {
    in_progress: usize,
    /// Attempts in progress per validated source, only while a per-source limit is configured
    /// at their admission; an entry goes once its count is zero.
    per_source: HashMap<SourceKey, NonZeroUsize>,
    /// Unvalidated attempts are answered with Retry while this is set.
    retrying: bool,
    rate: CompletionRate,
}

impl AdmissionController {
    /// Decide for an attempt from `source` that arrived at `now`. Without a configuration every
    /// attempt is admitted, and still counted.
    pub(crate) fn arrive(
        &mut self,
        now: Instant,
        config: Option<&AdmissionConfig>,
        source: IpAddr,
        validated: bool,
    ) -> Decision<Ticket> {
        self.rate.advance(now);
        let Some(config) = config else {
            return Decision::Admit(self.admit(None));
        };
        if self.in_progress >= config.max_in_progress {
            return Decision::Refuse(Refusal::Limit);
        }
        let threshold = config.threshold(self.rate.per_window());
        self.update_mode(threshold);
        let source = match config.max_in_progress_per_source {
            Some(limit) if validated => {
                let key = SourceKey::of(source);
                if self
                    .per_source
                    .get(&key)
                    .is_some_and(|held| held.get() >= limit.get())
                {
                    return Decision::Refuse(Refusal::Source);
                }
                Some(key)
            }
            _ => None,
        };
        if !validated && self.retrying {
            return Decision::Retry;
        }
        let ticket = self.admit(source);
        self.update_mode(threshold);
        Decision::Admit(ticket)
    }

    /// The attempt's handshake completed; it counts towards the completion rate.
    pub(crate) fn complete(&mut self, ticket: Ticket, now: Instant) {
        self.rate.record(now);
        self.release(ticket);
    }

    /// The attempt ended without completing its handshake.
    pub(crate) fn abandon(&mut self, ticket: Ticket) {
        self.release(ticket);
    }

    /// Attempts admitted and not yet completed or abandoned.
    pub(crate) fn in_progress(&self) -> usize {
        self.in_progress
    }

    /// The retry threshold `config` gives at `now`.
    pub(crate) fn threshold(&mut self, now: Instant, config: &AdmissionConfig) -> usize {
        self.rate.advance(now);
        config.threshold(self.rate.per_window())
    }

    /// Whether unvalidated attempts are currently answered with a Retry.
    #[cfg(test)]
    pub(crate) fn is_retrying(&self) -> bool {
        self.retrying
    }

    /// Tests: attempts in progress counted for `source`.
    #[cfg(test)]
    fn held_by(&self, source: IpAddr) -> usize {
        self.per_source
            .get(&SourceKey::of(source))
            .map_or(0, |held| held.get())
    }

    fn admit(&mut self, source: Option<SourceKey>) -> Ticket {
        self.in_progress = self.in_progress.saturating_add(1);
        if let Some(key) = source {
            self.per_source
                .entry(key)
                .and_modify(|held| *held = held.saturating_add(1))
                .or_insert(NonZeroUsize::MIN);
        }
        Ticket { source }
    }

    #[expect(
        clippy::needless_pass_by_value,
        reason = "consuming the ticket prevents releasing an attempt twice"
    )]
    fn release(&mut self, ticket: Ticket) {
        debug_assert!(self.in_progress > 0, "released more attempts than admitted");
        self.in_progress = self.in_progress.saturating_sub(1);
        let Some(key) = ticket.source else {
            return;
        };
        let held = self.per_source.get(&key).map(|held| held.get());
        debug_assert!(held.is_some(), "released an uncounted source");
        match held.and_then(|held| NonZeroUsize::new(held.saturating_sub(1))) {
            Some(left) => {
                self.per_source.insert(key, left);
            }
            None => {
                self.per_source.remove(&key);
            }
        }
    }

    /// Retry starts once `threshold` attempts are in progress and stops below three quarters
    /// of it.
    fn update_mode(&mut self, threshold: usize) {
        if self.retrying {
            if self.in_progress < low_watermark(threshold) {
                self.retrying = false;
            }
        } else if self.in_progress >= threshold {
            self.retrying = true;
        }
    }
}

fn low_watermark(threshold: usize) -> usize {
    threshold - threshold / 4
}

/// The endpoint's admission controller, shared with the leases of the attempts it admitted.
#[derive(Debug, Clone, Default)]
pub(crate) struct Admission(Arc<Mutex<AdmissionController>>);

impl Admission {
    /// Decide for an arriving attempt; an admitted one carries the lease that releases it.
    pub(crate) fn arrive(
        &self,
        now: Instant,
        config: Option<&AdmissionConfig>,
        source: IpAddr,
        validated: bool,
    ) -> Decision<AdmissionLease> {
        let decision = self.0.lock().arrive(now, config, source, validated);
        match decision {
            Decision::Admit(ticket) => Decision::Admit(AdmissionLease {
                admission: self.0.clone(),
                ticket: Some(ticket),
            }),
            Decision::Retry => Decision::Retry,
            Decision::Refuse(refusal) => Decision::Refuse(refusal),
        }
    }

    /// Attempts in progress, and the retry threshold `config` gives at `now`.
    pub(crate) fn load(&self, now: Instant, config: Option<&AdmissionConfig>) -> (usize, usize) {
        let mut controller = self.0.lock();
        let threshold = config.map_or(0, |config| controller.threshold(now, config));
        (controller.in_progress(), threshold)
    }
}

/// An admitted attempt's place among those in progress, released exactly once: completed when
/// its handshake does, abandoned when dropped otherwise.
#[derive(Debug)]
pub(crate) struct AdmissionLease {
    admission: Arc<Mutex<AdmissionController>>,
    ticket: Option<Ticket>,
}

impl AdmissionLease {
    /// The handshake completed.
    pub(crate) fn complete(mut self, now: Instant) {
        if let Some(ticket) = self.ticket.take() {
            self.admission.lock().complete(ticket, now);
        }
    }
}

impl Drop for AdmissionLease {
    fn drop(&mut self) {
        if let Some(ticket) = self.ticket.take() {
            self.admission.lock().abandon(ticket);
        }
    }
}

#[cfg(test)]
mod tests;

/// Exercise admission and lease accounting using an arbitrary sequence of events.
#[cfg(fuzzing)]
pub fn fuzz_admission(data: &[u8]) {
    let Some((&min, rest)) = data.split_first() else {
        return;
    };
    let Some((&max, rest)) = rest.split_first() else {
        return;
    };
    let Some((&limit, rest)) = rest.split_first() else {
        return;
    };
    let Some((&per_source, rest)) = rest.split_first() else {
        return;
    };
    let config = AdmissionConfig {
        retry_threshold_min: usize::from(min),
        retry_threshold_max: usize::from(max),
        max_in_progress: usize::from(limit),
        max_in_progress_per_source: NonZeroUsize::new(usize::from(per_source)),
    };
    let admission = Admission::default();
    let mut held = Vec::new();
    let mut now = Instant::now();
    for op in rest.as_chunks::<2>().0 {
        match op[0] % 5 {
            0 | 1 => {
                let validated = op[0] % 5 == 1;
                let source = IpAddr::from([192, 0, 2, op[1] % 8]);
                match admission.arrive(now, Some(&config), source, validated) {
                    Decision::Admit(lease) => held.push(lease),
                    Decision::Retry => assert!(!validated),
                    Decision::Refuse(_) => {}
                }
            }
            2 | 3 if !held.is_empty() => {
                let index = usize::from(op[1]) % held.len();
                let lease = held.swap_remove(index);
                if op[0] % 5 == 2 {
                    lease.complete(now);
                }
            }
            4 => now += Duration::from_millis(u64::from(op[1]) * 100),
            _ => {}
        }
        let (in_progress, threshold) = admission.load(now, Some(&config));
        assert_eq!(in_progress, held.len());
        assert!(in_progress <= config.max_in_progress);
        assert!(threshold <= config.max_in_progress);
        assert!(threshold >= config.retry_threshold_min.min(config.max_in_progress));
        let controller = admission.0.lock();
        let tracked: usize = controller.per_source.values().map(|held| held.get()).sum();
        assert!(tracked <= held.len());
        if let Some(limit) = config.max_in_progress_per_source {
            assert!(controller.per_source.values().all(|held| held <= &limit));
        }
    }
    drop(held);
    assert_eq!(admission.load(now, Some(&config)).0, 0);
    assert!(admission.0.lock().per_source.is_empty());
}
