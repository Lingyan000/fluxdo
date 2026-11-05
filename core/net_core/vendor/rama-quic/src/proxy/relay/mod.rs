//! Bounded forwarding between two separately authenticated QUIC connections.
//!
//! Each peer can initiate uni- and bidirectional streams. The relay preserves
//! stream bytes, FIN, reset and stop codes; it creates new stream identifiers and
//! does not translate identifiers embedded in application data. Protocols such as
//! HTTP/3 require their own protocol-aware relay. Packet layout, ACKs, secrets,
//! congestion state and timing belong to each independent connection.

use std::{
    future::{Future, pending},
    num::NonZeroUsize,
    pin::pin,
};

use rama_core::{
    Service,
    error::{BoxError, BoxErrorExt as _},
    extensions::ExtensionsRef as _,
    futures::{StreamExt as _, stream::FuturesUnordered},
    io::BridgeIo,
};
use rama_net::tls::ApplicationProtocol;
use rama_quic_proto::{Side, VarInt};
use rama_utils::{macros::generate_set_and_with, octets::kib};

use crate::{
    Connection, ConnectionError, NegotiatedTlsParameters, ReadError, RecvStream, SendStream,
    WriteError,
};

/// Relay dedicated QUIC connections through Rama's ordinary service boundary.
///
/// The input is [`BridgeIo<Connection, Connection>`]: ingress is the server
/// connection and egress is the client connection. This service forwards streams
/// and optional connection datagrams after both handshakes complete; interception
/// and certificate negotiation belong to the preceding handshake service.
/// Ordinary QUIC clients and servers do not construct this opt-in relay.
///
/// Each terminated hop keeps its own transport policy, RTT estimator and spin signal.
/// This relay forwards application data, never a downstream spin bit into an upstream
/// packet header. Configure [`crate::TransportConfig::set_allow_spin`] separately on each hop.
#[derive(Debug, Clone, Copy)]
pub struct QuicRelay {
    /// Maximum active or opening streams in each initiator/direction class.
    /// There are four classes, so the total is at most four times this value.
    streams_per_class: NonZeroUsize,
    /// Maximum bytes retained by each copy direction outside the QUIC engine.
    chunk_bytes: NonZeroUsize,
    /// Forward connection datagrams in both directions. Both hops must negotiate
    /// reception; an oversized datagram fails explicitly rather than truncating.
    datagrams: bool,
    /// Application error used when the relay itself fails or is cancelled.
    /// A peer's application close is forwarded with its original code and reason, and ends
    /// the relay successfully.
    failure_code: VarInt,
}

impl QuicRelay {
    /// Create a relay with 32 streams per class, 16 KiB copy buffers and no
    /// datagram forwarding. `failure_code` belongs to the carried application
    /// protocol; QUIC has no universal application error code for relay failure.
    #[must_use]
    #[expect(clippy::expect_used, reason = "nonzero compile-time defaults")]
    pub const fn new(failure_code: VarInt) -> Self {
        Self {
            streams_per_class: NonZeroUsize::new(32).expect("nonzero stream limit"),
            chunk_bytes: NonZeroUsize::new(kib(16)).expect("nonzero copy buffer"),
            datagrams: false,
            failure_code,
        }
    }

    generate_set_and_with! {
        /// Maximum active or opening streams in each of the four classes:
        /// ingress/egress initiation, each uni/bidirectional. Credit-blocked
        /// openings count toward this limit. At most four times this many stream
        /// pairs are retained; accepting one class never starves another.
        pub fn streams_per_class(mut self, limit: NonZeroUsize) -> Self {
            self.streams_per_class = limit;
            self
        }
    }

    generate_set_and_with! {
        /// Maximum bytes in each copy buffer outside the QUIC engines. A uni
        /// stream needs one buffer; a bidirectional stream needs two. All four
        /// full stream classes therefore retain at most `6 * streams_per_class`
        /// buffers. Engine flow-control budgets remain independently configured.
        pub fn chunk_bytes(mut self, bytes: NonZeroUsize) -> Self {
            self.chunk_bytes = bytes;
            self
        }
    }

    generate_set_and_with! {
        /// Forward native QUIC datagrams in both directions. Configure both
        /// connections' receive advertisements consistently before handshaking.
        /// Each forwarding direction retains at most one datagram; oversized
        /// datagrams close both connections with `failure_code` and are never
        /// truncated. This is an intentional failure policy for applications that
        /// require explicit detection of incompatible hop limits; choose receive
        /// limits compatible with both hops before enabling this relay.
        pub fn datagrams(mut self, enabled: bool) -> Self {
            self.datagrams = enabled;
            self
        }
    }

