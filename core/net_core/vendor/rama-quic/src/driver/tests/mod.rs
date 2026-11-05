#![cfg(any(
    feature = "boring",
    all(feature = "rustls", any(feature = "aws-lc", feature = "ring"))
))]

use rama_utils::octets;
use std::assert_matches;

use std::{
    convert::TryInto,
    future::Future,
    io,
    net::{IpAddr, Ipv4Addr, Ipv6Addr, SocketAddr, UdpSocket},
    pin::pin,
    str,
    sync::{
        Arc,
        atomic::{AtomicUsize, Ordering},
    },
    task::{Context, Poll, Wake, Waker},
};

use crate::driver::{Duration, Instant};
use crate::proto::{NegotiatedTlsParameters, RandomConnectionIdGenerator};
use crate::test_helpers;
use rama_core::bytes::Bytes;
use rama_core::extensions::{Extension, ExtensionsRef};
use rama_core::telemetry::tracing::Instrument as _;
use rama_core::telemetry::tracing::{error_span, info};
use rama_net::{address::SocketAddress, stream::SocketInfo};
use rand::{Rng, SeedableRng, rngs::StdRng};
use tokio::time::{sleep, timeout};
use tokio::{
    join,
    runtime::{Builder, Runtime},
};
use tracing_subscriber::EnvFilter;

use super::{Endpoint, EndpointConfig, RecvStream, SendDatagramError, SendStream, TransportConfig};

mod admission;
mod closing;
mod owned;
#[cfg(all(feature = "rustls", any(feature = "aws-lc", feature = "ring")))]
mod resumption;

/// A loopback address to bind on, for a fixture that lets the endpoint make its own socket.
fn localhost() -> SocketAddr {
    SocketAddr::new(IpAddr::V4(Ipv4Addr::LOCALHOST), 0)
}

#[test]
fn handshake_timeout() {
    let _guard = subscribe();
    let runtime = rt_threaded();
    let client = runtime
        .block_on(Endpoint::bind_client(
            rama_core::rt::Executor::new(),
            SocketAddr::new(IpAddr::V4(Ipv4Addr::LOCALHOST), 0),
        ))
        .unwrap();

    let identity = test_helpers::identity();

    let mut client_config = test_helpers::client(&identity);
    const IDLE_TIMEOUT: Duration = Duration::from_millis(500);
    let mut transport_config = crate::driver::TransportConfig::default();
    transport_config
        .set_max_idle_timeout(IDLE_TIMEOUT.try_into().unwrap())
        .set_initial_rtt(Duration::from_millis(10));
    client_config.set_transport_config(Arc::new(transport_config));

    let start = Instant::now();
    runtime.block_on(async move {
        match client
            .connect_with(
                client_config,
                SocketAddr::new(IpAddr::V4(Ipv4Addr::LOCALHOST), 1),
                "localhost",
            )
            .unwrap()
            .await
        {
            Err(crate::driver::ConnectionError::TimedOut) => {}
            Err(e) => panic!("unexpected error: {e:?}"),
            Ok(_) => panic!("unexpected success"),
        }
    });
    let dt = start.elapsed();
    assert!(dt > IDLE_TIMEOUT && dt < 2 * IDLE_TIMEOUT);
}

#[tokio::test]
async fn close_endpoint() {
    let _guard = subscribe();

    let identity = test_helpers::identity();

    let mut endpoint = Endpoint::bind_client(
        rama_core::rt::Executor::new(),
        SocketAddr::new(IpAddr::V4(Ipv4Addr::LOCALHOST), 0),
    )
    .await
    .unwrap();
    endpoint.set_default_client_config(test_helpers::client(&identity));

    let conn = endpoint
        .connect(
            SocketAddr::new(IpAddr::V4(Ipv4Addr::LOCALHOST), 1234),
            "localhost",
        )
        .unwrap();

    tokio::spawn(async move {
        let _handshake = conn.await;
    });

    let conn = endpoint
        .connect(
            SocketAddr::new(IpAddr::V4(Ipv4Addr::LOCALHOST), 1234),
            "localhost",
        )
        .unwrap();
    endpoint.close(0u32, &[]);
    match conn.await {
        Err(crate::driver::ConnectionError::LocallyClosed) => (),
        Err(e) => panic!("unexpected error: {e}"),
        Ok(_) => {
            panic!("unexpected success");
        }
    }
}

#[test]
fn local_addr() {
    let socket = UdpSocket::bind((Ipv6Addr::LOCALHOST, 0)).unwrap();
    let addr = socket.local_addr().unwrap();
    let runtime = rt_basic();
    let ep = {
        let _guard = runtime.enter();
        Endpoint::build(rama_core::rt::Executor::new())
            .with_std_socket(socket)
            .unwrap()
    };
    assert_eq!(
        addr,
        ep.local_addr()
            .expect("Could not obtain our local endpoint")
    );
}

#[test]
fn read_after_close() {
    let _guard = subscribe();
    let runtime = rt_basic();
    let endpoint = {
        let _guard = runtime.enter();
        endpoint()
    };

    const MSG: &[u8] = b"goodbye!";
    let endpoint2 = endpoint.clone();
    runtime.spawn(async move {
        let new_conn = endpoint2
            .accept()
            .await
            .expect("endpoint")
            .await
            .expect("connection");
        let mut s = new_conn.open_uni().await.unwrap();
        s.write_all(MSG).await.unwrap();
        s.finish().unwrap();
        // Wait for the stream to be closed, one way or another.
        _ = s.stopped().await;
    });
    runtime.block_on(async move {
        let new_conn = endpoint
            .connect(endpoint.local_addr().unwrap(), "localhost")
            .unwrap()
            .await
            .expect("connect");
        sleep(Duration::from_millis(100)).await;
        let mut stream = new_conn.accept_uni().await.expect("incoming streams");
        let msg = stream.read_to_end(usize::MAX).await.expect("read_to_end");
        assert_eq!(msg, MSG);
    });
}

#[derive(Debug, Extension)]
struct ConnectionMetadata(u32);

