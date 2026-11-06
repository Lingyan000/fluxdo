use rama_utils::octets;
use std::fmt::{Debug, Display, Formatter};

use super::min_max::MinMax;
use crate::proto::{Duration, Instant};

#[derive(Clone, Debug, Default)]
pub(crate) struct BandwidthEstimation {
    total_acked: u64,
    prev_total_acked: u64,
    acked_time: Option<Instant>,
    prev_acked_time: Option<Instant>,
    total_sent: u64,
    prev_total_sent: u64,
    sent_time: Option<Instant>,
    prev_sent_time: Option<Instant>,
    max_filter: MinMax,
    acked_at_last_window: u64,
}

impl BandwidthEstimation {
    pub(crate) fn on_sent(&mut self, now: Instant, bytes: u64) {
        self.prev_total_sent = self.total_sent;
        self.total_sent += bytes;
        self.prev_sent_time = self.sent_time;
        self.sent_time = Some(now);
    }

    pub(crate) fn on_ack(
        &mut self,
        now: Instant,
        _sent: Instant,
        bytes: u64,
        round: u64,
        app_limited: bool,
    ) {
        // All packets in an ACK batch have the same timestamp. Keep the start of the
        // measurement interval until a later batch so every acknowledged byte contributes.
        if self.acked_time != Some(now) {
            self.prev_total_acked = self.total_acked;
            self.prev_acked_time = self.acked_time;
            self.acked_time = Some(now);
        }
        self.total_acked += bytes;

        let Some(prev_sent_time) = self.prev_sent_time else {
            return;
        };

        let send_rate = match self.sent_time {
            Some(sent_time) if sent_time > prev_sent_time => Self::bw_from_delta(
                self.total_sent - self.prev_total_sent,
                sent_time - prev_sent_time,
            )
            .unwrap_or(0),
            _ => u64::MAX, // will take the min of send and ack, so this is just a skip
        };

        let ack_rate = match self.prev_acked_time {
            Some(prev_acked_time) => Self::bw_from_delta(
                self.total_acked - self.prev_total_acked,
                now - prev_acked_time,
            )
            .unwrap_or(0),
            None => 0,
        };

        let bandwidth = send_rate.min(ack_rate);
        // Lower non-app-limited samples must advance the filter's window too. An
        // application-limited sample is useful only when it raises the estimate.
        if !app_limited || bandwidth > self.max_filter.get() {
            self.max_filter.update_max(round, bandwidth);
        }
    }

    pub(crate) fn bytes_acked_this_window(&self) -> u64 {
        self.total_acked - self.acked_at_last_window
    }

    pub(crate) fn end_acks(&mut self, _current_round: u64, _app_limited: bool) {
        self.acked_at_last_window = self.total_acked;
    }

    pub(crate) fn get_estimate(&self) -> u64 {
        self.max_filter.get()
    }

    /// Tests: the estimate a measurement would leave, without driving one.
    #[cfg(test)]
    pub(super) fn update_max_for_test(&mut self, bandwidth: u64) {
        self.max_filter.update_max(0, bandwidth);
    }

    /// Bytes per second from bytes over a span, `None` for a span of no time.
    ///
    /// The multiplication and the span are both wider than the rate, so a whole window's worth
    /// of bytes over a nanosecond gives the largest rate a `u64` holds rather than wrapping,
    /// and a span longer than a `u64` of nanoseconds is used as it is rather than truncated.
    pub(crate) const fn bw_from_delta(bytes: u64, delta: Duration) -> Option<u64> {
        let window_duration_ns = delta.as_nanos();
        if window_duration_ns == 0 {
            return None;
        }
        let per_second = (bytes as u128 * 1_000_000_000) / window_duration_ns;
        Some(if per_second > u64::MAX as u128 {
            u64::MAX
        } else {
            per_second as u64
        })
    }
}

