use std::{
    marker::{PhantomData, Unpin},
    pin::Pin,
    task::{Context, Poll},
};

use rama_core::error::BoxError;
use rama_core::extensions::ExtensionsRef;
use rama_core::telemetry::tracing::{debug, error, trace};
use rama_core::{
    Service,
    bytes::{Buf, Bytes},
};
use rama_http::StreamingBody;
use rama_http_types::{Request, Response, StatusCode};
use rama_net::conn::LingeringClose;
use std::task::ready;
use tokio::io::{AsyncRead, AsyncWrite};

use super::{Http1Transaction, Wants};
use crate::body::{Body, DecodedLength, Incoming as IncomingBody};
use crate::client::dispatch::TrySendError;
use crate::common::task;
use crate::proto::{BodyLength, Conn, Dispatched, MessageHead, RequestHead};

pub(crate) struct Dispatcher<D, Bs: StreamingBody, I, T> {
    conn: Conn<I, Bs::Data, T>,
    dispatch: D,
    body_tx: SenderDropGuard,
    body_rx: Pin<Box<Option<Bs>>>,
    is_closing: bool,
    // Set once the dispatch loop has ended. After an error we still want to
    // drive a best-effort transport shutdown (so e.g. a TLS stream emits
    // close_notify) before yielding, instead of dropping it mid-flight.
    shutting_down: bool,
    // An error that could not be handed to a user (e.g. server-side, where
    // there is no client callback) and must be surfaced once the best-effort
    // shutdown has been driven.
    pending_err: Option<crate::Error>,
    // Shutdown completed or was abandoned after a write timeout; never retry it.
    shut_down: bool,
    linger: Linger,
}

/// Lingering close of a server connection: while responding and after shutting down, keep
/// reading and dropping what the client still sends, so that closing with
/// unread input does not reset the client, which on Windows would make it
/// drop the response it has not read yet.
enum Linger {
    NotStarted,
    Draining {
        bounds: LingeringClose,
        // Due at the idle deadline or at `give_up`, whichever comes first,
        // and only moved when it fires: cheaper than a reset on every read.
        timer: Pin<Box<tokio::time::Sleep>>,
        started: tokio::time::Instant,
        give_up: tokio::time::Instant,
        last_data: tokio::time::Instant,
        discarded: u64,
    },
    Done,
    // The peer was still sending when the allowance ran out. A response still
    // blocked on this upload must not retain the connection indefinitely. A
    // peer that went idle is done instead: it is not what blocks a response.
    Exhausted,
}

/// How many reads a lingering connection does per poll before it yields, so
/// that a client that always has data ready does not starve other tasks.
const LINGER_READS_PER_POLL: usize = 16;

/// `instant + duration`, or a far-off instant if that does not fit.
fn after(instant: tokio::time::Instant, duration: std::time::Duration) -> tokio::time::Instant {
    instant
        .checked_add(duration)
        .unwrap_or_else(|| instant + std::time::Duration::from_secs(86_400 * 365 * 30))
}

