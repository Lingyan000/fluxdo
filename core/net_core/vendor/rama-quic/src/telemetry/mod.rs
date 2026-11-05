//! OpenTelemetry metrics for endpoints and the connections they carry.
//!
//! Nothing is recorded unless an endpoint is built with
//! [`EndpointBuilder::with_metrics`](crate::EndpointBuilder::with_metrics).
//!
//! A connection is recorded once, at its first terminal outcome: its duration runs from
//! creation to that outcome, and its UDP totals are the ones it had then, so traffic of a
//! closing or draining period that follows is not counted. Connection series carry `quic.side`
//! (`client`, `server`) and `quic.version` (`1`, `2`, `other`); ended connections also carry
//! `quic.close.reason` and `quic.handshake.completed`:
//!
//! - `quic.connection.duration` and `quic.connection.closed`;
//! - `quic.connection.handshake.duration`, recorded when the handshake completes;
//! - `quic.connection.bytes` {`direction` = `sent`, `received`}: UDP payload bytes;
//! - `quic.connection.lost_packets`: packets declared lost on the connection's last path;
//! - `quic.connection.datagrams.gated` {`direction`}: datagrams the datagram gates dropped.
//!
//! Endpoint counters are read on collection and summed over every endpoint built with the same
//! [`QuicMetrics`] (or a clone of it), dropped endpoints included, so a total never falls. Two
//! separately created [`QuicMetrics`] report the same series unless their
//! [`MeterOptions`] attributes tell them apart. Exported endpoint counters:
//!
//! - `quic.endpoint.handshakes` {`outcome` = `accepted`, `outgoing`, `refused`, `ignored`}:
//!   `refused` and `ignored` are attempts the application refused or ignored;
//! - `quic.endpoint.handshakes.expired`: attempts that expired before the application took them;
//! - `quic.endpoint.admission.refused` {`reason` = `at_limit`, `per_source`, `unvalidated`}
//!   and `quic.endpoint.admission.retried`: attempts the endpoint refused or answered with a
//!   Retry under load, before the application saw them;
//! - `quic.endpoint.datagrams.received`, and `quic.endpoint.datagrams.dropped` for those a
//!   saturated receive queue dropped;
//! - `quic.endpoint.receive.truncated_entries`: receive entries discarded whole for a truncated
//!   datagram (entries, not datagrams);
//! - `quic.endpoint.receive.errors_ignored`: receive errors ignored as injectable noise;
//! - `quic.endpoint.responses.dropped` {`reason` = `queue_full`, `send_failed`}: stateless
//!   responses that never left.
//!
//! Occupancy (attempts in progress, queue use, retained sockets) is not exported; it is in
//! [`Endpoint::stats`](crate::Endpoint::stats).

use std::{
    borrow::Cow,
    sync::{Arc, Weak},
    time::Instant,
};

use parking_lot::Mutex;
use rama_core::telemetry::opentelemetry::{
    InstrumentationScope, KeyValue, MeterOptions, global,
    metrics::{AsyncInstrument, Counter, Histogram, Meter},
    semantic_conventions,
};
use rama_quic_proto::Version;

use crate::{ConnectionError, ConnectionStats};

#[cfg(test)]
mod tests;

const DURATION_BOUNDS: &[f64] = &[
    0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1.0, 2.5, 5.0, 10.0, 30.0, 60.0, 300.0, 900.0, 3600.0,
];
const HANDSHAKE_BOUNDS: &[f64] = &[
    0.001, 0.0025, 0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1.0, 2.5, 5.0, 10.0,
];

/// Metrics shared by the endpoints built with it, and by their connections.
///
/// Cheap to clone; clones report into the same series.
#[derive(Debug, Clone)]
pub struct QuicMetrics {
    inner: Arc<Instruments>,
}

#[derive(Debug)]
struct Instruments {
    base: Box<[KeyValue]>,
    duration: Histogram<f64>,
    handshake: Histogram<f64>,
    closed: Counter<u64>,
    bytes: Counter<u64>,
    lost_packets: Counter<u64>,
    gated_datagrams: Counter<u64>,
    endpoints: Arc<Registry>,
}

impl QuicMetrics {
    /// Metrics recorded with the global meter provider.
    #[must_use]
    pub fn new(options: MeterOptions) -> Self {
        Self::new_with_meter(&versioned_meter(), options)
    }

