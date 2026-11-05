use crate::driver::{Duration, Instant};

/// Limits the amount of time spent on a certain type of work in a cycle
///
/// The limiter works dynamically: For a sampled subset of cycles it measures
/// the time that is approximately required for fulfilling 1 work item, and
/// calculates the amount of allowed work items per cycle.
/// The estimates are smoothed over all cycles where the exact duration is measured.
///
/// In cycles where no measurement is performed the previously determined work limit
/// is used.
///
/// For the limiter the exact definition of a work item does not matter.
/// It could for example track the amount of transmitted bytes per cycle,
/// or the amount of transmitted datagrams per cycle.
/// It will however work best if the required time to complete a work item is
/// constant.
///
/// A cycle is a value: [`start_cycle`](Self::start_cycle) returns the [`WorkCycle`] that
/// answers [`allow_work`](WorkCycle::allow_work) and records work, and
/// [`finish_cycle`](Self::finish_cycle) consumes it. Work can therefore never be tested or
/// recorded outside a started cycle, and a measuring cycle always carries its start time.
#[derive(Debug)]
pub(crate) struct WorkLimiter {
    /// The number of finished cycles; every `SAMPLING_INTERVAL`th cycle measures
    cycle: u16,
    /// The amount of work items which are allowed for a cycle
    allowed: usize,
    /// The desired cycle time
    desired_cycle_time: Duration,
    /// The estimated and smoothed time per work item in nanoseconds
    smoothed_time_per_work_item_nanos: f64,
}

/// One started work cycle of a [`WorkLimiter`].
#[derive(Debug)]
pub(crate) struct WorkCycle {
    kind: CycleKind,
    /// How many work items have been completed in the cycle
    completed: usize,
}

#[derive(Debug, Clone, Copy)]
enum CycleKind {
    /// Measure the time work takes; bounded by the desired cycle time.
    Measure { started: Instant, budget: Duration },
    /// Use the previous estimate; bounded by the allowed number of work items.
    HistoricData { allowed: usize },
}

impl WorkLimiter {
    pub(crate) fn new(desired_cycle_time: Duration) -> Self {
        Self {
            cycle: 0,
            allowed: 0,
            desired_cycle_time,
            smoothed_time_per_work_item_nanos: 0.0,
        }
    }

    /// Starts one work cycle
    pub(crate) fn start_cycle(&self, now: impl Fn() -> Instant) -> WorkCycle {
        let kind = if self.cycle.is_multiple_of(SAMPLING_INTERVAL) {
            CycleKind::Measure {
                started: now(),
                budget: self.desired_cycle_time,
            }
        } else {
            CycleKind::HistoricData {
                allowed: self.allowed,
            }
        };
        WorkCycle { kind, completed: 0 }
    }

    /// Finishes one work cycle
    ///
    /// For cycles where the exact duration is measured this will update the estimates
    /// for the time per work item and the limit of allowed work items per cycle.
    /// The estimate is updated using the same exponential averaging (smoothing)
    /// mechanism which is used for determining QUIC path rtts: The last value is
    /// weighted by 1/8, and the previous average by 7/8.
    #[expect(
        clippy::suboptimal_flops,
        reason = "the 7/8 + 1/8 smoothing is written as the RTT estimator is; fusing it would change the estimate's rounding"
    )]
    #[expect(
        clippy::needless_pass_by_value,
        reason = "a cycle ends here, so it is taken rather than borrowed"
    )]
    pub(crate) fn finish_cycle(&mut self, cycle: WorkCycle, now: impl Fn() -> Instant) {
        // If no work was done in the cycle drop the measurement, it won't be useful
        if cycle.completed == 0 {
            return;
        }

        if let CycleKind::Measure { started, .. } = cycle.kind {
            let elapsed = now().saturating_duration_since(started);

            let time_per_work_item_nanos = (elapsed.as_nanos()) as f64 / cycle.completed as f64;

            // Calculate the time per work item. We set this to at least 1ns to avoid
            // dividing by 0 when calculating the allowed amount of work items.
            self.smoothed_time_per_work_item_nanos = if self.allowed == 0 {
                // Initial estimate
                time_per_work_item_nanos
            } else {
                // Smoothed estimate
                (7.0 * self.smoothed_time_per_work_item_nanos + time_per_work_item_nanos) / 8.0
            }
            .max(1.0);

            // Allow at least 1 work item in order to make progress
            self.allowed = (((self.desired_cycle_time.as_nanos()) as f64
                / self.smoothed_time_per_work_item_nanos) as usize)
                .max(1);
        }

        self.cycle = self.cycle.wrapping_add(1);
    }
}