pub(crate) trait Dispatch {
    type PollItem;
    type PollBody;
    type PollError;
    type RecvItem;
    fn poll_msg(
        self: Pin<&mut Self>,
        cx: &mut Context<'_>,
    ) -> Poll<Option<Result<(Self::PollItem, Self::PollBody), Self::PollError>>>;
    fn recv_msg(&mut self, msg: crate::Result<(Self::RecvItem, IncomingBody)>)
    -> crate::Result<()>;
    fn poll_ready(&mut self, cx: &mut Context<'_>) -> Poll<Result<(), ()>>;
    fn should_poll(&self) -> bool;
    /// Stops taking messages, settling those still on their way in.
    fn poll_close(&mut self, cx: &mut Context<'_>) -> Poll<()>;
}

pub(crate) struct Server<S, B>
where
    S: Service<Request<B>, Output = Response, Error = Infallible>,
{
    in_flight: Option<Pin<Box<dyn Future<Output = Result<Response, Infallible>> + Send + 'static>>>,
    pub(crate) service: S,
    _phantom: PhantomData<fn() -> B>,
}

pin_project_lite::pin_project! {
    pub(crate) struct Client<B> {
        callback: Option<crate::client::dispatch::Callback<Request<B>, Response<IncomingBody>>>,
        #[pin]
        rx: ClientRx<B>,
        rx_closed: bool,
    }
}

type ClientRx<B> = crate::client::dispatch::Receiver<Request<B>, Response<IncomingBody>>;

impl<D, Bs, I, T> Dispatcher<D, Bs, I, T>
where
    D: Dispatch<
            PollItem = MessageHead<T::Outgoing>,
            PollBody = Bs,
            RecvItem = MessageHead<T::Incoming>,
        > + Unpin,
    D::PollError: Into<BoxError>,
    I: AsyncRead + AsyncWrite + Unpin + ExtensionsRef,
    T: Http1Transaction + Unpin,
    Bs: StreamingBody<Data: Send + 'static, Error: Into<BoxError>> + Send + 'static + Unpin,
{
    pub(crate) fn new(dispatch: D, conn: Conn<I, Bs::Data, T>) -> Self {
        Self {
            conn,
            dispatch,
            body_tx: SenderDropGuard::none(),
            body_rx: Box::pin(None),
            is_closing: false,
            shutting_down: false,
            pending_err: None,
            shut_down: false,
            linger: Linger::NotStarted,
        }
    }

    pub(crate) fn disable_keep_alive(&mut self) {
        // A graceful shutdown must not wait for lingering clients.
        self.linger = Linger::Done;
        self.conn.disable_keep_alive();

        // If keep alive has been disabled and no read or write has been seen on
        // the connection yet, we must be in a state where the server is being asked to
        // shut down before any data has been seen on the connection
        if self.conn.is_write_closed() || self.conn.has_initial_read_write_state() {
            self.close();
        }
    }

    pub(crate) fn into_inner(self) -> (I, Bytes, D) {
        let (io, buf) = self.conn.into_inner();
        (io, buf, self.dispatch)
    }

    /// Run this dispatcher until HTTP says this connection is done,
    /// but don't call `Write::shutdown` on the underlying IO.
    ///
    /// This is useful for old-style HTTP upgrades, but ignores
    /// newer-style upgrade API.
    pub(crate) fn poll_without_shutdown(
        &mut self,
        cx: &mut Context<'_>,
    ) -> Poll<crate::Result<()>> {
        Pin::new(self).poll_catch(cx, false).map_ok(|ds| {
            if let Dispatched::Upgrade(pending) = ds {
                pending.manual();
            }
        })
    }

    fn poll_catch(
        &mut self,
        cx: &mut Context<'_>,
        should_shutdown: bool,
    ) -> Poll<crate::Result<Dispatched>> {
        // Phase 1: run the dispatch loop until it finishes or errors. On error
        // we switch into a best-effort shutdown phase rather than dropping the
        // transport mid-flight (which would skip TLS `close_notify`).
        if !self.shutting_down {
            match ready!(self.poll_inner(cx, should_shutdown)) {
                // An upgrade hands the connection off: its sender stays ready until dropped.
                Ok(upgrade @ Dispatched::Upgrade(_)) => return Poll::Ready(Ok(upgrade)),
                Ok(Dispatched::Shutdown) => (),
                Err(e) => {
                    // Be sure to alert a streaming body of the failure with a
                    // more specific error than the drop guard would provide.
                    if let Some(mut body) = self.body_tx.take() {
                        body.send_error(crate::Error::new_body("connection error"));
                    }
                    // Only a rejected request leaves a response worth
                    // protecting while the client may still be sending: the
                    // automatic 400, 414 or 431, or one already going out,
                    // which the conn marks by abandoning the input. After a
                    // service, body or IO error, or a parse error answered
                    // with nothing, the error should surface now.
                    if !e.is_parse() || !self.conn.is_read_abandoned() {
                        self.linger = Linger::Done;
                    }
                    // Try to hand the error to the user (client callback). The
                    // server has no user to hand it to, so `recv_msg` returns
                    // the error back; either way we still drive a best-effort
                    // shutdown below before surfacing any residual error,
                    // rather than returning early as the old code did.
                    self.pending_err = self.dispatch.recv_msg(Err(e)).err();
                }
            }
            self.shutting_down = true;
        }

        // Phase 2: best-effort transport shutdown so a still-writable stream
        // (e.g. a TLS stream whose *upstream* failed) emits `close_notify`
        // instead of being dropped silently. This intentionally applies to both
        // server and client connections (the clean path already shuts down).
        // `poll_shutdown` does not wait for the peer's `close_notify` reply, but
        // may still return Pending on local write readiness; it is bounded by
        // the surrounding connection / graceful-shutdown lifecycle, not
        // intrinsically.
        if should_shutdown {
            if !self.shut_down {
                // result ignored: the transport may already be broken, and
                // `conn::poll_shutdown` logs any IO error itself.
                _ = ready!(self.conn.poll_shutdown(cx));
                self.shut_down = true;
            }
            // Phase 3: lingering close, see `Linger`.
            ready!(self.poll_linger(cx));
        }

        // Phase 4: a send that began before the close may still publish its
        // request, whose caller can hold the sender while awaiting the response.
        ready!(self.dispatch.poll_close(cx));

        match self.pending_err.take() {
            Some(e) => Poll::Ready(Err(e)),
            None => Poll::Ready(Ok(Dispatched::Shutdown)),
        }
    }

    fn poll_inner(
        &mut self,
        cx: &mut Context<'_>,
        should_shutdown: bool,
    ) -> Poll<crate::Result<Dispatched>> {
        T::update_date();

        // Once shut down, only lingering is left to do.
        if !self.shut_down {
            let dispatched = self.poll_loop(cx)?;
            // Once HTTP abandons input, drain concurrently with the response.
            // Otherwise an uploading client that reads only after sending can
            // fill both directions and prevent even the FIN from being sent.
            // Never consume bytes belonging to an accepted/manual upgrade.
            if should_shutdown
                && T::is_server()
                && self.conn.is_read_closed()
                && !self.conn.can_write_head()
                && !self.conn.has_pending_upgrade()
            {
                _ = self.poll_linger(cx);
                // The body producer may be slow even though IO is writable.
                // Only a flush blocked on IO exhausts the response's allowance.
                if matches!(self.linger, Linger::Exhausted) && self.poll_flush(cx)?.is_pending() {
                    return self.linger_write_timeout();
                }
            }
            ready!(dispatched);
        }

        if self.shut_down || self.is_done() {
            if !self.shut_down {
                if let Some(pending) = self.conn.pending_upgrade() {
                    self.conn.take_error()?;
                    return Poll::Ready(Ok(Dispatched::Upgrade(pending)));
                } else if should_shutdown {
                    let shutdown = self.conn.poll_shutdown(cx);
                    if shutdown.is_pending() && matches!(self.linger, Linger::Exhausted) {
                        return self.linger_write_timeout();
                    }
                    let shutdown = ready!(shutdown);
                    self.shut_down = true;
                    shutdown.map_err(crate::Error::new_shutdown)?;
                }
            }
            if should_shutdown {
                ready!(self.poll_linger(cx));
            }
            self.conn.take_error()?;
            Poll::Ready(Ok(Dispatched::Shutdown))
        } else {
            Poll::Pending
        }
    }

    fn linger_write_timeout(&mut self) -> Poll<crate::Result<Dispatched>> {
        // A best-effort shutdown would flush the same blocked response again.
        // The response is incomplete. Publish an abnormal end before dropping
        // IO: Apple FFI streams otherwise fire their orderly close callback,
        // and TCP streams without unread input would send a clean FIN.
        self.conn.abort();
        self.shut_down = true;
        Poll::Ready(Err(crate::Error::new_body_write(std::io::Error::new(
            std::io::ErrorKind::TimedOut,
            "response blocked after the lingering upload allowance expired",
        ))))
    }

    /// Drain abandoned input concurrently with a response and after shutdown,
    /// sharing one allowance across both phases.
    fn poll_linger(&mut self, cx: &mut Context<'_>) -> Poll<()> {
        use tokio::time::Instant;

        loop {
            match &mut self.linger {
                Linger::Done | Linger::Exhausted => return Poll::Ready(()),
                Linger::NotStarted => {
                    let bounds = self.conn.lingering_close().filter(|bounds| {
                        T::is_server()
                            && bounds.is_enabled()
                            && !self.conn.is_peer_read_finished()
                            && self.conn.left_input_unread()
                    });
                    self.linger = match bounds {
                        Some(bounds) => {
                            let started = Instant::now();
                            let give_up = after(started, bounds.timeout());
                            let due = after(started, bounds.idle_timeout()).min(give_up);
                            Linger::Draining {
                                bounds,
                                timer: Box::pin(tokio::time::sleep_until(due)),
                                started,
                                give_up,
                                last_data: started,
                                discarded: 0,
                            }
                        }
                        None => Linger::Done,
                    };
                }
                Linger::Draining {
                    bounds,
                    timer,
                    started,
                    give_up,
                    last_data,
                    discarded,
                } => {
                    let end = 'drain: {
                        for _ in 0..LINGER_READS_PER_POLL {
                            let room = bounds.max_bytes().map_or(usize::MAX, |max| {
                                usize::try_from(max.saturating_sub(*discarded))
                                    .unwrap_or(usize::MAX)
                            });
                            if room == 0 {
                                break 'drain "max_bytes";
                            }
                            match self.conn.poll_discard_read(cx, room) {
                                Poll::Ready(Ok(0)) => break 'drain "eof",
                                Poll::Ready(Err(_)) => break 'drain "error",
                                Poll::Ready(Ok(n)) => {
                                    *discarded += n as u64;
                                    *last_data = Instant::now();
                                    if *last_data >= *give_up {
                                        break 'drain "timeout";
                                    }
                                }
                                Poll::Pending => loop {
                                    if timer.as_mut().poll(cx).is_pending() {
                                        return Poll::Pending;
                                    }
                                    let due =
                                        after(*last_data, bounds.idle_timeout()).min(*give_up);
                                    if due <= Instant::now() {
                                        break 'drain if due == *give_up {
                                            "timeout"
                                        } else {
                                            "idle"
                                        };
                                    }
                                    timer.as_mut().reset(due);
                                },
                            }
                        }
                        cx.waker().wake_by_ref();
                        return Poll::Pending;
                    };
                    trace!(
                        discarded = *discarded,
                        end,
                        linger_ms =
                            u64::try_from(started.elapsed().as_millis()).unwrap_or(u64::MAX),
                        "http1 server lingered before closing the connection",
                    );
                    self.linger = if matches!(end, "timeout" | "max_bytes") {
                        Linger::Exhausted
                    } else {
                        Linger::Done
                    };
                }
            }
        }
    }

