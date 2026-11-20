use std::fmt;
use std::io;
use std::marker::{PhantomData, Unpin};
use std::pin::Pin;
use std::task::{Context, Poll, ready};

use httparse::ParserConfig;
use rama_core::bytes::{Buf, Bytes};
use rama_core::extensions::{Extensions, ExtensionsRef, Ingress};
use rama_core::telemetry::tracing;
use rama_core::telemetry::tracing::{debug, error, trace};
use rama_http::io::upgrade;
use rama_http_types::body::Frame;
use rama_http_types::header::CONNECTION;
use rama_http_types::proto::h1::ext::{ConnectionClose, informational::OnInformational};
use rama_http_types::{HeaderMap, HeaderValue, Method, Version};
use rama_net::conn::{ConnectionHealthWatcher, LingeringClose, MaxConcurrency};
use tokio::io::{AsyncRead, AsyncWrite};

use super::io::Buffered;
use super::{Decoder, Encode, EncodedBuf, Encoder, Http1Transaction, ParseContext, Wants};
use crate::{
    body::DecodedLength,
    headers,
    proto::{BodyLength, MessageHead, h1::EncodeHead},
    server::conn::timeout::{Activity, ConnTimer, Expired},
};

const H2_PREFACE: &[u8] = b"PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n";

/// This handles a connection, which will have been established over an
/// `Read + Write` (like a socket), and will likely include multiple
/// `Transaction`s over HTTP.
///
/// The connection will determine when a message begins and ends as well as
/// determine if this connection can be kept alive after the message,
/// or if it is complete.
pub(crate) struct Conn<I, B, T> {
    io: Buffered<I, EncodedBuf<B>>,
    state: State,
    _marker: PhantomData<fn(T)>,
}

