use std::{
    collections::BTreeMap,
    iter,
    net::{Ipv4Addr, Ipv6Addr},
};

use quickcheck::{Arbitrary, Gen, QuickCheck, TestResult};

use super::*;

fn config(min: usize, max: usize, limit: usize) -> AdmissionConfig {
    AdmissionConfig::default()
        .with_retry_threshold_min(min)
        .with_retry_threshold_max(max)
        .with_max_in_progress(limit)
}

fn v4(last: u8) -> IpAddr {
    IpAddr::V4(Ipv4Addr::new(10, 0, 0, last))
}

fn admit(decision: Decision<Ticket>) -> Ticket {
    match decision {
        Decision::Admit(ticket) => ticket,
        other => panic!("expected an admission, got {other:?}"),
    }
}

#[track_caller]
fn assert_retry(decision: &Decision<Ticket>) {
    assert!(
        matches!(decision, Decision::Retry),
        "expected a Retry, got {decision:?}"
    );
}

#[track_caller]
fn assert_refused(decision: Decision<Ticket>, refusal: Refusal) {
    match decision {
        Decision::Refuse(got) => assert_eq!(got, refusal),
        other => panic!("expected {refusal:?}, got {other:?}"),
    }
}

#[test]
fn defaults_are_lenient_and_bounded() {
    let config = AdmissionConfig::default();
    assert_eq!(config.retry_threshold_min, 256);
    assert_eq!(config.retry_threshold_max, 4096);
    assert_eq!(config.max_in_progress, 16_384);
    let per_source = config.max_in_progress_per_source.unwrap().get();
    assert!(
        per_source < config.max_in_progress,
        "one source cannot take every slot"
    );
    assert!(
        per_source >= 1024,
        "lenient for sources behind carrier-grade NAT"
    );
    assert!(config.retry_threshold_min <= config.retry_threshold_max);
    assert!(config.retry_threshold_max <= config.max_in_progress);
}

#[test]
fn attempts_below_the_threshold_are_admitted_without_retry() {
    let now = Instant::now();
    let config = config(4, 4, 100);
    let mut controller = AdmissionController::default();
    let tickets: Vec<_> = (0..4)
        .map(|n| admit(controller.arrive(now, Some(&config), v4(n), false)))
        .collect();
    assert_eq!(controller.in_progress(), 4);
    assert!(controller.is_retrying());
    for ticket in tickets {
        controller.abandon(ticket);
    }
    assert_eq!(controller.in_progress(), 0);
}

#[test]
fn above_the_threshold_unvalidated_attempts_are_retried_and_validated_ones_admitted() {
    let now = Instant::now();
    let config = config(4, 4, 100);
    let mut controller = AdmissionController::default();
    let mut held: Vec<_> = (0..4)
        .map(|n| admit(controller.arrive(now, Some(&config), v4(n), false)))
        .collect();
    for n in 0..8 {
        assert_retry(&controller.arrive(now, Some(&config), v4(n), false));
    }
    assert_eq!(controller.in_progress(), 4, "a Retry holds nothing");
    for n in 0..8 {
        held.push(admit(controller.arrive(now, Some(&config), v4(n), true)));
    }
    assert_eq!(controller.in_progress(), 12);
    for ticket in held {
        controller.abandon(ticket);
    }
    assert_eq!(controller.in_progress(), 0);
}

#[test]
fn at_the_limit_every_attempt_is_refused() {
    let now = Instant::now();
    let config = config(2, 2, 5);
    let mut controller = AdmissionController::default();
    let mut held: Vec<_> = (0..5)
        .map(|n| admit(controller.arrive(now, Some(&config), v4(n), true)))
        .collect();
    assert_refused(
        controller.arrive(now, Some(&config), v4(9), true),
        Refusal::Limit,
    );
    assert_refused(
        controller.arrive(now, Some(&config), v4(9), false),
        Refusal::Limit,
    );
    controller.abandon(held.pop().unwrap());
    held.push(admit(controller.arrive(now, Some(&config), v4(9), true)));
    assert_eq!(controller.in_progress(), 5);
    for ticket in held {
        controller.abandon(ticket);
    }
}