#[tokio::test]
async fn connection_extensions_are_shared_by_handles_and_isolated_between_connections() {
    let endpoint = endpoint();
    let connecting = endpoint
        .connect(endpoint.local_addr().unwrap(), "localhost")
        .unwrap();
    let (outgoing, incoming) = timeout(Duration::from_secs(5), async {
        join!(connecting, async { endpoint.accept().await.unwrap().await })
    })
    .await
    .unwrap();
    let outgoing = outgoing.unwrap();
    let incoming = incoming.unwrap();
    let shared = outgoing.clone();

    outgoing.extensions().insert(ConnectionMetadata(1));
    assert_eq!(
        shared
            .extensions()
            .get_ref::<ConnectionMetadata>()
            .unwrap()
            .0,
        1
    );
    assert!(!incoming.extensions().contains::<ConnectionMetadata>());

    shared.extensions().insert(ConnectionMetadata(2));
    assert_eq!(
        outgoing
            .extensions()
            .get_ref::<ConnectionMetadata>()
            .unwrap()
            .0,
        2
    );
    drop(outgoing);
    assert_eq!(
        shared
            .extensions()
            .get_ref::<ConnectionMetadata>()
            .unwrap()
            .0,
        2
    );

    drop(shared);
    drop(incoming);
    endpoint.close(0u32, b"done");
    timeout(Duration::from_secs(5), endpoint.shutdown())
        .await
        .unwrap();
}

#[tokio::test]
async fn established_connections_publish_their_negotiated_tls_parameters() {
    let endpoint = endpoint();
    let connecting = endpoint
        .connect(endpoint.local_addr().unwrap(), "localhost")
        .unwrap();
    let (outgoing, incoming) = timeout(Duration::from_secs(5), async {
        join!(connecting, async { endpoint.accept().await.unwrap().await })
    })
    .await
    .unwrap();
    for connection in [outgoing.unwrap(), incoming.unwrap()] {
        let parameters = connection
            .extensions()
            .get_arc::<NegotiatedTlsParameters>()
            .expect("published once connected");
        assert!(parameters.application_layer_protocol.is_some());
    }
    endpoint.close(0u32, b"done");
    timeout(Duration::from_secs(5), endpoint.shutdown())
        .await
        .unwrap();
}

#[test]
fn export_keying_material() {
    let _guard = subscribe();
    let runtime = rt_basic();
    let endpoint = {
        let _guard = runtime.enter();
        endpoint()
    };

    runtime.block_on(async move {
        let outgoing_conn_fut = tokio::spawn({
            let endpoint = endpoint.clone();
            async move {
                endpoint
                    .connect(endpoint.local_addr().unwrap(), "localhost")
                    .unwrap()
                    .await
                    .expect("connect")
            }
        });
        let incoming_conn_fut = tokio::spawn({
            let endpoint = endpoint.clone();
            async move {
                endpoint
                    .accept()
                    .await
                    .expect("endpoint")
                    .await
                    .expect("connection")
            }
        });
        let outgoing_conn = outgoing_conn_fut.await.unwrap();
        let incoming_conn = incoming_conn_fut.await.unwrap();
        let mut i_buf = [0u8; 64];
        incoming_conn
            .export_keying_material(&mut i_buf, b"asdf", b"qwer")
            .unwrap();
        let mut o_buf = [0u8; 64];
        outgoing_conn
            .export_keying_material(&mut o_buf, b"asdf", b"qwer")
            .unwrap();
        assert_eq!(&i_buf[..], &o_buf[..]);
    });
}

#[tokio::test]
async fn ip_blocking() {
    let _guard = subscribe();
    let endpoint_factory = EndpointFactory::new();
    let client_1 = endpoint_factory.endpoint();
    let client_1_addr = client_1.local_addr().unwrap();
    let client_2 = endpoint_factory.endpoint();
    let server = endpoint_factory.endpoint();
    let server_addr = server.local_addr().unwrap();
    let server_task = tokio::spawn(async move {
        loop {
            let accepting = server.accept().await.unwrap();
            if accepting.remote_address() == client_1_addr {
                accepting.refuse();
            } else if accepting.remote_address_validated() {
                accepting.await.expect("connection");
            } else {
                accepting.retry().unwrap();
            }
        }
    });
    tokio::join!(
        async move {
            let e = client_1
                .connect(server_addr, "localhost")
                .unwrap()
                .await
                .expect_err("server should have blocked this");
            assert_matches!(
                e,
                crate::driver::ConnectionError::ConnectionClosed(_),
                "wrong error",
            );
        },
        async move {
            client_2
                .connect(server_addr, "localhost")
                .unwrap()
                .await
                .expect("connect");
        }
    );
    server_task.abort();
}

/// Construct an endpoint suitable for connecting to itself
pub(super) fn endpoint() -> Endpoint {
    EndpointFactory::new().endpoint()
}

fn endpoint_with_config(transport_config: TransportConfig) -> Endpoint {
    EndpointFactory::new().endpoint_with_config(transport_config)
}

/// Constructs endpoints suitable for connecting to themselves and each other
struct EndpointFactory {
    identity: rama_tls::server::ServerAuthData,
    endpoint_config: EndpointConfig,
}

impl EndpointFactory {
    fn new() -> Self {
        Self {
            identity: test_helpers::identity(),
            endpoint_config: EndpointConfig::try_with_rand_key().unwrap(),
        }
    }

    fn endpoint(&self) -> Endpoint {
        self.endpoint_with_config(TransportConfig::default())
    }

    fn endpoint_with_config(&self, transport_config: TransportConfig) -> Endpoint {
        let transport_config = Arc::new(transport_config);
        let mut server_config = test_helpers::server(&self.identity);
        server_config.set_transport_config(transport_config.clone());

        let mut endpoint = Endpoint::build(rama_core::rt::Executor::new())
            .with_config(self.endpoint_config.clone())
            .maybe_with_server_config(Some(server_config))
            .with_std_socket(
                UdpSocket::bind(SocketAddr::new(IpAddr::V4(Ipv4Addr::LOCALHOST), 0)).unwrap(),
            )
            .unwrap();
        let mut client_config = test_helpers::client(&self.identity);
        client_config.set_transport_config(transport_config);
        endpoint.set_default_client_config(client_config);

        endpoint
    }
}

