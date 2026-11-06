use std::{
    fmt,
    future::Future,
    io,
    net::{IpAddr, SocketAddr},
    pin::Pin,
    sync::{
        Arc, Weak,
        atomic::{AtomicU64, AtomicUsize, Ordering},
    },
    task::{Context, Poll, Waker, ready},
};

use parking_lot::Mutex;
use pin_project_lite::pin_project;
use rama_core::{
    bytes::Bytes,
    extensions::{Extension, Extensions, ExtensionsRef},
    telemetry::tracing::{Instrument, Span, debug, debug_span},
};
use rama_net::{
    gate::{DatagramGates, GateDirection, StreamGates},
    stream::SocketInfo,
};
use rama_quic_proto::{ConnectionId, Dir, Side, StreamId, VarInt, Version};
use rama_udp::SendFailure;
use rama_utils::reactive::{Change, ChangeListener, Changed, Reactive};
use rustc_hash::FxHashMap;
use tokio::sync::{
    Notify,
    futures::{Notified, OwnedNotified},
    oneshot,
};

use crate::{
    driver::{
        Duration, IO_LOOP_BOUND, QueuedPacket,
        endpoint::{EndpointInner, LocalSocket, ceiling::payload_ceiling},
        gate::{ConnectionDatagramGates, ConnectionGates, GateStack},
        now,
        queue::{BoundedReceiver, PacketBudget, PacketQueueStats},
        recv_stream::RecvStream,
        send_stream::SendStream,
        sockets::SocketId,
        timer::{Deadline, DeadlineTimer},
        udp::{FailureLog, SendError, Sender, known_local_address},
    },
    proto::{
        AdmissionLease, ConnectionError, ConnectionHandle, ConnectionStats, EndpointEvent, Event,
        GatedDatagramStats, NegotiatedTlsParameters, SendDatagramError as ProtoSendDatagramError,
        SendPermit, StreamEvent,
    },
};

/// Tests: the bytes a connection keeps allocated for sending, split by where they are.
#[cfg(all(
    test,
    any(
        feature = "boring",
        all(feature = "rustls", any(feature = "aws-lc", feature = "ring"))
    )
))]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) struct RetainedSend {
    /// The engine's write buffer, reused across descriptors.
    pub(crate) buffer: usize,
    /// The bytes of the descriptors that took a copy of their own.
    pub(crate) owned: usize,
    /// How many descriptors hold their own bytes.
    pub(crate) slots: usize,
}

/// Tests: one descriptor this connection offered to its sender, and what became of it.
#[cfg(test)]
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct Descriptor {
    pub(crate) id: u64,
    pub(crate) size: usize,
    /// The bytes offered, so a test can compare what reached the socket with what was built.
    pub(crate) bytes: Vec<u8>,
    pub(crate) segment_size: Option<usize>,
    pub(crate) destination: SocketAddr,
    pub(crate) cid_used: Option<u64>,
    pub(crate) outcome: Outcome,
    /// Whether the connection was actually told this offer's identifier reached the network. It
    /// is observed from the connection's own report count across this offer's processing, not
    /// copied from the condition that should cause the call.
    pub(crate) reported: bool,
}

/// Tests: what became of a descriptor that was offered.
#[cfg(test)]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum Outcome {
    /// Taken in full.
    Sent,
    /// The sender was not ready. The same descriptor is retained and offered again.
    Pending,
    /// Held because the route its identifier needs is not installed.
    Awaiting,
    /// Given up: its identifier may never be sent again.
    Obsolete,
    /// The sender refused it.
    Failed,
}

/// Tests: how many descriptor records are kept.
#[cfg(test)]
const DESCRIPTORS: usize = 64;

/// In-progress connection attempt future
#[derive(Debug)]
pub struct Connecting {
    conn: Option<ConnectionRef>,
    connected: oneshot::Receiver<Result<bool, ConnectionError>>,
    handshake_data_ready: Option<oneshot::Receiver<()>>,
    /// What a client attempt needs to try again in another version after a Version
    /// Negotiation packet (RFC 9368 §2.1). Taken by the one restart an attempt may make.
    restart: Option<Restart>,
}

/// The inputs of a client attempt, kept so a Version Negotiation packet can restart it.
#[derive(Debug)]
struct Restart {
    endpoint: crate::driver::Endpoint,
    config: crate::proto::ClientConfig,
    addr: SocketAddr,
    server_name: String,
}

impl Connecting {
    /// Tests: hold or release this (server-side) connection's HANDSHAKE_DONE before the
    /// handshake completes, so the peer can be observed complete but unconfirmed.
    #[cfg(all(
        test,
        any(
            feature = "boring",
            all(feature = "rustls", any(feature = "aws-lc", feature = "ring"))
        )
    ))]
    pub(crate) fn hold_handshake_done(&self, hold: bool) {
        if let Some(conn) = &self.conn {
            let conn = &mut *conn.state.lock();
            conn.inner.hold_handshake_done(hold);
            conn.wake();
        }
    }

    #[expect(
        clippy::expect_used,
        reason = "the connection is removed only after this future yields Ready or is consumed into early data"
    )]
    fn connection_ref(&self) -> &ConnectionRef {
        self.conn
            .as_ref()
            .expect("Connecting used after completion")
    }

    /// Refuse this (server-side) attempt while its handshake runs, as a new attempt is refused.
    pub(crate) fn refuse(self) {
        self.connection_ref()
            .close_transport(rama_quic_proto::TransportError::CONNECTION_REFUSED(""));
    }

    #[expect(
        clippy::expect_used,
        reason = "a connection is taken once; repolling a completed future violates its contract"
    )]
    fn take_connection(&mut self) -> ConnectionRef {
        self.conn.take().expect("Connecting used after completion")
    }

    /// Build the connection state and its driver. The driver is returned unspawned so the
    /// caller can register the connection first and submit the driver with no lock held
    /// (see [`ConnectionDriver::spawn`]).
    pub(crate) fn new(
        handle: ConnectionHandle,
        conn: crate::proto::Connection,
        endpoint: EndpointLink,
        packets: BoundedReceiver<QueuedPacket>,
        socket: Sender,
        receive_queue: PacketBudget,
        admission: Option<AdmissionLease>,
    ) -> (Self, ConnectionDriver) {
        let (on_handshake_data_send, on_handshake_data_recv) = oneshot::channel();
        let (on_connected_send, on_connected_recv) = oneshot::channel();
        let conn = ConnectionRef::new(
            handle,
            conn,
            endpoint,
            packets,
            on_handshake_data_send,
            on_connected_send,
            socket,
            receive_queue,
            admission,
        );
        let driver = ConnectionDriver::new(conn.0.clone());
        (
            Self {
                conn: Some(conn),
                connected: on_connected_recv,
                handshake_data_ready: Some(on_handshake_data_recv),
                restart: None,
            },
            driver,
        )
    }

    /// Let this client attempt start over in another version if the server answers with a
    /// Version Negotiation packet.
    pub(crate) fn with_restart(
        mut self,
        endpoint: crate::driver::Endpoint,
        config: crate::proto::ClientConfig,
        addr: SocketAddr,
        server_name: &str,
    ) -> Self {
        self.restart = Some(Restart {
            endpoint,
            config,
            addr,
            server_name: server_name.into(),
        });
        self
    }

    /// RFC 9368 §2.1: pick a mutually supported version from what the server offered and send
    /// a new first flight with it. The new attempt remembers the offer, so it ignores further
    /// Version Negotiation packets and checks the server's `version_information` against it.
    fn restart_after_version_negotiation(
        &mut self,
        offered: Vec<rama_quic_proto::Version>,
    ) -> Result<(), ConnectionError> {
        let mismatch = |offered| ConnectionError::VersionMismatch { offered };
        let Some(restart) = self.restart.take() else {
            return Err(mismatch(offered));
        };
        let Some(version) = restart.config.versions.select(&offered) else {
            return Err(mismatch(offered));
        };
        let mut config = restart.config;
        config.negotiation_offer = Some(offered.clone());
        if config.set_version(version).is_err() {
            return Err(mismatch(offered));
        }
        debug!(%version, "restarting after Version Negotiation");
        let next = restart
            .endpoint
            .connect_with(config, restart.addr, &restart.server_name)
            .map_err(|error| {
                ConnectionError::from(
                    rama_quic_proto::TransportError::INTERNAL_ERROR(
                        "restart after Version Negotiation failed",
                    )
                    .with_cause(error),
                )
            })?;
        // The lost attempt's reference goes away here; its connection is already draining.
        self.conn = next.conn;
        self.connected = next.connected;
        self.handshake_data_ready = next.handshake_data_ready;
        Ok(())
    }

    /// Shared state for the endpoint's connection table; not an application reference.
    pub(crate) fn inner(&self) -> Arc<ConnectionInner> {
        self.connection_ref().0.clone()
    }

    /// Convert into a 0-RTT or 0.5-RTT connection at the cost of weakened security
    ///
    /// Returns `Ok` immediately if the local endpoint is able to attempt sending 0/0.5-RTT data.
    /// If so, the returned [`Connection`] can be used to send application data without waiting for
    /// the rest of the handshake to complete, at the cost of weakened cryptographic security
    /// guarantees. The returned [`ZeroRttAccepted`] future resolves when the handshake does
    /// complete, at which point subsequently opened streams and written data will have full
    /// cryptographic protection.
    ///
    /// ## Outgoing
    ///
    /// For outgoing connections, the initial attempt to convert to a [`Connection`] which sends
    /// 0-RTT data will proceed if the [`ClientConfig`](crate::ClientConfig)
    /// attempts to resume a previous TLS session. However, **the remote endpoint may not actually
    /// _accept_ the 0-RTT data**--yet still accept the connection attempt in general. This
    /// possibility is conveyed through the [`ZeroRttAccepted`] future--when the handshake
    /// completes, it resolves to `Ok(true)` if the 0-RTT data was accepted and `Ok(false)`
    /// if it was rejected. A failed handshake returns `Err` with the connection error.
    /// If it was rejected, the existence of streams opened and other application data sent prior
    /// to the handshake completing will not be conveyed to the remote application, and local
    /// operations on them will return `ZeroRttRejected` errors.
    ///
    /// A server may reject 0-RTT data at its discretion, but accepting 0-RTT data requires the
    /// relevant resumption state to be stored in the server, which servers may limit or lose for
    /// various reasons including not persisting resumption state across server restarts.
    ///
    /// Whether the attempt offers 0-RTT at all follows the [`ClientConfig`](crate::ClientConfig)
    /// it was made with: `TlsOptions::with_early_data` governs it, and it is off by default.
    ///
    /// ## Incoming
    ///
    /// Incoming connections permit a 0.5-RTT handle. The [`ZeroRttAccepted`] future resolves
    /// to `Ok(true)` after a successful handshake or `Err` if authentication or the connection fails.
    ///
    /// Whether the server accepts 0-RTT follows the [`ServerConfig`](crate::ServerConfig) it
    /// was built with, through the same `TlsOptions` setting.
    ///
    /// ## Security
    ///
    /// On outgoing connections, this enables transmission of 0-RTT data, which is vulnerable to
    /// replay attacks, and should therefore never invoke non-idempotent operations.
    ///
    /// On incoming connections, this enables transmission of 0.5-RTT data, which may be sent
    /// before TLS client authentication has occurred, and should therefore not be used to send
    /// data for which client authentication is being used.
    pub fn into_0rtt(mut self) -> Result<(Connection, ZeroRttAccepted), Self> {
        // This lock borrows `self` and would normally be dropped at the end of this scope, so we'll
        // have to release it explicitly before returning `self` by value.
        let conn = self.connection_ref().state.lock();

        let is_ok = conn.inner.has_0rtt() || conn.inner.side().is_server();
        drop(conn);

        if is_ok {
            let conn = self.take_connection();
            Ok((Connection(conn), ZeroRttAccepted(self.connected)))
        } else {
            Err(self)
        }
    }

    /// What the handshake settled: the application protocol both sides agreed on, and the name
    /// the client sent, as [`NegotiatedTlsParameters`] carries them.
    ///
    /// Once this resolves, the connection's extensions hold the same parameters. They are
    /// published again, complete with the peer's chain when stored, once the connection is
    /// established.
    pub async fn handshake_data(&mut self) -> Result<NegotiatedTlsParameters, ConnectionError> {
        // Taking &mut self allows us to use a single oneshot channel rather than dealing with
        // potentially many tasks waiting on the same event. It's a bit of a hack, but keeps things
        // simple.
        //
        // The receiver is kept until it has answered, so a call cancelled while waiting leaves the
        // next one waiting too rather than reading metadata the session does not have yet.
        loop {
            if let Some(x) = self.handshake_data_ready.as_mut() {
                let _handshake = x.await;
                self.handshake_data_ready = None;
            }
            let result = {
                let conn = self.connection_ref();
                let inner = conn.state.lock();
                inner
                    .inner
                    .crypto_session()
                    .handshake_summary()
                    .ok_or_else(|| {
                        inner.error.clone().unwrap_or_else(|| {
                            rama_quic_proto::TransportError::INTERNAL_ERROR(
                                "TLS session did not provide handshake metadata",
                            )
                            .into()
                        })
                    })
            };
            match result {
                Err(ConnectionError::VersionMismatch { offered }) => {
                    self.restart_after_version_negotiation(offered)?;
                }
                result => return result,
            }
        }
    }

    /// The local IP address which was used when the peer established
    /// the connection
    ///
    /// This can be different from the address the endpoint is bound to, in case
    /// the endpoint is bound to a wildcard address like `0.0.0.0` or `::`.
    ///
    /// This will return `None` for clients, or when the platform does not expose this
    /// information. See `rama_udp::DatagramCapabilities::receive_local_ip` for platform
    /// support.
    ///
    /// Will panic if called after `poll` has returned `Ready`.
    pub fn local_ip(&self) -> Option<IpAddr> {
        let conn = self.connection_ref();
        let inner = conn.state.lock();

        inner.inner.local_ip()
    }

    /// The peer's UDP address
    ///
    /// Will panic if called after `poll` has returned `Ready`.
    pub fn remote_address(&self) -> SocketAddr {
        let conn_ref: &ConnectionRef = self.connection_ref();
        conn_ref.state.lock().inner.remote_address()
    }
}

impl Future for Connecting {
    type Output = Result<Connection, ConnectionError>;
    fn poll(mut self: Pin<&mut Self>, cx: &mut Context) -> Poll<Self::Output> {
        loop {
            let result = match Pin::new(&mut self.connected).poll(cx) {
                Poll::Pending => return Poll::Pending,
                Poll::Ready(result) => result,
            };
            let outcome = {
                let conn = self.connection_ref();
                match result {
                    Ok(Ok(_)) => Ok(()),
                    Ok(Err(error)) => Err(error),
                    Err(_) => Err(conn
                        .state
                        .lock()
                        .error
                        .clone()
                        .unwrap_or_else(handshake_driver_stopped)),
                }
            };
            match outcome {
                Ok(()) => return Poll::Ready(Ok(Connection(self.take_connection()))),
                Err(ConnectionError::VersionMismatch { offered }) => {
                    if let Err(error) = self.restart_after_version_negotiation(offered) {
                        self.take_connection();
                        return Poll::Ready(Err(error));
                    }
                }
                Err(error) => {
                    self.take_connection();
                    return Poll::Ready(Err(error));
                }
            }
        }
    }
}

/// Future that completes when a connection is fully established
///
/// On success, clients receive whether 0-RTT was accepted and servers receive `true`.
/// A handshake failure returns the connection error, preserving its source.
pub struct ZeroRttAccepted(oneshot::Receiver<Result<bool, ConnectionError>>);

impl Future for ZeroRttAccepted {
    type Output = Result<bool, ConnectionError>;
    fn poll(mut self: Pin<&mut Self>, cx: &mut Context) -> Poll<Self::Output> {
        Pin::new(&mut self.0)
            .poll(cx)
            .map(|result| result.unwrap_or_else(|_| Err(handshake_driver_stopped())))
    }
}

fn handshake_driver_stopped() -> ConnectionError {
    rama_quic_proto::TransportError::INTERNAL_ERROR(
        "QUIC handshake driver stopped without a result",
    )
    .into()
}

/// The endpoint side of a connection's control path.
///
/// Control is never queued. Lock order is endpoint state, then connection state: the
/// endpoint applies [`Control`] to a connection while holding both locks, and a connection
/// reaches its endpoint only after releasing its own lock. [`ConnectionDriver`] therefore
/// hands engine events to the endpoint outside the [`State`] lock.
#[derive(Debug, Clone)]
pub(crate) struct EndpointLink {
    endpoint: Weak<EndpointInner>,
    handle: ConnectionHandle,
}

impl EndpointLink {
    pub(crate) fn new(endpoint: Weak<EndpointInner>, handle: ConnectionHandle) -> Self {
        Self { endpoint, handle }
    }

    fn close_lease_released(&self) {
        if let Some(endpoint) = self.endpoint.upgrade() {
            endpoint.shared.close_leases_released.notify_waiters();
        }
    }

    /// A link to no endpoint, for driving a connection in isolation.
    #[cfg(all(
        test,
        any(
            feature = "boring",
            all(feature = "rustls", any(feature = "aws-lc", feature = "ring"))
        )
    ))]
    pub(crate) fn detached(handle: ConnectionHandle) -> Self {
        Self {
            endpoint: Weak::new(),
            handle,
        }
    }

    fn deliver(&self, events: Vec<EndpointEvent>) {
        if let Some(endpoint) = self.endpoint.upgrade() {
            endpoint.connection_events(self.handle, events);
        }
    }

    /// What the endpoint can offer for sending from `local`, given the socket in use.
    fn socket_for_local(&self, local: SocketAddr, current: SocketId) -> LocalSocket {
        match self.endpoint.upgrade() {
            Some(endpoint) => endpoint.socket_for_local(local, current),
            None => LocalSocket::Unowned,
        }
    }

    /// Hand back send handles this connection no longer uses: the endpoint releases their socket
    /// leases and drops the handles outside every lock. Without an endpoint they are dropped here,
    /// outside the connection lock.
    fn release_senders(&self, senders: Vec<Sender>) {
        if senders.is_empty() {
            return;
        }
        match self.endpoint.upgrade() {
            Some(endpoint) => endpoint.release_senders(senders),
            None => drop(senders),
        }
    }
}

/// A descriptor with the bytes that belong to it. They are the send buffer's while it is the
/// descriptor being worked on, and its own once it has to wait while the engine writes another.
///
/// A connection holds at most four of these worth of bytes: the one on the handle it sends from,
/// the one on the handle kept aside for another path, the one waiting for a station, and the
/// buffer the engine writes the next one into. Each holds one descriptor, which is at most
/// [`MAX_TRANSMIT_SEGMENTS`] datagrams — fewer when the socket offers fewer — of at most the path
/// MTU, except an MTU probe, which is deliberately larger. A count of datagrams alone does not
/// bound that.
#[derive(Debug)]
struct Held {
    id: crate::driver::udp::TransmitId,
    transmit: crate::proto::Transmit,
    bytes: Option<Vec<u8>>,
}

impl Held {
    /// The storage the descriptor's bytes are in: its own copy once taken, otherwise the send
    /// buffer the engine wrote it into.
    fn bytes<'a>(&'a self, send_buffer: &'a [u8]) -> &'a [u8] {
        self.bytes.as_deref().unwrap_or(send_buffer)
    }

    /// The bytes this descriptor covers, or `None` when its storage no longer holds them. A
    /// sender refuses such a descriptor rather than sending part of one, and so does everything
    /// here that needs the bytes.
    fn payload<'a>(&'a self, send_buffer: &'a [u8]) -> Option<&'a [u8]> {
        self.bytes(send_buffer).get(..self.transmit.size)
    }

    /// Take the bytes out of the send buffer, so the engine may write the next descriptor while
    /// this one waits.
    ///
    /// Fails, handing the descriptor back, when the buffer no longer holds them. A descriptor
    /// that fails here must be retired: it still points at a buffer the engine is about to
    /// write again, and offering it later would send whatever landed there instead.
    fn into_owned(mut self, send_buffer: &[u8]) -> Result<Owned, Self> {
        let bytes = match self.bytes.take() {
            Some(bytes) => bytes,
            None => match send_buffer.get(..self.transmit.size) {
                Some(payload) => payload.to_vec(),
                None => return Err(self),
            },
        };
        Ok(Owned {
            id: self.id,
            transmit: self.transmit,
            bytes,
        })
    }
}

/// A descriptor that carries its own bytes, so no later write to the send buffer can change
/// what it holds. It is the only way one is kept across an engine write.
#[derive(Debug)]
struct Owned {
    id: crate::driver::udp::TransmitId,
    transmit: crate::proto::Transmit,
    bytes: Vec<u8>,
}

