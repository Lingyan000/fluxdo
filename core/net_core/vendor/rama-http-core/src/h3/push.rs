//! Bounded, opt-in server push. Pushes are delivered to an application, never cached implicitly.

use std::{collections::BTreeMap, sync::Arc};

use rama_core::{
    bytes::Bytes,
    extensions::{Extensions, ExtensionsRef as _},
};
use rama_http_types::{Method, Request, Response, proto::h3::Code};
use rama_quic_proto::VarInt;
use tokio::sync::{OwnedSemaphorePermit, Semaphore};

use super::{
    Error, body,
    client::ClientLifetime,
    connection::{IdControlFrame, Shared},
    control::Role,
    headers,
    qpack::FieldPair,
    stream::{Phase, Reader},
    transport::{self, BoxedRecvStream, BoxedStreamHandle, RecvStream as _},
};

#[derive(Default)]
pub(crate) struct Entry {
    fields: Option<Vec<FieldPair>>,
    request: Option<Request<()>>,
    stream: Option<(BoxedRecvStream, Bytes)>,
    stream_seen: bool,
    delivered: bool,
    promised: bool,
    cancelled: bool,
    priority: rama_http::headers::Priority,
    server_stream: Option<u64>,
    server_abort: Option<BoxedStreamHandle>,
}

pub(crate) struct State {
    entries: BTreeMap<u64, Entry>,
    next: u64,
    peer_max: Option<u64>,
    advertised_max: Option<u64>,
    consumer_taken: bool,
    consumer_closed: bool,
}

impl State {
    pub(crate) fn new() -> Self {
        Self {
            entries: BTreeMap::new(),
            next: 0,
            peer_max: None,
            advertised_max: None,
            consumer_taken: false,
            consumer_closed: false,
        }
    }

    pub(crate) fn grant(&mut self, id: u64) {
        self.advertised_max = Some(id);
    }

    fn granted(&self, id: u64) -> bool {
        self.advertised_max.is_some_and(|max| id <= max)
    }

    pub(crate) fn max_id(&mut self, id: u64) {
        self.peer_max = Some(id);
    }

    pub(crate) fn allocate(&mut self, limit: usize, goaway: Option<u64>) -> Result<u64, Error> {
        let id = self.next;
        if id >= limit as u64 || self.peer_max.is_none_or(|max| id > max) || goaway.is_some() {
            return Err(Error::stream(
                Code::H3_REQUEST_REJECTED,
                "push quota unavailable",
            ));
        }
        self.next += 1;
        self.entries.insert(id, Entry::default());
        Ok(id)
    }

    pub(crate) fn mark_promised(&mut self, id: u64) {
        if let Some(entry) = self.entries.get_mut(&id) {
            entry.promised = true;
        }
    }

    pub(crate) fn attach_stream(
        &mut self,
        id: u64,
        stream_id: u64,
        abort: BoxedStreamHandle,
    ) -> rama_http::headers::Priority {
        let entry = self.entries.entry(id).or_default();
        entry.server_stream = Some(stream_id);
        if entry.cancelled {
            abort.abort(cancelled_code());
        } else {
            entry.server_abort = Some(abort);
        }
        entry.priority
    }

    pub(crate) fn priority(
        &mut self,
        id: u64,
        priority: Option<rama_http::headers::Priority>,
    ) -> Result<Option<u64>, Error> {
        let entry = self
            .entries
            .get_mut(&id)
            .filter(|entry| entry.promised)
            .ok_or_else(invalid_id)?;
        if let Some(priority) = priority {
            entry.priority = priority;
            Ok(entry.server_stream)
        } else {
            Ok(None)
        }
    }

    pub(crate) fn reject_from(&mut self, limit: u64) {
        for (_, entry) in self.entries.range_mut(limit..) {
            entry.cancelled = true;
            if let Some(abort) = entry.server_abort.take() {
                abort.abort(cancelled_code());
            }
        }
    }

    pub(crate) fn exhausted(&self, limit: usize) -> bool {
        self.next >= limit as u64
    }

    pub(crate) fn capacity(&self, limit: usize) -> bool {
        self.next < limit as u64 && self.peer_max.is_some_and(|max| self.next <= max)
    }

    pub(crate) fn cancelled(&self, id: u64) -> bool {
        self.entries.get(&id).is_none_or(|entry| entry.cancelled)
    }
}

