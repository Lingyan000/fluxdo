//! Rama's HTTP/3 scenarios over every pairing of rama's and Quinn's QUIC stacks, and with
//! reversed roles. The Quinn side goes through the adapter in `common::quinn_h3`.

mod common;

use std::{
    any::Any,
    error::Error,
    iter::successors,
    pin::pin,
    sync::{Arc, Weak},
    time::Duration,
};

use rama::{
    bytes::Bytes,
    error::BoxError,
    extensions::{Extensions, ExtensionsRef as _},
    futures::{future::join_all, stream},
    http::{
        Body, Method, Request, Response, StatusCode, Version,
        body::util::BodyExt,
        client::{
            Http3Transport, HttpConnectRequestAdapter, HttpConnector, HttpPooledConnectorConfig,
            http_connect,
        },
        core::h3::{
            Error as H3Error, client,
            connection::Config,
            server,
            transport::{
                BiReservation as _, BoxedConnection, Connection, RecvStream as _, ReserveBiStreams,
                Reversed, SendStream as _,
            },
        },
        datagram::{DatagramTransport, HttpDatagramSession, SessionEvent},
        io::upgrade::handle_upgrade,
        proto::{
            ext::{HttpDatagrams, Protocol},
            h3::Code,
        },
    },
    net::{
        client::{
            ConnectRequest, ConnectionError, EstablishedClientConnection,
            pool::{ConnectionReuse, ConnectionReusePolicy, ReuseKey},
        },
        uri::Uri,
    },
    quic::{self as rq, proto::VarInt},
    rt::{Executor, spawn},
    service::service_fn,
    utils::reactive::{Change, ChangeListener},
};
use tokio::{
    io::{AsyncReadExt as _, AsyncWriteExt as _},
    time::timeout,
};

use common::{
    LIMIT, identity, localhost,
    quinn_h3::{
        Limits, Quinn, anchor, h3_quinn_client_config, h3_quinn_server_config,
        h3_rama_client_config, h3_rama_server_config,
    },
    step,
};
use interop_common::scenario::SERVER_NAME;

/// The end that serves HTTP/3, the end that sends the requests, and the endpoints that keep
/// both alive.
struct Pair<S, C> {
    served: S,
    sending: C,
    _endpoints: Box<dyn Any + Send>,
}

async fn rama_and_rama() -> Pair<rq::Connection, rq::Connection> {
    let identity = identity();
    let server = rq::Endpoint::bind_server(
        Executor::new(),
        h3_rama_server_config(&identity),
        localhost(),
    )
    .await
    .expect("the rama server binds");
    let address = server.local_addr().expect("a local address");
    let client = rq::Endpoint::bind_client(Executor::new(), localhost())
        .await
        .expect("the rama client binds");
    let (served, sending) = step("connect", async {
        tokio::join!(
            async {
                server
                    .accept()
                    .await
                    .expect("an attempt")
                    .await
                    .expect("accepted")
            },
            async {
                client
                    .connect_with(
                        h3_rama_client_config(anchor(&identity)),
                        address,
                        SERVER_NAME,
                    )
                    .expect("the attempt starts")
                    .await
                    .expect("connected")
            },
        )
    })
    .await;
    Pair {
        served,
        sending,
        _endpoints: Box::new((server, client)),
    }
}

/// Rama's QUIC server, Quinn's QUIC client.
async fn rama_server_quinn_client() -> (rq::Connection, quinn::Connection, Box<dyn Any + Send>) {
    rama_server_quinn_client_with(|config| config).await
}

async fn rama_server_quinn_client_with(
    configure: impl FnOnce(rq::ServerConfig) -> rq::ServerConfig,
) -> (rq::Connection, quinn::Connection, Box<dyn Any + Send>) {
    let identity = identity();
    let server = rq::Endpoint::bind_server(
        Executor::new(),
        configure(h3_rama_server_config(&identity)),
        localhost(),
    )
    .await
    .expect("the rama server binds");
    let address = server.local_addr().expect("a local address");
    let client = quinn::Endpoint::client(localhost()).expect("the quinn client binds");
    let (rama, quinn) = step("connect", async {
        tokio::join!(
            async {
                server
                    .accept()
                    .await
                    .expect("an attempt")
                    .await
                    .expect("accepted")
            },
            async {
                client
                    .connect_with(
                        h3_quinn_client_config(anchor(&identity)),
                        address,
                        SERVER_NAME,
                    )
                    .expect("the attempt starts")
                    .await
                    .expect("connected")
            },
        )
    })
    .await;
    (rama, quinn, Box::new((server, client)))
}