    fn poll_loop(&mut self, cx: &mut Context<'_>) -> Poll<crate::Result<()>> {
        // Limit the looping on this connection, in case it is ready far too
        // often, so that other futures don't starve.
        //
        // 16 was chosen arbitrarily, as that is number of pipelined requests
        // benchmarks often use. Perhaps it should be a config option instead.
        for _ in 0..16 {
            _ = self.poll_read(cx)?;
            let write_ready = self.poll_write(cx)?.is_ready();
            let flush_ready = self.poll_flush(cx)?.is_ready();

            // If we can write more body and the connection is ready, we should
            // write again. If we return `Ready(Ok(())` here, we will yield
            // without a guaranteed wake-up from the write side of the connection.
            // This would lead to a deadlock if we also don't expect reads.
            let wants_write_again = self.can_write_again() && (write_ready || flush_ready);

            // This could happen if reading paused before blocking on IO,
            // such as getting to the end of a framed message, but then
            // writing/flushing set the state back to Init. In that case,
            // if the read buffer still had bytes, we'd want to try poll_read
            // again, or else we wouldn't ever be woken up again.
            //
            // Using this instead of task::current() and notify() inside
            // the Conn is noticeably faster in pipelined benchmarks.
            let wants_read_again = self.conn.wants_read_again();

            // If we cannot write or read again, we yield and rely on the
            // wake-up from the connection futures.
            if !(wants_write_again || wants_read_again) {
                return Poll::Ready(Ok(()));
            }
            // If we are continuing only because "wants_write_again", re-check whether a second
            // write poll can make progress. `poll_flush` can be ready even when there is no
            // buffered data and the request body is still pending, so relying on the previous
            // readiness can hot-loop.
            if !wants_read_again && wants_write_again {
                // If write was ready, just proceed with the loop
                if write_ready {
                    continue;
                }
                // Write was previously pending, but may have become ready since polling flush, so
                // we need to check it again. If it is still pending, it is safe to yield and rely
                // on wake-up from the connection futures.
                if self.poll_write(cx)?.is_pending() {
                    // That write can have buffered bytes before going pending: a body that
                    // reached end-of-stream between the two write polls buffers the end of the
                    // message here, and then the write goes pending on the *next* message.
                    // Yielding without flushing would strand those bytes in the write buffer
                    // until the peer gives up, since the wake-ups we then rely on are for
                    // reads. Flush what was just buffered before yielding.
                    if self.conn.has_buffered_write() {
                        _ = self.poll_flush(cx)?;
                    }
                    return Poll::Ready(Ok(()));
                }
            }
        }
        trace!("poll_loop yielding (self = {:p})", self);
        task::yield_now(cx).map(|never| match never {})
    }

