//! HTTP/3 server stream admission and response sending.

use std::{
    future::{Future, pending, poll_fn},
    sync::{
        Arc,
        atomic::{AtomicU64, Ordering},
    },
    task::Poll,
};

use rama_core::{
    bytes::BytesMut,
    error::BoxError,
    extensions::ExtensionsRef,
    telemetry::tracing::{debug, warn},
};
use rama_http::{
    headers::{HeaderMapExt as _, Priority},
    io::upgrade::{self, Pending},
};
use rama_http_types::{
    Method, Request, Response, StatusCode,
    body::StreamingBody,
    header::{self, trailer::ForbiddenTrailers},
    proto::{
        ext::{HttpDatagrams, Protocol},
        h3::{Code, FrameType, Settings, StreamType},
    },
};
use rama_net::uri::Uri;
use rama_quic_proto::{Side, VarInt, coding::Codec as _};
use rama_utils::guard::DropGuard;
use tokio::{
    sync::{Notify, Semaphore},
    time::{Instant, timeout},
};

use super::{
    Error, PriorityObserver, body,
    connection::{Config, Driver, Shared, receive::settings::SettingsPrelude},
    control::Role,
    datagram::{Association, DatagramDrops, Semantics},
    headers,
    quic::Writer,
    stream::{HEAD_TIMEOUT, HeadDeadline, Phase, Reader},
    transport::{self, SendStream as _, StreamHandle as _},
};
use crate::{
    headers::{ResponseLength, is_tunnel_response, set_content_length_if_missing},
    server::conn::timeout::{Activity, ConnTimer, HeadBudget},
};

/// Accepts request streams; the accompanying driver must run concurrently.
pub struct Connection<C> {
    connection: C,
    shared: Arc<Shared>,
    admission: Arc<Semaphore>,
    next_id: u64,
    draining: bool,
    idle: ConnTimer,
    heads: Arc<Heads>,
    /// The complete heads the idle deadline already accounted for.
    heads_seen: u64,
}

/// What request streams report to their connection's deadlines.
#[derive(Debug, Default)]
struct Heads {
    /// Complete request heads received; the first earns the full idle budget.
    received: AtomicU64,
    /// A head timed out on a connection that never received a complete one.
    stalled: Notify,
}

impl Heads {
    fn earned(&self) -> bool {
        self.received.load(Ordering::Relaxed) != 0
    }
}

/// An established server connection whose peer SETTINGS were read before local startup.
///
/// Finish with [`Self::into_connection`] after selecting local settings. Dropping
/// this owner closes the QUIC connection without emitting local HTTP/3 streams.
#[non_exhaustive]
pub struct Handshake<C: transport::Connection> {
    connection: C,
    received: Option<Box<SettingsPrelude>>,
}

impl<C: transport::Connection> std::fmt::Debug for Handshake<C> {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("H3ServerHandshake")
            .field("connection", &self.connection)
            .field("received", &self.received)
            .finish_non_exhaustive()
    }
}

impl<C: transport::Connection> Handshake<C> {
    /// The peer's ordered SETTINGS; unknown identifiers remain available to the caller.
    #[must_use]
    #[expect(
        clippy::expect_used,
        reason = "the private owner is returned only after complete SETTINGS and consumed once"
    )]
    pub fn peer_settings(&self) -> &Settings {
        self.received
            .as_ref()
            .expect("unconsumed server handshake")
            .settings()
    }

    /// Construct the server and driver with the selected local configuration.
    ///
    /// The receive chunk, frame and pending-stream limits must match those used
    /// by [`receive_settings`]. QPACK state is constructed only now, independently
    /// of any other connection. An error closes this connection.
    #[expect(
        clippy::expect_used,
        reason = "consuming the private owner transfers its receive state once"
    )]
    pub fn into_connection(mut self, config: Config) -> Result<(Connection<C>, Driver<C>), Error> {
        self.received
            .as_ref()
            .expect("unconsumed server handshake")
            .validate(&config)?;
        let (connection, driver) = handshake(self.connection.clone(), config)?;
        let received = self.received.take().expect("unconsumed server handshake");
        let driver = driver.with_received_settings(*received)?;
        Ok((connection, driver))
    }
}