impl Owned {
    /// Back to a held descriptor, still carrying its own bytes.
    fn into_held(self) -> Held {
        Held {
            id: self.id,
            transmit: self.transmit,
            bytes: Some(self.bytes),
        }
    }
}

/// One send handle for a path this connection is not sending on, with the descriptor waiting on
/// it. The handle and the descriptor belong together: a descriptor is never moved between
/// handles, so an accepted prefix stays with the sender that took it.
#[derive(Debug)]
struct AsideSlot {
    sender: Sender,
    /// The path this handle was taken for. A wildcard-bound socket does not carry that address in
    /// its own bind, so what the endpoint answered about is what the slot serves, not what the
    /// handle reports.
    serves: SocketAddr,
    held: Option<Held>,
}

/// Where a descriptor has to leave from.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Station {
    /// The handle this connection sends on, which is also the one for an address it covers.
    Primary,
    /// The handle kept aside for the path the descriptor names.
    Aside,
    /// No handle at hand serves that path; only the endpoint can give one.
    Ask(SocketAddr),
}

/// What became of one offer of a descriptor to one send handle.
#[derive(Debug)]
enum Offered {
    Sent,
    /// The sender kept this task's waker; the same descriptor must be offered to it again.
    Pending,
    /// The route by which a stateless reset would arrive is not installed yet, so nothing was
    /// offered to the wire. The endpoint's confirmation wakes this connection.
    Awaiting,
    /// The identifier may never be sent again: only a prefix the sender had already taken has
    /// left, and the remainder is given up (RFC 9000 §9.5).
    Obsolete,
    Failed(crate::driver::udp::SendError),
}

/// What a placement leaves the pass able to do.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Placed {
    /// Dealt with; the pass goes on.
    Done,
    /// The handle this connection sends on kept the descriptor. Only another path can make
    /// progress in this pass.
    Blocked,
    /// The pass ends: the handle this connection sends on kept the descriptor and there is no
    /// other path to serve. That handle holds this task's waker.
    Stopped,
}

/// What a send pass has spent, and whether it left anything behind that will wake this
/// connection again.
#[derive(Debug, Default, Clone, Copy)]
struct Work {
    /// Datagrams offered to a sender: newly produced, offered again, or given up.
    attempted: usize,
    /// Whether the engine was asked for anything in this pass.
    pulled: bool,
    /// Whether anything reached the wire in this pass.
    sent: bool,
    /// Something happened that leaves no waker of its own — bytes on the wire, a descriptor given
    /// up, or output the engine handed over. A pass that spent its allowance on such work asks
    /// for another turn; one that spent it waiting does not, or it would poll in a loop.
    advanced: bool,
}

/// The datagrams one descriptor stands for.
fn datagrams(transmit: &crate::proto::Transmit) -> usize {
    match transmit.segment_size {
        None => 1,
        Some(size) => transmit.size.div_ceil(size.get()), // round up
    }
}

/// Offer one descriptor to one send handle under the rules every send obeys, whichever path it
/// belongs to: the identifier's permission is settled before anything reaches the wire, and a
/// prefix the sender accepted counts as used towards its destination (RFC 9000 §10.3.1).
fn offer(
    inner: &mut crate::proto::Connection,
    sender: &mut Sender,
    cx: &mut Context,
    id: crate::driver::udp::TransmitId,
    transmit: &crate::proto::Transmit,
    bytes: &[u8],
) -> Offered {
    if let Some(seq) = transmit.cid_used {
        match inner.may_send_cid(seq, transmit.destination) {
            SendPermit::Sendable => {}
            SendPermit::AwaitingInstallation => return Offered::Awaiting,
            SendPermit::Obsolete => {
                sender.abandon(id);
                if sender.accepted_any(id) {
                    inner.cid_sent(seq, transmit.destination);
                }
                return Offered::Obsolete;
            }
        }
    }
    let outcome = sender.poll_transmit(cx, id, transmit, bytes);
    if let Some(seq) = transmit.cid_used
        && sender.accepted_any(id)
    {
        inner.cid_sent(seq, transmit.destination);
    }
    match outcome {
        Poll::Pending => Offered::Pending,
        Poll::Ready(Ok(())) => Offered::Sent,
        Poll::Ready(Err(error)) => Offered::Failed(error),
    }
}

/// Control the endpoint applies directly to a connection's engine.
#[derive(Debug)]
pub(crate) enum Control {
    Proto(crate::proto::ConnectionEvent),
    /// Close the connection. `abandon` is set when the endpoint itself is shutting down: the
    /// connection then leaves its closing period as soon as the peer has been told.
    Close {
        error_code: VarInt,
        reason: Bytes,
        abandon: bool,
    },
    Rebind(Sender),
}

/// What happened to a connection when the endpoint reported a failed socket.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum PathFailure {
    /// The connection did not use that socket.
    Unaffected,
    /// The connection left the socket for a path it may use.
    Switched,
    /// The connection had no path it may use and was terminated with a local path error.
    Terminated,
}

/// Whether a connection may start sending from a given local address (RFC 9000 §9).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Switch {
    /// The same local address: a socket replacement, not a migration; always allowed.
    SameAddress,
    /// A client whose handshake is confirmed, whose peer allows active migration and that has an
    /// unused destination connection ID (or a zero-length one) for the new address.
    Now,
    /// A client that may migrate but not yet: its handshake is not confirmed, or it has no unused
    /// destination connection ID (RFC 9000 §9.5) until the peer issues one.
    Later,
    /// Never: servers cannot change address (the preferred-address mechanism aside), and a
    /// peer may disable active migration.
    Never,
}

/// Socket and receive-queue statistics for one connection, counted by the driver around the
/// protocol engine. What the engine itself counts is [`ConnectionStats`].
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
#[non_exhaustive]
pub struct DriverStats {
    /// Datagrams the socket refused for their destination, recovered like any packet loss.
    pub send_failures: u64,
    /// Datagrams the network stack rejected as too large, recovered by loss detection and MTU
    /// discovery.
    pub oversized_sends: u64,
    /// Occupancy and drop counters of this connection's queue of received packets.
    pub receive_queue: PacketQueueStats,
    /// Entries that queue currently keeps storage for, at most the configured limit.
    pub receive_queue_capacity: usize,
}

/// A future that drives protocol logic for a connection
///
/// This future handles the protocol logic for a single connection, routing events from the
/// `Connection` API object to the `Endpoint` task and the related stream-related interfaces.
/// It also keeps track of outstanding timeouts for the `Connection`.
///
/// If the connection encounters an error condition, this future will yield an error. It will
/// terminate (yielding `Ok(())`) if the connection was closed without error. Unlike other
/// connection-related futures, this waits for the draining period to complete to ensure that
/// packets still in flight from the peer are handled gracefully.
#[must_use = "connection drivers must be spawned for their connections to function"]
#[derive(Debug)]
pub(crate) struct ConnectionDriver {
    conn: Arc<ConnectionInner>,
    span: Span,
}

impl ConnectionDriver {
    fn new(conn: Arc<ConnectionInner>) -> Self {
        let span = {
            let conn = &mut conn.state.lock();
            debug_span!("drive", id = conn.handle.0)
        };

        Self { conn, span }
    }

    /// Submit the driver to the runtime through a slot reserved while the connection was
    /// registered.
    ///
    /// Must be called with no endpoint or connection lock held: a runtime that discards the
    /// future inline (for example while shutting down) runs this driver's `Drop`, which
    /// delivers Drained to the endpoint and therefore takes the endpoint lock.
    pub(crate) fn spawn(self, slot: crate::driver::lifecycle::SpawnSlot) {
        slot.submit(Box::pin(
            async {
                if let Err(e) = self.await {
                    rama_core::telemetry::tracing::error!("I/O error: {e}");
                }
            }
            .instrument(Span::current()),
        ));
    }
}

/// Test observation: whether a connection driver ever polled inside an enabled dial9 session.
#[cfg(all(test, feature = "dial9"))]
pub(crate) static DRIVER_POLLED_WITH_DIAL9: std::sync::atomic::AtomicBool =
    std::sync::atomic::AtomicBool::new(false);

impl Future for ConnectionDriver {
    type Output = Result<(), io::Error>;

    fn poll(self: Pin<&mut Self>, cx: &mut Context) -> Poll<Self::Output> {
        #[cfg(all(test, feature = "dial9"))]
        if rama_core::telemetry::dial9::Dial9Handle::current().is_enabled() {
            DRIVER_POLLED_WITH_DIAL9.store(true, Ordering::Relaxed);
        }
        let (outcome, endpoint_work, wanted_local, budget_changed) = {
            let conn = &mut *self.conn.state.lock();
            let _guard = self.span.enter();
            let outcome = conn.drive(&self.conn.shared, &self.conn.extensions, cx);
            (
                outcome,
                !conn.pending_endpoint_events.is_empty() || !conn.released_senders.is_empty(),
                conn.wanted_local.take(),
                std::mem::take(&mut conn.stream_budget_changed),
            )
        };
        self.conn.shared.notify_stream_budget(budget_changed);
        if endpoint_work {
            // Our lock is released, so the endpoint may lock this connection back (lock order).
            self.conn.deliver_endpoint_events();
        }
        if outcome.is_ready() {
            let conn = &mut *self.conn.state.lock();
            conn.forward_app_events(&self.conn.shared, &self.conn.extensions);
            if conn.error.is_none() {
                conn.terminate(
                    rama_quic_proto::TransportError::INTERNAL_ERROR(
                        "QUIC engine drained without a close reason",
                    )
                    .into(),
                    &self.conn.shared,
                );
            }
        }
        if let Some((local, descriptor)) = wanted_local {
            // Asked with our lock released, in endpoint-then-connection order.
            self.conn.follow_local_address(local, descriptor);
        }
        outcome
    }
}

impl Drop for ConnectionDriver {
    fn drop(&mut self) {
        let (link, events, released, budget_changed) = {
            let conn = &mut *self.conn.state.lock();
            // Discarding queued packets releases their budget charges.
            conn.packets.close();
            if conn.error.is_none() {
                conn.terminate(
                    rama_quic_proto::TransportError::INTERNAL_ERROR("QUIC driver stopped").into(),
                    &self.conn.shared,
                );
            }
            // The send handles go away with the driver; they are handed back below, outside
            // this lock, so their socket leases are released and they are dropped there.
            let mut released = std::mem::take(&mut conn.released_senders);
            released.extend(conn.socket.take());
            released.extend(conn.pending_rebind.take());
            released.extend(conn.aside.take().map(|slot| slot.sender));
            conn.buffered_transmit = None;
            conn.deferred = None;
            conn.send_buffer = Vec::new();
            (
                conn.endpoint.clone(),
                conn.take_endpoint_events_with_drained(),
                released,
                // Never polled again: deliver what terminating queued here.
                std::mem::take(&mut conn.stream_budget_changed),
            )
        };
        self.conn.shared.notify_stream_budget(budget_changed);
        link.deliver(events);
        link.release_senders(released);
    }
}

/// A QUIC connection.
///
/// If all references to a connection (including every clone of the `Connection` handle, streams of
/// incoming streams, and the various stream types) have been dropped, then the connection will be
/// automatically closed with an `error_code` of 0 and an empty `reason`. You can also close the
/// connection explicitly by calling [`Connection::close()`].
///
/// Closing the connection immediately abandons efforts to deliver data to the peer.  Upon
/// receiving CONNECTION_CLOSE the peer *may* drop any stream data not yet delivered to the
/// application. [`Connection::close()`] describes in more detail how to gracefully close a
/// connection without losing application data.
///
/// May be cloned to obtain another handle to the same connection.
/// Connection-scoped extensions are shared by all handles and can be accessed
/// through [`ExtensionsRef::extensions`], independently of the transport state lock.
/// The connection publishes its [`SocketInfo`], its [`NegotiatedTlsParameters`] and, once the
/// handshake completes, its [`QuicConnectionInfo`] there.
/// `peer_certificate_chain` is only filled when the TLS configuration asked to store it
/// (`store_server_cert_chain` on a client, `store_client_cert_chain` on a server).
///
/// [`Connection::close()`]: Connection::close
#[derive(Debug, Clone)]
pub struct Connection(ConnectionRef);

/// QUIC facts of a connection, published in its extensions when the handshake completes.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Extension)]
#[extension(tags(net))]
pub struct QuicConnectionInfo {
    /// See [`Connection::version`].
    pub version: Version,
    /// See [`Connection::original_version`].
    pub original_version: Version,
    /// See [`Connection::early_data_keys_enabled`].
    pub early_data_keys_enabled: bool,
    /// Round-trip time estimate at handshake completion; see [`Connection::rtt`] for the
    /// current one.
    pub handshake_rtt: Duration,
    /// UDP payload MTU of the path at handshake completion.
    pub handshake_mtu: u16,
}

/// Holds off a connection's close at a graceful endpoint shutdown; see
/// [`Connection::close_lease`]. It does not keep the connection open otherwise.
pub struct CloseLease(Arc<ConnectionInner>);

impl fmt::Debug for CloseLease {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("CloseLease").finish_non_exhaustive()
    }
}

impl Drop for CloseLease {
    fn drop(&mut self) {
        if self.0.shared.close_leases.fetch_sub(1, Ordering::AcqRel) == 1 {
            let endpoint = self.0.state.lock().endpoint.clone();
            endpoint.close_lease_released();
        }
    }
}

impl ExtensionsRef for Connection {
    fn extensions(&self) -> &Extensions {
        &self.0.extensions
    }
}

