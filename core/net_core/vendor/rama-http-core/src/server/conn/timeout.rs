//! Request-head and idle deadlines shared by the HTTP/1, HTTP/2 and HTTP/3 servers.
//!
//! A request head gets a grace window from its first byte, after which it is cut
//! once its average arrival rate drops below a floor, and always at a ceiling. A
//! connection without open requests is closed once idle for a budget it earns by
//! completing a request head. A connection that never did gets one shorter window,
//! counted from when it first went idle, which open requests and heads only pause.

use std::{
    fmt,
    pin::Pin,
    task::{Context, Poll, ready},
    time::Duration,
};
use tokio::{
    task::coop::unconstrained,
    time::{Instant, Sleep, sleep_until},
};

/// An RTT sample extends a window by this many round trips, at most doubling it.
const RTT_FACTOR: u32 = 4;

/// The least a graceful close waits for a peer that does not finish it.
const DRAIN_FLOOR: Duration = Duration::from_secs(1);

/// The most a graceful close waits: an RTT the peer inflated buys no more than a fresh connection.
const DRAIN_CEILING: Duration = Duration::from_secs(10);

/// Deadline for receiving a complete request head, measured from its first byte.
///
/// A head is never cut within [`grace`](Self::grace). After that it is cut as soon
/// as the average rate at which its bytes arrived, counted from its first byte,
/// falls below [`min_rate`](Self::min_rate), so a slow but progressing client keeps
/// going while a trickle is cut. A head still incomplete at
/// [`ceiling`](Self::ceiling) is cut whatever its rate.
///
/// HTTP/1 closes the connection; HTTP/2 sends `GOAWAY` with `ENHANCE_YOUR_CALM`
/// and closes it, as an open header block stalls the whole connection; HTTP/3
/// resets only that request stream with `H3_REQUEST_REJECTED`, which tells the
/// client it may retry, unless the connection never received a complete head,
/// in which case it also closes the connection gracefully.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct HeaderReadTimeout {
    /// Never cut a head within this window after its first byte.
    ///
    /// Extended by four round trips, at most doubled, when the connection
    /// measured its round-trip time.
    pub grace: Duration,
    /// After the grace window, cut a head whose average arrival rate is below
    /// this many bytes per second. Zero disables the rate rule.
    pub min_rate: u32,
    /// Cut a head still incomplete after this long, whatever its rate.
    pub ceiling: Duration,
}

impl HeaderReadTimeout {
    /// 10 s of grace, a floor of 256 bytes per second, and a 60 s ceiling.
    ///
    /// Ten seconds absorbs a few lost-segment retransmissions. 256 B/s lets a
    /// 2.5 KiB head through within the grace window and is far above what a
    /// trickling attacker sends, yet far below any working link. Established
    /// servers cap header reads at 60 s.
    pub const DEFAULT: Self = Self {
        grace: Duration::from_secs(10),
        min_rate: 256,
        ceiling: Duration::from_mins(1),
    };
}

impl Default for HeaderReadTimeout {
    fn default() -> Self {
        Self::DEFAULT
    }
}

/// Budget for a connection without open requests before it is closed.
///
/// A connection is idle while it has no open request, no request head in
/// progress and no tunnel; a WebSocket, a CONNECT tunnel or a streamed response
/// keeps its request open, even while no bytes are transferred. HTTP/2 PINGs and
/// other connection-level control traffic do not restart this HTTP idle budget.
/// Transport timeouts (including QUIC's idle timeout) apply independently.
///
/// A connection that never received a complete request head gets one
/// [`first_request`](Self::first_request) window, counted from when
/// it first went idle: requests and heads in progress pause it but never restart
/// it. Once a complete head arrived, the connection earns the full
/// [`idle`](Self::idle) budget whenever it becomes idle again. This allows a
/// client to reuse the connection between requests, including through an HTTP
/// interception proxy.
///
/// HTTP/1 closes the connection; HTTP/2 and HTTP/3 send a graceful `GOAWAY`
/// and close once requests that raced it are done.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct IdleTimeout {
    /// Window for a connection that has not received a complete request head yet.
    ///
    /// Extended by four round trips, at most doubled, when the connection
    /// measured its round-trip time.
    pub first_request: Duration,
    /// Budget while idle after at least one complete request head was received.
    ///
    /// Starts when no request, response, tunnel or request head remains open,
    /// rather than when the last byte was transferred. Defaults to 90 seconds.
    /// Increase this for clients with longer gaps between requests using, for
    /// example, `IdleTimeout { idle: Duration::from_secs(300), ..IdleTimeout::DEFAULT }`.
    pub idle: Duration,
}

impl IdleTimeout {
    /// 10 s before the first request and 90 s idle after receiving a request head.
    ///
    /// The shorter initial window limits unused connections. The longer window
    /// allows reuse across minute-spaced requests, reducing reconnects and TLS
    /// handshakes for clients and HTTP interception proxies.
    pub const DEFAULT: Self = Self {
        first_request: Duration::from_secs(10),
        idle: Duration::from_secs(90),
    };
}

impl Default for IdleTimeout {
    fn default() -> Self {
        Self::DEFAULT
    }
}

/// `base` extended by [`RTT_FACTOR`] round trips, never more than doubled.
fn with_rtt(base: Duration, rtt: Option<Duration>) -> Duration {
    rtt.map_or(base, |rtt| {
        base.saturating_add(rtt.saturating_mul(RTT_FACTOR).min(base))
    })
}

/// How long a graceful close waits for an idle peer: [`RTT_FACTOR`] round trips,
/// within [`DRAIN_FLOOR`] and [`DRAIN_CEILING`].
fn drain_budget(rtt: Option<Duration>) -> Duration {
    rtt.map_or(DRAIN_FLOOR, |rtt| {
        rtt.saturating_mul(RTT_FACTOR)
            .clamp(DRAIN_FLOOR, DRAIN_CEILING)
    })
}