    fn poll_read(&mut self, cx: &mut Context<'_>) -> Poll<crate::Result<()>> {
        loop {
            if self.is_closing {
                return Poll::Ready(Ok(()));
            } else if self.conn.can_read_head() {
                ready!(self.poll_read_head(cx))?;
            } else if let Some(mut body) = self.body_tx.take() {
                if self.conn.can_read_body() {
                    match body.poll_ready(cx) {
                        Poll::Ready(Ok(())) => (),
                        Poll::Pending => {
                            self.body_tx.set(body);
                            return Poll::Pending;
                        }
                        Poll::Ready(Err(_canceled)) => {
                            // user doesn't care about the body
                            // so we should stop reading
                            trace!("body receiver dropped before eof, draining or closing");
                            self.conn.poll_drain_or_close_read(cx);
                            continue;
                        }
                    }
                    match self.conn.poll_read_body(cx) {
                        Poll::Ready(Some(Ok(frame))) => {
                            if frame.is_data() {
                                let chunk = frame.into_data().unwrap_or_else(|_| unreachable!());
                                match body.try_send_data(chunk) {
                                    // The last chunk drops the sender, which ends the body even
                                    // when no further read follows (the response already went out).
                                    Ok(()) if self.conn.can_read_body() => {
                                        self.body_tx.set(body);
                                    }
                                    Ok(()) => {}
                                    Err(_canceled) => {
                                        if self.conn.can_read_body() {
                                            trace!("body receiver dropped before eof, closing");
                                            self.conn.close_read();
                                        }
                                    }
                                }
                            } else if frame.is_trailers() {
                                let trailers =
                                    frame.into_trailers().unwrap_or_else(|_| unreachable!());
                                match body.try_send_trailers(trailers) {
                                    // Trailers end the body: dropping the sender delivers that.
                                    Ok(()) => {}
                                    Err(_canceled) => {
                                        if self.conn.can_read_body() {
                                            trace!("body receiver dropped before eof, closing");
                                            self.conn.close_read();
                                        }
                                    }
                                }
                            } else {
                                // we should have dropped all unknown frames in poll_read_body
                                error!("unexpected frame");
                            }
                        }
                        Poll::Ready(None) => {
                            // just drop, the body will close automatically
                        }
                        Poll::Pending => {
                            self.body_tx.set(body);
                            return Poll::Pending;
                        }
                        Poll::Ready(Some(Err(e))) => {
                            body.send_error(crate::Error::new_body(e));
                        }
                    }
                } else {
                    // just drop, the body will close automatically
                }
            } else {
                return self.conn.poll_read_keep_alive(cx);
            }
        }
    }

    fn poll_read_head(&mut self, cx: &mut Context<'_>) -> Poll<crate::Result<()>> {
        // can dispatch receive, or does it still care about other incoming message?
        if let Ok(()) = ready!(self.dispatch.poll_ready(cx)) {
        } else {
            trace!("dispatch no longer receiving messages");
            self.close();
            return Poll::Ready(Ok(()));
        }

        // dispatch is ready for a message, try to read one
        match ready!(self.conn.poll_read_head(cx)) {
            Some(Ok((head, body_len, wants))) => {
                let body = match body_len {
                    DecodedLength::ZERO => IncomingBody::empty(),
                    other => {
                        let (tx, rx) =
                            IncomingBody::new_channel(other, wants.contains(Wants::EXPECT));
                        self.body_tx.set(tx);
                        rx
                    }
                };
                if wants.contains(Wants::UPGRADE) {
                    let upgrade = self.conn.on_upgrade();
                    head.extensions.insert(upgrade);
                }
                self.dispatch.recv_msg(Ok((head, body)))?;
                Poll::Ready(Ok(()))
            }
            Some(Err(err)) => {
                debug!("read_head error: {}", err);
                self.dispatch.recv_msg(Err(err))?;
                // if here, the dispatcher gave the user the error
                // somewhere else. we still need to shutdown, but
                // not as a second error.
                self.close();
                Poll::Ready(Ok(()))
            }
            None => {
                // read eof, the write side will have been closed too unless
                // allow_read_close was set to true, in which case just do
                // nothing...
                debug_assert!(self.conn.is_read_closed());
                if self.conn.is_write_closed() {
                    self.close();
                }
                Poll::Ready(Ok(()))
            }
        }
    }

    fn poll_write(&mut self, cx: &mut Context<'_>) -> Poll<crate::Result<()>> {
        loop {
            if self.is_closing {
                return Poll::Ready(Ok(()));
            } else if self.body_rx.is_none()
                && self.conn.can_write_head()
                && self.dispatch.should_poll()
            {
                if let Some(msg) = ready!(Pin::new(&mut self.dispatch).poll_msg(cx)) {
                    let (head, body) = msg.map_err(crate::Error::new_user_service)?;

                    let body_type = if body.is_end_stream() {
                        self.body_rx.set(None);
                        None
                    } else {
                        let btype = body
                            .size_hint()
                            .exact()
                            .map(BodyLength::Known)
                            .or(Some(BodyLength::Unknown));
                        self.body_rx.set(Some(body));
                        btype
                    };
                    self.conn.write_head(head, body_type);
                } else {
                    self.close();
                    return Poll::Ready(Ok(()));
                }
            } else if !self.conn.can_buffer_body() {
                ready!(self.poll_flush(cx))?;
            } else {
                // A new scope is needed :(
                if let (Some(mut body), clear_body) =
                    OptGuard::new(self.body_rx.as_mut()).guard_mut()
                {
                    debug_assert!(!*clear_body, "opt guard defaults to keeping body");
                    if !self.conn.can_write_body() {
                        trace!(
                            "no more write body allowed, user body is_end_stream = {}",
                            body.is_end_stream(),
                        );
                        *clear_body = true;
                        continue;
                    }

                    let item = ready!(body.as_mut().poll_frame(cx));
                    if let Some(item) = item {
                        let frame = item.map_err(|e| {
                            *clear_body = true;
                            crate::Error::new_user_body(e)
                        })?;

                        if frame.is_data() {
                            let chunk = frame.into_data().unwrap_or_else(|_| unreachable!());
                            let eos = body.is_end_stream();
                            if eos {
                                *clear_body = true;
                                if chunk.remaining() == 0 {
                                    trace!("discarding empty chunk");
                                    self.conn.end_body()?;
                                } else {
                                    self.conn.write_body_and_end(chunk);
                                }
                            } else {
                                if chunk.remaining() == 0 {
                                    trace!("discarding empty chunk");
                                    continue;
                                }
                                self.conn.write_body(chunk);
                            }
                        } else if frame.is_trailers() {
                            *clear_body = true;
                            self.conn.write_trailers(
                                &frame.into_trailers().unwrap_or_else(|_| unreachable!()),
                            );
                        } else {
                            trace!("discarding unknown frame");
                        }
                    } else {
                        *clear_body = true;
                        self.conn.end_body()?;
                    }
                } else {
                    // If there's no body_rx, end the body
                    if self.conn.can_write_body() {
                        self.conn.end_body()?;
                    } else {
                        return Poll::Pending;
                    }
                }
            }
        }
    }

