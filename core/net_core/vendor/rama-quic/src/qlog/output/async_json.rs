//! Async JSON text-sequence encoding for the typed QUIC schema.
//!
//! Serde handles bounded scalar formatting; strings, binary fields, lists, and objects stream
//! directly to AsyncWrite. Keep this traversal in parity with the schema's Serialize mapping.

use super::{NamedQlogEventView, TraceInfo};
use crate::qlog::schema;
use crate::qlog::{
    QlogEventView,
    event::{
        EventView, LifecycleEventView, NegotiationEventView, PacketEvent, PathEvent,
        drops::DropEvent,
        lifecycle::{ReasonView, TupleEndpointInfo as ConnectionEndpoint},
        negotiation::{RestoredParameters, Version, VersionListView},
        packet::{PacketHeader, RawInfo},
        path::TupleEndpointInfo as PathEndpoint,
    },
};
use rama_utils::str::utf8::{self, DecodeError, REPLACEMENT_CHARACTER};
use serde::Serialize;
use std::{
    io,
    pin::Pin,
    task::{Context, Poll},
};
use tokio::io::{AsyncWrite, AsyncWriteExt};

/// Direct async qlog JSON text-sequence output without whole-event byte buffers.
/// Cancellation or an I/O error may leave a partial record; do not retry it on the same stream.
/// At most eight consecutive `Interrupted` writes are retried before returning an error retaining the original source.
/// Writers must report backpressure with `Pending` and arrange a wakeup; `WouldBlock` is an error.
#[derive(Debug, Default)]
pub struct AsyncJsonSeqEncoder;

macro_rules! fields {
    ($object:ident, $value:ident; $($field:ident),* $(,)?) => {$ (
        $object.scalar(stringify!($field), &$value.$field).await?;
    )*};
}
macro_rules! optional_fields {
    ($object:ident, $value:ident; $($field:ident),* $(,)?) => {$ (
        if let Some(value) = &$value.$field { $object.scalar(stringify!($field), value).await?; }
    )*};
}

impl super::QlogEncoder for AsyncJsonSeqEncoder {
    async fn begin<W: AsyncWrite + Unpin + Send>(
        &mut self,
        info: &TraceInfo,
        output: &mut W,
    ) -> io::Result<()> {
        let mut retrying = RetryInterrupted::new(output);
        let output = &mut retrying;
        output.write_all(&[schema::RECORD_SEPARATOR]).await?;
        let mut object = Object::new(output).await?;
        object
            .text("file_schema", schema::FILE_SCHEMA_SEQUENTIAL)
            .await?;
        object
            .text(
                "serialization_format",
                schema::SERIALIZATION_FORMAT_JSON_SEQ,
            )
            .await?;
        metadata(&mut object, info).await?;
        object.key("trace").await?;
        let mut trace = Object::new(object.output).await?;
        metadata(&mut trace, info).await?;
        trace.key("vantage_point").await?;
        trace.output.write_all(b"{\"type\":\"unknown\"}").await?;
        trace.key("event_schemas").await?;
        trace.output.write_all(b"[").await?;
        string(trace.output, schema::EVENT_SCHEMA_QUIC).await?;
        for event_schema in info.event_schemas {
            trace.output.write_all(b",").await?;
            string(trace.output, event_schema.id()).await?;
        }
        trace.output.write_all(b"]").await?;
        trace.key("common_fields").await?;
        trace.output.write_all(b"{\"time_format\":\"relative_to_epoch\",\"reference_time\":{\"clock_type\":\"monotonic\",\"epoch\":\"unknown\"}}").await?;
        trace.end().await?;
        object.end().await?;
        output.write_all(b"\n").await
    }

    async fn named_event<W: AsyncWrite + Unpin + Send>(
        &mut self,
        info: &TraceInfo,
        event: &NamedQlogEventView<'_>,
        output: &mut W,
    ) -> io::Result<()> {
        let mut retrying = RetryInterrupted::new(output);
        let output = &mut retrying;
        output.write_all(&[schema::RECORD_SEPARATOR]).await?;
        let mut object = Object::new(output).await?;
        let time = event
            .time()
            .saturating_duration_since(info.start_time)
            .as_secs_f64()
            * 1000.0;
        object.scalar("time", &time).await?;
        object.hex("group_id", &event.group_id()).await?;
        object.text("name", event.name()).await?;
        object.key("data").await?;
        object.output.write_all(event.data()).await?;
        object.end().await?;
        output.write_all(b"\n").await
    }

    async fn event<W: AsyncWrite + Unpin + Send>(
        &mut self,
        info: &TraceInfo,
        event: &QlogEventView<'_>,
        output: &mut W,
    ) -> io::Result<()> {
        let mut retrying = RetryInterrupted::new(output);
        let output = &mut retrying;
        output.write_all(&[schema::RECORD_SEPARATOR]).await?;
        let mut object = Object::new(output).await?;
        let time = event
            .time
            .saturating_duration_since(info.start_time)
            .as_secs_f64()
            * 1000.0;
        object.scalar("time", &time).await?;
        object.hex("group_id", &event.group_id).await?;
        if let Some(tuple) = &event.fields.tuple {
            object.scalar("tuple", tuple).await?;
        }
        object.text("name", event_name(&event.fields.event)).await?;
        object.key("data").await?;
        data(object.output, &event.fields.event).await?;
        object.end().await?;
        output.write_all(b"\n").await
    }

    async fn finish<W: AsyncWrite + Unpin + Send>(&mut self, _output: &mut W) -> io::Result<()> {
        Ok(())
    }
}

/// Bound interruptions before Tokio's write_all can retry them indefinitely.
/// Retry only the current write, leaving write_all's byte offset intact. Count interruptions
/// until a successful write, including across Pending, to bound self-wakes without progress.
pub(in crate::qlog) struct RetryInterrupted<W> {
    writer: W,
    interruptions: u8,
}

impl<W> RetryInterrupted<W> {
    const MAX_RETRIES: u8 = 8;

    pub(in crate::qlog) fn new(writer: W) -> Self {
        Self {
            writer,
            interruptions: 0,
        }
    }
}

/// Marks an exhausted retry budget so an adapter outside a buffer propagates the error
/// immediately. Keep the original error, including its source, intact inside this marker.
#[derive(Debug)]
struct RetryExhausted(io::Error);

impl std::fmt::Display for RetryExhausted {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        self.0.fmt(formatter)
    }
}

impl std::error::Error for RetryExhausted {
    fn source(&self) -> Option<&(dyn std::error::Error + 'static)> {
        Some(&self.0)
    }
}