impl<C: transport::Connection> Drop for Handshake<C> {
    fn drop(&mut self) {
        if self.received.is_some() {
            self.connection.close(
                VarInt::from_u32(Code::H3_INTERNAL_ERROR.value() as u32),
                b"HTTP/3 server handshake stopped",
            );
        }
    }
}

/// Read peer SETTINGS without opening or writing local HTTP/3 streams.
///
/// Uses `config`'s existing bounded frame, chunk and pending-stream limits.
/// Apply the caller's readiness deadline. Dropping the returned future, even
/// before polling it, closes this connection. The returned owner must be finished
/// before the driver and request handling start; held QPACK bytes are not decoded
/// under a provisional configuration.
pub fn receive_settings<C: transport::Connection>(
    connection: C,
    config: &Config,
) -> impl Future<Output = Result<Handshake<C>, Error>> + Send + '_ {
    let close = connection.clone();
    let mut guard = DropGuard::new(move || {
        close.close(
            VarInt::from_u32(Code::H3_INTERNAL_ERROR.value() as u32),
            b"HTTP/3 server handshake stopped",
        );
    });
    async move {
        if connection.side() != Side::Server {
            return Err(Error::connection(
                Code::H3_INTERNAL_ERROR,
                "server requires server-side QUIC connection",
            ));
        }
        config.settings()?;
        let received = match SettingsPrelude::read(&connection, config).await {
            Ok(received) => received,
            Err(error) => {
                let code = VarInt::from_u64(error.code().value())
                    .unwrap_or(VarInt::from_u32(Code::H3_INTERNAL_ERROR.value() as u32));
                connection.close(code, b"HTTP/3 peer SETTINGS rejected");
                guard.disarm();
                return Err(error);
            }
        };
        let handshake = Handshake {
            connection,
            received: Some(Box::new(received)),
        };
        guard.disarm();
        Ok(handshake)
    }
}

/// Prepare the server side of an established QUIC connection.
/// ALPN is required unless [`Config::server_alpn_policy`] permits out-of-band agreement.
/// This server setting is not published in connection or request extensions.
pub fn handshake<C: transport::Connection>(
    connection: C,
    config: Config,
) -> Result<(Connection<C>, Driver<C>), Error> {
    if connection.side() != Side::Server {
        return Err(Error::connection(
            Code::H3_INTERNAL_ERROR,
            "server requires server-side QUIC connection",
        ));
    }
    config.settings()?;
    let admission = Arc::new(Semaphore::new(config.max_requests));
    let idle = ConnTimer::new(config.idle_timeout, None);
    let shared = Shared::from_connection(config, Role::Server, &connection)?;
    let driver = Driver::new(connection.clone(), shared.clone(), Role::Server);
    Ok((
        Connection {
            connection,
            shared,
            admission,
            next_id: 0,
            draining: false,
            idle,
            heads: Arc::default(),
            heads_seen: 0,
        },
        driver,
    ))
}

impl<C: transport::Connection> Connection<C> {
    /// Wait for the peer's complete SETTINGS, preserving entry order and unknown IDs.
    ///
    /// Run the driver concurrently and apply the caller's handshake deadline.
    /// Cancelling this wait leaves the connection and other waiters intact. A
    /// connection failure before SETTINGS returns an error. The snapshot is
    /// cloned only when requested; observation need not be enabled.
    pub async fn peer_settings(&self) -> Result<Settings, Error> {
        self.shared.peer_settings_snapshot().await
    }

    #[cfg(test)]
    pub(crate) fn shared(&self) -> &Arc<Shared> {
        &self.shared
    }

    /// Received HTTP/3 datagrams this connection discarded, by reason.
    #[must_use]
    pub fn datagram_drops(&self) -> DatagramDrops {
        self.shared.datagram_drops()
    }