    fn poll_flush(&mut self, cx: &mut Context<'_>) -> Poll<crate::Result<()>> {
        self.conn.poll_flush(cx).map_err(|err| {
            debug!("error writing: {}", err);
            crate::Error::new_body_write(err)
        })
    }

    fn close(&mut self) {
        self.is_closing = true;
        self.conn.close_read();
        self.conn.close_write();
    }

    /// If there is pending data in `body_rx`, and the connection is still in a body-writing state,
    /// we can make progress writing if the connection is ready.
    #[expect(clippy::needless_pass_by_ref_mut)]
    fn can_write_again(&mut self) -> bool {
        !self.is_closing && self.body_rx.is_some() && self.conn.can_write_body()
    }

    fn is_done(&self) -> bool {
        if self.is_closing {
            return true;
        }

        let read_done = self.conn.is_read_closed();

        if !T::should_read_first() && read_done {
            // a client that cannot read may was well be done.
            true
        } else {
            let write_done = self.conn.is_write_closed()
                || (!self.dispatch.should_poll() && self.body_rx.is_none());
            read_done && write_done
        }
    }
}

impl<D, Bs, I, T> Future for Dispatcher<D, Bs, I, T>
where
    D: Dispatch<
            PollItem = MessageHead<T::Outgoing>,
            PollBody = Bs,
            RecvItem = MessageHead<T::Incoming>,
        > + Unpin,
    D::PollError: Into<BoxError>,
    I: AsyncRead + AsyncWrite + Unpin + ExtensionsRef,
    T: Http1Transaction + Unpin,
    Bs: StreamingBody<Data: Send + 'static, Error: Into<BoxError>> + Send + 'static + Unpin,
{
    type Output = crate::Result<Dispatched>;

    #[inline]
    fn poll(mut self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<Self::Output> {
        self.poll_catch(cx, true)
    }
}

// ===== impl OptGuard =====

/// A drop guard to allow a mutable borrow of an Option while being able to
/// set whether the `Option` should be cleared on drop.
struct OptGuard<'a, T>(Pin<&'a mut Option<T>>, bool);

impl<'a, T> OptGuard<'a, T> {
    fn new(pin: Pin<&'a mut Option<T>>) -> Self {
        OptGuard(pin, false)
    }

    fn guard_mut(&mut self) -> (Option<Pin<&mut T>>, &mut bool) {
        (self.0.as_mut().as_pin_mut(), &mut self.1)
    }
}

impl<T> Drop for OptGuard<'_, T> {
    fn drop(&mut self) {
        if self.1 {
            self.0.set(None);
        }
    }
}

// ===== impl SenderDropGuard =====

/// A drop guard for the body `Sender`.
///
/// If the `Dispatcher` future is dropped (e.g. the runtime driving the
/// connection is shut down) while it still owns a body `Sender`, the guard
/// sends an incomplete-message error so the receiver sees an error instead
/// of a silent, clean end-of-stream.
struct SenderDropGuard(Option<crate::body::Sender>);

impl SenderDropGuard {
    #[inline(always)]
    fn none() -> Self {
        Self(None)
    }

    fn set(&mut self, sender: crate::body::Sender) {
        self.0 = Some(sender);
    }

    fn take(&mut self) -> Option<crate::body::Sender> {
        self.0.take()
    }
}

impl Drop for SenderDropGuard {
    fn drop(&mut self) {
        if let Some(mut sender) = self.0.take() {
            sender.send_error(crate::Error::new_incomplete());
        }
    }
}

// ===== impl Server =====

impl<
    S: Service<Request<B>, Output = Response, Error = Infallible>,
    B: StreamingBody<Data: Send + 'static, Error: Into<BoxError> + Send + 'static + Unpin>,
> Server<S, B>
{
    pub(crate) fn new(service: S) -> Self {
        Self {
            in_flight: None,
            service,
            _phantom: PhantomData,
        }
    }

    pub(crate) fn into_service(self) -> S {
        self.service
    }
}

// Service is never pinned
impl<
    S: Service<Request<B>, Output = Response, Error = Infallible>,
    B: StreamingBody<Data: Send + 'static, Error: Into<BoxError> + Send + 'static + Unpin>,
> Unpin for Server<S, B>
{
}

impl<S> Dispatch for Server<S, IncomingBody>
where
    S: Service<Request<IncomingBody>, Output = Response, Error = Infallible> + Clone,
{
    type PollItem = MessageHead<StatusCode>;
    type PollBody = Body;
    type PollError = Infallible;
    type RecvItem = RequestHead;

    fn poll_msg(
        mut self: Pin<&mut Self>,
        cx: &mut Context<'_>,
    ) -> Poll<Option<Result<(Self::PollItem, Self::PollBody), Self::PollError>>> {
        let mut this = self.as_mut();
        let ret = if let Some(fut) = this.in_flight.as_mut() {
            let resp = ready!(fut.as_mut().poll(cx)?);
            let (parts, body) = resp.into_parts();
            let head = MessageHead {
                version: parts.version,
                subject: parts.status,
                headers: parts.headers,
                extensions: parts.extensions,
            };
            Poll::Ready(Some(Ok((head, body))))
        } else {
            unreachable!("poll_msg shouldn't be called if no inflight");
        };

        // Since in_flight finished, remove it
        this.in_flight = None;
        ret
    }

    fn recv_msg(
        &mut self,
        msg: crate::Result<(Self::RecvItem, IncomingBody)>,
    ) -> crate::Result<()> {
        let (msg, body) = msg?;
        let mut req = Request::new(body);
        *req.method_mut() = msg.subject.0;
        *req.uri_mut() = msg.subject.1;
        *req.headers_mut() = msg.headers;
        *req.version_mut() = msg.version;
        req.set_extensions(msg.extensions);
        let fut = {
            let svc = self.service.clone();
            async move { svc.serve(req).await }
        };
        self.in_flight = Some(Box::pin(fut));
        Ok(())
    }

    fn poll_ready(&mut self, _cx: &mut Context<'_>) -> Poll<Result<(), ()>> {
        if self.in_flight.is_some() {
            Poll::Pending
        } else {
            Poll::Ready(Ok(()))
        }
    }

    fn should_poll(&self) -> bool {
        self.in_flight.is_some()
    }

    fn poll_close(&mut self, _cx: &mut Context<'_>) -> Poll<()> {
        Poll::Ready(())
    }
}