impl Connection {
    /// Initiate a new outgoing unidirectional stream.
    ///
    /// Streams are cheap and instantaneous to open unless blocked by flow control. As a
    /// consequence, the peer won't be notified that a stream has been opened until the stream is
    /// actually used.
    pub fn open_uni(&self) -> OpenUni<'_> {
        OpenUni {
            conn: &self.0,
            notify: self.0.shared.stream_budget_available[Dir::Uni as usize].notified(),
        }
    }

    /// Initiate a new outgoing bidirectional stream.
    ///
    /// Streams are cheap and instantaneous to open unless blocked by flow control. As a
    /// consequence, the peer won't be notified that a stream has been opened until the stream is
    /// actually used. Calling [`open_bi()`] then waiting on the [`RecvStream`] without writing
    /// anything to [`SendStream`] will never succeed.
    ///
    /// [`open_bi()`]: crate::driver::Connection::open_bi
    /// [`SendStream`]: crate::driver::SendStream
    /// [`RecvStream`]: crate::driver::RecvStream
    pub fn open_bi(&self) -> OpenBi<'_> {
        OpenBi {
            conn: &self.0,
            notify: self.0.shared.stream_budget_available[Dir::Bi as usize].notified(),
        }
    }

    /// Reserve bidirectional stream credit without assigning a stream ID.
    ///
    /// Returns `None` before the handshake completes or while credit is exhausted.
    /// Dropping an unused reservation returns its credit without emitting a reset.
    /// Ordinary stream opens cannot consume reserved credit.
    pub fn try_reserve_bi(&self) -> Result<Option<BiStreamReservation>, ConnectionError> {
        let mut state = self.0.state.lock();
        if let Some(error) = &state.error {
            return Err(error.clone());
        }
        if !state.connected {
            return Ok(None);
        }
        let available = state.inner.streams().available_local_streams(Dir::Bi);
        if available <= state.reserved_streams[Dir::Bi as usize] {
            if available == 0 {
                // Pool admission may be the only caller asking for a stream.
                // Report real exhaustion so the peer promptly returns credit.
                _ = state.inner.streams().open(Dir::Bi);
                state.wake();
            }
            return Ok(None);
        }
        state.reserved_streams[Dir::Bi as usize] += 1;
        _ = state.refresh_stream_budget();
        drop(state);
        Ok(Some(BiStreamReservation {
            connection: Some(self.0.clone()),
        }))
    }

    /// Subscribe before trying admission to observe newly available stream credit.
    ///
    /// Values are change revisions, not capacities. A signal means credit was
    /// returned or increased, the handshake finished, or the connection closed;
    /// retry reservation or inspect [`Self::available_streams`]. Acquisitions do
    /// not wake subscribers.
    pub fn stream_budget_watch(&self, dir: Dir) -> Changed<usize> {
        self.0.shared.stream_budget_changes[dir as usize].watch()
    }

    /// Wake `listener` on every later signal of [`Self::stream_budget_watch`],
    /// until it is dropped.
    pub fn stream_budget_subscribe(&self, dir: Dir, listener: Weak<dyn ChangeListener>) {
        self.0.shared.stream_budget_changes[dir as usize].subscribe(listener);
    }

    /// Accept the next incoming uni-directional stream
    pub fn accept_uni(&self) -> AcceptUni<'_> {
        AcceptUni {
            conn: &self.0,
            notify: self.0.shared.stream_incoming[Dir::Uni as usize].notified(),
        }
    }

    /// Accept the next incoming bidirectional stream
    ///
    /// **Important Note**: The `Connection` that calls [`open_bi()`] must write to its [`SendStream`]
    /// before the other `Connection` is able to `accept_bi()`. Calling [`open_bi()`] then
    /// waiting on the [`RecvStream`] without writing anything to [`SendStream`] will never succeed.
    ///
    /// [`accept_bi()`]: crate::driver::Connection::accept_bi
    /// [`open_bi()`]: crate::driver::Connection::open_bi
    /// [`SendStream`]: crate::driver::SendStream
    /// [`RecvStream`]: crate::driver::RecvStream
    pub fn accept_bi(&self) -> AcceptBi<'_> {
        AcceptBi {
            conn: &self.0,
            notify: self.0.shared.stream_incoming[Dir::Bi as usize].notified(),
        }
    }

    /// Receive an application datagram
    pub fn read_datagram(&self) -> ReadDatagram<'_> {
        ReadDatagram {
            conn: &self.0,
            notify: self.0.shared.datagram_received.notified(),
        }
    }

    /// Wait for the connection to be closed for any reason
    ///
    /// Despite the return type's name, closed connections are often not an error condition at the
    /// application layer. Cases that might be routine include [`ConnectionError::LocallyClosed`]
    /// and [`ConnectionError::ApplicationClosed`].
    pub async fn closed(&self) -> ConnectionError {
        loop {
            {
                let conn = self.0.state.lock();
                if let Some(error) = &conn.error {
                    return error.clone();
                }
                self.0.shared.closed.notified()
            }
            .await;
        }
    }

    /// Hold off this connection's close at a graceful shutdown of its endpoint, until the
    /// lease is dropped or part of the endpoint's shutdown budget has passed.
    ///
    /// For work that must still leave over this connection once shutdown starts, such as a
    /// tunnel forwarding the close of a connection it carries. Other closes, and an explicit
    /// [`Endpoint::shutdown`](crate::Endpoint::shutdown), do not wait for it.
    #[must_use]
    pub fn close_lease(&self) -> CloseLease {
        self.0.shared.close_leases.fetch_add(1, Ordering::AcqRel);
        CloseLease(self.0.0.clone())
    }

    /// If the connection is closed, the reason why.
    ///
    /// Returns `None` if the connection is still open.
    pub fn close_reason(&self) -> Option<ConnectionError> {
        self.0.state.lock().error.clone()
    }

    /// Close the connection immediately.
    ///
    /// Pending operations will fail immediately with [`ConnectionError::LocallyClosed`]. No
    /// more data is sent to the peer and the peer may drop buffered data upon receiving
    /// the CONNECTION_CLOSE frame.
    ///
    /// `error_code` and `reason` are not interpreted, and are provided directly to the peer.
    ///
    /// `reason` will be truncated to fit in a single packet with overhead; to improve odds that it
    /// is preserved in full, it should be kept under 1KiB.
    ///
    /// # Gracefully closing a connection
    ///
    /// Only the peer last receiving application data can be certain that all data is
    /// delivered. The only reliable action it can then take is to close the connection,
    /// potentially with a custom error code. The delivery of the final CONNECTION_CLOSE
    /// frame is very likely if both endpoints stay online long enough, and
    /// [`Endpoint::wait_idle()`] can be used to provide sufficient time. Otherwise, the
    /// remote peer will time out the connection, provided that the idle timeout is not
    /// disabled.
    ///
    /// The sending side can not guarantee all stream data is delivered to the remote
    /// application. It only knows the data is delivered to the QUIC stack of the remote
    /// endpoint. Once the local side sends a CONNECTION_CLOSE frame in response to calling
    /// [`close()`] the remote endpoint may drop any data it received but is as yet
    /// undelivered to the application, including data that was acknowledged as received to
    /// the local endpoint.
    ///
    /// [`ConnectionError::LocallyClosed`]: crate::ConnectionError::LocallyClosed
    /// [`Endpoint::wait_idle()`]: crate::Endpoint::wait_idle
    /// [`close()`]: Connection::close
    pub fn close(&self, error_code: impl Into<VarInt>, reason: &[u8]) {
        let budget_changed = {
            let conn = &mut *self.0.state.lock();
            conn.close(
                error_code.into(),
                Bytes::copy_from_slice(reason),
                &self.0.shared,
            );
            std::mem::take(&mut conn.stream_budget_changed)
        };
        // Whether or not a driver still polls, subscribers learn of the close.
        self.0.shared.notify_stream_budget(budget_changed);
    }

    /// Send a transport CONNECTION_CLOSE for protocol interoperability tests.
    ///
    /// Application shutdown normally uses [`Self::close`]. This hook exercises
    /// peers which finish with transport `NO_ERROR`, rather than an application code.
    #[cfg(feature = "test-utils")]
    pub fn close_transport(&self, error: rama_quic_proto::TransportError) {
        self.0.close_transport(error);
    }

    /// Whether the handshake was confirmed, see [`Self::handshake_confirmed`].
    ///
    /// This stays true after the connection closes, so buffered data received over an
    /// authenticated connection can be told apart from an incomplete handshake.
    #[must_use]
    pub fn is_handshake_confirmed(&self) -> bool {
        self.0.state.lock().handshake_confirmed
    }

    /// Wait for the handshake to be confirmed.
    ///
    /// As a server, who must be authenticated by clients,
    /// this happens when the handshake completes
    /// upon receiving a TLS Finished message from the client.
    /// In return, the server send a HANDSHAKE_DONE frame.
    ///
    /// As a client, this happens when receiving a HANDSHAKE_DONE frame.
    /// At this point, the server has either accepted our authentication,
    /// or, if client authentication is not required, accepted our lack of authentication.
    pub async fn handshake_confirmed(&self) -> Result<(), ConnectionError> {
        self.handshake_confirmed_inner().await
    }

    /// Tests: hold or release the server's HANDSHAKE_DONE (see the engine seam).
    #[cfg(all(
        test,
        any(
            feature = "boring",
            all(feature = "rustls", any(feature = "aws-lc", feature = "ring"))
        )
    ))]
    pub(crate) fn hold_handshake_done(&self, hold: bool) {
        let conn = &mut *self.0.state.lock();
        conn.inner.hold_handshake_done(hold);
        conn.wake();
    }

    /// The destination connection ID this connection currently puts on the wire (tests).
    #[cfg(all(
        test,
        any(
            feature = "boring",
            all(feature = "rustls", any(feature = "aws-lc", feature = "ring"))
        )
    ))]
    pub(crate) fn active_dcid(&self) -> Vec<u8> {
        self.0.state.lock().inner.active_rem_cid().to_vec()
    }

    /// Tests: whether a datagram carrying the active connection ID has gone out since the last
    /// switch, which is what makes that identifier one this connection has used.
    #[cfg(all(
        test,
        any(
            feature = "boring",
            all(feature = "rustls", any(feature = "aws-lc", feature = "ring"))
        )
    ))]
    pub(crate) fn active_cid_confirmed(&self) -> bool {
        self.0.state.lock().inner.active_cid_confirmed()
    }

    /// Tests: whether a datagram carrying the identifier numbered `seq` has gone out.
    #[cfg(all(
        test,
        any(
            feature = "boring",
            all(feature = "rustls", any(feature = "aws-lc", feature = "ring"))
        )
    ))]
    pub(crate) fn cid_confirmed(&self, seq: u64) -> bool {
        self.0.state.lock().inner.cid_confirmed(seq)
    }

    /// Tests: the datagram this connection has buffered: its exact bytes, its destination and
    /// the identifier it carries.
    ///
    /// A descriptor is buffered either because the socket was not ready for it or because the
    /// route its identifier needs is not installed; this does not distinguish the two. A test
    /// that needs to know which must arrange one of them, as the route tests do by holding
    /// installation on a socket that is otherwise writable.
    #[cfg(all(
        test,
        any(
            feature = "boring",
            all(feature = "rustls", any(feature = "aws-lc", feature = "ring"))
        )
    ))]
    pub(crate) fn held_transmit(&self) -> Option<(Vec<u8>, std::net::SocketAddr, Option<u64>)> {
        let state = self.0.state.lock();
        let held = state.buffered_transmit.as_ref()?;
        let bytes = held.payload(&state.send_buffer)?.to_vec();
        Some((bytes, held.transmit.destination, held.transmit.cid_used))
    }

    /// Tests: run send passes with a smaller allowance, so the end of a pass is reachable
    /// without arranging twenty datagrams.
    #[cfg(all(
        test,
        any(
            feature = "boring",
            all(feature = "rustls", any(feature = "aws-lc", feature = "ring"))
        )
    ))]
    pub(crate) fn set_pass_allowance(&self, datagrams: usize) {
        self.0.state.lock().pass_allowance = Some(datagrams);
    }

    /// Tests: how many send passes this connection has run.
    #[cfg(all(
        test,
        any(
            feature = "boring",
            all(feature = "rustls", any(feature = "aws-lc", feature = "ring"))
        )
    ))]
    pub(crate) fn send_passes(&self) -> u64 {
        self.0.state.lock().passes
    }

    /// Tests: passes that spent their allowance without advancing, and so asked for no further
    /// turn.
    #[cfg(all(
        test,
        any(
            feature = "boring",
            all(feature = "rustls", any(feature = "aws-lc", feature = "ring"))
        )
    ))]
    pub(crate) fn allowance_parked_without_progress(&self) -> u64 {
        self.0.state.lock().allowance_parked_without_progress
    }

    /// Tests: passes that spent their allowance on descriptors that were already waiting and put
    /// bytes on the wire — those that asked for another turn, and those that parked instead.
    #[cfg(all(
        test,
        any(
            feature = "boring",
            all(feature = "rustls", any(feature = "aws-lc", feature = "ring"))
        )
    ))]
    pub(crate) fn retry_allowance_ends(&self) -> (u64, u64) {
        let state = self.0.state.lock();
        (state.retry_allowance_asked, state.retry_allowance_parked)
    }

    /// Tests: the datagram waiting on the handle kept aside for another path, with the address
    /// that handle serves.
    #[cfg(all(
        test,
        any(
            feature = "boring",
            all(feature = "rustls", any(feature = "aws-lc", feature = "ring"))
        )
    ))]
    pub(crate) fn aside_transmit(&self) -> Option<(std::net::SocketAddr, Vec<u8>, Option<u64>)> {
        let state = self.0.state.lock();
        let slot = state.aside.as_ref()?;
        let held = slot.held.as_ref()?;
        let bytes = held.payload(&state.send_buffer)?;
        Some((slot.serves, bytes.to_vec(), held.transmit.cid_used))
    }

    /// Tests: the local address of the handle kept aside for another path, if one is held.
    #[cfg(all(
        test,
        any(
            feature = "boring",
            all(feature = "rustls", any(feature = "aws-lc", feature = "ring"))
        )
    ))]
    pub(crate) fn aside_address(&self) -> Option<std::net::SocketAddr> {
        self.0.state.lock().aside.as_ref().map(|slot| slot.serves)
    }

    /// Tests: make the next attempt to take a descriptor's bytes out of the send buffer find
    /// nothing there, so the retirement path can be observed.
    #[cfg(all(
        test,
        any(
            feature = "boring",
            all(feature = "rustls", any(feature = "aws-lc", feature = "ring"))
        )
    ))]
    pub(crate) fn fail_next_ownership(&self) {
        self.0.state.lock().fail_ownership = true;
    }

    /// Tests: the descriptors this connection offered to its sender, oldest first.
    #[cfg(all(
        test,
        any(
            feature = "boring",
            all(feature = "rustls", any(feature = "aws-lc", feature = "ring"))
        )
    ))]
    pub(crate) fn descriptors(&self) -> Vec<Descriptor> {
        self.0.state.lock().descriptors.iter().cloned().collect()
    }

    /// Tests: how many times this connection has been told a datagram reached the network.
    #[cfg(all(
        test,
        any(
            feature = "boring",
            all(feature = "rustls", any(feature = "aws-lc", feature = "ring"))
        )
    ))]
    pub(crate) fn cid_sent_calls(&self) -> u64 {
        self.0.state.lock().inner.cid_sent_calls()
    }

    /// Tests: whether the identifier numbered `seq` may be sent to `remote` — that is, whether
    /// its route is installed, which is a different question from whether anything has been sent
    /// with it.
    #[cfg(all(
        test,
        any(
            feature = "boring",
            all(feature = "rustls", any(feature = "aws-lc", feature = "ring"))
        )
    ))]
    pub(crate) fn send_permit(&self, seq: u64, remote: std::net::SocketAddr) -> SendPermit {
        self.0.state.lock().inner.may_send_cid(seq, remote)
    }

    /// Tests: whether a datagram carrying the identifier numbered `seq` has gone out towards
    /// `remote`, which is what RFC 9000 §10.3.1 ties recognition to.
    #[cfg(all(
        test,
        any(
            feature = "boring",
            all(feature = "rustls", any(feature = "aws-lc", feature = "ring"))
        )
    ))]
    pub(crate) fn cid_confirmed_to(&self, seq: u64, remote: std::net::SocketAddr) -> bool {
        self.0.state.lock().inner.cid_confirmed_to(seq, remote)
    }

    /// Tests: the bytes this connection keeps allocated for sending.
    ///
    /// `buffer` is the storage the engine writes the next descriptor into, which is reused and
    /// so holds the largest it has ever written. `owned` is the bytes of the descriptors that
    /// had to wait and took a copy of their own. `slots` is how many of those there are. The
    /// bound they stay under is the one [`Held`] documents: a descriptor's worth is at most
    /// [`MAX_TRANSMIT_SEGMENTS`] datagrams of at most the path's largest payload, and at most
    /// four descriptors' worth is kept.
    #[cfg(all(
        test,
        any(
            feature = "boring",
            all(feature = "rustls", any(feature = "aws-lc", feature = "ring"))
        )
    ))]
    pub(crate) fn retained_send_bytes(&self) -> RetainedSend {
        let state = self.0.state.lock();
        let held = [
            state.buffered_transmit.as_ref(),
            state.deferred.as_ref(),
            state.aside.as_ref().and_then(|slot| slot.held.as_ref()),
        ];
        let carried = held
            .into_iter()
            .flatten()
            .filter_map(|held| held.bytes.as_ref());
        RetainedSend {
            buffer: state.send_buffer.capacity(),
            owned: carried.clone().map(Vec::capacity).sum(),
            slots: carried.count(),
        }
    }

    /// Tests: the largest UDP payload this connection's *current* path may carry, which MTU
    /// discovery searches up to and no datagram may exceed.
    ///
    /// This is not on its own a bound on what is retained. The buffer keeps capacity a former
    /// path put there, and a `Vec` may allocate past what was asked of it, so a bound over a
    /// connection's life takes the largest payload the test saw and allows for that growth.
    /// [`RETAINED_DESCRIPTORS`] and [`MAX_TRANSMIT_SEGMENTS`] are the other two terms.
    #[cfg(all(
        test,
        any(
            feature = "boring",
            all(feature = "rustls", any(feature = "aws-lc", feature = "ring"))
        )
    ))]
    pub(crate) fn max_datagram_payload(&self) -> usize {
        self.0.state.lock().inner.max_datagram_payload() as usize
    }

    /// Tests: how many datagrams were given up because their identifier may never be sent again.
    /// A datagram merely waiting for its route is not one of them.
    #[cfg(all(
        test,
        any(
            feature = "boring",
            all(feature = "rustls", any(feature = "aws-lc", feature = "ring"))
        )
    ))]
    pub(crate) fn stale_transmits(&self) -> u64 {
        self.0.state.lock().stale_transmits
    }

    /// Tests: how many datagrams were given up because this endpoint owns no socket that could
    /// send from the local address their path names.
    #[cfg(all(
        test,
        any(
            feature = "boring",
            all(feature = "rustls", any(feature = "aws-lc", feature = "ring"))
        )
    ))]
    pub(crate) fn unowned_paths(&self) -> u64 {
        self.0.state.lock().unowned_paths
    }

    /// Tests: whether a datagram naming `local` would leave from the handle this connection
    /// sends on — because that is the handle's own address, or because the endpoint said the
    /// socket behind it covers that address.
    #[cfg(all(
        test,
        any(
            feature = "boring",
            all(feature = "rustls", any(feature = "aws-lc", feature = "ring"))
        )
    ))]
    pub(crate) fn sends_from_for(&self, local: std::net::SocketAddr) -> bool {
        matches!(
            self.0.state.lock().station_for(Some(local)),
            Station::Primary
        )
    }

    /// Tests: the local address this connection sends from, as its send handle reports it.
    #[cfg(all(
        test,
        any(
            feature = "boring",
            all(feature = "rustls", any(feature = "aws-lc", feature = "ring"))
        )
    ))]
    pub(crate) fn sending_from(&self) -> Option<std::net::SocketAddr> {
        self.0.state.lock().socket.as_ref().map(Sender::local_addr)
    }

    /// Tests: the sequence number of the connection ID this side is addressing its peer with.
    #[cfg(all(
        test,
        any(
            feature = "boring",
            all(feature = "rustls", any(feature = "aws-lc", feature = "ring"))
        )
    ))]
    pub(crate) fn active_dcid_seq(&self) -> u64 {
        self.0.state.lock().inner.active_rem_cid_seq()
    }

    /// Observe the constructor's suppression decision in integration tests; never overrides it.
    #[doc(hidden)]
    #[cfg(any(
        feature = "test-utils",
        all(
            test,
            any(
                feature = "boring",
                all(feature = "rustls", any(feature = "ring", feature = "aws-lc"))
            )
        )
    ))]
    pub fn spin_enabled_for_test(&self) -> bool {
        self.0.state.lock().inner.spin_enabled_for_test()
    }

    #[cfg(all(
        test,
        any(
            feature = "boring",
            all(feature = "rustls", any(feature = "ring", feature = "aws-lc"))
        )
    ))]
    pub(crate) fn path_validated_for_test(&self) -> bool {
        self.0.state.lock().inner.path_validated()
    }

    /// Tests: have the peer retire every connection ID we issued below `v`, issuing replacements.
    #[cfg(all(
        test,
        any(
            feature = "boring",
            all(feature = "rustls", any(feature = "aws-lc", feature = "ring"))
        )
    ))]
    pub(crate) fn rotate_local_cid(&self, v: u64) {
        let conn = &mut *self.0.state.lock();
        conn.inner
            .rotate_local_cid(v, crate::driver::Instant::now());
        conn.wake();
    }

    /// The destination connection ID set aside for a candidate path, if any (tests).
    #[cfg(all(
        test,
        any(
            feature = "boring",
            all(feature = "rustls", any(feature = "aws-lc", feature = "ring"))
        )
    ))]
    pub(crate) fn reserved_dcid(&self) -> Option<Vec<u8>> {
        self.0
            .state
            .lock()
            .inner
            .reserved_rem_cid()
            .map(|cid| cid.to_vec())
    }

    async fn handshake_confirmed_inner(&self) -> Result<(), ConnectionError> {
        {
            let conn = self.0.state.lock();
            if let Some(error) = conn.error.as_ref() {
                return Err(error.clone());
            }
            if conn.handshake_confirmed {
                return Ok(());
            }
            // Construct the future while the lock is held to ensure we can't miss a wakeup if
            // the `Notify` is signaled immediately after we release the lock. `await` it after
            // the lock guard is out of scope.
            self.0.shared.handshake_confirmed.notified()
        }
        .await;
        if let Some(error) = self.0.state.lock().error.as_ref() {
            Err(error.clone())
        } else {
            Ok(())
        }
    }

    /// Transmit `data` as an unreliable, unordered application datagram
    ///
    /// Application datagrams are a low-level primitive. They may be lost or delivered out of order,
    /// and `data` must both fit inside a single QUIC packet and be smaller than the maximum
    /// dictated by the peer.
    ///
    /// Previously queued datagrams which are still unsent may be discarded to make space for this
    /// datagram, in order of oldest to newest.
    pub fn send_datagram(&self, data: Bytes) -> Result<(), SendDatagramError> {
        self.0.send_gated_datagram(data, true)
    }

    /// Transmit `data` as an unreliable, unordered application datagram without waiting or
    /// discarding queued datagrams: a full send buffer returns [`SendDatagramError::Blocked`].
    ///
    /// See [`send_datagram()`] for details.
    ///
    /// [`send_datagram()`]: Connection::send_datagram
    pub fn try_send_datagram(&self, data: Bytes) -> Result<(), SendDatagramError> {
        self.0.send_gated_datagram(data, false)
    }

    /// Transmit `data` as an unreliable, unordered application datagram
    ///
    /// Unlike [`send_datagram()`], this method will wait for buffer space during congestion
    /// conditions, which effectively prioritizes old datagrams over new datagrams.
    ///
    /// See [`send_datagram()`] for details.
    ///
    /// [`send_datagram()`]: Connection::send_datagram
    pub fn send_datagram_wait(&self, data: Bytes) -> SendDatagram<'_> {
        SendDatagram {
            conn: &self.0,
            data: Some(data),
            admitted: false,
            notify: self.0.shared.datagrams_unblocked.notified(),
        }
    }

    /// Wait until queued datagrams may have made room for another one, or the connection closed.
    ///
    /// The returned future is registered on creation: create it before a send that may be
    /// refused as [`SendDatagramError::Blocked`] (see [`try_send_datagram()`]) and await it
    /// after the refusal, so a wake in between is not missed. Each future is an independent
    /// registration and dropping it is harmless. A wake is a hint: retry the send.
    ///
    /// [`try_send_datagram()`]: Connection::try_send_datagram
    pub fn datagram_send_ready(&self) -> DatagramSendReady {
        let mut notified =
            Box::pin(Arc::clone(&self.0.shared.datagrams_unblocked).notified_owned());
        notified.as_mut().enable();
        let closed = self.0.state.lock().error.is_some();
        DatagramSendReady { notified, closed }
    }

    /// Compute the maximum size of datagrams that may be passed to [`send_datagram()`].
    ///
    /// Returns `None` if datagrams are unsupported by the peer or disabled locally.
    ///
    /// This may change over the lifetime of a connection according to variation in the path MTU
    /// estimate. The peer can also enforce an arbitrarily small fixed limit, but if the peer's
    /// limit is large this is guaranteed to be a little over a kilobyte at minimum.
    ///
    /// Not necessarily the maximum size of received datagrams.
    ///
    /// [`send_datagram()`]: Connection::send_datagram
    pub fn max_datagram_size(&self) -> Option<usize> {
        self.0.state.lock().inner.datagrams().max_size()
    }

    /// Datagrams received from the peer and not yet taken by
    /// [`read_datagram()`](Self::read_datagram).
    pub fn received_datagrams(&self) -> usize {
        self.0.state.lock().inner.datagrams().received_len()
    }

    /// Whether this connection accepts QUIC DATAGRAM frames from its peer: this endpoint
    /// advertised `max_datagram_frame_size` (RFC 9221 §3), whatever the peer supports.
    pub fn datagram_receive_enabled(&self) -> bool {
        self.0.state.lock().inner.datagrams().receive_enabled()
    }

    /// Bytes available in the outgoing datagram buffer
    ///
    /// When greater than zero, calling [`send_datagram()`](Self::send_datagram) with a datagram of
    /// at most this size is guaranteed not to cause older datagrams to be dropped.
    pub fn datagram_send_buffer_space(&self) -> usize {
        self.0.state.lock().inner.datagrams().send_buffer_space()
    }

    /// Whether this connection ever enabled early-data keys.
    ///
    /// This remains true after the keys are discarded. Waiting for handshake
    /// confirmation and then inspecting a stream's acceptance time cannot rule
    /// out early bytes buffered before that acceptance. Applications rejecting
    /// early request data must disable it before connection establishment.
    #[must_use]
    pub fn early_data_keys_enabled(&self) -> bool {
        self.0.state.lock().inner.has_0rtt()
    }

    /// Whether the server accepted this client's early data, once the handshake completed.
    ///
    /// `None` while the decision is pending, without early data and on server connections.
    /// Streams opened before the decision are exactly those a rejection discarded.
    #[must_use]
    pub fn early_data_accepted(&self) -> Option<bool> {
        self.0.state.lock().inner.early_data_decision()
    }

    /// Which side of the connection this is: the one that opened it, or the one that accepted
    /// it.
    #[must_use]
    pub fn side(&self) -> Side {
        self.0.state.lock().inner.side()
    }

    /// The peer's UDP address
    ///
    /// If `ServerConfig::migration` is `true`, clients may change addresses at will, e.g. when
    /// switching to a cellular internet connection.
    pub fn remote_address(&self) -> SocketAddr {
        self.0.state.lock().inner.remote_address()
    }

    /// The local IP address which was used when the peer established
    /// the connection
    ///
    /// This can be different from the address the endpoint is bound to, in case
    /// the endpoint is bound to a wildcard address like `0.0.0.0` or `::`.
    ///
    /// This will return `None` for clients, or when the platform does not expose this
    /// information. See `rama_udp::DatagramCapabilities::receive_local_ip` for platform
    /// support.
    pub fn local_ip(&self) -> Option<IpAddr> {
        self.0.state.lock().inner.local_ip()
    }

    /// Current best estimate of this connection's latency (round-trip-time)
    pub fn rtt(&self) -> Duration {
        self.0.state.lock().inner.rtt()
    }

    /// Minimum RTT seen on this path, ignoring ack delay
    #[must_use]
    pub fn min_rtt(&self) -> Duration {
        self.0.state.lock().inner.min_rtt()
    }

    /// Returns connection statistics
    pub fn stats(&self) -> ConnectionStats {
        let mut stats = self.0.state.lock().inner.stats();
        let [received, sent] = &self.0.shared.gated_datagrams;
        stats.gated_datagrams = GatedDatagramStats {
            received: received.load(Ordering::Relaxed),
            sent: sent.load(Ordering::Relaxed),
        };
        stats
    }

    /// The QUIC version this connection runs in: the client's first flight version, or the
    /// compatible version the server moved it to (RFC 9368).
    pub fn version(&self) -> rama_quic_proto::Version {
        self.0.state.lock().inner.version()
    }

    /// The QUIC version of the client's first flight, which differs from [`Self::version`]
    /// only after compatible version negotiation moved the connection (RFC 9368 §2.3).
    pub fn original_version(&self) -> rama_quic_proto::Version {
        self.0.state.lock().inner.original_version()
    }

    /// A stable identifier for this connection
    ///
    /// Peer addresses and connection IDs can change, but this value will remain
    /// fixed for the lifetime of the connection.
    pub fn stable_id(&self) -> usize {
        self.0.stable_id()
    }

    /// Update traffic keys now, without waiting for the usage limit that would force one.
    ///
    /// Answers whether an update was started. Nothing changes and the answer is `false` when the
    /// connection is not established, when the handshake is not confirmed yet (RFC 9001 §6.1
    /// forbids initiating an update before then, which for a client means after HANDSHAKE_DONE),
    /// or when an update is already in flight (§6 allows one at a time).
    /// [`ConnectionStats::key_updates`](crate::ConnectionStats::key_updates) counts the updates
    /// this connection has made, whichever side asked for them.
    pub fn force_key_update(&self) -> bool {
        self.0.state.lock().inner.force_key_update(now())
    }

    /// Derive keying material from this connection's TLS session secrets.
    ///
    /// Two peers calling this with the same `label`, the same `context` and `output` buffers of
    /// equal length get the same bytes. The bytes are cryptographically strong and pseudorandom,
    /// suitable as keying material. A different label or a different context gives different
    /// bytes.
    ///
    /// TLS 1.3 defines this exporter in [RFC 8446 §7.5]; [RFC 5705] defined the earlier one it
    /// replaces.
    ///
    /// [RFC 8446 §7.5]: https://www.rfc-editor.org/rfc/rfc8446#section-7.5
    /// [RFC 5705]: https://www.rfc-editor.org/rfc/rfc5705
    pub fn export_keying_material(
        &self,
        output: &mut [u8],
        label: &[u8],
        context: &[u8],
    ) -> Result<(), crate::proto::crypto::ExportKeyingMaterialError> {
        self.0
            .state
            .lock()
            .inner
            .crypto_session()
            .export_keying_material(output, label, context)
    }

    /// Socket and receive-queue statistics counted by the driver for this connection.
    ///
    /// What the protocol engine counts is [`Connection::stats`].
    #[must_use]
    pub fn driver_stats(&self) -> DriverStats {
        let conn = self.0.state.lock();
        DriverStats {
            send_failures: conn.send_failures,
            oversized_sends: conn.oversized_sends,
            receive_queue: conn.receive_queue.stats(),
            receive_queue_capacity: conn.packets.capacity(),
        }
    }

    /// Modify the number of remotely initiated unidirectional streams that may be concurrently open
    ///
    /// No streams may be opened by the peer unless fewer than `count` are already open. Large
    /// `count`s increase both minimum and worst-case memory consumption.
    pub fn set_max_concurrent_uni_streams(&self, count: impl Into<VarInt>) {
        let mut conn = self.0.state.lock();
        conn.inner
            .set_max_concurrent_streams(Dir::Uni, count.into());
        // May need to send MAX_STREAMS to make progress
        conn.wake();
    }

    /// How many remotely initiated streams of `dir` may be open at once, as this side has
    /// allowed them.
    ///
    /// Lowering the target with
    /// [`set_max_concurrent_streams`](Self::set_max_concurrent_uni_streams) does not take
    /// effect at once: the number falls by one as each open stream of that direction closes.
    #[must_use]
    pub fn max_concurrent_streams(&self, dir: Dir) -> u64 {
        self.0.state.lock().inner.max_concurrent_streams(dir)
    }

    /// Unreserved streams that can be opened immediately under peer credit.
    #[must_use]
    pub fn available_streams(&self, dir: Dir) -> u64 {
        let mut state = self.0.state.lock();
        state
            .inner
            .streams()
            .available_local_streams(dir)
            .saturating_sub(state.reserved_streams[dir as usize])
    }

    /// Exclusive cumulative stream-index limit permitted by the peer for `dir`.
    ///
    /// A locally initiated stream is within peer credit when its index
    /// (`stream_id / 4`) is smaller than this value. Opened and reserved streams
    /// do not reduce this limit; use [`available_streams`](Self::available_streams)
    /// to determine how many additional streams can be opened immediately.
    #[must_use]
    pub fn local_stream_limit(&self, dir: Dir) -> u64 {
        self.0.state.lock().inner.streams().local_stream_limit(dir)
    }

    /// Exclusive cumulative stream-index limit advertised to the peer for `dir`.
    ///
    /// This is the initial transport limit or the latest transmitted MAX_STREAMS
    /// value. A remote stream is within the advertised limit when its index
    /// (`stream_id / 4`) is smaller than this value. Unlike the concurrency
    /// target, it includes streams that have already closed.
    #[must_use]
    pub fn remote_stream_limit(&self, dir: Dir) -> u64 {
        self.0.state.lock().inner.streams().remote_stream_limit(dir)
    }

    /// How many remotely initiated streams of `dir` are open, including those this side has
    /// not accepted yet. They count against
    /// [`max_concurrent_streams`](Self::max_concurrent_streams).
    #[must_use]
    pub fn remote_open_streams(&self, dir: Dir) -> u64 {
        self.0.state.lock().inner.streams().remote_open_streams(dir)
    }

    /// The connection ID this endpoint's generator made for the handshake, from the generator
    /// [`EndpointConfig::set_cid_generator`](crate::EndpointConfig::set_cid_generator)
    /// installed.
    ///
    /// A connection issues further identifiers as it runs and retires this one in time, so
    /// several may be usable at once and this is not "the one in use". It stays the same for
    /// the life of the connection, which is what makes it worth reporting.
    #[must_use]
    pub fn initial_local_id(&self) -> ConnectionId {
        self.0.state.lock().inner.initial_local_id()
    }

    /// The connection ID that names this connection in a qlog trace: the destination the
    /// client chose for its first Initial, which both ends know and neither changes.
    #[must_use]
    pub fn trace_id(&self) -> ConnectionId {
        self.0.state.lock().inner.trace_id()
    }

    /// Control this connection's configured qlog sink. The handle can outlive the
    /// connection and can be inserted into Rama extensions for an application-level trigger.
    /// Returns `None` when no qlog sink was configured before creating the connection.
    #[must_use]
    pub fn qlog_control(&self) -> Option<crate::qlog::ConnectionQlogControl> {
        self.0.state.lock().inner.qlog_control()
    }

    /// Tell the connection its network path changed, so the congestion controller, the
    /// round-trip estimate and MTU discovery start again from the transport configuration.
    ///
    /// Use it when something outside QUIC says the path is a different one, such as a change of
    /// interface. The connection detects a peer's own move on its own.
    pub fn path_changed(&self) {
        let mut conn = self.0.state.lock();
        let now = now();
        conn.inner.path_changed(now);
        conn.wake();
    }

    /// Set the maximum data this connection keeps in flight, as
    /// [`TransportConfig::set_send_window`](crate::TransportConfig::set_send_window) does
    /// before it is established.
    pub fn set_send_window(&self, send_window: u64) {
        let mut conn = self.0.state.lock();
        conn.inner.set_send_window(send_window);
        conn.wake();
    }

    /// Set the flow control window this connection advertises, as
    /// [`TransportConfig::set_receive_window`](crate::TransportConfig::set_receive_window) does
    /// before it is established.
    pub fn set_receive_window(&self, receive_window: impl Into<VarInt>) {
        let mut conn = self.0.state.lock();
        conn.inner.set_receive_window(receive_window.into());
        conn.wake();
    }

    /// Modify the number of remotely initiated bidirectional streams that may be concurrently open
    ///
    /// No streams may be opened by the peer unless fewer than `count` are already open. Large
    /// `count`s increase both minimum and worst-case memory consumption.
    pub fn set_max_concurrent_bi_streams(&self, count: impl Into<VarInt>) {
        let mut conn = self.0.state.lock();
        conn.inner.set_max_concurrent_streams(Dir::Bi, count.into());
        // May need to send MAX_STREAMS to make progress
        conn.wake();
    }

    /// Pace the streams opened or accepted from now on through `gates`, on top of any gates
    /// added before: a stream's bytes move only as all of them admit.
    ///
    /// A gate is consulted only when its stream has data to read or may still send, and
    /// never under this connection's lock. A stream's end, reset or stop reaches a task
    /// waiting on a gate at once, as does a lost connection once the data a gate held back
    /// was read. Writes that never wait ([`SendStream::try_write_generated`]) pass
    /// ungated; datagrams pass the [datagram gates](Self::add_datagram_gates).
    pub fn add_stream_gates(&self, gates: impl StreamGates) {
        let mut state = self.0.state.lock();
        state.gates = Some(ConnectionGates::add(state.gates.as_ref(), gates));
    }

    /// Admit every datagram received or sent from now on through `gates`, on top of any
    /// added before: a datagram moves only if all of them admit it.
    ///
    /// A gate is asked only about a datagram the connection would otherwise deliver or
    /// accept for sending, never under this connection's lock, and once per datagram. A
    /// refused datagram is dropped: a send of it still returns `Ok`, and the drop is counted
    /// in [`ConnectionStats::gated_datagrams`].
    pub fn add_datagram_gates(&self, gates: impl DatagramGates) {
        let mut state = self.0.state.lock();
        state.datagram_gates = Some(ConnectionDatagramGates::add(
            state.datagram_gates.as_ref(),
            gates,
        ));
    }
}