impl WorkCycle {
    /// A cycle with a fixed item allowance, independent of any clock.
    #[cfg(test)]
    pub(crate) fn with_allowance(allowed: usize) -> Self {
        Self {
            kind: CycleKind::HistoricData { allowed },
            completed: 0,
        }
    }

    /// Returns whether more work can be performed inside the desired cycle time
    ///
    /// Requires that previous work was tracked using `record_work`.
    pub(crate) fn allow_work(&self, now: impl Fn() -> Instant) -> bool {
        match self.kind {
            CycleKind::Measure { started, budget } => {
                now().saturating_duration_since(started) < budget
            }
            CycleKind::HistoricData { allowed } => self.completed < allowed,
        }
    }

    /// Records that `work` additional work items have been completed inside the cycle
    pub(crate) fn record_work(&mut self, work: usize) {
        self.completed = self.completed.saturating_add(work);
    }
}

/// We take a measurement sample once every `SAMPLING_INTERVAL` cycles
const SAMPLING_INTERVAL: u16 = 256;

#[cfg(test)]
mod tests {
    use super::*;
    use std::assert_matches;
    use std::cell::RefCell;

    #[test]
    #[expect(
        clippy::suboptimal_flops,
        reason = "the expectation is written as the estimator computes it, so the two round alike"
    )]
    fn limit_work() {
        const CYCLE_TIME: Duration = Duration::from_millis(500);
        const BATCH_WORK_ITEMS: usize = 12;
        const BATCH_TIME: Duration = Duration::from_millis(100);

        const EXPECTED_INITIAL_BATCHES: usize =
            (CYCLE_TIME.as_nanos() / BATCH_TIME.as_nanos()) as usize;
        const EXPECTED_ALLOWED_WORK_ITEMS: usize = EXPECTED_INITIAL_BATCHES * BATCH_WORK_ITEMS;

        let mut limiter = WorkLimiter::new(CYCLE_TIME);
        reset_time();

        // The initial cycle is measuring
        let mut cycle = limiter.start_cycle(get_time);
        let mut initial_batches = 0;
        while cycle.allow_work(get_time) {
            cycle.record_work(BATCH_WORK_ITEMS);
            advance_time(BATCH_TIME);
            initial_batches += 1;
        }
        limiter.finish_cycle(cycle, get_time);

        assert_eq!(initial_batches, EXPECTED_INITIAL_BATCHES);
        assert_eq!(limiter.allowed, EXPECTED_ALLOWED_WORK_ITEMS);
        let initial_time_per_work_item = limiter.smoothed_time_per_work_item_nanos;

        // The next cycles are using historic data
        const BATCH_SIZES: [usize; 4] = [1, 2, 3, 5];
        for &batch_size in &BATCH_SIZES {
            let mut cycle = limiter.start_cycle(get_time);
            let mut allowed_work = 0;
            while cycle.allow_work(get_time) {
                cycle.record_work(batch_size);
                allowed_work += batch_size;
            }
            limiter.finish_cycle(cycle, get_time);

            assert_eq!(allowed_work, EXPECTED_ALLOWED_WORK_ITEMS);
        }

        // After `SAMPLING_INTERVAL`, we get into measurement mode again
        for _ in 0..(SAMPLING_INTERVAL as usize - BATCH_SIZES.len() - 1) {
            let mut cycle = limiter.start_cycle(get_time);
            cycle.record_work(1);
            limiter.finish_cycle(cycle, get_time);
        }

        // We now do more work per cycle, and expect the estimate of allowed
        // work items to go up
        const BATCH_WORK_ITEMS_2: usize = 96;
        const TIME_PER_WORK_ITEMS_2_NANOS: f64 =
            CYCLE_TIME.as_nanos() as f64 / (EXPECTED_INITIAL_BATCHES * BATCH_WORK_ITEMS_2) as f64;

        let expected_updated_time_per_work_item =
            (initial_time_per_work_item * 7.0 + TIME_PER_WORK_ITEMS_2_NANOS) / 8.0;
        let expected_updated_allowed_work_items =
            (CYCLE_TIME.as_nanos() as f64 / expected_updated_time_per_work_item) as usize;

        let mut cycle = limiter.start_cycle(get_time);
        let mut initial_batches = 0;
        while cycle.allow_work(get_time) {
            cycle.record_work(BATCH_WORK_ITEMS_2);
            advance_time(BATCH_TIME);
            initial_batches += 1;
        }
        limiter.finish_cycle(cycle, get_time);

        assert_eq!(initial_batches, EXPECTED_INITIAL_BATCHES);
        assert_eq!(limiter.allowed, expected_updated_allowed_work_items);
    }

    #[test]
    fn idle_cycles_keep_measuring_until_work_is_seen() {
        let mut limiter = WorkLimiter::new(Duration::from_millis(10));
        reset_time();
        // Cycles without work neither advance the cadence nor produce an estimate.
        for _ in 0..3 {
            let cycle = limiter.start_cycle(get_time);
            assert_matches!(cycle.kind, CycleKind::Measure { .. });
            advance_time(Duration::from_secs(1));
            limiter.finish_cycle(cycle, get_time);
            assert_eq!(limiter.allowed, 0);
            assert_eq!(limiter.cycle, 0);
        }
        // The first cycle with work measures; the following one uses that estimate.
        let mut cycle = limiter.start_cycle(get_time);
        cycle.record_work(4);
        advance_time(Duration::from_millis(2));
        limiter.finish_cycle(cycle, get_time);
        assert_eq!(limiter.allowed, 20, "10 ms per cycle at 0.5 ms per item");
        let cycle = limiter.start_cycle(get_time);
        assert_matches!(cycle.kind, CycleKind::HistoricData { allowed: 20 });
    }

    #[test]
    fn a_slow_item_still_allows_one_per_cycle() {
        let mut limiter = WorkLimiter::new(Duration::from_millis(1));
        reset_time();
        let mut cycle = limiter.start_cycle(get_time);
        assert!(
            cycle.allow_work(get_time),
            "a fresh measuring cycle allows work"
        );
        cycle.record_work(1);
        advance_time(Duration::from_secs(5));
        assert!(!cycle.allow_work(get_time), "the budget is spent");
        limiter.finish_cycle(cycle, get_time);
        assert_eq!(limiter.allowed, 1, "progress is always possible");
        let mut cycle = limiter.start_cycle(get_time);
        assert!(cycle.allow_work(get_time));
        cycle.record_work(1);
        assert!(!cycle.allow_work(get_time), "exactly `allowed` items pass");
        limiter.finish_cycle(cycle, get_time);
    }

    #[test]
    fn a_clock_that_runs_backwards_ends_the_measurement() {
        let limiter = WorkLimiter::new(Duration::from_millis(10));
        reset_time();
        let mut cycle = limiter.start_cycle(get_time);
        cycle.record_work(1);
        let earlier = get_time().checked_sub(Duration::from_secs(1)).unwrap();
        assert!(
            cycle.allow_work(|| earlier),
            "an earlier reading counts as no time spent"
        );
        let mut limiter = limiter;
        limiter.finish_cycle(cycle, || earlier);
        assert_eq!(
            limiter.allowed, 10_000_000,
            "zero elapsed is clamped to 1 ns per item"
        );
    }

    thread_local! {
        /// Mocked time
        pub(crate) static TIME: RefCell<Instant> = RefCell::new(Instant::now());
    }

    fn reset_time() {
        TIME.with(|t| {
            *t.borrow_mut() = Instant::now();
        })
    }

    fn get_time() -> Instant {
        TIME.with(|t| *t.borrow())
    }

    fn advance_time(duration: Duration) {
        TIME.with(|t| {
            *t.borrow_mut() += duration;
        })
    }
}