fn cancelled_code() -> VarInt {
    VarInt::from_u32(Code::H3_REQUEST_CANCELLED.value() as u32)
}

fn invalid_id() -> Error {
    Error::connection(Code::H3_ID_ERROR, "push ID is outside granted quota")
}

impl Shared {
    pub(crate) fn accept_push_stream(
        &self,
        id: u64,
        mut stream: impl transport::RecvStream,
        prefix: Bytes,
    ) -> Result<(), Error> {
        if !self.pushes.lock().granted(id) {
            return Err(invalid_id());
        }
        let mut pushes = self.pushes.lock();
        let entry = pushes.entries.entry(id).or_default();
        if entry.stream_seen {
            return Err(Error::connection(
                Code::H3_ID_ERROR,
                "duplicate push stream",
            ));
        }
        entry.stream_seen = true;
        let cancelled_stream = if entry.cancelled {
            let id = u64::from(stream.id());
            _ = stream.stop(cancelled_code());
            Some(id)
        } else {
            entry.stream = Some((stream.boxed(), prefix));
            None
        };
        drop(pushes);
        if let Some(id) = cancelled_stream {
            self.cancel(id);
        }
        self.push_ready.notify_waiters();
        Ok(())
    }

    pub(crate) async fn promise(
        &self,
        carrier: u64,
        id: u64,
        bytes: Bytes,
        origin: Option<rama_net::uri::Uri>,
    ) -> Result<(), Error> {
        if self.role != Role::Client || !self.pushes.lock().granted(id) {
            return Err(invalid_id());
        }
        let fields = self.decode(carrier, bytes).await?;
        let explicit_authority = fields
            .iter()
            .any(|field| field.name.as_ref() == b":authority" && !field.value.is_empty());
        let request = headers::request_head(fields.clone(), false)?;
        let valid = explicit_authority
            && matches!(*request.method(), Method::GET | Method::HEAD)
            && headers::content_length(request.headers())?.is_none_or(|length| length == 0)
            && origin.as_ref().is_some_and(|origin| {
                origin.scheme() == request.uri().scheme()
                    && origin.authority() == request.uri().authority()
            });
        {
            let mut pushes = self.pushes.lock();
            let entry = pushes.entries.entry(id).or_default();
            if let Some(previous) = &entry.fields {
                if previous
                    .iter()
                    .map(|f| (&f.name, &f.value))
                    .ne(fields.iter().map(|f| (&f.name, &f.value)))
                {
                    return Err(Error::connection(
                        Code::H3_GENERAL_PROTOCOL_ERROR,
                        "repeated push promise changed fields",
                    ));
                }
            } else if !entry.delivered && !entry.cancelled {
                entry.fields = Some(fields);
                entry.request = Some(request);
            }
        }
        if !valid || self.pushes.lock().consumer_closed {
            self.cancel_push(id, true)?;
        }
        self.push_ready.notify_waiters();
        Ok(())
    }

    pub(crate) fn cancel_push(&self, id: u64, send: bool) -> Result<(), Error> {
        let mut pushes = self.pushes.lock();
        if self.role == Role::Client {
            if !pushes.granted(id) {
                return Err(invalid_id());
            }
        } else if id >= pushes.next
            || (!send && pushes.entries.get(&id).is_none_or(|entry| !entry.promised))
        {
            return Err(invalid_id());
        }
        let entry = pushes.entries.entry(id).or_default();
        if entry.cancelled {
            return Ok(());
        }
        let send = send && (self.role != Role::Client || !entry.stream_seen);
        entry.cancelled = true;
        entry.request = None;
        if let Some(abort) = entry.server_abort.take() {
            abort.abort(cancelled_code());
        }
        let cancelled_stream = entry.stream.take().map(|(mut stream, _)| {
            let id = u64::from(stream.id());
            _ = stream.stop(cancelled_code());
            id
        });
        drop(pushes);
        // Buffered streams have no Reader to release QPACK references on drop
        // (RFC 9204 section 2.2.2.2), so cancellation must do that here.
        if let Some(id) = cancelled_stream {
            self.cancel(id);
        }
        if send {
            self.send_control_id(IdControlFrame::CancelPush(id))?;
        }
        self.push_ready.notify_waiters();
        Ok(())
    }

