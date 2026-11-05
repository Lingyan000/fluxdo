//! Path observations use only tuples and transitions known to the engine.
use std::net::SocketAddr;

use rama_quic_proto::ConnectionId;

pub(in crate::proto::connection) use crate::qlog::event::path::MigrationState;
use crate::qlog::event::{
    EventFieldsView, EventView, Initiator, TupleId,
    path::{PathEvent, TupleAssigned, TupleEndpointInfo},
};

use crate::proto::{Instant, TIMER_GRANULARITY, connection::Connection};

/// Attach a known path, leaving the default handshake tuple implicit.
pub(in crate::proto::connection) fn with_path<'a>(
    generation: u64,
    event: impl Into<EventView<'a>>,
) -> EventFieldsView<'a> {
    EventFieldsView {
        tuple: (generation != 0).then_some(TupleId::Generation(generation)),
        event: event.into(),
    }
}

impl From<SocketAddr> for TupleEndpointInfo {
    fn from(address: SocketAddr) -> Self {
        match address {
            SocketAddr::V4(address) => Self::V4 {
                ip_v4: *address.ip(),
                port_v4: address.port(),
            },
            SocketAddr::V6(address) => Self::V6 {
                ip_v6: *address.ip(),
                port_v6: address.port(),
            },
        }
    }
}

fn tuple_id(generation: u64) -> TupleId {
    if generation == 0 {
        TupleId::Default
    } else {
        TupleId::Generation(generation)
    }
}

impl Connection {
    pub(in crate::proto::connection) fn qlog_init_recovery(&self, now: Instant) {
        self.qlog_sink
            .emit(self.trace_cid, now, || PathEvent::RecoveryParametersSet {
                reordering_threshold: self.config.packet_threshold.try_into().ok(),
                time_threshold: self.config.time_threshold,
                timer_granularity: TIMER_GRANULARITY.as_millis() as u16,
                initial_rtt: self.config.initial_rtt.as_secs_f32() * 1000.0,
                max_datagram_size: self.path.current_mtu(),
                initial_congestion_window: self.path.congestion.initial_window(),
                persistent_congestion_threshold: self
                    .config
                    .persistent_congestion_threshold
                    .try_into()
                    .ok(),
            });
    }

    pub(in crate::proto::connection) fn qlog_assign_current_tuple(&self, now: Instant) {
        self.qlog_sink.emit(self.trace_cid, now, || {
            PathEvent::TupleAssigned(TupleAssigned {
                tuple_id: tuple_id(self.path.generation()),
                tuple_remote: Some(self.path.remote.into()),
                tuple_local: self.path.local.map(Into::into),
            })
        });
    }

    pub(in crate::proto::connection) fn qlog_migration_state(
        &self,
        now: Instant,
        new: MigrationState,
    ) {
        self.qlog_sink.emit(self.trace_cid, now, || {
            with_path(
                self.path.generation(),
                PathEvent::MigrationStateUpdated {
                    new,
                    tuple_id: tuple_id(self.path.generation()),
                },
            )
        });
    }

    pub(in crate::proto::connection) fn qlog_candidate_state(
        &self,
        now: Instant,
        seq: u64,
        remote: SocketAddr,
        new: MigrationState,
    ) {
        // The reserved CID sequence is unique for each probing attempt. A path generation is
        // assigned only after promotion; the probe tuple remains the history of that attempt.
        self.qlog_sink.emit(self.trace_cid, now, || {
            PathEvent::TupleAssigned(TupleAssigned {
                tuple_id: TupleId::Probe(seq),
                tuple_remote: Some(remote.into()),
                tuple_local: self.path.local.map(Into::into),
            })
        });
        self.qlog_sink
            .emit(self.trace_cid, now, || EventFieldsView {
                tuple: Some(TupleId::Probe(seq)),
                event: PathEvent::MigrationStateUpdated {
                    new,
                    tuple_id: TupleId::Probe(seq),
                }
                .into(),
            });
    }

    pub(in crate::proto::connection) fn qlog_remote_cid_updated(
        &self,
        now: Instant,
        old: ConnectionId,
    ) {
        let new = self.rem_cids.active();
        if old == new {
            return;
        }
        self.qlog_sink
            .emit(self.trace_cid, now, || PathEvent::ConnectionIdUpdated {
                initiator: Initiator::Remote,
                old: Some(old),
                new,
            });
    }

    pub(in crate::proto::connection) fn qlog_local_cid_updated(
        &self,
        now: Instant,
        old: Option<ConnectionId>,
        new: ConnectionId,
    ) {
        if old == Some(new) {
            return;
        }
        self.qlog_sink
            .emit(self.trace_cid, now, || PathEvent::ConnectionIdUpdated {
                initiator: Initiator::Local,
                old,
                new,
            });
    }

    pub(in crate::proto::connection) fn qlog_mtu_updated(&self, now: Instant, old: u16) {
        let new = self.path.current_mtu();
        if old == new {
            return;
        }
        self.qlog_sink.emit(self.trace_cid, now, || {
            with_path(self.path.generation(), PathEvent::MtuUpdated { old, new })
        });
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn path_scoping_keeps_default_tuple_implicit() {
        let default = serde_json::to_value(with_path(
            0,
            PathEvent::MtuUpdated {
                old: 1200,
                new: 1300,
            },
        ))
        .unwrap();
        assert!(default.get("tuple").is_none());
        assert_eq!(default["name"], "quic:mtu_updated");
        assert_eq!(
            default["data"],
            serde_json::json!({"old": 1200, "new": 1300})
        );
        let migrated = serde_json::to_value(with_path(
            7,
            PathEvent::MtuUpdated {
                old: 1300,
                new: 1200,
            },
        ))
        .unwrap();
        assert_eq!(migrated["tuple"], "7");
        assert_eq!(migrated["data"]["new"], 1200);
        assert!(migrated["data"].get("done").is_none());
    }

    #[test]
    fn tuple_and_cid_schema() {
        let event = PathEvent::TupleAssigned(TupleAssigned {
            tuple_id: TupleId::Default,
            tuple_remote: Some(SocketAddr::from((std::net::Ipv6Addr::LOCALHOST, 443)).into()),
            tuple_local: None,
        });
        let value = serde_json::to_value(event).unwrap();
        assert_eq!(value["name"], "quic:tuple_assigned");
        assert_eq!(value["data"]["tuple_id"], "");
        assert_eq!(value["data"]["tuple_remote"]["ip_v6"], "::1");
        assert_eq!(value["data"]["tuple_remote"]["port_v6"], 443);
        assert!(value["data"].get("tuple_local").is_none());
        let value = serde_json::to_value(PathEvent::ConnectionIdUpdated {
            initiator: Initiator::Remote,
            old: Some(ConnectionId::new(&[0xab, 0xcd])),
            new: ConnectionId::new(&[0xef, 0x12]),
        })
        .unwrap();
        assert_eq!(
            value["data"],
            serde_json::json!({"initiator": "remote", "old": "abcd", "new": "ef12"})
        );
    }
}