#[tokio::test]
async fn zero_rtt() {
    let _guard = subscribe();
    let endpoint = endpoint();

    const MSG0: &[u8] = b"zero";
    const MSG1: &[u8] = b"one";
    let endpoint2 = endpoint.clone();
    tokio::spawn(async move {
        for _ in 0..2 {
            let incoming = endpoint2.accept().await.unwrap().accept().unwrap();
            let (connection, established) = incoming
                .into_0rtt()
                .expect("server connections permit early data handles");
            let c = connection.clone();
            tokio::spawn(async move {
                while let Ok(mut x) = c.accept_uni().await {
                    let msg = x.read_to_end(usize::MAX).await.unwrap();
                    assert_eq!(msg, MSG0);
                }
            });
            info!("sending 0.5-RTT");
            let mut s = connection.open_uni().await.expect("open_uni");
            s.write_all(MSG0).await.expect("write");
            s.finish().unwrap();
            assert!(established.await.unwrap());
            info!("sending 1-RTT");
            let mut s = connection.open_uni().await.expect("open_uni");
            s.write_all(MSG1).await.expect("write");
            // The peer might close the connection before ACKing
            let _finished = s.finish();
        }
    });

    let connection = endpoint
        .connect(endpoint.local_addr().unwrap(), "localhost")
        .unwrap()
        .into_0rtt()
        .err()
        .expect("0-RTT succeeded without keys")
        .await
        .expect("connect");

    {
        let mut stream = connection.accept_uni().await.expect("incoming streams");
        let msg = stream.read_to_end(usize::MAX).await.expect("read_to_end");
        assert_eq!(msg, MSG0);
        // Read a 1-RTT message to ensure the handshake completes fully, allowing the server's
        // NewSessionTicket frame to be received.
        let mut stream = connection.accept_uni().await.expect("incoming streams");
        let msg = stream.read_to_end(usize::MAX).await.expect("read_to_end");
        assert_eq!(msg, MSG1);
        drop(connection);
    }

    info!("initial connection complete");

    let (connection, zero_rtt) = endpoint
        .connect(endpoint.local_addr().unwrap(), "localhost")
        .unwrap()
        .into_0rtt()
        .unwrap_or_else(|_| panic!("missing 0-RTT keys"));
    // Send something ASAP to use 0-RTT
    let c = connection.clone();
    tokio::spawn(async move {
        let mut s = c.open_uni().await.expect("0-RTT open uni");
        info!("sending 0-RTT");
        s.write_all(MSG0).await.expect("0-RTT write");
        s.finish().unwrap();
    });

    let mut stream = connection.accept_uni().await.expect("incoming streams");
    let msg = stream.read_to_end(usize::MAX).await.expect("read_to_end");
    assert_eq!(msg, MSG0);
    assert!(zero_rtt.await.unwrap());

    drop((stream, connection));

    endpoint.wait_idle().await;
}

#[test]
#[cfg_attr(
    any(target_os = "solaris", target_os = "illumos"),
    ignore = "Fails on Solaris and Illumos"
)]
fn echo_v6() {
    run_echo(&EchoArgs {
        client_addr: SocketAddr::new(IpAddr::V6(Ipv6Addr::UNSPECIFIED), 0),
        server_addr: SocketAddr::new(IpAddr::V6(Ipv6Addr::LOCALHOST), 0),
        nr_streams: 1,
        stream_size: octets::kib(10),
        receive_window: None,
        stream_receive_window: None,
    });
}

#[test]
#[cfg_attr(target_os = "solaris", ignore = "Sometimes hangs in poll() on Solaris")]
fn echo_v4() {
    run_echo(&EchoArgs {
        client_addr: SocketAddr::new(IpAddr::V4(Ipv4Addr::UNSPECIFIED), 0),
        server_addr: SocketAddr::new(IpAddr::V4(Ipv4Addr::LOCALHOST), 0),
        nr_streams: 1,
        stream_size: octets::kib(10),
        receive_window: None,
        stream_receive_window: None,
    });
}

#[test]
#[cfg_attr(target_os = "solaris", ignore = "Hangs in poll() on Solaris")]
fn echo_dualstack() {
    run_echo(&EchoArgs {
        client_addr: SocketAddr::new(IpAddr::V6(Ipv6Addr::UNSPECIFIED), 0),
        server_addr: SocketAddr::new(IpAddr::V4(Ipv4Addr::LOCALHOST), 0),
        nr_streams: 1,
        stream_size: octets::kib(10),
        receive_window: None,
        stream_receive_window: None,
    });
}

#[test]
#[ignore = "stress: run with `just rama-quic/qa-stress`"]
#[cfg_attr(target_os = "solaris", ignore = "Hangs in poll() on Solaris")]
fn stress_receive_window() {
    run_echo(&EchoArgs {
        client_addr: SocketAddr::new(IpAddr::V4(Ipv4Addr::UNSPECIFIED), 0),
        server_addr: SocketAddr::new(IpAddr::V4(Ipv4Addr::LOCALHOST), 0),
        nr_streams: 50,
        stream_size: octets::kib(25) + 11,
        receive_window: Some(37),
        stream_receive_window: Some(octets::mib_u64(100)),
    });
}

#[test]
#[ignore = "stress: run with `just rama-quic/qa-stress`"]
#[cfg_attr(target_os = "solaris", ignore = "Hangs in poll() on Solaris")]
fn stress_stream_receive_window() {
    // Note that there is no point in running this with too many streams,
    // since the window is only active within a stream.
    run_echo(&EchoArgs {
        client_addr: SocketAddr::new(IpAddr::V4(Ipv4Addr::UNSPECIFIED), 0),
        server_addr: SocketAddr::new(IpAddr::V4(Ipv4Addr::LOCALHOST), 0),
        nr_streams: 2,
        stream_size: octets::kib(250) + 11,
        receive_window: Some(octets::mib_u64(100)),
        stream_receive_window: Some(37),
    });
}

#[test]
#[ignore = "stress: run with `just rama-quic/qa-stress`"]
#[cfg_attr(target_os = "solaris", ignore = "Hangs in poll() on Solaris")]
fn stress_both_windows() {
    run_echo(&EchoArgs {
        client_addr: SocketAddr::new(IpAddr::V4(Ipv4Addr::UNSPECIFIED), 0),
        server_addr: SocketAddr::new(IpAddr::V4(Ipv4Addr::LOCALHOST), 0),
        nr_streams: 50,
        stream_size: octets::kib(25) + 11,
        receive_window: Some(37),
        stream_receive_window: Some(37),
    });
}

