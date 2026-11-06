//! What both interoperability test files need: the identities, the configurations for each
//! stack, and the bounded waiting that keeps a hang from stalling a run.
#![allow(
    dead_code,
    reason = "shared support for several integration test binaries, each using part of it"
)]

pub mod quinn_h3;

use interop_common::backend::VerifyBackend as _;
use std::{
    io::{self, IoSliceMut},
    net::{Ipv4Addr, SocketAddr},
    pin::Pin,
    sync::{
        Arc,
        atomic::{AtomicUsize, Ordering},
    },
    task::{Context, Poll, Waker, ready},
    time::Duration,
};

use quinn::{
    AsyncUdpSocket, UdpPoller,
    udp::{RecvMeta, Transmit},
};

use parking_lot::Mutex;
use rama::{
    crypto::{
        cert::{CertificateIdentity, CertificateSubject, LeafCertRequest, SelfSignedCaConfig},
        pki_types::CertificateDer,
    },
    net::tls::ApplicationProtocol,
    quic::{ClientConfig, ServerConfig},
    tls::{
        client::TlsClientConfig,
        server::{GeneratedServerAuthConfig, ServerAuthData, TlsServerConfig},
    },
    utils::{collections::smallvec::smallvec, octets},
};
use sha2::{Digest, Sha256};

use interop_common::{Chunk, Deadline, Received};

/// The protocol every scenario negotiates, shared with the other peer projects.
pub use interop_common::ALPN;
/// Every await in these tests is bounded: a hang has to fail the test, not stall it.
pub const LIMIT: Duration = Duration::from_secs(20);

/// Await one step of a scenario, naming it so a timeout says which step stalled.
pub async fn step<F: std::future::Future>(what: &str, future: F) -> F::Output {
    match tokio::time::timeout(LIMIT, future).await {
        Ok(value) => value,
        Err(_) => panic!("{what}: not within {LIMIT:?}"),
    }
}

/// A spawned peer. The guard owns its handle for as long as it exists, including while a wait on
/// it is in progress, so a wait that is itself cancelled leaves the task with the guard. Dropping
/// the guard aborts the task; it does not wait for the task to unwind.
pub struct Peer(Option<tokio::task::JoinHandle<()>>);

impl Peer {
    pub fn spawn(task: impl std::future::Future<Output = ()> + Send + 'static) -> Self {
        Self(Some(tokio::spawn(task)))
    }

    pub async fn join(mut self, what: &str) {
        if let Err(reason) = self.try_join_within(LIMIT).await {
            panic!("{what}: {reason}");
        }
    }

    /// Wait for the task, with the handle staying in the guard throughout. Awaiting it by value
    /// would drop it on a timeout, leaving the task detached; taking it out first would do the
    /// same if this wait were cancelled.
    pub async fn try_join_within(&mut self, limit: Duration) -> Result<(), String> {
        let handle = self.0.as_mut().expect("waited on once");
        let outcome = match tokio::time::timeout(limit, handle).await {
            Ok(Ok(())) => Ok(()),
            Ok(Err(error)) if error.is_panic() => Err(format!("panicked: {error}")),
            Ok(Err(error)) => Err(format!("ended: {error}")),
            Err(_) => {
                let handle = self.0.as_mut().expect("still here");
                handle.abort();
                let _ = handle.await;
                Err(format!("not within {limit:?}"))
            }
        };
        // Whatever happened, the task is finished and the guard has nothing left to abort.
        self.0 = None;
        outcome
    }
}

impl Drop for Peer {
    fn drop(&mut self) {
        if let Some(handle) = self.0.take() {
            handle.abort();
        }
    }
}

pub fn localhost() -> SocketAddr {
    SocketAddr::new(Ipv4Addr::LOCALHOST.into(), 0)
}

pub fn digest(payload: &[u8]) -> [u8; 32] {
    Sha256::digest(payload).into()
}

pub fn payload(seed: u8, len: usize) -> Vec<u8> {
    (0..len).map(|i| (i as u8) ^ seed).collect()
}