impl<I, B, T> Conn<I, B, T>
where
    I: AsyncRead + AsyncWrite + Unpin + ExtensionsRef,
    B: Buf,
    T: Http1Transaction,
{
    pub(crate) fn new(io: I) -> Self {
        ConnectionHealthWatcher::install(io.extensions());
        io.extensions().insert(MaxConcurrency::new(1));

        Self {
            io: Buffered::new(io),
            state: State {
                allow_half_close: false,
                lingering_close: None,
                read_abandoned: false,
                error: None,
                keep_alive: KA::Busy,
                method: None,
                h1_parser_config: ParserConfig::default(),
                h1_max_headers: None,
                h1_max_header_size: None,
                timer: ConnTimer::new(None, None),
                date_header: true,
                strict_connect_framing: false,
                title_case_headers: false,
                h09_responses: false,
                on_informational: None,
                notify_read: false,
                reading: Reading::Init,
                writing: Writing::Init,
                encoded_request_extensions: None,
                upgrade: None,
                // We assume a modern world where the remote speaks HTTP/1.1.
                // If they tell us otherwise, we'll downgrade in `read_head`.
                version: Version::HTTP_11,
                allow_trailer_fields: false,
                trailer_forbidden: Default::default(),
            },
            _marker: PhantomData,
        }
    }

    pub(crate) fn set_flush_pipeline(&mut self, enabled: bool) {
        self.io.set_flush_pipeline(enabled);
    }

    pub(crate) fn set_write_strategy_queue(&mut self) {
        self.io.set_write_strategy_queue();
    }

    pub(crate) fn set_max_buf_size(&mut self, max: usize) {
        self.io.set_max_buf_size(max);
    }

    pub(crate) fn set_read_buf_exact_size(&mut self, sz: usize) {
        self.io.set_read_buf_exact_size(sz);
    }

    pub(crate) fn set_write_strategy_flatten(&mut self) {
        self.io.set_write_strategy_flatten();
    }

    pub(crate) fn set_h1_parser_config(&mut self, parser_config: ParserConfig) {
        self.state.h1_parser_config = parser_config;
    }

    pub(crate) fn set_title_case_headers(&mut self) {
        self.state.title_case_headers = true;
    }

    pub(crate) fn set_h09_responses(&mut self) {
        self.state.h09_responses = true;
    }

    pub(crate) fn set_http1_max_headers(&mut self, val: usize) {
        self.state.h1_max_headers = Some(val);
    }

    pub(crate) fn set_http1_max_header_size(&mut self, val: usize) {
        self.state.h1_max_header_size = Some(val);
    }

    pub(crate) fn set_timer(&mut self, timer: ConnTimer) {
        self.state.timer = timer;
    }

    pub(crate) fn set_allow_half_close(&mut self) {
        self.state.allow_half_close = true;
    }

    pub(crate) fn set_lingering_close(&mut self, linger: Option<LingeringClose>) {
        self.state.lingering_close = linger;
    }

    pub(crate) fn lingering_close(&self) -> Option<LingeringClose> {
        self.state.lingering_close
    }

    /// Whether the peer ended its stream or reading from it failed, so it
    /// sends nothing more.
    pub(crate) fn is_peer_read_finished(&self) -> bool {
        self.io.is_read_finished()
    }

    /// Whether input was left unread: an abandoned request body, the rest of
    /// a rejected request, or bytes already buffered, such as a pipelined
    /// request.
    pub(crate) fn left_input_unread(&self) -> bool {
        self.state.read_abandoned || !self.io.read_buf().is_empty()
    }

    /// Whether a request was left unread: an abandoned body, or the rest of
    /// a rejected request that is being answered.
    pub(crate) fn is_read_abandoned(&self) -> bool {
        self.state.read_abandoned
    }

    /// Read and drop input. Returns how many bytes were dropped, or 0 once
    /// the peer ended its stream.
    pub(crate) fn poll_discard_read(
        &mut self,
        cx: &mut Context<'_>,
        max: usize,
    ) -> Poll<io::Result<usize>> {
        let buffered = self.io.discard_read_buf(max);
        self.io.read_to_discard();
        if buffered > 0 {
            return Poll::Ready(Ok(buffered));
        }
        let read = ready!(self.io.poll_read_from_io_limited(cx, max))?;
        Poll::Ready(Ok(self.io.discard_read_buf(max).max(read)))
    }

    pub(crate) fn disable_date_header(&mut self) {
        self.state.date_header = false;
    }

    pub(crate) fn set_strict_connect_framing(&mut self) {
        self.state.strict_connect_framing = true;
    }

    pub(crate) fn into_inner(self) -> (I, Bytes) {
        self.io.into_inner()
    }

    pub(crate) fn has_pending_upgrade(&self) -> bool {
        self.state.upgrade.is_some()
    }

    pub(crate) fn pending_upgrade(&mut self) -> Option<upgrade::Pending> {
        self.state.upgrade.take()
    }

    pub(crate) fn is_read_closed(&self) -> bool {
        self.state.is_read_closed()
    }

    pub(crate) fn is_write_closed(&self) -> bool {
        self.state.is_write_closed()
    }

    pub(crate) fn can_read_head(&self) -> bool {
        if !matches!(self.state.reading, Reading::Init) {
            return false;
        }

        if T::should_read_first() {
            return true;
        }

        !matches!(self.state.writing, Writing::Init)
    }

    pub(crate) fn can_read_body(&self) -> bool {
        matches!(
            self.state.reading,
            Reading::Body(..) | Reading::Continue(..)
        )
    }

    pub(crate) fn has_initial_read_write_state(&self) -> bool {
        matches!(self.state.reading, Reading::Init)
            && matches!(self.state.writing, Writing::Init)
            && self.io.read_buf().is_empty()
    }

    fn should_error_on_eof(&self) -> bool {
        // If we're idle, it's probably just the connection closing gracefully.
        T::should_error_on_parse_eof() && !self.state.is_idle()
    }

    fn has_h2_prefix(&self) -> bool {
        let read_buf = self.io.read_buf();
        read_buf.len() >= 24 && read_buf[..24] == *H2_PREFACE
    }

    pub(super) fn poll_read_head(
        &mut self,
        cx: &mut Context<'_>,
    ) -> Poll<Option<crate::Result<(MessageHead<T::Incoming>, DecodedLength, Wants)>>> {
        debug_assert!(self.can_read_head());
        trace!("Conn::read_head");

        if self
            .state
            .timer
            .head_elapsed(self.io.read_buf().len() as u64)
        {
            debug!("request head deadline elapsed");
            return Poll::Ready(Some(Err(crate::Error::new_header_timeout())));
        }

        let prepared = if T::is_client() {
            // Client receiving a response
            // Client receiving a response
            self.state.encoded_request_extensions
                    .as_ref()
                    .map(|req_ext| req_ext.fork())
                    .unwrap_or_else(|| {
                        tracing::warn!(
                            "encoded_request_extensions should always be set in poll_read_head but it was missing; falling back to default; report bug in rama"
                        );
                        Extensions::new()
                    })
        } else {
            // Server receiving a request
            let ext = Extensions::new();
            ext.insert(Ingress(self.io.extensions().clone()));
            ext
        };
        let mut prepared_extensions = Some(prepared);

        let msg = match self.io.parse::<T>(
            cx,
            ParseContext {
                req_method: &mut self.state.method,
                h1_parser_config: self.state.h1_parser_config.clone(),
                h1_max_headers: self.state.h1_max_headers,
                h1_max_header_size: self.state.h1_max_header_size,
                h09_responses: self.state.h09_responses,
                on_informational: &mut self.state.on_informational,
                prepared_extensions: &mut prepared_extensions,
            },
        ) {
            Poll::Ready(Ok(msg)) => msg,
            Poll::Ready(Err(e)) => return self.on_read_head_error(e),
            Poll::Pending => {
                let bytes = self.io.read_buf().len() as u64;
                let activity = if bytes == 0 {
                    Activity::Idle
                } else {
                    Activity::Head { bytes, block: 0 }
                };
                return match self.state.timer.poll(cx, activity) {
                    Poll::Pending => Poll::Pending,
                    Poll::Ready(Expired::Head) => {
                        debug!("request head deadline elapsed");
                        Poll::Ready(Some(Err(crate::Error::new_header_timeout())))
                    }
                    Poll::Ready(Expired::Idle | Expired::Drain) => {
                        // An idle close is a clean end of the connection, as an EOF is.
                        debug!("idle deadline elapsed, closing");
                        self.close_read();
                        self.close_write();
                        Poll::Ready(None)
                    }
                };
            }
        };

        self.state.timer.request_received();

        if !msg.keep_alive {
            msg.head.extensions.insert(ConnectionClose);
        }

        // Note: don't deconstruct `msg` into local variables, it appears
        // the optimizer doesn't remove the extra copies.

        debug!("incoming body is {}", msg.decode);

        // Prevent accepting HTTP/0.9 responses after the initial one, if any.
        self.state.h09_responses = false;

        // Drop any OnInformational callbacks, we're done there!
        self.state.on_informational = None;

        self.state.busy();
        self.state.keep_alive &= msg.keep_alive;
        self.state.version = msg.head.version;

        let mut wants = if msg.wants_upgrade {
            Wants::UPGRADE
        } else {
            Wants::EMPTY
        };

        if msg.decode == DecodedLength::ZERO {
            if msg.expect_continue {
                debug!("ignoring expect-continue since body is empty");
            }
            self.state.reading = Reading::KeepAlive;
            if !T::should_read_first() {
                self.try_keep_alive(cx);
            }
        } else if msg.expect_continue && msg.head.version.gt(&Version::HTTP_10) {
            self.state.reading = Reading::Continue(Decoder::new(
                msg.decode,
                self.state.h1_max_headers,
                self.state.h1_max_header_size,
            ));
            wants = wants.add(Wants::EXPECT);
        } else {
            self.state.reading = Reading::Body(Decoder::new(
                msg.decode,
                self.state.h1_max_headers,
                self.state.h1_max_header_size,
            ));
        }

        self.state.allow_trailer_fields = headers::te_is_trailers(&msg.head.headers);
        self.state.trailer_forbidden = headers::connection_header_names(&msg.head.headers);

        Poll::Ready(Some(Ok((msg.head, msg.decode, wants))))
    }

    fn on_read_head_error<Z>(&mut self, e: crate::Error) -> Poll<Option<crate::Result<Z>>> {
        // If we are currently waiting on a message, then an empty
        // message should be reported as an error. If not, it is just
        // the connection closing gracefully.
        let must_error = self.should_error_on_eof();
        self.close_read();
        self.io.consume_leading_lines();
        let was_mid_parse = e.is_parse() || !self.io.read_buf().is_empty();
        if was_mid_parse || must_error {
            // We check if the buf contains the h2 Preface
            debug!(
                "parse error ({}) with {} bytes",
                e,
                self.io.read_buf().len()
            );
            match self.on_parse_error(e) {
                Ok(()) => Poll::Pending, // XXX: wat?
                Err(e) => Poll::Ready(Some(Err(e))),
            }
        } else {
            debug!("read eof");
            self.close_write();
            Poll::Ready(None)
        }
    }

    pub(crate) fn poll_read_body(
        &mut self,
        cx: &mut Context<'_>,
    ) -> Poll<Option<io::Result<Frame<Bytes>>>> {
        debug_assert!(self.can_read_body());

        let (reading, ret) = match &mut self.state.reading {
            Reading::Body(decoder) => {
                match ready!(decoder.decode(cx, &mut self.io)) {
                    Ok(frame) => {
                        if frame.is_data() {
                            let slice = frame.data_ref().unwrap_or_else(|| unreachable!());
                            let (reading, maybe_frame) = if decoder.is_eof() {
                                debug!("incoming body completed");
                                (
                                    Reading::KeepAlive,
                                    if !slice.is_empty() {
                                        Some(Ok(frame))
                                    } else {
                                        None
                                    },
                                )
                            } else if slice.is_empty() {
                                error!("incoming body unexpectedly ended");
                                // This should be unreachable, since all 3 decoders
                                // either set eof=true or return an Err when reading
                                // an empty slice...
                                (Reading::Closed, None)
                            } else {
                                return Poll::Ready(Some(Ok(frame)));
                            };
                            (reading, Poll::Ready(maybe_frame))
                        } else if frame.is_trailers() {
                            debug!("incoming body completed with trailers");
                            let Ok(mut trailers) = frame.into_trailers() else {
                                unreachable!("a trailer frame must contain trailers")
                            };
                            for name in &self.state.trailer_forbidden {
                                trailers.remove(name);
                            }
                            (
                                Reading::KeepAlive,
                                Poll::Ready(Some(Ok(Frame::trailers(trailers)))),
                            )
                        } else {
                            trace!("discarding unknown frame");
                            (Reading::Closed, Poll::Ready(None))
                        }
                    }
                    Err(e) => {
                        debug!("incoming body decode error: {}", e);
                        // The client may still be sending the rest of it.
                        self.state.read_abandoned = true;
                        (Reading::Closed, Poll::Ready(Some(Err(e))))
                    }
                }
            }
            Reading::Continue(decoder) => {
                // Write the 100 Continue if not already responded...
                if matches!(self.state.writing, Writing::Init) {
                    trace!("automatically sending 100 Continue");
                    let cont = b"HTTP/1.1 100 Continue\r\n\r\n";
                    self.io.headers_buf().extend_from_slice(cont);
                }

                // And now recurse once in the Reading::Body state...
                self.state.reading = Reading::Body(decoder.clone());
                return self.poll_read_body(cx);
            }
            Reading::Closed | Reading::KeepAlive | Reading::Init => {
                unreachable!("poll_read_body invalid state: {:?}", self.state.reading)
            }
        };

        self.state.reading = reading;
        self.try_keep_alive(cx);
        ret
    }

    pub(crate) fn wants_read_again(&mut self) -> bool {
        let ret = self.state.notify_read;
        self.state.notify_read = false;
        ret
    }

    pub(crate) fn poll_read_keep_alive(&mut self, cx: &mut Context<'_>) -> Poll<crate::Result<()>> {
        debug_assert!(!self.can_read_head() && !self.can_read_body());

        if self.is_read_closed() {
            Poll::Pending
        } else if self.is_mid_message() {
            self.mid_message_detect_eof(cx)
        } else {
            self.require_empty_read(cx)
        }
    }

    fn is_mid_message(&self) -> bool {
        !matches!(
            (&self.state.reading, &self.state.writing),
            (&Reading::Init, &Writing::Init)
        )
    }

    // This will check to make sure the io object read is empty.
    //
    // This should only be called for Clients wanting to enter the idle
    // state.
    fn require_empty_read(&mut self, cx: &mut Context<'_>) -> Poll<crate::Result<()>> {
        debug_assert!(!self.can_read_head() && !self.can_read_body() && !self.is_read_closed());
        debug_assert!(!self.is_mid_message());
        debug_assert!(T::is_client());

        if !self.io.read_buf().is_empty() {
            debug!("received an unexpected {} bytes", self.io.read_buf().len());
            return Poll::Ready(Err(crate::Error::new_unexpected_message()));
        }

        let num_read = ready!(self.force_io_read(cx)).map_err(crate::Error::new_io)?;

        if num_read == 0 {
            let ret = if self.should_error_on_eof() {
                trace!("found unexpected EOF on busy connection: {:?}", self.state);
                Poll::Ready(Err(crate::Error::new_incomplete()))
            } else {
                trace!("found EOF on idle connection, closing");
                Poll::Ready(Ok(()))
            };

            // order is important: should_error needs state BEFORE close_read
            self.state.close_read();
            return ret;
        }

        debug!(
            "received unexpected {} bytes on an idle connection",
            num_read
        );
        Poll::Ready(Err(crate::Error::new_unexpected_message()))
    }

    fn mid_message_detect_eof(&mut self, cx: &mut Context<'_>) -> Poll<crate::Result<()>> {
        debug_assert!(!self.can_read_head() && !self.can_read_body() && !self.is_read_closed());
        debug_assert!(self.is_mid_message());

        if self.state.allow_half_close || !self.io.read_buf().is_empty() {
            return Poll::Pending;
        }

        let num_read = ready!(self.force_io_read(cx)).map_err(crate::Error::new_io)?;

        if num_read == 0 {
            trace!("found unexpected EOF on busy connection: {:?}", self.state);
            self.state.close_read();
            Poll::Ready(Err(crate::Error::new_incomplete()))
        } else {
            Poll::Ready(Ok(()))
        }
    }

    fn force_io_read(&mut self, cx: &mut Context<'_>) -> Poll<io::Result<usize>> {
        debug_assert!(!self.state.is_read_closed());

        let result = ready!(self.io.poll_read_from_io(cx));
        Poll::Ready(result.map_err(|e| {
            trace!("force_io_read; io error: {e:?}");
            self.state.close();
            e
        }))
    }

    fn maybe_notify(&mut self, cx: &mut Context<'_>) {
        // its possible that we returned NotReady from poll() without having
        // exhausted the underlying Io. We would have done this when we
        // determined we couldn't keep reading until we knew how writing
        // would finish.

        match self.state.reading {
            Reading::Continue(..) | Reading::Body(..) | Reading::KeepAlive | Reading::Closed => {
                return;
            }
            Reading::Init => (),
        }

        match self.state.writing {
            Writing::Body(..) => return,
            Writing::Init | Writing::KeepAlive | Writing::Closed => (),
        }

        if !self.io.is_read_blocked() {
            if self.io.read_buf().is_empty() {
                match self.io.poll_read_from_io(cx) {
                    Poll::Ready(Ok(n)) => {
                        if n == 0 {
                            trace!("maybe_notify; read eof");
                            if self.state.is_idle() {
                                self.state.close();
                            } else {
                                self.close_read();
                            }
                            return;
                        }
                    }
                    Poll::Pending => {
                        trace!("maybe_notify; read_from_io blocked");
                        return;
                    }
                    Poll::Ready(Err(e)) => {
                        trace!("maybe_notify; read_from_io error: {}", e);
                        self.state.close();
                        self.state.error = Some(crate::Error::new_io(e));
                    }
                }
            }
            self.state.notify_read = true;
        }
    }

    fn try_keep_alive(&mut self, cx: &mut Context<'_>) {
        self.state.try_keep_alive::<T>();
        self.maybe_notify(cx);
    }

    pub(crate) fn can_write_head(&self) -> bool {
        if !T::should_read_first() && matches!(self.state.reading, Reading::Closed) {
            return false;
        }

        match self.state.writing {
            Writing::Init => self.io.can_headers_buf(),
            Writing::Body(_) | Writing::KeepAlive | Writing::Closed => false,
        }
    }

    pub(crate) fn can_write_body(&self) -> bool {
        match self.state.writing {
            Writing::Body(..) => true,
            Writing::Init | Writing::KeepAlive | Writing::Closed => false,
        }
    }

    pub(crate) fn can_buffer_body(&self) -> bool {
        self.io.can_buffer()
    }

    /// Whether bytes are sitting in the write buffer waiting to be flushed.
    pub(crate) fn has_buffered_write(&self) -> bool {
        self.io.has_buffered_write()
    }

    pub(crate) fn write_head(&mut self, head: MessageHead<T::Outgoing>, body: Option<BodyLength>) {
        let accepts_upgrade = T::accepts_upgrade(&head.subject, self.state.method.as_ref());
        if let Some(encoder) = self.encode_head(head, body) {
            if T::is_server() && !accepts_upgrade {
                // A request only proposes an upgrade. Reject its promise when
                // the response stays HTTP, including on a reusable connection.
                self.state.upgrade = None;
            }
            self.state.writing = if !encoder.is_eof() {
                Writing::Body(encoder)
            } else if encoder.is_last() {
                Writing::Closed
            } else {
                Writing::KeepAlive
            };
        }
    }

    fn encode_head(
        &mut self,
        mut head: MessageHead<T::Outgoing>,
        body: Option<BodyLength>,
    ) -> Option<Encoder> {
        debug_assert!(self.can_write_head());

        if !T::should_read_first() {
            self.state.busy();
            // A client request carrying `Connection: close` must not be pooled or
            // reused. hyper otherwise derives connection reuse from the response
            // alone, so a backend that ignores the request-side close (omits
            // `Connection: close` in its response) would leave the connection in
            // the pool. Disable keep-alive up front so the connection is evicted
            // regardless of the response. Propagate the same transport state via
            // the request extensions copied onto the corresponding response.
            if headers::connection_any_close(&head.headers) {
                self.state.disable_keep_alive();
                head.extensions.insert(ConnectionClose);
            }
        }

        self.enforce_version(&mut head);

        let buf = self.io.headers_buf();
        match super::role::encode_headers::<T>(
            Encode {
                head: EncodeHead {
                    version: head.version,
                    subject: head.subject,
                    headers: head.headers,
                    extensions: &mut head.extensions,
                },
                body,
                keep_alive: self.state.wants_keep_alive(),
                req_method: &mut self.state.method,
                title_case_headers: self.state.title_case_headers,
                date_header: self.state.date_header,
                strict_connect_framing: self.state.strict_connect_framing,
            },
            buf,
        ) {
            Ok(encoder) => {
                self.state.on_informational = head.extensions.get_ref::<OnInformational>().cloned();
                self.state.encoded_request_extensions = Some(head.extensions);
                Some(encoder)
            }
            Err(err) => {
                self.state.error = Some(err);
                self.state.writing = Writing::Closed;
                None
            }
        }
    }

    // Fix keep-alive when Connection: keep-alive header is not present
    fn fix_keep_alive(&mut self, head: &mut MessageHead<T::Outgoing>) {
        // A `close` option wins over any `keep-alive` one.
        if headers::connection_any_close(&head.headers) {
            self.state.disable_keep_alive();
            return;
        }
        if headers::connection_any_keep_alive(&head.headers) {
            return;
        }
        match head.version {
            // If response is version 1.0 and keep-alive is not present in the response,
            // disable keep-alive so the server closes the connection
            Version::HTTP_10 => self.state.disable_keep_alive(),
            // If response is version 1.1 and keep-alive is wanted, add
            // Connection: keep-alive, keeping the hop-by-hop fields it nominates.
            Version::HTTP_11 if self.state.wants_keep_alive() => {
                head.headers
                    .append(CONNECTION, HeaderValue::from_static("keep-alive"));
            }
            _ => (),
        }
    }

    // If we know the remote speaks an older version, we try to fix up any messages
    // to work with our older peer.
    fn enforce_version(&mut self, head: &mut MessageHead<T::Outgoing>) {
        match self.state.version {
            Version::HTTP_10 => {
                // Fixes response or connection when keep-alive header is not present
                self.fix_keep_alive(head);
                // If the remote only knows HTTP/1.0, we should force ourselves
                // to do only speak HTTP/1.0 as well.
                head.version = Version::HTTP_10;
            }
            Version::HTTP_11 => {
                if matches!(self.state.keep_alive.status(), KA::Disabled) {
                    headers::connection_set_close(&mut head.headers);
                }
            }
            _ => (),
        }
        // If the remote speaks HTTP/1.1, then it *should* be fine with
        // both HTTP/1.0 and HTTP/1.1 from us. So again, we just let
        // the user's headers be.
    }

    pub(crate) fn write_body(&mut self, chunk: B) {
        debug_assert!(self.can_write_body() && self.can_buffer_body());
        // empty chunks should be discarded at Dispatcher level
        debug_assert!(chunk.remaining() != 0);

        let state = match &mut self.state.writing {
            Writing::Body(encoder) => {
                self.io.buffer(encoder.encode(chunk));

                if !encoder.is_eof() {
                    return;
                }

                if encoder.is_last() {
                    Writing::Closed
                } else {
                    Writing::KeepAlive
                }
            }
            _ => unreachable!("write_body invalid state: {:?}", self.state.writing),
        };

        self.state.writing = state;
    }

    pub(crate) fn write_trailers(&mut self, trailers: &HeaderMap) {
        if T::is_server() && !self.state.allow_trailer_fields {
            debug!("trailers not allowed to be sent");
            return;
        }
        debug_assert!(self.can_write_body() && self.can_buffer_body());

        match &mut self.state.writing {
            Writing::Body(encoder) => {
                if let Some(enc_buf) =
                    encoder.encode_trailers(trailers, self.state.title_case_headers)
                {
                    self.io.buffer(enc_buf);

                    self.state.writing = if encoder.is_last() || encoder.is_close_delimited() {
                        Writing::Closed
                    } else {
                        Writing::KeepAlive
                    };
                }
            }
            Writing::Closed | Writing::KeepAlive | Writing::Init => {
                unreachable!("write_trailers invalid state: {:?}", self.state.writing)
            }
        }
    }

    pub(crate) fn write_body_and_end(&mut self, chunk: B) {
        debug_assert!(self.can_write_body() && self.can_buffer_body());
        // empty chunks should be discarded at Dispatcher level
        debug_assert!(chunk.remaining() != 0);

        let state = match &mut self.state.writing {
            Writing::Body(encoder) => {
                let can_keep_alive = encoder.encode_and_end(chunk, self.io.write_buf());
                if can_keep_alive {
                    Writing::KeepAlive
                } else {
                    Writing::Closed
                }
            }
            Writing::Closed | Writing::KeepAlive | Writing::Init => {
                unreachable!("write_body invalid state: {:?}", self.state.writing)
            }
        };

        self.state.writing = state;
    }

    pub(crate) fn end_body(&mut self) -> crate::Result<()> {
        debug_assert!(self.can_write_body());

        let Writing::Body(encoder) = &mut self.state.writing else {
            return Ok(());
        };

        // end of stream, that means we should try to eof
        match encoder.end() {
            Ok(end) => {
                if let Some(end) = end {
                    self.io.buffer(end);
                }

                self.state.writing = if encoder.is_last() || encoder.is_close_delimited() {
                    Writing::Closed
                } else {
                    Writing::KeepAlive
                };

                Ok(())
            }
            Err(not_eof) => {
                self.state.writing = Writing::Closed;
                Err(crate::Error::new_body_write_aborted().with(not_eof))
            }
        }
    }

    // When we get a parse error, depending on what side we are, we might be able
    // to write a response before closing the connection.
    //
    // - Client: there is nothing we can do
    // - Server: if Response hasn't been written yet, we can send a 4xx response
    fn on_parse_error(&mut self, err: crate::Error) -> crate::Result<()> {
        if matches!(self.state.writing, Writing::Init) {
            if self.has_h2_prefix() {
                return Err(crate::Error::new_version_h2());
            }
            if let Some(msg) = T::on_error(&err) {
                // The client may still be sending the rest of what was
                // rejected, even when the whole head was already read.
                self.state.read_abandoned = true;
                self.write_head(msg, None);
                self.state.error = Some(err);
                return Ok(());
            }
        } else if err.is_parse() {
            // A response is going out while the client still sends.
            self.state.read_abandoned = true;
        }

        // fallback is pass the error back up
        Err(err)
    }

    pub(crate) fn poll_flush(&mut self, cx: &mut Context<'_>) -> Poll<io::Result<()>> {
        ready!(Pin::new(&mut self.io).poll_flush(cx))?;
        self.try_keep_alive(cx);
        trace!("flushed({}): {:?}", T::LOG, self.state);
        Poll::Ready(Ok(()))
    }

    pub(crate) fn poll_shutdown(&mut self, cx: &mut Context<'_>) -> Poll<io::Result<()>> {
        self.io
            .extensions()
            .get_ref_or_insert(ConnectionHealthWatcher::default)
            .mark_broken();

        match ready!(self.io.poll_shutdown(cx)) {
            Ok(()) => {
                trace!("shut down IO complete");
                Poll::Ready(Ok(()))
            }
            Err(e) => {
                debug!("error shutting down IO: {}", e);
                Poll::Ready(Err(e))
            }
        }
    }

    pub(crate) fn abort(&self) {
        if let Some(abort) = self
            .io
            .extensions()
            .self_get_ref::<rama_core::io::AbortIo>()
        {
            abort.abort();
        }
    }

    /// If the read side can be cheaply drained, do so. Otherwise, close.
    pub(super) fn poll_drain_or_close_read(&mut self, cx: &mut Context<'_>) {
        if let Reading::Continue(decoder) = &mut self.state.reading {
            // skip sending the 100-continue
            // just move forward to a read, in case a tiny body was included
            self.state.reading = Reading::Body(decoder.clone());
        }

        _ = self.poll_read_body(cx);

        // If still in Reading::Body, just give up
        match self.state.reading {
            Reading::Init | Reading::KeepAlive => {
                trace!("body drained")
            }
            _ => self.close_read(),
        }
    }

    pub(crate) fn close_read(&mut self) {
        self.state.close_read();
    }

    pub(crate) fn close_write(&mut self) {
        self.state.close_write();
    }

    pub(crate) fn disable_keep_alive(&mut self) {
        if self.state.is_idle() {
            trace!("disable_keep_alive; closing idle connection");
            self.state.close();
        } else {
            trace!("disable_keep_alive; in-progress connection");
            self.state.disable_keep_alive();
        }
    }

    pub(crate) fn take_error(&mut self) -> crate::Result<()> {
        if let Some(err) = self.state.error.take() {
            Err(err)
        } else {
            Ok(())
        }
    }

    pub(super) fn on_upgrade(&mut self) -> upgrade::OnUpgrade {
        trace!("{}: prepare possible HTTP upgrade", T::LOG);
        self.state.prepare_upgrade()
    }
}