fn run_echo(args: &EchoArgs) {
    let args = *args;
    let _guard = subscribe();
    let runtime = rt_basic();
    let handle = {
        // Use small receive windows
        let mut transport_config = TransportConfig::default();
        if let Some(receive_window) = args.receive_window {
            transport_config
                .set_receive_window(rama_quic_proto::VarInt::try_from(receive_window).unwrap());
        }
        if let Some(stream_receive_window) = args.stream_receive_window {
            transport_config.set_stream_receive_window(
                rama_quic_proto::VarInt::try_from(stream_receive_window).unwrap(),
            );
        }
        transport_config.set_max_concurrent_bidi_streams(1_u8);
        transport_config.set_max_concurrent_uni_streams(1_u8);
        let transport_config = Arc::new(transport_config);

        // We don't use the `endpoint` helper here because we want two different endpoints with
        // different addresses.
        let identity = test_helpers::identity();
        let mut server_config = test_helpers::server(&identity);

        server_config.transport = transport_config.clone();
        let server_sock = UdpSocket::bind(args.server_addr).unwrap();
        let server_addr = server_sock.local_addr().unwrap();
        let server = {
            let _guard = runtime.enter();
            let _guard = error_span!("server").entered();
            Endpoint::build(rama_core::rt::Executor::new())
                .maybe_with_server_config(Some(server_config))
                .with_std_socket(server_sock)
                .unwrap()
        };

        let mut client = {
            let _guard = error_span!("client").entered();
            runtime
                .block_on(Endpoint::bind_client(
                    rama_core::rt::Executor::new(),
                    args.client_addr,
                ))
                .unwrap()
        };
        let mut client_config = test_helpers::client(&identity);
        client_config.set_transport_config(transport_config);
        client.set_default_client_config(client_config);

        let handle = runtime.spawn(async move {
            let incoming = echo_phase(&args, "server accept", server.accept())
                .await
                .unwrap();

            // Note for anyone modifying the platform support in this test:
            // If `local_ip` gets available on additional platforms - which
            // requires modifying this test - please update the list of supported
            // platforms in the doc comment of `rama_udp::DatagramCapabilities::receive_local_ip`.
            if cfg!(target_os = "linux")
                || cfg!(target_os = "android")
                || cfg!(target_os = "freebsd")
                || cfg!(target_os = "openbsd")
                || cfg!(target_os = "netbsd")
                || cfg!(target_os = "macos")
                || cfg!(target_os = "windows")
            {
                let local_ip = incoming.local_ip().expect("Local IP must be available");
                assert!(local_ip.is_loopback());
            } else {
                assert_eq!(None, incoming.local_ip());
            }

            let new_conn = echo_phase(&args, "server handshake", incoming)
                .await
                .unwrap();
            for index in 0..args.nr_streams {
                let stream = echo_phase(
                    &args,
                    &format!("server accept stream {index}"),
                    new_conn.accept_bi(),
                )
                .await
                .unwrap();
                echo_phase(&args, &format!("server echo stream {index}"), echo(stream)).await;
            }
            echo_phase(&args, "server connection close", new_conn.closed()).await;
            drop(new_conn);
            echo_phase(&args, "server shutdown", server.shutdown()).await;
        });

        info!("connecting from {} to {}", args.client_addr, server_addr);
        runtime.block_on(
            async move {
                let new_conn = echo_phase(
                    &args,
                    "client handshake",
                    client.connect(server_addr, "localhost").unwrap(),
                )
                .await
                .expect("connect");

                /// This is just an arbitrary number to generate deterministic test data
                const SEED: u64 = 0x12345678;

                for i in 0..args.nr_streams {
                    eprintln!("Opening stream {i}");
                    let (mut send, mut recv) = echo_phase(
                        &args,
                        &format!("client open stream {i}"),
                        new_conn.open_bi(),
                    )
                    .await
                    .expect("stream open");
                    let msg = gen_data(args.stream_size, SEED);

                    let send_task = async {
                        send.write_all(&msg).await.expect("write");
                        send.finish().unwrap();
                    };
                    let recv_task = async { recv.read_to_end(usize::MAX).await.expect("read") };

                    let (_, data) =
                        echo_phase(&args, &format!("client transfer stream {i}"), async {
                            tokio::join!(send_task, recv_task)
                        })
                        .await;

                    assert_eq!(data[..], msg[..], "Data mismatch");
                }
                new_conn.close(0u32, b"done");
                drop(new_conn);
                echo_phase(&args, "client shutdown", client.shutdown()).await;
            }
            .instrument(error_span!("client")),
        );
        handle
    };
    runtime
        .block_on(echo_phase(&args, "server task join", handle))
        .unwrap();
}

async fn echo_phase<T>(
    args: &EchoArgs,
    phase: &str,
    future: impl std::future::IntoFuture<Output = T>,
) -> T {
    tokio::time::timeout(Duration::from_secs(15), future)
        .await
        .unwrap_or_else(|_| panic!("echo timed out during {phase}: {args:?}"))
}

#[derive(Debug, Clone, Copy)]
struct EchoArgs {
    client_addr: SocketAddr,
    server_addr: SocketAddr,
    nr_streams: usize,
    stream_size: usize,
    receive_window: Option<u64>,
    stream_receive_window: Option<u64>,
}

async fn echo((mut send, mut recv): (SendStream, RecvStream)) {
    loop {
        // These are 32 buffers, for reading approximately 32kB at once
        #[rustfmt::skip]
        let mut bufs = [
            Bytes::new(), Bytes::new(), Bytes::new(), Bytes::new(),
            Bytes::new(), Bytes::new(), Bytes::new(), Bytes::new(),
            Bytes::new(), Bytes::new(), Bytes::new(), Bytes::new(),
            Bytes::new(), Bytes::new(), Bytes::new(), Bytes::new(),
            Bytes::new(), Bytes::new(), Bytes::new(), Bytes::new(),
            Bytes::new(), Bytes::new(), Bytes::new(), Bytes::new(),
            Bytes::new(), Bytes::new(), Bytes::new(), Bytes::new(),
            Bytes::new(), Bytes::new(), Bytes::new(), Bytes::new(),
        ];

        match recv.read_chunks(&mut bufs).await.expect("read chunks") {
            Some(n) => {
                send.write_all_chunks(&mut bufs[..n])
                    .await
                    .expect("write chunks");
            }
            None => break,
        }
    }

    let _finished = send.finish();
}