    /// Metrics recorded with `meter`.
    #[must_use]
    pub fn new_with_meter(meter: &Meter, options: MeterOptions) -> Self {
        let base: Box<[KeyValue]> = options.attributes.unwrap_or_default().into();
        let prefix = options.metric_prefix.as_deref();
        let endpoints = Arc::new(Registry::default());
        observe_endpoints(meter, prefix, &base, &endpoints);
        Self {
            inner: Arc::new(Instruments {
                duration: meter
                    .f64_histogram(name(prefix, "quic.connection.duration"))
                    .with_unit("s")
                    .with_boundaries(DURATION_BOUNDS.to_vec())
                    .with_description("Time from a connection's creation to its terminal outcome")
                    .build(),
                handshake: meter
                    .f64_histogram(name(prefix, "quic.connection.handshake.duration"))
                    .with_unit("s")
                    .with_boundaries(HANDSHAKE_BOUNDS.to_vec())
                    .with_description("Time from a connection's creation to its handshake")
                    .build(),
                closed: meter
                    .u64_counter(name(prefix, "quic.connection.closed"))
                    .with_unit("{connection}")
                    .with_description("Connections ended, by reason")
                    .build(),
                bytes: meter
                    .u64_counter(name(prefix, "quic.connection.bytes"))
                    .with_unit("By")
                    .with_description("UDP payload bytes of ended connections")
                    .build(),
                lost_packets: meter
                    .u64_counter(name(prefix, "quic.connection.lost_packets"))
                    .with_unit("{packet}")
                    .with_description("Packets ended connections declared lost on their last path")
                    .build(),
                gated_datagrams: meter
                    .u64_counter(name(prefix, "quic.connection.datagrams.gated"))
                    .with_unit("{datagram}")
                    .with_description("Datagrams the connection's datagram gates dropped")
                    .build(),
                base,
                endpoints,
            }),
        }
    }

    /// Count `endpoint` in the endpoint series until its slot is dropped. Never call this with
    /// the endpoint's lock held: collection takes the registry before the endpoint.
    pub(crate) fn register(&self, endpoint: Weak<dyn CountedEndpoint>) -> EndpointSlot {
        self.inner.endpoints.register(endpoint)
    }

    /// A record for a connection created now.
    pub(crate) fn connection(&self) -> ConnectionMetrics {
        ConnectionMetrics {
            metrics: self.clone(),
            started: crate::driver::now(),
        }
    }

    fn attributes(&self, server: bool, version: Version, extra: usize) -> Vec<KeyValue> {
        let mut attributes = Vec::with_capacity(self.inner.base.len() + 2 + extra);
        attributes.extend_from_slice(&self.inner.base);
        attributes.push(KeyValue::new(
            "quic.side",
            if server { "server" } else { "client" },
        ));
        attributes.push(KeyValue::new("quic.version", version_name(version)));
        attributes
    }
}

fn versioned_meter() -> Meter {
    global::meter_with_scope(
        InstrumentationScope::builder("rama-quic")
            .with_version(rama_utils::info::VERSION)
            .with_schema_url(semantic_conventions::SCHEMA_URL)
            .build(),
    )
}

fn name<'a>(prefix: Option<&str>, name: &'a str) -> Cow<'a, str> {
    match prefix {
        Some(prefix) => Cow::Owned(format!("{prefix}.{name}")),
        None => Cow::Borrowed(name),
    }
}

/// Bounded: a version outside the two standard ones is `other`.
fn version_name(version: Version) -> &'static str {
    match version {
        Version::V1 => "1",
        Version::V2 => "2",
        _ => "other",
    }
}

fn reason_name(reason: Option<&ConnectionError>) -> &'static str {
    match reason {
        Some(ConnectionError::LocallyClosed) => "local_close",
        Some(ConnectionError::ApplicationClosed(_)) => "application_close",
        Some(ConnectionError::ConnectionClosed(_)) => "transport_close",
        Some(ConnectionError::TransportError(_)) => "transport_error",
        Some(ConnectionError::Reset) => "reset",
        Some(ConnectionError::TimedOut) => "timeout",
        Some(ConnectionError::VersionMismatch { .. }) => "version_mismatch",
        Some(ConnectionError::CidsExhausted) => "cids_exhausted",
        Some(ConnectionError::EndpointInUse) => "endpoint_in_use",
        None => "dropped",
    }
}

/// One connection's record, finished once: finishing consumes it.
#[derive(Debug)]
pub(crate) struct ConnectionMetrics {
    metrics: QuicMetrics,
    started: Instant,
}

