//! Rama-native HTTP/3 request sender.

use std::{
    marker::PhantomData,
    mem,
    pin::pin,
    sync::{Arc, Weak},
};

use parking_lot::Mutex;
use rama_core::{
    error::BoxError,
    extensions::{Extension, Extensions, ExtensionsRef},
    rt::Executor,
};
use rama_http::io::upgrade as http_upgrade;
use rama_http_types::{
    Method, Request, Response, StatusCode,
    body::StreamingBody,
    header::trailer::ForbiddenTrailers,
    proto::{
        RequestHeaders,
        ext::{HttpDatagrams, Protocol},
        h1::ext::informational::OnInformational,
        h3::{Code, FrameType, Settings, control::ClientControlFrame},
    },
};
use rama_net::client::{
    ConnectionError, ConnectionErrorKind,
    pool::{ConnectionAdmission, ConnectionAdmissionLease, ConnectionAdmissionPolicy},
};
use rama_quic_proto::ConnectionError as QuicConnectionError;
use rama_quic_proto::{Dir, Side};
use rama_utils::reactive::{Change, ChangeListener, ChangeSignal};
use tokio::sync::{OwnedSemaphorePermit, Semaphore};

use super::{
    Error, PriorityHandle, body,
    connection::{Config, Driver, Shared},
    control::Role,
    datagram::{Association, DatagramDrops, Semantics},
    headers,
    quic::Writer,
    stream::{Phase, Reader},
    transport::{
        self, BiReservation as _, BoxedBiReservation, EarlyData, RecvStream as _, SendStream as _,
    },
};
use crate::headers::{content_length_parse_all, drop_undeliverable_content_length};

/// Cloneable sender for a multiplexed HTTP/3 connection.
pub struct SendRequest<B, C: transport::Connection> {
    connection: C,
    shared: Arc<Shared>,
    lifetime: Arc<ConnectionLifetime<C>>,
    executor: Executor,
    _body: PhantomData<fn(B)>,
}

// The driver owns a transport handle too, so transport reference counting alone
// cannot detect when the application has stopped using this connection.
/// Keeps a client connection open while held: the last drop closes it.
pub(crate) trait ClientLifetime: Send + Sync {}

impl<C: transport::Connection> ClientLifetime for ConnectionLifetime<C> {}

pub(crate) struct ConnectionLifetime<C: transport::Connection> {
    connection: C,
    shared: Arc<Shared>,
    admission: Arc<Semaphore>,
    max_requests: usize,
    admission_changed: ChangeSignal,
}

impl<C: transport::Connection> Drop for ConnectionLifetime<C> {
    fn drop(&mut self) {
        self.connection
            .close(self.shared.close_code(), b"HTTP/3 client released");
    }
}

impl<B, C: transport::Connection> Clone for SendRequest<B, C> {
    fn clone(&self) -> Self {
        Self {
            connection: self.connection.clone(),
            shared: self.shared.clone(),
            lifetime: self.lifetime.clone(),
            executor: self.executor.clone(),
            _body: PhantomData,
        }
    }
}

impl<B, C: transport::Connection> std::fmt::Debug for SendRequest<B, C> {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("H3SendRequest")
            .field("connection", &self.connection)
            .finish_non_exhaustive()
    }
}

/// Prepare a client connection. The returned driver must be run concurrently.
///
/// Application data is sent only after handshake confirmation. The QUIC endpoint
/// must allow at least three peer unidirectional streams.
/// ALPN is required unless the connection extensions explicitly carry
/// [`rama_net::tls::AlpnPolicy::OutOfBandAgreement`] for a known HTTP/3 peer.
pub fn handshake<B, C: transport::Connection>(
    connection: C,
    config: Config,
    executor: Executor,
) -> Result<(SendRequest<B, C>, Driver<C>), Error> {
    if connection.side() != Side::Client {
        return Err(Error::connection(
            Code::H3_INTERNAL_ERROR,
            "client requires client-side QUIC connection",
        ));
    }
    config.settings()?;
    // Priorities may name future requests, but never exceed peer stream credit.
    // Ordinary connections without configured priorities need no extra lookup.
    let highest_priority = config.client_control.as_ref().and_then(|preferences| {
        preferences
            .frames
            .iter()
            .filter_map(|frame| match frame {
                ClientControlFrame::RequestPriority { request, .. } => Some(request.index()),
                ClientControlFrame::Ignored { .. } => None,
            })
            .max()
    });
    if highest_priority.is_some_and(|index| index >= connection.local_stream_limit(Dir::Bi)) {
        return Err(Error::connection(
            Code::H3_ID_ERROR,
            "client control priority exceeds peer stream limit",
        ));
    }
    let max_requests = config.max_requests;
    let admission = Arc::new(Semaphore::new(max_requests));
    let shared = Shared::from_connection(config, Role::Client, &connection)?;
    let driver = Driver::new(connection.clone(), shared.clone(), Role::Client);
    Ok((
        SendRequest {
            lifetime: Arc::new(ConnectionLifetime {
                connection: connection.clone(),
                shared: shared.clone(),
                admission,
                max_requests,
                admission_changed: ChangeSignal::new(),
            }),
            connection,
            shared,
            executor,
            _body: PhantomData,
        },
        driver,
    ))
}