fn gen_data(size: usize, seed: u64) -> Vec<u8> {
    let mut rng: StdRng = SeedableRng::seed_from_u64(seed);
    let mut buf = vec![0; size];
    rng.fill_bytes(&mut buf);
    buf
}

fn subscribe() -> rama_core::telemetry::tracing::subscriber::DefaultGuard {
    let sub = tracing_subscriber::FmtSubscriber::builder()
        .with_env_filter(EnvFilter::from_default_env())
        .with_writer(|| TestWriter)
        .finish();
    rama_core::telemetry::tracing::subscriber::set_default(sub)
}

struct TestWriter;

impl std::io::Write for TestWriter {
    fn write(&mut self, buf: &[u8]) -> io::Result<usize> {
        eprint!(
            "{}",
            str::from_utf8(buf).expect("tried to log invalid UTF-8")
        );
        Ok(buf.len())
    }

    fn flush(&mut self) -> io::Result<()> {
        io::stdout().flush()
    }
}

fn rt_basic() -> Runtime {
    Builder::new_current_thread().enable_all().build().unwrap()
}

fn rt_threaded() -> Runtime {
    Builder::new_multi_thread().enable_all().build().unwrap()
}

#[tokio::test]
async fn rebind_recv() {
    let _guard = subscribe();

    let identity = test_helpers::identity();

    let mut client = Endpoint::bind_client(
        rama_core::rt::Executor::new(),
        SocketAddr::new(IpAddr::V4(Ipv4Addr::LOCALHOST), 0),
    )
    .await
    .unwrap();
    let mut client_config = test_helpers::client(&identity);
    client_config.set_transport_config(Arc::new({
        let mut cfg = TransportConfig::default();
        cfg.set_max_concurrent_uni_streams(1u32);
        cfg
    }));
    client.set_default_client_config(client_config);

    let server_config = test_helpers::server(&identity);
    let server = {
        let _guard = rama_core::telemetry::tracing::error_span!("server").entered();
        Endpoint::bind_server(
            rama_core::rt::Executor::new(),
            server_config,
            SocketAddr::new(IpAddr::V4(Ipv4Addr::LOCALHOST), 0),
        )
        .await
        .unwrap()
    };
    let server_addr = server.local_addr().unwrap();

    const MSG: &[u8; 5] = b"hello";

    let write_send = Arc::new(tokio::sync::Notify::new());
    let write_recv = write_send.clone();
    let connected_send = Arc::new(tokio::sync::Notify::new());
    let connected_recv = connected_send.clone();
    let server = tokio::spawn(async move {
        let connection = server.accept().await.unwrap().await.unwrap();
        info!("got conn");
        connected_send.notify_one();
        write_recv.notified().await;
        let mut stream = connection.open_uni().await.unwrap();
        stream.write_all(MSG).await.unwrap();
        stream.finish().unwrap();
        // Wait for the stream to be closed, one way or another.
        _ = stream.stopped().await;
    });

    let connection = {
        let _guard = rama_core::telemetry::tracing::error_span!("client").entered();
        client
            .connect(server_addr, "localhost")
            .unwrap()
            .await
            .unwrap()
    };
    info!("connected");
    connected_recv.notified().await;
    client
        .rebind_std_socket(
            UdpSocket::bind(SocketAddr::new(IpAddr::V4(Ipv4Addr::LOCALHOST), 0)).unwrap(),
        )
        .unwrap();
    info!("rebound");
    write_send.notify_one();
    let mut stream = connection.accept_uni().await.unwrap();
    assert_eq!(stream.read_to_end(MSG.len()).await.unwrap(), MSG);
    server.await.unwrap();
}

#[tokio::test]
async fn socket_info_follows_a_rebind() {
    let _guard = subscribe();
    let identity = test_helpers::identity();
    let localhost = SocketAddr::new(IpAddr::V4(Ipv4Addr::LOCALHOST), 0);
    let mut client = Endpoint::bind_client(rama_core::rt::Executor::new(), localhost)
        .await
        .unwrap();
    client.set_default_client_config(test_helpers::client(&identity));
    let server = Endpoint::bind_server(
        rama_core::rt::Executor::new(),
        test_helpers::server(&identity),
        localhost,
    )
    .await
    .unwrap();
    let server_addr = server.local_addr().unwrap();
    let (client_connection, server_connection) = tokio::join!(
        async {
            client
                .connect(server_addr, "localhost")
                .unwrap()
                .await
                .unwrap()
        },
        async { server.accept().await.unwrap().await.unwrap() },
    );
    let socket_info =
        |connection: &super::Connection| connection.extensions().get_arc::<SocketInfo>().unwrap();
    let before = client.local_addr().unwrap();
    assert_eq!(
        socket_info(&client_connection).local_addr(),
        Some(before.into())
    );
    assert_eq!(
        socket_info(&server_connection).peer_addr(),
        SocketAddress::from(before)
    );

    client
        .rebind_std_socket(UdpSocket::bind(localhost).unwrap())
        .unwrap();
    let after = client.local_addr().unwrap();
    assert_ne!(before, after);
    let echo = async {
        let (mut send, mut recv) = server_connection.accept_bi().await.unwrap();
        let data = recv.read_to_end(16).await.unwrap();
        send.write_all(&data).await.unwrap();
        send.finish().unwrap();
    };
    let ask = async {
        let (mut send, mut recv) = client_connection.open_bi().await.unwrap();
        send.write_all(b"ping").await.unwrap();
        send.finish().unwrap();
        recv.read_to_end(16).await.unwrap()
    };
    let ((), reply) = timeout(Duration::from_secs(5), async { tokio::join!(echo, ask) })
        .await
        .unwrap();
    assert_eq!(reply, b"ping");

    assert_eq!(
        socket_info(&client_connection).local_addr(),
        Some(after.into())
    );
    // The server publishes the new peer once its path validation completes, which can trail
    // the round trip.
    timeout(Duration::from_secs(5), async {
        while socket_info(&server_connection).peer_addr() != SocketAddress::from(after) {
            sleep(Duration::from_millis(10)).await;
        }
    })
    .await
    .expect("the server follows the validated path");
}

