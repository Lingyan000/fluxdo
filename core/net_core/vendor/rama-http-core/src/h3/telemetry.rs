//! OpenTelemetry metrics for HTTP/3 connections.

use std::{borrow::Cow, sync::Arc};

use rama_core::telemetry::opentelemetry::{
    InstrumentationScope, KeyValue, MeterOptions, global,
    metrics::{Counter, Meter},
    semantic_conventions,
};

use super::{DatagramDrops, control::Role};

/// Metrics for the HTTP/3 connections of a [`Config`](super::connection::Config) that sets them.
///
/// `h3.datagrams.dropped` {`reason`, `http.h3.side` = `client`, `server`} counts the received
/// HTTP datagrams a connection discarded, recorded once when its driver ends: after its last
/// received datagrams were filed, or when it is dropped. Datagrams still queued then and
/// discarded later, as a request handle that kept them goes, are not counted. Reasons are the
/// fields of [`DatagramDrops`]; a reason with nothing dropped is not recorded.
///
/// Cheap to clone; clones report into the same series.
#[derive(Debug, Clone)]
pub struct H3Metrics {
    inner: Arc<Instruments>,
}

#[derive(Debug)]
struct Instruments {
    base: Box<[KeyValue]>,
    dropped: Counter<u64>,
}

impl H3Metrics {
    /// Metrics recorded with the global meter provider.
    #[must_use]
    pub fn new(options: MeterOptions) -> Self {
        Self::new_with_meter(&versioned_meter(), options)
    }

    /// Metrics recorded with `meter`.
    #[must_use]
    pub fn new_with_meter(meter: &Meter, options: MeterOptions) -> Self {
        let prefix = options.metric_prefix.as_deref();
        let name: Cow<'_, str> = match prefix {
            Some(prefix) => Cow::Owned(format!("{prefix}.h3.datagrams.dropped")),
            None => Cow::Borrowed("h3.datagrams.dropped"),
        };
        Self {
            inner: Arc::new(Instruments {
                dropped: meter
                    .u64_counter(name)
                    .with_unit("{datagram}")
                    .with_description("Received HTTP datagrams a connection discarded, by reason")
                    .build(),
                base: options.attributes.unwrap_or_default().into(),
            }),
        }
    }

    pub(super) fn record(&self, role: Role, drops: DatagramDrops) {
        let DatagramDrops {
            no_semantics,
            invalid_id,
            beyond_limit,
            unknown_stream,
            receive_closed,
            queue_full,
            over_budget,
            expired,
            unadvertised,
        } = drops;
        let side = match role {
            Role::Client => "client",
            Role::Server => "server",
        };
        for (reason, count) in [
            ("no_semantics", no_semantics),
            ("invalid_id", invalid_id),
            ("beyond_limit", beyond_limit),
            ("unknown_stream", unknown_stream),
            ("receive_closed", receive_closed),
            ("queue_full", queue_full),
            ("over_budget", over_budget),
            ("expired", expired),
            ("unadvertised", unadvertised),
        ] {
            if count == 0 {
                continue;
            }
            let mut attributes = Vec::with_capacity(self.inner.base.len() + 2);
            attributes.extend_from_slice(&self.inner.base);
            attributes.push(KeyValue::new("http.h3.side", side));
            attributes.push(KeyValue::new("reason", reason));
            self.inner.dropped.add(count, &attributes);
        }
    }
}

fn versioned_meter() -> Meter {
    global::meter_with_scope(
        InstrumentationScope::builder("rama-http-core-h3")
            .with_version(rama_utils::info::VERSION)
            .with_schema_url(semantic_conventions::SCHEMA_URL)
            .build(),
    )
}