    /// Stop admitting requests and notify the peer while accepted streams finish.
    pub fn shutdown(&mut self) -> Result<(), Error> {
        self.shared.send_goaway(self.next_id)?;
        self.draining = true;
        Ok(())
    }

    /// Wait for accepted bodies, push senders and upgraded tunnels to be released,
    /// including acknowledgement of response FINs, and for the queued GOAWAY to
    /// be handed to QUIC. Run the driver concurrently. Apply a shutdown deadline
    /// around this operation when the peer may stop acknowledging data.
    pub async fn drained(&self) -> Result<(), Error> {
        let _all = self
            .admission
            .clone()
            .acquire_many_owned(self.shared.config.max_requests as u32)
            .await
            .map_err(|_error| Error::connection(Code::H3_INTERNAL_ERROR, "admission closed"))?;
        self.shared.control_flushed().await
    }

    /// Accept the next stream without waiting for its headers. Resolve each returned
    /// stream independently so a blocked QPACK section cannot hold up other requests.
    pub async fn accept(&mut self) -> Result<RequestStream<C>, Error> {
        if self.draining {
            return Err(Error::connection(Code::H3_NO_ERROR, "server draining"));
        }
        let permit = tokio::select! {
            error = self.shared.failed() => return Err(error),
            error = self.connection.closed() => return Err(Error::from_transport(&error)),
            permit = self.admission.clone().acquire_owned() => Arc::new(permit.map_err(|_error| Error::connection(Code::H3_NO_ERROR, "server draining"))?),
        };
        let (send, recv) = loop {
            tokio::select! {
                biased;
                error = self.shared.failed() => return Err(error),
                () = self.heads.stalled.notified() => {
                    // A connection that completed a head meanwhile is serving requests.
                    if !self.heads.earned() {
                        return Err(self.close_gracefully("HTTP/3 request head timeout").await);
                    }
                }
                accepted = self.connection.accept_bi() => {
                    break accepted.map_err(|error| Error::from_transport(&error))?;
                }
                () = async {
                    if !self.idle.is_enabled() {
                        pending::<()>().await;
                    }
                    // The reserved accept permit is the only one left when every request ends.
                    let all = self.admission.clone().acquire_many_owned(
                        self.shared.config.max_requests.saturating_sub(1) as u32,
                    ).await;
                    drop(all);
                    let received = self.heads.received.load(Ordering::Relaxed);
                    if received != self.heads_seen {
                        self.heads_seen = received;
                        self.idle.request_received();
                    }
                    self.idle.set_rtt(self.connection.rtt());
                    poll_fn(|cx| self.idle.poll(cx, Activity::Idle)).await;
                } => return Err(self.close_gracefully("HTTP/3 idle timeout").await),
            }
        };
        self.idle.mark_busy();
        let accepted = Instant::now();
        let id = u64::from(send.id());
        self.next_id = self.next_id.max(id.saturating_add(4));
        self.shared.schedule.register(id, Priority::default())?;
        let mut reader = Reader::new(recv, self.shared.clone(), id);
        let abort = send.boxed_handle();
        reader.abort = Some(abort.clone());
        // Held until the head (or the response) settles its semantics.
        reader.datagrams = self
            .shared
            .register_datagrams(id, Semantics::Provisional, abort);
        reader.cancel_code = Code::H3_REQUEST_REJECTED;
        let mut writer = Writer::new(send);
        writer.cancel_code = Code::H3_REQUEST_REJECTED;
        Ok(RequestStream {
            connection: self.connection.clone(),
            accepted,
            heads: self.heads.clone(),
            reader,
            writer,
            priority: super::priority::Lease {
                shared: self.shared.clone(),
                id,
                permit,
            },
        })
    }