/// Saturate an unrepresentable deadline to a far future instant, never to `now`.
pub(crate) fn deadline_after(start: Instant, mut duration: Duration) -> Instant {
    loop {
        if let Some(deadline) = start.checked_add(duration) {
            return deadline;
        }
        duration = duration.checked_div(2).unwrap_or_default();
    }
}

/// How long `bytes` last at `rate` bytes per second, plus 1 ns: the first
/// instant at which the average rate since the first byte is below `rate`.
fn rate_allowance(bytes: u64, rate: u32) -> Duration {
    let rate = u64::from(rate.max(1));
    let secs = bytes.checked_div(rate).unwrap_or_default();
    let rest = bytes.checked_rem(rate).unwrap_or_default();
    // rest < rate <= u32::MAX, so the product fits in u64.
    let nanos = rest
        .saturating_mul(1_000_000_000)
        .checked_div(rate)
        .unwrap_or_default();
    Duration::from_secs(secs)
        .saturating_add(Duration::from_nanos(nanos))
        .saturating_add(Duration::from_nanos(1))
}

/// The deadline rule of one request head, as offsets from its first byte.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) struct HeadBudget {
    grace: Duration,
    min_rate: u32,
    ceiling: Duration,
}

impl HeadBudget {
    pub(crate) fn new(config: &HeaderReadTimeout, rtt: Option<Duration>) -> Self {
        Self {
            grace: with_rtt(config.grace, rtt).min(config.ceiling),
            min_rate: config.min_rate,
            ceiling: config.ceiling,
        }
    }

    /// How long after its first byte a head that received `bytes` may stay incomplete.
    pub(crate) fn allowance(&self, bytes: u64) -> Duration {
        let earned = if self.min_rate == 0 {
            self.ceiling
        } else {
            rate_allowance(bytes, self.min_rate)
        };
        self.grace.max(earned).min(self.ceiling)
    }
}

/// What a connection is doing, as observed by its protocol driver.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum Activity {
    /// A request is open: no deadline applies.
    Busy,
    /// No request is open nor being received.
    Idle,
    /// A request head is being received; `bytes` of it arrived so far.
    ///
    /// `block` tells consecutive heads apart: a new value starts a new head even
    /// when no other activity was observed in between.
    Head { bytes: u64, block: u64 },
}

/// Which deadline passed.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum Expired {
    /// The connection stayed idle for its budget.
    Idle,
    /// A request head did not complete in time.
    Head,
    /// A graceful close was not completed by the peer in time.
    Drain,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Phase {
    Busy,
    Idle { since: Instant },
    Head { started: Instant, block: u64 },
}

/// The deadline rules of one connection, free of any timer: callers report
/// activity and get the instant at which the current phase expires.
#[derive(Debug, Clone)]
pub(crate) struct ConnDeadlines {
    idle: Option<IdleTimeout>,
    head: Option<HeaderReadTimeout>,
    rtt: Option<Duration>,
    earned: bool,
    /// Start of the first idle phase, which anchors the window of an unearned connection.
    first_idle: Option<Instant>,
    phase: Phase,
    /// Once a graceful close started: how long each idle phase may last.
    drain: Option<Duration>,
}

impl ConnDeadlines {
    pub(crate) fn new(idle: Option<IdleTimeout>, head: Option<HeaderReadTimeout>) -> Self {
        Self {
            idle,
            head,
            rtt: None,
            earned: false,
            first_idle: None,
            phase: Phase::Busy,
            drain: None,
        }
    }

    /// Whether any deadline is configured.
    pub(crate) fn is_enabled(&self) -> bool {
        self.idle.is_some() || self.head.is_some()
    }

    /// Replace the budgets, keeping what was observed so far.
    pub(crate) fn reconfigure(
        &mut self,
        idle: Option<IdleTimeout>,
        head: Option<HeaderReadTimeout>,
    ) {
        self.idle = idle;
        self.head = head;
    }

    /// Round-trip time measured on this connection; it applies from the next observation.
    pub(crate) fn set_rtt(&mut self, rtt: Duration) {
        self.rtt = Some(rtt);
    }

    /// A complete request head was received: the connection earned its full idle budget.
    pub(crate) fn request_received(&mut self) {
        self.earned = true;
        self.phase = Phase::Busy;
    }

    /// End the current phase without a request: the next observation starts a new one.
    pub(crate) fn mark_busy(&mut self) {
        self.phase = Phase::Busy;
    }

    /// A graceful close started: from now on an idle phase lasts at most the drain budget.
    ///
    /// The budget counts from the start of each idle phase, so a request that raced
    /// the close gets the whole budget to flush its response once it completes.
    pub(crate) fn start_drain(&mut self) {
        self.drain = Some(self.drain_budget());
        self.phase = Phase::Busy;
    }

    /// How long a graceful close waits for an idle peer.
    pub(crate) fn drain_budget(&self) -> Duration {
        drain_budget(self.rtt)
    }

    /// When the head in progress expires with `bytes` received, if a head is in progress.
    fn head_deadline(&self, bytes: u64) -> Option<Instant> {
        let Phase::Head { started, .. } = self.phase else {
            return None;
        };
        let config = self.head?;
        Some(deadline_after(
            started,
            HeadBudget::new(&config, self.rtt).allowance(bytes),
        ))
    }

    /// Record `activity` and return when the current phase expires, if it does.
    ///
    /// `now` is only read when a new phase starts.
    pub(crate) fn observe(
        &mut self,
        activity: Activity,
        now: impl FnOnce() -> Instant,
    ) -> Option<(Instant, Expired)> {
        match activity {
            Activity::Busy => {
                self.phase = Phase::Busy;
                None
            }
            Activity::Idle => {
                let since = match self.phase {
                    Phase::Idle { since } => since,
                    Phase::Busy | Phase::Head { .. } => {
                        let since = now();
                        self.phase = Phase::Idle { since };
                        since
                    }
                };
                if let Some(drain) = self.drain {
                    return Some((deadline_after(since, drain), Expired::Drain));
                }
                let idle = self.idle?;
                let deadline = if self.earned {
                    deadline_after(since, idle.idle)
                } else {
                    let first = *self.first_idle.get_or_insert(since);
                    deadline_after(first, with_rtt(idle.first_request, self.rtt))
                };
                Some((deadline, Expired::Idle))
            }
            Activity::Head { bytes, block } => {
                match self.phase {
                    Phase::Head { block: current, .. } if current == block => {}
                    Phase::Busy | Phase::Idle { .. } | Phase::Head { .. } => {
                        self.phase = Phase::Head {
                            started: now(),
                            block,
                        };
                    }
                }
                self.head_deadline(bytes)
                    .map(|deadline| (deadline, Expired::Head))
            }
        }
    }
}

