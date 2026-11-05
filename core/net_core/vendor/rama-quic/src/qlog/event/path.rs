//! Network tuple, migration, and recovery configuration event data.

use super::{Initiator, TupleId};
use rama_quic_proto::ConnectionId;
use serde::Serialize;
use std::net::{Ipv4Addr, Ipv6Addr};

#[derive(Clone, Copy, Debug, Serialize)]
#[serde(tag = "name", content = "data")]
/// Network tuple, migration, connection ID, MTU, and recovery configuration observations.
pub enum PathEvent {
    /// A network tuple received its trace identifier.
    #[serde(rename = "quic:tuple_assigned")]
    TupleAssigned(TupleAssigned),

    /// Path probing or migration entered a new state.
    #[serde(rename = "quic:migration_state_updated")]
    MigrationStateUpdated {
        /// Newly entered probing or migration state.
        new: MigrationState,

        /// Identifier of the affected network tuple.
        tuple_id: TupleId,
    },

    /// An endpoint changed its active connection ID.
    #[serde(rename = "quic:connection_id_updated")]
    ConnectionIdUpdated {
        /// Endpoint owning the changed connection ID: local or remote.
        initiator: Initiator,

        /// Previous connection ID, when known.
        #[serde(skip_serializing_if = "Option::is_none")]
        #[serde(serialize_with = "super::serialize_optional_cid")]
        old: Option<ConnectionId>,

        /// New active connection ID.
        #[serde(serialize_with = "super::serialize_cid")]
        new: ConnectionId,
    },

    /// The usable UDP payload size changed.
    #[serde(rename = "quic:mtu_updated")]
    MtuUpdated {
        /// Previous maximum UDP payload size, in bytes.
        old: u16,

        /// New maximum UDP payload size, in bytes.
        new: u16,
    },

    /// Loss detection and congestion-control parameters were established.
    #[serde(rename = "quic:recovery_parameters_set")]
    RecoveryParametersSet {
        /// Acknowledged packet-number gap that triggers packet-threshold loss detection.
        #[serde(skip_serializing_if = "Option::is_none")]
        reordering_threshold: Option<u16>,

        /// Round-trip time multiplier used for time-threshold loss detection.
        /// Non-finite values are omitted.
        #[serde(skip_serializing_if = "non_finite")]
        time_threshold: f32,

        /// Minimum timer resolution, in milliseconds.
        timer_granularity: u16,

        /// Initial round-trip time estimate, in milliseconds.
        /// Non-finite values are omitted.
        #[serde(skip_serializing_if = "non_finite")]
        initial_rtt: f32,

        /// Maximum UDP payload used by recovery calculations, in bytes.
        max_datagram_size: u16,

        /// Initial congestion window, in bytes.
        initial_congestion_window: u64,

        /// Probe-timeout multiplier used to identify persistent congestion.
        #[serde(skip_serializing_if = "Option::is_none")]
        persistent_congestion_threshold: Option<u16>,
    },
}

#[derive(Clone, Copy, Debug, Serialize)]
#[serde(rename_all = "snake_case")]
/// Observed progress of a path probe or migration.
pub enum MigrationState {
    /// Validation of a candidate network tuple began.
    ProbingStarted,

    /// Validation of the candidate network tuple was abandoned.
    ProbingAbandoned,

    /// Validation confirmed the candidate network tuple was usable.
    ProbingSuccessful,

    /// Connection traffic began moving to another network tuple.
    MigrationStarted,

    /// Migration to the candidate network tuple was abandoned.
    MigrationAbandoned,

    /// Migration to the new network tuple completed.
    MigrationComplete,
}

#[derive(Clone, Copy, Debug, Serialize)]
/// A named network tuple and its known endpoints.
pub struct TupleAssigned {
    /// Identifier assigned to this network tuple.
    pub tuple_id: TupleId,

    /// Remote endpoint address, when known.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub tuple_remote: Option<TupleEndpointInfo>,

    /// Local endpoint address, when known.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub tuple_local: Option<TupleEndpointInfo>,
}

#[derive(Clone, Copy, Debug, Serialize)]
#[serde(untagged)]
/// An IPv4 or IPv6 network endpoint.
pub enum TupleEndpointInfo {
    /// An IPv4 endpoint.
    V4 {
        /// IPv4 address.
        ip_v4: Ipv4Addr,

        /// UDP port.
        port_v4: u16,
    },

    /// An IPv6 endpoint.
    V6 {
        /// IPv6 address.
        ip_v6: Ipv6Addr,

        /// UDP port.
        port_v6: u16,
    },
}

#[expect(
    clippy::trivially_copy_pass_by_ref,
    reason = "Serde skip predicates borrow the field"
)]
fn non_finite(value: &f32) -> bool {
    !value.is_finite()
}