async fn rama_serves_quinn_sends() -> Pair<rq::Connection, Quinn> {
    let (served, sending, endpoints) = rama_server_quinn_client().await;
    Pair {
        served,
        sending: Quinn::new(sending, Limits::DEFAULTS),
        _endpoints: endpoints,
    }
}

/// Quinn's QUIC server, rama's QUIC client.
async fn quinn_server_rama_client() -> (quinn::Connection, rq::Connection, Box<dyn Any + Send>) {
    let identity = identity();
    let server = quinn::Endpoint::server(h3_quinn_server_config(&identity), localhost())
        .expect("the quinn server binds");
    let address = server.local_addr().expect("a local address");
    let client = rq::Endpoint::bind_client(Executor::new(), localhost())
        .await
        .expect("the rama client binds");
    let (quinn, rama) = step("connect", async {
        tokio::join!(
            async {
                server
                    .accept()
                    .await
                    .expect("an attempt")
                    .await
                    .expect("accepted")
            },
            async {
                client
                    .connect_with(
                        h3_rama_client_config(anchor(&identity)),
                        address,
                        SERVER_NAME,
                    )
                    .expect("the attempt starts")
                    .await
                    .expect("connected")
            },
        )
    })
    .await;
    (quinn, rama, Box::new((server, client)))
}

async fn quinn_serves_rama_sends() -> Pair<Quinn, rq::Connection> {
    let (served, sending, endpoints) = quinn_server_rama_client().await;
    Pair {
        served: Quinn::new(served, Limits::DEFAULTS),
        sending,
        _endpoints: endpoints,
    }
}

/// The QUIC client (Quinn) serves HTTP/3, the QUIC server (rama) sends the requests.
async fn reversed_quinn_serves_rama_sends() -> Pair<Reversed<Quinn>, Reversed<rq::Connection>> {
    let (quic_server, quic_client, endpoints) = rama_server_quinn_client().await;
    Pair {
        served: Reversed::new(Quinn::new(quic_client, Limits::DEFAULTS)),
        sending: Reversed::new(quic_server),
        _endpoints: endpoints,
    }
}

/// The QUIC client (rama) serves HTTP/3, the QUIC server (Quinn) sends the requests.
async fn reversed_rama_serves_quinn_sends() -> Pair<Reversed<rq::Connection>, Reversed<Quinn>> {
    let (quic_server, quic_client, endpoints) = quinn_server_rama_client().await;
    Pair {
        served: Reversed::new(quic_client),
        sending: Reversed::new(Quinn::new(quic_server, Limits::DEFAULTS)),
        _endpoints: endpoints,
    }
}

/// Every scenario over every pairing, each on a fresh connection pair.
macro_rules! scenarios {
    ($($pairing:ident),* $(,)?) => {$(
        mod $pairing {
            #[tokio::test]
            async fn requests() {
                let pair = super::$pairing().await;
                super::timeout(3 * super::LIMIT, super::requests(pair.served, pair.sending))
                    .await
                    .expect("the scenario ends after its steps");
            }

            #[tokio::test]
            async fn large_bodies() {
                let pair = super::$pairing().await;
                super::timeout(3 * super::LIMIT, super::large_bodies(pair.served, pair.sending))
                    .await
                    .expect("the scenario ends after its steps");
            }

            #[tokio::test]
            async fn cancellation() {
                let pair = super::$pairing().await;
                super::timeout(3 * super::LIMIT, super::cancellation(pair.served, pair.sending))
                    .await
                    .expect("the scenario ends after its steps");
            }

            #[tokio::test]
            async fn goaway() {
                let pair = super::$pairing().await;
                super::timeout(3 * super::LIMIT, super::goaway(pair.served, pair.sending))
                    .await
                    .expect("the scenario ends after its steps");
            }

            #[tokio::test]
            async fn connect_tunnel() {
                let pair = super::$pairing().await;
                super::timeout(3 * super::LIMIT, super::connect_tunnel(pair.served, pair.sending))
                    .await
                    .expect("the scenario ends after its steps");
            }

            #[tokio::test]
            async fn datagrams() {
                let pair = super::$pairing().await;
                super::timeout(3 * super::LIMIT, super::datagrams(pair.served, pair.sending))
                    .await
                    .expect("the scenario ends after its steps");
            }

            #[tokio::test]
            async fn backend_client() {
                let pair = super::$pairing().await;
                super::timeout(3 * super::LIMIT, super::backend_client(pair.served, pair.sending))
                    .await
                    .expect("the scenario ends after its steps");
            }

            #[tokio::test]
            async fn pooled_backend_client() {
                let pair = super::$pairing().await;
                super::timeout(3 * super::LIMIT, super::pooled_backend_client(pair.served, pair.sending))
                    .await
                    .expect("the scenario ends after its steps");
            }
        }
    )*};
}