/// Storage for a lazily created [`Sleep`].
pub(crate) trait SleepSlot {
    /// Arm the timer at `deadline`, creating it on first use.
    fn arm(&mut self, deadline: Instant);
    /// Poll the armed timer.
    fn poll_elapsed(&mut self, cx: &mut Context<'_>) -> Poll<()>;
}

// Timers are polled unconstrained: a task whose frame input exhausted its
// cooperative budget must still observe an elapsed deadline.

impl SleepSlot for Option<Pin<Box<Sleep>>> {
    fn arm(&mut self, deadline: Instant) {
        match self {
            Some(sleep) => sleep.as_mut().reset(deadline),
            None => *self = Some(Box::pin(sleep_until(deadline))),
        }
    }

    fn poll_elapsed(&mut self, cx: &mut Context<'_>) -> Poll<()> {
        match self {
            Some(sleep) => Pin::new(&mut unconstrained(sleep.as_mut())).poll(cx),
            None => Poll::Pending,
        }
    }
}

impl SleepSlot for Pin<&mut Option<Sleep>> {
    fn arm(&mut self, deadline: Instant) {
        match self.as_mut().as_pin_mut() {
            Some(sleep) => sleep.reset(deadline),
            None => self.set(Some(sleep_until(deadline))),
        }
    }

    fn poll_elapsed(&mut self, cx: &mut Context<'_>) -> Poll<()> {
        match self.as_mut().as_pin_mut() {
            Some(sleep) => Pin::new(&mut unconstrained(sleep)).poll(cx),
            None => Poll::Pending,
        }
    }
}

/// A timer only moved to earlier deadlines right away: a later deadline is
/// adopted once the earlier one fires, so steady progress resets no timer.
#[derive(Debug, Default, Clone, Copy)]
pub(crate) struct LazyDeadline {
    armed: Option<Instant>,
}

impl LazyDeadline {
    /// Ready once `deadline`, recomputed by the caller on every call, passed.
    pub(crate) fn poll(
        &mut self,
        slot: &mut impl SleepSlot,
        cx: &mut Context<'_>,
        deadline: Instant,
    ) -> Poll<()> {
        loop {
            if self.armed.is_none_or(|armed| armed > deadline) {
                slot.arm(deadline);
                self.armed = Some(deadline);
            }
            ready!(slot.poll_elapsed(cx));
            let fired = self.armed.take().unwrap_or(deadline);
            if deadline <= fired {
                return Poll::Ready(());
            }
        }
    }
}

/// [`ConnDeadlines`] driven by one reusable timer per connection.
pub(crate) struct ConnTimer {
    deadlines: ConnDeadlines,
    lazy: LazyDeadline,
    sleep: Option<Pin<Box<Sleep>>>,
}

impl fmt::Debug for ConnTimer {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("ConnTimer")
            .field("deadlines", &self.deadlines)
            .field("lazy", &self.lazy)
            .finish_non_exhaustive()
    }
}

impl ConnTimer {
    pub(crate) fn new(idle: Option<IdleTimeout>, head: Option<HeaderReadTimeout>) -> Self {
        Self {
            deadlines: ConnDeadlines::new(idle, head),
            lazy: LazyDeadline::default(),
            sleep: None,
        }
    }

    pub(crate) fn is_enabled(&self) -> bool {
        self.deadlines.is_enabled()
    }

    /// Hand the timer to the protocol detected on its connection, with that protocol's budgets.
    pub(crate) fn reconfigure(
        &mut self,
        idle: Option<IdleTimeout>,
        head: Option<HeaderReadTimeout>,
    ) {
        self.deadlines.reconfigure(idle, head);
    }

    pub(crate) fn set_rtt(&mut self, rtt: Duration) {
        self.deadlines.set_rtt(rtt);
    }

    pub(crate) fn request_received(&mut self) {
        self.deadlines.request_received();
    }

    pub(crate) fn mark_busy(&mut self) {
        self.deadlines.mark_busy();
    }

    pub(crate) fn start_drain(&mut self) {
        self.deadlines.start_drain();
    }

    #[cfg(feature = "quic")]
    pub(crate) fn drain_budget(&self) -> Duration {
        self.deadlines.drain_budget()
    }

    /// Whether the head in progress ran out of time with `bytes` received.
    ///
    /// Checked before consuming newly available bytes: a ready read must not
    /// revive a head whose budget elapsed while unpolled. Only a head in
    /// progress reads the clock.
    pub(crate) fn head_elapsed(&self, bytes: u64) -> bool {
        self.deadlines
            .head_deadline(bytes)
            .is_some_and(|deadline| Instant::now() >= deadline)
    }

    /// Record `activity` and poll the deadline of the current phase.
    pub(crate) fn poll(&mut self, cx: &mut Context<'_>, activity: Activity) -> Poll<Expired> {
        let Some((deadline, expired)) = self.deadlines.observe(activity, Instant::now) else {
            return Poll::Pending;
        };
        ready!(self.lazy.poll(&mut self.sleep, cx, deadline));
        Poll::Ready(expired)
    }
}