impl<I, B: Buf, T> fmt::Debug for Conn<I, B, T> {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("Conn")
            .field("state", &self.state)
            .field("io", &self.io)
            .finish()
    }
}

// B and T are never pinned
impl<I: Unpin, B, T> Unpin for Conn<I, B, T> {}

struct State {
    allow_half_close: bool,
    /// How long to keep reading and discarding after shutting down, if at
    /// all. Only the server lingers.
    lingering_close: Option<LingeringClose>,
    /// Input was left unread when reading was closed: a request body, or
    /// the rest of a rejected request.
    read_abandoned: bool,
    /// If an error occurs when there wasn't a direct way to return it
    /// back to the user, this is set.
    error: Option<crate::Error>,
    /// Current keep-alive status.
    keep_alive: KA,
    /// If mid-message, the HTTP Method that started it.
    ///
    /// This is used to know things such as if the message can include
    /// a body or not.
    method: Option<Method>,
    h1_parser_config: ParserConfig,
    h1_max_headers: Option<usize>,
    h1_max_header_size: Option<usize>,
    timer: ConnTimer,
    date_header: bool,
    strict_connect_framing: bool,
    title_case_headers: bool,
    h09_responses: bool,
    /// If set, called with each 1xx informational response received for
    /// the current request. MUST be unset after a non-1xx response is
    /// received.
    on_informational: Option<OnInformational>,
    /// Set to true when the Dispatcher should poll read operations
    /// again. See the `maybe_notify` method for more.
    notify_read: bool,
    /// State of allowed reads.
    reading: Reading,
    /// State of allowed writes.
    writing: Writing,
    /// Last known request extensions encoded
    encoded_request_extensions: Option<rama_core::extensions::Extensions>,
    /// An expected pending HTTP upgrade.
    upgrade: Option<upgrade::Pending>,
    /// Either HTTP/1.0 or 1.1 connection.
    version: Version,
    /// Flag to track if trailer fields are allowed to be sent.
    allow_trailer_fields: bool,
    /// Fields nominated by the current inbound message's `Connection` values.
    trailer_forbidden: headers::ConnectionHeaderNames,
}