    pub(crate) async fn decode_for_stream(
        &self,
        stream: u64,
        push: Option<u64>,
        bytes: Bytes,
    ) -> Result<Vec<FieldPair>, Error> {
        if let Some(push) = push {
            tokio::select! {
                error = self.push_cancelled(push) => { self.cancel(stream); Err(error) },
                fields = self.decode(stream, bytes) => fields,
            }
        } else {
            self.decode(stream, bytes).await
        }
    }

    pub(crate) async fn push_cancelled(&self, id: u64) -> Error {
        loop {
            let changed = self.push_ready.notified();
            let mut changed = std::pin::pin!(changed);
            changed.as_mut().enable();
            if let Some(error) = self.receive_error() {
                return error;
            }
            if self.role == Role::Server && self.goaway().is_some_and(|limit| id >= limit) {
                return Error::stream(Code::H3_REQUEST_REJECTED, "push excluded by GOAWAY");
            }
            if self.pushes.lock().cancelled(id) {
                return Error::stream(Code::H3_REQUEST_CANCELLED, "push cancelled");
            }
            changed.await;
        }
    }
}

/// Application consumer for the connection's opt-in push quota.
/// Drop unwanted pushes to cancel them. The quota is a lifetime limit for this
/// connection, bounding even reordered promises and retained duplicate state.
pub struct Pushes {
    lifetime: Arc<dyn ClientLifetime>,
    shared: Arc<Shared>,
    admission: Arc<Semaphore>,
}

impl Pushes {
    pub(crate) fn take(shared: Arc<Shared>, lifetime: Arc<dyn ClientLifetime>) -> Option<Self> {
        let mut pushes = shared.pushes.lock();
        if pushes.consumer_taken || shared.config.max_pushes == 0 {
            return None;
        }
        pushes.consumer_taken = true;
        drop(pushes);
        Some(Self {
            lifetime,
            admission: Arc::new(Semaphore::new(shared.config.max_pushes)),
            shared,
        })
    }

    /// Wait for a promise and its push stream, regardless of arrival order.
    pub async fn next(&mut self) -> Result<Push, Error> {
        loop {
            let changed = self.shared.push_ready.notified();
            let mut changed = std::pin::pin!(changed);
            changed.as_mut().enable();
            if let Some(error) = self.shared.error() {
                return Err(error);
            }
            let ready = {
                let mut pushes = self.shared.pushes.lock();
                pushes.entries.iter_mut().find_map(|(&id, entry)| {
                    if entry.cancelled
                        || entry.delivered
                        || entry.request.is_none()
                        || entry.stream.is_none()
                    {
                        return None;
                    }
                    entry.delivered = true;
                    Some((id, entry.request.take(), entry.stream.take()))
                })
            };
            if let Some((id, Some(request), Some((stream, prefix)))) = ready {
                let stream_id = u64::from(stream.id());
                let mut reader =
                    Reader::with_prefix(stream, self.shared.clone(), stream_id, id, prefix)?;
                reader.client_lifetime = Some(self.lifetime.clone());
                let permit = Arc::new(self.admission.clone().acquire_owned().await.map_err(
                    |_error| Error::stream(Code::H3_REQUEST_CANCELLED, "push consumer closed"),
                )?);
                return Ok(Push {
                    request,
                    reader,
                    permit,
                    lease: Lease {
                        shared: self.shared.clone(),
                        id,
                        finished: false,
                    },
                });
            }
            changed.await;
        }
    }
}

impl Drop for Pushes {
    fn drop(&mut self) {
        // The configured lifetime quota bounds this scan, including not-yet-promised IDs.
        self.shared.pushes.lock().consumer_closed = true;
        for id in 0..self.shared.config.max_pushes as u64 {
            if !self.shared.pushes.lock().entries.contains_key(&id) {
                continue;
            }
            if let Err(error) = self.shared.cancel_push(id, true) {
                self.shared.fail(error);
                break;
            }
        }
    }
}

/// One promised request and its incoming response stream.
pub struct Push {
    request: Request<()>,
    reader: Reader<BoxedRecvStream>,
    permit: Arc<OwnedSemaphorePermit>,
    lease: Lease,
}

impl Push {
    /// The promised GET/HEAD request, validated against the associated request origin.
    pub fn request(&self) -> &Request<()> {
        &self.request
    }

    /// Change this push's scheduling before or after receiving its response head.
    pub fn priority_handle(&self) -> super::PriorityHandle {
        super::PriorityHandle::new(&self.reader.shared, self.lease.id, true)
    }