// ===== impl Client =====

use std::convert::Infallible;

impl<B> Client<B> {
    pub(crate) fn new(rx: ClientRx<B>) -> Self {
        Self {
            callback: None,
            rx,
            rx_closed: false,
        }
    }
}

impl<B> Dispatch for Client<B>
where
    B: StreamingBody<Data: Send + 'static, Error: Into<BoxError>> + Send + 'static + Unpin,
{
    type PollItem = RequestHead;
    type PollBody = B;
    type PollError = Infallible;
    type RecvItem = crate::proto::ResponseHead;

    fn poll_msg(
        mut self: Pin<&mut Self>,
        cx: &mut Context<'_>,
    ) -> Poll<Option<Result<(Self::PollItem, Self::PollBody), Infallible>>> {
        let mut this = self.as_mut();
        debug_assert!(!this.rx_closed);
        match this.rx.poll_recv(cx) {
            Poll::Ready(Some((req, mut cb))) => {
                // check that future hasn't been canceled already
                match cb.poll_canceled(cx) {
                    Poll::Ready(()) => {
                        trace!("request canceled");
                        Poll::Ready(None)
                    }
                    Poll::Pending => {
                        let (parts, body) = req.into_parts();
                        let head = RequestHead {
                            version: parts.version,
                            subject: crate::proto::RequestLine(parts.method, parts.uri),
                            headers: parts.headers,
                            extensions: parts.extensions,
                        };
                        this.callback = Some(cb);
                        Poll::Ready(Some(Ok((head, body))))
                    }
                }
            }
            Poll::Ready(None) => {
                // user has dropped sender handle
                trace!("client tx closed");
                this.rx_closed = true;
                Poll::Ready(None)
            }
            Poll::Pending => Poll::Pending,
        }
    }

    fn recv_msg(
        &mut self,
        msg: crate::Result<(Self::RecvItem, IncomingBody)>,
    ) -> crate::Result<()> {
        match msg {
            Ok((msg, body)) => {
                if let Some(cb) = self.callback.take() {
                    let res = msg.into_response(body);
                    cb.send(Ok(res));
                    Ok(())
                } else {
                    // Getting here is likely a bug! An error should have happened
                    // in Conn::require_empty_read() before ever parsing a
                    // full message!
                    Err(crate::Error::new_unexpected_message())
                }
            }
            Err(err) => {
                if let Some(cb) = self.callback.take() {
                    cb.send(Err(TrySendError {
                        error: err,
                        message: None,
                    }));
                    Ok(())
                } else if !self.rx_closed {
                    self.rx.close();
                    if let Some((req, cb)) = self.rx.try_recv() {
                        trace!("canceling queued request with connection error: {}", err);
                        // in this case, the message was never even started, so it's safe to tell
                        // the user that the request was completely canceled
                        cb.send(Err(TrySendError {
                            error: crate::Error::new_canceled().with(err),
                            message: Some(req),
                        }));
                        Ok(())
                    } else {
                        Err(err)
                    }
                } else {
                    Err(err)
                }
            }
        }
    }

    fn poll_ready(&mut self, cx: &mut Context<'_>) -> Poll<Result<(), ()>> {
        match &mut self.callback {
            Some(cb) => match cb.poll_canceled(cx) {
                Poll::Ready(()) => {
                    trace!("callback receiver has dropped");
                    Poll::Ready(Err(()))
                }
                Poll::Pending => Poll::Ready(Ok(())),
            },
            None => Poll::Ready(Err(())),
        }
    }

    fn should_poll(&self) -> bool {
        self.callback.is_none()
    }

    fn poll_close(&mut self, cx: &mut Context<'_>) -> Poll<()> {
        self.rx.poll_close(cx)
    }
}

#[cfg(test)]
mod tests {
    use rama_core::ServiceInput;
    use tokio::io::{ReadBuf, join};
    use tokio::task::{coop, yield_now};

    use super::*;
    use crate::proto::h1::ClientTransaction;
    use std::cell::Cell;
    use std::future::poll_fn;
    use std::io;
    use std::rc::Rc;
    use std::time::Duration;

    #[derive(Clone, Copy)]
    enum ReadState {
        Pending,
        Response,
        Close,
        Done,
    }

    /// Consumes no coop budget, so the close is seen while the request queue yields.
    struct ClosingReader {
        state: Rc<Cell<ReadState>>,
        reset: bool,
    }

    impl AsyncRead for ClosingReader {
        fn poll_read(
            self: Pin<&mut Self>,
            _cx: &mut Context<'_>,
            buf: &mut ReadBuf<'_>,
        ) -> Poll<io::Result<()>> {
            match self.state.get() {
                ReadState::Pending => Poll::Pending,
                ReadState::Response => {
                    buf.put_slice(b"HTTP/1.1 200 OK\r\ncontent-length: 0\r\n\r\n");
                    self.state.set(ReadState::Pending);
                    Poll::Ready(Ok(()))
                }
                ReadState::Close => {
                    self.state.set(ReadState::Done);
                    if self.reset {
                        Poll::Ready(Err(io::ErrorKind::ConnectionReset.into()))
                    } else {
                        Poll::Ready(Ok(()))
                    }
                }
                ReadState::Done => panic!("closed IO must not be polled again"),
            }
        }
    }