#[test]
fn a_zero_limit_refuses_everything_and_a_zero_threshold_retries_every_unvalidated_attempt() {
    let now = Instant::now();
    let mut controller = AdmissionController::default();
    assert_refused(
        controller.arrive(now, Some(&config(0, 0, 0)), v4(1), true),
        Refusal::Limit,
    );
    let always_validate = config(0, 0, 10);
    assert_retry(&controller.arrive(now, Some(&always_validate), v4(1), false));
    let ticket = admit(controller.arrive(now, Some(&always_validate), v4(1), true));
    assert_retry(&controller.arrive(now, Some(&always_validate), v4(1), false));
    controller.abandon(ticket);
    assert_retry(&controller.arrive(now, Some(&always_validate), v4(1), false));
}

#[test]
fn retry_stays_on_until_three_quarters_of_the_threshold() {
    let now = Instant::now();
    let config = config(8, 8, 100);
    let mut controller = AdmissionController::default();
    let mut held: Vec<_> = (0..8)
        .map(|n| admit(controller.arrive(now, Some(&config), v4(n), false)))
        .collect();
    assert!(controller.is_retrying());
    // Down to the low watermark (6): still validating.
    controller.abandon(held.pop().unwrap());
    controller.abandon(held.pop().unwrap());
    assert_eq!(controller.in_progress(), 6);
    assert_retry(&controller.arrive(now, Some(&config), v4(1), false));
    // Below it: lenient again, until the threshold is reached once more.
    controller.abandon(held.pop().unwrap());
    held.push(admit(controller.arrive(now, Some(&config), v4(1), false)));
    held.push(admit(controller.arrive(now, Some(&config), v4(2), false)));
    held.push(admit(controller.arrive(now, Some(&config), v4(3), false)));
    assert_eq!(controller.in_progress(), 8);
    assert_retry(&controller.arrive(now, Some(&config), v4(4), false));
    for ticket in held {
        controller.abandon(ticket);
    }
}

#[test]
fn the_per_source_limit_counts_only_validated_attempts_and_groups_ipv6_by_prefix() {
    let now = Instant::now();
    let config =
        config(100, 100, 1000).with_max_in_progress_per_source(NonZeroUsize::new(2).unwrap());
    let mut controller = AdmissionController::default();
    let mut held = Vec::new();
    held.push(admit(controller.arrive(now, Some(&config), v4(1), true)));
    held.push(admit(controller.arrive(now, Some(&config), v4(1), true)));
    assert_refused(
        controller.arrive(now, Some(&config), v4(1), true),
        Refusal::Source,
    );
    // A spoofable source address charges nobody.
    for _ in 0..10 {
        held.push(admit(controller.arrive(now, Some(&config), v4(1), false)));
    }
    assert_eq!(controller.held_by(v4(1)), 2);
    held.push(admit(controller.arrive(now, Some(&config), v4(2), true)));

    // The v4-mapped form of an address is that address.
    let mapped = IpAddr::V6(Ipv4Addr::new(10, 0, 0, 1).to_ipv6_mapped());
    assert_refused(
        controller.arrive(now, Some(&config), mapped, true),
        Refusal::Source,
    );

    // One /64 is one source; another /64 is another.
    let host =
        |prefix: u16, host: u16| IpAddr::V6(Ipv6Addr::new(0x2001, 0xdb8, 0, prefix, 0, 0, 0, host));
    held.push(admit(controller.arrive(
        now,
        Some(&config),
        host(1, 1),
        true,
    )));
    held.push(admit(controller.arrive(
        now,
        Some(&config),
        host(1, 2),
        true,
    )));
    assert_refused(
        controller.arrive(now, Some(&config), host(1, 3), true),
        Refusal::Source,
    );
    held.push(admit(controller.arrive(
        now,
        Some(&config),
        host(2, 1),
        true,
    )));

    for ticket in held {
        controller.abandon(ticket);
    }
    assert_eq!(controller.in_progress(), 0);
    assert!(
        controller.per_source.is_empty(),
        "{:?}",
        controller.per_source
    );
}