pin_project! {
    /// Future produced by [`Connection::open_uni`]
    pub struct OpenUni<'a> {
        conn: &'a ConnectionRef,
        #[pin]
        notify: Notified<'a>,
    }
}

impl Future for OpenUni<'_> {
    type Output = Result<SendStream, ConnectionError>;
    fn poll(self: Pin<&mut Self>, ctx: &mut Context<'_>) -> Poll<Self::Output> {
        let this = self.project();
        let stream = ready!(poll_open(ctx, this.conn, this.notify, Dir::Uni))?;
        Poll::Ready(Ok(stream.send()))
    }
}

/// Owned credit for one bidirectional stream, returned by [`Connection::try_reserve_bi`].
///
/// Stream IDs are assigned only by [`open`](Self::open), so abandoning a
/// reservation does not consume the peer's cumulative MAX_STREAMS limit.
#[derive(Debug)]
pub struct BiStreamReservation {
    connection: Option<ConnectionRef>,
}

impl BiStreamReservation {
    /// Consume this reservation and open its stream without waiting for credit.
    #[expect(
        clippy::expect_used,
        reason = "owned reservation consumes its guaranteed stream credit exactly once"
    )]
    pub fn open(mut self) -> Result<(SendStream, RecvStream), ConnectionError> {
        let connection = self.connection.take().expect("unconsumed reservation");
        let mut state = connection.state.lock();
        state.reserved_streams[Dir::Bi as usize] -= 1;
        let (gates, side) = (state.gates.clone(), state.inner.side());
        let result = if let Some(error) = &state.error {
            Err(error.clone())
        } else {
            // Reservations are issued only after TLS completes. MAX_STREAMS can
            // no longer shrink through 0-RTT rejection, and other opens respect
            // reserved credit while holding this same state lock.
            let id = state
                .inner
                .streams()
                .open(Dir::Bi)
                .expect("reserved stream credit");
            Ok(id)
        };
        let changed = state.refresh_stream_budget();
        drop(state);
        connection.shared.notify_stream_budget(changed);
        let stream = NewStream {
            conn: connection,
            id: result?,
            is_0rtt: false,
            gates,
            side,
        };
        Ok((stream.send(), stream.recv()))
    }
}

impl Drop for BiStreamReservation {
    fn drop(&mut self) {
        if let Some(connection) = self.connection.take() {
            let mut state = connection.state.lock();
            state.reserved_streams[Dir::Bi as usize] -= 1;
            let changed = state.refresh_stream_budget();
            drop(state);
            connection.shared.notify_stream_budget(changed);
            connection.shared.stream_budget_available[Dir::Bi as usize].notify_waiters();
        }
    }
}

pin_project! {
    /// Future produced by [`Connection::open_bi`]
    pub struct OpenBi<'a> {
        conn: &'a ConnectionRef,
        #[pin]
        notify: Notified<'a>,
    }
}

impl Future for OpenBi<'_> {
    type Output = Result<(SendStream, RecvStream), ConnectionError>;
    fn poll(self: Pin<&mut Self>, ctx: &mut Context<'_>) -> Poll<Self::Output> {
        let this = self.project();
        let stream = ready!(poll_open(ctx, this.conn, this.notify, Dir::Bi))?;
        Poll::Ready(Ok((stream.send(), stream.recv())))
    }
}

fn poll_open<'a>(
    ctx: &mut Context<'_>,
    conn: &'a ConnectionRef,
    mut notify: Pin<&mut Notified<'a>>,
    dir: Dir,
) -> Poll<Result<NewStream, ConnectionError>> {
    let mut state = conn.state.lock();
    if let Some(ref e) = state.error {
        return Poll::Ready(Err(e.clone()));
    }
    let available = state.inner.streams().available_local_streams(dir);
    if available > state.reserved_streams[dir as usize]
        && let Some(id) = state.inner.streams().open(dir)
    {
        let is_0rtt = state.inner.side().is_client() && state.inner.is_handshaking();
        _ = state.refresh_stream_budget();
        let (gates, side) = (state.gates.clone(), state.inner.side());
        drop(state); // Release the lock so clone can take it
        return Poll::Ready(Ok(NewStream {
            conn: conn.clone(),
            id,
            is_0rtt,
            gates,
            side,
        }));
    }
    // Advertise actual peer-credit exhaustion, not a locally reserved slot.
    if available == 0 {
        _ = state.inner.streams().open(dir);
        state.wake();
    }
    loop {
        match notify.as_mut().poll(ctx) {
            // `state` lock ensures we didn't race with readiness
            Poll::Pending => return Poll::Pending,
            // Spurious wakeup, get a new future
            Poll::Ready(()) => {
                notify.set(conn.shared.stream_budget_available[dir as usize].notified())
            }
        }
    }
}

pin_project! {
    /// Future produced by [`Connection::accept_uni`]
    pub struct AcceptUni<'a> {
        conn: &'a ConnectionRef,
        #[pin]
        notify: Notified<'a>,
    }
}

impl Future for AcceptUni<'_> {
    type Output = Result<RecvStream, ConnectionError>;

    fn poll(self: Pin<&mut Self>, ctx: &mut Context<'_>) -> Poll<Self::Output> {
        let this = self.project();
        let stream = ready!(poll_accept(ctx, this.conn, this.notify, Dir::Uni))?;
        Poll::Ready(Ok(stream.recv()))
    }
}

pin_project! {
    /// Future produced by [`Connection::accept_bi`]
    pub struct AcceptBi<'a> {
        conn: &'a ConnectionRef,
        #[pin]
        notify: Notified<'a>,
    }
}

impl Future for AcceptBi<'_> {
    type Output = Result<(SendStream, RecvStream), ConnectionError>;

    fn poll(self: Pin<&mut Self>, ctx: &mut Context<'_>) -> Poll<Self::Output> {
        let this = self.project();
        let stream = ready!(poll_accept(ctx, this.conn, this.notify, Dir::Bi))?;
        Poll::Ready(Ok((stream.send(), stream.recv())))
    }
}

fn poll_accept<'a>(
    ctx: &mut Context<'_>,
    conn: &'a ConnectionRef,
    mut notify: Pin<&mut Notified<'a>>,
    dir: Dir,
) -> Poll<Result<NewStream, ConnectionError>> {
    let mut state = conn.state.lock();
    // Check for incoming streams before checking `state.error` so that already-received streams,
    // which are necessarily finite, can be drained from a closed connection.
    if let Some(id) = state.inner.streams().accept(dir) {
        let is_0rtt = state.inner.is_handshaking();
        state.wake(); // To send additional stream ID credit
        let (gates, side) = (state.gates.clone(), state.inner.side());
        drop(state); // Release the lock so clone can take it
        return Poll::Ready(Ok(NewStream {
            conn: conn.clone(),
            id,
            is_0rtt,
            gates,
            side,
        }));
    } else if let Some(ref e) = state.error {
        return Poll::Ready(Err(e.clone()));
    }
    loop {
        match notify.as_mut().poll(ctx) {
            // `state` lock ensures we didn't race with readiness
            Poll::Pending => return Poll::Pending,
            // Spurious wakeup, get a new future
            Poll::Ready(()) => notify.set(conn.shared.stream_incoming[dir as usize].notified()),
        }
    }
}

/// A stream just opened or accepted, before its handles exist.
struct NewStream {
    conn: ConnectionRef,
    id: StreamId,
    is_0rtt: bool,
    gates: Option<ConnectionGates>,
    side: Side,
}

impl NewStream {
    fn send(&self) -> SendStream {
        SendStream::new(self.conn.clone(), self.id, self.is_0rtt)
            .maybe_with_gates(self.gates(GateDirection::Write))
    }

    fn recv(self) -> RecvStream {
        let gates = self.gates(GateDirection::Read);
        RecvStream::new(self.conn, self.id, self.is_0rtt).maybe_with_gates(gates)
    }

    fn gates(&self, direction: GateDirection) -> Option<GateStack> {
        self.gates.as_ref()?.open(self.id, self.side, direction)
    }
}

/// Refused datagrams one [`ReadDatagram`] poll discards before yielding.
const GATED_DATAGRAMS_PER_POLL: usize = 32;

pin_project! {
    /// Future produced by [`Connection::read_datagram`]
    pub struct ReadDatagram<'a> {
        conn: &'a ConnectionRef,
        #[pin]
        notify: Notified<'a>,
    }
}

impl Future for ReadDatagram<'_> {
    type Output = Result<Bytes, ConnectionError>;
    fn poll(self: Pin<&mut Self>, ctx: &mut Context<'_>) -> Poll<Self::Output> {
        let mut this = self.project();
        let mut refused = 0;
        let state = loop {
            let mut state = this.conn.state.lock();
            // Check for buffered datagrams before checking `state.error` so that already-received
            // datagrams, which are necessarily finite, can be drained from a closed connection.
            let Some(x) = state.inner.datagrams().recv() else {
                break state;
            };
            let Some(gates) = state.datagram_gates.clone() else {
                return Poll::Ready(Ok(x));
            };
            drop(state);
            if this
                .conn
                .admit_datagram(&gates, GateDirection::Read, x.len())
            {
                return Poll::Ready(Ok(x));
            }
            refused += 1;
            if refused == GATED_DATAGRAMS_PER_POLL {
                // A peer keeping the queue full of refused datagrams must not hold the task.
                ctx.waker().wake_by_ref();
                return Poll::Pending;
            }
        };
        if let Some(ref e) = state.error {
            return Poll::Ready(Err(e.clone()));
        }
        loop {
            match this.notify.as_mut().poll(ctx) {
                // `state` lock ensures we didn't race with readiness
                Poll::Pending => return Poll::Pending,
                // Spurious wakeup, get a new future
                Poll::Ready(()) => this
                    .notify
                    .set(this.conn.shared.datagram_received.notified()),
            }
        }
    }
}

/// Future produced by [`Connection::datagram_send_ready`].
pub struct DatagramSendReady {
    notified: Pin<Box<OwnedNotified>>,
    closed: bool,
}

impl fmt::Debug for DatagramSendReady {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("DatagramSendReady")
            .field("closed", &self.closed)
            .finish_non_exhaustive()
    }
}

impl Future for DatagramSendReady {
    type Output = ();

    fn poll(mut self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<()> {
        if self.closed {
            return Poll::Ready(());
        }
        self.notified.as_mut().poll(cx)
    }
}

pin_project! {
    /// Future produced by [`Connection::send_datagram_wait`]
    pub struct SendDatagram<'a> {
        conn: &'a ConnectionRef,
        data: Option<Bytes>,
        // The datagram gates were asked about this payload; never twice across polls.
        admitted: bool,
        #[pin]
        notify: Notified<'a>,
    }
}