impl<W> RetryInterrupted<W> {
    fn retry<T>(&mut self, cx: &Context<'_>, result: Poll<io::Result<T>>) -> Poll<io::Result<T>> {
        match result {
            Poll::Ready(Err(error)) if error.kind() == io::ErrorKind::Interrupted => {
                if self.interruptions < Self::MAX_RETRIES {
                    self.interruptions += 1;
                    cx.waker().wake_by_ref();
                    Poll::Pending
                } else {
                    // Interrupted would make write_all retry beyond our budget.
                    Poll::Ready(Err(io::Error::other(RetryExhausted(error))))
                }
            }
            Poll::Ready(Ok(value)) => {
                self.interruptions = 0;
                Poll::Ready(Ok(value))
            }
            result => result,
        }
    }
}

impl<W: AsyncWrite + Unpin> AsyncWrite for RetryInterrupted<W> {
    fn poll_write(
        mut self: Pin<&mut Self>,
        cx: &mut Context<'_>,
        bytes: &[u8],
    ) -> Poll<io::Result<usize>> {
        let result = Pin::new(&mut self.writer).poll_write(cx, bytes);
        self.retry(cx, result)
    }

    fn poll_flush(mut self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<io::Result<()>> {
        let result = Pin::new(&mut self.writer).poll_flush(cx);
        self.retry(cx, result)
    }

    fn poll_shutdown(mut self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<io::Result<()>> {
        let result = Pin::new(&mut self.writer).poll_shutdown(cx);
        self.retry(cx, result)
    }
}

async fn metadata<W: AsyncWrite + Unpin + Send>(
    object: &mut Object<'_, W>,
    info: &TraceInfo,
) -> io::Result<()> {
    if let Some(value) = &info.title {
        object.text("title", value).await?;
    }
    if let Some(value) = &info.description {
        object.text("description", value).await?;
    }
    Ok(())
}

fn event_name(event: &EventView<'_>) -> &'static str {
    match event {
        EventView::Packet(event) => match event {
            PacketEvent::PacketSent(_) => "quic:packet_sent",
            PacketEvent::PacketReceived(_) => "quic:packet_received",
            PacketEvent::PacketLost(_) => "quic:packet_lost",
            PacketEvent::RecoveryMetricsUpdated(_) => "quic:recovery_metrics_updated",
        },
        EventView::Negotiation(event) => match event {
            NegotiationEventView::VersionInformation(_) => "quic:version_information",
            NegotiationEventView::AlpnInformation { .. } => "quic:alpn_information",
            NegotiationEventView::ParametersSet(_) => "quic:parameters_set",
            NegotiationEventView::ParametersRestored(_) => "quic:parameters_restored",
            NegotiationEventView::KeyUpdated(_) => "quic:key_updated",
            NegotiationEventView::KeyDiscarded(_) => "quic:key_discarded",
        },
        EventView::Lifecycle(event) => match event {
            LifecycleEventView::Started { .. } => "quic:connection_started",
            LifecycleEventView::StateUpdated { .. } => "quic:connection_state_updated",
            LifecycleEventView::Closed(_) => "quic:connection_closed",
        },
        EventView::Path(event) => match event {
            PathEvent::TupleAssigned(_) => "quic:tuple_assigned",
            PathEvent::MigrationStateUpdated { .. } => "quic:migration_state_updated",
            PathEvent::ConnectionIdUpdated { .. } => "quic:connection_id_updated",
            PathEvent::MtuUpdated { .. } => "quic:mtu_updated",
            PathEvent::RecoveryParametersSet { .. } => "quic:recovery_parameters_set",
        },
        EventView::Drop(DropEvent::PacketDropped(_)) => "quic:packet_dropped",
        EventView::Drop(DropEvent::PacketBuffered(_)) => "quic:packet_buffered",
    }
}

async fn data<W: AsyncWrite + Unpin + Send>(
    output: &mut W,
    event: &EventView<'_>,
) -> io::Result<()> {
    let mut object = Object::new(output).await?;
    match event {
        EventView::Packet(event) => match event {
            PacketEvent::PacketSent(packet) | PacketEvent::PacketReceived(packet) => {
                object.key("header").await?;
                packet_header(object.output, &packet.header).await?;
                if let Some(raw) = &packet.raw {
                    object.key("raw").await?;
                    raw_info(object.output, raw).await?;
                }
                optional_fields!(object, packet; is_mtu_probe_packet);
            }
            PacketEvent::PacketLost(packet) => {
                object.key("header").await?;
                packet_header(object.output, &packet.header).await?;
                fields!(object, packet; is_mtu_probe_packet, trigger);
            }
            PacketEvent::RecoveryMetricsUpdated(metrics) => {
                for (name, value) in [
                    ("min_rtt", metrics.min_rtt),
                    ("smoothed_rtt", metrics.smoothed_rtt),
                    ("latest_rtt", metrics.latest_rtt),
                    ("rtt_variance", metrics.rtt_variance),
                ] {
                    if let Some(value) = value.filter(|value| value.is_finite()) {
                        object.scalar(name, &value).await?;
                    }
                }
                optional_fields!(object, metrics;
                    pto_count, congestion_window, bytes_in_flight, ssthresh, pacing_rate);
            }
        },
        EventView::Negotiation(event) => match event {
            NegotiationEventView::VersionInformation(info) => {
                if let Some(versions) = &info.server_versions {
                    object.key("server_versions").await?;
                    version_list(object.output, versions).await?;
                }
                if let Some(versions) = &info.client_versions {
                    object.key("client_versions").await?;
                    version_list(object.output, versions).await?;
                }
                optional_fields!(object, info; chosen_version);
            }
            NegotiationEventView::AlpnInformation { chosen_alpn } => {
                object.key("chosen_alpn").await?;
                let mut alpn = Object::new(object.output).await?;
                alpn.hex("byte_value", &chosen_alpn.byte_value.0).await?;
                alpn.end().await?;
            }
            NegotiationEventView::ParametersSet(params) => {
                object.scalar("initiator", &params.initiator).await?;
                restored_parameters(&mut object, &params.parameters).await?;
                fields!(object, params; ack_delay_exponent, max_ack_delay);
                if let Some(cid) = &params.original_destination_connection_id {
                    object
                        .hex("original_destination_connection_id", cid)
                        .await?;
                }
                if let Some(cid) = &params.initial_source_connection_id {
                    object.hex("initial_source_connection_id", cid).await?;
                }
                if let Some(cid) = &params.retry_source_connection_id {
                    object.hex("retry_source_connection_id", cid).await?;
                }
            }
            NegotiationEventView::ParametersRestored(params) => {
                restored_parameters(&mut object, params).await?
            }
            NegotiationEventView::KeyUpdated(key) | NegotiationEventView::KeyDiscarded(key) => {
                object.scalar("key_type", &key.key_type).await?;
                optional_fields!(object, key; key_phase);
                if let Some(trigger) = key.trigger {
                    object.scalar("trigger", &trigger).await?;
                }
            }
        },
        EventView::Lifecycle(event) => match event {
            LifecycleEventView::Started { local, remote } => {
                object.key("local").await?;
                connection_endpoint(object.output, local).await?;
                object.key("remote").await?;
                connection_endpoint(object.output, remote).await?;
            }
            LifecycleEventView::StateUpdated { old, new } => {
                if let Some(value) = old {
                    object.scalar("old", value).await?;
                }
                object.scalar("new", new).await?;
            }
            LifecycleEventView::Closed(closed) => {
                optional_fields!(object, closed; initiator, trigger);
                optional_fields!(object, closed; connection_error);
                if let Some(value) = closed.application_error {
                    object.text("application_error", value).await?;
                }
                optional_fields!(object, closed; error_code);
                if let Some(value) = &closed.reason {
                    object.key("reason").await?;
                    #[expect(
                        clippy::match_same_arms,
                        reason = "static and borrowed reason bindings have different lifetimes and cannot share an or-pattern"
                    )]
                    match value {
                        ReasonView::Static(value) => string(object.output, value).await?,
                        ReasonView::Text(value) => string(object.output, value).await?,
                        ReasonView::Owned(value) => string(object.output, value).await?,
                        ReasonView::Bytes(value) => lossy_string(object.output, value).await?,
                    }
                }
            }
        },
        EventView::Path(event) => match event {
            PathEvent::TupleAssigned(tuple) => {
                fields!(object, tuple; tuple_id);
                if let Some(value) = &tuple.tuple_remote {
                    object.key("tuple_remote").await?;
                    path_endpoint(object.output, value).await?;
                }
                if let Some(value) = &tuple.tuple_local {
                    object.key("tuple_local").await?;
                    path_endpoint(object.output, value).await?;
                }
            }
            PathEvent::MigrationStateUpdated { new, tuple_id } => {
                object.scalar("new", new).await?;
                object.scalar("tuple_id", tuple_id).await?;
            }
            PathEvent::ConnectionIdUpdated {
                initiator,
                old,
                new,
            } => {
                object.scalar("initiator", initiator).await?;
                if let Some(value) = old {
                    object.hex("old", value).await?;
                }
                object.hex("new", new).await?;
            }
            PathEvent::MtuUpdated { old, new } => {
                object.scalar("old", old).await?;
                object.scalar("new", new).await?;
            }
            PathEvent::RecoveryParametersSet {
                reordering_threshold,
                time_threshold,
                timer_granularity,
                initial_rtt,
                max_datagram_size,
                initial_congestion_window,
                persistent_congestion_threshold,
            } => {
                if let Some(value) = reordering_threshold {
                    object.scalar("reordering_threshold", value).await?;
                }
                if time_threshold.is_finite() {
                    object.scalar("time_threshold", time_threshold).await?;
                }
                object
                    .scalar("timer_granularity", timer_granularity)
                    .await?;
                if initial_rtt.is_finite() {
                    object.scalar("initial_rtt", initial_rtt).await?;
                }
                object
                    .scalar("max_datagram_size", max_datagram_size)
                    .await?;
                object
                    .scalar("initial_congestion_window", initial_congestion_window)
                    .await?;
                if let Some(value) = persistent_congestion_threshold {
                    object
                        .scalar("persistent_congestion_threshold", value)
                        .await?;
                }
            }
        },
        EventView::Drop(DropEvent::PacketDropped(packet)) => {
            if let Some(header) = &packet.header {
                object.key("header").await?;
                let mut nested = Object::new(object.output).await?;
                nested.scalar("packet_type", &header.packet_type).await?;
                optional_fields!(nested, header; packet_number);
                nested.end().await?;
            }
            if let Some(raw) = &packet.raw {
                object.key("raw").await?;
                raw_info(object.output, raw).await?;
            }
            fields!(object, packet; trigger);
        }
        EventView::Drop(DropEvent::PacketBuffered(packet)) => {
            if let Some(header) = &packet.header {
                object.key("header").await?;
                let mut nested = Object::new(object.output).await?;
                nested.scalar("packet_type", &header.packet_type).await?;
                optional_fields!(nested, header; packet_number);
                nested.end().await?;
            }
            if let Some(raw) = &packet.raw {
                object.key("raw").await?;
                raw_info(object.output, raw).await?;
            }
            fields!(object, packet; trigger);
        }
    }
    object.end().await
}

async fn packet_header<W: AsyncWrite + Unpin + Send>(
    output: &mut W,
    header: &PacketHeader,
) -> io::Result<()> {
    let mut object = Object::new(output).await?;
    fields!(object, header; packet_type, packet_number);
    object.end().await
}

async fn raw_info<W: AsyncWrite + Unpin + Send>(output: &mut W, raw: &RawInfo) -> io::Result<()> {
    let mut object = Object::new(output).await?;
    fields!(object, raw; length);
    object.end().await
}

async fn restored_parameters<W: AsyncWrite + Unpin + Send>(
    object: &mut Object<'_, W>,
    params: &RestoredParameters,
) -> io::Result<()> {
    fields!(object, params; disable_active_migration, max_idle_timeout, max_udp_payload_size, active_connection_id_limit,
        initial_max_data, initial_max_stream_data_bidi_local, initial_max_stream_data_bidi_remote,
        initial_max_stream_data_uni, initial_max_streams_bidi, initial_max_streams_uni);
    optional_fields!(object, params; max_datagram_frame_size);
    fields!(object, params; grease_quic_bit);
    Ok(())
}

async fn connection_endpoint<W: AsyncWrite + Unpin + Send>(
    output: &mut W,
    endpoint: &ConnectionEndpoint,
) -> io::Result<()> {
    let mut object = Object::new(output).await?;
    optional_fields!(object, endpoint; ip_v4, port_v4, ip_v6, port_v6);
    object.key("connection_ids").await?;
    object.output.write_all(b"[").await?;
    for (index, cid) in endpoint.connection_ids.iter().enumerate() {
        if index != 0 {
            object.output.write_all(b",").await?;
        }
        hex(object.output, cid).await?;
    }
    object.output.write_all(b"]").await?;
    object.end().await
}

async fn path_endpoint<W: AsyncWrite + Unpin + Send>(
    output: &mut W,
    endpoint: &PathEndpoint,
) -> io::Result<()> {
    let mut object = Object::new(output).await?;
    match endpoint {
        PathEndpoint::V4 { ip_v4, port_v4 } => {
            object.scalar("ip_v4", ip_v4).await?;
            object.scalar("port_v4", port_v4).await?;
        }
        PathEndpoint::V6 { ip_v6, port_v6 } => {
            object.scalar("ip_v6", ip_v6).await?;
            object.scalar("port_v6", port_v6).await?;
        }
    }
    object.end().await
}

async fn version_list<W: AsyncWrite + Unpin + Send>(
    output: &mut W,
    versions: &VersionListView<'_>,
) -> io::Result<()> {
    output.write_all(b"[").await?;
    match versions {
        VersionListView::Host(values) => {
            for (index, value) in values.iter().enumerate() {
                if index != 0 {
                    output.write_all(b",").await?;
                }
                scalar(output, &Version(value.to_be_bytes())).await?;
            }
        }
        VersionListView::Network(values) => {
            for (index, value) in values.iter().enumerate() {
                if index != 0 {
                    output.write_all(b",").await?;
                }
                scalar(output, &Version(*value)).await?;
            }
        }
    }
    output.write_all(b"]").await
}

struct Object<'a, W> {
    output: &'a mut W,
    first: bool,
}

