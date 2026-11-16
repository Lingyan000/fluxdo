//! Connection-local HTTP/2 alternative-service advertisements.

use crate::conn::HttpOrigin;
use crate::proto::h2::frame;
use rama_core::{
    bytes::Bytes,
    extensions::{Extension, Extensions},
};
use rama_utils::octets::kib;
use std::{
    sync::atomic::{AtomicU64, Ordering},
    time::{Instant as StdInstant, SystemTime},
};
use tokio::sync::mpsc;
use tokio::time::Instant;

/// Bound queued server advertisements independently of stream flow control.
pub const ALT_SVC_QUEUE_CAPACITY: usize = 8;

/// Maximum observed or queued advertisement payload, including its origin.
///
/// This also fits the minimum HTTP/2 peer frame-size limit.
pub const ALT_SVC_MAX_PAYLOAD: usize = kib(16);

/// Origin established by the frame's connection or request-stream association.
#[derive(Clone, Debug)]
pub enum AltSvcOrigin {
    /// Origin serialized in a stream-zero frame; the consumer must authorize it.
    Explicit(Bytes),
    /// Origin captured from the request that opened the associated stream.
    Request(HttpOrigin),
}

/// An advertisement received on this connection, never a relay instruction.
#[derive(Clone, Debug)]
pub struct AltSvcEvent {
    pub origin: AltSvcOrigin,
    pub field_value: Bytes,
    pub received_at: Instant,
    /// Tie-breaker for receipts within the same monotonic clock tick.
    pub sequence: u64,
}

/// Receipt time of an HTTP/2 response carrying an Alt-Svc field.
///
/// Installed by an observing connection before handing headers to the response
/// consumer. This preserves ordering against subsequent ALTSVC frames even when
/// the application polls its response later. Wall time is captured alongside the
/// monotonic time so response age does not depend on application scheduling.
#[derive(Clone, Copy, Debug, Extension)]
pub struct AltSvcReceivedAt {
    pub instant: StdInstant,
    pub wall: SystemTime,
    /// Process-local ordering for receipts within the same clock tick.
    pub sequence: u64,
}

impl AltSvcReceivedAt {
    /// Capture receipt time before publishing an advertisement to consumers.
    pub fn now() -> Self {
        static NEXT: AtomicU64 = AtomicU64::new(0);
        Self {
            instant: StdInstant::now(),
            wall: SystemTime::now(),
            sequence: NEXT.fetch_add(1, Ordering::Relaxed),
        }
    }
}

/// Receive connection-local alternative-service observations directly.
///
/// The HTTP/2 driver calls this synchronously. Implementations must return
/// promptly, bound retained state, and authorize the advertised origin against
/// the established connection metadata before using an advertisement.
/// No observer is installed by default, and observations are never relayed.
pub trait AltSvcObserver: Send + Sync + 'static {
    fn observe(&self, event: AltSvcEvent, connection: &Extensions);
}

/// Opt in to ALTSVC observations before the HTTP/2 client handshake.
///
/// Install this on connection extensions. The HTTP connector also forwards an
/// explicitly configured input observer when the established HTTP/2 transport
/// has no observer of its own.
/// The extension store shares this value; no extra channel or task is created.
#[derive(Extension)]
pub struct AltSvcObserverExtension(Box<dyn AltSvcObserver>);

impl AltSvcObserverExtension {
    pub fn new(observer: impl AltSvcObserver) -> Self {
        Self(Box::new(observer))
    }

    /// Deliver one bounded frame observation from this connection's driver.
    pub fn observe(&self, event: AltSvcEvent, connection: &Extensions) {
        self.0.observe(event, connection);
    }
}

impl std::fmt::Debug for AltSvcObserverExtension {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("AltSvcObserverExtension")
            .finish_non_exhaustive()
    }
}

/// Explicit server-side ALTSVC emission on one HTTP/2 connection.
///
/// Installed on server connection extensions when ALTSVC emission is enabled
/// on the server builder, and inherited by its requests.
/// Advertisements are never copied from received frames automatically.
#[derive(Clone, Debug, Extension)]
pub struct AltSvcSender(mpsc::Sender<frame::AltSvc>);

impl AltSvcSender {
    /// Create the endpoint pair used by an HTTP/2 connection driver.
    pub fn channel() -> (Self, mpsc::Receiver<frame::AltSvc>) {
        let (sender, receiver) = mpsc::channel(ALT_SVC_QUEUE_CAPACITY);
        (Self(sender), receiver)
    }

    /// Queue a frame without blocking request handling.
    ///
    /// A nonzero stream ID must identify the request whose origin is being
    /// advertised. The sender does not keep a separate stream registry;
    /// use stream zero with an explicit origin for connection-level hints.
    pub fn try_send(&self, frame: frame::AltSvc) -> Result<(), AltSvcSendError> {
        if frame.payload_len() > ALT_SVC_MAX_PAYLOAD {
            return Err(AltSvcSendError::TooLarge);
        }
        self.0.try_send(frame).map_err(|error| match error {
            mpsc::error::TrySendError::Full(_) => AltSvcSendError::Full,
            mpsc::error::TrySendError::Closed(_) => AltSvcSendError::Closed,
        })
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum AltSvcSendError {
    Disabled,
    TooLarge,
    Full,
    Closed,
}

impl std::fmt::Display for AltSvcSendError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(match self {
            Self::Disabled => "ALTSVC emission was not enabled before the handshake",
            Self::TooLarge => "ALTSVC advertisement exceeds the connection limit",
            Self::Full => "ALTSVC advertisement queue is full",
            Self::Closed => "HTTP/2 connection is closed",
        })
    }
}

impl std::error::Error for AltSvcSendError {}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::proto::h2::frame::StreamId;

    #[test]
    fn emission_limits_queue_payload_and_connection_lifetime() {
        let (sender, receiver) = AltSvcSender::channel();
        let frame = frame::AltSvc::new(
            StreamId::zero(),
            Bytes::from_static(b"https://example.com"),
            Bytes::from_static(b"clear"),
        )
        .unwrap();
        let oversized = frame::AltSvc::new(
            StreamId::from(1),
            Bytes::new(),
            Bytes::from(vec![b'x'; ALT_SVC_MAX_PAYLOAD]),
        )
        .unwrap();
        assert_eq!(sender.try_send(oversized), Err(AltSvcSendError::TooLarge));
        for _ in 0..ALT_SVC_QUEUE_CAPACITY {
            sender.try_send(frame.clone()).unwrap();
        }
        assert_eq!(sender.try_send(frame.clone()), Err(AltSvcSendError::Full));
        drop(receiver);
        assert_eq!(sender.try_send(frame), Err(AltSvcSendError::Closed));
    }
}