impl Future for SendDatagram<'_> {
    type Output = Result<(), SendDatagramError>;
    #[expect(
        clippy::unwrap_used,
        reason = "payload is present until the future completes; repolling after Ready violates the Future contract"
    )]
    fn poll(self: Pin<&mut Self>, ctx: &mut Context<'_>) -> Poll<Self::Output> {
        let mut this = self.project();
        let mut state = this.conn.state.lock();
        if !*this.admitted {
            let len = this.data.as_ref().map_or(0, Bytes::len);
            let gates = match state.datagram_send_gates(len) {
                Ok(gates) => gates,
                Err(error) => return Poll::Ready(Err(error)),
            };
            *this.admitted = true;
            if let Some(gates) = gates {
                drop(state);
                if !this.conn.admit_datagram(&gates, GateDirection::Write, len) {
                    this.data.take();
                    return Poll::Ready(Ok(()));
                }
                state = this.conn.state.lock();
            }
        }
        if let Some(ref e) = state.error {
            return Poll::Ready(Err(SendDatagramError::ConnectionLost(e.clone())));
        }
        match state
            .inner
            .datagrams()
            .send(this.data.take().unwrap(), false)
        {
            Ok(()) => {
                state.wake();
                Poll::Ready(Ok(()))
            }
            Err(e) => Poll::Ready(Err(match e {
                ProtoSendDatagramError::Blocked(data) => {
                    this.data.replace(data);
                    loop {
                        match this.notify.as_mut().poll(ctx) {
                            Poll::Pending => return Poll::Pending,
                            // Spurious wakeup, get a new future
                            Poll::Ready(()) => this
                                .notify
                                .set(this.conn.shared.datagrams_unblocked.notified()),
                        }
                    }
                }
                ProtoSendDatagramError::UnsupportedByPeer => SendDatagramError::UnsupportedByPeer,
                ProtoSendDatagramError::Disabled => SendDatagramError::Disabled,
                ProtoSendDatagramError::TooLarge => SendDatagramError::TooLarge,
            })),
        }
    }
}

#[derive(Debug)]
pub(crate) struct ConnectionRef(Arc<ConnectionInner>);

impl ConnectionRef {
    #[expect(
        clippy::too_many_arguments,
        reason = "constructor wires every shared handle of a new connection"
    )]
    fn new(
        handle: ConnectionHandle,
        mut conn: crate::proto::Connection,
        endpoint: EndpointLink,
        packets: BoundedReceiver<QueuedPacket>,
        on_handshake_data: oneshot::Sender<()>,
        on_connected: oneshot::Sender<Result<bool, ConnectionError>>,
        socket: Sender,
        receive_queue: PacketBudget,
        admission: Option<AdmissionLease>,
    ) -> Self {
        conn.set_spin_local_address(Some(socket.local_addr()));
        let extensions = Extensions::new();
        let socket_info = extensions.insert_arc(Arc::new(SocketInfo::new(
            known_local_address(socket.local_addr(), conn.local_ip()).map(Into::into),
            conn.remote_address().into(),
        )));
        conn.publish_observation(&extensions, true, false);
        #[cfg(feature = "dial9")]
        let dial9 = crate::dial9::Lifecycle::new(&conn);
        #[cfg(feature = "dial9")]
        if dial9.context().operation_id() != 0 {
            extensions.insert(dial9.context());
        }
        Self(Arc::new(ConnectionInner {
            extensions,
            state: Mutex::new(State {
                #[cfg(feature = "dial9")]
                dial9,
                #[cfg(feature = "opentelemetry")]
                metrics: None,
                inner: conn,
                driver: None,
                handle,
                on_handshake_data: Some(on_handshake_data),
                on_connected: Some(on_connected),
                connected: false,
                admission,
                available_streams: [0; 2],
                stream_budget_changed: [BudgetChange::default(); 2],
                socket_info,
                reserved_streams: [0; 2],
                handshake_confirmed: false,
                timer: DeadlineTimer::default(),
                packets,
                endpoint,
                pending_endpoint_events: Vec::new(),
                blocked_writers: FxHashMap::default(),
                blocked_readers: FxHashMap::default(),
                gates: None,
                datagram_gates: None,
                stopped: FxHashMap::default(),
                error: None,
                socket: Some(socket),
                send_buffer: Vec::new(),
                abandon_close: false,
                buffered_transmit: None,
                deferred: None,
                transmits_offered: 0,
                #[cfg(test)]
                descriptors: std::collections::VecDeque::new(),
                endpoint_drained: false,
                pending_rebind: None,
                aside: None,
                wanted_local: None,
                covered_local: None,
                unowned_paths: 0,
                #[cfg(test)]
                pass_allowance: None,
                #[cfg(test)]
                passes: 0,
                #[cfg(test)]
                allowance_parked_without_progress: 0,
                #[cfg(test)]
                retry_allowance_asked: 0,
                #[cfg(test)]
                retry_allowance_parked: 0,
                released_senders: Vec::new(),
                stale_transmits: 0,
                #[cfg(test)]
                fail_ownership: false,
                receive_queue,
                failure_log: FailureLog::default(),
                send_failures: 0,
                oversized_sends: 0,
            }),
            shared: Shared {
                ref_count: AtomicUsize::new(1),
                ..Shared::default()
            },
        }))
    }

    fn stable_id(&self) -> usize {
        Arc::as_ptr(&self.0) as usize
    }
}

impl Clone for ConnectionRef {
    fn clone(&self) -> Self {
        self.shared.ref_count.fetch_add(1, Ordering::Relaxed);
        Self(self.0.clone())
    }
}

impl ConnectionRef {
    /// Close with a transport CONNECTION_CLOSE, ending the connection at once.
    fn close_transport(&self, error: rama_quic_proto::TransportError) {
        let budget_changed = {
            let conn = &mut *self.state.lock();
            conn.inner.close_transport(now(), error);
            conn.terminate(ConnectionError::LocallyClosed, &self.shared);
            conn.wake();
            std::mem::take(&mut conn.stream_budget_changed)
        };
        self.shared.notify_stream_budget(budget_changed);
    }
}

impl Drop for ConnectionRef {
    fn drop(&mut self) {
        if self.shared.ref_count.fetch_sub(1, Ordering::Relaxed) > 1 {
            return;
        }

        let budget_changed = {
            let conn = &mut *self.state.lock();

            if !conn.inner.is_closed() {
                // If the driver is alive, it's just it and us, so we'd better shut it down. If
                // it's not, we can't do any harm. If there were any streams being opened, then
                // either the connection will be closed for an unrelated reason or a fresh
                // reference will be constructed for the newly opened stream.
                conn.implicit_close(&self.shared);
            }
            std::mem::take(&mut conn.stream_budget_changed)
        };
        self.shared.notify_stream_budget(budget_changed);
    }
}

impl std::ops::Deref for ConnectionRef {
    type Target = ConnectionInner;
    fn deref(&self) -> &Self::Target {
        &self.0
    }
}

#[derive(Debug)]
pub(crate) struct ConnectionInner {
    extensions: Extensions,
    pub(crate) state: Mutex<State>,
    pub(crate) shared: Shared,
}

impl ConnectionInner {
    /// Queue a datagram once every datagram gate admits it; a refused one is dropped as sent.
    pub(crate) fn send_gated_datagram(
        &self,
        data: Bytes,
        drop_oldest: bool,
    ) -> Result<(), SendDatagramError> {
        let gates = {
            let mut state = self.state.lock();
            match state.datagram_send_gates(data.len())? {
                Some(gates) => gates,
                None => return state.send_datagram(data, drop_oldest),
            }
        };
        if !self.admit_datagram(&gates, GateDirection::Write, data.len()) {
            return Ok(());
        }
        self.state.lock().send_datagram(data, drop_oldest)
    }

    /// Ask `gates` about a datagram of `len` bytes, counting a refusal; never under the lock.
    pub(crate) fn admit_datagram(
        &self,
        gates: &ConnectionDatagramGates,
        direction: GateDirection,
        len: usize,
    ) -> bool {
        let admitted = gates.admit(direction, len);
        if !admitted {
            let index = match direction {
                GateDirection::Read => 0,
                GateDirection::Write => 1,
            };
            self.shared.gated_datagrams[index].fetch_add(1, Ordering::Relaxed);
        }
        admitted
    }

    /// Apply endpoint control; the caller holds the endpoint lock (see [`EndpointLink`]).
    pub(crate) fn control(&self, message: Control) {
        let mut budget_changed = [BudgetChange::default(); 2];
        let mut state = self.state.lock();
        let conn = &mut *state;
        match message {
            Control::Proto(event) => conn.inner.handle_event(event),
            Control::Close {
                error_code,
                reason,
                abandon,
            } => {
                conn.abandon_close |= abandon;
                conn.close(error_code, reason, &self.shared);
                budget_changed = std::mem::take(&mut conn.stream_budget_changed);
            }
            Control::Rebind(socket) => {
                // A connection that may never send from the new address (a server, or a client
                // whose peer disabled migration) keeps its socket and hands the offer back at
                // once. Otherwise the offer waits until any partially accepted transmit finished
                // on the current sender and the connection may migrate; a rebind that supersedes
                // a still-pending offer hands the superseded sender back.
                if conn.switch_to(&socket) == Switch::Never {
                    conn.released_senders.push(socket);
                } else if let Some(superseded) = conn.pending_rebind.replace(socket) {
                    conn.released_senders.push(superseded);
                }
            }
        }
        conn.wake();
        drop(state);
        // Outside the state lock; endpoint-then-connection order allows the wakers.
        self.shared.notify_stream_budget(budget_changed);
    }

    /// The endpoint marked socket `failed` unusable: leave it now. A transmit still pending on
    /// it is lost like any dropped datagram (loss recovery resends). The pending replacement
    /// takes over when this connection may send from its address now (a same-address
    /// replacement, or a confirmed client whose peer allows migration and that has an unused
    /// destination connection ID); otherwise there is no path it may use at this moment, and
    /// waiting on a dead socket is not an option, so it is terminated with a local path error,
    /// waking everything blocked on it.
    /// The caller holds the endpoint lock (lock order endpoint → connection).
    pub(crate) fn path_failed(&self, failed: SocketId) -> PathFailure {
        let conn = &mut *self.state.lock();
        let mut outcome = PathFailure::Unaffected;
        if conn
            .pending_rebind
            .as_ref()
            .is_some_and(|s| s.socket_id() == failed)
            && let Some(pending) = conn.pending_rebind.take()
        {
            conn.released_senders.push(pending);
        }
        // The aside slot's socket is gone: whatever waited there is given up with its accounting
        // and the handle released. The path this connection sends on is untouched by this.
        if conn
            .aside
            .as_ref()
            .is_some_and(|slot| slot.sender.socket_id() == failed)
        {
            conn.give_up_aside();
        }
        if conn
            .socket
            .as_ref()
            .is_some_and(|s| s.socket_id() == failed)
            && let Some(dead) = {
                // A prefix that handle accepted has left from its address, so the identifier it
                // carried counts before the handle goes; a descriptor nothing was taken from is
                // kept for whichever handle comes next.
                conn.release_buffered();
                conn.socket.take()
            }
        {
            let dead_addr = dead.local_addr();
            conn.released_senders.push(dead);
            outcome = if let Some(replacement) = conn.pending_rebind.take() {
                match conn.switch_from(dead_addr, &replacement) {
                    Switch::SameAddress => {
                        conn.socket = Some(replacement);
                        PathFailure::Switched
                    }
                    Switch::Now if conn.inner.migrate_local_address(now()) => {
                        conn.socket = Some(replacement);
                        PathFailure::Switched
                    }
                    Switch::Now | Switch::Later | Switch::Never => {
                        conn.released_senders.push(replacement);
                        conn.lose_path(&self.shared);
                        PathFailure::Terminated
                    }
                }
            } else {
                conn.lose_path(&self.shared);
                PathFailure::Terminated
            };
        }
        conn.wake();
        outcome
    }

    /// Follow this connection's path to `local`: take a send handle for that address from the
    /// endpoint, note that the current one already covers it, or, when neither is possible, give
    /// up the datagram that named it rather than send it from another address. Called with no
    /// connection lock held, so the endpoint's lock comes first.
    fn follow_local_address(&self, local: SocketAddr, descriptor: crate::driver::udp::TransmitId) {
        let (link, current) = {
            let conn = &*self.state.lock();
            (
                conn.endpoint.clone(),
                conn.socket.as_ref().map(Sender::socket_id),
            )
        };
        let Some(current) = current else {
            return;
        };
        let offered = link.socket_for_local(local, current);
        let released = {
            let conn = &mut *self.state.lock();
            // The question was asked with this lock released, so what it was asked about may be
            // gone: a concurrent path failure, rebind or shutdown changes the socket in use or
            // ends the connection. An answer about a socket this connection no longer sends from
            // is not applied, and a handle offered for it goes back the way any released handle
            // does.
            let stale = conn.error.is_some()
                || conn.socket.as_ref().map(Sender::socket_id) != Some(current)
                || conn.deferred.as_ref().map(|held| held.id) != Some(descriptor);
            if stale {
                let offered = match offered {
                    LocalSocket::Owned(sender) => Some(sender),
                    LocalSocket::Covered | LocalSocket::Unowned => None,
                };
                conn.wake();
                offered
            } else {
                let released = match offered {
                    LocalSocket::Owned(sender)
                        if sender.local_addr() != local && !sender.can_select_source() =>
                    {
                        // That socket is not bound to the path's address and cannot put another
                        // source on the wire, so it cannot honour this path after all. The
                        // datagram goes the way any datagram with no socket for its path goes.
                        conn.give_up_deferred();
                        conn.unowned_paths = conn.unowned_paths.saturating_add(1);
                        Some(sender)
                    }
                    LocalSocket::Owned(sender) => {
                        // A handle for a path this connection is not sending on goes to the aside
                        // slot: the current path keeps its own handle, so its datagrams keep
                        // leaving from it and a socket that is not ready for the other path
                        // cannot park it. The slot serves the path the endpoint answered about,
                        // which a wildcard-bound socket does not report as its own address. The
                        // descriptor that asked for this waits and is offered on the next pass.
                        // What the handle in use covers is untouched: that handle is unchanged,
                        // and the record is what names the concrete path it serves.
                        conn.aside
                            .replace(AsideSlot {
                                sender,
                                serves: local,
                                held: None,
                            })
                            .map(|slot| slot.sender)
                    }
                    LocalSocket::Covered => {
                        conn.covered_local = conn
                            .socket
                            .as_ref()
                            .map(|socket| (socket.socket_id(), local));
                        None
                    }
                    LocalSocket::Unowned => {
                        // The path identity of that datagram cannot be honoured: sending it from
                        // another address would put a different source on the path the peer is
                        // validating. It is given up like any lost datagram, with the accounting its
                        // sender needs, and loss recovery decides what follows.
                        conn.give_up_deferred();
                        conn.unowned_paths = conn.unowned_paths.saturating_add(1);
                        None
                    }
                };
                conn.wake();
                released
            }
        };
        if let Some(previous) = released {
            link.release_senders(vec![previous]);
        }
    }

    fn deliver_endpoint_events(&self) {
        let (link, events, released) = {
            let conn = &mut *self.state.lock();
            (
                conn.endpoint.clone(),
                std::mem::take(&mut conn.pending_endpoint_events),
                std::mem::take(&mut conn.released_senders),
            )
        };
        if !events.is_empty() {
            link.deliver(events);
        }
        link.release_senders(released);
    }
}

#[derive(Debug, Default)]
pub(crate) struct Shared {
    handshake_confirmed: Notify,
    /// Notified when new streams may be locally initiated due to an increase in stream ID flow
    /// control budget
    stream_budget_available: [Notify; 2],
    stream_budget_changes: [Reactive<usize>; 2],
    /// Notified when the peer has initiated a new stream
    stream_incoming: [Notify; 2],
    datagram_received: Notify,
    datagrams_unblocked: Arc<Notify>,
    /// Datagrams the datagram gates dropped: received, sent.
    gated_datagrams: [AtomicU64; 2],
    closed: Notify,
    /// Number of live handles that can used to initiate or handle I/O; excludes the driver
    ref_count: AtomicUsize,
    /// Live [`CloseLease`]s: a graceful endpoint shutdown closes this connection after them.
    pub(crate) close_leases: AtomicUsize,
}

impl Shared {
    /// Admission wakers may re-enter the connection; call outside its state lock.
    fn notify_stream_budget(&self, changed: [BudgetChange; 2]) {
        for (revision, changed) in self.stream_budget_changes.iter().zip(changed) {
            if changed.other || changed.freed > FREED_STREAMS_MAX {
                revision.set(revision.get().wrapping_add(1));
            } else {
                // One request more for each: one waiter each.
                for _ in 0..changed.freed {
                    revision.set_change(revision.get().wrapping_add(1), Change::Freed);
                }
            }
        }
    }
}

/// Beyond this many streams of credit at once, a raise wakes every waiter.
const FREED_STREAMS_MAX: u64 = 64;

/// What happened to one direction's stream credit since admission last heard.
#[derive(Debug, Default, Clone, Copy, PartialEq, Eq)]
struct BudgetChange {
    /// Streams of unreserved credit that came free.
    freed: u64,
    /// Anything else: the handshake finished, the connection closed.
    other: bool,
}

impl BudgetChange {
    const OTHER: Self = Self {
        freed: 0,
        other: true,
    };

    fn merge(&mut self, change: Self) {
        self.freed = self.freed.saturating_add(change.freed);
        self.other |= change.other;
    }
}

pub(crate) struct State {
    #[cfg(feature = "dial9")]
    dial9: crate::dial9::Lifecycle,
    /// Set by the endpoint before the connection is driven, when it records metrics.
    #[cfg(feature = "opentelemetry")]
    pub(crate) metrics: Option<crate::telemetry::ConnectionMetrics>,
    pub(crate) inner: crate::proto::Connection,
    driver: Option<Waker>,
    handle: ConnectionHandle,
    on_handshake_data: Option<oneshot::Sender<()>>,
    on_connected: Option<oneshot::Sender<Result<bool, ConnectionError>>>,
    connected: bool,
    /// An accepted attempt's place among those in progress, until its handshake completes or
    /// the connection ends.
    admission: Option<AdmissionLease>,
    available_streams: [u64; 2],
    stream_budget_changed: [BudgetChange; 2],
    /// Updated in place when a validated path changes.
    socket_info: Arc<SocketInfo>,
    reserved_streams: [u64; 2],
    handshake_confirmed: bool,
    timer: DeadlineTimer,
    packets: BoundedReceiver<QueuedPacket>,
    endpoint: EndpointLink,
    /// Engine events for the endpoint, delivered once the connection lock is released.
    pending_endpoint_events: Vec<EndpointEvent>,
    pub(crate) blocked_writers: FxHashMap<StreamId, Waker>,
    pub(crate) blocked_readers: FxHashMap<StreamId, Waker>,
    /// What the streams opened or accepted from now on move their bytes through.
    gates: Option<ConnectionGates>,
    /// What every datagram received or sent passes through.
    datagram_gates: Option<ConnectionDatagramGates>,
    pub(crate) stopped: FxHashMap<StreamId, super::send_stream::StoppedNotify>,
    /// Always set to Some before the connection becomes drained
    pub(crate) error: Option<ConnectionError>,
    socket: Option<Sender>,
    /// A local address the engine has moved this connection to, with the descriptor that named
    /// it, for which a send handle has been asked of the endpoint. The datagram waits until the
    /// answer arrives, so it leaves from that address rather than from the one this connection was
    /// sending from. The descriptor is part of the request: an answer is applied only while the
    /// work that motivated it is still the work in hand.
    wanted_local: Option<(SocketAddr, crate::driver::udp::TransmitId)>,
    /// A second send handle and the one descriptor waiting on it: a path this connection is not
    /// sending on, such as one it is validating or one it has left, whose datagrams must leave
    /// from another of the endpoint's sockets. Holding it here keeps it out of the current path's
    /// way, so a socket that is not ready for that path cannot park the path that is ready.
    aside: Option<AsideSlot>,
    /// A local address the socket this connection sends from can carry, with the identity of that
    /// socket: a wildcard-bound listener reports the address a datagram arrived on and can put it
    /// on the wire as the source. The socket's identity is part of the record, so a replacement
    /// that cannot carry the same path is asked about again.
    covered_local: Option<(SocketId, SocketAddr)>,
    pending_rebind: Option<Sender>,
    /// Send handles this connection gave up; handed to the endpoint after the connection lock is
    /// released (lock order), which releases their socket leases and drops them outside its own.
    released_senders: Vec<Sender>,
    /// Datagrams dropped because the identifier they carried may no longer be sent.
    stale_transmits: u64,
    /// Tests: make the next ownership attempt find nothing where the descriptor's bytes were.
    #[cfg(test)]
    fail_ownership: bool,
    send_buffer: Vec<u8>,
    /// The endpoint is shutting down: once the peer has been told of the close and nothing is
    /// left to send, the closing period is not waited out (RFC 9000 §10.2).
    abandon_close: bool,
    /// We buffer a transmit when the underlying I/O would block, with the name of the attempt it
    /// belongs to, so the sender cannot apply what it accepted to a different descriptor.
    buffered_transmit: Option<Held>,
    /// A descriptor the engine produced that no handle at hand could take: its path has no
    /// station yet, or the station it belongs to is occupied. It owns its bytes and is placed
    /// first on the next pass.
    deferred: Option<Held>,
    /// Datagrams given up because this endpoint owns no socket that could send from the local
    /// address their path names.
    unowned_paths: u64,
    /// Tests: a smaller per-pass allowance, so the end of a pass is reachable without arranging
    /// twenty datagrams.
    #[cfg(test)]
    pass_allowance: Option<usize>,
    /// Tests: how many send passes this connection has run.
    #[cfg(test)]
    passes: u64,
    /// Tests: passes that spent their allowance without advancing, and so asked for no further
    /// turn.
    #[cfg(test)]
    allowance_parked_without_progress: u64,
    /// Tests: passes that spent their allowance offering descriptors that were already waiting,
    /// put bytes on the wire, and asked for another turn; and those that parked instead.
    #[cfg(test)]
    retry_allowance_asked: u64,
    #[cfg(test)]
    retry_allowance_parked: u64,
    /// Names each descriptor handed to the sender.
    transmits_offered: u64,
    /// Tests: the last [`DESCRIPTORS`] descriptors offered, oldest first.
    #[cfg(test)]
    descriptors: std::collections::VecDeque<Descriptor>,
    endpoint_drained: bool,
    receive_queue: PacketBudget,
    failure_log: FailureLog,
    send_failures: u64,
    oversized_sends: u64,
}

