//! Receive ownership before local SETTINGS and compression state are selected.

use super::super::{
    Config, Error, FrameDecoder, FrameEvent, Shared, compression_error, confirm_connection,
    critical_receive_closed, receive_uni,
};
use super::{Observed, PendingUni, Receiver, TypedUni};
use crate::h3::{
    control::{Control, Role},
    cooperative,
    qlog::{self, Initiator},
    transport::{self, RecvStream as _},
};
use rama_http_types::proto::h3::{Code, FrameHeader, Settings, StreamType, VarIntDecoder};
use rama_quic_proto::VarInt;
use rama_utils::guard::DropGuard;
use std::{
    future::{Future, poll_fn},
    pin::{Pin, pin},
    sync::{Arc, atomic::Ordering},
    task::Poll,
};

type Handler<'a> = Pin<Box<dyn Future<Output = Result<(), Error>> + Send + 'a>>;

/// Only native stream/parser state survives the readiness boundary.
pub(in crate::h3) struct SettingsPrelude {
    control: Control,
    settings_header: Option<FrameHeader>,
    incoming: InitialReceive,
}

pub(in crate::h3::connection) struct InitialReceive {
    streams: Vec<ReceivedUni>,
    pending: Vec<PendingUni>,
    max_frame_size: usize,
    read_chunk_size: usize,
    max_pending_uni_streams: usize,
}

struct ReceivedUni {
    input: TypedUni,
    frames: Option<FrameDecoder>,
}

impl std::fmt::Debug for SettingsPrelude {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("ReceivedH3Settings")
            .field("settings_entries", &self.settings().len())
            .field("classified_streams", &self.incoming.streams.len())
            .field("pending_streams", &self.incoming.pending.len())
            .field("max_frame_size", &self.incoming.max_frame_size)
            .field("read_chunk_size", &self.incoming.read_chunk_size)
            .field(
                "max_pending_uni_streams",
                &self.incoming.max_pending_uni_streams,
            )
            .finish_non_exhaustive()
    }
}