impl<B, C: transport::Connection> SendRequest<B, C> {
    /// Borrow the established transport for live QUIC statistics and path control.
    #[must_use]
    pub const fn connection(&self) -> &C {
        &self.connection
    }

    /// Wait for the peer's complete SETTINGS, preserving entry order and unknown IDs.
    ///
    /// Run the driver concurrently and apply the caller's handshake deadline.
    /// Cancelling this wait leaves the connection and other waiters intact. A
    /// connection failure before SETTINGS returns an error. The snapshot is
    /// cloned only when requested; observation need not be enabled.
    pub async fn peer_settings(&self) -> Result<Settings, Error> {
        self.shared.peer_settings_snapshot().await
    }

    /// Publish exact request admission for a multiplexing connection pool.
    ///
    /// A checkout reserves local request capacity and peer QUIC stream credit.
    /// The request consumes its own ticket; abandoned checkouts return both.
    /// The policy holds a weak connection reference, avoiding an extension cycle.
    pub fn connection_admission(&self) -> ConnectionAdmission
    where
        C: transport::ReserveBiStreams,
    {
        ConnectionAdmission::new(RequestAdmission {
            lifetime: Arc::downgrade(&self.lifetime),
        })
    }

    /// Received HTTP/3 datagrams this connection discarded, by reason.
    #[must_use]
    pub fn datagram_drops(&self) -> DatagramDrops {
        self.shared.datagram_drops()
    }

    #[cfg(test)]
    pub(crate) fn shared(&self) -> &Arc<Shared> {
        &self.shared
    }

    #[cfg(test)]
    pub(crate) fn dynamic_insert_count(&self) -> u64 {
        self.shared.dynamic_insert_count()
    }

    /// Take the opt-in push consumer once per connection, shared across sender clones.
    pub fn take_pushes(&self) -> Option<super::push::Pushes> {
        super::push::Pushes::take(self.shared.clone(), self.lifetime.clone())
    }

    /// Whether the underlying connection is terminal.
    pub fn is_closed(&self) -> bool {
        self.shared.error().is_some() || self.connection.close_reason().is_some()
    }

    /// Whether the peer has begun graceful shutdown.
    pub fn is_draining(&self) -> bool {
        self.shared.goaway().is_some()
    }

    /// Wait until the peer stops admitting requests or the connection fails.
    /// Active streams may continue after graceful shutdown begins.
    pub fn closed_or_draining(&self) -> impl Future<Output = Error> + Send + 'static {
        let shared = self.shared.clone();
        async move { shared.rejected(None).await }
    }

    /// Rejected early data invalidated this attempt's critical streams: retire it.
    fn early_rejection(&self) -> Option<Error> {
        (self.shared.early_attempt() && self.connection.early_data() == EarlyData::Rejected).then(
            || {
                let error = Error::early_data_rejected();
                self.shared.fail(error);
                self.connection
                    .close(self.shared.close_code(), b"early HTTP/3 rejected");
                error
            },
        )
    }

    /// A clean transport close can wake a request before the control driver has
    /// consumed its buffered GOAWAY. Wait for that bounded drain before deciding
    /// whether an incomplete response was explicitly rejected without processing.
    async fn response_error(&self, id: u64, error: Error) -> Error {
        if let Some(error) = self.early_rejection() {
            return error;
        }
        if error.code() == Code::H3_REQUEST_INCOMPLETE
            && self
                .connection
                .close_reason()
                .as_ref()
                .is_some_and(|reason| Error::from_transport(reason).is_clean_close())
        {
            let terminal = self.shared.failed().await;
            if let Some(rejection) = self.shared.rejection(Some(id)) {
                return rejection;
            }
            if !terminal.is_clean_close() {
                return terminal;
            }
        }
        self.shared.rejection(Some(id)).unwrap_or(error)
    }

    /// Check whether this connection still admits new work.
    pub async fn ready(&mut self) -> Result<(), Error> {
        self.connection
            .handshake_confirmed()
            .await
            .map_err(|error| {
                self.shared
                    .rejection(None)
                    .or_else(|| self.early_rejection())
                    .unwrap_or_else(|| Error::from_transport(&error))
            })?;
        if let Some(error) = self.early_rejection() {
            return Err(error);
        }
        if let Some(error) = self.shared.rejection(None).or_else(|| self.shared.error()) {
            return Err(error);
        }
        super::connection::validate_alpn(&self.connection, &self.shared.config)?;
        Ok(())
    }
}