    #[cfg(not(miri))]
    #[tokio::test]
    async fn client_close_cancels_requests_still_queued() {
        for (reset, should_shutdown) in [(true, true), (false, true), (false, false)] {
            let state = Rc::new(Cell::new(ReadState::Pending));
            let io = ServiceInput::new(join(
                ClosingReader {
                    state: state.clone(),
                    reset,
                },
                Vec::<u8>::new(),
            ));
            let (mut tx, rx) = crate::client::dispatch::channel();
            let conn = Conn::<_, Bytes, ClientTransaction>::new(io);
            let mut dispatcher = Dispatcher::new(Client::new(rx), conn);

            // Complete an exchange to put the connection into idle keep-alive.
            let first = tx.try_send(Request::new(IncomingBody::empty())).unwrap();
            let mut first = tokio_test::task::spawn(first);
            tokio_test::task::spawn(()).enter(|cx, _| {
                assert!(Pin::new(&mut dispatcher).poll(cx).is_pending());
                state.set(ReadState::Response);
                assert!(Pin::new(&mut dispatcher).poll(cx).is_pending());
            });
            tokio_test::assert_ready_ok!(first.poll()).unwrap();
            assert!(tx.is_ready());

            state.set(ReadState::Close);
            let req = Request::builder()
                .uri("/not-sent")
                .body(IncomingBody::empty())
                .unwrap();
            let promise = tx.try_send(req).unwrap();
            let closing = poll_fn(|cx| dispatcher.poll_catch(cx, should_shutdown));
            let mut closing = tokio_test::task::spawn(closing);

            // Out of coop budget even a closed queue reports Pending, as it does
            // for a send that began before the close and has yet to publish.
            poll_fn(|cx| {
                while let Poll::Ready(restore) = coop::poll_proceed(cx) {
                    restore.made_progress();
                }
                Poll::Ready(())
            })
            .await;
            assert!(
                closing.poll().is_pending(),
                "must finish draining before exiting"
            );
            assert!(tx.is_closed(), "must reject new requests while draining");

            // The result is kept while draining, rather than polling the closed IO again.
            yield_now().await;
            assert!(closing.is_woken());
            match tokio_test::assert_ready!(closing.poll()) {
                Err(err) if reset => assert_eq!(
                    err.find_source::<io::Error>().unwrap().kind(),
                    io::ErrorKind::ConnectionReset,
                ),
                Ok(Dispatched::Shutdown) if !reset => (),
                _ => panic!("unexpected result (reset = {reset})"),
            }

            // Both the sender and the dispatcher are alive: the cancel must not need a drop.
            let mut promise = tokio_test::task::spawn(promise);
            let mut err = tokio_test::assert_ready_ok!(promise.poll()).unwrap_err();
            assert!(err.error.is_canceled(), "{err:?}");
            assert_eq!(err.take_message().unwrap().uri().as_str(), "/not-sent");
            assert!(tx.is_closed());
        }
    }

    #[test]
    fn client_read_bytes_before_writing_request() {
        tokio_test::task::spawn(()).enter(|cx, _| {
            let (io, mut handle) = tokio_test::io::Builder::new().build_with_handle();
            let io = ServiceInput::new(io);

            // Block at 0 for now, but we will release this response before
            // the request is ready to write later...
            let (mut tx, rx) = crate::client::dispatch::channel();
            let conn = Conn::<_, rama_core::bytes::Bytes, ClientTransaction>::new(io);
            let mut dispatcher = Dispatcher::new(Client::new(rx), conn);

            // First poll is needed to allow tx to send...
            assert!(Pin::new(&mut dispatcher).poll(cx).is_pending());

            // Unblock our IO, which has a response before we've sent request!
            //
            handle.read(b"HTTP/1.1 200 OK\r\n\r\n");

            let mut res_rx = tx.try_send(Request::new(IncomingBody::empty())).unwrap();

            tokio_test::assert_ready_ok!(Pin::new(&mut dispatcher).poll(cx));
            let err = tokio_test::assert_ready_ok!(Pin::new(&mut res_rx).poll(cx))
                .expect_err("callback should send error");

            match (err.error.is_canceled(), err.message.as_ref()) {
                (true, Some(_)) => (),
                _ => panic!("expected Canceled, got {err:?}"),
            }
        });
    }

    #[cfg(not(miri))]
    #[tokio::test]
    async fn client_flushing_is_not_ready_for_next_request() {
        let (io, _handle) = tokio_test::io::Builder::new()
            .write(b"POST / HTTP/1.1\r\ncontent-length: 4\r\n\r\n")
            .read(b"HTTP/1.1 200 OK\r\ncontent-length: 0\r\n\r\n")
            .wait(std::time::Duration::from_secs(2))
            .build_with_handle();

        let io = ServiceInput::new(io);

        let (mut tx, rx) = crate::client::dispatch::channel();
        let mut conn = Conn::<_, rama_core::bytes::Bytes, ClientTransaction>::new(io);
        conn.set_write_strategy_queue();

        let dispatcher = Dispatcher::new(Client::new(rx), conn);
        let _dispatcher = tokio::spawn(dispatcher);

        let body = {
            let (mut tx, body) = IncomingBody::new_channel(DecodedLength::new(4), false);
            tx.try_send_data("reee".into()).unwrap();
            body
        };

        let req = Request::builder().method("POST").body(body).unwrap();

        let res = tx.try_send(req).unwrap().await.expect("response");
        drop(res);

        assert!(!tx.is_ready());
    }

    #[cfg(not(miri))]
    #[tokio::test]
    async fn body_empty_chunks_ignored() {
        let io = tokio_test::io::Builder::new()
            // no reading or writing, just be blocked for the test...
            .wait(Duration::from_secs(5))
            .build();

        let io = ServiceInput::new(io);

        let (mut tx, rx) = crate::client::dispatch::channel();
        let conn = Conn::<_, rama_core::bytes::Bytes, ClientTransaction>::new(io);
        let mut dispatcher = tokio_test::task::spawn(Dispatcher::new(Client::new(rx), conn));

        // First poll is needed to allow tx to send...
        assert!(dispatcher.poll().is_pending());

        let body = {
            let (mut tx, body) = IncomingBody::channel();
            tx.try_send_data("".into()).unwrap();
            body
        };

        let _res_rx = tx.try_send(Request::new(body)).unwrap();

        // Ensure conn.write_body wasn't called with the empty chunk.
        // If it is, it will trigger an assertion.
        assert!(dispatcher.poll().is_pending());
    }