#[tokio::test]
async fn stream_id_flow_control() {
    let _guard = subscribe();
    let mut cfg = TransportConfig::default();
    cfg.set_max_concurrent_uni_streams(1u32);
    let endpoint = endpoint_with_config(cfg);

    let (client, server) = tokio::join!(
        endpoint
            .connect(endpoint.local_addr().unwrap(), "localhost")
            .unwrap(),
        async { endpoint.accept().await.unwrap().await }
    );
    let client = client.unwrap();
    let server = server.unwrap();

    // If `open_uni` doesn't get unblocked when the previous stream is dropped, this will time out.
    tokio::join!(
        async {
            client.open_uni().await.unwrap();
        },
        async {
            client.open_uni().await.unwrap();
        },
        async {
            client.open_uni().await.unwrap();
        },
        async {
            server.accept_uni().await.unwrap();
            server.accept_uni().await.unwrap();
        }
    );
}

#[tokio::test]
async fn try_send_datagram_reports_a_full_buffer_without_discarding() {
    let _guard = subscribe();
    let mut transport = TransportConfig::default();
    transport.set_datagram_send_buffer_size(64);
    let endpoint = endpoint_with_config(transport);
    let (client, server) = tokio::join!(
        endpoint
            .connect(endpoint.local_addr().unwrap(), "localhost")
            .unwrap(),
        async { endpoint.accept().await.unwrap().await }
    );
    let client = client.unwrap();
    let server = server.unwrap();
    let mut queued = 0;
    // Fill synchronously: the driver cannot drain the buffer between these calls.
    loop {
        match client.try_send_datagram(vec![queued; 16].into()) {
            Ok(()) => queued += 1,
            Err(SendDatagramError::Blocked) => break,
            Err(error) => panic!("unexpected {error:?}"),
        }
    }
    assert!(queued > 0);
    for expected in 0..queued {
        // A lost datagram fails the test instead of waiting forever.
        let datagram = tokio::time::timeout(Duration::from_secs(10), server.read_datagram())
            .await
            .expect("every queued datagram arrives")
            .unwrap();
        assert_eq!(datagram[0], expected, "no queued datagram may be discarded");
    }
}

#[tokio::test]
async fn stream_datagrams_follow_the_transport_send_state() {
    let _guard = subscribe();
    let endpoint = endpoint();
    let (client, server) = tokio::join!(
        endpoint
            .connect(endpoint.local_addr().unwrap(), "localhost")
            .unwrap(),
        async { endpoint.accept().await.unwrap().await }
    );
    let client = client.unwrap();
    let server = server.unwrap();

    // Peer STOP_SENDING: the writer is never polled again, the handle and its clone see it.
    let (mut send, _recv) = client.open_bi().await.unwrap();
    send.write_all(b"x").await.unwrap();
    let handle = send.handle();
    let clone = handle.clone();
    handle.send_datagram(Bytes::from_static(b"open")).unwrap();
    clone
        .try_send_datagram(Bytes::from_static(b"open"))
        .unwrap();
    let (_server_send, mut server_recv) = server.accept_bi().await.unwrap();
    server_recv.stop(7u32).unwrap();
    assert_eq!(send.stopped().await.unwrap(), Some(7u32.into()));
    for handle in [&handle, &clone] {
        assert_matches!(
            handle.send_datagram(Bytes::from_static(b"stopped")),
            Err(SendDatagramError::StreamClosed)
        );
        assert_matches!(
            handle.try_send_datagram(Bytes::from_static(b"stopped")),
            Err(SendDatagramError::StreamClosed)
        );
    }

    // A local FIN closes it at once, before the peer acknowledges it.
    let (mut send, _recv) = client.open_bi().await.unwrap();
    let handle = send.handle();
    handle.send_datagram(Bytes::from_static(b"open")).unwrap();
    send.finish().unwrap();
    assert_matches!(
        handle.send_datagram(Bytes::from_static(b"finished")),
        Err(SendDatagramError::StreamClosed)
    );

    // A local reset through any handle.
    let (send, _recv) = client.open_bi().await.unwrap();
    let handle = send.handle();
    handle.clone().abort(9u32);
    assert_matches!(
        handle.send_datagram(Bytes::from_static(b"reset")),
        Err(SendDatagramError::StreamClosed)
    );

    // Connection-wide datagrams and the connection itself are unaffected by closed streams.
    let (send, _recv) = client.open_bi().await.unwrap();
    let handle = send.handle();
    client.send_datagram(Bytes::from_static(b"conn")).unwrap();
    handle
        .send_datagram(Bytes::from_static(b"still open"))
        .unwrap();

    client.close(0u32, b"done");
    assert_matches!(
        handle.send_datagram(Bytes::from_static(b"lost")),
        Err(SendDatagramError::ConnectionLost(_))
    );
}

#[tokio::test]
async fn received_datagrams_counts_those_not_yet_read() {
    let _guard = subscribe();
    let endpoint = endpoint();

    let (client, server) = tokio::join!(
        endpoint
            .connect(endpoint.local_addr().unwrap(), "localhost")
            .unwrap(),
        async { endpoint.accept().await.unwrap().await }
    );
    let client = client.unwrap();
    let server = server.unwrap();

    assert_eq!(client.received_datagrams(), 0);
    for payload in [&b"one"[..], b"two", b"three"] {
        server.send_datagram(payload.into()).unwrap();
    }
    tokio::time::timeout(Duration::from_secs(10), async {
        while client.received_datagrams() < 3 {
            tokio::time::sleep(Duration::from_millis(1)).await;
        }
    })
    .await
    .unwrap();
    assert_eq!(client.received_datagrams(), 3);
    client.read_datagram().await.unwrap();
    assert_eq!(client.received_datagrams(), 2);
}