scenarios!(
    rama_and_rama,
    rama_serves_quinn_sends,
    quinn_serves_rama_sends,
    reversed_quinn_serves_rama_sends,
    reversed_rama_serves_quinn_sends,
);

fn start<S: Connection, C: Connection>(
    served: S,
    sending: C,
    server_config: Config,
) -> (client::SendRequest<Body, C>, server::Connection<S>) {
    let (server, driver) =
        server::handshake(served, server_config).expect("the server handshake starts");
    spawn(driver.run());
    let (client, driver) =
        client::handshake::<Body, _>(sending, Config::default(), Executor::new())
            .expect("the client handshake starts");
    spawn(driver.run());
    (client, server)
}

fn post(path: &str, body: Body) -> Request<Body> {
    Request::builder()
        .method(Method::POST)
        .uri(format!("https://localhost{path}"))
        .body(body)
        .expect("a request")
}

/// Answer each request with its path followed by its body.
async fn echo<S: Connection>(server: &mut server::Connection<S>) {
    let (request, response) = server
        .accept()
        .await
        .expect("a request")
        .resolve()
        .await
        .expect("its head");
    let mut reply = request.uri().request_target().to_string().into_bytes();
    let body = request.into_body().collect().await.expect("a body");
    reply.extend_from_slice(&body.to_bytes());
    response
        .send_response(Response::new(Body::from(reply)))
        .await
        .expect("the response is sent");
}

async fn body_of(response: Response<rama::http::core::body::Incoming>) -> Bytes {
    step("body", response.into_body().collect())
        .await
        .expect("a body")
        .to_bytes()
}

async fn requests(served: impl Connection, sending: impl Connection) {
    let (mut client, mut server) = start(served, sending, Config::default());
    let serve = spawn(async move {
        for _ in 0..2 {
            echo(&mut server).await;
        }
    });
    for path in ["/first", "/second"] {
        let response = step(
            "request",
            client.send_request(post(path, Body::from(" across stacks"))),
        )
        .await
        .expect("a response");
        assert_eq!(body_of(response).await, format!("{path} across stacks"));
    }
    step("serve", serve).await.expect("the server task");
}

async fn large_bodies(served: impl Connection, sending: impl Connection) {
    let (mut client, mut server) = start(served, sending, Config::default());
    let serve = spawn(async move { echo(&mut server).await });
    let payload: Bytes = (0..4 * 1024 * 1024).map(|i| (i % 251) as u8).collect();
    let response = step(
        "request",
        client.send_request(post("/large", Body::from(payload.clone()))),
    )
    .await
    .expect("a response");
    let body = body_of(response).await;
    assert_eq!(&body[..b"/large".len()], b"/large");
    assert!(
        body[b"/large".len()..] == payload[..],
        "the echoed body differs"
    );
    step("serve", serve).await.expect("the server task");
}