struct RequestPermit<C: transport::Connection> {
    permit: Option<OwnedSemaphorePermit>,
    lifetime: Weak<ConnectionLifetime<C>>,
}

impl<C: transport::Connection> RequestPermit<C> {
    fn new(permit: OwnedSemaphorePermit, lifetime: &Arc<ConnectionLifetime<C>>) -> Self {
        Self {
            permit: Some(permit),
            lifetime: Arc::downgrade(lifetime),
        }
    }
}

impl<C: transport::Connection> Drop for RequestPermit<C> {
    fn drop(&mut self) {
        // Release first, then wake subscribers: acquiring after a wake must see
        // the returned local admission permit.
        self.permit.take();
        if let Some(lifetime) = self.lifetime.upgrade() {
            lifetime.admission_changed.notify(Change::Freed);
        }
    }
}

struct ReservedRequest<C: transport::Connection> {
    // Boxed: `send_request` takes reservations without requiring `ReserveBiStreams`.
    stream: Mutex<Option<BoxedBiReservation<C::SendStream, C::RecvStream>>>,
    permit: RequestPermit<C>,
}

/// A checkout publishes only a weak ticket: dropping its owning pool handout
/// immediately releases unused resources, even if request extensions survive.
#[derive(Clone, Debug, Extension)]
struct RequestReservation<C: transport::Connection>(Weak<ReservedRequest<C>>);

#[derive(Debug)]
struct RequestAdmission<C: transport::Connection> {
    lifetime: Weak<ConnectionLifetime<C>>,
}

/// No request was dispatched. Graceful drain means another connection can serve
/// it; an actual HTTP/3 protocol error still identifies a failing endpoint.
fn admission_error(error: Error) -> BoxError {
    let kind = if error.is_clean_close() || error.is_rejected() {
        ConnectionErrorKind::Unavailable
    } else {
        ConnectionErrorKind::Protocol
    };
    ConnectionError::application(error, kind).into()
}

impl<C: transport::ReserveBiStreams> ConnectionAdmissionPolicy for RequestAdmission<C> {
    fn try_acquire(
        &self,
        _input: &Extensions,
    ) -> Result<Option<ConnectionAdmissionLease>, BoxError> {
        let lifetime = self.lifetime.upgrade().ok_or_else(|| {
            admission_error(Error::stream(
                Code::H3_REQUEST_REJECTED,
                "HTTP/3 client released",
            ))
        })?;
        if let Some(error) = lifetime
            .shared
            .rejection(None)
            .or_else(|| lifetime.shared.error())
        {
            return Err(admission_error(error));
        }
        // Stream credit before the local permit, so no permit is ever held for a
        // ticket that does not come: nobody is refused, or answered busy, for
        // one. Without a free permit, no credit is reserved and handed back,
        // which would wake the credit's subscribers for nothing.
        if lifetime.admission.available_permits() == 0 {
            return Ok(None);
        }
        let Some(stream) = lifetime.connection.try_reserve_bi().map_err(|error| {
            let kind = if matches!(error, QuicConnectionError::TimedOut) {
                ConnectionErrorKind::Timeout
            } else {
                ConnectionErrorKind::Unavailable
            };
            ConnectionError::transport(error, kind)
        })?
        else {
            return Ok(None);
        };
        let Ok(permit) = lifetime.admission.clone().try_acquire_owned() else {
            // Another checkout took the last permit since: the credit goes back.
            return Ok(None);
        };
        let ticket = Arc::new(ReservedRequest {
            stream: Mutex::new(Some(BoxedBiReservation::new(stream))),
            permit: RequestPermit::new(permit, &lifetime),
        });
        let binding = RequestReservation(Arc::downgrade(&ticket));
        Ok(Some(ConnectionAdmissionLease::new(ticket, binding)))
    }