/// One generated identity, used by whichever side is the server and trusted by the other.
pub fn identity() -> ServerAuthData {
    ServerAuthData::new_generated(GeneratedServerAuthConfig::default())
        .expect("an identity is generated")
}

/// Identity issued by a certificate authority with a distinct name, so a peer trusting another
/// anchor finds no issuer for it.
pub fn identity_from_a_stranger(issuer: &str) -> ServerAuthData {
    ServerAuthData::new_generated(GeneratedServerAuthConfig::GeneratedCa {
        ca: SelfSignedCaConfig {
            subject: CertificateSubject {
                organisation_name: Some(issuer.to_owned()),
                common_name: Some(issuer.to_owned()),
            },
            ..Default::default()
        },
        leaf: LeafCertRequest::default(),
    })
    .expect("an identity is generated")
}

/// An identity valid for the loopback address, so a client may name the address it connects to.
pub fn address_identity() -> ServerAuthData {
    ServerAuthData::new_self_signed_leaf(LeafCertRequest::new(CertificateIdentity::Ip(
        Ipv4Addr::LOCALHOST.into(),
    )))
    .expect("an identity is generated")
}

pub fn rama_server_config(auth: &ServerAuthData) -> ServerConfig {
    rama_server_config_with_alpn(auth, ALPN)
}

pub fn rama_server_config_with_alpn(auth: &ServerAuthData, alpn: &[u8]) -> ServerConfig {
    let tls = TlsServerConfig::new()
        .with_alpn(smallvec![ApplicationProtocol::from(alpn)])
        .with_server_auth(auth.clone())
        .verify_backend();
    interop_common::backend::server_tls_provider()
        .server_config(&tls, interop_common::backend::options())
        .expect("the server config is built")
}

pub fn rama_client_config(anchor: CertificateDer<'static>) -> ClientConfig {
    rama_client_config_with_alpn(anchor, ALPN)
}

pub fn rama_client_config_with_alpn(anchor: CertificateDer<'static>, alpn: &[u8]) -> ClientConfig {
    let tls = TlsClientConfig::new()
        .with_alpn(smallvec![ApplicationProtocol::from(alpn)])
        .try_with_server_trust_anchors([anchor])
        .expect("the trust anchor is accepted")
        .verify_backend();
    interop_common::backend::tls_provider()
        .client_config(&tls, interop_common::backend::options())
        .expect("the client config is built")
}

pub fn quinn_server_config(auth: &ServerAuthData) -> quinn::ServerConfig {
    quinn_server_config_with_alpn(auth, ALPN)
}

pub fn quinn_server_config_with_alpn(auth: &ServerAuthData, alpn: &[u8]) -> quinn::ServerConfig {
    let mut tls = rustls::ServerConfig::builder_with_provider(Arc::new(
        rustls::crypto::ring::default_provider(),
    ))
    .with_protocol_versions(&[&rustls::version::TLS13])
    .expect("TLS 1.3 is supported")
    .with_no_client_auth()
    .with_single_cert(auth.cert_chain.clone(), auth.private_key.clone_key())
    .expect("the identity is accepted");
    tls.alpn_protocols = vec![alpn.to_vec()];
    quinn::ServerConfig::with_crypto(Arc::new(
        quinn::crypto::rustls::QuicServerConfig::try_from(tls).expect("a QUIC server config"),
    ))
}

pub fn quinn_client_config(anchor: CertificateDer<'static>) -> quinn::ClientConfig {
    quinn_client_config_with_alpn(anchor, ALPN)
}

pub fn quinn_client_config_with_alpn(
    anchor: CertificateDer<'static>,
    alpn: &[u8],
) -> quinn::ClientConfig {
    let mut roots = rustls::RootCertStore::empty();
    roots.add(anchor).expect("the anchor is accepted");
    let mut tls = rustls::ClientConfig::builder_with_provider(Arc::new(
        rustls::crypto::ring::default_provider(),
    ))
    .with_protocol_versions(&[&rustls::version::TLS13])
    .expect("TLS 1.3 is supported")
    .with_root_certificates(roots)
    .with_no_client_auth();
    tls.alpn_protocols = vec![alpn.to_vec()];
    quinn::ClientConfig::new(Arc::new(
        quinn::crypto::rustls::QuicClientConfig::try_from(tls).expect("a QUIC client config"),
    ))
}