async fn cancellation(served: impl Connection, sending: impl Connection) {
    let (client, mut server) = start(served, sending, Config::default());
    // A body that never ends keeps the request open until the client gives up on it.
    let endless = Body::from_stream(stream::pending::<Result<Bytes, BoxError>>());
    let abandoned = spawn({
        let mut client = client.clone();
        async move { client.send_request(post("/abandoned", endless)).await }
    });
    let (request, _response) = step("abandoned head", async {
        server.accept().await.expect("a request").resolve().await
    })
    .await
    .expect("its head");
    abandoned.abort();
    let cancelled = step("cancelled body", request.into_body().collect())
        .await
        .expect_err("the abandoned body completed");
    let reset = successors(Some(&cancelled as &dyn Error), |&error| error.source())
        .find_map(|error| error.downcast_ref::<H3Error>())
        .expect("an h3 error");
    assert_eq!(reset.code(), Code::H3_REQUEST_CANCELLED);
    // A local "closed" fallback carries the same code; only the peer's reset is remote.
    assert!(reset.is_remote_failure(), "{reset:?}");

    // The connection carries on.
    let serve = spawn(async move { echo(&mut server).await });
    let mut client = client;
    let response = step(
        "request",
        client.send_request(post("/after", Body::empty())),
    )
    .await
    .expect("a response");
    assert_eq!(body_of(response).await, "/after");
    step("serve", serve).await.expect("the server task");
}

async fn goaway(served: impl Connection, sending: impl Connection) {
    let (mut client, mut server) = start(served, sending, Config::default());
    let in_flight = spawn({
        let mut client = client.clone();
        async move { client.send_request(post("/in-flight", Body::empty())).await }
    });
    let (request, response) = step("in-flight head", async {
        server.accept().await.expect("a request").resolve().await
    })
    .await
    .expect("its head");
    server.shutdown().expect("the GOAWAY is queued");
    let draining = step("draining", client.closed_or_draining()).await;
    assert!(draining.is_rejected(), "{draining:?}");
    let refused = step(
        "late request",
        client.send_request(post("/late", Body::empty())),
    )
    .await
    .expect_err("a request after GOAWAY");
    assert!(refused.is_rejected(), "{refused:?}");
    drop(request);
    step(
        "in-flight response sent",
        response.send_response(Response::new(Body::from("finished"))),
    )
    .await
    .expect("the response is sent");
    let finished = step("in-flight response", in_flight)
        .await
        .expect("the client task")
        .expect("a response");
    assert_eq!(body_of(finished).await, "finished");
    step("drained", server.drained()).await.expect("drained");
}

async fn connect_tunnel(served: impl Connection, sending: impl Connection) {
    let (mut client, mut server) = start(served, sending, Config::default());
    let serve = spawn(async move {
        let (request, response) = server
            .accept()
            .await
            .expect("a CONNECT")
            .resolve()
            .await
            .expect("its head");
        let upgrade = handle_upgrade(&request);
        response
            .send_response(Response::new(Body::empty()))
            .await
            .expect("the response is sent");
        let mut tunnel = upgrade.await.expect("the server tunnel");
        let mut received = [0; 4];
        tunnel
            .read_exact(&mut received)
            .await
            .expect("client bytes");
        assert_eq!(&received, b"ping");
        tunnel.write_all(b"pong").await.expect("server bytes");
        tunnel.shutdown().await.expect("the server half closes");
        // Keep the server connection until the client has read the answer.
        let mut rest = Vec::new();
        tunnel
            .read_to_end(&mut rest)
            .await
            .expect("the client half close");
        server
    });
    let connect = Request::builder()
        .method(Method::CONNECT)
        .uri(Uri::parse_http_request_target("localhost:443", true).expect("an authority"))
        .body(Body::empty())
        .expect("a CONNECT");
    let response = step("CONNECT", client.send_request(connect))
        .await
        .expect("a response");
    assert_eq!(response.status(), StatusCode::OK);
    let mut tunnel = step("client tunnel", handle_upgrade(response))
        .await
        .expect("the client tunnel");
    step("client bytes", tunnel.write_all(b"ping"))
        .await
        .expect("client bytes");
    let mut received = [0; 4];
    step("server bytes", tunnel.read_exact(&mut received))
        .await
        .expect("server bytes");
    assert_eq!(&received, b"pong");
    step("client half close", tunnel.shutdown())
        .await
        .expect("the client half closes");
    drop(step("serve", serve).await.expect("the server task"));
}