impl Display for BandwidthEstimation {
    fn fmt(&self, f: &mut Formatter<'_>) -> std::fmt::Result {
        write!(
            f,
            "{:.3} MB/s",
            self.get_estimate() as f32 / octets::mib(1) as f32
        )
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn bandwidth_falls_after_the_measurement_window_expires() {
        let mut estimate = BandwidthEstimation::default();
        let start = Instant::now();
        for round in 0..=2 {
            let sent = start + Duration::from_millis(round);
            estimate.on_sent(sent, 1200);
            estimate.on_ack(sent + Duration::from_millis(100), sent, 1200, round, false);
        }
        assert_eq!(estimate.get_estimate(), 1_200_000);
        for round in 3..=40 {
            let sent = start + Duration::from_millis(2 + (round - 2) * 10);
            estimate.on_sent(sent, 1200);
            estimate.on_ack(sent + Duration::from_millis(100), sent, 1200, round, false);
        }
        assert_eq!(estimate.get_estimate(), 120_000);
    }

    #[test]
    fn bandwidth_counts_every_packet_in_an_ack_batch() {
        let mut estimate = BandwidthEstimation::default();
        let start = Instant::now();
        // Two 1200-byte packets per two milliseconds, acknowledged together.
        for round in 0..40 {
            for packet in 0..2 {
                estimate.on_sent(start + Duration::from_millis(round * 2 + packet), 1200);
            }
            for packet in 0..2 {
                estimate.on_ack(
                    start + Duration::from_millis(100 + round * 2),
                    start + Duration::from_millis(round * 2 + packet),
                    1200,
                    round,
                    false,
                );
            }
            estimate.end_acks(round, false);
        }
        assert_eq!(estimate.get_estimate(), 1_200_000);
    }

    #[test]
    fn application_limited_samples_only_raise_the_estimate() {
        let mut estimate = BandwidthEstimation::default();
        let start = Instant::now();
        for round in 0..=2 {
            let sent = start + Duration::from_millis(round);
            estimate.on_sent(sent, 1200);
            estimate.on_ack(sent + Duration::from_millis(100), sent, 1200, round, false);
        }
        for round in 3..=40 {
            let sent = start + Duration::from_millis(2 + (round - 2) * 10);
            estimate.on_sent(sent, 1200);
            estimate.on_ack(sent + Duration::from_millis(100), sent, 1200, round, true);
        }
        assert_eq!(estimate.get_estimate(), 1_200_000);
        for round in 41..=43 {
            let sent = start + Duration::from_micros(382_000 + (round - 40) * 500);
            estimate.on_sent(sent, 1200);
            estimate.on_ack(sent + Duration::from_millis(100), sent, 1200, round, true);
        }
        assert_eq!(estimate.get_estimate(), 2_400_000);
    }

    /// Bytes over a span, at the edges of the range the public configuration accepts.
    #[test]
    fn a_rate_holds_its_units_across_the_range() {
        assert_eq!(
            BandwidthEstimation::bw_from_delta(1200, Duration::from_millis(1)),
            Some(1_200_000),
            "1200 bytes in a millisecond is 1.2 MB/s"
        );
        assert_eq!(
            BandwidthEstimation::bw_from_delta(0, Duration::from_secs(1)),
            Some(0)
        );
        assert_eq!(
            BandwidthEstimation::bw_from_delta(1200, Duration::ZERO),
            None,
            "no time is no rate, not a division"
        );
        assert_eq!(
            BandwidthEstimation::bw_from_delta(u64::MAX, Duration::from_nanos(1)),
            Some(u64::MAX),
            "the largest window over the shortest span saturates rather than wrapping"
        );
        assert_eq!(
            BandwidthEstimation::bw_from_delta(u64::MAX, Duration::from_secs(1)),
            Some(u64::MAX)
        );
        // Exactly 2^64 nanoseconds, the span that a narrowing denominator turns into zero.
        let overflowing_denominator = Duration::new(18_446_744_073, 709_551_616);
        assert_eq!(overflowing_denominator.as_nanos(), 1u128 << 64);
        assert_eq!(
            BandwidthEstimation::bw_from_delta(1200, overflowing_denominator),
            Some(0),
            "a span that does not fit a u64 of nanoseconds is a span, not a division by zero"
        );

        // A span longer than a u64 of nanoseconds: 600 years is about 1.9e19 ns.
        let ancient = Duration::from_secs(600 * 365 * 24 * 60 * 60);
        assert!(ancient.as_nanos() > u128::from(u64::MAX));
        assert_eq!(
            BandwidthEstimation::bw_from_delta(u64::MAX, ancient),
            Some(974_904_028),
            "and the span is used as it is rather than truncated into the rate"
        );
    }
}
