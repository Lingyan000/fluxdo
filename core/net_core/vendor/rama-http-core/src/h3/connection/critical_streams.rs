//! Allocation order and first-write policy for the connection's QPACK streams.
//!
//! Opening a QUIC stream reserves its ID; its type becomes visible to the peer
//! only when bytes are sent. Deferred prefixes follow actual compression work,
//! without changing the encoder's output-credit or decoder-feedback budgets.

use super::{CRITICAL_SEND_RESERVE, Encoder, Error, Shared, encoding_error, write_chunks};
use crate::h3::{qpack::EncodeField, quic::GeneratedWrite, transport};
use rama_core::bytes::{Bytes, BytesMut};
use rama_http_types::proto::h3::{
    Code, StreamType, VarInt, critical_streams::Startup, qpack::FieldSectionBase,
};
use rama_quic_proto::coding::Codec as _;
use std::{future::Future, sync::Arc};

pub(super) struct EncoderStream {
    stream: Box<dyn GeneratedWrite>,
    started: bool,
}

impl EncoderStream {
    pub(super) fn encode<'a, I, F, N, V>(
        &mut self,
        encoder: &mut Encoder,
        id: u64,
        fields: I,
        base: Option<FieldSectionBase>,
    ) -> Result<Bytes, Error>
    where
        I: IntoIterator<Item = F>,
        F: Into<EncodeField<'a, N, V>>,
        N: AsRef<[u8]>,
        V: AsRef<[u8]>,
    {
        let prefix = VarInt::from_u32(StreamType::QPACK_ENCODER.value() as u32);
        let prefix_size = if self.started { 0 } else { prefix.size() };
        let started = &mut self.started;
        let mut fields = Some(fields);
        let mut result = None;
        self.stream
            .try_write_generated(CRITICAL_SEND_RESERVE, &mut |credit| {
                let Some(fields) = fields.take() else {
                    return Bytes::new();
                };
                // Admit the type and its first instructions atomically. If they
                // cannot fit together, the encoder keeps its literal fallback.
                result = Some(
                    encoder
                        .encode_with_credit(id, fields, credit.saturating_sub(prefix_size), base)
                        .map_err(encoding_error),
                );
                let mut output = encoder.take_encoder_stream();
                if !*started && !output.is_empty() {
                    let mut prefixed = BytesMut::with_capacity(prefix_size + output.len());
                    prefix.encode(&mut prefixed);
                    prefixed.extend_from_slice(&output);
                    output = prefixed.freeze();
                    *started = true;
                }
                output
            })
            .map_err(|error| match error {
                transport::WriteError::ConnectionLost(error) => Error::from_transport(&error),
                _ => closed("encoder stream closed"),
            })?;
        result.unwrap_or(Err(Error::connection(
            Code::H3_INTERNAL_ERROR,
            "encoder stream wrote without encoding",
        )))
    }
}

/// Register a deferred encoder synchronously, before the driver exposes SETTINGS.
/// Encoding must see the stream's available credit even before its type is sent.
pub(super) fn encoder_task(
    shared: Arc<Shared>,
    stream: impl transport::SendStream,
    started: bool,
) -> Result<impl Future<Output = Result<(), Error>> + Send, Error> {
    stream
        .set_priority(i32::MAX)
        .map_err(|_error| closed("encoder stream closed"))?;
    let stopped = stream.stopped();
    let pending = if started || shared.config.critical_streams.encoder == Startup::OnDemand {
        *shared.encoder_stream.lock() = Some(EncoderStream {
            stream: Box::new(stream),
            started,
        });
        shared.progress.notify_waiters();
        None
    } else {
        Some(stream)
    };
    Ok(async move {
        if let Some(mut stream) = pending {
            write_prefix(&mut stream, StreamType::QPACK_ENCODER).await?;
            *shared.encoder_stream.lock() = Some(EncoderStream {
                stream: Box::new(stream),
                started: true,
            });
            shared.progress.notify_waiters();
        }
        _ = stopped.await;
        Err(closed("encoder stream stopped"))
    })
}

pub(super) async fn write_decoder(
    shared: Arc<Shared>,
    mut stream: impl transport::SendStream,
    mut started: bool,
) -> Result<(), Error> {
    stream
        .set_priority(i32::MAX)
        .map_err(|_error| closed("decoder stream closed"))?;
    if !started && shared.config.critical_streams.decoder == Startup::Immediate {
        write_prefix(&mut stream, StreamType::QPACK_DECODER).await?;
        started = true;
    }
    loop {
        let mut output = [shared.take_decoder_output()?];
        if output[0].is_empty() {
            tokio::select! {
                _ = shared.decoder_output_ready.notified() => (),
                _ = stream.stopped() => return Err(closed("decoder stream stopped")),
            }
            continue;
        }
        if !started {
            write_prefix(&mut stream, StreamType::QPACK_DECODER).await?;
            started = true;
        }
        while !output[0].is_empty() {
            let before = output[0].len();
            write_chunks(&mut stream, &mut output)
                .await
                .map_err(|_error| closed("decoder stream closed"))?;
            // The type prefix is not decoder feedback and owns no reservation.
            shared.decoder_output_written(before - output[0].len())?;
        }
    }
}

pub(super) async fn write_prefix(
    stream: &mut impl transport::SendStream,
    kind: StreamType,
) -> Result<(), Error> {
    let mut prefix = BytesMut::with_capacity(1);
    VarInt::from_u32(kind.value() as u32).encode(&mut prefix);
    let mut output = [prefix.freeze()];
    while !output[0].is_empty() {
        write_chunks(stream, &mut output)
            .await
            .map_err(|_error| closed("QPACK prefix stream closed"))?;
    }
    Ok(())
}

fn closed(message: &'static str) -> Error {
    Error::connection(Code::H3_CLOSED_CRITICAL_STREAM, message)
}