async fn datagrams(served: impl Connection, sending: impl Connection) {
    let server_config = Config {
        extended_connect: true,
        datagrams: Some(Default::default()),
        ..Config::default()
    };
    let (mut client, mut server) = start(served, sending, server_config);
    let accept = async {
        let (request, response) = server
            .accept()
            .await
            .expect("an Extended CONNECT")
            .resolve()
            .await
            .expect("its head");
        let upgrade = handle_upgrade(&request);
        let accepted = Response::new(Body::empty());
        accepted.extensions().insert(HttpDatagrams);
        response
            .send_response(accepted)
            .await
            .expect("the response is sent");
        upgrade.await.expect("the server tunnel")
    };
    let request = Request::builder()
        .method(Method::CONNECT)
        .uri("https://localhost/datagrams")
        .body(Body::empty())
        .expect("an Extended CONNECT");
    request
        .extensions()
        .insert(Protocol::from_static("x-interop-datagrams"));
    request.extensions().insert(HttpDatagrams);
    let (response, server_io) = step("tunnel", async {
        tokio::join!(client.send_request(request), accept)
    })
    .await;
    let response = response.expect("a response");
    assert_eq!(response.status(), StatusCode::OK);
    let client_io = step("client tunnel", handle_upgrade(&response))
        .await
        .expect("the client tunnel");
    let mut client_session = HttpDatagramSession::new(client_io);
    let mut server_session = HttpDatagramSession::new(server_io);
    step("native ready", async {
        for session in [&client_session, &server_session] {
            while session
                .native()
                .and_then(|native| native.channel().max_payload_size())
                .is_none()
            {
                tokio::time::sleep(Duration::from_millis(1)).await;
            }
        }
    })
    .await;
    step(
        "client datagram sent",
        client_session.send_datagram(Bytes::from_static(b"ping")),
    )
    .await
    .expect("a datagram sent");
    assert_eq!(
        step("server datagram", server_session.recv())
            .await
            .expect("a datagram"),
        Some(SessionEvent::Datagram {
            payload: Bytes::from_static(b"ping"),
            transport: DatagramTransport::Native,
        })
    );
    step(
        "server datagram sent",
        server_session.send_datagram(Bytes::from_static(b"pong")),
    )
    .await
    .expect("a datagram sent");
    assert_eq!(
        step("client datagram", client_session.recv())
            .await
            .expect("a datagram"),
        Some(SessionEvent::Datagram {
            payload: Bytes::from_static(b"pong"),
            transport: DatagramTransport::Native,
        })
    );
}

/// rama's HTTP client service over the sending end, boxed like the backend boxes any transport.
async fn backend_client(served: impl Connection, sending: impl ReserveBiStreams) {
    let (mut server, driver) =
        server::handshake(served, Config::default()).expect("the server handshake starts");
    spawn(driver.run());
    let serve = spawn(async move {
        for _ in 0..2 {
            echo(&mut server).await;
        }
    });
    let transport = Http3Transport {
        connection: BoxedConnection::new(sending),
        config: Arc::new(Config::default()),
    };
    let handshake = Request::builder()
        .version(Version::HTTP_3)
        .uri("https://localhost/")
        .body(Body::empty())
        .expect("a request");
    let client = step(
        "connect",
        http_connect::<_, _, Body>(transport, handshake, Executor::new()),
    )
    .await
    .expect("an HTTP/3 client service")
    .conn;
    for path in ["/first", "/second"] {
        let mut request = post(path, Body::from(" through the backend"));
        *request.version_mut() = Version::HTTP_3;
        let response = step("request", rama::Service::serve(&client, request))
            .await
            .expect("a response");
        let body = step("body", response.into_body().collect())
            .await
            .expect("a body")
            .to_bytes();
        assert_eq!(body, format!("{path} through the backend"));
    }
    step("serve", serve).await.expect("the server task");
}

