use std::time::Duration;

pub(super) mod drops;
pub(super) mod event;
pub(super) mod lifecycle;
pub(super) mod negotiation;
pub(super) mod path;
use crate::proto::{
    Instant,
    connection::{PathData, SentPacket},
};
use crate::qlog::{ConnectionQlogControl, QlogRecorder, event::EventFieldsView};
use event::{Event, Packet, PacketHeader, PacketLost, PacketLostTrigger, PacketType, RawInfo};
use rama_quic_proto::{ConnectionId, packet::SpaceId};

/// Per-connection admission. The configuration's template is forked for each connection.
#[derive(Clone, Default)]
pub(crate) struct ConnectionQlog {
    control: Option<ConnectionQlogControl>,
}

impl ConnectionQlog {
    pub(crate) fn from_sink(sink: Option<std::sync::Arc<dyn crate::qlog::QlogSink>>) -> Self {
        Self {
            control: sink
                .map(|sink| ConnectionQlogControl::from_sink(sink, ConnectionId::new(&[]))),
        }
    }

    pub(crate) fn for_connection(&self, group: ConnectionId) -> Self {
        Self {
            control: self
                .control
                .as_ref()
                .map(|control| control.for_connection(group)),
        }
    }

    pub(crate) fn control(&self) -> Option<ConnectionQlogControl> {
        self.control.clone()
    }

    /// Reserve queue capacity before capturing any diagnostic data.
    pub(crate) fn emit<'a, E: Into<EventFieldsView<'a>>>(
        &self,
        group: ConnectionId,
        now: Instant,
        event: impl FnOnce() -> E,
    ) -> bool {
        self.control
            .as_ref()
            .is_some_and(|control| control.emit(group, now, || Some(event())))
    }

    pub(crate) fn is_enabled(&self) -> bool {
        self.control
            .as_ref()
            .is_some_and(ConnectionQlogControl::is_enabled)
    }

    pub(super) fn emit_recovery_metrics(
        &self,
        pto_count: u32,
        path: &mut PathData,
        now: Instant,
        group: ConnectionId,
    ) {
        let mut changed = false;
        if let Some(control) = &self.control
            && !control.emit(group, now, || {
                path.qlog_reset_on_toggle(control.generation());
                path.qlog_recovery_metrics(pto_count).map(|metrics| {
                    changed = true;
                    path::with_path(path.generation(), Event::RecoveryMetricsUpdated(metrics))
                })
            })
            && changed
        {
            path.qlog_reset_metrics();
        }
    }

    pub(super) fn emit_packet_lost(
        &self,
        pn: u64,
        info: &SentPacket,
        loss_delay: Duration,
        space: SpaceId,
        now: Instant,
        group: ConnectionId,
    ) {
        self.emit(group, now, || {
            Event::PacketLost(PacketLost {
                header: PacketHeader {
                    packet_number: pn,
                    packet_type: packet_type(space, info.is_0rtt),
                },
                is_mtu_probe_packet: info.is_mtu_probe_packet,
                trigger: if now.saturating_duration_since(info.time_sent) >= loss_delay {
                    PacketLostTrigger::TimeThreshold
                } else {
                    PacketLostTrigger::ReorderingThreshold
                },
            })
        });
    }

    pub(super) fn emit_packet_sent(
        &self,
        pn: u64,
        len: usize,
        space: SpaceId,
        is_0rtt: bool,
        is_mtu_probe_packet: bool,
        now: Instant,
        group: ConnectionId,
    ) {
        self.emit(group, now, || {
            Event::PacketSent(Packet {
                header: PacketHeader {
                    packet_number: pn,
                    packet_type: packet_type(space, is_0rtt),
                },
                raw: Some(RawInfo { length: len }),
                is_mtu_probe_packet: Some(is_mtu_probe_packet),
            })
        });
    }

    pub(super) fn emit_packet_received(
        &self,
        pn: u64,
        len: Option<usize>,
        space: SpaceId,
        is_0rtt: bool,
        now: Instant,
        group: ConnectionId,
    ) {
        self.emit(group, now, || {
            Event::PacketReceived(Packet {
                header: PacketHeader {
                    packet_number: pn,
                    packet_type: packet_type(space, is_0rtt),
                },
                raw: len.map(|length| RawInfo { length }),
                is_mtu_probe_packet: None,
            })
        });
    }
}

impl From<Option<QlogRecorder>> for ConnectionQlog {
    fn from(recorder: Option<QlogRecorder>) -> Self {
        Self {
            control: recorder.map(|recorder| recorder.connection(ConnectionId::new(&[]))),
        }
    }
}

fn packet_type(space: SpaceId, is_0rtt: bool) -> PacketType {
    match space {
        SpaceId::Initial => PacketType::Initial,
        SpaceId::Handshake => PacketType::Handshake,
        SpaceId::Data if is_0rtt => PacketType::ZeroRtt,
        SpaceId::Data => PacketType::OneRtt,
    }
}

#[cfg(test)]
mod tests;