#[tokio::test]
async fn two_datagram_readers() {
    let _guard = subscribe();
    let endpoint = endpoint();

    let (client, server) = tokio::join!(
        endpoint
            .connect(endpoint.local_addr().unwrap(), "localhost")
            .unwrap(),
        async { endpoint.accept().await.unwrap().await }
    );
    let client = client.unwrap();
    let server = server.unwrap();

    let done = tokio::sync::Notify::new();
    let (a, b, ()) = tokio::join!(
        async {
            let x = client.read_datagram().await.unwrap();
            done.notify_waiters();
            x
        },
        async {
            let x = client.read_datagram().await.unwrap();
            done.notify_waiters();
            x
        },
        async {
            server.send_datagram(b"one"[..].into()).unwrap();
            done.notified().await;
            server.send_datagram_wait(b"two"[..].into()).await.unwrap();
        }
    );
    assert!(*a == *b"one" || *b == *b"one");
    assert!(*a == *b"two" || *b == *b"two");
}

#[tokio::test]
async fn multiple_conns_with_zero_length_cids() {
    let _guard = subscribe();
    let mut factory = EndpointFactory::new();
    factory.endpoint_config.set_cid_generator(Arc::new(|| {
        Box::new(RandomConnectionIdGenerator::new(0).expect("zero is a length"))
    }));
    let server = {
        let _guard = error_span!("server").entered();
        factory.endpoint()
    };
    let server_addr = server.local_addr().unwrap();

    let client1 = {
        let _guard = error_span!("client1").entered();
        factory.endpoint()
    };
    let client2 = {
        let _guard = error_span!("client2").entered();
        factory.endpoint()
    };

    let client1 = async move {
        let conn = client1
            .connect(server_addr, "localhost")
            .unwrap()
            .await
            .unwrap();
        conn.closed().await;
    }
    .instrument(error_span!("client1"));
    let client2 = async move {
        let conn = client2
            .connect(server_addr, "localhost")
            .unwrap()
            .await
            .unwrap();
        conn.closed().await;
    }
    .instrument(error_span!("client2"));
    let server = async move {
        let client1 = server.accept().await.unwrap().await.unwrap();
        let client2 = server.accept().await.unwrap().await.unwrap();
        // Both connections are now concurrently live.
        client1.close(42u32, &[]);
        client2.close(42u32, &[]);
    }
    .instrument(error_span!("server"));
    tokio::join!(client1, client2, server);
}

#[tokio::test]
async fn stream_stopped() {
    let _guard = subscribe();
    let factory = EndpointFactory::new();
    let server = {
        let _guard = error_span!("server").entered();
        factory.endpoint()
    };
    let server_addr = server.local_addr().unwrap();

    let client = {
        let _guard = error_span!("client1").entered();
        factory.endpoint()
    };

    let client = async move {
        let conn = client
            .connect(server_addr, "localhost")
            .unwrap()
            .await
            .unwrap();
        let mut stream = conn.open_uni().await.unwrap();
        let stopped1 = stream.stopped();
        let stopped2 = stream.stopped();
        let stopped3 = stream.stopped();

        stream.write_all(b"hi").await.unwrap();
        // spawn one of the futures into a task
        let stopped1 = tokio::task::spawn(stopped1);
        // verify that both futures resolved
        let (stopped1, stopped2) = tokio::join!(stopped1, stopped2);
        assert_matches!(stopped1, Ok(Ok(Some(val))) if val == 42);
        assert_matches!(stopped2, Ok(Some(val)) if val == 42);
        // drop the stream
        drop(stream);
        // verify that a future also resolves after dropping the stream
        let stopped3 = stopped3.await;
        assert_eq!(stopped3, Ok(Some(42u32.into())));
    };
    let client = timeout(Duration::from_millis(100), client).instrument(error_span!("client"));
    let server = async move {
        let conn = server.accept().await.unwrap().await.unwrap();
        let mut stream = conn.accept_uni().await.unwrap();
        let mut buf = [0u8; 2];
        stream.read_exact(&mut buf).await.unwrap();
        stream.stop(42u32).unwrap();
        conn
    }
    .instrument(error_span!("server"));
    let (client, conn) = tokio::join!(client, server);
    client.expect("timeout");
    drop(conn);
}

#[tokio::test]
async fn stream_stopped_2() {
    let _guard = subscribe();
    let endpoint = endpoint();

    let (conn, _server_conn) = tokio::try_join!(
        endpoint
            .connect(endpoint.local_addr().unwrap(), "localhost")
            .unwrap(),
        async { endpoint.accept().await.unwrap().await }
    )
    .unwrap();
    let send_stream = conn.open_uni().await.unwrap();
    let mut stopped = std::pin::pin!(
        timeout(Duration::from_millis(100), send_stream.stopped())
            .instrument(error_span!("stopped"))
    );
    // poll the future once so that the waker is registered.
    tokio::select! {
        biased;
        _x = &mut stopped => {},
        _x = std::future::ready(()) => {}
    }
    // drop the send stream
    drop(send_stream);
    // make sure the stopped future still resolves
    let res = stopped.await;
    assert_eq!(res, Ok(Ok(None)));
}

#[tokio::test]
async fn stream_drop_removes_blocked_reader() {
    let _guard = subscribe();

    for drop_stream in [false, true] {
        let endpoint_factory = EndpointFactory::new();
        let server = endpoint_factory.endpoint();
        let server_address = server.local_addr().unwrap();
        let client = endpoint_factory.endpoint();

        let server_task = tokio::spawn(async move {
            let conn = server.accept().await.unwrap().await.unwrap();
            let mut stream = conn.accept_uni().await.unwrap();

            // read "hello"
            let mut buf = [0u8; 5];
            stream.read_exact(&mut buf).await.unwrap();

            let (waker, wake_counter) = new_count_waker();
            let mut cx = Context::from_waker(&waker);
            // do a blocking read which will add the stream in conn.blocked_readers
            {
                let mut buf = [0u8; 64];
                let mut read_fut = std::pin::pin!(stream.read(&mut buf));
                assert_matches!(read_fut.as_mut().poll(&mut cx), Poll::Pending);
            }

            if !drop_stream {
                assert_eq!(wake_counter.wakes(), 0);
                // We have a blocked reader, closing the connection should wake it. We use this as
                // a proxy to assert that the stream is in conn.blocked_readers.
                conn.close(0u32, b"done");
                assert_eq!(wake_counter.wakes(), 1);
            } else {
                // dropping the stream should remove it from conn.blocked_readers, so we don't
                // expect any wakeups
                drop(stream);
                assert_eq!(wake_counter.wakes(), 0, "no wakeups should have occurred");
                conn.close(0u32, b"done");
                assert_eq!(wake_counter.wakes(), 0, "no wakeups should have occurred");
            }
        });

        let conn = client
            .connect(server_address, "localhost")
            .unwrap()
            .await
            .unwrap();
        let mut stream = conn.open_uni().await.unwrap();
        // need to send some data to actually start the stream
        stream.write_all(b"hello").await.unwrap();

        server_task.await.unwrap();
    }
}

