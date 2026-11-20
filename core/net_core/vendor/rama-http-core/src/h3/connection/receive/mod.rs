//! Receive ownership for native unidirectional stream classification.
//!
//! The ordinary path keeps direct handlers. Optional observation alone drains
//! currently readable type prefixes before publishing a first-request boundary.

use super::{Error, Shared, receive_uni};
use crate::h3::{
    transport::BoxedRecvStream,
    transport::{self, RecvStream as _},
};
use atomic_waker::AtomicWaker;
use rama_core::{
    bytes::Bytes,
    futures::{Stream, StreamExt, stream::FuturesUnordered},
};
use rama_http_types::proto::h3::{Code, StreamType, VarIntDecoder};
use std::{
    future::{Future, poll_fn},
    pin::{Pin, pin},
    sync::{
        Arc,
        atomic::{AtomicU64, Ordering},
    },
    task::{Context, Poll, Wake, Waker},
};

pub(in crate::h3) mod settings;

pub(super) trait Receiver: Send {
    fn run(&mut self) -> impl Future<Output = Result<(), Error>> + Send;
    fn drain(&mut self) -> impl Future<Output = Result<(), Error>> + Send;
}

/// A classified stream and the remainder of the chunk that supplied its type.
struct TypedUni {
    stream: BoxedRecvStream,
    kind: StreamType,
    chunk: Bytes,
}

/// No observation token, queue or extra state is put in the ordinary handler.
struct Direct<'a, C, Make, Handler> {
    connection: &'a C,
    shared: &'a Arc<Shared>,
    make: Make,
    handlers: FuturesUnordered<Handler>,
}

impl<C: transport::Connection, Make, Handler> Receiver for Direct<'_, C, Make, Handler>
where
    Make: FnMut(C::RecvStream) -> Handler + Send,
    Handler: Future<Output = Result<(), Error>> + Send,
{
    async fn run(&mut self) -> Result<(), Error> {
        loop {
            tokio::select! {
                incoming = self.connection.accept_uni() => {
                    let stream = incoming.map_err(|_error| Error::connection(
                        Code::H3_GENERAL_PROTOCOL_ERROR,
                        "QUIC accept failed",
                    ))?;
                    if self.handlers.len() >= self.shared.config.max_pending_uni_streams {
                        return Err(Error::connection(
                            Code::H3_EXCESSIVE_LOAD,
                            "too many pending unidirectional streams",
                        ));
                    }
                    self.handlers.push((self.make)(stream));
                }
                result = self.handlers.next(), if !self.handlers.is_empty() => {
                    if let Some(Err(error)) = result {
                        if !error.is_clean_close() {
                            let error = error.remote();
                            self.shared.fail(error);
                            return Err(error);
                        }
                        return Err(error);
                    }
                }
            }
        }
    }

    async fn drain(&mut self) -> Result<(), Error> {
        let mut accepting = true;
        while accepting || !self.handlers.is_empty() {
            tokio::select! {
                incoming = self.connection.accept_uni(), if accepting && self.handlers.len() < self.shared.config.max_pending_uni_streams => {
                    match incoming {
                        Ok(stream) => self.handlers.push((self.make)(stream)),
                        Err(_) => accepting = false,
                    }
                }
                result = self.handlers.next(), if !self.handlers.is_empty() => {
                    if let Some(Err(error)) = result && !error.is_clean_close() {
                        let error = error.remote();
                        self.shared.fail(error);
                        return Err(error);
                    }
                }
            }
        }
        Ok(())
    }
}

struct TypeReadWake {
    parent: AtomicWaker,
    generation: AtomicU64,
}

impl Wake for TypeReadWake {
    fn wake(self: Arc<Self>) {
        self.wake_by_ref();
    }

    fn wake_by_ref(self: &Arc<Self>) {
        self.generation.fetch_add(1, Ordering::Release);
        self.parent.wake();
    }
}

struct PendingUni {
    stream: BoxedRecvStream,
    kind: VarIntDecoder,
}

impl PendingUni {
    fn poll_type(
        &mut self,
        cx: &mut Context<'_>,
        chunk_size: usize,
    ) -> Poll<Option<(StreamType, Bytes)>> {
        loop {
            let mut bytes = match self.stream.poll_read_chunk(cx, chunk_size) {
                Poll::Pending => return Poll::Pending,
                Poll::Ready(Ok(Some(chunk))) => chunk,
                Poll::Ready(Ok(None) | Err(_)) => return Poll::Ready(None),
            };
            if let Some(value) = self.kind.decode(&mut bytes) {
                return Poll::Ready(Some((StreamType::new(value.into_inner()), bytes)));
            }
        }
    }
}

struct Observed<'a, C, Make, Handler> {
    connection: &'a C,
    shared: &'a Arc<Shared>,
    make: Make,
    handlers: FuturesUnordered<Handler>,
    pending: Vec<PendingUni>,
    cursor: usize,
    round_generation: u64,
    type_read_wake: Arc<TypeReadWake>,
}