impl State {
    /// Record the connection at its first terminal outcome: `reason`, or the error it ended
    /// with, if any.
    #[cfg(feature = "opentelemetry")]
    fn finish_metrics(&mut self, reason: Option<&ConnectionError>) {
        if let Some(metrics) = self.metrics.take() {
            metrics.finish(
                self.inner.side().is_server(),
                self.inner.version(),
                reason.or(self.error.as_ref()),
                self.connected,
                &self.inner.stats(),
            );
        }
    }

    fn drive(
        &mut self,
        shared: &Shared,
        extensions: &Extensions,
        cx: &mut Context,
    ) -> Poll<io::Result<()>> {
        self.inner.expire_handshake(now());

        let mut keep_going = match self.process_packets(cx) {
            Ok(more) => more,
            Err(e) => {
                self.terminate(e, shared);
                return Poll::Ready(Ok(()));
            }
        };
        // Callback work can finish without a peer packet: resume it before sending.
        self.inner.poll_pending_callbacks(now, cx);
        keep_going |= match self.drive_transmit(cx) {
            Ok(keep_going) => keep_going,
            Err(error) => {
                let reason =
                    rama_quic_proto::TransportError::INTERNAL_ERROR("QUIC UDP send failed")
                        .with_cause(error);
                self.terminate(reason.into(), shared);
                return Poll::Ready(Ok(()));
            }
        };
        // If a timer expires, there might be more to transmit. When we transmit something, we
        // might need to reset a timer. Hence, we must loop until neither happens.
        keep_going |= self.drive_timer(cx);
        if self.abandon_close
            && self.buffered_transmit.is_none()
            && self.deferred.is_none()
            && self.inner.close_announced()
        {
            self.inner.abandon_close(now());
        }
        self.forward_endpoint_events();
        let closed = self.inner.is_closed();
        self.inner.publish_observation(extensions, false, closed);
        self.update_socket_info();
        if !self.inner.is_drained() {
            self.forward_app_events(shared, extensions);
            if keep_going {
                // If the connection hasn't processed all tasks, schedule it again
                cx.waker().wake_by_ref();
            } else {
                self.driver = Some(cx.waker().clone());
            }
            return Poll::Pending;
        }
        // The driver delivers Drained to the endpoint before notifying the
        // application. A Version Negotiation retry can then reuse this socket
        // even if the waiting task resumes immediately on another worker.
        Poll::Ready(Ok(()))
    }

    /// Tests: record what became of a descriptor that was offered.
    #[cfg(test)]
    fn note_descriptor(&mut self, held: &Held, outcome: Outcome, reported: bool) {
        while self.descriptors.len() >= DESCRIPTORS {
            self.descriptors.pop_front();
        }
        let bytes = held.payload(&self.send_buffer).unwrap_or_default().to_vec();
        self.descriptors.push_back(Descriptor {
            id: held.id.0,
            size: held.transmit.size,
            bytes,
            segment_size: held.transmit.segment_size.map(|size| size.get()),
            destination: held.transmit.destination,
            cid_used: held.transmit.cid_used,
            outcome,
            reported,
        });
    }

    /// Where a descriptor has to leave from: the handle this connection sends on carries the
    /// paths it is bound to and those it covers, another path's handle waits aside, and anything
    /// else only the endpoint can answer.
    fn station_for(&self, local: Option<SocketAddr>) -> Station {
        let Some(local) = local else {
            return Station::Primary;
        };
        let ours = self.socket.as_ref().is_some_and(|socket| {
            socket.local_addr() == local || self.covered_local == Some((socket.socket_id(), local))
        });
        if ours {
            return Station::Primary;
        }
        match self.aside.as_ref() {
            Some(slot) if slot.serves == local => Station::Aside,
            _ => Station::Ask(local),
        }
    }

    /// Deal with one descriptor: offer it where its path says it must leave from, or set it aside
    /// until a handle for that path is at hand.
    fn place(
        &mut self,
        cx: &mut Context,
        now: crate::driver::Instant,
        held: Held,
        work: &mut Work,
    ) -> io::Result<Placed> {
        work.attempted += datagrams(&held.transmit);
        match self.station_for(held.transmit.local) {
            // A descriptor already waits on that handle: this one waits its turn rather than
            // taking its place, so nothing is lost and nothing is sent out of order.
            Station::Primary if self.buffered_transmit.is_some() => Ok(self.set_aside(held, work)),
            Station::Primary => self.send_primary(cx, now, held, work),
            Station::Aside => Ok(self.send_aside(cx, now, held, work)),
            // A descriptor for a path this connection is not sending on — one it is validating,
            // or one it has left whose challenge is answered late — has to leave from another of
            // the endpoint's sockets (RFC 9000 §9.6, §8.2.2). One path at a time is kept aside,
            // so a handle serving another path goes back before this one is asked for.
            Station::Ask(local) => {
                self.give_up_aside();
                // The endpoint is asked about the descriptor that is actually waiting for the
                // answer. One given up for want of a place to wait must not rename the question,
                // or the answer would arrive for a descriptor that is no longer there.
                let id = held.id;
                let placed = self.set_aside(held, work);
                if self.deferred.as_ref().is_some_and(|held| held.id == id) {
                    self.wanted_local = Some((local, id));
                }
                Ok(placed)
            }
        }
    }

    /// Offer a descriptor on the handle this connection sends from.
    fn send_primary(
        &mut self,
        cx: &mut Context,
        now: crate::driver::Instant,
        held: Held,
        work: &mut Work,
    ) -> io::Result<Placed> {
        let Some(sender) = self.socket.as_mut() else {
            return Err(io::Error::new(
                io::ErrorKind::NotConnected,
                "QUIC send handle released",
            ));
        };
        // Observed before and after this offer's processing, so the record says whether the
        // connection was told, not whether it should have been. No other connection can move
        // this count while this state is locked.
        #[cfg(test)]
        let reports_before = self.inner.cid_sent_calls();
        // This descriptor is offered in the pass the engine wrote it in, so the send buffer
        // still holds it; a descriptor kept past that owns its bytes.
        let Some(bytes) = held.payload(&self.send_buffer) else {
            return Ok(self.retire(held, work));
        };
        let outcome = offer(&mut self.inner, sender, cx, held.id, &held.transmit, bytes);
        #[cfg(test)]
        let reported = self.inner.cid_sent_calls() > reports_before;
        match outcome {
            Offered::Sent => {
                #[cfg(test)]
                self.note_descriptor(&held, Outcome::Sent, reported);
                work.advanced = true;
                work.sent = true;
                Ok(Placed::Done)
            }
            // The descriptor is retained with its socket state and any accepted prefix. The
            // sender's waker, or the endpoint's confirmation that the route a reset would arrive
            // by is installed, brings this connection back; no polling loop is needed. Receiving,
            // timers and shutdown continue meanwhile, and so does a path kept aside: the bytes
            // move out of the send buffer so the engine can write for that path.
            _outcome @ (Offered::Pending | Offered::Awaiting) => {
                #[cfg(test)]
                self.note_descriptor(
                    &held,
                    match _outcome {
                        Offered::Awaiting => Outcome::Awaiting,
                        _ => Outcome::Pending,
                    },
                    reported,
                );
                // Another path to serve is reason to take the bytes out of the send buffer and
                // go on: the engine can then write what that path needs. With no such path the
                // descriptor stays where the engine wrote it and the pass ends here.
                if self.aside.is_some() || self.inner.serves_another_path() {
                    return match held.into_owned(self.ownership_source()) {
                        Ok(owned) => {
                            self.buffered_transmit = Some(owned.into_held());
                            Ok(Placed::Blocked)
                        }
                        Err(held) => Ok(self.retire(held, work)),
                    };
                }
                self.buffered_transmit = Some(held);
                Ok(Placed::Stopped)
            }
            Offered::Obsolete => {
                #[cfg(test)]
                self.note_descriptor(&held, Outcome::Obsolete, reported);
                self.stale_transmits += 1;
                work.advanced = true;
                Ok(Placed::Done)
            }
            Offered::Failed(error) => {
                #[cfg(test)]
                self.note_descriptor(&held, Outcome::Failed, reported);
                match error.class {
                    // The engine already counts this datagram as in flight, so loss detection
                    // and MTU discovery recover from it like from any dropped packet.
                    SendFailure::Datagram | SendFailure::TooLarge => {
                        // Too large because the socket now carries less than QUIC needs (a
                        // shrunken tunnel): every later packet fails the same way.
                        if error.class == SendFailure::TooLarge
                            && let Some(Err(capacity)) = self
                                .socket
                                .as_ref()
                                .map(|sender| payload_ceiling(&sender.capabilities()))
                        {
                            return Err(io::Error::other(capacity));
                        }
                        if error.class == SendFailure::TooLarge {
                            self.oversized_sends += 1;
                        } else {
                            self.send_failures += 1;
                        }
                        self.log_send_failure(now, "QUIC transmit", &held, &error);
                        work.advanced = true;
                        Ok(Placed::Done)
                    }
                    // An invalid descriptor or an unusable socket cannot be retried.
                    SendFailure::Descriptor | SendFailure::Socket => Err(error.error),
                }
            }
        }
    }

    /// Log a datagram the network stack refused, quietly for an MTU discovery probe: refusing
    /// one as too large is how the search learns the local interface is smaller.
    fn log_send_failure(
        &mut self,
        now: crate::driver::Instant,
        what: &'static str,
        held: &Held,
        error: &SendError,
    ) {
        if error.class == SendFailure::TooLarge
            && is_mtu_probe(&held.transmit, self.inner.current_mtu())
        {
            debug!(
                error = %error.error,
                size = held.transmit.size,
                "{what}: MTU probe above the local MTU dropped"
            );
        } else {
            self.failure_log.record(now, what, error);
        }
    }

    /// Offer a descriptor on the handle kept aside for the path it names. The slot holds one
    /// descriptor with the bytes that belong to it, so a socket that is not ready for that path
    /// cannot park the path this connection is sending on.
    fn send_aside(
        &mut self,
        cx: &mut Context,
        now: crate::driver::Instant,
        held: Held,
        work: &mut Work,
    ) -> Placed {
        // One descriptor at a time on that path: what the engine produced next waits until the
        // handle has taken what already waits on it.
        let Some(serves) = self
            .aside
            .as_ref()
            .and_then(|slot| slot.held.is_none().then_some(slot.serves))
        else {
            return self.set_aside(held, work);
        };
        // The descriptor waits on that handle across passes, so its bytes come with it.
        let owned = match held.into_owned(self.ownership_source()) {
            Ok(owned) => owned,
            Err(held) => return self.retire(held, work),
        };
        let serves = Some(serves);
        #[cfg(test)]
        let reports_before = self.inner.cid_sent_calls();
        let outcome = {
            let Some(slot) = self.aside.as_mut() else {
                return self.set_aside(owned.into_held(), work);
            };
            offer(
                &mut self.inner,
                &mut slot.sender,
                cx,
                owned.id,
                &owned.transmit,
                &owned.bytes,
            )
        };
        let held = owned.into_held();
        #[cfg(test)]
        let reported = self.inner.cid_sent_calls() > reports_before;
        match outcome {
            Offered::Sent => {
                #[cfg(test)]
                self.note_descriptor(&held, Outcome::Sent, reported);
                work.advanced = true;
                work.sent = true;
                if serves == self.inner.path_local() {
                    self.promote_aside();
                }
                Placed::Done
            }
            // Nothing left for that path; the sender's waker or the endpoint's route
            // confirmation brings this connection back and the descriptor is offered again.
            Offered::Pending | Offered::Awaiting => {
                if let Some(slot) = self.aside.as_mut() {
                    slot.held = Some(held);
                }
                Placed::Done
            }
            Offered::Obsolete => {
                #[cfg(test)]
                self.note_descriptor(&held, Outcome::Obsolete, reported);
                self.stale_transmits += 1;
                work.advanced = true;
                Placed::Done
            }
            Offered::Failed(error) => {
                #[cfg(test)]
                self.note_descriptor(&held, Outcome::Failed, reported);
                if error.class == SendFailure::TooLarge {
                    self.oversized_sends += 1;
                } else {
                    self.send_failures += 1;
                }
                self.log_send_failure(now, "QUIC transmit aside", &held, &error);
                work.advanced = true;
                // An invalid descriptor or an unusable socket ends that handle's usefulness: the
                // path it served is given up, while the path this connection sends on is not
                // touched by it.
                if matches!(error.class, SendFailure::Descriptor | SendFailure::Socket) {
                    self.give_up_aside();
                }
                Placed::Done
            }
        }
    }

    /// Offer the descriptor waiting on the aside handle again. A socket that became writable, a
    /// route that was installed or a timer is reason to retry it even when the engine has no new
    /// output at all.
    fn retry_aside(&mut self, cx: &mut Context, now: crate::driver::Instant, work: &mut Work) {
        let Some(held) = self.aside.as_mut().and_then(|slot| slot.held.take()) else {
            return;
        };
        work.attempted += datagrams(&held.transmit);
        let _ = self.send_aside(cx, now, held, work);
    }

    /// The path the handle kept aside serves is the one this connection sends on now, so that
    /// handle becomes the one in hand and the one it replaces goes aside. A descriptor the
    /// replaced handle has taken a prefix of goes with it: those bytes left from that address.
    fn promote_aside(&mut self) {
        let Some(primary) = self.socket.take() else {
            return;
        };
        // The tuple that handle served, which for a wildcard-bound socket is the concrete
        // address it was covering rather than the address it is bound to.
        let previous = self
            .covered_local
            .filter(|(id, _)| *id == primary.socket_id())
            .map_or_else(|| primary.local_addr(), |(_, address)| address);
        let waiting = self
            .buffered_transmit
            .take_if(|held| primary.accepted_any(held.id));
        // Whatever waits goes on to another handle, so its bytes come with it; one whose bytes
        // are gone is retired here rather than carried.
        let waiting = match waiting.map(|held| held.into_owned(self.ownership_source())) {
            Some(Ok(owned)) => Some(owned.into_held()),
            Some(Err(held)) => {
                self.retire_quietly(held);
                None
            }
            None => None,
        };
        let Some(slot) = self.aside.as_mut() else {
            self.socket = Some(primary);
            self.buffered_transmit = waiting.or_else(|| self.buffered_transmit.take());
            return;
        };
        let promoted = std::mem::replace(&mut slot.sender, primary);
        slot.serves = previous;
        slot.held = waiting;
        self.socket = Some(promoted);
        // The coverage record stays as it is: it names the socket it was established on, and that
        // socket is no longer the one in use, so the record is inert until the endpoint answers
        // about this one.
    }

