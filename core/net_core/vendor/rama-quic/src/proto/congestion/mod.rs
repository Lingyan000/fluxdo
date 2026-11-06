//! Logic for controlling the rate at which data is sent

use crate::proto::Instant;
use crate::proto::connection::RttEstimator;
use std::sync::Arc;

mod bbr;
mod cubic;
mod new_reno;

pub(crate) use bbr::BbrConfig;
pub(crate) use cubic::CubicConfig;
pub(crate) use new_reno::NewRenoConfig;

/// Common interface for different congestion controllers
pub(crate) trait Controller: Send + Sync {
    /// One or more packets were just sent
    #[expect(
        unused_variables,
        reason = "default no-op implementation keeps the documented parameter names"
    )]
    fn on_sent(&mut self, now: Instant, bytes: u64, last_packet_number: u64) {}

    /// Packet deliveries were confirmed
    ///
    /// `app_limited` indicates whether the connection was blocked on outgoing
    /// application data prior to receiving these acknowledgements.
    #[expect(
        unused_variables,
        reason = "default no-op implementation keeps the documented parameter names"
    )]
    fn on_ack(
        &mut self,
        now: Instant,
        sent: Instant,
        bytes: u64,
        app_limited: bool,
        rtt: &RttEstimator,
    ) {
    }

    /// Packets are acked in batches, all with the same `now` argument. This indicates one of those batches has completed.
    #[expect(
        unused_variables,
        reason = "default no-op implementation keeps the documented parameter names"
    )]
    fn on_end_acks(
        &mut self,
        now: Instant,
        in_flight: u64,
        app_limited: bool,
        largest_packet_num_acked: Option<u64>,
    ) {
    }

    /// Packets were deemed lost or marked congested
    ///
    /// `in_persistent_congestion` indicates whether all packets sent within the persistent
    /// congestion threshold period ending when the most recent packet in this batch was sent were
    /// lost.
    /// `lost_bytes` indicates how many bytes were lost. This value will be 0 for ECN triggers.
    fn on_congestion_event(
        &mut self,
        now: Instant,
        sent: Instant,
        is_persistent_congestion: bool,
        lost_bytes: u64,
    );

    /// The known MTU for the current network path has been updated
    fn on_mtu_update(&mut self, new_mtu: u16);

    /// Number of ack-eliciting bytes that may be in flight
    fn window(&self) -> u64;

    /// Retrieve implementation-specific metrics used to populate `qlog` traces when they are enabled
    fn metrics(&self) -> ControllerMetrics {
        ControllerMetrics {
            congestion_window: self.window(),
            ssthresh: None,
            pacing_rate: None,
        }
    }

    /// Duplicate the controller's state
    fn clone_box(&self) -> Box<dyn Controller>;

    /// Initial congestion window
    fn initial_window(&self) -> u64;
}

/// Common congestion controller metrics
#[derive(Default)]
#[non_exhaustive]
pub(crate) struct ControllerMetrics {
    /// Congestion window (bytes)
    pub(crate) congestion_window: u64,
    /// Slow start threshold (bytes)
    pub(crate) ssthresh: Option<u64>,
    /// Pacing rate (bits/s)
    pub(crate) pacing_rate: Option<u64>,
}

/// Constructs controllers on demand
pub(crate) trait ControllerFactory {
    /// Construct a fresh `Controller`
    fn build(self: Arc<Self>, now: Instant, current_mtu: u16) -> Box<dyn Controller>;
}

pub(crate) const BASE_DATAGRAM_SIZE: u64 = 1200;

#[cfg(test)]
mod tests {
    use super::*;
    use crate::proto::{CongestionControl, Duration, TransportConfig, connection::RttEstimator};

    /// A window at the top of the range grows no further instead of wrapping, driven through
    /// the sequence a connection uses: sent, acknowledged, end of the acknowledgements.
    #[test]
    fn a_window_at_the_top_of_the_range_saturates() {
        // BBR follows the bandwidth-delay product it measures rather than the configured
        // window, so its arithmetic is checked in its own module.
        for control in [CongestionControl::Cubic, CongestionControl::NewReno] {
            // One below the top, so slow start is the branch that adds to the window.
            let window = u64::MAX - 1;
            let mut controller = controller_with(control, window);
            assert_eq!(
                controller.window(),
                window,
                "{control:?} starts at the top of the range"
            );

            let now = Instant::now();
            let rtt = RttEstimator::new(Duration::from_millis(10));
            for round in 1..=8u64 {
                let sent = now + Duration::from_millis(round * 10);
                let acked = sent + Duration::from_millis(10);
                controller.on_sent(sent, BASE_DATAGRAM_SIZE, round);
                controller.on_ack(acked, sent, BASE_DATAGRAM_SIZE, false, &rtt);
                controller.on_end_acks(acked, BASE_DATAGRAM_SIZE, false, Some(round));
            }

            assert!(
                controller.window() >= window,
                "{control:?} stays at the top rather than wrapping to {}",
                controller.window()
            );
            let metrics = controller.metrics();
            assert_eq!(metrics.congestion_window, controller.window());
            if let Some(rate) = metrics.pacing_rate {
                assert_eq!(
                    rate,
                    u64::MAX,
                    "{control:?} reports the largest rate rather than a wrapped one"
                );
            }
        }
    }

    /// The controller a configuration describes, built for a path of the base datagram size.
    fn controller_with(control: CongestionControl, window: u64) -> Box<dyn Controller> {
        let mut config = TransportConfig::default();
        config.set_congestion_control(control);
        config
            .try_set_initial_congestion_window(window)
            .expect("the window is accepted");
        config
            .congestion_factory()
            .build(Instant::now(), BASE_DATAGRAM_SIZE as u16)
    }
}