/// A reference for [`ConnDeadlines`] that recomputes every expected deadline
/// from the whole observation history instead of incremental state.
#[cfg(any(test, feature = "fuzz-utils"))]
pub(crate) mod model {
    use super::{
        Activity, ConnDeadlines, Expired, HeadBudget, HeaderReadTimeout, IdleTimeout,
        deadline_after, drain_budget, with_rtt,
    };
    use std::time::Duration;
    use tokio::time::Instant;

    /// One step in the life of a connection.
    #[derive(Debug, Clone, Copy, PartialEq, Eq)]
    pub(crate) enum Event {
        Observe(Activity),
        Received,
        MarkBusy,
        Drain,
        Rtt(Duration),
    }

    impl Event {
        /// Decode a step chosen by a fuzzer or a property test.
        pub(crate) fn decode(kind: u8, value: u16) -> Self {
            match kind % 8 {
                0 => Self::Observe(Activity::Busy),
                1 | 7 => Self::Observe(Activity::Idle),
                2 => Self::Observe(Activity::Head {
                    bytes: u64::from(value),
                    block: u64::from(kind / 8 % 3),
                }),
                3 => Self::Received,
                4 => Self::MarkBusy,
                5 => Self::Drain,
                _ => Self::Rtt(Duration::from_millis(u64::from(value))),
            }
        }
    }

    /// Whether `event` continues the phase that `activity` observes.
    fn continues(event: Event, activity: Activity) -> bool {
        match (event, activity) {
            (Event::Observe(Activity::Idle), Activity::Idle) => true,
            (
                Event::Observe(Activity::Head { block, .. }),
                Activity::Head { block: current, .. },
            ) => block == current,
            _ => false,
        }
    }

    fn rtt_before(history: &[(Instant, Event)]) -> Option<Duration> {
        history.iter().rev().find_map(|(_, event)| match event {
            Event::Rtt(rtt) => Some(*rtt),
            _ => None,
        })
    }

    /// The deadline the observation that ends `history` must report.
    fn expected(
        idle: Option<IdleTimeout>,
        head: Option<HeaderReadTimeout>,
        history: &[(Instant, Event)],
    ) -> Option<(Instant, Expired)> {
        let (_, Event::Observe(activity)) = *history.last()? else {
            return None;
        };
        if activity == Activity::Busy {
            return None;
        }
        let rtt = rtt_before(history);
        // The phase started at the earliest observation of the run that ends here;
        // RTT samples do not interrupt a run, anything else does.
        let start = history
            .iter()
            .rev()
            .filter(|(_, event)| !matches!(event, Event::Rtt(_)))
            .take_while(|(_, event)| continues(*event, activity))
            .last()
            .map(|(at, _)| *at)?;
        match activity {
            Activity::Head { bytes, .. } => {
                let budget = HeadBudget::new(&head?, rtt).allowance(bytes);
                Some((deadline_after(start, budget), Expired::Head))
            }
            Activity::Idle => {
                if let Some(drained) = history
                    .iter()
                    .rposition(|(_, event)| *event == Event::Drain)
                {
                    let budget = drain_budget(rtt_before(&history[..drained]));
                    return Some((deadline_after(start, budget), Expired::Drain));
                }
                let idle = idle?;
                if history.iter().any(|(_, event)| *event == Event::Received) {
                    return Some((deadline_after(start, idle.idle), Expired::Idle));
                }
                let first = history
                    .iter()
                    .find(|(_, event)| *event == Event::Observe(Activity::Idle))
                    .map(|(at, _)| *at)?;
                Some((
                    deadline_after(first, with_rtt(idle.first_request, rtt)),
                    Expired::Idle,
                ))
            }
            Activity::Busy => None,
        }
    }