    /// Send GOAWAY, give the peer a bounded drain, then close QUIC without error.
    async fn close_gracefully(&mut self, reason: &'static str) -> Error {
        if let Err(error) = self.shutdown() {
            return error;
        }
        // Bound flushing even when the peer stopped granting control-stream credit.
        self.idle.set_rtt(self.connection.rtt());
        _ = timeout(self.idle.drain_budget(), self.shared.control_flushed()).await;
        // Closing QUIC immediately can discard the queued GOAWAY before transmission.
        self.idle.start_drain();
        tokio::select! {
            _ = self.connection.closed() => (),
            _ = poll_fn(|cx| self.idle.poll(cx, Activity::Idle)) => (),
        }
        self.connection.close(
            VarInt::from_u32(Code::H3_NO_ERROR.value() as u32),
            reason.as_bytes(),
        );
        Error::connection(Code::H3_NO_ERROR, reason)
    }
}

/// A newly accepted request stream, including its bounded admission permit.
pub struct RequestStream<C: transport::Connection> {
    connection: C,
    accepted: Instant,
    heads: Arc<Heads>,
    reader: Reader<C::RecvStream>,
    writer: Writer<C::SendStream>,
    priority: super::priority::Lease,
}

impl<C: transport::Connection> RequestStream<C> {
    /// Decode and validate the request head, returning the common Incoming body.
    pub async fn resolve(
        mut self,
    ) -> Result<(Request<crate::body::Incoming>, SendResponse<C>), Error> {
        // Early or buffered bytes may be replayed: dispatch only after the client's verified Finished.
        if !self.connection.is_handshake_confirmed()
            && let Err(error) = self.connection.handshake_confirmed().await
        {
            let error = Error::from_transport(&error);
            // A graceful close after authentication may still drain buffered requests.
            if !error.is_clean_close() || !self.connection.is_handshake_confirmed() {
                return Err(self.reader.reject(error));
            }
        }
        let extended_connect = self.reader.shared.config.extended_connect;
        let deadline = self
            .reader
            .shared
            .config
            .header_read_timeout
            .map(|config| HeadDeadline {
                accepted: self.accepted,
                budget: HeadBudget::new(&config, Some(self.connection.rtt())),
            });
        let fields = match self.reader.headers_within(deadline).await {
            Ok(fields) => fields,
            Err(error) => {
                if error == HEAD_TIMEOUT && !self.heads.earned() {
                    self.heads.stalled.notify_one();
                }
                return Err(self.reader.reject(error));
            }
        };
        let observation = self
            .reader
            .shared
            .request_observation(self.reader.id, &fields);
        let request = match headers::request_head(fields, extended_connect) {
            Ok(request) => request,
            Err(error) => return Err(self.reader.reject(error)),
        };
        if let Some((observer, snapshot)) = observation {
            request.extensions().insert(observer);
            request.extensions().insert(snapshot);
        }
        let remaining = headers::content_length(request.headers())?;
        self.heads.received.fetch_add(1, Ordering::Relaxed);
        let method = request.method().clone();
        // Only an Extended CONNECT can be declared to carry datagrams, by its 2xx response.
        let extended_connect =
            method == Method::CONNECT && request.extensions().contains::<Protocol>();
        if !extended_connect && let Some(datagrams) = &self.reader.datagrams {
            datagrams.decide(false);
            if datagrams.violated() {
                return Err(self.reader.reject(no_semantics()));
            }
        }
        let priority = request
            .headers()
            .typed_get::<Priority>()
            .unwrap_or_default();
        self.reader
            .shared
            .schedule
            .initial_priority(self.reader.id, priority);
        self.reader.phase = Phase::Body;
        self.reader.cancel_code = Code::H3_REQUEST_CANCELLED;
        self.writer.cancel_code = Code::H3_REQUEST_CANCELLED;
        let permit = self.priority.permit.clone();
        let mut response = SendResponse {
            connection: self.connection,
            origin: request.uri().clone(),
            outgoing_push: None,
            connect: None,
            shared: self.reader.shared.clone(),
            id: self.reader.id,
            writer: self.writer,
            method,
            priority_lease: self.priority,
        };
        if response.method == Method::CONNECT {
            let (pending, upgrade) = upgrade::pending();
            request.extensions().insert(upgrade);
            response.connect = Some((self.reader, pending, extended_connect));
            return Ok((request.map(|()| crate::body::Incoming::empty()), response));
        }
        // RFC 9114 section 4.1: discarding an otherwise valid request body
        // asks the client to stop its upload without invalidating the response.
        self.reader.cancel_code = Code::H3_NO_ERROR;
        let incoming = body::Body::new(self.reader, remaining, permit);
        Ok((
            request.map(|()| crate::body::Incoming::h3(incoming)),
            response,
        ))
    }
}