#[test]
fn tickets_admitted_with_a_per_source_limit_are_released_after_it_is_lifted() {
    let now = Instant::now();
    let limited =
        config(10, 10, 100).with_max_in_progress_per_source(NonZeroUsize::new(1).unwrap());
    let unlimited = config(10, 10, 100);
    let mut controller = AdmissionController::default();
    let ticket = admit(controller.arrive(now, Some(&limited), v4(1), true));
    let other = admit(controller.arrive(now, Some(&unlimited), v4(1), true));
    controller.complete(ticket, now);
    controller.abandon(other);
    assert_eq!(controller.in_progress(), 0);
    assert!(controller.per_source.is_empty());
}

#[test]
fn without_a_configuration_attempts_are_admitted_and_still_counted() {
    let now = Instant::now();
    let mut controller = AdmissionController::default();
    let held: Vec<_> = (0..1000)
        .map(|n| admit(controller.arrive(now, None, v4((n % 250) as u8), n % 2 == 0)))
        .collect();
    assert_eq!(controller.in_progress(), 1000);
    assert!(!controller.is_retrying());
    for ticket in held {
        controller.complete(ticket, now);
    }
    assert_eq!(controller.in_progress(), 0);
}

#[test]
fn the_threshold_follows_the_completion_rate_within_its_bounds() {
    let start = Instant::now();
    let config = config(10, 100, 1000);
    let mut controller = AdmissionController::default();
    assert_eq!(
        controller.threshold(start, &config),
        10,
        "idle: the minimum"
    );

    // Fifty completions per second.
    let mut now = start;
    let mut thresholds = Vec::new();
    for second in 0..12u64 {
        for n in 0..50u64 {
            now = start + Duration::from_secs(second) + Duration::from_millis(n * 19);
            let ticket = admit(controller.arrive(now, Some(&config), v4(1), true));
            controller.complete(ticket, now);
        }
        thresholds.push(controller.threshold(start + Duration::from_secs(second + 1), &config));
    }
    assert!(
        thresholds.windows(2).all(|pair| pair[0] <= pair[1]),
        "a steady rate only raises it: {thresholds:?}"
    );
    let settled = *thresholds.last().unwrap();
    assert!((45..=50).contains(&settled), "{thresholds:?}");
    assert!(thresholds[2] >= 40, "it rises quickly: {thresholds:?}");

    // Idle: it falls slowly, back to the minimum.
    let quiet = now + Duration::from_secs(2);
    let after_two = controller.threshold(quiet, &config);
    assert!(
        after_two >= settled * 3 / 4 - 1,
        "{after_two} after {settled}"
    );
    assert_eq!(
        controller.threshold(quiet + Duration::from_secs(3600), &config),
        10
    );

    // A thousand per second is capped at the maximum.
    let busy = quiet + Duration::from_secs(3600);
    for second in 0..6u64 {
        for n in 0..1000u64 {
            let at = busy + Duration::from_secs(second) + Duration::from_micros(n * 900);
            let ticket = admit(controller.arrive(at, None, v4(1), true));
            controller.complete(ticket, at);
        }
    }
    let capped = controller.threshold(busy + Duration::from_secs(6), &config);
    assert_eq!(capped, 100);
    // And the limit caps the maximum.
    assert_eq!(
        controller.threshold(
            busy + Duration::from_secs(6),
            &config.clone().with_max_in_progress(30)
        ),
        30
    );
    assert_eq!(controller.in_progress(), 0);
}