    async fn run(self, guard: CloseOnDrop) -> Result<(), BoxError> {
        let ingress = &guard.ingress;
        let egress = &guard.egress;
        if ingress.side() != Side::Server || egress.side() != Side::Client {
            return Err(BoxError::from_static_str(
                "QUIC relay needs a server and a client connection",
            ));
        }
        tokio::try_join!(ingress.handshake_confirmed(), egress.handshake_confirmed())?;
        let ingress_alpn = negotiated_alpn(ingress);
        let egress_alpn = negotiated_alpn(egress);
        if ingress_alpn.is_none() || ingress_alpn != egress_alpn {
            return Err(BoxError::from_static_str(
                "QUIC relay negotiated application protocols differ or are absent",
            ));
        }
        if ingress.early_data_keys_enabled() || egress.early_data_keys_enabled() {
            return Err(BoxError::from_static_str(
                "QUIC relay requires early data disabled",
            ));
        }
        if self.datagrams
            && [ingress, egress]
                .iter()
                .any(|conn| !conn.datagram_receive_enabled() || conn.max_datagram_size().is_none())
        {
            return Err(BoxError::from_static_str(
                "QUIC relay datagram capability mismatch",
            ));
        }

        if !self.datagrams
            && [ingress, egress]
                .iter()
                .any(|conn| conn.datagram_receive_enabled())
        {
            return Err(BoxError::from_static_str(
                "QUIC relay disabled datagrams were advertised",
            ));
        }

        // Each stream class has its own bounded work set. Waiting for outbound
        // credit never stops existing copies or the other initiator's accepts.
        tokio::select! {
            result = async {
                tokio::try_join!(
                    self.unidirectional(ingress, egress),
                    self.unidirectional(egress, ingress),
                    self.bidirectional(ingress, egress),
                    self.bidirectional(egress, ingress),
                    self.forward_datagrams(ingress, egress),
                    self.forward_datagrams(egress, ingress),
                )?;
                Ok(())
            } => {
                // A stream can observe the same peer close before closed() is
                // polled. Preserve its application code in either scheduling order.
                if let Some(reason) = ingress.close_reason() {
                    propagate_close(egress, reason, self.failure_code)
                } else if let Some(reason) = egress.close_reason() {
                    propagate_close(ingress, reason, self.failure_code)
                } else {
                    result
                }
            },
            reason = ingress.closed() => propagate_close(egress, reason, self.failure_code),
            reason = egress.closed() => propagate_close(ingress, reason, self.failure_code),
        }
    }

    async fn unidirectional(self, from: &Connection, to: &Connection) -> Result<(), BoxError> {
        let mut work = FuturesUnordered::new();
        loop {
            tokio::select! {
                accepted = from.accept_uni(), if work.len() < self.streams_per_class.get() => {
                    let mut recv = accepted?;
                    work.push(async move {
                        let send = tokio::select! {
                            opened = to.open_uni() => opened?,
                            reset = recv.received_reset() => {
                                if reset?.is_some() {
                                    return Ok(());
                                }
                                to.open_uni().await?
                            }
                        };
                        copy(recv, send, self.chunk_bytes).await
                    });
                }
                Some(result) = work.next(), if !work.is_empty() => result?,
            }
        }
    }

    async fn bidirectional(self, from: &Connection, to: &Connection) -> Result<(), BoxError> {
        let mut work = FuturesUnordered::new();
        loop {
            tokio::select! {
                accepted = from.accept_bi(), if work.len() < self.streams_per_class.get() => {
                    let (send, recv) = accepted?;
                    work.push(relay_bidi(recv, send, to, self.chunk_bytes));
                }
                Some(result) = work.next(), if !work.is_empty() => result?,
            }
        }
    }

    async fn forward_datagrams(self, from: &Connection, to: &Connection) -> Result<(), BoxError> {
        if !self.datagrams {
            return pending().await;
        }
        loop {
            let datagram = from.read_datagram().await?;
            // Backpressure retains at most one datagram here; the engine's own
            // negotiated receive budget bounds the remaining unreliable queue.
            to.send_datagram_wait(datagram).await?;
        }
    }
}

impl Service<BridgeIo<Connection, Connection>> for QuicRelay {
    type Output = ();
    type Error = BoxError;

    /// Relay dedicated, established connections until either connection ends.
    ///
    /// `ingress` is a server connection and `egress` a client connection.
    /// Both hops must negotiate the same nonempty ALPN. Do not consume their
    /// streams or datagrams concurrently elsewhere. Configure receive datagram
    /// advertisements to match this policy before establishing either hop. Neither
    /// hop may have enabled early-data keys: this generic relay does not decide
    /// application replay safety. Configure TLS early data off on both hops.
    ///
    /// Dropping this future closes both connections, including streams waiting
    /// for remote credit. Connection-level transport errors are returned locally
    /// and mapped to `failure_code` on the other hop; they are not fabricated as
    /// transport errors belonging to that independent connection.
    fn serve(
        &self,
        BridgeIo(ingress, egress): BridgeIo<Connection, Connection>,
    ) -> impl Future<Output = Result<(), BoxError>> + Send + '_ {
        let guard = CloseOnDrop {
            ingress,
            egress,
            code: self.failure_code,
        };
        let relay = *self;
        // Acquire cancellation ownership at invocation, before the first poll.
        async move { relay.run(guard).await }
    }
}