impl<'a, W: AsyncWrite + Unpin + Send> Object<'a, W> {
    async fn new(output: &'a mut W) -> io::Result<Self> {
        output.write_all(b"{").await?;
        Ok(Self {
            output,
            first: true,
        })
    }

    async fn key(&mut self, key: &'static str) -> io::Result<()> {
        if !self.first {
            self.output.write_all(b",").await?;
        }
        self.first = false;
        self.output.write_all(b"\"").await?;
        self.output.write_all(key.as_bytes()).await?;
        self.output.write_all(b"\":").await
    }

    async fn scalar<T: Serialize + Sync>(
        &mut self,
        key: &'static str,
        value: &T,
    ) -> io::Result<()> {
        self.key(key).await?;
        scalar(self.output, value).await
    }

    async fn text(&mut self, key: &'static str, value: &str) -> io::Result<()> {
        self.key(key).await?;
        string(self.output, value).await
    }

    async fn hex(&mut self, key: &'static str, value: &[u8]) -> io::Result<()> {
        self.key(key).await?;
        hex(self.output, value).await
    }

    async fn end(self) -> io::Result<()> {
        self.output.write_all(b"}").await
    }
}

/// Only bounded numbers, enums, addresses and tuple IDs reach this helper.
async fn scalar<W: AsyncWrite + Unpin + Send, T: Serialize + Sync>(
    output: &mut W,
    value: &T,
) -> io::Result<()> {
    let mut storage = [0u8; 128];
    let mut unused = storage.as_mut_slice();
    serde_json::to_writer(&mut unused, value).map_err(io::Error::from)?;
    let length = 128 - unused.len();
    output.write_all(&storage[..length]).await
}

