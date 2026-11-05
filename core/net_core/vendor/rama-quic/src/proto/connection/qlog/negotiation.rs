//! Negotiation and traffic-key observations for the QUIC qlog event schema.

use crate::qlog::event::Initiator;
use crate::qlog::event::negotiation::{NegotiationEventView as Event, *};
use rama_quic_proto::{packet::SpaceId, transport_parameters::TransportParameters};
use std::borrow::Cow;

use crate::proto::{Instant, connection::Connection};

fn restored_parameters(params: &TransportParameters) -> RestoredParameters {
    RestoredParameters {
        disable_active_migration: params.disable_active_migration,
        max_idle_timeout: params.max_idle_timeout.into_inner(),
        max_udp_payload_size: params.max_udp_payload_size.into_inner(),
        active_connection_id_limit: params.active_connection_id_limit.into_inner(),
        initial_max_data: params.initial_max_data.into_inner(),
        initial_max_stream_data_bidi_local: params.initial_max_stream_data_bidi_local.into_inner(),
        initial_max_stream_data_bidi_remote: params
            .initial_max_stream_data_bidi_remote
            .into_inner(),
        initial_max_stream_data_uni: params.initial_max_stream_data_uni.into_inner(),
        initial_max_streams_bidi: params.initial_max_streams_bidi.into_inner(),
        initial_max_streams_uni: params.initial_max_streams_uni.into_inner(),
        max_datagram_frame_size: params
            .max_datagram_frame_size
            .map(|value| value.into_inner()),
        grease_quic_bit: params.grease_quic_bit,
    }
}

impl ParametersSet {
    fn new(initiator: Initiator, params: &TransportParameters) -> Self {
        Self {
            initiator,
            parameters: restored_parameters(params),
            ack_delay_exponent: params.ack_delay_exponent.into_inner(),
            max_ack_delay: params.max_ack_delay.into_inner(),
            original_destination_connection_id: params.original_dst_cid,
            initial_source_connection_id: params.initial_src_cid,
            retry_source_connection_id: params.retry_src_cid,
        }
    }
}

impl Connection {
    pub(in crate::proto::connection) fn qlog_init_negotiation(&self, now: Instant) {
        self.qlog_sink.emit(self.trace_cid, now, || {
            let versions = version_list(&self.endpoint_config.supported_versions);
            let (client_versions, server_versions) = if self.side.is_client() {
                (versions, None)
            } else {
                (None, versions)
            };
            Event::VersionInformation(VersionInformationView {
                client_versions,
                server_versions,
                chosen_version: Some(Version(self.version().to_be_bytes())),
            })
        });
        self.qlog_key_change(now, SpaceId::Initial, false, Some(KeyChangeTrigger::Tls));
    }

    pub(in crate::proto::connection) fn qlog_version_negotiated(
        &self,
        now: Instant,
        payload: &[u8],
    ) {
        self.qlog_sink.emit(self.trace_cid, now, || {
            Event::VersionInformation(VersionInformationView {
                client_versions: version_list(&self.endpoint_config.supported_versions),
                server_versions: network_version_list(payload.as_chunks::<4>().0),
                // This connection terminates on Version Negotiation, so no version was selected.
                chosen_version: None,
            })
        });
    }

    pub(crate) fn qlog_local_parameters(&self, now: Instant, params: &TransportParameters) {
        self.qlog_sink.emit(self.trace_cid, now, || {
            Event::ParametersSet(ParametersSet::new(Initiator::Local, params))
        });
    }

    pub(in crate::proto::connection) fn qlog_remote_parameters(
        &self,
        now: Instant,
        params: &TransportParameters,
    ) {
        self.qlog_sink.emit(self.trace_cid, now, || {
            Event::ParametersSet(ParametersSet::new(Initiator::Remote, params))
        });
    }

    pub(in crate::proto::connection) fn qlog_restored_parameters(
        &self,
        now: Instant,
        params: &TransportParameters,
    ) {
        self.qlog_sink.emit(self.trace_cid, now, || {
            Event::ParametersRestored(restored_parameters(params))
        });
    }