#[derive(Debug)]
enum Reading {
    Init,
    Continue(Decoder),
    Body(Decoder),
    KeepAlive,
    Closed,
}

enum Writing {
    Init,
    Body(Encoder),
    KeepAlive,
    Closed,
}

impl fmt::Debug for State {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        let mut builder = f.debug_struct("State");
        builder
            .field("reading", &self.reading)
            .field("writing", &self.writing)
            .field("keep_alive", &self.keep_alive);

        // Only show error field if it's interesting...
        if let Some(error) = &self.error {
            builder.field("error", error);
        }

        if self.allow_half_close {
            builder.field("allow_half_close", &true);
        }

        // Purposefully leaving off other fields..

        builder.finish()
    }
}

impl fmt::Debug for Writing {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Init => f.write_str("Init"),
            Self::Body(enc) => f.debug_tuple("Body").field(enc).finish(),
            Self::KeepAlive => f.write_str("KeepAlive"),
            Self::Closed => f.write_str("Closed"),
        }
    }
}

impl std::ops::BitAndAssign<bool> for KA {
    fn bitand_assign(&mut self, enabled: bool) {
        if !enabled {
            trace!("remote disabling keep-alive");
            *self = Self::Disabled;
        }
    }
}

#[derive(Clone, Copy, Debug, Default)]
enum KA {
    Idle,
    #[default]
    Busy,
    Disabled,
}