async fn hex<W: AsyncWrite + Unpin + Send>(output: &mut W, bytes: &[u8]) -> io::Result<()> {
    output.write_all(b"\"").await?;
    let mut storage = [0u8; 64];
    for chunk in bytes.chunks(storage.len() / 2) {
        let encoded = rama_utils::fmt::hex(chunk)
            .encode_to_slice(&mut storage)
            .map_err(io::Error::other)?;
        output.write_all(encoded).await?;
    }
    output.write_all(b"\"").await
}

async fn string<W: AsyncWrite + Unpin + Send>(output: &mut W, text: &str) -> io::Result<()> {
    output.write_all(b"\"").await?;
    string_contents(output, text).await?;
    output.write_all(b"\"").await
}

async fn string_contents<W: AsyncWrite + Unpin + Send>(
    output: &mut W,
    mut text: &str,
) -> io::Result<()> {
    if !text
        .bytes()
        .any(|byte| byte < 32 || byte == b'"' || byte == b'\\')
    {
        return output.write_all(text.as_bytes()).await;
    }
    // Reuse Serde escaping on bounded UTF-8 fragments while retaining
    // the surrounding JSON string. Six is the maximum expansion of one control byte.
    const SCRATCH: usize = rama_utils::octets::kib(1);
    let mut storage = [0u8; SCRATCH];
    while !text.is_empty() {
        let end = text.floor_char_boundary((SCRATCH - 2) / 6);
        let (fragment, remaining) = text.split_at(end);
        let mut unused = storage.as_mut_slice();
        serde_json::to_writer(&mut unused, fragment).map_err(io::Error::from)?;
        let length = SCRATCH - unused.len();
        output.write_all(&storage[1..length - 1]).await?;
        text = remaining;
    }
    Ok(())
}