    pub(in crate::proto::connection) fn qlog_negotiated_alpn(&self, now: Instant) {
        if !self.qlog_sink.is_enabled() {
            return;
        }
        if let Some(protocol) = self.crypto.negotiated_alpn() {
            self.qlog_sink
                .emit(self.trace_cid, now, || Event::AlpnInformation {
                    chosen_alpn: AlpnIdentifierView {
                        byte_value: HexView(Cow::Borrowed(protocol)),
                    },
                });
        }
    }

    pub(in crate::proto::connection) fn qlog_key_change(
        &self,
        now: Instant,
        space: SpaceId,
        discarded: bool,
        trigger: Option<KeyChangeTrigger>,
    ) {
        for client in [true, false] {
            self.qlog_directional_key_change(now, space, client, discarded, trigger);
        }
    }

    pub(in crate::proto::connection) fn qlog_directional_key_change(
        &self,
        now: Instant,
        space: SpaceId,
        client: bool,
        discarded: bool,
        trigger: Option<KeyChangeTrigger>,
    ) {
        let key_type = match (space, client) {
            (SpaceId::Initial, true) => KeyType::ClientInitialSecret,
            (SpaceId::Initial, false) => KeyType::ServerInitialSecret,
            (SpaceId::Handshake, true) => KeyType::ClientHandshakeSecret,
            (SpaceId::Handshake, false) => KeyType::ServerHandshakeSecret,
            (SpaceId::Data, true) => KeyType::ClientOneRttSecret,
            (SpaceId::Data, false) => KeyType::ServerOneRttSecret,
        };
        self.qlog_key(
            now,
            KeyChange {
                key_type,
                key_phase: (space == SpaceId::Data).then_some(self.stats.key_updates),
                trigger,
            },
            discarded,
        );
    }

    pub(in crate::proto::connection) fn qlog_zero_rtt_key(&self, now: Instant, discarded: bool) {
        // 0-RTT traffic flows only from client to server, even on the server's trace.
        self.qlog_key(
            now,
            KeyChange {
                key_type: KeyType::ClientZeroRttSecret,
                key_phase: None,
                trigger: Some(KeyChangeTrigger::Tls),
            },
            discarded,
        );
    }

    pub(in crate::proto::connection) fn qlog_discard_retired_keys(&mut self, now: Instant) {
        if self.zero_rtt_crypto.take().is_some() {
            self.qlog_zero_rtt_key(now, true);
        }
        self.qlog_discard_previous_keys(now);
    }

    pub(in crate::proto::connection) fn qlog_discard_previous_keys(&mut self, now: Instant) {
        if self.prev_crypto.take().is_some() {
            for key_type in [KeyType::ClientOneRttSecret, KeyType::ServerOneRttSecret] {
                self.qlog_key(
                    now,
                    KeyChange {
                        key_type,
                        key_phase: Some(self.stats.key_updates.saturating_sub(1)),
                        trigger: None,
                    },
                    true,
                );
            }
        }
    }

    fn qlog_key(&self, now: Instant, change: KeyChange, discarded: bool) {
        self.qlog_sink.emit(self.trace_cid, now, || {
            if discarded {
                Event::KeyDiscarded(change)
            } else {
                Event::KeyUpdated(change)
            }
        });
    }
}

fn version_list(versions: &[rama_quic_proto::Version]) -> Option<VersionListView<'_>> {
    (!versions.is_empty()).then_some(VersionListView::Host(Cow::Borrowed(versions)))
}

fn network_version_list(versions: &[[u8; 4]]) -> Option<VersionListView<'_>> {
    (!versions.is_empty()).then_some(VersionListView::Network(Cow::Borrowed(versions)))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn empty_version_lists_are_omitted() {
        let event = Event::VersionInformation(VersionInformationView {
            client_versions: version_list(&[
                rama_quic_proto::Version::V1,
                rama_quic_proto::Version::V2,
            ]),
            server_versions: version_list(&[]),
            chosen_version: None,
        });
        assert_eq!(
            serde_json::to_value(event).unwrap(),
            serde_json::json!({
                "name": "quic:version_information",
                "data": { "client_versions": ["00000001", "6b3343cf"] }
            })
        );
    }
}