/// Sends informational responses and a final response on one request stream.
pub struct SendResponse<C: transport::Connection> {
    connection: C,
    origin: Uri,
    outgoing_push: Option<super::push::Lease>,
    connect: Option<(Reader<C::RecvStream>, Pending, bool)>,
    shared: Arc<Shared>,
    id: u64,
    writer: Writer<C::SendStream>,
    method: Method,
    priority_lease: super::priority::Lease,
}

impl<C: transport::Connection> SendResponse<C> {
    /// Reset the response and stop the request upload with the same application code.
    ///
    /// The upload is stopped even while another owner retains its request body.
    /// Unknown HTTP/3 codes are preserved when they fit QUIC's integer range.
    /// Use `H3_REQUEST_REJECTED` only when the application has not processed the
    /// request, since that code allows the peer to retry it.
    pub fn reset(mut self, code: Code) -> Result<(), Error> {
        let wire_code = VarInt::from_u64(code.value()).map_err(|_error| {
            Error::stream(
                Code::H3_INTERNAL_ERROR,
                "reset code exceeds QUIC integer range",
            )
        })?;
        self.writer.handle().abort(wire_code);
        self.writer.reset(code);
        Ok(())
    }

    async fn flush(&mut self, finish: bool) -> Result<(), Error> {
        let push = self.outgoing_push.as_ref().map(super::push::Lease::id);
        let shared = self.shared.clone();
        let write = poll_fn(|cx| {
            if finish {
                self.writer.poll_finish(cx)
            } else {
                self.writer.poll_flush(cx)
            }
        });
        if let Some(id) = push {
            tokio::select! { error = shared.push_cancelled(id) => Err(error), result = write => result }
        } else {
            write.await
        }
    }

    /// Wait for the peer to grant a push ID. Applications can apply their own deadline.
    pub async fn ready_for_push(&self) -> Result<(), Error> {
        loop {
            let changed = self.shared.push_ready.notified();
            let mut changed = std::pin::pin!(changed);
            changed.as_mut().enable();
            if let Some(error) = self.shared.error() {
                return Err(error);
            }
            if self
                .shared
                .pushes
                .lock()
                .exhausted(self.shared.config.max_pushes)
                || self.shared.goaway().is_some()
            {
                return Err(Error::stream(
                    Code::H3_REQUEST_REJECTED,
                    "push disabled or connection draining",
                ));
            }
            if self
                .shared
                .pushes
                .lock()
                .capacity(self.shared.config.max_pushes)
            {
                return Ok(());
            }
            changed.await;
        }
    }