    /// The buffer an ownership attempt copies from.
    ///
    /// Tests can make one attempt find nothing there: the engine cannot produce that state, and
    /// the code has to retire the descriptor rather than leave it pointing at a buffer that is
    /// about to hold something else.
    #[cfg_attr(
        not(test),
        expect(
            clippy::needless_pass_by_ref_mut,
            reason = "the test build takes the one-shot failure flag out of `self` here"
        )
    )]
    fn ownership_source(&mut self) -> &[u8] {
        #[cfg(test)]
        if std::mem::take(&mut self.fail_ownership) {
            return &[];
        }
        &self.send_buffer
    }

    /// Give up a descriptor whose bytes are no longer there to send. It is never offered: it
    /// points at a buffer the engine writes again, so what it named is left to loss recovery.
    fn retire(&mut self, held: Held, work: &mut Work) -> Placed {
        self.retire_quietly(held);
        work.advanced = true;
        Placed::Done
    }

    /// The same, where the caller is not running a send pass.
    #[expect(
        clippy::needless_pass_by_value,
        reason = "the descriptor is relinquished here, so it is taken rather than borrowed"
    )]
    fn retire_quietly(&mut self, held: Held) {
        #[cfg(test)]
        self.note_descriptor(&held, Outcome::Obsolete, false);
        let _ = held;
        self.stale_transmits += 1;
    }

    /// Ask the engine for the next descriptor, written into the send buffer.
    fn pull(&mut self, now: crate::driver::Instant, max_datagrams: usize) -> Option<Held> {
        self.update_spin_local();
        self.send_buffer.clear();
        self.send_buffer.reserve(self.inner.current_mtu() as usize);
        let transmit = self
            .inner
            .poll_transmit(now, max_datagrams, &mut self.send_buffer)?;
        self.transmits_offered = self.transmits_offered.wrapping_add(1);
        Some(Held {
            id: crate::driver::udp::TransmitId(self.transmits_offered),
            transmit,
            bytes: None,
        })
    }

    /// Give up whatever waits on the aside handle and release it: the prefix its sender took is
    /// reported, the remainder is dropped, and the handle goes back through the endpoint.
    fn give_up_aside(&mut self) {
        let Some(mut slot) = self.aside.take() else {
            return;
        };
        if let Some(held) = slot.held.take() {
            let accepted = slot.sender.accepted_any(held.id);
            slot.sender.abandon(held.id);
            let mut reported = false;
            if let Some(seq) = held.transmit.cid_used
                && accepted
            {
                self.inner.cid_sent(seq, held.transmit.destination);
                reported = true;
            }
            #[cfg(test)]
            self.note_descriptor(&held, Outcome::Obsolete, reported);
            let _ = reported;
            self.stale_transmits += 1;
        }
        self.released_senders.push(slot.sender);
    }

    /// Release the descriptor waiting on this connection's sender before that sender changes or
    /// goes away.
    ///
    /// The sender's record of the descriptor is cancelled either way. A descriptor the sender had
    /// already taken a prefix of cannot move: those bytes left from that socket's address, so the
    /// identifier they carried is reported as used towards its destination (RFC 9000 §10.3.1) and
    /// the unsent remainder is given up like any dropped datagram. One nothing was taken from is
    /// kept, whole, for whichever sender comes next.
    fn release_buffered(&mut self) {
        let Some(held) = self.buffered_transmit.take() else {
            return;
        };
        let Some(socket) = self.socket.as_mut() else {
            return;
        };
        let started = socket.accepted_any(held.id);
        socket.abandon(held.id);
        if !started {
            self.buffered_transmit = Some(held);
            return;
        }
        #[cfg(test)]
        let reports_before = self.inner.cid_sent_calls();
        if let Some(seq) = held.transmit.cid_used {
            self.inner.cid_sent(seq, held.transmit.destination);
        }
        #[cfg(test)]
        {
            let reported = self.inner.cid_sent_calls() > reports_before;
            self.note_descriptor(&held, Outcome::Obsolete, reported);
        }
        self.stale_transmits += 1;
    }

    /// Keep a descriptor whose station is occupied, or that is waiting for the endpoint's answer,
    /// until it can be placed. It takes its bytes with it, so the engine may write the next one.
    ///
    /// There is one such place. A second descriptor for a station that is still occupied is given
    /// up the way one that never reached a sender is: a path that cannot take anything does not
    /// get to stop the path that can, and loss recovery decides what follows.
    fn set_aside(&mut self, held: Held, work: &mut Work) -> Placed {
        if self.deferred.is_none() {
            return match held.into_owned(self.ownership_source()) {
                Ok(owned) => {
                    self.deferred = Some(owned.into_held());
                    Placed::Done
                }
                Err(held) => self.retire(held, work),
            };
        }
        #[cfg(test)]
        self.note_descriptor(&held, Outcome::Obsolete, false);
        let _ = held;
        self.stale_transmits += 1;
        work.advanced = true;
        Placed::Done
    }

    /// Take the descriptor that waited for a station, if the station it belongs to is free now.
    /// One still waiting for the endpoint's answer stays where it is.
    fn take_deferred(&mut self) -> Option<Held> {
        let station = {
            let held = self.deferred.as_ref()?;
            self.station_for(held.transmit.local)
        };
        let free = match station {
            Station::Primary => self.buffered_transmit.is_none(),
            Station::Aside => self.aside.as_ref().is_some_and(|slot| slot.held.is_none()),
            Station::Ask(_) => false,
        };
        free.then(|| self.deferred.take()).flatten()
    }

    /// Give up the descriptor waiting for a handle: it never reached a sender, so nothing of it
    /// left and there is no accepted prefix to account for.
    fn give_up_deferred(&mut self) {
        let Some(held) = self.deferred.take() else {
            return;
        };
        #[cfg(test)]
        self.note_descriptor(&held, Outcome::Obsolete, false);
        let _ = held;
        self.stale_transmits += 1;
    }

    /// The datagrams one pass may offer before it gives the task back.
    #[cfg_attr(
        not(test),
        expect(
            clippy::unused_self,
            reason = "the test build reads a per-connection allowance from `self`"
        )
    )]
    fn pass_allowance(&self) -> usize {
        #[cfg(test)]
        if let Some(allowance) = self.pass_allowance {
            return allowance;
        }
        MAX_TRANSMIT_DATAGRAMS
    }

    fn drive_transmit(&mut self, cx: &mut Context) -> io::Result<bool> {
        let now = now();
        // A failure raised where it could not be returned closes the connection here, before
        // anything is retried: a datagram held for a route that will never exist must not keep
        // the cause from reaching the application.
        #[cfg(test)]
        {
            self.passes += 1;
        }
        self.inner.settle_deferred_error(now);
        // What already waits on a handle is offered again before the engine is asked for more: a
        // socket that became writable, or a route that was installed, is the reason this pass
        // runs and there may be no new output at all.
        // Every offer counts against the same allowance, whether the descriptor is new, waiting
        // on a handle from an earlier pass, or given up for want of a station.
        let mut work = Work::default();
        self.retry_aside(cx, now, &mut work);
        let mut blocked = false;

        loop {
            if self.buffered_transmit.is_none()
                && let Some(pending) = self.pending_rebind.as_ref()
            {
                // The in-flight transmit finished on the old sender: switch when this connection
                // may send from the offered address, keep waiting while the handshake is not
                // confirmed, and hand the offer back once it is known to be unusable.
                match self.switch_to(pending) {
                    // The connection ID switch is committed first; the address follows only
                    // once it succeeded, so no CID is ever sent from two addresses.
                    Switch::Now if !self.inner.migrate_local_address(now) => {}
                    Switch::SameAddress | Switch::Now => {
                        if let Some(socket) = self.pending_rebind.take()
                            && let Some(old) = self.socket.replace(socket)
                        {
                            self.released_senders.push(old);
                        }
                    }
                    Switch::Later => {}
                    Switch::Never => {
                        self.released_senders.extend(self.pending_rebind.take());
                    }
                }
            }
            let Some(socket) = self.socket.as_ref() else {
                return Err(io::Error::new(
                    io::ErrorKind::NotConnected,
                    "QUIC send handle released",
                ));
            };
            let max_datagrams = socket.max_transmit_segments().min(MAX_TRANSMIT_SEGMENTS);
            // The descriptor in hand first, then one that had no station last time, then a new
            // one. Nothing is asked of the engine while something already produced has nowhere to
            // go, or past a blocked handle with no free station for another path to run on:
            // either way what it produced would have nowhere to wait.
            let held = match self.buffered_transmit.take_if(|_| !blocked) {
                Some(held) => held,
                None => {
                    if let Some(held) = self.take_deferred() {
                        held
                    } else {
                        // The engine is asked only while some station could take what it
                        // produces. With the handle in use blocked that means a handle kept
                        // aside with nothing on it, or the room to ask the endpoint for one.
                        let aside_free = match self.aside.as_ref() {
                            Some(slot) => slot.held.is_none(),
                            None => self.deferred.is_none(),
                        };
                        if blocked && !aside_free {
                            return Ok(false);
                        }
                        match self.pull(now, max_datagrams) {
                            Some(held) => {
                                // The engine handed this over; whatever becomes of it, there may
                                // be more where it came from.
                                work.pulled = true;
                                work.advanced = true;
                                held
                            }
                            None => break,
                        }
                    }
                }
            };
            match self.place(cx, now, held, &mut work)? {
                Placed::Done => {}
                Placed::Blocked => blocked = true,
                Placed::Stopped => return Ok(false),
            }
            if work.attempted >= self.pass_allowance() {
                let another_turn = work.advanced;
                #[cfg(test)]
                if !another_turn {
                    // A pass that spent its allowance without placing, giving up or producing
                    // anything, and so asked for no further turn.
                    self.allowance_parked_without_progress += 1;
                }
                #[cfg(test)]
                if !work.pulled && work.sent {
                    // A pass that spent its allowance on descriptors that were already waiting,
                    // and put bytes on the wire doing it.
                    match another_turn {
                        true => self.retry_allowance_asked += 1,
                        false => self.retry_allowance_parked += 1,
                    }
                }
                // TODO: What isn't ideal here yet is that if we don't poll all
                // datagrams that could be sent we don't go into the `app_limited`
                // state and CWND continues to grow until we get here the next time.
                //
                // A pass that spent its allowance waiting asks for no further turn: what it
                // waits on holds this task's waker. One that spent it on bytes that left, on
                // descriptors it gave up, or on output the engine handed over asks for another,
                // because none of those leave a waker behind.
                return Ok(another_turn);
            }
        }

        Ok(false)
    }

    fn forward_endpoint_events(&mut self) {
        while let Some(event) = self.inner.poll_endpoint_events() {
            if event.is_drained() {
                self.endpoint_drained = true;
            }
            self.pending_endpoint_events.push(event);
        }
    }

    /// Pending engine events plus exactly one Drained, if none was emitted yet.
    fn take_endpoint_events_with_drained(&mut self) -> Vec<EndpointEvent> {
        let mut events = std::mem::take(&mut self.pending_endpoint_events);
        if !self.endpoint_drained {
            self.endpoint_drained = true;
            events.push(EndpointEvent::drained());
        }
        events
    }

    /// Keep spin's local address in sync with the sender before receiving or building packets.
    fn update_spin_local(&mut self) {
        if let Some(socket) = &self.socket {
            self.inner.set_spin_local_address(Some(socket.local_addr()));
        }
    }

    /// Feed queued packets to the engine, bounded per poll. Each packet releases its budget
    /// charge here. `Err` means the endpoint driver is gone and this driver must exit.
    fn process_packets(&mut self, cx: &mut Context) -> Result<bool, ConnectionError> {
        self.update_spin_local();
        for _ in 0..IO_LOOP_BOUND {
            match self.packets.poll_recv(cx) {
                Poll::Ready(Some(QueuedPacket { event, _permit })) => {
                    self.inner.handle_event(event);
                }
                Poll::Ready(None) => {
                    return Err(ConnectionError::TransportError(
                        rama_quic_proto::TransportError::new(
                            rama_quic_proto::TransportErrorCode::INTERNAL_ERROR,
                            "endpoint driver future was dropped",
                        ),
                    ));
                }
                Poll::Pending => return Ok(false),
            }
        }
        Ok(true)
    }

    /// Report a moved path once it is validated: an attempt that is reverted never shows.
    fn update_socket_info(&self) {
        let Some(socket) = &self.socket else {
            return;
        };
        if !self.inner.path_validated() {
            return;
        }
        let local_addr =
            known_local_address(socket.local_addr(), self.inner.local_ip()).map(Into::into);
        let peer_addr = self.inner.remote_address().into();
        if self.socket_info.set_current(local_addr, peer_addr) {
            debug!(
                %peer_addr,
                ?local_addr,
                "quic connection moved to another path"
            );
        }
    }

    fn forward_app_events(&mut self, shared: &Shared, extensions: &Extensions) {
        while let Some(event) = self.inner.poll() {
            match event {
                Event::HandshakeDataReady => {
                    // Early data uses the connection before the handshake completes: publish the
                    // negotiated protocol now; `Connected` publishes it again with the peer's chain.
                    if let Some(parameters) = self.inner.crypto_session().handshake_summary() {
                        extensions.insert(parameters);
                    }
                    if let Some(x) = self.on_handshake_data.take() {
                        // Nobody waiting for it is not an error: the receiver may be gone.
                        let _sent = x.send(());
                    }
                }
                Event::Connected => {
                    #[cfg(feature = "dial9")]
                    self.dial9.connected(&self.inner);
                    #[cfg(feature = "opentelemetry")]
                    if let Some(metrics) = &self.metrics {
                        metrics.connected(self.inner.side().is_server(), self.inner.version());
                    }
                    self.connected = true;
                    // Published like the TLS stacks do for streams, so services read the
                    // negotiated protocol and peer identity from the connection's extensions.
                    if let Some(parameters) = self.inner.crypto_session().handshake_summary() {
                        extensions.insert(parameters);
                    }
                    extensions.insert(QuicConnectionInfo {
                        version: self.inner.version(),
                        original_version: self.inner.original_version(),
                        early_data_keys_enabled: self.inner.has_0rtt(),
                        handshake_rtt: self.inner.rtt(),
                        handshake_mtu: self.inner.current_mtu(),
                    });
                    if let Some(admission) = self.admission.take() {
                        admission.complete(now());
                    }
                    // Reservations are disabled before this event, even when
                    // provisional transport parameters already exposed credit.
                    for pending in &mut self.stream_budget_changed {
                        pending.merge(BudgetChange::OTHER);
                    }
                    if let Some(x) = self.on_connected.take() {
                        // Nobody waiting for it is not an error: the receiver may be gone.
                        drop(x.send(Ok(
                            self.inner.side().is_server() || self.inner.accepted_0rtt()
                        )));
                    }
                    if self.inner.side().is_client() && !self.inner.accepted_0rtt() {
                        // Wake up rejected 0-RTT streams so they can fail immediately with
                        // `ZeroRttRejected` errors.
                        wake_all(&mut self.blocked_writers);
                        wake_all(&mut self.blocked_readers);
                        wake_all_notify(&mut self.stopped);
                    }
                }
                Event::HandshakeConfirmed => {
                    self.handshake_confirmed = true;
                    shared.handshake_confirmed.notify_waiters();
                }
                Event::ConnectionLost { reason } => {
                    self.terminate(reason, shared);
                }
                Event::Stream(StreamEvent::Writable { id }) => {
                    wake_stream(id, &mut self.blocked_writers)
                }
                Event::Stream(StreamEvent::Opened { dir: Dir::Uni }) => {
                    shared.stream_incoming[Dir::Uni as usize].notify_waiters();
                }
                Event::Stream(StreamEvent::Opened { dir: Dir::Bi }) => {
                    shared.stream_incoming[Dir::Bi as usize].notify_waiters();
                }
                Event::DatagramReceived => {
                    shared.datagram_received.notify_waiters();
                }
                Event::DatagramsUnblocked => {
                    shared.datagrams_unblocked.notify_waiters();
                }
                Event::Stream(StreamEvent::Readable { id }) => {
                    wake_stream(id, &mut self.blocked_readers)
                }
                Event::Stream(StreamEvent::Available { dir }) => {
                    // Might mean any number of streams are ready, so we wake up everyone
                    shared.stream_budget_available[dir as usize].notify_waiters();
                }
                Event::Stream(StreamEvent::Finished { id }) => {
                    wake_stream_notify(id, &self.stopped)
                }
                Event::Stream(StreamEvent::Stopped { id, .. }) => {
                    wake_stream_notify(id, &self.stopped);
                    wake_stream(id, &mut self.blocked_writers);
                }
            }
        }
        let changed = self.refresh_stream_budget();
        for (pending, changed) in self.stream_budget_changed.iter_mut().zip(changed) {
            pending.merge(changed);
        }
    }

    /// Wake admission only when unreserved stream credit increases, by how
    /// much it did. Acquiring or consuming a reservation cannot help another
    /// waiter.
    fn refresh_stream_budget(&mut self) -> [BudgetChange; 2] {
        let mut changed = [BudgetChange::default(); 2];
        for dir in Dir::iter() {
            let index = dir as usize;
            let available = self
                .inner
                .streams()
                .available_local_streams(dir)
                .saturating_sub(self.reserved_streams[index]);
            changed[index].freed = available.saturating_sub(self.available_streams[index]);
            self.available_streams[index] = available;
        }
        changed
    }

    fn drive_timer(&mut self, cx: &mut Context<'_>) -> bool {
        let Some(deadline) = self.inner.poll_timeout() else {
            self.timer.clear();
            return false;
        };
        match self.timer.poll(deadline, now(), cx) {
            Deadline::Elapsed => {
                self.inner.handle_timeout(now());
                true
            }
            Deadline::Pending => false,
        }
    }

    /// Wake up a blocked `Driver` task to process I/O
    pub(crate) fn wake(&mut self) {
        if let Some(x) = self.driver.take() {
            x.wake();
        }
    }

    /// Whether this connection may start sending from `candidate` instead of its current sender.
    fn switch_to(&self, candidate: &Sender) -> Switch {
        match self.socket.as_ref().map(Sender::local_addr) {
            Some(current) => self.switch_from(current, candidate),
            // Without a sender there is no address to keep; only the migration rules apply.
            None => self.migration_switch(),
        }
    }

    /// Whether this connection, currently sending from `current`, may send from `candidate`.
    fn switch_from(&self, current: SocketAddr, candidate: &Sender) -> Switch {
        if candidate.local_addr() == current {
            return Switch::SameAddress;
        }
        self.migration_switch()
    }

    /// The active-migration rules of RFC 9000 §9 for this connection's role and state.
    fn migration_switch(&self) -> Switch {
        if self.inner.side().is_server() {
            return Switch::Never;
        }
        if !self.inner.handshake_confirmed() {
            return Switch::Later;
        }
        if !self.inner.may_migrate_actively() {
            return Switch::Never;
        }
        if self.inner.can_migrate_locally() {
            Switch::Now
        } else {
            Switch::Later
        }
    }

    /// The local socket failed and this connection has no address it may send from any more.
    fn lose_path(&mut self, shared: &Shared) {
        let reason = rama_quic_proto::TransportError::INTERNAL_ERROR(
            "QUIC local socket failed and this connection may not migrate now",
        )
        .with_cause(io::Error::new(
            io::ErrorKind::NotConnected,
            "the socket this connection sends from is unusable",
        ));
        self.terminate(reason.into(), shared);
    }

    /// Used to wake up all blocked futures when the connection becomes closed for any reason
    fn terminate(&mut self, reason: ConnectionError, shared: &Shared) {
        // Driver and socket failures can end a connection without its closing path.
        self.inner.cancel_pending_callbacks();
        #[cfg(feature = "dial9")]
        self.dial9.finish(
            &self.inner,
            Some(&reason),
            self.connected,
            self.send_failures,
            self.oversized_sends,
        );
        #[cfg(feature = "opentelemetry")]
        self.finish_metrics(Some(&reason));
        let reason = self.error.get_or_insert(reason).clone();
        // A handshake that ends here leaves the attempts in progress.
        self.admission = None;
        // Whatever was waiting to be sent is never going out, and holding it would pin the
        // sender's state for a descriptor nobody will offer again. What waits on a handle kept
        // aside is accounted as it is given up: a prefix that left counts either way.
        self.buffered_transmit = None;
        self.deferred = None;
        self.give_up_aside();
        if let Some(x) = self.on_handshake_data.take() {
            let _sent = x.send(());
        }
        wake_all(&mut self.blocked_writers);
        wake_all(&mut self.blocked_readers);
        shared.stream_budget_available[Dir::Uni as usize].notify_waiters();
        shared.stream_budget_available[Dir::Bi as usize].notify_waiters();
        shared.stream_incoming[Dir::Uni as usize].notify_waiters();
        shared.stream_incoming[Dir::Bi as usize].notify_waiters();
        shared.datagram_received.notify_waiters();
        shared.datagrams_unblocked.notify_waiters();
        if let Some(x) = self.on_connected.take() {
            let _sent = x.send(Err(reason));
        }
        shared.handshake_confirmed.notify_waiters();
        wake_all_notify(&mut self.stopped);
        shared.closed.notify_waiters();
        // Admission learns of the close with the next budget signal, sent
        // outside the state lock.
        for pending in &mut self.stream_budget_changed {
            pending.merge(BudgetChange::OTHER);
        }
    }

    fn close(&mut self, error_code: VarInt, reason: Bytes, shared: &Shared) {
        self.inner.close(now(), error_code, reason);
        self.terminate(ConnectionError::LocallyClosed, shared);
        self.wake();
    }

    /// Close for a reason other than the application's explicit request
    pub(crate) fn implicit_close(&mut self, shared: &Shared) {
        self.close(0u32.into(), Bytes::new(), shared);
    }

    /// The datagram gates to ask before sending `len` bytes, once the send passed every other
    /// check; `None` without gates, so the caller sends at once.
    pub(crate) fn datagram_send_gates(
        &mut self,
        len: usize,
    ) -> Result<Option<ConnectionDatagramGates>, SendDatagramError> {
        let Some(gates) = self.datagram_gates.clone() else {
            return Ok(None);
        };
        if let Some(ref x) = self.error {
            return Err(SendDatagramError::ConnectionLost(x.clone()));
        }
        match self.inner.datagrams().check_send(len) {
            Ok(_) => Ok(Some(gates)),
            Err(ProtoSendDatagramError::UnsupportedByPeer) => {
                Err(SendDatagramError::UnsupportedByPeer)
            }
            Err(ProtoSendDatagramError::Disabled) => Err(SendDatagramError::Disabled),
            Err(ProtoSendDatagramError::TooLarge | ProtoSendDatagramError::Blocked(_)) => {
                Err(SendDatagramError::TooLarge)
            }
        }
    }

    /// Queue a datagram, dropping the oldest queued ones for space when `drop_oldest`.
    #[expect(
        clippy::unreachable,
        reason = "the engine never returns Blocked when its drop-oldest send policy is enabled"
    )]
    pub(crate) fn send_datagram(
        &mut self,
        data: Bytes,
        drop_oldest: bool,
    ) -> Result<(), SendDatagramError> {
        if let Some(ref x) = self.error {
            return Err(SendDatagramError::ConnectionLost(x.clone()));
        }
        match self.inner.datagrams().send(data, drop_oldest) {
            Ok(()) => {
                self.wake();
                Ok(())
            }
            Err(e) => Err(match e {
                ProtoSendDatagramError::Blocked(..) if drop_oldest => unreachable!(),
                ProtoSendDatagramError::Blocked(..) => SendDatagramError::Blocked,
                ProtoSendDatagramError::UnsupportedByPeer => SendDatagramError::UnsupportedByPeer,
                ProtoSendDatagramError::Disabled => SendDatagramError::Disabled,
                ProtoSendDatagramError::TooLarge => SendDatagramError::TooLarge,
            }),
        }
    }

    pub(crate) fn check_0rtt(&self) -> Result<(), ()> {
        if self.inner.is_handshaking()
            || self.inner.accepted_0rtt()
            || self.inner.side().is_server()
        {
            Ok(())
        } else {
            Err(())
        }
    }
}

impl Drop for State {
    fn drop(&mut self) {
        #[cfg(feature = "dial9")]
        self.dial9.finish(
            &self.inner,
            self.error.as_ref(),
            self.connected,
            self.send_failures,
            self.oversized_sends,
        );
        #[cfg(feature = "opentelemetry")]
        self.finish_metrics(None);
        // The driver's Drop already delivered Drained; this only covers a state that was never
        // driven. No lock is held here, so delivering to the endpoint is safe.
        if !self.endpoint_drained {
            let link = self.endpoint.clone();
            link.deliver(self.take_endpoint_events_with_drained());
        }
    }
}

impl fmt::Debug for State {
    fn fmt(&self, f: &mut fmt::Formatter) -> fmt::Result {
        f.debug_struct("State").field("inner", &self.inner).finish()
    }
}

fn wake_stream(stream_id: StreamId, wakers: &mut FxHashMap<StreamId, Waker>) {
    if let Some(waker) = wakers.remove(&stream_id) {
        waker.wake();
    }
}