impl<'a, C: transport::Connection, Make, Handler> Observed<'a, C, Make, Handler>
where
    Make: FnMut(TypedUni) -> Handler + Send,
    Handler: Future<Output = Result<(), Error>> + Send,
{
    fn new(connection: &'a C, shared: &'a Arc<Shared>, make: Make) -> Self {
        Self {
            connection,
            shared,
            make,
            handlers: FuturesUnordered::new(),
            pending: Vec::new(),
            cursor: 0,
            round_generation: 0,
            type_read_wake: Arc::new(TypeReadWake {
                parent: AtomicWaker::new(),
                generation: AtomicU64::new(0),
            }),
        }
    }

    async fn receive(&mut self, closing: bool) -> Result<(), Error> {
        let mut accepting = true;
        let mut incoming = pin!(self.connection.accept_uni());
        let mut progress = pin!(self.shared.progress.notified());
        progress.as_mut().enable();
        poll_fn(|cx| {
            self.type_read_wake.parent.register(cx.waker());
            let io_waker = Waker::from(self.type_read_wake.clone());
            let mut io = Context::from_waker(&io_waker);
            let mut operations = 0;
            loop {
                if operations == super::super::cooperative::OPERATIONS_PER_QUANTUM {
                    // Resume the same bounded classification round next poll.
                    cx.waker().wake_by_ref();
                    return Poll::Pending;
                }
                operations += 1;

                let limit = self.shared.config.max_pending_uni_streams;
                let mut incoming_pending = !accepting;
                if accepting && (!closing || self.pending.len() + self.handlers.len() < limit) {
                    match incoming.as_mut().poll(&mut io) {
                        Poll::Ready(Ok(stream)) => {
                            if self.pending.len() + self.handlers.len() >= limit {
                                return Poll::Ready(Err(Error::connection(
                                    Code::H3_EXCESSIVE_LOAD,
                                    "too many pending unidirectional streams",
                                )));
                            }
                            self.pending.push(PendingUni {
                                stream: stream.boxed(),
                                kind: VarIntDecoder::new(),
                            });
                            incoming.set(self.connection.accept_uni());
                            continue;
                        }
                        Poll::Ready(Err(_)) if closing => {
                            accepting = false;
                            incoming_pending = true;
                        }
                        Poll::Ready(Err(_)) => {
                            return Poll::Ready(Err(Error::connection(
                                Code::H3_GENERAL_PROTOCOL_ERROR,
                                "QUIC accept failed",
                            )));
                        }
                        Poll::Pending => incoming_pending = true,
                    }
                }

                if self.cursor < self.pending.len() {
                    let pending = &mut self.pending[self.cursor];
                    match pending.poll_type(&mut io, self.shared.config.read_chunk_size) {
                        Poll::Ready(Some((kind, chunk))) => {
                            let pending = self.pending.remove(self.cursor);
                            // This is ordinary native classification, not a UA
                            // ordering rule. Register the fact before scheduling
                            // the typed CONTROL/QPACK handler.
                            if let Err(error) = self
                                .shared
                                .register_peer_uni(pending.stream.id().into(), kind)
                            {
                                let error = error.remote();
                                self.shared.fail(error);
                                return Poll::Ready(Err(error));
                            }
                            self.handlers.push((self.make)(TypedUni {
                                stream: pending.stream,
                                kind,
                                chunk,
                            }));
                        }
                        Poll::Ready(None) => {
                            self.pending.remove(self.cursor);
                        }
                        Poll::Pending => self.cursor += 1,
                    }
                    match Pin::new(&mut self.handlers).poll_next(cx) {
                        Poll::Ready(Some(Err(error))) if !closing || !error.is_clean_close() => {
                            if !error.is_clean_close() {
                                let error = error.remote();
                                self.shared.fail(error);
                                return Poll::Ready(Err(error));
                            }
                            return Poll::Ready(Err(error));
                        }
                        _ => (),
                    }
                    continue;
                }

                match Pin::new(&mut self.handlers).poll_next(cx) {
                    Poll::Ready(Some(Err(error))) if !closing || !error.is_clean_close() => {
                        if !error.is_clean_close() {
                            let error = error.remote();
                            self.shared.fail(error);
                            return Poll::Ready(Err(error));
                        }
                        return Poll::Ready(Err(error));
                    }
                    Poll::Ready(Some(_)) => continue,
                    _ => (),
                }
                let generation = self.type_read_wake.generation.load(Ordering::Acquire);
                if generation != self.round_generation {
                    self.round_generation = generation;
                    self.cursor = 0;
                    continue;
                }
                if incoming_pending {
                    // Required native hook: published only after the completed
                    // classification pass, never based on handlers' Pending.
                    self.shared.publish_first_request_observation();
                }
                if closing && !accepting && self.pending.is_empty() && self.handlers.is_empty() {
                    return Poll::Ready(Ok(()));
                }
                // Future traffic starts a fresh classification pass. Existing
                // peer-empty handles remain Pending and are never awaited as
                // prerequisites for this publication.
                self.cursor = 0;
                if progress.as_mut().poll(cx).is_ready() {
                    progress.set(self.shared.progress.notified());
                    progress.as_mut().enable();
                    continue;
                }
                return Poll::Pending;
            }
        })
        .await
    }
}

pub(super) fn direct<'a, C: transport::Connection>(
    connection: &'a C,
    shared: &'a Arc<Shared>,
) -> impl Receiver + 'a {
    Direct {
        connection,
        shared,
        make: move |stream| receive_uni(connection, shared.clone(), stream, ()),
        handlers: FuturesUnordered::new(),
    }
}

pub(super) fn observed<'a, C: transport::Connection>(
    connection: &'a C,
    shared: &'a Arc<Shared>,
) -> impl Receiver + 'a {
    Observed::new(connection, shared, move |input: TypedUni| {
        receive_uni(
            connection,
            shared.clone(),
            input.stream,
            (input.kind, input.chunk),
        )
    })
}

impl<C: transport::Connection, Make, Handler> Receiver for Observed<'_, C, Make, Handler>
where
    Make: FnMut(TypedUni) -> Handler + Send,
    Handler: Future<Output = Result<(), Error>> + Send,
{
    async fn run(&mut self) -> Result<(), Error> {
        self.receive(false).await
    }

    async fn drain(&mut self) -> Result<(), Error> {
        self.receive(true).await
    }
}

#[cfg(test)]
mod tests;