    /// Receive final response headers and the ordinary streaming body.
    pub async fn response(mut self) -> Result<Response<crate::body::Incoming>, Error> {
        loop {
            let response = headers::response_for_method(
                self.reader.headers().await?,
                false,
                Extensions::new(),
            )?;
            response.extensions().insert(self.priority_handle());
            if response.status().is_informational() {
                tokio::task::yield_now().await;
                continue;
            }
            let length = if self.request.method() == Method::HEAD
                || response.status() == rama_http_types::StatusCode::NO_CONTENT
                || response.status() == rama_http_types::StatusCode::NOT_MODIFIED
            {
                Some(0)
            } else {
                headers::content_length(response.headers())?
            };
            self.reader.phase = Phase::Body;
            let incoming = body::Body::new(self.reader, length, self.permit).with_push(self.lease);
            return Ok(response.map(|()| crate::body::Incoming::h3(incoming)));
        }
    }
}

pub(crate) struct Lease {
    shared: Arc<Shared>,
    id: u64,
    pub(crate) finished: bool,
}

impl Lease {
    pub(crate) fn new(shared: Arc<Shared>, id: u64) -> Self {
        Self {
            shared,
            id,
            finished: false,
        }
    }

    pub(crate) fn id(&self) -> u64 {
        self.id
    }
}

impl Drop for Lease {
    fn drop(&mut self) {
        if self.finished
            && let Some(entry) = self.shared.pushes.lock().entries.get_mut(&self.id)
        {
            entry.server_abort = None;
        }
        if !self.finished
            && let Err(error) = self.shared.cancel_push(self.id, true)
        {
            self.shared.fail(error);
        }
    }
}

#[cfg(test)]
mod tests {
    use std::assert_matches;

    use rama_core::futures::FutureExt as _;

    use super::*;
    use crate::h3::{
        connection::Config,
        qpack::{Encoder, EncoderConfig},
    };

    fn shared() -> Arc<Shared> {
        let shared = Shared::new(
            Config {
                max_pushes: 2,
                ..Config::default()
            },
            Role::Client,
            Default::default(),
        )
        .unwrap();
        shared.pushes.lock().grant(1);
        shared
    }

    fn promise(path: &'static str) -> Bytes {
        let mut encoder = Encoder::before_peer_settings(EncoderConfig::default());
        encoder
            .encode(
                0,
                [
                    (":method", "GET"),
                    (":scheme", "https"),
                    (":authority", "example.com"),
                    (":path", path),
                ],
            )
            .unwrap()
    }

    #[tokio::test]
    async fn extreme_push_ids_never_expand_the_local_quota() {
        for role in [Role::Client, Role::Server] {
            for quota in [0, 2] {
                for id in [0, 1, 2, (1u64 << 62) - 1] {
                    let shared = Shared::new(
                        Config {
                            max_pushes: quota,
                            ..Config::default()
                        },
                        role,
                        Default::default(),
                    )
                    .unwrap();
                    {
                        let mut pushes = shared.pushes.lock();
                        pushes.max_id((1u64 << 62) - 1);
                        if quota != 0 {
                            pushes.grant(quota as u64 - 1);
                        }
                        if role == Role::Server {
                            for expected in 0..quota as u64 {
                                assert_eq!(pushes.allocate(quota, None).unwrap(), expected);
                                pushes.mark_promised(expected);
                            }
                            pushes.allocate(quota, None).unwrap_err();
                        }
                    }
                    let before = shared.pushes.lock().entries.len();
                    let cancellation = shared.cancel_push(id, false);
                    if id < quota as u64 {
                        cancellation.unwrap();
                    } else {
                        assert_eq!(cancellation.unwrap_err().code(), Code::H3_ID_ERROR);
                        assert_eq!(shared.pushes.lock().entries.len(), before);
                    }
                    let origin = Some(rama_net::uri::Uri::parse("https://example.com/").unwrap());
                    let received = shared.promise(0, id, promise("/a"), origin).await;
                    if role == Role::Client && id < quota as u64 {
                        received.unwrap();
                    } else {
                        assert_eq!(received.unwrap_err().code(), Code::H3_ID_ERROR);
                    }
                    assert!(shared.pushes.lock().entries.len() <= quota);
                }
            }
        }
    }