    /// Drive [`ConnDeadlines`] through `steps` of (delay in ms, kind, value) and
    /// compare every observation with the reference.
    pub(crate) fn conforms(
        idle: Option<IdleTimeout>,
        head: Option<HeaderReadTimeout>,
        steps: &[(u16, u8, u16)],
    ) -> bool {
        let mut deadlines = ConnDeadlines::new(idle, head);
        let mut history = Vec::with_capacity(steps.len());
        let mut now = Instant::now();
        for &(delay, kind, value) in steps {
            now = deadline_after(now, Duration::from_millis(u64::from(delay)));
            let event = Event::decode(kind, value);
            history.push((now, event));
            let observed = match event {
                Event::Observe(activity) => deadlines.observe(activity, || now),
                Event::Received => {
                    deadlines.request_received();
                    continue;
                }
                Event::MarkBusy => {
                    deadlines.mark_busy();
                    continue;
                }
                Event::Drain => {
                    deadlines.start_drain();
                    continue;
                }
                Event::Rtt(rtt) => {
                    deadlines.set_rtt(rtt);
                    continue;
                }
            };
            if observed != expected(idle, head, &history) {
                return false;
            }
        }
        true
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use quickcheck::{Arbitrary, Gen, QuickCheck};
    use std::{future::poll_fn, ptr};
    use tokio::{task::coop::poll_proceed, time::advance};

    const SEC: Duration = Duration::from_secs(1);

    fn ms(value: u64) -> Duration {
        Duration::from_millis(value)
    }

    fn head(bytes: u64) -> Activity {
        Activity::Head { bytes, block: 0 }
    }

    #[test]
    fn unrepresentable_budgets_never_expire_immediately() {
        let now = Instant::now();
        assert!(deadline_after(now, Duration::MAX) > now);
        assert_eq!(deadline_after(now, Duration::ZERO), now);
        let mut timer = ConnDeadlines::new(
            Some(IdleTimeout {
                first_request: Duration::MAX,
                idle: Duration::MAX,
            }),
            Some(HeaderReadTimeout {
                grace: Duration::MAX,
                min_rate: 0,
                ceiling: Duration::MAX,
            }),
        );
        assert!(timer.observe(Activity::Idle, || now).unwrap().0 > now);
        assert!(timer.observe(head(1), || now).unwrap().0 > now);
        timer.set_rtt(Duration::MAX);
        timer.start_drain();
        assert!(timer.observe(Activity::Idle, || now).unwrap().0 > now);
    }

    #[test]
    fn defaults_are_documented_values() {
        assert_eq!(
            HeaderReadTimeout::default(),
            HeaderReadTimeout {
                grace: SEC * 10,
                min_rate: 256,
                ceiling: SEC * 60,
            }
        );
        assert_eq!(
            IdleTimeout::default(),
            IdleTimeout {
                first_request: SEC * 10,
                idle: SEC * 90,
            }
        );
    }

    #[test]
    fn rtt_extends_at_most_to_double() {
        for (rtt, expected) in [
            (None, SEC * 10),
            (Some(Duration::ZERO), SEC * 10),
            (Some(ms(100)), ms(10_400)),
            (Some(ms(600)), ms(12_400)),
            (Some(SEC * 3), SEC * 20),
            (Some(Duration::MAX), SEC * 20),
        ] {
            assert_eq!(with_rtt(SEC * 10, rtt), expected, "rtt {rtt:?}");
        }
    }

    #[test]
    fn drain_budget_is_four_round_trips_within_bounds() {
        for (rtt, expected) in [
            (None, SEC),
            (Some(Duration::ZERO), SEC),
            (Some(ms(100)), SEC),
            (Some(ms(300)), ms(1_200)),
            (Some(SEC * 2), SEC * 8),
            (Some(SEC * 5), SEC * 10),
            (Some(Duration::MAX), SEC * 10),
        ] {
            assert_eq!(drain_budget(rtt), expected, "rtt {rtt:?}");
        }
    }

    #[test]
    fn rate_allowance_is_first_instant_below_rate() {
        for (bytes, rate, expected) in [
            (0, 256, Duration::from_nanos(1)),
            (256, 256, SEC + Duration::from_nanos(1)),
            (128, 256, ms(500) + Duration::from_nanos(1)),
            (1, 3, Duration::from_nanos(333_333_334)),
            (u64::MAX, 1, Duration::new(u64::MAX, 1)),
            (
                u64::MAX,
                u32::MAX,
                Duration::from_secs(4_294_967_297) + Duration::from_nanos(1),
            ),
        ] {
            assert_eq!(
                rate_allowance(bytes, rate),
                expected,
                "{bytes} B at {rate} B/s"
            );
        }
    }

    #[test]
    fn head_budget_matrix() {
        let config = HeaderReadTimeout::DEFAULT;
        let budget = HeadBudget::new(&config, None);
        for (bytes, expected) in [
            (0, SEC * 10),
            (2_560, SEC * 10 + Duration::from_nanos(1)),
            (2_561, Duration::from_nanos(10_003_906_251)),
            (5_120, SEC * 20 + Duration::from_nanos(1)),
            (15_360, SEC * 60),
            (1 << 40, SEC * 60),
        ] {
            assert_eq!(budget.allowance(bytes), expected, "{bytes} B");
        }
        // The rate rule disabled: only the ceiling cuts after grace.
        let no_rate = HeadBudget::new(
            &HeaderReadTimeout {
                min_rate: 0,
                ..config
            },
            None,
        );
        assert_eq!(no_rate.allowance(0), SEC * 60);
        // A ceiling below the grace wins.
        let short = HeadBudget::new(
            &HeaderReadTimeout {
                ceiling: SEC * 5,
                ..config
            },
            Some(SEC),
        );
        assert_eq!(short.allowance(0), SEC * 5);
        assert_eq!(short.allowance(u64::MAX), SEC * 5);
        // RTT extends the grace but never the ceiling.
        let far = HeadBudget::new(&config, Some(ms(500)));
        assert_eq!(far.allowance(0), SEC * 12);
    }

    #[test]
    fn idle_earned_rule() {
        let now = Instant::now();
        let mut deadlines = ConnDeadlines::new(Some(IdleTimeout::DEFAULT), None);
        assert_eq!(
            deadlines.observe(Activity::Idle, || now),
            Some((now + SEC * 10, Expired::Idle)),
            "first request window"
        );
        deadlines.set_rtt(ms(250));
        assert_eq!(
            deadlines.observe(Activity::Idle, || unreachable!("phase continues")),
            Some((now + SEC * 11, Expired::Idle)),
            "an RTT measured mid-phase extends the running window"
        );
        assert_eq!(deadlines.observe(Activity::Busy, || now), None);
        let later = now + SEC;
        assert_eq!(
            deadlines.observe(Activity::Idle, || later),
            Some((now + SEC * 11, Expired::Idle)),
            "a pause does not restart the first request window"
        );
        deadlines.request_received();
        let after = now + SEC * 2;
        assert_eq!(
            deadlines.observe(Activity::Idle, || after),
            Some((after + SEC * 90, Expired::Idle)),
            "earned budget"
        );
        assert_eq!(
            deadlines.observe(head(10), || after),
            None,
            "no head deadline configured"
        );
        let next = after + SEC * 5;
        assert_eq!(
            deadlines.observe(Activity::Idle, || next),
            Some((next + SEC * 90, Expired::Idle)),
            "an earned budget restarts after every phase"
        );
    }

    #[test]
    fn rejected_heads_never_restart_the_first_request_window() {
        let now = Instant::now();
        let mut deadlines =
            ConnDeadlines::new(Some(IdleTimeout::DEFAULT), Some(HeaderReadTimeout::DEFAULT));
        assert_eq!(
            deadlines.observe(Activity::Idle, || now),
            Some((now + SEC * 10, Expired::Idle))
        );
        for round in 1..5 {
            let head_at = now + SEC * 9 * round;
            assert_eq!(
                deadlines.observe(head(9), || head_at),
                Some((head_at + SEC * 10, Expired::Head)),
                "a head in progress has its own deadline"
            );
            let rejected = head_at + ms(500);
            assert_eq!(
                deadlines.observe(Activity::Idle, || rejected),
                Some((now + SEC * 10, Expired::Idle)),
                "round {round}: the window stays anchored at the first idle phase"
            );
        }
    }

    #[test]
    fn a_new_header_block_starts_a_new_head() {
        let now = Instant::now();
        let mut deadlines = ConnDeadlines::new(None, Some(HeaderReadTimeout::DEFAULT));
        assert_eq!(
            deadlines.observe(Activity::Head { bytes: 1, block: 4 }, || now),
            Some((now + SEC * 10, Expired::Head))
        );
        assert_eq!(
            deadlines.observe(Activity::Head { bytes: 2, block: 4 }, || unreachable!()),
            Some((now + SEC * 10, Expired::Head)),
            "the same block continues"
        );
        let next = now + SEC * 5;
        assert_eq!(
            deadlines.observe(Activity::Head { bytes: 5, block: 5 }, || next),
            Some((next + SEC * 10, Expired::Head)),
            "the next block gets its own grace without an idle gap"
        );
    }

    #[test]
    fn head_and_idle_phases_do_not_share_their_start() {
        let now = Instant::now();
        let mut deadlines =
            ConnDeadlines::new(Some(IdleTimeout::DEFAULT), Some(HeaderReadTimeout::DEFAULT));
        assert_eq!(
            deadlines.observe(Activity::Idle, || now),
            Some((now + SEC * 10, Expired::Idle))
        );
        let first_byte = now + SEC * 9;
        assert_eq!(
            deadlines.observe(head(1), || first_byte),
            Some((first_byte + SEC * 10, Expired::Head)),
            "the head gets its own grace, starting at its first byte"
        );
        assert_eq!(
            deadlines.observe(head(5_120), || unreachable!()),
            Some((
                first_byte + SEC * 20 + Duration::from_nanos(1),
                Expired::Head
            )),
        );
        deadlines.request_received();
        let idle = now + SEC * 12;
        assert_eq!(
            deadlines.observe(Activity::Idle, || idle),
            Some((idle + SEC * 90, Expired::Idle))
        );
    }

    #[test]
    fn drain_counts_from_each_idle_phase() {
        let now = Instant::now();
        let mut deadlines =
            ConnDeadlines::new(Some(IdleTimeout::DEFAULT), Some(HeaderReadTimeout::DEFAULT));
        deadlines.start_drain();
        assert_eq!(
            deadlines.observe(Activity::Idle, || now),
            Some((now + SEC, Expired::Drain))
        );
        assert_eq!(deadlines.observe(Activity::Busy, || now), None);
        let done = now + SEC * 3;
        assert_eq!(
            deadlines.observe(Activity::Idle, || done),
            Some((done + SEC, Expired::Drain)),
            "a request that raced the close gets the whole drain once it completes"
        );
        let head_at = done + ms(10);
        assert_eq!(
            deadlines.observe(head(0), || head_at),
            Some((head_at + SEC * 10, Expired::Head)),
            "heads keep their own deadline while draining"
        );
        let mut far = ConnDeadlines::new(None, None);
        far.set_rtt(SEC * 2);
        far.start_drain();
        assert_eq!(
            far.observe(Activity::Idle, || now),
            Some((now + SEC * 8, Expired::Drain)),
            "drain applies even without an idle budget and follows the RTT"
        );
    }

    #[test]
    fn disabled_deadlines_never_expire() {
        let mut deadlines = ConnDeadlines::new(None, None);
        assert!(!deadlines.is_enabled());
        for activity in [Activity::Busy, Activity::Idle, head(3)] {
            assert_eq!(deadlines.observe(activity, Instant::now), None);
        }
    }

    #[test]
    fn deadlines_match_history_reference() {
        #[expect(
            clippy::needless_pass_by_value,
            reason = "QuickCheck passes generated values by ownership"
        )]
        fn property(
            first: u16,
            idle: u16,
            grace: u16,
            rate: u8,
            enabled: u8,
            steps: Vec<(u16, u8, u16)>,
        ) -> bool {
            let idle = (enabled & 1 == 0).then(|| IdleTimeout {
                first_request: ms(u64::from(first)),
                idle: ms(u64::from(idle)),
            });
            let head = (enabled & 2 == 0).then(|| HeaderReadTimeout {
                grace: ms(u64::from(grace)),
                min_rate: u32::from(rate),
                ceiling: ms(u64::from(grace) * 4),
            });
            model::conforms(idle, head, &steps)
        }
        QuickCheck::new()
            .tests(20_000)
            .quickcheck(property as fn(u16, u16, u16, u8, u8, Vec<(u16, u8, u16)>) -> bool);
    }

    // ===== property tests =====

    /// A byte-arrival schedule for one head: (delay since the previous event, bytes).
    #[derive(Debug, Clone)]
    struct Schedule {
        config: HeaderReadTimeout,
        rtt: Option<Duration>,
        arrivals: Vec<(Duration, u64)>,
    }

    impl Arbitrary for Schedule {
        fn arbitrary(g: &mut Gen) -> Self {
            let grace = ms(u64::from(u16::arbitrary(g) % 20_000));
            let ceiling = grace + ms(u64::from(u16::arbitrary(g) % 60_000));
            let min_rate = match u8::arbitrary(g) % 4 {
                0 => 0,
                1 => 1 + u32::from(u8::arbitrary(g)),
                _ => 1 + u32::from(u16::arbitrary(g) % 2_048),
            };
            let rtt = bool::arbitrary(g).then(|| ms(u64::from(u16::arbitrary(g) % 3_000)));
            let len = usize::arbitrary(g) % 24;
            let arrivals = (0..len)
                .map(|_| {
                    let delay = ms(u64::from(u16::arbitrary(g) % 8_000));
                    let bytes = match u8::arbitrary(g) % 3 {
                        0 => u64::from(u8::arbitrary(g) % 4),
                        1 => u64::from(u16::arbitrary(g) % 1_500),
                        _ => u64::from(u16::arbitrary(g)),
                    };
                    (delay, bytes)
                })
                .collect();
            Self {
                config: HeaderReadTimeout {
                    grace,
                    min_rate,
                    ceiling,
                },
                rtt,
                arrivals,
            }
        }
    }

    impl Schedule {
        /// Arrival offsets from the first byte (which arrives at offset zero) with
        /// the cumulative byte count after each one.
        fn cumulative(&self) -> Vec<(Duration, u64)> {
            let mut at = Duration::ZERO;
            let mut total = 1u64;
            let mut out = vec![(Duration::ZERO, total)];
            for (delay, bytes) in &self.arrivals {
                at += *delay;
                total = total.saturating_add(*bytes);
                out.push((at, total));
            }
            out
        }

        fn bytes_at(cumulative: &[(Duration, u64)], at: Duration) -> u64 {
            cumulative
                .iter()
                .take_while(|(offset, _)| *offset <= at)
                .last()
                .map_or(0, |(_, bytes)| *bytes)
        }

        /// The rule as specified: cut at the first offset `t` such that `t` reached
        /// the ceiling, or `t` is past the grace window and fewer than
        /// `min_rate * t` bytes arrived. Exact rational arithmetic in nanoseconds.
        fn reference_cut(&self) -> Duration {
            let cumulative = self.cumulative();
            let grace = with_rtt(self.config.grace, self.rtt).min(self.config.ceiling);
            let below = |at: Duration, bytes: u64| {
                self.config.min_rate != 0
                    && u128::from(bytes) * 1_000_000_000
                        < u128::from(self.config.min_rate) * at.as_nanos()
            };
            // Between arrivals the byte count is constant, so the earliest cut in an
            // interval is either its start or the instant the rate drops below.
            let mut candidates = vec![self.config.ceiling, grace];
            for (offset, bytes) in &cumulative {
                candidates.push(*offset);
                if self.config.min_rate != 0 {
                    candidates.push(rate_allowance(*bytes, self.config.min_rate));
                }
            }
            candidates.sort();
            candidates
                .into_iter()
                .find(|at| {
                    *at >= self.config.ceiling
                        || (*at >= grace && below(*at, Self::bytes_at(&cumulative, *at)))
                })
                .unwrap_or(self.config.ceiling)
        }

        /// Drive [`ConnDeadlines`] and [`LazyDeadline`] the way the servers do,
        /// with a simulated timer that fires exactly at its armed instant.
        fn simulated_cut(&self) -> Duration {
            let start = Instant::now();
            let cumulative = self.cumulative();
            let mut deadlines = ConnDeadlines::new(None, Some(self.config));
            if let Some(rtt) = self.rtt {
                deadlines.set_rtt(rtt);
            }
            let mut armed: Option<Instant> = None;
            let mut events = cumulative.iter().peekable();
            let mut bytes = 0;
            let mut now = start;
            loop {
                // Deliver every arrival up to `now`, then observe like a poll would.
                while let Some((_, total)) = events.next_if(|(offset, _)| start + *offset <= now) {
                    bytes = *total;
                }
                let (deadline, expired) = deadlines
                    .observe(head(bytes), || now)
                    .expect("head deadline configured");
                assert_eq!(expired, Expired::Head);
                if armed.is_none_or(|armed| armed > deadline) {
                    armed = Some(deadline);
                }
                let fire = armed.expect("armed above");
                match events.peek() {
                    Some((offset, _)) if start + *offset < fire => now = start + *offset,
                    _ => {
                        now = fire;
                        armed = None;
                        // The timer fired: observe with the bytes known at that instant.
                        while let Some((_, total)) =
                            events.next_if(|(offset, _)| start + *offset <= now)
                        {
                            bytes = *total;
                        }
                        let (deadline, _) = deadlines
                            .observe(head(bytes), || unreachable!())
                            .expect("head deadline configured");
                        if deadline <= fire {
                            return fire.duration_since(start);
                        }
                    }
                }
            }
        }
    }

    #[test]
    fn head_deadline_matches_reference_rule() {
        #[expect(
            clippy::needless_pass_by_value,
            reason = "QuickCheck passes generated values by ownership"
        )]
        fn property(schedule: Schedule) -> bool {
            schedule.simulated_cut() == schedule.reference_cut()
        }
        QuickCheck::new()
            .tests(20_000)
            .quickcheck(property as fn(Schedule) -> bool);
    }

    #[test]
    fn head_deadline_invariants() {
        #[expect(
            clippy::needless_pass_by_value,
            reason = "QuickCheck passes generated values by ownership"
        )]
        fn property(schedule: Schedule) -> bool {
            let cut = schedule.simulated_cut();
            let config = schedule.config;
            let grace = with_rtt(config.grace, schedule.rtt).min(config.ceiling);
            let cumulative = schedule.cumulative();
            // Never inside the grace window, always by the ceiling.
            let bounded = cut >= grace && cut <= config.ceiling;
            // A schedule whose average rate never drops below the floor after
            // the grace window is only cut by the ceiling.
            let steady = config.min_rate != 0
                && cumulative
                    .iter()
                    .zip(cumulative.iter().skip(1))
                    .all(|(now, next)| {
                        // The rate is lowest right before the next arrival.
                        next.0 <= grace
                            || u128::from(now.1) * 1_000_000_000
                                >= u128::from(config.min_rate) * next.0.as_nanos()
                    })
                && cumulative.last().is_some_and(|(_, bytes)| {
                    u128::from(*bytes) * 1_000_000_000
                        >= u128::from(config.min_rate) * config.ceiling.as_nanos()
                });
            // A trickle already below the floor when the grace ends is cut right then.
            let at_grace = Schedule::bytes_at(&cumulative, grace);
            let trickle = config.min_rate != 0
                && u128::from(at_grace) * 1_000_000_000
                    < u128::from(config.min_rate) * grace.as_nanos();
            bounded && (!steady || cut == config.ceiling) && (!trickle || cut == grace)
        }
        QuickCheck::new()
            .tests(20_000)
            .quickcheck(property as fn(Schedule) -> bool);
    }

    #[tokio::test(start_paused = true)]
    async fn lazy_deadline_resets_only_to_earlier_deadlines() {
        let start = Instant::now();
        let mut lazy = LazyDeadline::default();
        let mut slot: Option<Pin<Box<Sleep>>> = None;
        let mut deadline = start + SEC * 10;
        // Pending: arms at 10 s.
        assert!(
            poll_fn(|cx| Poll::Ready(lazy.poll(&mut slot, cx, deadline)))
                .await
                .is_pending()
        );
        assert_eq!(lazy.armed, Some(start + SEC * 10));
        // A later deadline keeps the earlier timer.
        deadline = start + SEC * 20;
        assert!(
            poll_fn(|cx| Poll::Ready(lazy.poll(&mut slot, cx, deadline)))
                .await
                .is_pending()
        );
        assert_eq!(lazy.armed, Some(start + SEC * 10));
        // When the early timer fires, the later deadline is adopted.
        advance(SEC * 10).await;
        assert!(
            poll_fn(|cx| Poll::Ready(lazy.poll(&mut slot, cx, deadline)))
                .await
                .is_pending()
        );
        assert_eq!(lazy.armed, Some(start + SEC * 20));
        // An earlier deadline resets right away and expires.
        deadline = start + SEC * 15;
        poll_fn(|cx| lazy.poll(&mut slot, cx, deadline)).await;
        assert_eq!(Instant::now(), start + SEC * 15);
        assert_eq!(lazy.armed, None);
    }

    #[tokio::test(start_paused = true)]
    async fn conn_timer_reports_each_expiry() {
        let start = Instant::now();
        let mut timer =
            ConnTimer::new(Some(IdleTimeout::DEFAULT), Some(HeaderReadTimeout::DEFAULT));
        assert_eq!(
            poll_fn(|cx| timer.poll(cx, Activity::Idle)).await,
            Expired::Idle
        );
        assert_eq!(Instant::now(), start + SEC * 10);

        let head_at = Instant::now();
        assert_eq!(poll_fn(|cx| timer.poll(cx, head(100))).await, Expired::Head);
        assert_eq!(Instant::now(), head_at + SEC * 10);

        timer.request_received();
        let idle = Instant::now();
        assert_eq!(
            poll_fn(|cx| timer.poll(cx, Activity::Idle)).await,
            Expired::Idle
        );
        assert_eq!(Instant::now(), idle + SEC * 90);

        timer.start_drain();
        let drain = Instant::now();
        assert_eq!(
            poll_fn(|cx| timer.poll(cx, Activity::Idle)).await,
            Expired::Drain
        );
        assert_eq!(Instant::now(), drain + SEC);
    }

    #[tokio::test(start_paused = true)]
    async fn conn_timer_busy_never_expires() {
        let mut timer =
            ConnTimer::new(Some(IdleTimeout::DEFAULT), Some(HeaderReadTimeout::DEFAULT));
        let busy = poll_fn(|cx| Poll::Ready(timer.poll(cx, Activity::Busy))).await;
        assert!(busy.is_pending());
        advance(Duration::from_hours(1)).await;
        let busy = poll_fn(|cx| Poll::Ready(timer.poll(cx, Activity::Busy))).await;
        assert!(busy.is_pending());
    }

    #[tokio::test(start_paused = true)]
    async fn elapsed_deadline_is_seen_with_an_exhausted_task_budget() {
        let mut timer = ConnTimer::new(Some(IdleTimeout::DEFAULT), None);
        assert!(
            poll_fn(|cx| Poll::Ready(timer.poll(cx, Activity::Idle)))
                .await
                .is_pending()
        );
        advance(SEC * 10).await;
        let expired = poll_fn(|cx| {
            // Spend the whole budget, as a stream of ready frames would.
            while let Poll::Ready(budget) = poll_proceed(cx) {
                budget.made_progress();
            }
            Poll::Ready(timer.poll(cx, Activity::Idle))
        })
        .await;
        assert_eq!(expired, Poll::Ready(Expired::Idle));
    }

    #[tokio::test(start_paused = true)]
    async fn handoff_keeps_the_anchor_rtt_and_timer() {
        let start = Instant::now();
        let mut timer = ConnTimer::new(Some(IdleTimeout::DEFAULT), None);
        timer.set_rtt(ms(250));
        assert!(
            poll_fn(|cx| Poll::Ready(timer.poll(cx, Activity::Idle)))
                .await
                .is_pending()
        );
        let sleep = timer
            .sleep
            .as_ref()
            .map(|sleep| ptr::from_ref::<Sleep>(sleep));
        advance(SEC * 4).await;
        timer.reconfigure(
            Some(IdleTimeout {
                first_request: SEC * 20,
                idle: SEC * 30,
            }),
            Some(HeaderReadTimeout::DEFAULT),
        );
        timer.mark_busy();
        assert!(
            poll_fn(|cx| Poll::Ready(timer.poll(cx, Activity::Idle)))
                .await
                .is_pending()
        );
        assert_eq!(
            timer
                .sleep
                .as_ref()
                .map(|sleep| ptr::from_ref::<Sleep>(sleep)),
            sleep,
            "the timer allocation is reused"
        );
        assert_eq!(
            poll_fn(|cx| timer.poll(cx, Activity::Idle)).await,
            Expired::Idle
        );
        assert_eq!(
            Instant::now(),
            start + SEC * 21,
            "the new budget applies from the original first idle phase, with the RTT"
        );
    }

    #[tokio::test(start_paused = true)]
    async fn head_elapsed_follows_the_head_in_progress() {
        let mut timer = ConnTimer::new(None, Some(HeaderReadTimeout::DEFAULT));
        assert!(!timer.head_elapsed(0), "no head in progress");
        assert!(
            poll_fn(|cx| Poll::Ready(timer.poll(cx, head(1))))
                .await
                .is_pending()
        );
        advance(SEC * 10).await;
        assert!(timer.head_elapsed(1));
        assert!(
            !timer.head_elapsed(5_120),
            "more bytes earn more time at the minimum rate"
        );
        timer.request_received();
        assert!(!timer.head_elapsed(1), "a received head is done");
    }
}