#[test]
fn abandoned_attempts_do_not_count_as_completions() {
    let start = Instant::now();
    let config = config(1, 1000, 10_000);
    let mut controller = AdmissionController::default();
    for second in 0..5u64 {
        let at = start + Duration::from_secs(second);
        let held: Vec<_> = (0..200)
            .map(|_| admit(controller.arrive(at, None, v4(1), false)))
            .collect();
        for ticket in held {
            controller.abandon(ticket);
        }
    }
    assert_eq!(
        controller.threshold(start + Duration::from_secs(5), &config),
        1
    );
}

#[test]
fn a_gap_of_any_length_is_folded_in_bounded_work() {
    let start = Instant::now();
    let mut rate = CompletionRate::default();
    rate.advance(start);
    rate.in_window = u64::MAX;
    rate.advance(start + Duration::from_secs(1));
    assert!(rate.per_window() > 0);
    // Centuries of idle windows decay it to nothing without iterating over each one.
    rate.advance(start + Duration::from_secs(1) + Duration::from_hours(24 * 365 * 100));
    assert_eq!(rate.per_window(), 0);
    // A clock that does not move does not fold anything.
    let before = rate.smoothed;
    rate.advance(start);
    assert_eq!(rate.smoothed, before);
}

#[test]
fn a_lease_is_released_exactly_once_whichever_way_it_ends() {
    let now = Instant::now();
    let config = config(1, 1, 3).with_max_in_progress_per_source(NonZeroUsize::new(3).unwrap());
    let admission = Admission::default();
    let lease = |admission: &Admission| match admission.arrive(now, Some(&config), v4(1), true) {
        Decision::Admit(lease) => lease,
        other => panic!("expected an admission, got {other:?}"),
    };
    let completed = lease(&admission);
    let dropped = lease(&admission);
    let kept = lease(&admission);
    assert_eq!(admission.load(now, Some(&config)).0, 3);
    completed.complete(now);
    drop(dropped);
    assert_eq!(admission.load(now, Some(&config)).0, 1);
    drop(kept);
    let controller = admission.0.lock();
    assert_eq!(controller.in_progress(), 0);
    assert!(controller.per_source.is_empty());
}

// Differential property tests against a reference model.
//
// The reference keeps every live attempt in a list and recomputes the completion rate from the
// full history of completion times, window by window from the first event, so the counters,
// the per-source map and the incremental window bookkeeping are each checked against a
// derivation that shares none of their state.

const POOL: [IpAddr; 6] = [
    IpAddr::V4(Ipv4Addr::new(192, 0, 2, 1)),
    IpAddr::V4(Ipv4Addr::new(192, 0, 2, 2)),
    IpAddr::V4(Ipv4Addr::new(198, 51, 100, 7)),
    IpAddr::V6(Ipv6Addr::new(0x2001, 0xdb8, 0, 1, 0, 0, 0, 1)),
    IpAddr::V6(Ipv6Addr::new(0x2001, 0xdb8, 0, 1, 0, 0, 0, 2)),
    IpAddr::V6(Ipv6Addr::new(0x2001, 0xdb8, 0, 2, 0, 0, 0, 1)),
];

#[derive(Debug, Clone, Copy)]
enum Op {
    Arrive { source: usize, validated: bool },
    Complete(usize),
    Abandon(usize),
    Advance(u64),
    Threshold,
}

impl Arbitrary for Op {
    fn arbitrary(g: &mut Gen) -> Self {
        match u8::arbitrary(g) % 10 {
            0..=3 => Self::Arrive {
                source: usize::arbitrary(g) % POOL.len(),
                validated: bool::arbitrary(g),
            },
            4 | 5 => Self::Complete(usize::arbitrary(g)),
            6 => Self::Abandon(usize::arbitrary(g)),
            7 | 8 => Self::Advance(match u8::arbitrary(g) % 4 {
                // within a window, across one, across many, and very far
                0 => u64::from(u16::arbitrary(g) % 1000),
                1 => 1000 + u64::from(u16::arbitrary(g) % 1000),
                2 => u64::from(u32::arbitrary(g) % 120_000),
                _ => u64::from(u32::arbitrary(g) % 10_000_000) * 1000,
            }),
            _ => Self::Threshold,
        }
    }