    fn subscribe(&self, listener: Weak<dyn ChangeListener>) {
        // Once ended or draining nothing changes any more, and its broken marking frees the
        // waiters.
        let Some(lifetime) = self.lifetime.upgrade().filter(|lifetime| {
            lifetime.connection.close_reason().is_none()
                && lifetime.shared.rejection(None).is_none()
        }) else {
            return;
        };
        // Local-permit releases, which do not alter the transport's stream limit, peer
        // credit and the close of the transport, and a GOAWAY or failure all push.
        lifetime.admission_changed.subscribe(listener.clone());
        lifetime
            .connection
            .subscribe_bi_stream_budget(listener.clone());
        lifetime.shared.subscribe_admission_end(listener);
    }

    // Requests, their bodies and upgraded tunnels hold a permit until they end. A closed,
    // draining or failed connection admits nothing more, so it is left for the pool to
    // retire: busy only while its subscribers can still learn of its work ending.
    fn in_use(&self) -> bool {
        self.lifetime.upgrade().is_some_and(|lifetime| {
            lifetime.admission.available_permits() < lifetime.max_requests
                && lifetime.connection.close_reason().is_none()
                && lifetime.shared.rejection(None).is_none()
                && lifetime.shared.error().is_none()
        })
    }
}

impl<B, C: transport::Connection> SendRequest<B, C>
where
    B: StreamingBody + Unpin + Send + 'static,
    B::Data: Send,
    B::Error: Into<BoxError>,
{
    /// Send a request on its own bidirectional QUIC stream.
    ///
    /// A request carrying a [`Protocol`] is sent as Extended CONNECT (RFC 9220) once the
    /// server's SETTINGS enable it; otherwise it fails locally before a stream is opened.
    /// A successful (2xx) response exposes the tunnel through the upgrade API.
    pub fn send_request(
        &mut self,
        request: Request<B>,
    ) -> impl Future<Output = Result<Response<crate::body::Incoming>, Error>> + Send + '_ {
        self.send_request_inner::<false, _>(request, |_| {})
    }

    /// Publish this request's priority handle after opening its stream and
    /// before sending HEADERS or awaiting the response. Relays can translate
    /// downstream priority changes while the origin is still working.
    /// The callback runs once; cancellation before stream admission never calls it.
    pub fn send_request_with_priority<F>(
        &mut self,
        request: Request<B>,
        on_stream: F,
    ) -> impl Future<Output = Result<Response<crate::body::Incoming>, Error>> + Send + '_
    where
        F: FnOnce(PriorityHandle) + Send + 'static,
    {
        self.send_request_inner::<true, _>(request, on_stream)
    }

    /// Whether this request may use TLS early keys: replay-safe and still before the decision.
    fn sends_early(&self, request: &Request<B>) -> bool {
        self.shared.early_attempt()
            && self.connection.early_data() == EarlyData::Pending
            && request.method().is_safe()
            && request.body().is_end_stream()
            && !request.extensions().contains::<Protocol>()
    }

    async fn send_request_inner<const OBSERVE: bool, F>(
        &mut self,
        mut request: Request<B>,
        on_stream: F,
    ) -> Result<Response<crate::body::Incoming>, Error>
    where
        F: FnOnce(PriorityHandle) + Send,
    {
        if !self.sends_early(&request) {
            self.ready().await?;
        }
        if request.extensions().contains::<Protocol>() {
            if request.method() != Method::CONNECT {
                return Err(Error::stream(
                    Code::H3_MESSAGE_ERROR,
                    ":protocol requires CONNECT",
                ));
            }
            // RFC 8441 §3: :protocol requires the server's SETTINGS_ENABLE_CONNECT_PROTOCOL.
            let settings = tokio::select! {
                biased;
                error = self.shared.rejected(None) => return Err(error),
                settings = self.shared.peer_settings() => settings?,
            };
            if !settings.extended_connect {
                return Err(Error::stream(
                    Code::H3_MESSAGE_ERROR,
                    "peer did not enable extended CONNECT",
                ));
            }
        }
        headers::wait_for_header_admission(&self.shared, request.extensions()).await?;
        let reserved = request
            .extensions()
            .get_ref::<RequestReservation<C>>()
            .and_then(|reservation| reservation.0.upgrade())
            // The ticket's weak lifetime keeps its address from being reused.
            .filter(|ticket| ticket.permit.lifetime.as_ptr() == Arc::as_ptr(&self.lifetime))
            .and_then(|ticket| {
                let stream = ticket.stream.lock().take()?;
                Some((stream, ticket))
            });
        let (send, recv, permit): (_, _, Arc<dyn Send + Sync>) = if let Some((stream, ticket)) =
            reserved
        {
            let (send, recv) = stream
                .open()
                .map_err(|error| Error::from_transport(&error))?;
            (send, recv, ticket)
        } else {
            let permit = tokio::select! {
                biased;
                error = self.shared.rejected(None) => return Err(error),
                permit = self.lifetime.admission.clone().acquire_owned() => Arc::new(RequestPermit::new(permit.map_err(|_error| Error::stream(Code::H3_REQUEST_REJECTED, "connection draining"))?, &self.lifetime)),
            };
            let (send, recv) = tokio::select! {
                biased;
                error = self.shared.rejected(None) => return Err(error),
                streams = self.connection.open_bi() => streams.map_err(|error| Error::from_transport(&error))?,
            };
            (send, recv, permit)
        };
        // A stream opened after a rejection would carry 1-RTT data the server processes.
        if !recv.is_0rtt()
            && let Some(error) = self.early_rejection()
        {
            return Err(error);
        }
        let id = u64::from(send.id());
        let mut reader = Reader::new(recv, self.shared.clone(), id);
        reader.abort = Some(send.boxed_handle());
        let mut writer = Writer::new(send);
        reader.client_lifetime = Some(self.lifetime.clone());
        // GOAWAY and newly available stream credit can become ready together.
        // Its limit classifies existing requests; even the maximum limit forbids
        // starting this new request (RFC 9114 section 5.2).
        if self.shared.goaway().is_some() {
            return Err(Error::stream(
                Code::H3_REQUEST_REJECTED,
                "connection draining",
            ));
        }
        // The default path uses a zero-sized callback and removes this branch
        // at monomorphization: no priority handle or observer is created for it.
        if OBSERVE {
            on_stream(PriorityHandle::new(&self.shared, id, false));
        }
        reader.origin = Some(request.uri().clone());
        // Responses fork their request's extensions, as on HTTP/1.1 and h2.
        let request_extensions = request.extensions().clone();
        let method = request.method().clone();
        let extended = method == Method::CONNECT && request.extensions().contains::<Protocol>();
        // Registered before HEADERS leave, so early replies wait for the session. Only a
        // declared Extended CONNECT has datagram semantics (RFC 9297 §2).
        let claimed = extended && request.extensions().contains::<HttpDatagrams>();
        let semantics = if claimed {
            Semantics::Claimed
        } else {
            Semantics::None
        };
        reader.datagrams = reader
            .abort
            .clone()
            .and_then(|abort| self.shared.register_datagrams(id, semantics, abort));
        let association = reader
            .datagrams
            .clone()
            .zip(reader.abort.clone())
            .filter(|_| claimed)
            .map(|(registration, send)| Association::new(registration, send));
        let informational = request.extensions().get_ref::<OnInformational>().cloned();
        // Tunnel data goes through the upgrade API, as on HTTP/2: only a body that announces
        // content is refused; any other, such as an empty one being recorded, is not sent.
        if method == Method::CONNECT
            && (content_length_parse_all(request.headers()).is_some_and(|len| len != 0)
                || request.body().size_hint().lower() > 0)
        {
            return Err(Error::stream(
                Code::H3_MESSAGE_ERROR,
                "CONNECT requires the upgrade API for tunnel data",
            ));
        }
        if method == Method::CONNECT || request.body().is_end_stream() {
            drop_undeliverable_content_length(request.headers_mut());
        }
        let (encoded, sent) = headers::encode_request_fields(&self.shared, id, &request)?;
        writer.queue(FrameType::HEADERS, encoded)?;
        let remaining = headers::content_length(request.headers())?;
        // The response records the fields its request sent.
        request_extensions.insert(RequestHeaders::from(
            sent.of(mem::take(request.headers_mut())),
        ));
        if method == Method::CONNECT {
            tokio::select! {
                biased;
                error = self.shared.rejected(Some(id)) => return Err(error),
                result = std::future::poll_fn(|cx| writer.poll_flush(cx)) => result?,
            }
            loop {
                let fields = tokio::select! {
                    biased;
                    error = self.shared.rejected(Some(id)) => return Err(error),
                    fields = reader.headers() => match fields {
                        Ok(fields) => fields,
                        Err(error) => return Err(self.response_error(id, error).await),
                    },
                };
                let response = headers::response_for_method(
                    fields,
                    method == Method::CONNECT,
                    request_extensions.fork(),
                )
                .map_err(|error| reader.reject(error.remote()))?;
                response
                    .extensions()
                    .insert(super::PriorityHandle::new(&self.shared, id, false));
                if response.status().is_informational() {
                    if let Some(callback) = &informational {
                        callback.call(response);
                    }
                    tokio::task::yield_now().await;
                    continue;
                }
                if response.status().is_success() {
                    let (pending, upgrade) = http_upgrade::pending();
                    pending.fulfill(super::upgrade::new(
                        reader,
                        writer,
                        permit,
                        None,
                        &self.connection,
                        association,
                        extended,
                    ));
                    response.extensions().insert(upgrade);
                    return Ok(response.map(|()| crate::body::Incoming::empty()));
                }
                drop(association);
                // The remaining response body carries no datagrams.
                if let Some(datagrams) = &reader.datagrams {
                    datagrams.decide(false);
                }
                std::future::poll_fn(|cx| writer.poll_finish(cx)).await?;
                match writer.acknowledged().await {
                    Ok(()) => writer.mark_acknowledged(),
                    // A final rejection can stop the CONNECT send direction while
                    // its ordinary response body remains readable.
                    Err(error) if error.is_peer_stop() => writer.reset(error.code()),
                    Err(error) => return Err(error),
                }
                let length = headers::content_length(response.headers())?;
                reader.phase = Phase::Body;
                return Ok(response
                    .map(|()| crate::body::Incoming::h3(body::Body::new(reader, length, permit))));
            }
        }
        let shared = self.shared.clone();
        let upload_permit = permit.clone();
        let upload_lifetime = self.lifetime.clone();
        let allowed_trailers = request.extensions().get_arc::<ForbiddenTrailers>();
        let (_, request_body) = request.into_parts();
        let task = self.executor.spawn_task(async move {
            let _permit = upload_permit;
            let _lifetime = upload_lifetime;
            let result = body::send(
                writer,
                request_body,
                shared.clone(),
                id,
                remaining,
                allowed_trailers,
            )
            .await;
            if let Err(error) = result
                && error.scope() == super::qpack::ErrorScope::Connection
                && !error.is_clean_close()
            {
                shared.fail(error);
            }
            result
        });
        // Aborting the upload drops Writer, which resets partial output rather than FINishing it.
        struct Upload(Option<tokio::task::JoinHandle<Result<(), Error>>>);
        impl Drop for Upload {
            fn drop(&mut self) {
                if let Some(task) = &self.0 {
                    task.abort();
                }
            }
        }
        let mut upload = Upload(Some(task));
        loop {
            let fields = {
                let head = reader.headers();
                let mut head = pin!(head);
                loop {
                    tokio::select! {
                        biased;
                        error = self.shared.rejected(Some(id)) => return Err(error),
                        result = &mut head => break match result {
                            Ok(fields) => fields,
                            Err(error) => return Err(self.response_error(id, error).await),
                        },
                        result = async {
                            match upload.0.as_mut() {
                                Some(task) => task.await,
                                None => std::future::pending().await,
                            }
                        } => {
                            upload.0 = None;
                            if let Err(error) = result.map_err(|_error| Error::stream(Code::H3_INTERNAL_ERROR, "upload task failed"))?
                                && !error.is_peer_stop() && !error.is_clean_close() { return Err(self.early_rejection().unwrap_or(error)); }
                        }
                    }
                }
            };
            let response = headers::response_for_method(
                fields,
                method == Method::CONNECT,
                request_extensions.fork(),
            )
            .map_err(|error| reader.reject(error.remote()))?;
            response
                .extensions()
                .insert(super::PriorityHandle::new(&self.shared, id, false));
            if response.status().is_informational() {
                if let Some(callback) = &informational {
                    callback.call(response);
                }
                tokio::task::yield_now().await;
                continue;
            }
            let length = if method == Method::HEAD
                || response.status() == StatusCode::NOT_MODIFIED
                || response.status() == StatusCode::NO_CONTENT
            {
                Some(0)
            } else {
                headers::content_length(response.headers())?
            };
            reader.phase = Phase::Body;
            // The upload may legitimately outlive receipt of response headers. Its lifetime
            // is transferred to the response body together with the admission permit.
            let task = upload.0.take();
            let incoming = body::Body::new(reader, length, permit).with_upload(task);
            return Ok(response.map(|()| crate::body::Incoming::h3(incoming)));
        }
    }
}