async fn lossy_string<W: AsyncWrite + Unpin + Send>(
    output: &mut W,
    mut bytes: &[u8],
) -> io::Result<()> {
    output.write_all(b"\"").await?;
    loop {
        match utf8::decode(bytes) {
            Ok(valid) => {
                string_contents(output, valid).await?;
                break;
            }
            Err(DecodeError::Invalid {
                valid_prefix,
                remaining_input,
                ..
            }) => {
                string_contents(output, valid_prefix).await?;
                output.write_all(REPLACEMENT_CHARACTER.as_bytes()).await?;
                bytes = remaining_input;
            }
            Err(DecodeError::Incomplete { valid_prefix, .. }) => {
                string_contents(output, valid_prefix).await?;
                output.write_all(REPLACEMENT_CHARACTER.as_bytes()).await?;
                break;
            }
        }
    }
    output.write_all(b"\"").await
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::qlog::output::reference::ReferenceJsonEncoder;
    use crate::qlog::{
        QlogEncoder,
        event::{
            EventFields, EventFieldsView, Initiator, TupleId,
            drops::{
                BufferReason, DropHeader, DropPacketType, DropReason, PacketBuffered, PacketDropped,
            },
            lifecycle::{
                ConnectionClosedTrigger, ConnectionClosedView, ConnectionState, TransportErrorName,
            },
            negotiation::{
                AlpnIdentifierView, HexView, KeyChange, KeyChangeTrigger, KeyType, ParametersSet,
                VersionInformationView,
            },
            packet::{Packet, PacketLost, PacketLostTrigger, PacketType, RecoveryMetricsUpdated},
            path::{MigrationState, TupleAssigned},
        },
    };
    use rama_quic_proto::ConnectionId;
    use std::{
        borrow::Cow,
        net::{Ipv4Addr, Ipv6Addr},
        pin::Pin,
        task::{Context, Poll},
        time::{Duration, Instant},
    };

    #[derive(Default)]
    struct StutteringWriter {
        bytes: Vec<u8>,
        pending: bool,
        interrupt: bool,
        interrupted: bool,
        interruptions: usize,
        writes: usize,
        fail_after: Option<usize>,
        zero: bool,
    }

    impl AsyncWrite for StutteringWriter {
        fn poll_write(
            mut self: Pin<&mut Self>,
            cx: &mut Context<'_>,
            bytes: &[u8],
        ) -> Poll<io::Result<usize>> {
            if self.pending {
                self.pending = false;
                cx.waker().wake_by_ref();
                return Poll::Pending;
            }
            if self.interrupt && !self.interrupted {
                self.interrupted = true;
                self.interruptions += 1;
                return Poll::Ready(Err(io::Error::from(io::ErrorKind::Interrupted)));
            }
            self.interrupted = false;
            self.pending = true;
            self.writes += 1;
            if self.fail_after == Some(self.bytes.len()) {
                return Poll::Ready(Err(io::Error::other("output failed")));
            }
            if self.zero {
                return Poll::Ready(Ok(0));
            }
            let mut count = bytes.len().min(3);
            if let Some(limit) = self.fail_after {
                count = count.min(limit.saturating_sub(self.bytes.len()));
            }
            self.bytes.extend_from_slice(&bytes[..count]);
            Poll::Ready(Ok(count))
        }

        fn poll_flush(self: Pin<&mut Self>, _cx: &mut Context<'_>) -> Poll<io::Result<()>> {
            Poll::Ready(Ok(()))
        }

        fn poll_shutdown(self: Pin<&mut Self>, _cx: &mut Context<'_>) -> Poll<io::Result<()>> {
            Poll::Ready(Ok(()))
        }
    }

    fn params() -> RestoredParameters {
        RestoredParameters {
            disable_active_migration: true,
            max_idle_timeout: u64::MAX,
            max_udp_payload_size: 65_527,
            active_connection_id_limit: 4,
            initial_max_data: 123,
            initial_max_stream_data_bidi_local: 456,
            initial_max_stream_data_bidi_remote: 789,
            initial_max_stream_data_uni: 321,
            initial_max_streams_bidi: 42,
            initial_max_streams_uni: 17,
            max_datagram_frame_size: Some(1200),
            grease_quic_bit: true,
        }
    }

    fn samples() -> Vec<EventFields> {
        let header = PacketHeader {
            packet_type: PacketType::OneRtt,
            packet_number: u64::MAX,
        };
        let cid = ConnectionId::new(&[0x00, 0xab, 0xff]);
        let endpoint = ConnectionEndpoint {
            ip_v4: Some(Ipv4Addr::LOCALHOST),
            port_v4: Some(443),
            ip_v6: Some(Ipv6Addr::LOCALHOST),
            port_v6: Some(80),
            connection_ids: [cid],
        };
        let key = KeyChange {
            key_type: KeyType::ClientOneRttSecret,
            key_phase: Some(u64::MAX),
            trigger: Some(KeyChangeTrigger::Tls),
        };
        let mut events: Vec<EventFields> = vec![
            PacketEvent::PacketSent(Packet {
                header,
                raw: Some(RawInfo { length: usize::MAX }),
                is_mtu_probe_packet: Some(true),
            })
            .into(),
            PacketEvent::PacketReceived(Packet {
                header,
                raw: None,
                is_mtu_probe_packet: None,
            })
            .into(),
            PacketEvent::PacketLost(PacketLost {
                header,
                is_mtu_probe_packet: true,
                trigger: PacketLostTrigger::TimeThreshold,
            })
            .into(),
            PacketEvent::RecoveryMetricsUpdated(RecoveryMetricsUpdated {
                min_rtt: Some(-0.0),
                smoothed_rtt: Some(0.12345),
                latest_rtt: Some(f32::MAX),
                rtt_variance: Some(f32::NAN),
                pto_count: Some(u16::MAX),
                congestion_window: Some(u64::MAX),
                bytes_in_flight: Some(3),
                ssthresh: Some(4),
                pacing_rate: Some(5),
            })
            .into(),
            PacketEvent::RecoveryMetricsUpdated(RecoveryMetricsUpdated::default()).into(),
            PacketEvent::RecoveryMetricsUpdated(RecoveryMetricsUpdated {
                min_rtt: Some(f32::NAN),
                smoothed_rtt: Some(f32::NEG_INFINITY),
                latest_rtt: Some(f32::INFINITY),
                rtt_variance: Some(0.0),
                ..Default::default()
            })
            .into(),
            NegotiationEventView::VersionInformation(VersionInformationView {
                server_versions: Some(VersionListView::Network(Cow::Owned(vec![
                    [0, 0, 0, 1],
                    [0xff; 4],
                ]))),
                client_versions: Some(VersionListView::Host(Cow::Owned(vec![
                    rama_quic_proto::Version::V1,
                    rama_quic_proto::Version::V2,
                ]))),
                chosen_version: Some(Version([0, 0, 0, 1])),
            })
            .into(),
            NegotiationEventView::VersionInformation(VersionInformationView {
                server_versions: None,
                client_versions: None,
                chosen_version: None,
            })
            .into(),
            NegotiationEventView::AlpnInformation {
                chosen_alpn: AlpnIdentifierView {
                    byte_value: HexView(Cow::Owned((0..=255).collect())),
                },
            }
            .into(),
            NegotiationEventView::ParametersSet(ParametersSet {
                initiator: Initiator::Remote,
                parameters: params(),
                ack_delay_exponent: 3,
                max_ack_delay: u64::MAX,
                original_destination_connection_id: Some(cid),
                initial_source_connection_id: Some(cid),
                retry_source_connection_id: Some(ConnectionId::new(&[])),
            })
            .into(),
            NegotiationEventView::ParametersRestored(params()).into(),
            NegotiationEventView::KeyUpdated(key).into(),
            NegotiationEventView::KeyDiscarded(KeyChange {
                key_type: KeyType::ServerInitialSecret,
                key_phase: None,
                trigger: None,
            })
            .into(),
            LifecycleEventView::Started {
                local: endpoint,
                remote: endpoint,
            }
            .into(),
            LifecycleEventView::StateUpdated {
                old: Some(ConnectionState::Attempted),
                new: ConnectionState::HandshakeStarted,
            }
            .into(),
            LifecycleEventView::StateUpdated {
                old: None,
                new: ConnectionState::Closed,
            }
            .into(),
            LifecycleEventView::Closed(ConnectionClosedView {
                initiator: Some(Initiator::Local),
                trigger: Some(ConnectionClosedTrigger::Application),
                connection_error: Some(TransportErrorName::Crypto(255)),
                application_error: Some("unknown"),
                error_code: Some(u64::MAX),
                reason: Some(ReasonView::Static("\0\n\t\\\"😀")),
            })
            .into(),
            LifecycleEventView::Closed(ConnectionClosedView::default()).into(),
            PathEvent::TupleAssigned(TupleAssigned {
                tuple_id: TupleId::Default,
                tuple_remote: Some(PathEndpoint::V4 {
                    ip_v4: Ipv4Addr::LOCALHOST,
                    port_v4: 443,
                }),
                tuple_local: Some(PathEndpoint::V6 {
                    ip_v6: Ipv6Addr::LOCALHOST,
                    port_v6: 80,
                }),
            })
            .into(),
            PathEvent::TupleAssigned(TupleAssigned {
                tuple_id: TupleId::Probe(u64::MAX),
                tuple_remote: None,
                tuple_local: None,
            })
            .into(),
            PathEvent::MigrationStateUpdated {
                new: MigrationState::MigrationComplete,
                tuple_id: TupleId::Generation(u64::MAX),
            }
            .into(),
            PathEvent::ConnectionIdUpdated {
                initiator: Initiator::Local,
                old: Some(cid),
                new: cid,
            }
            .into(),
            PathEvent::ConnectionIdUpdated {
                initiator: Initiator::Remote,
                old: None,
                new: cid,
            }
            .into(),
            PathEvent::MtuUpdated {
                old: 1200,
                new: 1500,
            }
            .into(),
            PathEvent::RecoveryParametersSet {
                reordering_threshold: Some(u16::MAX),
                time_threshold: 1.125,
                timer_granularity: 1,
                initial_rtt: f32::MAX,
                max_datagram_size: u16::MAX,
                initial_congestion_window: u64::MAX,
                persistent_congestion_threshold: Some(u16::MAX),
            }
            .into(),
            PathEvent::RecoveryParametersSet {
                reordering_threshold: None,
                time_threshold: f32::NEG_INFINITY,
                timer_granularity: 0,
                initial_rtt: f32::INFINITY,
                max_datagram_size: 1200,
                initial_congestion_window: 0,
                persistent_congestion_threshold: None,
            }
            .into(),
            DropEvent::PacketDropped(PacketDropped {
                header: Some(DropHeader {
                    packet_type: DropPacketType::VersionNegotiation,
                    packet_number: Some(u64::MAX),
                }),
                raw: Some(RawInfo { length: usize::MAX }),
                trigger: DropReason::DecryptionFailure,
            })
            .into(),
            DropEvent::PacketDropped(PacketDropped {
                header: None,
                raw: None,
                trigger: DropReason::Invalid,
            })
            .into(),
            DropEvent::PacketBuffered(PacketBuffered {
                header: Some(DropHeader {
                    packet_type: DropPacketType::Handshake,
                    packet_number: None,
                }),
                raw: Some(RawInfo { length: 1200 }),
                trigger: BufferReason::KeysUnavailable,
            })
            .into(),
            DropEvent::PacketBuffered(PacketBuffered {
                header: None,
                raw: None,
                trigger: BufferReason::KeysUnavailable,
            })
            .into(),
        ];
        let mut without_datagrams = params();
        without_datagrams.max_datagram_frame_size = None;
        events.push(NegotiationEventView::ParametersRestored(without_datagrams).into());
        events.push(
            NegotiationEventView::ParametersSet(ParametersSet {
                initiator: Initiator::Local,
                parameters: without_datagrams,
                ack_delay_exponent: 0,
                max_ack_delay: 0,
                original_destination_connection_id: None,
                initial_source_connection_id: None,
                retry_source_connection_id: None,
            })
            .into(),
        );
        events.push(
            NegotiationEventView::VersionInformation(VersionInformationView {
                server_versions: Some(VersionListView::Network(Cow::Borrowed(&[]))),
                client_versions: Some(VersionListView::Host(Cow::Borrowed(&[]))),
                chosen_version: None,
            })
            .into(),
        );
        events.push(
            DropEvent::PacketDropped(PacketDropped {
                header: Some(DropHeader {
                    packet_type: DropPacketType::Initial,
                    packet_number: None,
                }),
                raw: None,
                trigger: DropReason::KeyUnavailable,
            })
            .into(),
        );
        events.push(
            PacketEvent::PacketSent(Packet {
                header,
                raw: None,
                is_mtu_probe_packet: Some(false),
            })
            .into(),
        );
        for trigger in [
            ConnectionClosedTrigger::IdleTimeout,
            ConnectionClosedTrigger::Application,
            ConnectionClosedTrigger::Error,
            ConnectionClosedTrigger::VersionMismatch,
            ConnectionClosedTrigger::StatelessReset,
            ConnectionClosedTrigger::Aborted,
            ConnectionClosedTrigger::Unspecified,
        ] {
            events.push(
                LifecycleEventView::Closed(ConnectionClosedView {
                    initiator: Some(Initiator::Remote),
                    trigger: Some(trigger),
                    ..Default::default()
                })
                .into(),
            );
        }
        for key_type in [
            KeyType::ServerInitialSecret,
            KeyType::ClientInitialSecret,
            KeyType::ServerHandshakeSecret,
            KeyType::ClientHandshakeSecret,
            KeyType::ServerZeroRttSecret,
            KeyType::ClientZeroRttSecret,
            KeyType::ServerOneRttSecret,
            KeyType::ClientOneRttSecret,
        ] {
            for trigger in [
                None,
                Some(KeyChangeTrigger::Tls),
                Some(KeyChangeTrigger::RemoteUpdate),
                Some(KeyChangeTrigger::LocalUpdate),
            ] {
                events.push(
                    NegotiationEventView::KeyUpdated(KeyChange {
                        key_type,
                        key_phase: None,
                        trigger,
                    })
                    .into(),
                );
            }
        }
        for packet_type in [
            DropPacketType::Initial,
            DropPacketType::Handshake,
            DropPacketType::ZeroRtt,
            DropPacketType::OneRtt,
            DropPacketType::Retry,
            DropPacketType::VersionNegotiation,
            DropPacketType::StatelessReset,
            DropPacketType::Unknown,
        ] {
            events.push(
                DropEvent::PacketDropped(PacketDropped {
                    header: Some(DropHeader {
                        packet_type,
                        packet_number: None,
                    }),
                    raw: None,
                    trigger: DropReason::Invalid,
                })
                .into(),
            );
        }
        for (index, fields) in events.iter_mut().enumerate() {
            if index % 2 == 0 {
                fields.tuple = Some(TupleId::Probe(index as u64));
            }
        }
        events
    }

    // Keep this exhaustive match beside the fixtures: every new schema variant needs an
    // oracle case, even if production serialization was already updated to handle it.
    fn fixture_variant(event: &EventView<'_>) -> usize {
        match event {
            EventView::Packet(event) => match event {
                PacketEvent::PacketSent(_) => 0,
                PacketEvent::PacketReceived(_) => 1,
                PacketEvent::PacketLost(_) => 2,
                PacketEvent::RecoveryMetricsUpdated(_) => 3,
            },
            EventView::Negotiation(event) => match event {
                NegotiationEventView::VersionInformation(_) => 4,
                NegotiationEventView::AlpnInformation { .. } => 5,
                NegotiationEventView::ParametersSet(_) => 6,
                NegotiationEventView::ParametersRestored(_) => 7,
                NegotiationEventView::KeyUpdated(_) => 8,
                NegotiationEventView::KeyDiscarded(_) => 9,
            },
            EventView::Lifecycle(event) => match event {
                LifecycleEventView::Started { .. } => 10,
                LifecycleEventView::StateUpdated { .. } => 11,
                LifecycleEventView::Closed(_) => 12,
            },
            EventView::Path(event) => match event {
                PathEvent::TupleAssigned(_) => 13,
                PathEvent::MigrationStateUpdated { .. } => 14,
                PathEvent::ConnectionIdUpdated { .. } => 15,
                PathEvent::MtuUpdated { .. } => 16,
                PathEvent::RecoveryParametersSet { .. } => 17,
            },
            EventView::Drop(DropEvent::PacketDropped(_)) => 18,
            EventView::Drop(DropEvent::PacketBuffered(_)) => 19,
        }
    }

    async fn parity(info: &TraceInfo, event: &QlogEventView<'_>) {
        let mut expected = Vec::new();
        ReferenceJsonEncoder::event(info, event, &mut expected).unwrap();
        let mut actual = StutteringWriter::default();
        AsyncJsonSeqEncoder
            .event(info, event, &mut actual)
            .await
            .unwrap();
        assert!(actual.writes > 1);
        assert_eq!(actual.bytes, expected, "event {:?}", event.fields.event);
    }

    #[tokio::test]
    async fn every_schema_variant_matches_serde_through_pending_and_short_writes() {
        let now = Instant::now();
        let info = TraceInfo {
            event_schemas: &[],
            title: None,
            description: None,
            start_time: now + Duration::from_secs(1),
        };
        let mut covered = [false; 20];
        for fields in samples() {
            covered[fixture_variant(&fields.event)] = true;
            let event = QlogEventView {
                group_id: ConnectionId::new(&[0; 20]),
                time: now,
                fields,
            };
            parity(&info, &event).await;
        }
        assert!(covered.into_iter().all(|covered| covered));
    }

    #[tokio::test]
    async fn metadata_empty_and_escaped_strings_match_serde() {
        for title in [
            None,
            Some(rama_utils::str::arcstr::arcstr!("static trace")),
            Some(String::new().into()),
            Some("\0\x08\x0c\n\r\t\\\"😀".repeat(257).into()),
        ] {
            let info = TraceInfo {
                event_schemas: &[],
                description: title.clone(),
                title,
                start_time: Instant::now(),
            };
            let mut expected = Vec::new();
            ReferenceJsonEncoder::begin(&info, &mut expected).unwrap();
            let mut actual = StutteringWriter::default();
            AsyncJsonSeqEncoder.begin(&info, &mut actual).await.unwrap();
            let before_finish = actual.bytes.len();
            AsyncJsonSeqEncoder.finish(&mut actual).await.unwrap();
            assert_eq!(actual.bytes.len(), before_finish);
            assert_eq!(actual.bytes, expected);
        }
    }

    #[tokio::test]
    async fn worst_case_and_homogeneous_escaping_match_serde() {
        // NUL expands sixfold; quote-only and backslash-only strings must still select
        // escaping even when no ordinary character is present to influence the fast path.
        for character in ['\0', '"', '\\'] {
            let text = character.to_string().repeat(rama_utils::octets::kib(2) + 1);
            let info = TraceInfo {
                event_schemas: &[],
                title: Some(text.clone().into()),
                description: None,
                start_time: Instant::now(),
            };

            let mut expected = Vec::new();
            ReferenceJsonEncoder::begin(&info, &mut expected).unwrap();
            let mut actual = StutteringWriter::default();
            AsyncJsonSeqEncoder.begin(&info, &mut actual).await.unwrap();

            assert_eq!(actual.bytes, expected);

            for reason in [
                ReasonView::Text(&text),
                ReasonView::Bytes(Cow::Borrowed(text.as_bytes())),
            ] {
                let fields = LifecycleEventView::Closed(ConnectionClosedView {
                    reason: Some(reason),
                    ..Default::default()
                })
                .into();

                parity(
                    &info,
                    &QlogEventView {
                        group_id: ConnectionId::new(&[]),
                        time: info.start_time,
                        fields,
                    },
                )
                .await;
            }
        }
    }

    #[tokio::test]
    async fn borrowed_hex_and_lossy_text_cross_scratch_boundaries() {
        let info = TraceInfo {
            event_schemas: &[],
            title: None,
            description: None,
            start_time: Instant::now(),
        };
        let bytes: Vec<u8> = (0..=255).cycle().take(1025).collect();
        let text = "string with UTF-8 😀 and escaping \"\\\n".repeat(97);
        for length in [0, 1, 31, 32, 33, 127, 128, 129, 1025] {
            let fields: EventFieldsView<'_> = NegotiationEventView::AlpnInformation {
                chosen_alpn: AlpnIdentifierView {
                    byte_value: HexView(Cow::Borrowed(&bytes[..length])),
                },
            }
            .into();
            parity(
                &info,
                &QlogEventView {
                    group_id: ConnectionId::new(&[]),
                    time: info.start_time + Duration::from_micros(1234),
                    fields,
                },
            )
            .await;
        }
        for reason in [
            ReasonView::Text(&text),
            ReasonView::Owned(text.clone().into_boxed_str()),
            ReasonView::Bytes(Cow::Borrowed(&bytes)),
            ReasonView::Bytes(Cow::Borrowed(b"\xf0\x90\x80")),
            ReasonView::Bytes(Cow::Borrowed("valid😀".as_bytes())),
        ] {
            let fields: EventFieldsView<'_> = LifecycleEventView::Closed(ConnectionClosedView {
                reason: Some(reason),
                ..Default::default()
            })
            .into();
            parity(
                &info,
                &QlogEventView {
                    group_id: ConnectionId::new(&[]),
                    time: info.start_time,
                    fields,
                },
            )
            .await;
        }
    }

    #[tokio::test]
    async fn interruptions_pending_and_short_writes_preserve_header_and_event_offsets() {
        let info = TraceInfo {
            event_schemas: &[],
            title: Some("interrupted \"header\"".into()),
            description: Some("\nUnicode 😀".into()),
            start_time: Instant::now(),
        };
        let mut expected = Vec::new();
        ReferenceJsonEncoder::begin(&info, &mut expected).unwrap();
        let mut actual = StutteringWriter {
            interrupt: true,
            ..Default::default()
        };
        AsyncJsonSeqEncoder.begin(&info, &mut actual).await.unwrap();
        for fields in samples() {
            let event = QlogEventView {
                group_id: ConnectionId::new(&[0xab, 0xff]),
                time: info.start_time,
                fields,
            };
            ReferenceJsonEncoder::event(&info, &event, &mut expected).unwrap();
            AsyncJsonSeqEncoder
                .event(&info, &event, &mut actual)
                .await
                .unwrap();
        }
        assert!(actual.interruptions > 100);
        assert!(actual.writes > 100);
        assert_eq!(actual.bytes, expected);
    }

    #[test]
    fn interrupted_adapter_yields_after_one_underlying_poll() {
        struct Interrupted(usize);

        impl AsyncWrite for Interrupted {
            fn poll_write(
                mut self: Pin<&mut Self>,
                _cx: &mut Context<'_>,
                _bytes: &[u8],
            ) -> Poll<io::Result<usize>> {
                self.0 += 1;
                Poll::Ready(Err(io::ErrorKind::Interrupted.into()))
            }

            fn poll_flush(self: Pin<&mut Self>, _cx: &mut Context<'_>) -> Poll<io::Result<()>> {
                Poll::Ready(Ok(()))
            }

            fn poll_shutdown(self: Pin<&mut Self>, _cx: &mut Context<'_>) -> Poll<io::Result<()>> {
                Poll::Ready(Ok(()))
            }
        }
        let mut writer = Interrupted(0);
        let mut adapter = RetryInterrupted::new(&mut writer);
        let mut context = Context::from_waker(std::task::Waker::noop());
        assert!(
            Pin::new(&mut adapter)
                .poll_write(&mut context, b"test")
                .is_pending()
        );
        assert_eq!(writer.0, 1);
    }

    #[tokio::test]
    async fn persistent_interruptions_return_the_original_error_after_bounded_retries() {
        struct Interrupted {
            polls: usize,
            pending: bool,
        }

        impl AsyncWrite for Interrupted {
            fn poll_write(
                mut self: Pin<&mut Self>,
                cx: &mut Context<'_>,
                _bytes: &[u8],
            ) -> Poll<io::Result<usize>> {
                if self.pending {
                    self.pending = false;
                    cx.waker().wake_by_ref();
                    return Poll::Pending;
                }
                self.pending = true;
                self.polls += 1;
                assert!(self.polls <= 9, "retry budget exceeded");
                Poll::Ready(Err(io::Error::new(
                    io::ErrorKind::Interrupted,
                    io::Error::new(io::ErrorKind::PermissionDenied, "original source"),
                )))
            }

            fn poll_flush(self: Pin<&mut Self>, _cx: &mut Context<'_>) -> Poll<io::Result<()>> {
                Poll::Ready(Ok(()))
            }

            fn poll_shutdown(self: Pin<&mut Self>, _cx: &mut Context<'_>) -> Poll<io::Result<()>> {
                Poll::Ready(Ok(()))
            }
        }

        let info = TraceInfo {
            event_schemas: &[],
            title: None,
            description: None,
            start_time: Instant::now(),
        };
        let mut writer = Interrupted {
            polls: 0,
            pending: false,
        };
        let error = AsyncJsonSeqEncoder
            .begin(&info, &mut writer)
            .await
            .unwrap_err();
        assert_eq!(
            writer.polls,
            usize::from(RetryInterrupted::<Interrupted>::MAX_RETRIES) + 1
        );
        assert_eq!(error.kind(), io::ErrorKind::Other);
        assert_eq!(
            error
                .get_ref()
                .unwrap()
                .downcast_ref::<RetryExhausted>()
                .unwrap()
                .0
                .get_ref()
                .unwrap()
                .downcast_ref::<io::Error>()
                .unwrap()
                .kind(),
            io::ErrorKind::PermissionDenied
        );
        assert_eq!(error.to_string(), "original source");
    }

    #[tokio::test]
    async fn write_failures_and_zero_writes_propagate_without_restarting_records() {
        let info = TraceInfo {
            event_schemas: &[],
            title: None,
            description: None,
            start_time: Instant::now(),
        };
        let event = QlogEventView {
            group_id: ConnectionId::new(&[1]),
            time: info.start_time,
            fields: samples().remove(0),
        };
        let mut expected = Vec::new();
        ReferenceJsonEncoder::event(&info, &event, &mut expected).unwrap();
        for limit in [0, 1, 2, 17, expected.len() - 1] {
            let mut output = StutteringWriter {
                fail_after: Some(limit),
                ..Default::default()
            };
            assert_eq!(
                AsyncJsonSeqEncoder
                    .event(&info, &event, &mut output)
                    .await
                    .unwrap_err()
                    .kind(),
                io::ErrorKind::Other
            );
            assert_eq!(output.bytes, expected[..limit]);
        }
        let mut output = StutteringWriter {
            zero: true,
            ..Default::default()
        };
        assert_eq!(
            AsyncJsonSeqEncoder
                .event(&info, &event, &mut output)
                .await
                .unwrap_err()
                .kind(),
            io::ErrorKind::WriteZero
        );
    }
}