    fn shrink(&self) -> Box<dyn Iterator<Item = Self>> {
        match *self {
            Self::Advance(ms) => Box::new(ms.shrink().map(Self::Advance)),
            _ => Box::new(iter::empty()),
        }
    }
}

#[derive(Debug, Clone)]
struct Scenario {
    config: AdmissionConfig,
    ops: Vec<Op>,
}

impl Arbitrary for Scenario {
    fn arbitrary(g: &mut Gen) -> Self {
        let config = AdmissionConfig {
            retry_threshold_min: usize::arbitrary(g) % 12,
            retry_threshold_max: usize::arbitrary(g) % 24,
            max_in_progress: usize::arbitrary(g) % 32,
            max_in_progress_per_source: NonZeroUsize::new(usize::arbitrary(g) % 6),
        };
        Self {
            config,
            ops: Vec::arbitrary(g),
        }
    }

    fn shrink(&self) -> Box<dyn Iterator<Item = Self>> {
        let config = self.config.clone();
        Box::new(self.ops.shrink().map(move |ops| Self {
            config: config.clone(),
            ops,
        }))
    }
}

/// The controller's policy, written plainly over a list of live attempts.
#[derive(Debug, Default)]
struct Model {
    live: Vec<Option<SourceKey>>,
    retrying: bool,
    start: Option<Instant>,
    completions: Vec<Instant>,
}

impl Model {
    fn per_window_at(&self, now: Instant) -> u64 {
        let Some(start) = self.start else {
            return 0;
        };
        let window = WINDOW.as_nanos();
        let closed = now.saturating_duration_since(start).as_nanos() / window;
        let mut counts = BTreeMap::<u128, u64>::new();
        for at in &self.completions {
            let index = at.saturating_duration_since(start).as_nanos() / window;
            *counts.entry(index).or_default() += 1;
        }
        let mut smoothed: u64 = 0;
        let mut index = 0u128;
        while index < closed {
            let sample = counts.get(&index).copied().unwrap_or(0).saturating_mul(16);
            smoothed = if sample >= smoothed {
                smoothed + (sample - smoothed) / 2
            } else {
                smoothed - (smoothed - sample) / 8
            };
            index += 1;
            // Below eight an empty window changes nothing, so skip to the next one that is not.
            if smoothed < 8 {
                match counts.range(index..).next() {
                    Some((&next, _)) => index = next,
                    None => break,
                }
            }
        }
        smoothed / 16
    }

    fn threshold(&mut self, now: Instant, config: &AdmissionConfig) -> usize {
        self.start.get_or_insert(now);
        let rate = usize::try_from(self.per_window_at(now)).unwrap_or(usize::MAX);
        let ceiling = config.retry_threshold_max.max(config.retry_threshold_min);
        rate.clamp(config.retry_threshold_min, ceiling)
            .min(config.max_in_progress)
    }

    fn arrive(
        &mut self,
        now: Instant,
        config: &AdmissionConfig,
        source: IpAddr,
        validated: bool,
    ) -> Decision<()> {
        let threshold = self.threshold(now, config);
        if self.live.len() >= config.max_in_progress {
            return Decision::Refuse(Refusal::Limit);
        }
        self.mode(threshold);
        let key = SourceKey::of(source);
        let counted = validated && config.max_in_progress_per_source.is_some();
        if let Some(limit) = config.max_in_progress_per_source
            && validated
            && self.live.iter().filter(|held| **held == Some(key)).count() >= limit.get()
        {
            return Decision::Refuse(Refusal::Source);
        }
        if !validated && self.retrying {
            return Decision::Retry;
        }
        self.live.push(counted.then_some(key));
        self.mode(threshold);
        Decision::Admit(())
    }