impl SettingsPrelude {
    #[expect(
        clippy::expect_used,
        reason = "this private readiness owner is exposed only after complete SETTINGS"
    )]
    pub(in crate::h3) fn settings(&self) -> &Settings {
        self.control.settings().expect("complete peer SETTINGS")
    }

    pub(in crate::h3) fn validate(&self, config: &Config) -> Result<(), Error> {
        if self.incoming.max_frame_size != config.max_frame_size
            || self.incoming.read_chunk_size != config.read_chunk_size
            || self.incoming.max_pending_uni_streams != config.max_pending_uni_streams
        {
            return Err(Error::connection(
                Code::H3_INTERNAL_ERROR,
                "server receive limits changed after reading peer SETTINGS",
            ));
        }
        Ok(())
    }

    pub(in crate::h3) async fn read(
        connection: &impl transport::Connection,
        config: &Config,
    ) -> Result<Self, Error> {
        confirm_connection(connection, config).await?;
        let mut received = Self {
            control: Control::new(Role::Server),
            settings_header: None,
            incoming: InitialReceive {
                streams: Vec::new(),
                pending: Vec::new(),
                max_frame_size: config.max_frame_size,
                read_chunk_size: config.read_chunk_size,
                max_pending_uni_streams: config.max_pending_uni_streams,
            },
        };
        // Declared after the partial owner: cancellation closes the transport
        // before dropping receive handles can queue STOP_SENDING for critical streams.
        let close = connection.clone();
        let mut guard = DropGuard::new(move || {
            close.close(
                VarInt::from_u32(Code::H3_INTERNAL_ERROR.value() as u32),
                b"HTTP/3 peer SETTINGS read stopped",
            );
        });
        let mut accepting = pin!(connection.accept_uni());
        let result = poll_fn(|cx| {
            let mut operations = 0;
            'progress: loop {
                if operations == cooperative::OPERATIONS_PER_QUANTUM {
                    cx.waker().wake_by_ref();
                    return Poll::Pending;
                }
                operations += 1;
                for input in &mut received.incoming.streams {
                    if let Some(frames) = &mut input.frames {
                        frames
                            .feed_bytes(&mut input.input.chunk)
                            .map_err(|_error| {
                                Error::connection(
                                    Code::H3_INTERNAL_ERROR,
                                    "frame input not drained",
                                )
                            })?;
                        while let Some(event) = frames.poll().map_err(|error| {
                            Error::from_frame(&error).unwrap_or(Error::connection(
                                Code::H3_INTERNAL_ERROR,
                                "frame backpressure",
                            ))
                        })? {
                            received.control.receive(&event)?;
                            match event {
                                FrameEvent::Header(header) => {
                                    received.settings_header = Some(header)
                                }
                                FrameEvent::Settings(_) => return Poll::Ready(Ok(())),
                                _ => (),
                            }
                        }
                        match input
                            .input
                            .stream
                            .poll_read_chunk(cx, config.read_chunk_size)
                        {
                            Poll::Ready(Ok(Some(chunk))) => {
                                input.input.chunk = chunk;
                                continue 'progress;
                            }
                            Poll::Ready(Ok(None) | Err(_)) => {
                                return Poll::Ready(Err(critical_receive_closed(connection)));
                            }
                            Poll::Pending => (),
                        }
                    }
                }
                let mut index = 0;
                while index < received.incoming.pending.len() {
                    match received.incoming.pending[index].poll_type(cx, config.read_chunk_size) {
                        Poll::Ready(Some((kind, chunk))) => {
                            // Keep the receive handle in its owner until validation
                            // succeeds, so error closure precedes handle cleanup.
                            received.control.register(kind)?;
                            let pending = received.incoming.pending.remove(index);
                            if matches!(
                                kind,
                                StreamType::CONTROL
                                    | StreamType::QPACK_ENCODER
                                    | StreamType::QPACK_DECODER
                            ) {
                                let frames = (kind == StreamType::CONTROL).then(|| {
                                    FrameDecoder::with_input_limit(
                                        config.max_frame_size,
                                        config.read_chunk_size,
                                    )
                                    .with_header_events()
                                });
                                received.incoming.streams.push(ReceivedUni {
                                    input: TypedUni {
                                        stream: pending.stream,
                                        kind,
                                        chunk,
                                    },
                                    frames,
                                });
                            } else {
                                let mut stream = pending.stream;
                                _ = stream.stop(VarInt::from_u32(
                                    Code::H3_STREAM_CREATION_ERROR.value() as u32,
                                ));
                                // Keep the consumed native stream fact for observation;
                                // discard its unsupported payload, bounded by the same
                                // readiness stream limit as every retained prefix.
                                received.incoming.streams.push(ReceivedUni {
                                    input: TypedUni {
                                        stream,
                                        kind,
                                        chunk: Default::default(),
                                    },
                                    frames: None,
                                });
                            }
                            continue 'progress;
                        }
                        Poll::Ready(None) => {
                            received.incoming.pending.remove(index);
                            continue 'progress;
                        }
                        Poll::Pending => index += 1,
                    }
                }
                match accepting.as_mut().poll(cx) {
                    Poll::Ready(Ok(stream)) => {
                        if received.incoming.pending.len() + received.incoming.streams.len()
                            >= config.max_pending_uni_streams
                        {
                            // This handle has not entered the retained owner yet.
                            // Close before its implicit stop can precede this error.
                            connection.close(
                                VarInt::from_u32(Code::H3_EXCESSIVE_LOAD.value() as u32),
                                b"too many pending unidirectional streams",
                            );
                            return Poll::Ready(Err(Error::connection(
                                Code::H3_EXCESSIVE_LOAD,
                                "too many pending unidirectional streams",
                            )));
                        }
                        received.incoming.pending.push(PendingUni {
                            stream: stream.boxed(),
                            kind: VarIntDecoder::new(),
                        });
                        accepting.set(connection.accept_uni());
                    }
                    Poll::Ready(Err(_)) => {
                        return Poll::Ready(Err(Error::connection(
                            Code::H3_GENERAL_PROTOCOL_ERROR,
                            "QUIC accept failed",
                        )));
                    }
                    Poll::Pending => return Poll::Pending,
                }
            }
        })
        .await;
        if let Err(error) = result {
            let code = VarInt::from_u64(error.code().value())
                .unwrap_or(VarInt::from_u32(Code::H3_INTERNAL_ERROR.value() as u32));
            connection.close(code, b"HTTP/3 peer SETTINGS rejected");
            guard.disarm();
            return Err(error);
        }
        guard.disarm();
        Ok(received)
    }

    pub(in crate::h3::connection) fn apply_peer_settings(
        &self,
        shared: &Arc<Shared>,
    ) -> Result<(), Error> {
        shared
            .state
            .lock()
            .encoder
            .apply_peer_settings(self.settings())
            .map_err(compression_error)?;
        qlog::parameters(shared.qlog.as_ref(), Initiator::Remote, self.settings());
        for input in &self.incoming.streams {
            let id = input.input.stream.id().into();
            qlog::stream_type(
                shared.qlog.as_ref(),
                Initiator::Remote,
                id,
                input.input.kind,
            );
            if input.input.kind == StreamType::CONTROL {
                qlog::parsed_settings(shared.qlog.as_ref(), id, self.settings());
            }
        }
        Ok(())
    }

    #[expect(
        clippy::expect_used,
        reason = "header events precede the complete SETTINGS that constructs this owner"
    )]
    pub(in crate::h3::connection) fn into_receiver(self, shared: &Arc<Shared>) -> InitialReceive {
        let settings = self.settings();
        let datagrams = settings.h3_datagram();
        {
            let mut state = shared.state.lock();
            state.begin_observation_control_batch();
            if let Some(observation) = &mut state.observation {
                for input in &self.incoming.streams {
                    observation.stream(input.input.stream.id().into(), input.input.kind);
                }
                observation.control(&FrameEvent::Header(
                    self.settings_header.expect("SETTINGS header received"),
                ));
                observation.control(&FrameEvent::Settings(settings.clone()));
            }
            state.control = self.control;
        }
        shared.peer_datagrams.store(datagrams, Ordering::Release);
        shared.settings_ready.notify_waiters();
        self.incoming
    }
}

pub(in crate::h3::connection) fn resume<'a, C: transport::Connection>(
    connection: &'a C,
    shared: &'a Arc<Shared>,
    received: InitialReceive,
) -> impl Receiver + 'a {
    // Reuse the existing bounded prefix owner. Boxed handlers exist only on this
    // explicitly staged path; ordinary direct/observed drivers are unchanged.
    let make = move |input: TypedUni| -> Handler<'a> {
        Box::pin(receive_uni(
            connection,
            shared.clone(),
            input.stream,
            (input.kind, input.chunk),
        ))
    };
    let mut receiver = Observed::new(connection, shared, make);
    receiver.pending = received.pending;
    for input in received.streams {
        let handler: Handler<'a> = if let Some(frames) = input.frames {
            Box::pin(receive_uni(
                connection,
                shared.clone(),
                input.input.stream,
                (input.input.kind, input.input.chunk, frames),
            ))
        } else {
            Box::pin(receive_uni(
                connection,
                shared.clone(),
                input.input.stream,
                (input.input.kind, input.input.chunk),
            ))
        };
        receiver.handlers.push(handler);
    }
    receiver
}