impl ConnectionMetrics {
    pub(crate) fn connected(&self, server: bool, version: Version) {
        self.metrics.inner.handshake.record(
            seconds(self.started),
            &self.metrics.attributes(server, version, 0),
        );
    }

    /// Record the connection as it is at its terminal outcome.
    pub(crate) fn finish(
        self,
        server: bool,
        version: Version,
        reason: Option<&ConnectionError>,
        connected: bool,
        stats: &ConnectionStats,
    ) {
        let metrics = self.metrics;
        let instruments = &metrics.inner;
        let mut attributes = metrics.attributes(server, version, 2);
        attributes.push(KeyValue::new("quic.close.reason", reason_name(reason)));
        attributes.push(KeyValue::new("quic.handshake.completed", connected));
        instruments
            .duration
            .record(seconds(self.started), &attributes);
        instruments.closed.add(1, &attributes);

        let mut attributes = metrics.attributes(server, version, 1);
        instruments
            .lost_packets
            .add(stats.path.lost_packets, &attributes);
        attributes.push(KeyValue::new("direction", "sent"));
        instruments.bytes.add(stats.udp_tx.bytes, &attributes);
        instruments
            .gated_datagrams
            .add(stats.gated_datagrams.sent, &attributes);
        if let Some(direction) = attributes.last_mut() {
            *direction = KeyValue::new("direction", "received");
        }
        instruments.bytes.add(stats.udp_rx.bytes, &attributes);
        instruments
            .gated_datagrams
            .add(stats.gated_datagrams.received, &attributes);
    }
}

fn seconds(since: Instant) -> f64 {
    crate::driver::now()
        .saturating_duration_since(since)
        .as_secs_f64()
}

macro_rules! endpoint_counters {
    ($($field:ident),+ $(,)?) => {
        /// The cumulative counters of one endpoint that are exported.
        #[derive(Debug, Default, Clone, Copy, PartialEq, Eq)]
        pub(crate) struct EndpointCounters {
            $(pub(crate) $field: u64,)+
        }

        impl EndpointCounters {
            /// Field by field, so a total built from what was last seen never falls.
            fn max(self, other: Self) -> Self {
                Self { $($field: self.$field.max(other.$field),)+ }
            }

            fn add(&mut self, other: Self) {
                $(self.$field = self.$field.saturating_add(other.$field);)+
            }
        }
    };
}

endpoint_counters! {
    accepted,
    outgoing,
    refused,
    ignored,
    expired,
    refused_at_limit,
    refused_per_source,
    refused_unvalidated,
    retried,
    received,
    dropped,
    truncated_entries,
    errors_ignored,
    responses_queue_full,
    responses_send_failed,
}

/// An endpoint whose counters can be read.
pub(crate) trait CountedEndpoint: Send + Sync {
    fn counters(&self) -> EndpointCounters;
}

#[derive(Default)]
struct Registry {
    state: Mutex<RegistryState>,
}

impl std::fmt::Debug for Registry {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("Registry").finish_non_exhaustive()
    }
}

#[derive(Default)]
struct RegistryState {
    /// What endpoints whose slots are gone had counted when they went.
    retired: EndpointCounters,
    live: Vec<Arc<Mutex<Entry>>>,
}

struct Entry {
    endpoint: Weak<dyn CountedEndpoint>,
    /// The largest counters seen: an endpoint that cannot be reached any more, but has not
    /// handed in its last counters yet, still counts what it was seen to count.
    seen: EndpointCounters,
}

impl Registry {
    fn register(self: &Arc<Self>, endpoint: Weak<dyn CountedEndpoint>) -> EndpointSlot {
        let entry = Arc::new(Mutex::new(Entry {
            endpoint,
            seen: EndpointCounters::default(),
        }));
        self.state.lock().live.push(entry.clone());
        EndpointSlot {
            registry: self.clone(),
            entry,
        }
    }

    fn collect(&self) -> EndpointCounters {
        // Reached endpoints are released after the registry: the last one dropped retires its
        // slot, which takes the registry.
        let mut reached = Vec::new();
        let state = self.state.lock();
        let mut total = state.retired;
        for entry in &state.live {
            let mut entry = entry.lock();
            if let Some(endpoint) = entry.endpoint.upgrade() {
                entry.seen = entry.seen.max(endpoint.counters());
                reached.push(endpoint);
            }
            total.add(entry.seen);
        }
        drop(state);
        drop(reached);
        total
    }
}