    fn mode(&mut self, threshold: usize) {
        let low = threshold - threshold / 4;
        if self.retrying && self.live.len() < low {
            self.retrying = false;
        } else if !self.retrying && self.live.len() >= threshold {
            self.retrying = true;
        }
    }

    fn complete(&mut self, index: usize, now: Instant) {
        self.start.get_or_insert(now);
        self.completions.push(now);
        self.live.remove(index);
    }
}

fn agrees_with_the_model(scenario: Scenario) -> TestResult {
    let Scenario { config, ops } = scenario;
    let mut now = Instant::now();
    let mut controller = AdmissionController::default();
    let mut model = Model::default();
    let mut tickets: Vec<Ticket> = Vec::new();
    for op in ops {
        match op {
            Op::Arrive { source, validated } => {
                let source = POOL[source];
                let got = controller.arrive(now, Some(&config), source, validated);
                let expected = model.arrive(now, &config, source, validated);
                match (got, expected) {
                    (Decision::Admit(ticket), Decision::Admit(())) => tickets.push(ticket),
                    (Decision::Retry, Decision::Retry) => {
                        if validated {
                            return TestResult::error("a validated attempt was retried");
                        }
                    }
                    (Decision::Refuse(got), Decision::Refuse(expected)) if got == expected => {}
                    (got, expected) => {
                        return TestResult::error(format!(
                            "decision {got:?}, model {expected:?}, {} live",
                            model.live.len()
                        ));
                    }
                }
            }
            Op::Complete(index) if !tickets.is_empty() => {
                let index = index % tickets.len();
                controller.complete(tickets.remove(index), now);
                model.complete(index, now);
            }
            Op::Abandon(index) if !tickets.is_empty() => {
                let index = index % tickets.len();
                controller.abandon(tickets.remove(index));
                model.live.remove(index);
            }
            Op::Complete(_) | Op::Abandon(_) => {}
            Op::Advance(ms) => {
                if let Some(later) = now.checked_add(Duration::from_millis(ms)) {
                    now = later;
                }
            }
            Op::Threshold => {
                let got = controller.threshold(now, &config);
                let expected = model.threshold(now, &config);
                if got != expected {
                    return TestResult::error(format!("threshold {got}, model {expected}"));
                }
                let ceiling = config.retry_threshold_max.max(config.retry_threshold_min);
                if got > config.max_in_progress
                    || (got < config.retry_threshold_min.min(config.max_in_progress))
                    || got > ceiling
                {
                    return TestResult::error(format!("threshold {got} out of bounds"));
                }
            }
        }
        if controller.in_progress() != model.live.len() || controller.in_progress() != tickets.len()
        {
            return TestResult::error("in-progress count drifted");
        }
        if controller.in_progress() > config.max_in_progress {
            return TestResult::error("past the limit");
        }
        if controller.retrying != model.retrying {
            return TestResult::error("retry mode drifted");
        }
        for (key, held) in &controller.per_source {
            let expected = model
                .live
                .iter()
                .filter(|live| **live == Some(*key))
                .count();
            if held.get() != expected {
                return TestResult::error(format!("{key:?} holds {held}, model {expected}"));
            }
            if config
                .max_in_progress_per_source
                .is_some_and(|limit| held.get() > limit.get())
            {
                return TestResult::error("a source past its limit");
            }
        }
        if model
            .live
            .iter()
            .flatten()
            .any(|key| !controller.per_source.contains_key(key))
        {
            return TestResult::error("a counted source is missing");
        }
    }
    for ticket in tickets {
        controller.abandon(ticket);
    }
    if controller.in_progress() != 0 || !controller.per_source.is_empty() {
        return TestResult::error("attempts leaked after every lease was released");
    }
    TestResult::passed()
}

#[test]
fn the_controller_agrees_with_the_reference_model() {
    QuickCheck::new()
        .tests(4_000)
        .rng(Gen::new(200))
        .quickcheck(agrees_with_the_model as fn(Scenario) -> TestResult);
}