/// A socket that counts the datagrams through it. Everything else is the socket it wraps.
#[derive(Debug)]
pub struct Counted {
    inner: Arc<dyn AsyncUdpSocket>,
    sent: AtomicUsize,
    received: AtomicUsize,
    polls: AtomicUsize,
}

impl Counted {
    #[must_use]
    pub fn around(inner: Arc<dyn AsyncUdpSocket>) -> Arc<Self> {
        Arc::new(Self {
            inner,
            sent: AtomicUsize::new(0),
            received: AtomicUsize::new(0),
            polls: AtomicUsize::new(0),
        })
    }

    /// Datagrams submitted to this socket for sending, which is not delivery confirmed on
    /// the wire.
    pub fn sent(&self) -> usize {
        self.sent.load(Ordering::Relaxed)
    }

    /// Datagrams this socket delivered.
    pub fn received(&self) -> usize {
        self.received.load(Ordering::Relaxed)
    }

    /// Reads that reached this socket, whether or not one delivered anything. What tells a
    /// read that was passed on from one that was held above it.
    pub fn polls(&self) -> usize {
        self.polls.load(Ordering::Relaxed)
    }
}

impl AsyncUdpSocket for Counted {
    fn create_io_poller(self: Arc<Self>) -> Pin<Box<dyn UdpPoller>> {
        self.inner.clone().create_io_poller()
    }

    fn try_send(&self, transmit: &Transmit) -> io::Result<()> {
        self.inner.try_send(transmit)?;
        // One `Transmit` carries several datagrams when the sender segments it.
        let datagrams = transmit
            .segment_size
            .map_or(1, |size| transmit.contents.len().div_ceil(size));
        self.sent.fetch_add(datagrams, Ordering::Relaxed);
        Ok(())
    }

    fn poll_recv(
        &self,
        cx: &mut Context,
        bufs: &mut [IoSliceMut<'_>],
        meta: &mut [RecvMeta],
    ) -> Poll<io::Result<usize>> {
        self.polls.fetch_add(1, Ordering::Relaxed);
        let taken = ready!(self.inner.poll_recv(cx, bufs, meta))?;
        let datagrams: usize = meta[..taken]
            .iter()
            .map(|it| it.len.div_ceil(it.stride.max(1)))
            .sum();
        self.received.fetch_add(datagrams, Ordering::Relaxed);
        Poll::Ready(Ok(taken))
    }

    fn local_addr(&self) -> io::Result<SocketAddr> {
        self.inner.local_addr()
    }

    fn max_transmit_segments(&self) -> usize {
        self.inner.max_transmit_segments()
    }

    fn max_receive_segments(&self) -> usize {
        self.inner.max_receive_segments()
    }

    fn may_fragment(&self) -> bool {
        self.inner.may_fragment()
    }
}

/// The most one of these reads in a call, so a peer sending more fails rather than filling
/// memory.
const READ_CAP: usize = octets::mib(1);

/// One exchange over Quinn, from the opening side, checked by length and digest on the way
/// back, and saying what came back.
pub async fn exchange(
    what: &str,
    deadline: Deadline,
    connection: &quinn::Connection,
    payload: Chunk,
) -> Received {
    let (mut send, mut recv) = deadline
        .wait(what, connection.open_bi())
        .await
        .expect("a bi stream");
    deadline
        .wait(what, send.write_all(&payload.bytes()))
        .await
        .expect("the payload is written");
    send.finish().expect("the stream ends");
    let back = deadline
        .wait(what, recv.read_to_end(READ_CAP))
        .await
        .expect("the answer completes");
    let back = Received::Bytes(back);
    back.check(what, "exchange", payload);
    back
}

/// The same exchange from the answering side, saying what it carried.
pub async fn answer(
    what: &str,
    deadline: Deadline,
    connection: &quinn::Connection,
    payload: Chunk,
) -> Received {
    let (mut send, mut recv) = deadline
        .wait(what, connection.accept_bi())
        .await
        .expect("the stream arrives");
    let got = deadline
        .wait(what, recv.read_to_end(READ_CAP))
        .await
        .expect("it completes");
    Received::Bytes(got.clone()).check(what, "exchange", payload);
    deadline
        .wait(what, send.write_all(&got))
        .await
        .expect("the answer is written");
    send.finish().expect("the answer ends");
    Received::Bytes(got)
}

/// Whether a socket is paused, and who to wake when it is let go. One lock over both: a
/// resume that read the flag separately could land between a read seeing it set and that read
/// registering, and the wake would go nowhere.
#[derive(Debug, Default)]
struct Paused {
    deaf: bool,
    waiting: Option<Waker>,
}

/// A socket that can be told to stop delivering what arrives, so the peer built on it stops
/// acknowledging and the other side's transport stalls rather than only its reads. Everything
/// else is the socket it wraps.
#[derive(Debug)]
pub struct Deaf {
    inner: Arc<dyn AsyncUdpSocket>,
    state: Mutex<Paused>,
}

impl Deaf {
    #[must_use]
    pub fn around(inner: Arc<dyn AsyncUdpSocket>) -> Arc<Self> {
        Arc::new(Self {
            inner,
            state: Mutex::new(Paused::default()),
        })
    }