    /// Promise a same-origin GET/HEAD and open its independently framed response stream.
    /// Both peers must opt into push. The configured quota is a lifetime bound.
    pub async fn push(&mut self, request: Request<()>) -> Result<Self, Error> {
        if !self.id.is_multiple_of(4)
            || !matches!(*request.method(), Method::GET | Method::HEAD)
            || request.uri().authority() != self.origin.authority()
            || request.uri().scheme() != self.origin.scheme()
            || headers::content_length(request.headers())?.is_some_and(|length| length != 0)
        {
            return Err(Error::stream(
                Code::H3_MESSAGE_ERROR,
                "push requires a same-origin cacheable request without content",
            ));
        }
        headers::wait_for_header_admission(&self.shared, request.extensions()).await?;
        self.flush(false).await?;
        let goaway = self.shared.goaway();
        let id = self
            .shared
            .pushes
            .lock()
            .allocate(self.shared.config.max_pushes, goaway)?;
        let lease = super::push::Lease::new(self.shared.clone(), id);
        let encoded = headers::encode_request(&self.shared, self.id, &request)?;
        let mut promise = BytesMut::with_capacity(8 + encoded.len());
        VarInt::from_u64(id)
            .map_err(|_error| Error::stream(Code::H3_INTERNAL_ERROR, "invalid push ID"))?
            .encode(&mut promise);
        promise.extend_from_slice(&encoded);
        self.writer
            .queue(FrameType::PUSH_PROMISE, promise.freeze())?;
        poll_fn(|cx| {
            let mut pushes = self.shared.pushes.lock();
            let result = self.writer.poll_flush(cx);
            if !matches!(result, Poll::Ready(Err(_))) && self.writer.is_drained() {
                pushes.mark_promised(id);
            }
            result
        })
        .await?;
        let stream = tokio::select! {
            error = self.shared.push_cancelled(id) => return Err(error),
            result = self.connection.open_uni() => result.map_err(|_error| Error::connection(Code::H3_STREAM_CREATION_ERROR, "cannot open push stream"))?,
        };
        let stream_id = u64::from(stream.id());
        let mut prefix = BytesMut::with_capacity(9);
        VarInt::from_u32(StreamType::PUSH.value() as u32).encode(&mut prefix);
        VarInt::from_u64(id)
            .map_err(|_error| Error::stream(Code::H3_INTERNAL_ERROR, "invalid push ID"))?
            .encode(&mut prefix);
        let mut writer = Writer::with_prefix(stream, prefix.freeze());
        tokio::select! {
            error = self.shared.push_cancelled(id) => return Err(error),
            result = poll_fn(|cx| writer.poll_flush(cx)) => result?,
        }
        let priority =
            self.shared
                .pushes
                .lock()
                .attach_stream(id, stream_id, writer.boxed_handle());
        self.shared.schedule.register(stream_id, priority)?;
        Ok(Self {
            connection: self.connection.clone(),
            origin: request.uri().clone(),
            outgoing_push: Some(lease),
            connect: None,
            shared: self.shared.clone(),
            id: stream_id,
            writer,
            method: request.method().clone(),
            priority_lease: super::priority::Lease {
                shared: self.shared.clone(),
                id: stream_id,
                permit: self.priority_lease.permit.clone(),
            },
        })
    }

    /// Observe current and future effective priorities while relaying this response.
    /// Cancel the observer's pending wait when this response completes.
    #[must_use]
    pub fn peer_priority(&self) -> PriorityObserver {
        PriorityObserver::new(&self.shared, self.id)
    }

    /// Override peer priority using application knowledge.
    pub fn set_priority(&mut self, priority: Priority) {
        self.shared.override_priority(self.id, priority);
    }

    /// Send a non-101 informational response before the final response.
    pub async fn send_informational(&mut self, mut response: Response<()>) -> Result<(), Error> {
        if !response.status().is_informational()
            || response.status() == StatusCode::SWITCHING_PROTOCOLS
        {
            return Err(Error::stream(
                Code::H3_INTERNAL_ERROR,
                "expected informational response",
            ));
        }
        if response
            .headers_mut()
            .remove(header::CONTENT_LENGTH)
            .is_some()
        {
            debug!("content-length dropped: forbidden for an informational response");
        }
        headers::wait_for_header_admission(&self.shared, response.extensions()).await?;
        self.flush(false).await?;
        let bytes = headers::encode_response(&self.shared, self.id, &response)?;
        self.writer.queue(FrameType::HEADERS, bytes)?;
        self.flush(false).await
    }