impl KA {
    fn idle(&mut self) {
        *self = Self::Idle;
    }

    fn busy(&mut self) {
        *self = Self::Busy;
    }

    fn disable(&mut self) {
        *self = Self::Disabled;
    }

    fn status(self) -> Self {
        self
    }
}

impl State {
    /// Remember that a request body was left unread, so the peer may still
    /// be sending it.
    fn abandon_reading(&mut self) {
        if matches!(self.reading, Reading::Body(..) | Reading::Continue(..)) {
            self.read_abandoned = true;
        }
    }

    fn close(&mut self) {
        trace!("State::close()");
        self.abandon_reading();
        self.reading = Reading::Closed;
        self.writing = Writing::Closed;
        self.keep_alive.disable();
    }

    fn close_read(&mut self) {
        trace!("State::close_read()");
        self.abandon_reading();
        self.reading = Reading::Closed;
        self.keep_alive.disable();
    }

    fn close_write(&mut self) {
        trace!("State::close_write()");
        self.writing = Writing::Closed;
        self.keep_alive.disable();
    }

    fn wants_keep_alive(&self) -> bool {
        !matches!(self.keep_alive.status(), KA::Disabled)
    }

    fn try_keep_alive<T: Http1Transaction>(&mut self) {
        match (&self.reading, &self.writing) {
            (&Reading::KeepAlive, &Writing::KeepAlive) => {
                if matches!(self.keep_alive.status(), KA::Busy) {
                    self.idle::<T>();
                } else {
                    trace!(
                        "try_keep_alive({}): could keep-alive, but status = {:?}",
                        T::LOG,
                        self.keep_alive
                    );
                    self.close();
                }
            }
            (&Reading::Closed, &Writing::KeepAlive) | (&Reading::KeepAlive, &Writing::Closed) => {
                self.close();
            }
            _ => (),
        }
    }