struct CloseOnDrop {
    ingress: Connection,
    egress: Connection,
    code: VarInt,
}

impl Drop for CloseOnDrop {
    fn drop(&mut self) {
        self.ingress.close(self.code, b"QUIC relay ended");
        self.egress.close(self.code, b"QUIC relay ended");
    }
}

fn negotiated_alpn(connection: &Connection) -> Option<ApplicationProtocol> {
    connection
        .extensions()
        .get_ref::<NegotiatedTlsParameters>()?
        .application_layer_protocol
        .clone()
        .filter(|protocol| !protocol.as_bytes().is_empty())
}

fn propagate_close(
    to: &Connection,
    reason: ConnectionError,
    fallback: VarInt,
) -> Result<(), BoxError> {
    // An application closing its connection is how a relayed exchange normally ends: relaying
    // that close faithfully is success. Anything else is a failure of that hop.
    if let ConnectionError::ApplicationClosed(close) = &reason {
        to.close(close.error_code, &close.reason);
        return Ok(());
    }
    to.close(fallback, b"QUIC relay peer failed");
    Err(reason.into())
}

async fn relay_bidi(
    mut recv: RecvStream,
    send: SendStream,
    to: &Connection,
    maximum: NonZeroUsize,
) -> Result<(), BoxError> {
    let mut request_reset = None;
    let mut response_stopped = None;
    let mut watch_reset = true;
    let (mut other_send, mut other_recv) = {
        let mut stopped = pin!(send.stopped());
        loop {
            // A single cancelled direction still leaves the other one meaningful.
            // When both end before credit arrives, release this pending relay slot.
            if request_reset.is_some() && response_stopped.is_some() {
                return Ok(());
            }
            tokio::select! {
                opened = to.open_bi() => break opened?,
                reset = recv.received_reset(), if watch_reset => {
                    request_reset = reset?;
                    watch_reset = false;
                }
                stopped = &mut stopped, if response_stopped.is_none() => {
                    response_stopped = stopped?;
                    if response_stopped.is_none() {
                        return Err(BoxError::from_static_str("relay send ended before opening its peer stream"));
                    }
                }
            }
        }
    };

    // One direction resetting does not discard data still valid in the other.
    tokio::try_join!(
        async {
            if let Some(code) = request_reset {
                let _already_closed = other_send.reset(code);
                Ok(())
            } else {
                copy(recv, other_send, maximum).await
            }
        },
        async {
            if let Some(code) = response_stopped {
                let _already_closed = other_recv.stop(code);
                Ok(())
            } else {
                copy(other_recv, send, maximum).await
            }
        },
    )?;
    Ok(())
}

async fn copy(
    mut from: RecvStream,
    mut to: SendStream,
    maximum: NonZeroUsize,
) -> Result<(), BoxError> {
    // A fixed buffer gives this copy an exact retention bound. A short slice
    // from read_chunk could otherwise keep a larger shared packet allocation alive.
    let mut buffer = vec![0; maximum.get()];
    let mut stopped = pin!(to.stopped());
    loop {
        let next = tokio::select! {
            next = from.read(&mut buffer) => next,
            stopped = &mut stopped => {
                if let Some(code) = stopped? {
                    let _already_closed = from.stop(code);
                }
                return Ok(());
            }
        };
        let read = match next {
            Ok(Some(read)) => read,
            Ok(None) => {
                to.finish()?;
                if let Some(code) = stopped.await? {
                    let _already_closed = from.stop(code);
                }
                return Ok(());
            }
            Err(ReadError::Reset(code)) => {
                let _already_closed = to.reset(code);
                return Ok(());
            }
            Err(error) => return Err(error.into()),
        };

        // A stop wakes a direction even while no input arrives or its write is
        // blocked by flow control. Forward the peer's code without translation.
        let written = {
            let mut write = pin!(to.write_all(&buffer[..read]));
            let mut watch_reset = true;
            loop {
                tokio::select! {
                    written = &mut write => break Ok(written),
                    reset = from.received_reset(), if watch_reset => {
                        match reset? {
                            Some(code) => break Err(code),
                            None => watch_reset = false,
                        }
                    }
                    stopped = &mut stopped => {
                        if let Some(code) = stopped? {
                            let _already_closed = from.stop(code);
                        }
                        return Ok(());
                    }
                }
            }
        };
        let written = match written {
            Ok(written) => written,
            Err(code) => {
                let _already_closed = to.reset(code);
                return Ok(());
            }
        };
        match written {
            Ok(()) => {}
            Err(WriteError::Stopped(code)) => {
                let _already_closed = from.stop(code);
                return Ok(());
            }
            Err(error) => return Err(error.into()),
        }
    }
}

#[cfg(all(
    test,
    any(
        feature = "boring",
        all(feature = "rustls", any(feature = "aws-lc", feature = "ring"))
    )
))]
mod tests;