    #[test]
    fn client_cancels_only_pushes_whose_stream_has_not_arrived() {
        for stream_seen in [false, true] {
            let shared = shared();
            shared.pushes.lock().entries.insert(
                0,
                Entry {
                    stream_seen,
                    ..Entry::default()
                },
            );
            shared.cancel_push(0, true).unwrap();
            assert_eq!(
                shared.control_flushed().now_or_never().is_some(),
                stream_seen
            );
        }
    }

    #[test]
    fn server_announces_cancel_even_after_opening_a_push_stream() {
        let shared = Shared::new(
            Config {
                max_pushes: 1,
                ..Config::default()
            },
            Role::Server,
            Default::default(),
        )
        .unwrap();
        {
            let mut pushes = shared.pushes.lock();
            pushes.next = 1;
            pushes.entries.insert(
                0,
                Entry {
                    promised: true,
                    stream_seen: true,
                    ..Entry::default()
                },
            );
        }
        shared.cancel_push(0, true).unwrap();
        assert!(shared.control_flushed().now_or_never().is_none());
    }

    #[tokio::test]
    async fn configured_quota_does_not_authorize_unsolicited_push() {
        let shared = Shared::new(
            Config {
                max_pushes: 2,
                ..Config::default()
            },
            Role::Client,
            Default::default(),
        )
        .unwrap();
        assert_eq!(
            shared
                .promise(0, 0, promise("/a"), None)
                .await
                .unwrap_err()
                .code(),
            Code::H3_ID_ERROR
        );
    }

    #[tokio::test]
    async fn repeated_live_promise_is_compared_after_delivery() {
        let shared = shared();
        let origin = Some(rama_net::uri::Uri::parse("https://example.com/").unwrap());
        shared
            .promise(0, 0, promise("/a"), origin.clone())
            .await
            .unwrap();
        shared.pushes.lock().entries.get_mut(&0).unwrap().delivered = true;
        shared
            .promise(4, 0, promise("/a"), origin.clone())
            .await
            .unwrap();
        assert_eq!(
            shared
                .promise(8, 0, promise("/b"), origin)
                .await
                .unwrap_err()
                .code(),
            Code::H3_GENERAL_PROTOCOL_ERROR
        );
    }

    #[tokio::test]
    async fn reordered_cancellation_does_not_deliver_later_promise() {
        let shared = shared();
        shared.cancel_push(0, false).unwrap();
        shared
            .promise(
                0,
                0,
                promise("/a"),
                Some(rama_net::uri::Uri::parse("https://example.com/").unwrap()),
            )
            .await
            .unwrap();
        let pushes = shared.pushes.lock();
        assert!(pushes.entries[&0].cancelled);
        assert!(pushes.entries[&0].request.is_none());
    }

    #[tokio::test]
    async fn cancel_interrupts_qpack_blocked_push_headers() {
        use std::{
            future::Future as _,
            task::{Context, Poll, Waker},
        };
        let shared = shared();
        shared.pushes.lock().entries.insert(0, Entry::default());
        let mut encoder = Encoder::new(EncoderConfig::default());
        let encoded = encoder
            .encode(
                3,
                [
                    (":status", "200"),
                    ("x-dynamic", "requires missing insertion"),
                ],
            )
            .unwrap();
        assert!(encoder.insert_count() > 0);
        let mut decode = Box::pin(shared.decode_for_stream(3, Some(0), encoded));
        assert_matches!(
            decode
                .as_mut()
                .poll(&mut Context::from_waker(Waker::noop())),
            Poll::Pending,
        );
        shared.cancel_push(0, false).unwrap();
        assert_eq!(decode.await.unwrap_err().code(), Code::H3_REQUEST_CANCELLED);
    }

    #[test]
    fn server_rejects_cancel_for_allocated_but_unpromised_id() {
        let shared = Shared::new(
            Config {
                max_pushes: 1,
                ..Config::default()
            },
            Role::Server,
            Default::default(),
        )
        .unwrap();
        shared.pushes.lock().max_id(0);
        let id = shared.pushes.lock().allocate(1, None).unwrap();
        assert_eq!(
            shared.cancel_push(id, false).unwrap_err().code(),
            Code::H3_ID_ERROR
        );
        shared.pushes.lock().mark_promised(id);
        shared.cancel_push(id, false).unwrap();
    }
}