    /// Stop delivering. What arrives stays in the kernel's buffer until this is lifted.
    pub fn stop_reading(&self) {
        self.state.lock().deaf = true;
    }

    /// Deliver again, waking whoever was waiting on a read. The waker is taken under the lock
    /// and woken outside it.
    pub fn read_again(&self) {
        let waiting = {
            let mut state = self.state.lock();
            state.deaf = false;
            state.waiting.take()
        };
        if let Some(waker) = waiting {
            waker.wake();
        }
    }

    /// Attempt a resume without waiting for an in-flight read's critical section.
    pub fn try_read_again(&self) -> bool {
        let waiting = {
            let Some(mut state) = self.state.try_lock() else {
                return false;
            };
            state.deaf = false;
            state.waiting.take()
        };
        if let Some(waker) = waiting {
            waker.wake();
        }
        true
    }

    /// Test seam immediately after observing a pause, before registering the reader.
    pub fn poll_recv_at_registration(
        &self,
        cx: &mut Context,
        bufs: &mut [IoSliceMut<'_>],
        meta: &mut [RecvMeta],
        before_register: impl FnOnce(),
    ) -> Poll<io::Result<usize>> {
        {
            let mut state = self.state.lock();
            if state.deaf {
                before_register();
                state.waiting = Some(cx.waker().clone());
                return Poll::Pending;
            }
        }
        self.inner.poll_recv(cx, bufs, meta)
    }
}

impl AsyncUdpSocket for Deaf {
    fn create_io_poller(self: Arc<Self>) -> Pin<Box<dyn UdpPoller>> {
        self.inner.clone().create_io_poller()
    }

    fn try_send(&self, transmit: &Transmit) -> io::Result<()> {
        self.inner.try_send(transmit)
    }

    fn poll_recv(
        &self,
        cx: &mut Context,
        bufs: &mut [IoSliceMut<'_>],
        meta: &mut [RecvMeta],
    ) -> Poll<io::Result<usize>> {
        self.poll_recv_at_registration(cx, bufs, meta, || {})
    }

    fn local_addr(&self) -> io::Result<SocketAddr> {
        self.inner.local_addr()
    }

    fn max_transmit_segments(&self) -> usize {
        self.inner.max_transmit_segments()
    }

    fn max_receive_segments(&self) -> usize {
        self.inner.max_receive_segments()
    }

    fn may_fragment(&self) -> bool {
        self.inner.may_fragment()
    }
}

/// A loopback socket ready for quinn's runtime to wrap.
#[must_use]
pub fn bound_socket() -> std::net::UdpSocket {
    std::net::UdpSocket::bind(SocketAddr::new(Ipv4Addr::LOCALHOST.into(), 0))
        .expect("the socket binds")
}