/// Test that dropping a `RecvStream` after cancelling a read and then
/// explicitly `stop`ing it doesn't panic.
#[tokio::test]
async fn recv_stream_cancel_stop_drop() {
    let _guard = subscribe();
    let factory = EndpointFactory::new();
    let server = {
        let _guard = error_span!("server").entered();
        factory.endpoint()
    };
    let server_addr = server.local_addr().unwrap();

    let client = {
        let _guard = error_span!("client").entered();
        factory.endpoint()
    };
    let recv_dropped = tokio::sync::SetOnce::new();
    join!(
        async {
            let conn = server.accept().await.unwrap().await.unwrap();
            let mut recv = conn.accept_uni().await.unwrap();
            // Create a future to read from the stream, poll it once, then immediately drop it
            {
                let fut = pin!(recv.read_to_end(usize::MAX));
                let mut cx = Context::from_waker(Waker::noop());
                assert!(fut.poll(&mut cx).is_pending());
            }
            recv_dropped.set(()).unwrap();
            recv.stop(0u32).unwrap();
        },
        async {
            let conn = client
                .connect(server_addr, "localhost")
                .unwrap()
                .await
                .unwrap();
            let mut send = conn.open_uni().await.unwrap();
            _ = send.write_all(b"hello").await;
            // Don't drop (finish) the send stream until the read has been
            // cancelled by the server, ensuring that read_to_end can't complete
            // immediately.
            recv_dropped.wait().await;
        },
    );
}

#[derive(Default)]
struct WakeCounter {
    wakes: AtomicUsize,
}

impl WakeCounter {
    fn wakes(&self) -> usize {
        self.wakes.load(Ordering::SeqCst)
    }
}

impl Wake for WakeCounter {
    fn wake(self: Arc<Self>) {
        self.wakes.fetch_add(1, Ordering::SeqCst);
    }

    fn wake_by_ref(self: &Arc<Self>) {
        self.wakes.fetch_add(1, Ordering::SeqCst);
    }
}

fn new_count_waker() -> (Waker, Arc<WakeCounter>) {
    let counter = Arc::new(WakeCounter::default());
    (Waker::from(counter.clone()), counter)
}

/// Rejected early handles can outlive rejection while their stream IDs are reused. Operations
/// on those handles must leave the replacement's state and readiness registrations alone.
#[tokio::test]
async fn rejected_early_handles_leave_replacement_streams_untouched() {
    timeout(Duration::from_secs(20), async {
        let factory = EndpointFactory::new();
        let endpoint = factory.endpoint();
        let addr = endpoint.local_addr().unwrap();
        let first = endpoint.connect(addr, "localhost").unwrap();
        let (client, server) = join!(first, async { endpoint.accept().await.unwrap().await });
        let client = client.unwrap();
        let server = server.unwrap();
        // An application response arrives after the server's session tickets, priming 0-RTT.
        let mut response = server.open_uni().await.unwrap();
        response.write_all(b"ticket").await.unwrap();
        response.finish().unwrap();
        let mut received = client.accept_uni().await.unwrap();
        assert_eq!(received.read_to_end(64).await.unwrap(), b"ticket");
        client.close(0u32, b"primed");
        drop((response, received, client, server));
        endpoint.wait_idle().await;

        // The same identity with a fresh session store rejects the client's cached early data.
        endpoint.set_server_config(Some(test_helpers::server(&factory.identity)));
        let (client, accepted) = endpoint
            .connect(addr, "localhost")
            .unwrap()
            .into_0rtt()
            .unwrap_or_else(|_| panic!("a cached early-data ticket"));
        let (mut old_send, old_recv) = client.open_bi().await.unwrap();
        let old_id = old_send.id();
        let (accepted, server) = join!(accepted, async { endpoint.accept().await.unwrap().await });
        assert!(!accepted.unwrap(), "the early data was rejected");
        let server = server.unwrap();
        let (mut send, mut recv) = client.open_bi().await.unwrap();
        assert_eq!(
            send.id(),
            old_id,
            "the early stream's numeric ID was reused"
        );
        send.set_priority(7).unwrap();
        old_send.set_priority(19).unwrap_err();
        old_send.priority().unwrap_err();
        assert_eq!(send.priority().unwrap(), 7);
        old_send.finish().unwrap_err();
        send.write_all(b"request").await.unwrap();

        let (reader_waker, reader_wakes) = new_count_waker();
        let mut reader_cx = Context::from_waker(&reader_waker);
        let mut read_buf = [0; 1];
        assert!(recv.poll_read(&mut reader_cx, &mut read_buf).is_pending());
        drop(old_recv);

        // Make the replacement writer block without yielding, then drop its rejected namesake.
        client.set_send_window(0);
        let (writer_waker, writer_wakes) = new_count_waker();
        let mut writer_cx = Context::from_waker(&writer_waker);
        assert!(
            std::pin::Pin::new(&mut send)
                .poll_write(&mut writer_cx, b"x")
                .is_pending()
        );
        drop(old_send);
        client.set_send_window(1024);

        let (mut answer, mut request) = server.accept_bi().await.unwrap();
        assert_eq!(request.read(&mut [0; 7]).await.unwrap(), Some(7));
        answer.write_all(b"a").await.unwrap();
        answer.finish().unwrap();
        // Advance the drivers without manually re-polling the blocked stream futures.
        while reader_wakes.wakes() == 0 || writer_wakes.wakes() == 0 {
            tokio::task::yield_now().await;
        }
        assert_eq!(recv.read(&mut read_buf).await.unwrap(), Some(1));
        assert_eq!(read_buf, [b'a']);
        send.write_all(b"x").await.unwrap();
        endpoint.shutdown().await;
    })
    .await
    .expect("rejected handles do not strand replacement streams");
}