    fn disable_keep_alive(&mut self) {
        self.keep_alive.disable();
    }

    fn busy(&mut self) {
        if matches!(self.keep_alive.status(), KA::Disabled) {
            return;
        }
        self.keep_alive.busy();
    }

    fn idle<T: Http1Transaction>(&mut self) {
        debug_assert!(!self.is_idle(), "State::idle() called while idle");

        self.method = None;
        self.keep_alive.idle();

        if !self.is_idle() {
            self.close();
            return;
        }

        self.reading = Reading::Init;
        self.writing = Writing::Init;

        // !T::should_read_first() means Client.
        //
        // If Client connection has just gone idle, the Dispatcher
        // should try the poll loop one more time, so as to poll the
        // pending requests stream.
        if !T::should_read_first() {
            self.notify_read = true;
        }

        if self.timer.is_enabled() {
            // Next read will start and poll the header read timeout,
            // so we can close the connection if another header isn't
            // received in a timely manner.
            self.notify_read = true;
        }
    }

    fn is_idle(&self) -> bool {
        matches!(self.keep_alive.status(), KA::Idle)
    }

    fn is_read_closed(&self) -> bool {
        matches!(self.reading, Reading::Closed)
    }

    fn is_write_closed(&self) -> bool {
        matches!(self.writing, Writing::Closed)
    }