/// rama's pooled HTTP client over the sending end: concurrent requests share the one
/// connection, admitted through its stream credit behind [`BoxedConnection`].
async fn pooled_backend_client(served: impl Connection, sending: impl ReserveBiStreams) {
    const REQUESTS: usize = 4;
    let (mut server, driver) =
        server::handshake(served, Config::default()).expect("the server handshake starts");
    spawn(driver.run());
    let serve = spawn(async move {
        for _ in 0..REQUESTS {
            echo(&mut server).await;
        }
    });
    let sending = Arc::new(parking_lot::Mutex::new(Some(sending)));
    let connector = service_fn(move |input: ConnectRequest| {
        let connection = sending.lock().take().expect("the pool dials once");
        connection
            .extensions()
            .insert(ConnectionReuse::new(SingleOrigin));
        async move {
            Ok::<_, ConnectionError>(EstablishedClientConnection {
                conn: Http3Transport {
                    connection: BoxedConnection::new(connection),
                    config: Arc::new(Config::default()),
                },
                input,
            })
        }
    });
    let client = HttpConnectRequestAdapter::new(
        HttpPooledConnectorConfig::default()
            .build_connector(HttpConnector::<_, Body>::new(connector, Executor::new())),
    );
    let requests = (0..REQUESTS).map(|index| {
        let client = &client;
        async move {
            let path = format!("/{index}");
            let mut request = post(&path, Body::from(" through the pool"));
            *request.version_mut() = Version::HTTP_3;
            let EstablishedClientConnection { conn, input } = rama::Service::serve(client, request)
                .await
                .expect("a pooled connection");
            let response = rama::Service::serve(&conn, input)
                .await
                .expect("a response");
            let body = step("body", response.into_body().collect())
                .await
                .expect("a body")
                .to_bytes();
            assert_eq!(body, format!("{path} through the pool"));
        }
    });
    step("pooled requests", join_all(requests)).await;
    step("serve", serve).await.expect("the server task");
}

/// The pool's connector always reaches the same origin.
#[derive(Debug)]
struct SingleOrigin;

impl ConnectionReusePolicy for SingleOrigin {
    fn classifier(&self) -> ReuseKey {
        ReuseKey::of::<Self>()
    }

    fn connection_key(&self) -> Option<ReuseKey> {
        Some(ReuseKey::of::<Self>())
    }

    fn request_key(&self, _: &Extensions) -> Option<ReuseKey> {
        self.connection_key()
    }
}

#[tokio::test]
async fn quinn_budget_listener_hears_every_freed_stream_and_the_close() {
    let (served, sending, _endpoints) = rama_server_quinn_client_with(|config| {
        config.with_transport_config(Arc::new(
            rq::TransportConfig::default().with_max_concurrent_bidi_streams(1u32),
        ))
    })
    .await;
    let accepting = served.clone();
    spawn(async move { while accepting.accept_bi().await.is_ok() {} });
    let quinn = Quinn::new(sending, Limits::DEFAULTS);
    let listener = Arc::new(Recorder::default());
    let weak: Weak<dyn ChangeListener> = Arc::downgrade(&listener) as _;
    quinn.subscribe_bi_stream_budget(weak);

    for freed in 1..=3 {
        step(
            "freed credit",
            listener.until(|changes| changes.len() >= freed),
        )
        .await;
        let (mut send, mut recv) = quinn
            .try_reserve_bi()
            .expect("an open connection")
            .expect("the freed credit")
            .open()
            .expect("an opened stream");
        send.reset(VarInt::from_u32(0)).expect("an open send side");
        recv.stop(VarInt::from_u32(0))
            .expect("an open receive side");
    }
    step("freed credit", listener.until(|changes| changes.len() >= 4)).await;
    let unused = quinn
        .try_reserve_bi()
        .expect("an open connection")
        .expect("the freed credit");
    drop(unused);
    assert_eq!(listener.changes(), [Change::Freed; 5]);

    served.close(0u32, b"done");
    step(
        "close",
        listener.until(|changes| changes.last() == Some(&Change::Other)),
    )
    .await;
}

#[derive(Default)]
struct Recorder {
    changes: parking_lot::Mutex<Vec<Change>>,
    changed: tokio::sync::Notify,
}

impl Recorder {
    fn changes(&self) -> Vec<Change> {
        self.changes.lock().clone()
    }

    async fn until(&self, done: impl Fn(&[Change]) -> bool) {
        loop {
            let mut changed = pin!(self.changed.notified());
            changed.as_mut().enable();
            if done(&self.changes.lock()) {
                return;
            }
            changed.await;
        }
    }
}

impl ChangeListener for Recorder {
    fn changed(&self, change: Change) {
        self.changes.lock().push(change);
        self.changed.notify_waiters();
    }
}