    /// Send final headers followed by the streaming response body and trailers.
    /// Completion waits for the peer to acknowledge the finished send direction.
    pub async fn send_response<B>(mut self, mut response: Response<B>) -> Result<(), Error>
    where
        B: StreamingBody + Unpin,
        B::Error: Into<BoxError>,
    {
        if response.status().is_informational() {
            return Err(Error::stream(
                Code::H3_INTERNAL_ERROR,
                "final response cannot be informational",
            ));
        }
        if is_tunnel_response(Some(&self.method), response.status())
            && self.shared.config.strict_connect_framing
            && (response.headers().contains_key(header::CONTENT_LENGTH)
                || response.headers().contains_key(header::TRANSFER_ENCODING))
        {
            return Err(Error::stream(
                Code::H3_INTERNAL_ERROR,
                "framing headers on a successful response to CONNECT",
            ));
        }
        let response_length = ResponseLength::of(Some(&self.method), response.status());
        if response_length == ResponseLength::Forbidden
            && response.headers().contains_key(header::CONTENT_LENGTH)
        {
            debug!("content-length dropped: forbidden for this response");
            response.headers_mut().remove(header::CONTENT_LENGTH);
        }
        headers::wait_for_header_admission(&self.shared, response.extensions()).await?;
        self.flush(false).await?;
        if response.status().is_success()
            && let Some((reader, pending, extended_connect)) = self.connect.take()
        {
            if response
                .body()
                .size_hint()
                .exact()
                .is_some_and(|len| len != 0)
            {
                warn!("body of a successful response to CONNECT dropped: a tunnel follows");
            }
            // RFC 9297 §2: the server declares datagram semantics on its response.
            let claimed = extended_connect && response.extensions().contains::<HttpDatagrams>();
            let datagrams = reader.datagrams.clone().and_then(|registration| {
                registration.decide(claimed);
                let send = reader.abort.clone().filter(|_| claimed)?;
                Some(Association::new(registration, send))
            });
            if reader
                .datagrams
                .as_ref()
                .is_some_and(|datagrams| datagrams.violated())
            {
                return Err(no_semantics());
            }
            let bytes = headers::encode_response(&self.shared, self.id, &response)?;
            self.writer.queue(FrameType::HEADERS, bytes)?;
            self.flush(false).await?;
            pending.fulfill(super::upgrade::new(
                reader,
                self.writer,
                self.priority_lease.permit.clone(),
                Some(self.priority_lease),
                &self.connection,
                datagrams,
                extended_connect,
            ));
            return Ok(());
        }
        if let Some((mut reader, _pending, _)) = self.connect.take() {
            reader.cancel_code = Code::H3_NO_ERROR;
            if let Some(datagrams) = &reader.datagrams {
                datagrams.refuse();
                if datagrams.violated() {
                    return Err(no_semantics());
                }
            }
        }
        let body = response.body();
        let body_len = (self.method == Method::HEAD || !body.is_end_stream())
            .then(|| body.size_hint().exact())
            .flatten();
        if let Some(len) = response_length.implied(body_len) {
            set_content_length_if_missing(response.headers_mut(), len);
        }
        let bodyless = self.method == Method::HEAD
            || response.status() == StatusCode::NOT_MODIFIED
            || response.status() == StatusCode::NO_CONTENT;
        self.flush(false).await?;
        let bytes = headers::encode_response(&self.shared, self.id, &response)?;
        self.writer.queue(FrameType::HEADERS, bytes)?;
        if bodyless {
            self.flush(true).await?;
            let since = tokio::time::Instant::now();
            tokio::select! {
                result = self.writer.acknowledged() => result?,
                () = self.shared.goaway_drain_expired(since) => {}
            }
            self.writer.mark_acknowledged();
            if let Some(push) = &mut self.outgoing_push {
                push.finished = true;
            }
            return Ok(());
        }
        let remaining = headers::content_length(response.headers())?;
        let allowed_trailers = response.extensions().get_arc::<ForbiddenTrailers>();
        let (_, response_body) = response.into_parts();
        let shared = self.shared.clone();
        let result = body::send(
            self.writer,
            response_body,
            self.shared,
            self.id,
            remaining,
            allowed_trailers,
        );
        if let Some(mut push) = self.outgoing_push {
            tokio::select! {
                error = shared.push_cancelled(push.id()) => Err(error),
                result = result => { if result.is_ok() { push.finished = true; } result }
            }
        } else {
            result.await
        }
    }
}

/// The driver aborted a request that received datagrams without semantics (RFC 9297 §2).
fn no_semantics() -> Error {
    Error::stream(
        Code::H3_DATAGRAM_ERROR,
        "datagram for a request without datagram semantics",
    )
    .remote()
}