    #[cfg(not(miri))]
    #[tokio::test]
    async fn lingering_obeys_exact_byte_allowance() {
        use crate::proto::h1::ServerTransaction;
        use rama_core::service::service_fn;
        use std::sync::{
            Arc,
            atomic::{AtomicUsize, Ordering},
        };

        struct Input {
            head: Option<Vec<u8>>,
            drained: Arc<AtomicUsize>,
        }
        impl AsyncRead for Input {
            fn poll_read(
                mut self: Pin<&mut Self>,
                _: &mut Context<'_>,
                buf: &mut tokio::io::ReadBuf<'_>,
            ) -> Poll<std::io::Result<()>> {
                if let Some(head) = self.head.take() {
                    buf.put_slice(&head);
                } else {
                    let n = buf.remaining();
                    buf.initialize_unfilled().fill(b'x');
                    buf.advance(n);
                    self.drained.fetch_add(n, Ordering::Relaxed);
                }
                Poll::Ready(Ok(()))
            }
        }
        impl AsyncWrite for Input {
            fn poll_write(
                self: Pin<&mut Self>,
                _: &mut Context<'_>,
                buf: &[u8],
            ) -> Poll<std::io::Result<usize>> {
                Poll::Ready(Ok(buf.len()))
            }
            fn poll_flush(self: Pin<&mut Self>, _: &mut Context<'_>) -> Poll<std::io::Result<()>> {
                Poll::Ready(Ok(()))
            }
            fn poll_shutdown(
                self: Pin<&mut Self>,
                _: &mut Context<'_>,
            ) -> Poll<std::io::Result<()>> {
                Poll::Ready(Ok(()))
            }
        }
        for buffered in [false, true] {
            let drained = Arc::new(AtomicUsize::new(0));
            let mut head = b"POST / HTTP/1.1\r\nhost: a\r\ncontent-length: 10000\r\n\r\n".to_vec();
            if buffered {
                head.extend_from_slice(&[b'x'; 64]);
            }
            let io = ServiceInput::new(Input {
                head: Some(head),
                drained: drained.clone(),
            });
            let mut conn = Conn::<_, Bytes, ServerTransaction>::new(io);
            std::future::poll_fn(|cx| conn.poll_read_head(cx))
                .await
                .unwrap()
                .unwrap();
            conn.close_read();
            conn.set_lingering_close(Some(LingeringClose::new().with_max_bytes(1)));
            let service = service_fn(|_req: Request<IncomingBody>| async {
                Ok::<_, Infallible>(Response::new(Body::empty()))
            });
            let mut dispatcher = Dispatcher::new(Server::new(service), conn);
            std::future::poll_fn(|cx| dispatcher.poll_linger(cx)).await;
            let (_, unread, _) = dispatcher.into_inner();
            if buffered {
                assert_eq!(
                    unread.len(),
                    63,
                    "discarded buffered input past the allowance"
                );
                assert_eq!(drained.load(Ordering::Relaxed), 0);
            } else {
                assert_eq!(
                    drained.load(Ordering::Relaxed),
                    1,
                    "read past the allowance"
                );
            }
        }
    }
    // Regression for #1014: when a server connection ends via a dispatch error,
    // the dispatcher must still drive `poll_shutdown` on the transport (so e.g.
    // a TLS stream emits close_notify) instead of dropping it mid-flight.
    #[cfg(not(miri))]
    #[tokio::test]
    async fn server_drives_shutdown_on_dispatch_error() {
        use crate::proto::h1::ServerTransaction;
        use rama_core::service::service_fn;
        use std::convert::Infallible;
        use std::io;
        use std::pin::Pin;
        use std::sync::Arc;
        use std::sync::atomic::{AtomicBool, Ordering};
        use std::task::{Context, Poll};
        use tokio::io::{AsyncRead, AsyncWrite, ReadBuf};

        struct RecordIo {
            // a valid request on the first read, then a hard error on the next.
            request: Option<&'static [u8]>,
            shutdown_called: Arc<AtomicBool>,
        }

        impl AsyncRead for RecordIo {
            fn poll_read(
                mut self: Pin<&mut Self>,
                _cx: &mut Context<'_>,
                buf: &mut ReadBuf<'_>,
            ) -> Poll<io::Result<()>> {
                match self.request.take() {
                    Some(req) => {
                        buf.put_slice(req);
                        Poll::Ready(Ok(()))
                    }
                    // mid-connection transport failure on the next (keep-alive) read.
                    None => Poll::Ready(Err(io::Error::other("boom"))),
                }
            }
        }

        impl AsyncWrite for RecordIo {
            fn poll_write(
                self: Pin<&mut Self>,
                _cx: &mut Context<'_>,
                buf: &[u8],
            ) -> Poll<io::Result<usize>> {
                // sink the response write
                Poll::Ready(Ok(buf.len()))
            }
            fn poll_flush(self: Pin<&mut Self>, _cx: &mut Context<'_>) -> Poll<io::Result<()>> {
                Poll::Ready(Ok(()))
            }
            fn poll_shutdown(self: Pin<&mut Self>, _cx: &mut Context<'_>) -> Poll<io::Result<()>> {
                self.shutdown_called.store(true, Ordering::SeqCst);
                Poll::Ready(Ok(()))
            }
        }

        let shutdown_called = Arc::new(AtomicBool::new(false));
        let io = RecordIo {
            request: Some(b"GET / HTTP/1.1\r\nhost: a\r\n\r\n"),
            shutdown_called: shutdown_called.clone(),
        };
        let io = ServiceInput::new(io);

        let service = service_fn(|_req: Request<IncomingBody>| async move {
            Ok::<_, Infallible>(Response::new(Body::empty()))
        });

        let conn = Conn::<_, rama_core::bytes::Bytes, ServerTransaction>::new(io);
        let dispatcher = Dispatcher::new(Server::new(service), conn);

        let result = dispatcher.await;

        assert!(
            result.is_err(),
            "an errored connection should surface its error"
        );
        assert!(
            shutdown_called.load(Ordering::SeqCst),
            "poll_shutdown must be driven on the dispatch error path (regression #1014)"
        );
    }
}