/// An endpoint's place in the endpoint series; dropping it retires the endpoint with the
/// counters it last handed in, whether or not anything collects. Never drop it with the
/// endpoint's lock held: collection takes the registry before the endpoint.
pub(crate) struct EndpointSlot {
    registry: Arc<Registry>,
    entry: Arc<Mutex<Entry>>,
}

impl std::fmt::Debug for EndpointSlot {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("EndpointSlot").finish_non_exhaustive()
    }
}

impl EndpointSlot {
    pub(crate) fn hand_in(&self, counters: EndpointCounters) {
        let mut entry = self.entry.lock();
        entry.seen = entry.seen.max(counters);
    }
}

impl Drop for EndpointSlot {
    fn drop(&mut self) {
        let mut state = self.registry.state.lock();
        if let Some(at) = state
            .live
            .iter()
            .position(|entry| Arc::ptr_eq(entry, &self.entry))
        {
            state.live.swap_remove(at);
        }
        let seen = self.entry.lock().seen;
        state.retired.add(seen);
    }
}

/// One callback per instrument, each reading the registry's total.
fn observe_endpoints(
    meter: &Meter,
    prefix: Option<&str>,
    base: &[KeyValue],
    registry: &Arc<Registry>,
) {
    let with = |key: &'static str, value: &'static str| {
        let mut attributes = base.to_vec();
        attributes.push(KeyValue::new(key, value));
        attributes
    };
    let series = |instrument: &'static str,
                  unit: &'static str,
                  description: &'static str,
                  read: Vec<(Vec<KeyValue>, fn(&EndpointCounters) -> u64)>| {
        let registry = registry.clone();
        let _observed = meter
            .u64_observable_counter(name(prefix, instrument))
            .with_unit(unit)
            .with_description(description)
            .with_callback(move |observer: &dyn AsyncInstrument<u64>| {
                let total = registry.collect();
                for (attributes, read) in &read {
                    observer.observe(read(&total), attributes);
                }
            })
            .build();
    };
    series(
        "quic.endpoint.handshakes",
        "{handshake}",
        "Handshakes the endpoint accepted, started, or the application refused or ignored",
        vec![
            (with("outcome", "accepted"), |c| c.accepted),
            (with("outcome", "outgoing"), |c| c.outgoing),
            (with("outcome", "refused"), |c| c.refused),
            (with("outcome", "ignored"), |c| c.ignored),
        ],
    );
    series(
        "quic.endpoint.handshakes.expired",
        "{handshake}",
        "Attempts that expired before the application took them",
        vec![(base.to_vec(), |c| c.expired)],
    );
    series(
        "quic.endpoint.admission.refused",
        "{handshake}",
        "Attempts the endpoint refused under load before the application saw them",
        vec![
            (with("reason", "at_limit"), |c| c.refused_at_limit),
            (with("reason", "per_source"), |c| c.refused_per_source),
            (with("reason", "unvalidated"), |c| c.refused_unvalidated),
        ],
    );
    series(
        "quic.endpoint.admission.retried",
        "{handshake}",
        "Unvalidated attempts answered with a Retry under load",
        vec![(base.to_vec(), |c| c.retried)],
    );
    series(
        "quic.endpoint.datagrams.received",
        "{datagram}",
        "UDP datagrams passed to the protocol engine",
        vec![(base.to_vec(), |c| c.received)],
    );
    series(
        "quic.endpoint.datagrams.dropped",
        "{datagram}",
        "Received datagrams dropped because a receive queue was saturated",
        vec![(base.to_vec(), |c| c.dropped)],
    );
    series(
        "quic.endpoint.receive.truncated_entries",
        "{entry}",
        "Receive entries discarded whole because a datagram in them was truncated",
        vec![(base.to_vec(), |c| c.truncated_entries)],
    );
    series(
        "quic.endpoint.receive.errors_ignored",
        "{error}",
        "Receive errors ignored as injectable noise",
        vec![(base.to_vec(), |c| c.errors_ignored)],
    );
    series(
        "quic.endpoint.responses.dropped",
        "{response}",
        "Stateless responses that never left the endpoint",
        vec![
            (with("reason", "queue_full"), |c| c.responses_queue_full),
            (with("reason", "send_failed"), |c| c.responses_send_failed),
        ],
    );
}