fn wake_all(wakers: &mut FxHashMap<StreamId, Waker>) {
    wakers.drain().for_each(|(_, waker)| waker.wake())
}

fn wake_stream_notify(
    stream_id: StreamId,
    wakers: &FxHashMap<StreamId, super::send_stream::StoppedNotify>,
) {
    if let Some(notify) = wakers.get(&stream_id) {
        notify.events.notify.notify_waiters()
    }
}

fn wake_all_notify(wakers: &mut FxHashMap<StreamId, super::send_stream::StoppedNotify>) {
    wakers
        .drain()
        .for_each(|(_, notify)| notify.events.notify.notify_waiters())
}

/// Errors that can arise when sending a datagram
#[derive(Debug, Clone, Eq, PartialEq)]
pub enum SendDatagramError {
    /// The peer does not support receiving datagram frames
    UnsupportedByPeer,
    /// Datagram support is disabled locally
    Disabled,
    /// The datagram is larger than the connection can currently accommodate
    ///
    /// Exceeds the path MTU minus overhead, the peer's advertised limit, or the configured send
    /// buffer budget including queue-entry overhead.
    TooLarge,
    /// The send buffer is full; only returned by the `try_send_datagram` methods
    Blocked,
    /// The stream the datagram is bound to can no longer send; see
    /// [`StreamHandle::send_datagram`](crate::StreamHandle::send_datagram)
    StreamClosed,
    /// The connection was lost
    ConnectionLost(ConnectionError),
}

impl core::fmt::Display for SendDatagramError {
    fn fmt(&self, f: &mut core::fmt::Formatter<'_>) -> core::fmt::Result {
        match self {
            Self::UnsupportedByPeer => f.write_str("datagrams not supported by peer"),
            Self::Disabled => f.write_str("datagram support disabled"),
            Self::TooLarge => f.write_str("datagram too large"),
            Self::Blocked => f.write_str("datagram send buffer full"),
            Self::StreamClosed => f.write_str("datagram stream closed for sending"),
            Self::ConnectionLost(_) => f.write_str("connection lost"),
        }
    }
}

impl std::error::Error for SendDatagramError {
    fn source(&self) -> Option<&(dyn std::error::Error + 'static)> {
        match self {
            Self::ConnectionLost(inner) => Some(inner),
            _ => None,
        }
    }
}

impl From<ConnectionError> for SendDatagramError {
    fn from(value: ConnectionError) -> Self {
        Self::ConnectionLost(value)
    }
}

/// The maximum amount of datagrams which will be produced in a single `drive_transmit` call
///
/// This limits the amount of CPU resources consumed by datagram generation,
/// and allows other tasks (like receiving ACKs) to run in between.
pub(crate) const MAX_TRANSMIT_DATAGRAMS: usize = 20;

/// How many descriptors' worth of bytes a connection keeps at once: the one on the handle it
/// sends from, the one on the handle kept aside, the one waiting for a station, and the buffer
/// the engine writes the next one into. See [`Held`].
#[cfg(all(
    test,
    any(
        feature = "boring",
        all(feature = "rustls", any(feature = "aws-lc", feature = "ring"))
    )
))]
pub(crate) const RETAINED_DESCRIPTORS: usize = 4;

/// The maximum amount of datagrams that are sent in a single transmit
///
/// This can be lower than the maximum platform capabilities, to avoid excessive
/// memory allocations when calling `poll_transmit()`. Benchmarks have shown
/// that numbers around 10 are a good compromise.
pub(crate) const MAX_TRANSMIT_SEGMENTS: usize = 10;

/// Whether `transmit` is an MTU discovery probe: one datagram larger than the path MTU
/// confirmed so far.
fn is_mtu_probe(transmit: &crate::proto::Transmit, confirmed_mtu: u16) -> bool {
    transmit.segment_size.is_none() && transmit.size > usize::from(confirmed_mtu)
}

#[cfg(test)]
#[cfg(any(
    feature = "boring",
    all(feature = "rustls", any(feature = "aws-lc", feature = "ring"))
))]
mod tests {
    use std::num::NonZeroUsize;

    use super::*;
    use crate::{driver::Instant, proto::ReceiveQueueLimits};

    /// A single datagram above the confirmed MTU is a probe; a batch never is.
    #[test]
    fn only_a_single_datagram_above_the_confirmed_mtu_is_an_mtu_probe() {
        let transmit = |size, segment_size| crate::proto::Transmit {
            destination: SocketAddr::from(([127, 0, 0, 1], 443)),
            ecn: None,
            size,
            segment_size,
            local: None,
            cid_used: None,
        };
        assert!(is_mtu_probe(&transmit(1452, None), 1200));
        assert!(!is_mtu_probe(&transmit(1200, None), 1200));
        assert!(!is_mtu_probe(&transmit(1000, None), 1200));
        assert!(!is_mtu_probe(
            &transmit(2400, NonZeroUsize::new(1200)),
            1200
        ));
    }
    use std::{assert_matches, error::Error as _, io::IoSliceMut};

    use rama_net::address::SocketAddress;
    use rama_udp::{
        DatagramCapabilities, DatagramError, DatagramMetadata, DatagramSender, DatagramSocket,
    };
    use rama_utils::{octets, reactive::ChangeWaiter};

    #[derive(Debug, Clone, Copy)]
    enum Failure {
        /// A destination-local refusal; the connection must keep running.
        Datagram,
        /// An invalid descriptor; the connection must terminate.
        Descriptor,
    }

    #[derive(Debug)]
    struct FailingSocket(Arc<AtomicUsize>, Failure);
    impl rama_net::stream::Socket for FailingSocket {
        fn local_addr(&self) -> io::Result<SocketAddress> {
            Ok(([127, 0, 0, 1], 1234).into())
        }
        fn peer_addr(&self) -> io::Result<SocketAddress> {
            Err(io::ErrorKind::NotConnected.into())
        }
    }
    impl DatagramSocket for FailingSocket {
        type Sender = FailingSender;
        fn create_sender(&self) -> Self::Sender {
            self.0.fetch_add(1, Ordering::Relaxed);
            FailingSender(self.0.clone(), self.1)
        }
        fn poll_recv(
            &mut self,
            _: &mut Context<'_>,
            _: &mut [IoSliceMut<'_>],
            _: &mut [DatagramMetadata],
        ) -> Poll<Result<usize, DatagramError>> {
            Poll::Pending
        }
        fn capabilities(&self) -> DatagramCapabilities {
            DatagramCapabilities::portable()
        }
    }
    #[derive(Debug)]
    struct FailingSender(Arc<AtomicUsize>, Failure);
    impl Drop for FailingSender {
        fn drop(&mut self) {
            self.0.fetch_sub(1, Ordering::Relaxed);
        }
    }
    impl DatagramSender for FailingSender {
        fn poll_send(
            &mut self,
            _: &mut Context<'_>,
            _: &rama_udp::SendDatagram<'_>,
        ) -> Poll<Result<(), DatagramError>> {
            Poll::Ready(Err(match self.1 {
                Failure::Datagram => {
                    io::Error::new(io::ErrorKind::PermissionDenied, "injected UDP failure").into()
                }
                Failure::Descriptor => DatagramError::TooManySegments { count: 2, max: 1 },
            }))
        }
        fn capabilities(&self) -> DatagramCapabilities {
            DatagramCapabilities::portable()
        }
    }

    /// The packet sender is returned too: dropping it tells the driver the endpoint is gone.
    fn isolated_connection(
        failure: Failure,
    ) -> (
        Connecting,
        Connection,
        Arc<AtomicUsize>,
        crate::driver::queue::BoundedSender<QueuedPacket>,
    ) {
        let (connecting, driver, alive, packets, _endpoint) = unspawned_connection(
            failure,
            4,
            PacketBudget::new(ReceiveQueueLimits::new(4, octets::kib(64)).unwrap()),
            None,
        );
        driver.spawn(crate::driver::lifecycle::Lifecycle::default().reserve());
        let connection = Connection(connecting.conn.as_ref().unwrap().clone());
        (connecting, connection, alive, packets)
    }

    /// Keep the real engine and its endpoint available without scheduling the connection driver.
    fn unpolled_connection() -> (Connection, ConnectionDriver) {
        let (connecting, driver, _alive, _packets, _endpoint) = unspawned_connection(
            Failure::Datagram,
            4,
            PacketBudget::new(ReceiveQueueLimits::new(4, octets::kib(64)).unwrap()),
            None,
        );
        (
            Connection(connecting.conn.as_ref().unwrap().clone()),
            driver,
        )
    }

    /// Records what a signal tells its listeners.
    #[derive(Default)]
    struct Changes(Mutex<Vec<Change>>);

    impl ChangeListener for Changes {
        fn changed(&self, change: Change) {
            self.0.lock().push(change);
        }
    }

    #[test]
    fn returned_stream_credit_is_reported_in_units() {
        let shared = Shared::default();
        let listener = Arc::new(Changes::default());
        shared.stream_budget_changes[Dir::Bi as usize]
            .subscribe(Arc::downgrade(&listener) as Weak<dyn ChangeListener>);
        let told = |changed: BudgetChange| {
            shared.notify_stream_budget([changed, BudgetChange::default()]);
            std::mem::take(&mut *listener.0.lock())
        };
        let freed = |freed| BudgetChange {
            freed,
            other: false,
        };
        assert_eq!(
            told(freed(2)),
            [Change::Freed, Change::Freed],
            "one per stream"
        );
        assert_eq!(
            told(BudgetChange {
                freed: 3,
                other: true
            }),
            [Change::Other]
        );
        assert_eq!(
            told(freed(FREED_STREAMS_MAX + 1)),
            [Change::Other],
            "too many to count out"
        );
        assert!(told(BudgetChange::default()).is_empty());
    }

    /// Budget subscribers learn of a close that no driver poll follows.
    #[tokio::test]
    async fn closing_without_a_driver_poll_wakes_budget_subscribers() {
        for drop_driver in [true, false] {
            let (connection, driver) = unpolled_connection();
            let waiter = ChangeWaiter::new();
            connection.stream_budget_subscribe(Dir::Bi, waiter.listener());
            if drop_driver {
                drop(driver);
            } else {
                connection.close(0u32, b"closed");
            }
            assert!(connection.close_reason().is_some());
            tokio::time::timeout(Duration::from_secs(5), waiter.wait())
                .await
                .expect("the close is signalled to budget subscribers");
        }
    }

    fn unspawned_connection(
        failure: Failure,
        packet_limit: usize,
        receive_queue: PacketBudget,
        sink: Option<Arc<dyn crate::qlog::QlogSink>>,
    ) -> (
        Connecting,
        ConnectionDriver,
        Arc<AtomicUsize>,
        crate::driver::queue::BoundedSender<QueuedPacket>,
        crate::proto::Endpoint,
    ) {
        let mut config = crate::test_helpers::client(&crate::test_helpers::identity());
        if let Some(sink) = sink {
            config.transport =
                Arc::new(crate::proto::TransportConfig::default().with_qlog_sink(sink));
        }
        let mut endpoint = crate::proto::Endpoint::new(
            Arc::new(crate::proto::EndpointConfig::try_with_rand_key().unwrap()),
            None,
            false,
            None,
        );
        let (handle, engine) = endpoint
            .connect(
                Instant::now(),
                config,
                ([127, 0, 0, 2], 443).into(),
                "localhost",
            )
            .unwrap();
        let alive = Arc::new(AtomicUsize::new(0));
        let sender = crate::driver::udp::Socket::new(FailingSocket(alive.clone(), failure))
            .unwrap()
            .create_sender();
        let (packets, receiver) = crate::driver::queue::bounded_queue(packet_limit);
        let (connecting, driver) = Connecting::new(
            handle,
            engine,
            EndpointLink::detached(handle),
            receiver,
            sender,
            receive_queue,
            None,
        );
        (connecting, driver, alive, packets, endpoint)
    }

    /// Inspect actual packet processing through the engine's synchronous qlog callback.
    /// Distinct wire lengths identify FIFO order without adding an engine or driver hook.
    struct ReceiveObserver {
        endpoint: PacketBudget,
        connection: PacketBudget,
        packets: std::sync::OnceLock<Weak<crate::driver::queue::BoundedSender<QueuedPacket>>>,
        total: usize,
        seen: AtomicUsize,
        panic_on: Option<usize>,
    }

    impl ReceiveObserver {
        fn assert_charged(&self, first: usize) {
            let bytes = (first..self.total)
                .map(|index| crate::driver::queue::PACKET_OVERHEAD + 32 + index)
                .sum::<usize>();
            for budget in [&self.endpoint, &self.connection] {
                let stats = budget.stats();
                assert_eq!(stats.queued_datagrams, self.total - first);
                assert_eq!(stats.queued_bytes, bytes);
                assert_eq!(stats.dropped_datagrams, 0);
            }
        }
    }

    impl crate::qlog::QlogSink for ReceiveObserver {
        fn emit_named(&self, _event: &crate::qlog::NamedQlogEventView<'_>) {}

        fn accepts_named(&self, _schema: &crate::qlog::EventSchema) -> bool {
            false
        }

        fn emit(&self, event: &crate::qlog::QlogEventView<'_>) -> bool {
            use crate::qlog::event::{DropEvent, EventView, drops::DropReason};
            // Each packet is either held until its keys are available or, once the hold is
            // full, dropped for lack of them.
            let raw = match &event.fields.event {
                EventView::Drop(DropEvent::PacketBuffered(packet)) => packet.raw,
                EventView::Drop(DropEvent::PacketDropped(packet)) => {
                    assert_matches!(packet.trigger, DropReason::KeyUnavailable);
                    packet.raw
                }
                _ => return true,
            };
            let index = self.seen.fetch_add(1, Ordering::Relaxed);
            assert_eq!(raw.unwrap().length, 32 + index, "packet FIFO order");
            // The current event and every unprocessed packet in the queue remain charged.
            // This runs inside handle_event, so it detects release after dequeue but before
            // processing, which a receiver-only test cannot see.
            self.assert_charged(index);
            if let Some(packets) = self.packets.get().and_then(Weak::upgrade) {
                assert!(packets.is_unlocked(), "event callback holds the queue lock");
            }
            assert_ne!(
                self.panic_on,
                Some(index),
                "injected receive callback panic"
            );
            true
        }
    }

    struct ReceiveFixture {
        _connecting: Connecting,
        driver: ConnectionDriver,
        packets: Option<Arc<crate::driver::queue::BoundedSender<QueuedPacket>>>,
        observer: Arc<ReceiveObserver>,
    }

    impl ReceiveFixture {
        fn new(total: usize, panic_on: Option<usize>) -> Self {
            let limits = ReceiveQueueLimits::new(total, octets::mib(1)).unwrap();
            let observer = Arc::new(ReceiveObserver {
                endpoint: PacketBudget::new(limits),
                connection: PacketBudget::new(limits),
                packets: std::sync::OnceLock::new(),
                total,
                seen: AtomicUsize::new(0),
                panic_on,
            });
            let (connecting, driver, _alive, packets, mut endpoint) = unspawned_connection(
                Failure::Datagram,
                total,
                observer.connection.clone(),
                Some(observer.clone()),
            );
            let packets = Arc::new(packets);
            observer.packets.set(Arc::downgrade(&packets)).unwrap();
            let cid = driver.conn.state.lock().inner.initial_local_id();
            for index in 0..total {
                // These routed short headers reach the real connection but cannot decrypt yet:
                // the unspawned client has not obtained application packet-protection keys.
                let mut wire = vec![0; 32 + index];
                wire[0] = 0x40;
                wire[1..1 + cid.len()].copy_from_slice(&cid);
                let event = endpoint.handle(
                    now(),
                    ([127, 0, 0, 2], 443).into(),
                    None,
                    None,
                    wire.as_slice().into(),
                    &mut Vec::new(),
                );
                let Some(crate::proto::DatagramEvent::ConnectionEvent(_, event)) = event else {
                    panic!("test datagram must route to the connection");
                };
                let permit = observer
                    .endpoint
                    .reserve(wire.len())
                    .unwrap()
                    .for_connection(&observer.connection)
                    .unwrap();
                packets
                    .send(QueuedPacket {
                        event,
                        _permit: permit,
                    })
                    .unwrap();
            }
            Self {
                _connecting: connecting,
                driver,
                packets: Some(packets),
                observer,
            }
        }

        fn process(&self) -> Result<bool, ConnectionError> {
            self.driver
                .conn
                .state
                .lock()
                .process_packets(&mut Context::from_waker(Waker::noop()))
        }
    }

    #[tokio::test]
    async fn receive_processing_obeys_the_exact_poll_allowance_and_drains_before_eof() {
        // Literal boundaries deliberately pin the production fairness contract to 160.
        for total in [159, 160, 161] {
            for sender_dropped in [false, true] {
                let mut fixture = ReceiveFixture::new(total, None);
                if sender_dropped {
                    drop(fixture.packets.take());
                }
                let result = fixture.process();
                if total >= 160 {
                    assert_matches!(result, Ok(true), "the allowance requests another poll");
                } else if sender_dropped {
                    assert_matches!(result, Err(ConnectionError::TransportError(_)));
                } else {
                    assert_matches!(result, Ok(false), "a live drained queue waits");
                }
                assert_eq!(
                    fixture.observer.seen.load(Ordering::Relaxed),
                    total.min(160)
                );
                fixture.observer.assert_charged(total.min(160));

                let result = fixture.process();
                if sender_dropped {
                    assert_matches!(result, Err(ConnectionError::TransportError(_)));
                } else {
                    assert_matches!(result, Ok(false));
                }
                assert_eq!(fixture.observer.seen.load(Ordering::Relaxed), total);
                fixture.observer.assert_charged(total);
            }
        }
    }

    #[tokio::test]
    async fn receive_callback_panic_releases_the_current_packet_but_preserves_queued_charges() {
        let fixture = ReceiveFixture::new(17, Some(1));
        let panic = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| fixture.process()))
            .expect_err("the second packet callback must panic");
        let message = panic
            .downcast_ref::<String>()
            .map(String::as_str)
            .or_else(|| panic.downcast_ref::<&str>().copied())
            .unwrap();
        assert!(
            message.contains("injected receive callback panic"),
            "{message}"
        );
        assert_eq!(fixture.observer.seen.load(Ordering::Relaxed), 2);
        // The completed first packet and the second callback's current permit release.
        // The other fifteen packets stay queued and charged until the receiver closes.
        fixture.observer.assert_charged(2);
        fixture.driver.conn.state.lock().packets.close();
        fixture.observer.assert_charged(17);
    }

    #[tokio::test]
    async fn descriptor_failures_terminate_wake_retained_handles_and_release_the_sender() {
        let (connecting, connection, alive, _packets) = isolated_connection(Failure::Descriptor);
        let streams = connection.clone();
        let datagrams = connection.clone();
        let (connected, closed, accepted, datagram) =
            tokio::time::timeout(Duration::from_secs(1), async {
                tokio::join!(
                    connecting,
                    connection.closed(),
                    streams.accept_uni(),
                    datagrams.read_datagram()
                )
            })
            .await
            .expect("all waiters must wake after a fatal send failure");
        connected.unwrap_err();
        accepted.unwrap_err();
        datagram.unwrap_err();
        let source = closed
            .source()
            .unwrap()
            .source()
            .unwrap()
            .downcast_ref::<io::Error>()
            .unwrap();
        assert_eq!(
            source.to_string(),
            DatagramError::TooManySegments { count: 2, max: 1 }.to_string()
        );
        assert_eq!(
            alive.load(Ordering::Relaxed),
            0,
            "retained connection handles must not retain the send socket"
        );
        assert!(connection.close_reason().is_some());
        assert_eq!(connection.0.shared.ref_count.load(Ordering::Relaxed), 3);
        let clone = connection.clone();
        drop(clone);
        assert_eq!(connection.0.shared.ref_count.load(Ordering::Relaxed), 3);
    }

    #[tokio::test]
    async fn destination_failures_are_counted_and_the_connection_keeps_running() {
        let (connecting, connection, alive, _packets) = isolated_connection(Failure::Datagram);
        tokio::time::timeout(Duration::from_secs(3), async {
            while connection.driver_stats().send_failures < 2 {
                tokio::time::sleep(Duration::from_millis(5)).await;
            }
        })
        .await
        .expect("retransmissions keep hitting the refusing socket");
        assert!(
            connection.close_reason().is_none(),
            "a destination-local refusal must not terminate the connection"
        );
        assert_eq!(
            alive.load(Ordering::Relaxed),
            1,
            "the sender stays owned by the driver"
        );
        assert_eq!(connection.driver_stats().oversized_sends, 0);
        connection.close(0u32, b"done");
        assert_matches!(
            tokio::time::timeout(Duration::from_secs(1), connecting)
                .await
                .unwrap(),
            Err(ConnectionError::LocallyClosed),
        );
    }
}