    fn prepare_upgrade(&mut self) -> upgrade::OnUpgrade {
        let (tx, rx) = upgrade::pending();
        self.upgrade = Some(tx);
        rx
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::proto::RequestLine;
    use rama_core::extensions::Extensions;
    use std::assert_matches;
    use tokio::io::{AsyncRead, AsyncWrite, ReadBuf};

    struct TestIo<I> {
        inner: I,
        extensions: Extensions,
    }

    impl<I> TestIo<I> {
        fn new(inner: I) -> Self {
            Self {
                inner,
                extensions: Extensions::new(),
            }
        }
    }

    impl<I: AsyncRead + Unpin> AsyncRead for TestIo<I> {
        fn poll_read(
            mut self: Pin<&mut Self>,
            cx: &mut Context<'_>,
            buf: &mut ReadBuf<'_>,
        ) -> Poll<io::Result<()>> {
            Pin::new(&mut self.inner).poll_read(cx, buf)
        }
    }

    impl<I: AsyncWrite + Unpin> AsyncWrite for TestIo<I> {
        fn poll_write(
            mut self: Pin<&mut Self>,
            cx: &mut Context<'_>,
            buf: &[u8],
        ) -> Poll<io::Result<usize>> {
            Pin::new(&mut self.inner).poll_write(cx, buf)
        }

        fn poll_flush(mut self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<io::Result<()>> {
            Pin::new(&mut self.inner).poll_flush(cx)
        }

        fn poll_shutdown(mut self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<io::Result<()>> {
            Pin::new(&mut self.inner).poll_shutdown(cx)
        }
    }

    impl<I> ExtensionsRef for TestIo<I> {
        fn extensions(&self) -> &Extensions {
            &self.extensions
        }
    }

    #[test]
    fn server_enforces_peer_version_and_keep_alive_state() {
        for peer_version in [Version::HTTP_10, Version::HTTP_11] {
            for response_version in [Version::HTTP_10, Version::HTTP_11] {
                for enabled in [false, true] {
                    for explicit_keep_alive in [false, true] {
                        let io = TestIo::new(tokio_test::io::Builder::new().build());
                        let mut conn = Conn::<_, Bytes, ServerTransaction>::new(io);
                        conn.state.version = peer_version;
                        if !enabled {
                            conn.state.disable_keep_alive();
                        }
                        let mut head = MessageHead {
                            version: response_version,
                            ..MessageHead::default()
                        };
                        if explicit_keep_alive {
                            head.headers
                                .insert(CONNECTION, HeaderValue::from_static("keep-alive"));
                        }
                        conn.enforce_version(&mut head);
                        assert_eq!(
                            head.version,
                            if peer_version == Version::HTTP_10 {
                                Version::HTTP_10
                            } else {
                                response_version
                            }
                        );
                        let expected_enabled = enabled
                            && !(peer_version == Version::HTTP_10
                                && response_version == Version::HTTP_10
                                && !explicit_keep_alive);
                        assert_eq!(conn.state.wants_keep_alive(), expected_enabled);
                        let expected_header = if peer_version == Version::HTTP_11 && !enabled {
                            Some("close")
                        } else if explicit_keep_alive
                            || (peer_version == Version::HTTP_10
                                && response_version == Version::HTTP_11
                                && enabled)
                        {
                            Some("keep-alive")
                        } else {
                            None
                        };
                        assert_eq!(
                            head.headers
                                .get(CONNECTION)
                                .map(|value| value.to_str().unwrap()),
                            expected_header
                        );
                    }
                }
            }
        }
    }

    #[test]
    fn enforce_version_keeps_nominated_hop_by_hop_fields() {
        // (peer version, keep-alive enabled, outgoing lines, expected lines, expected keep-alive)
        let cases: &[(Version, bool, &[&str], &[&str], bool)] = &[
            (
                Version::HTTP_11,
                false,
                &["x-hop"],
                &["x-hop", "close"],
                false,
            ),
            (
                Version::HTTP_11,
                false,
                &["close, x-hop"],
                &["close, x-hop"],
                false,
            ),
            (
                Version::HTTP_11,
                false,
                &["keep-alive, x-hop"],
                &["x-hop, close"],
                false,
            ),
            (
                Version::HTTP_11,
                false,
                &["Keep-Alive", "x-hop"],
                &["x-hop, close"],
                false,
            ),
            (Version::HTTP_11, true, &["x-hop"], &["x-hop"], true),
            (
                Version::HTTP_10,
                true,
                &["x-hop"],
                &["x-hop", "keep-alive"],
                true,
            ),
            (
                Version::HTTP_10,
                true,
                &["keep-alive, x-hop"],
                &["keep-alive, x-hop"],
                true,
            ),
            (
                Version::HTTP_10,
                true,
                &["close, x-hop"],
                &["close, x-hop"],
                false,
            ),
            (
                Version::HTTP_10,
                true,
                &["keep-alive", "close"],
                &["keep-alive", "close"],
                false,
            ),
            (Version::HTTP_10, false, &["x-hop"], &["x-hop"], false),
        ];
        for &(peer_version, enabled, lines, expected, expected_keep_alive) in cases {
            let io = TestIo::new(tokio_test::io::Builder::new().build());
            let mut conn = Conn::<_, Bytes, ServerTransaction>::new(io);
            conn.state.version = peer_version;
            if !enabled {
                conn.state.disable_keep_alive();
            }
            let mut head = MessageHead {
                version: Version::HTTP_11,
                ..MessageHead::default()
            };
            for &line in lines {
                head.headers
                    .append(CONNECTION, HeaderValue::from_static(line));
            }
            conn.enforce_version(&mut head);
            let actual: Vec<_> = head
                .headers
                .get_all(CONNECTION)
                .iter()
                .map(|value| value.to_str().unwrap())
                .collect();
            let case = format!("{peer_version:?}, enabled = {enabled}, {lines:?}");
            assert_eq!(actual, expected, "{case}");
            assert_eq!(conn.state.wants_keep_alive(), expected_keep_alive, "{case}");
        }
    }

    // A client request carrying `Connection: close` must evict the connection
    // (disable keep-alive) at request-encode time, so it is never returned to the
    // pool for reuse — independent of whether the backend response echoes
    // `Connection: close`. The client otherwise derives reuse from the response alone.
    #[test]
    fn client_request_connection_close_marks_closed_exchange() {
        // Encodes a client GET (with the given Connection header lines, one
        // `append` each) on a fresh client Conn and returns its reuse state and
        // whether the request extensions mark the exchange as closing.
        fn state_after_get(connection_values: &[&'static str]) -> (bool, bool) {
            let io = TestIo::new(tokio_test::io::Builder::new().build());
            let mut conn = Conn::<_, Bytes, crate::proto::h1::ClientTransaction>::new(io);
            assert!(
                conn.state.wants_keep_alive(),
                "a fresh client connection should want keep-alive"
            );

            let mut headers = HeaderMap::new();
            for value in connection_values {
                headers.append(CONNECTION, HeaderValue::from_static(value));
            }
            let head = MessageHead {
                version: Version::HTTP_11,
                subject: RequestLine(Method::GET, "/".parse().unwrap()),
                headers,
                extensions: Extensions::new(),
            };
            conn.write_head(head, None);
            (
                conn.state.wants_keep_alive(),
                conn.state
                    .encoded_request_extensions
                    .as_ref()
                    .is_some_and(|extensions| extensions.contains::<ConnectionClose>()),
            )
        }

        // Control: a request without `Connection: close` leaves the connection reusable.
        assert_eq!(
            state_after_get(&[]),
            (true, false),
            "a keep-alive request must leave the connection reusable and unmarked"
        );
        // Fix: a `Connection: close` request must disable keep-alive so the
        // connection is evicted and mark the corresponding response.
        assert_eq!(
            state_after_get(&["close"]),
            (false, true),
            "a `Connection: close` request must close and mark the exchange"
        );
        // A `close` token in a comma-separated value is honored.
        assert_eq!(
            state_after_get(&["keep-alive, close"]),
            (false, true),
            "a comma-separated `close` token must close and mark the exchange"
        );
        // A `close` in ANY of multiple Connection header lines is honored
        // (get_all, not just the first line).
        assert_eq!(
            state_after_get(&["keep-alive", "close"]),
            (false, true),
            "a `close` in any Connection field must close and mark the exchange"
        );
    }

    use crate::proto::h1::ClientTransaction;
    use crate::proto::h1::ServerTransaction;

    fn poll_head<I, T>(
        conn: &mut Conn<TestIo<I>, Bytes, T>,
    ) -> Poll<Option<crate::Result<(MessageHead<T::Incoming>, DecodedLength, Wants)>>>
    where
        I: tokio::io::AsyncRead + tokio::io::AsyncWrite + Unpin,
        T: Http1Transaction + Unpin,
    {
        tokio_test::task::spawn(()).enter(|cx, _| conn.poll_read_head(cx))
    }

    fn ready<T>(poll: Poll<T>) -> T {
        match poll {
            Poll::Ready(value) => value,
            Poll::Pending => panic!("expected ready"),
        }
    }

    #[test]
    fn conn_reads_request_head() {
        let io = tokio_test::io::Builder::new()
            .read(b"GET / HTTP/1.1\r\n\r\n")
            .build();
        let mut conn = Conn::<_, Bytes, ServerTransaction>::new(TestIo::new(io));

        let (head, body, _) = ready(poll_head(&mut conn))
            .expect("message")
            .expect("valid request");
        assert_eq!(head.subject, RequestLine(Method::GET, "/".parse().unwrap()));
        assert_eq!(body, DecodedLength::ZERO);
    }

    #[test]
    fn conn_reads_partial_request_head() {
        tokio_test::task::spawn(()).enter(|cx, _| {
            let (io, mut handle) = tokio_test::io::Builder::new().build_with_handle();
            let mut conn = Conn::<_, Bytes, ServerTransaction>::new(TestIo::new(io));
            handle.read(b"GET / HTTP");
            assert!(conn.poll_read_head(cx).is_pending());
            handle.read(b"/1.1\r\nHost: foo.bar\r\n\r\n");
            assert!(conn.poll_read_head(cx).is_ready());
        });
    }

    #[test]
    fn conn_accepts_eof_when_idle() {
        let io = tokio_test::io::Builder::new().build();
        let mut conn = Conn::<_, Bytes, ServerTransaction>::new(TestIo::new(io));
        conn.state.idle::<ServerTransaction>();
        assert_matches!(poll_head(&mut conn), Poll::Ready(None));
    }

    #[test]
    fn conn_rejects_eof_during_partial_head() {
        let io = tokio_test::io::Builder::new()
            .read(b"GET / HTTP/1.1")
            .build();
        let mut conn = Conn::<_, Bytes, ServerTransaction>::new(TestIo::new(io));
        conn.state.idle::<ServerTransaction>();
        let err = ready(poll_head(&mut conn))
            .expect("error result")
            .expect_err("partial head must fail");
        assert!(err.is_incomplete_message(), "unexpected error: {err:?}");
    }

    #[test]
    fn client_rejects_eof_while_busy() {
        let io = tokio_test::io::Builder::new().build();
        let mut client = Conn::<_, Bytes, ClientTransaction>::new(TestIo::new(io));
        client.state.busy();
        client.state.writing = Writing::KeepAlive;
        let err = ready(poll_head(&mut client))
            .expect("error result")
            .expect_err("client EOF must fail");
        assert!(err.is_incomplete_message(), "unexpected error: {err:?}");
    }

    #[test]
    fn server_accepts_eof_while_busy() {
        let io = tokio_test::io::Builder::new().build();
        let mut server = Conn::<_, Bytes, ServerTransaction>::new(TestIo::new(io));
        server.state.busy();
        assert_matches!(poll_head(&mut server), Poll::Ready(None));
    }

    #[test]
    fn conn_reads_empty_response_before_eof() {
        let io = tokio_test::io::Builder::new()
            .read(b"HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n")
            .build();
        let mut conn = Conn::<_, Bytes, ClientTransaction>::new(TestIo::new(io));
        conn.state.busy();
        conn.state.writing = Writing::KeepAlive;
        let (_, body, _) = ready(poll_head(&mut conn))
            .expect("response")
            .expect("valid response");
        assert_eq!(body, DecodedLength::ZERO);
    }

    #[test]
    fn conn_reads_body_and_reports_end() {
        let io = tokio_test::io::Builder::new()
            .read(b"POST / HTTP/1.1\r\nContent-Length: 5\r\n\r\n12345")
            .wait(std::time::Duration::from_secs(1))
            .build();
        let mut conn = Conn::<_, Bytes, ServerTransaction>::new(TestIo::new(io));
        let (_, body, _) = ready(poll_head(&mut conn))
            .expect("request")
            .expect("valid request");
        assert_eq!(body, DecodedLength::new(5));

        tokio_test::task::spawn(()).enter(|cx, _| {
            let frame = conn.poll_read_body(cx);
            let data = ready(frame)
                .expect("body frame")
                .expect("valid body")
                .into_data()
                .expect("data frame");
            assert_eq!(data, "12345");
            assert!(
                !conn.can_read_body(),
                "the complete body must return to head-reading state"
            );
        });
    }

    #[test]
    fn conn_removes_connection_nominated_trailers() {
        let io = tokio_test::io::Builder::new()
            .read(
                b"POST / HTTP/1.1\r\n\
                  Connection: x-hop\r\n\
                  Transfer-Encoding: chunked\r\n\r\n\
                  0\r\n\
                  x-hop: late\r\n\
                  x-end: kept\r\n\r\n",
            )
            .build();
        let mut conn = Conn::<_, Bytes, ServerTransaction>::new(TestIo::new(io));
        let (_, body, _) = ready(poll_head(&mut conn))
            .expect("request")
            .expect("valid request");
        assert_eq!(body, DecodedLength::CHUNKED);

        tokio_test::task::spawn(()).enter(|cx, _| {
            let frame = ready(conn.poll_read_body(cx))
                .expect("body frame")
                .expect("valid body");
            let trailers = frame.into_trailers().expect("trailer frame");
            assert!(!trailers.contains_key("x-hop"));
            assert_eq!(trailers["x-end"], "kept");
        });
    }

    #[test]
    fn closed_conn_cannot_read_or_write() {
        let io = tokio_test::io::Builder::new().build();
        let mut conn = Conn::<_, Bytes, ServerTransaction>::new(TestIo::new(io));
        conn.state.close();
        assert!(conn.is_read_closed());
        assert!(conn.is_write_closed());
        assert!(!conn.can_read_head());
        assert!(!conn.can_write_head());
    }

    #[test]
    fn conn_writes_chunked_body() {
        let io = tokio_test::io::Builder::new()
            .write(b"7\r\nheaders\r\n0\r\n\r\n")
            .build();
        let mut conn = Conn::<_, Bytes, ServerTransaction>::new(TestIo::new(io));
        conn.state.writing = Writing::Body(Encoder::chunked());
        conn.write_body(Bytes::from_static(b"headers"));
        conn.end_body().unwrap();
        tokio_test::task::spawn(()).enter(|cx, _| {
            assert!(conn.poll_flush(cx).is_ready());
        });
    }
}
