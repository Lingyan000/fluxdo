//! Real QUIC round trips complement deterministic framing/cancellation tests.
mod cancellation;
mod close;
mod credit;
mod critical_streams;
mod datagram;
mod demux;
mod extended_connect;
mod fairness;
mod framing;
mod insertion;
mod loss;
mod observation;
mod qlog;
mod reversed;
mod robustness;
mod settings_profile;
mod timeouts;
mod transport;

use std::{assert_matches, num::NonZeroUsize, sync::Arc, time::Duration};

use rama_core::{
    bytes::Bytes,
    extensions::{Extension, ExtensionsRef as _},
    rt::{Executor, spawn},
};
use rama_http_types::{
    Body, HeaderMap, HeaderName, HeaderValue, Method, Request, Response, Version,
    body::{Frame, util::BodyExt},
    header,
    proto::{
        RequestHeaders,
        h3::{
            Code,
            critical_streams::{Order, Preferences, Startup},
        },
    },
};
use rama_net::{address::SocketAddress, stream::SocketInfo};
use rama_quic::{Endpoint, NegotiatedTlsParameters, TransportConfig, tls::TlsOptions};
use rama_tls::{
    client::TlsClientConfig,
    server::{GeneratedServerAuthConfig, ServerAuthData, TlsServerConfig},
};
use rama_udp::test_utils::{MemoryDatagramControl, MemoryDatagramSocket};

use super::{client, connection::Config, server};

const LIMIT: Duration = Duration::from_secs(20);

pub(super) struct Pair {
    client_endpoint: Endpoint,
    server_endpoint: Endpoint,
    pub(super) client: rama_quic::Connection,
    pub(super) server: rama_quic::Connection,
    datagram_faults: Option<[MemoryDatagramControl; 2]>,
}

impl Pair {
    async fn new(
        client_transport: Option<TransportConfig>,
        server_transport: Option<TransportConfig>,
    ) -> Self {
        Self::build(client_transport, server_transport, None, false).await
    }

    pub(super) async fn in_memory(
        client_transport: Option<TransportConfig>,
        server_transport: Option<TransportConfig>,
    ) -> Self {
        Self::build(
            client_transport,
            server_transport,
            Some(NonZeroUsize::MIN),
            false,
        )
        .await
    }

    async fn impaired() -> Self {
        Self::build(None, None, NonZeroUsize::new(4), false).await
    }

    async fn build(
        client_transport: Option<TransportConfig>,
        server_transport: Option<TransportConfig>,
        memory_capacity: Option<NonZeroUsize>,
        capture: bool,
    ) -> Self {
        let identity = ServerAuthData::new_generated(GeneratedServerAuthConfig::default()).unwrap();
        let server_tls = TlsServerConfig::new()
            .with_alpn([b"h3".as_slice().into()].into_iter().collect())
            .with_server_auth(identity.clone());
        let client_tls = TlsClientConfig::new()
            .with_alpn([b"h3".as_slice().into()].into_iter().collect())
            .with_store_server_cert_chain(true)
            .try_with_server_trust_anchors([identity.cert_chain.last().unwrap().clone()])
            .unwrap();
        // Select explicitly: dev-dependencies also enable Rustls, whose default
        // would otherwise silently make the Boring test run exercise Rustls.
        let (client_provider, server_provider) = rama_quic::test_utils::tls_providers().unwrap();
        let mut server_config = rama_quic::ServerConfig::try_from_rama_tls_with_provider(
            &server_tls,
            TlsOptions::default(),
            server_provider.as_ref(),
        )
        .unwrap();
        if capture {
            server_config.set_capture(Default::default());
        }
        let mut client_config = rama_quic::ClientConfig::try_from_rama_tls_with_provider(
            &client_tls,
            TlsOptions::default(),
            client_provider.as_ref(),
        )
        .unwrap();
        let default_transport = || {
            let mut transport = TransportConfig::default();
            Config::default()
                .configure_transport(&mut transport)
                .unwrap();
            transport
        };
        server_config
            .set_transport_config(Arc::new(server_transport.unwrap_or_else(default_transport)));
        client_config
            .set_transport_config(Arc::new(client_transport.unwrap_or_else(default_transport)));
        let server = Endpoint::build(Executor::new()).with_server_config(server_config);
        let client = Endpoint::build(Executor::new());
        let (server_endpoint, client_endpoint, datagram_faults) =
            if let Some(capacity) = memory_capacity {
                let (server_socket, client_socket) = MemoryDatagramSocket::pair(
                    SocketAddress::local_ipv4(443),
                    SocketAddress::local_ipv4(444),
                    capacity,
                );
                // Small queues force the real driver through send backpressure.
                server_socket.set_max_send_segments(NonZeroUsize::MIN);
                let faults = [client_socket.fault_control(), server_socket.fault_control()];
                (
                    server.with_datagram_socket(server_socket).unwrap(),
                    client.with_datagram_socket(client_socket).unwrap(),
                    Some(faults),
                )
            } else {
                let localhost = SocketAddress::local_ipv4(0);
                (
                    server.bind_address(localhost).await.unwrap(),
                    client.bind_address(localhost).await.unwrap(),
                    None,
                )
            };
        let accept = spawn({
            let endpoint = server_endpoint.clone();
            async move { endpoint.accept().await.unwrap().await.unwrap() }
        });
        let client = client_endpoint
            .connect_with(
                client_config,
                server_endpoint.local_addr().unwrap(),
                "localhost",
            )
            .unwrap()
            .await
            .unwrap();
        let server = accept.await.unwrap();
        Self {
            client_endpoint,
            server_endpoint,
            client,
            server,
            datagram_faults,
        }
    }

    pub(super) async fn close(self) {
        self.client.close(0u32, b"test complete");
        tokio::join!(
            self.client_endpoint.shutdown(),
            self.server_endpoint.shutdown()
        );
    }
}

#[tokio::test]
async fn dropping_last_client_sender_stops_its_driver() {
    tokio::time::timeout(LIMIT, async {
        let pair = Pair::new(None, None).await;
        let (client, driver) =
            client::handshake::<Body, _>(pair.client.clone(), Config::default(), Executor::new())
                .unwrap();
        let driver = spawn(driver.run());
        let clone = client.clone();
        drop(client);
        assert!(pair.client.close_reason().is_none());
        drop(clone);
        // Extra transport handles must not keep the detached H3 driver alive.
        assert!(pair.client.close_reason().is_some());
        _ = driver.await.unwrap();
        pair.close().await;
    })
    .await
    .unwrap();
}

#[tokio::test]
async fn response_body_keeps_driver_alive_after_client_sender_drop() {
    tokio::time::timeout(LIMIT, async {
        let pair = Pair::new(None, None).await;
        let (mut client, client_driver) =
            client::handshake::<Body, _>(pair.client.clone(), Config::default(), Executor::new())
                .unwrap();
        let (mut server, server_driver) =
            server::handshake(pair.server.clone(), Config::default()).unwrap();
        let client_driver = spawn(client_driver.run());
        let server_driver = spawn(server_driver.run());
        let serve = spawn(async move {
            let (request, response) = server.accept().await.unwrap().resolve().await.unwrap();
            request.into_body().collect().await.unwrap();
            response
                .send_response(Response::new(Body::from("still readable")))
                .await
                .unwrap();
        });
        let response = client
            .send_request(
                Request::builder()
                    .uri("https://localhost/")
                    .body(Body::empty())
                    .unwrap(),
            )
            .await
            .unwrap();
        drop(client);
        assert!(pair.client.close_reason().is_none());
        assert_eq!(
            response.into_body().collect().await.unwrap().to_bytes(),
            "still readable"
        );
        serve.await.unwrap();
        _ = client_driver.await.unwrap();
        _ = server_driver.await.unwrap();
        assert!(pair.client.close_reason().is_some());
        pair.close().await;
    })
    .await
    .unwrap();
}

#[tokio::test]
async fn streaming_round_trip_reuses_connection_and_dynamic_qpack() {
    tokio::time::timeout(LIMIT, async {
        let pair = Pair::new(None, None).await;
        let (mut client, client_driver) =
            client::handshake::<Body, _>(pair.client.clone(), Config::default(), Executor::new())
                .unwrap();
        let (mut server, server_driver) =
            server::handshake(pair.server.clone(), Config::default()).unwrap();
        let client_driver = spawn(client_driver.run());
        let server_driver = spawn(server_driver.run());
        let serve = spawn(async move {
            for _ in 0..3 {
                let (request, mut response) =
                    server.accept().await.unwrap().resolve().await.unwrap();
                assert_eq!(request.version(), Version::HTTP_3);
                assert_eq!(request.uri().request_target(), "/echo?x=1");
                let collected = request.into_body().collect().await.unwrap();
                assert_eq!(
                    collected.trailers().unwrap()["x-trailer"],
                    "request trailer"
                );
                let bytes = collected.to_bytes();
                response
                    .send_informational(Response::builder().status(103).body(()).unwrap())
                    .await
                    .unwrap();
                let mut trailers = rama_http_types::HeaderMap::new();
                trailers.insert("x-trailer", "response trailer".parse().unwrap());
                let body = Body::from_frame_stream(rama_core::futures::stream::iter([
                    Ok::<_, std::convert::Infallible>(Frame::data(bytes)),
                    Ok(Frame::trailers(trailers)),
                ]));
                response
                    .send_response(
                        Response::builder()
                            .header("x-repeated", "a value for dynamic compression")
                            .body(body)
                            .unwrap(),
                    )
                    .await
                    .unwrap();
            }
        });
        for _ in 0..3 {
            let mut trailers = rama_http_types::HeaderMap::new();
            trailers.insert("x-trailer", "request trailer".parse().unwrap());
            let body = Body::from_frame_stream(rama_core::futures::stream::iter([
                Ok::<_, std::convert::Infallible>(Frame::data(Bytes::from_static(
                    b"streaming request payload",
                ))),
                Ok(Frame::trailers(trailers)),
            ]));
            let request = Request::builder()
                .method("POST")
                .uri("https://localhost/echo?x=1")
                .version(Version::HTTP_3)
                .header("x-repeated", "another dynamic value")
                .body(body)
                .unwrap();
            let response = client.send_request(request).await.unwrap();
            assert_eq!(response.version(), Version::HTTP_3);
            let collected = response.into_body().collect().await.unwrap();
            assert_eq!(
                collected.trailers().unwrap()["x-trailer"],
                "response trailer"
            );
            assert_eq!(collected.to_bytes(), "streaming request payload");
        }
        assert!(client.dynamic_insert_count() > 0);
        serve.await.unwrap();
        pair.client.close(0u32, b"test complete");
        _ = client_driver.await.unwrap();
        _ = server_driver.await.unwrap();
        pair.close().await;
    })
    .await
    .unwrap();
}

/// Name, bytes and sensitivity of each field, in order.
fn field_lines(headers: &HeaderMap) -> Vec<(String, Vec<u8>, bool)> {
    headers
        .ordered_iter()
        .map(|(name, value)| {
            (
                name.as_str().to_owned(),
                value.as_bytes().to_vec(),
                value.is_sensitive(),
            )
        })
        .collect()
}

/// The response carries its request's fields as sent, line for line what the server
/// received: all of them, or without the connection-specific ones and an unusable
/// `Host`, with `TE` as the `trailers` it sends and a sensitive `TE` kept so.
#[tokio::test]
async fn request_headers_record_the_fields_as_sent() {
    let mut sensitive_te = HeaderValue::from_static("trailers");
    sensitive_te.set_sensitive(true);
    let mut sensitive_te_gzip = HeaderValue::from_static("trailers, gzip");
    sensitive_te_gzip.set_sensitive(true);
    let cases: Vec<Vec<(HeaderName, HeaderValue)>> = vec![
        vec![],
        vec![
            (header::CONNECTION, HeaderValue::from_static("keep-alive")),
            (
                HeaderName::from_static("keep-alive"),
                HeaderValue::from_static("timeout=5"),
            ),
            (header::TE, HeaderValue::from_static("trailers, gzip")),
        ],
        // One field each way, so only the rewritten `TE` value tells them apart.
        vec![(header::TE, HeaderValue::from_static("trailers, gzip"))],
        vec![(header::HOST, HeaderValue::from_static("not a host"))],
        vec![(header::TE, sensitive_te)],
        vec![(header::TE, sensitive_te_gzip)],
    ];

    tokio::time::timeout(LIMIT, async {
        let pair = Pair::new(None, None).await;
        let (mut client, client_driver) =
            client::handshake::<Body, _>(pair.client.clone(), Config::default(), Executor::new())
                .unwrap();
        let (mut server, server_driver) =
            server::handshake(pair.server.clone(), Config::default()).unwrap();
        let client_driver = spawn(client_driver.run());
        let server_driver = spawn(server_driver.run());
        let (received_tx, mut received_rx) = tokio::sync::mpsc::unbounded_channel();
        let requests = cases.len();
        let serve = spawn(async move {
            for _ in 0..requests {
                let (request, response) = server.accept().await.unwrap().resolve().await.unwrap();
                received_tx.send(field_lines(request.headers())).unwrap();
                response
                    .send_response(Response::new(Body::empty()))
                    .await
                    .unwrap();
            }
        });
        for case in cases {
            let mut request = Request::builder()
                .uri("https://localhost/")
                .header("x-a", "1")
                .body(Body::empty())
                .unwrap();
            for (name, value) in case {
                request.headers_mut().append(name, value);
            }
            let response = client.send_request(request).await.unwrap();
            let recorded = field_lines(response.extensions().get_ref::<RequestHeaders>().unwrap());
            assert_eq!(recorded, received_rx.recv().await.unwrap());
        }
        serve.await.unwrap();
        pair.client.close(0u32, b"test complete");
        _ = client_driver.await.unwrap();
        _ = server_driver.await.unwrap();
        pair.close().await;
    })
    .await
    .unwrap();
}

#[tokio::test]
async fn header_order_survives_transport_and_message_forwarding() {
    use rama_http_types::{
        HeaderMap, HeaderValue,
        header::trailer::ForbiddenTrailers,
        proto::h3::{PseudoHeader, PseudoHeaderOrder},
    };

    fn headers() -> HeaderMap {
        let mut headers = HeaderMap::new();
        headers.append("x-first", HeaderValue::from_static("Keep CASE"));
        headers.append("cookie", HeaderValue::from_static("a=1"));
        headers.append("x-first", HeaderValue::from_static("second"));
        let mut secret = HeaderValue::from_static("b=2");
        secret.set_sensitive(true);
        headers.append("cookie", secret);
        headers
    }

    fn assert_headers(actual: &HeaderMap) {
        let actual: Vec<_> = actual
            .ordered_iter()
            .map(|(name, value)| (name.as_str(), value.as_bytes(), value.is_sensitive()))
            .collect();
        let expected = headers();
        let expected: Vec<_> = expected
            .ordered_iter()
            .map(|(name, value)| (name.as_str(), value.as_bytes(), value.is_sensitive()))
            .collect();
        assert_eq!(actual, expected);
    }

    tokio::time::timeout(LIMIT, async {
        let pair = Pair::new(None, None).await;
        let (mut client, client_driver) =
            client::handshake::<Body, _>(pair.client.clone(), Config::default(), Executor::new())
                .unwrap();
        let (mut server, server_driver) =
            server::handshake(pair.server.clone(), Config::default()).unwrap();
        let client_driver = spawn(client_driver.run());
        let server_driver = spawn(server_driver.run());
        let order: PseudoHeaderOrder = [
            PseudoHeader::Path,
            PseudoHeader::Scheme,
            PseudoHeader::Method,
            PseudoHeader::Authority,
        ]
        .into_iter()
        .collect();
        let expected_order = order.clone();
        let serve = spawn(async move {
            let (request, response) = server.accept().await.unwrap().resolve().await.unwrap();
            assert_headers(request.headers());
            assert_eq!(
                request.extensions().get_ref::<PseudoHeaderOrder>(),
                Some(&expected_order)
            );
            let (parts, body) = request.into_parts();
            let body = body.collect().await.unwrap();
            assert_headers(body.trailers().unwrap());
            // Forward received field lines and trailer lines through a second QPACK encode.
            let trailers = body.trailers().unwrap().clone();
            let body = Body::from_frame_stream(rama_core::futures::stream::iter([
                Ok::<_, std::convert::Infallible>(Frame::data(body.to_bytes())),
                Ok(Frame::trailers(trailers)),
            ]));
            let mut reply = Response::new(body);
            *reply.headers_mut() = parts.headers;
            // A relay forwards `cookie` trailers as received.
            reply.extensions().insert(ForbiddenTrailers::AllowAll);
            response.send_response(reply).await.unwrap();
        });
        let body = Body::from_frame_stream(rama_core::futures::stream::iter([
            Ok::<_, std::convert::Infallible>(Frame::data(Bytes::from_static(b"body"))),
            Ok(Frame::trailers(headers())),
        ]));
        let mut request = Request::builder()
            .uri("https://localhost/")
            .body(body)
            .unwrap();
        *request.headers_mut() = headers();
        request.extensions().insert(order);
        request.extensions().insert(ForbiddenTrailers::AllowAll);
        let response = client.send_request(request).await.unwrap();
        assert_headers(response.headers());
        let body = response.into_body().collect().await.unwrap();
        assert_headers(body.trailers().unwrap());
        assert_eq!(body.to_bytes(), "body");
        serve.await.unwrap();
        pair.client.close(0u32, b"test complete");
        _ = client_driver.await.unwrap();
        _ = server_driver.await.unwrap();
        pair.close().await;
    })
    .await
    .unwrap();
}

#[tokio::test]
async fn idle_qpack_stream_stop_closes_connection() {
    tokio::time::timeout(LIMIT, async {
        let pair = Pair::new(None, None).await;
        let (_sender, driver) =
            client::handshake::<Body, _>(pair.client.clone(), Config::default(), Executor::new())
                .unwrap();
        let driver = spawn(driver.run());
        let mut kept = Vec::new();
        loop {
            let mut stream = pair.server.accept_uni().await.unwrap();
            let mut ty = [0];
            stream.read_exact(&mut ty).await.unwrap();
            if ty == [2] {
                stream.stop(0u32).unwrap();
                break;
            }
            kept.push(stream);
        }
        assert_eq!(
            driver.await.unwrap().unwrap_err().code(),
            Code::H3_CLOSED_CRITICAL_STREAM
        );
        pair.close().await;
    })
    .await
    .unwrap();
}

#[tokio::test]
async fn initial_request_error_closes_while_control_write_is_blocked() {
    tokio::time::timeout(LIMIT, async {
        let mut transport = TransportConfig::default();
        transport.set_stream_receive_window_uni(1u32.into());
        let pair = Pair::new(Some(transport), None).await;
        let (mut server, driver) =
            server::handshake(pair.server.clone(), Config::default()).unwrap();
        let driver = spawn(driver.run());
        let (mut send, _recv) = pair.client.open_bi().await.unwrap();
        send.write_all(&[0, 0]).await.unwrap(); // DATA before HEADERS.
        let error = server
            .accept()
            .await
            .unwrap()
            .resolve()
            .await
            .err()
            .unwrap();
        assert_eq!(error.code(), Code::H3_FRAME_UNEXPECTED);
        assert_eq!(
            driver.await.unwrap().unwrap_err().code(),
            Code::H3_FRAME_UNEXPECTED
        );
        pair.close().await;
    })
    .await
    .unwrap();
}

#[tokio::test]
async fn upload_error_does_not_wait_for_response_headers() {
    tokio::time::timeout(LIMIT, async {
        let pair = Pair::new(None, None).await;
        let (mut client, driver) =
            client::handshake::<Body, _>(pair.client.clone(), Config::default(), Executor::new())
                .unwrap();
        let driver = spawn(driver.run());
        let body = Body::from_stream(rama_core::futures::stream::iter([Err::<Bytes, _>(
            std::io::Error::other("body failed"),
        )]));
        let error = client
            .send_request(
                Request::builder()
                    .uri("https://localhost/")
                    .body(body)
                    .unwrap(),
            )
            .await
            .unwrap_err();
        assert_eq!(error.code(), Code::H3_INTERNAL_ERROR);
        driver.abort();
        _ = driver.await;
        pair.close().await;
    })
    .await
    .unwrap();
}

#[tokio::test]
async fn goaway_wakes_request_waiting_for_stream_credit() {
    tokio::time::timeout(LIMIT, async {
        let mut transport = TransportConfig::default();
        transport.set_max_concurrent_bidi_streams(0u32);
        let pair = Pair::new(None, Some(transport)).await;
        let (mut client, driver) =
            client::handshake::<Body, _>(pair.client.clone(), Config::default(), Executor::new())
                .unwrap();
        let driver = spawn(driver.run());
        let request = spawn(async move {
            client
                .send_request(
                    Request::builder()
                        .uri("https://localhost/")
                        .body(Body::empty())
                        .unwrap(),
                )
                .await
        });
        let mut control = pair.server.open_uni().await.unwrap();
        control.write_all(&[0, 4, 0, 7, 1, 0]).await.unwrap(); // Control, SETTINGS {}, GOAWAY 0.
        assert_eq!(
            request.await.unwrap().unwrap_err().code(),
            Code::H3_REQUEST_REJECTED
        );
        driver.abort();
        _ = driver.await;
        pair.close().await;
    })
    .await
    .unwrap();
}

#[tokio::test]
async fn connect_upgrade_keeps_half_closed_tunnel_alive() {
    use rama_http::io::upgrade::handle_upgrade;
    use tokio::io::{AsyncReadExt as _, AsyncWriteExt as _};
    tokio::time::timeout(LIMIT, async {
        let pair = Pair::new(None, None).await;
        let client_local = pair.client_endpoint.local_addr().unwrap().into();
        let server_local = pair.server_endpoint.local_addr().unwrap().into();
        for (connection, marker) in [(&pair.client, 1), (&pair.server, 2)] {
            connection.extensions().insert(ConnectionMetadata(marker));
        }
        let server_extensions = pair.server.extensions().clone();
        let (mut client, client_driver) =
            client::handshake::<Body, _>(pair.client.clone(), Config::default(), Executor::new())
                .unwrap();
        let (mut server, server_driver) =
            server::handshake(pair.server.clone(), Config::default()).unwrap();
        let client_driver = spawn(client_driver.run());
        let server_driver = spawn(server_driver.run());
        let serve = spawn(async move {
            let (request, mut response) = server.accept().await.unwrap().resolve().await.unwrap();
            assert_eq!(request.method(), Method::CONNECT);
            let upgrade = handle_upgrade(request);
            response
                .send_informational(Response::builder().status(103).body(()).unwrap())
                .await
                .unwrap();
            response
                .send_response(
                    Response::builder()
                        .status(201)
                        .header("content-length", "0")
                        .body(Body::empty())
                        .unwrap(),
                )
                .await
                .unwrap();
            let mut tunnel = upgrade.await.unwrap();
            assert_eq!(
                tunnel
                    .extensions()
                    .get_ref::<ConnectionMetadata>()
                    .unwrap()
                    .0,
                2
            );
            assert_eq!(
                tunnel
                    .extensions()
                    .get_ref::<SocketInfo>()
                    .unwrap()
                    .local_addr(),
                Some(server_local)
            );
            tunnel.extensions().insert(ConnectionMetadata(3));
            assert_eq!(
                server_extensions.get_ref::<ConnectionMetadata>().unwrap().0,
                2
            );
            server.shutdown().unwrap();
            {
                use std::{
                    future::Future as _,
                    task::{Context, Poll, Waker},
                };
                let mut drained = Box::pin(server.drained());
                assert_matches!(
                    drained
                        .as_mut()
                        .poll(&mut Context::from_waker(Waker::noop())),
                    Poll::Pending,
                );
            }
            let mut bytes = Vec::new();
            tunnel.read_to_end(&mut bytes).await.unwrap();
            assert_eq!(bytes, b"client tunnel bytes");
            tunnel.write_all(b"server after client FIN").await.unwrap();
            tunnel.shutdown().await.unwrap();
            server.drained().await.unwrap();
            drop(tunnel);
        });
        let response = client
            .send_request(
                Request::builder()
                    .method(Method::CONNECT)
                    .uri(
                        rama_net::uri::Uri::parse_http_request_target("localhost:443", true)
                            .unwrap(),
                    )
                    .body(Body::empty())
                    .unwrap(),
            )
            .await
            .unwrap();
        assert_eq!(response.status(), rama_http_types::StatusCode::CREATED);
        assert!(!response.headers().contains_key("content-length"));
        let mut tunnel = handle_upgrade(response).await.unwrap();
        assert_eq!(
            tunnel
                .extensions()
                .get_ref::<ConnectionMetadata>()
                .unwrap()
                .0,
            1
        );
        assert_eq!(
            tunnel
                .extensions()
                .get_ref::<SocketInfo>()
                .unwrap()
                .local_addr(),
            Some(client_local)
        );
        assert!(
            tunnel
                .extensions()
                .get_ref::<NegotiatedTlsParameters>()
                .unwrap()
                .peer_certificate_chain
                .is_some()
        );
        tunnel.extensions().insert(ConnectionMetadata(4));
        assert_eq!(
            pair.client
                .extensions()
                .get_ref::<ConnectionMetadata>()
                .unwrap()
                .0,
            1
        );
        tunnel.write_all(b"client tunnel bytes").await.unwrap();
        tunnel.shutdown().await.unwrap();
        let mut bytes = Vec::new();
        tunnel.read_to_end(&mut bytes).await.unwrap();
        assert_eq!(bytes, b"server after client FIN");
        serve.await.unwrap();
        pair.client.close(0u32, b"test complete");
        _ = client_driver.await.unwrap();
        _ = server_driver.await.unwrap();
        pair.close().await;
    })
    .await
    .unwrap();
}

#[derive(Debug, Extension)]
struct ConnectionMetadata(u8);

#[tokio::test]
async fn tiny_windows_fall_back_without_qpack_deadlock() {
    for window in [1u32, 3] {
        for critical_streams in [
            Preferences::default(),
            Preferences {
                order: Order::DecoderFirst,
                encoder: Startup::OnDemand,
                decoder: Startup::OnDemand,
                ..Preferences::default()
            },
        ] {
            tokio::time::timeout(LIMIT, async {
                let transport = || {
                    let mut transport = TransportConfig::default();
                    transport.set_stream_receive_window_uni(window.into());
                    transport.set_stream_receive_window(32u32);
                    transport.set_receive_window(128u32);
                    transport
                };
                let pair = Pair::new(Some(transport()), Some(transport())).await;
                let (mut client, client_driver) = client::handshake::<Body, _>(
                    pair.client.clone(),
                    Config {
                        critical_streams,
                        ..Config::default()
                    },
                    Executor::new(),
                )
                .unwrap();
                let (mut server, server_driver) = server::handshake(
                    pair.server.clone(),
                    Config {
                        critical_streams,
                        ..Config::default()
                    },
                )
                .unwrap();
                let client_driver = spawn(client_driver.run());
                let server_driver = spawn(server_driver.run());
                if critical_streams.encoder == Startup::OnDemand {
                    // Exercise the exact prefix-credit boundary after the peer
                    // has enabled dynamic compression, rather than racing SETTINGS.
                    client.peer_settings().await.unwrap();
                }
                let serve = spawn(async move {
                    for _ in 0..4 {
                        let (request, response) =
                            server.accept().await.unwrap().resolve().await.unwrap();
                        let body = request.into_body().collect().await.unwrap().to_bytes();
                        assert_eq!(body.len(), rama_utils::octets::kib(4));
                        response
                            .send_response(Response::new(Body::from(body)))
                            .await
                            .unwrap();
                    }
                });
                for _ in 0..4 {
                    let response = client
                        .send_request(
                            Request::builder()
                                .method("POST")
                                .uri("https://localhost/tiny-window")
                                .header(
                                    "x-long-field",
                                    "this dynamic insertion cannot fit the encoder stream credit",
                                )
                                .body(Body::from(vec![b'x'; rama_utils::octets::kib(4)]))
                                .unwrap(),
                        )
                        .await
                        .unwrap();
                    assert_eq!(
                        response
                            .into_body()
                            .collect()
                            .await
                            .unwrap()
                            .to_bytes()
                            .len(),
                        rama_utils::octets::kib(4)
                    );
                }
                assert_eq!(client.dynamic_insert_count(), 0);
                serve.await.unwrap();
                pair.client.close(0u32, b"test complete");
                _ = client_driver.await.unwrap();
                _ = server_driver.await.unwrap();
                pair.close().await;
            })
            .await
            .unwrap();
        }
    }
}

#[tokio::test]
async fn opt_in_push_delivers_common_body_and_enforces_quota() {
    tokio::time::timeout(LIMIT, async {
        let pair = Pair::new(None, None).await;
        let config = Config {
            max_pushes: 1,
            ..Config::default()
        };
        let (mut client, client_driver) =
            client::handshake::<Body, _>(pair.client.clone(), config.clone(), Executor::new())
                .unwrap();
        let mut pushes = client.take_pushes().unwrap();
        assert!(client.take_pushes().is_none());
        let (mut server, server_driver) = server::handshake(pair.server.clone(), config).unwrap();
        let client_driver = spawn(client_driver.run());
        let server_driver = spawn(server_driver.run());
        let consume = spawn(async move {
            let push = pushes.next().await.unwrap();
            assert_eq!(push.request().uri().request_target(), "/asset");
            let response = push.response().await.unwrap();
            assert_eq!(response.version(), Version::HTTP_3);
            assert_eq!(
                response.into_body().collect().await.unwrap().to_bytes(),
                "pushed content"
            );
            pushes
        });
        let serve = spawn(async move {
            let (_request, mut response) = server.accept().await.unwrap().resolve().await.unwrap();
            response.ready_for_push().await.unwrap();
            let pushed = response
                .push(
                    Request::builder()
                        .uri("https://localhost/asset")
                        .body(())
                        .unwrap(),
                )
                .await
                .unwrap();
            pushed
                .send_response(Response::new(Body::from("pushed content")))
                .await
                .unwrap();
            assert!(
                response
                    .push(
                        Request::builder()
                            .uri("https://localhost/second")
                            .body(())
                            .unwrap()
                    )
                    .await
                    .is_err()
            );
            response
                .send_response(Response::new(Body::from("main response")))
                .await
                .unwrap();
        });
        let response = client
            .send_request(
                Request::builder()
                    .uri("https://localhost/")
                    .body(Body::empty())
                    .unwrap(),
            )
            .await
            .unwrap();
        assert_eq!(
            response.into_body().collect().await.unwrap().to_bytes(),
            "main response"
        );
        let pushes = consume.await.unwrap();
        serve.await.unwrap();
        drop(pushes);
        pair.client.close(0u32, b"test complete");
        _ = client_driver.await.unwrap();
        _ = server_driver.await.unwrap();
        pair.close().await;
    })
    .await
    .unwrap();
}

#[tokio::test]
async fn connect_upstream_failure_resets_with_connect_error() {
    use rama_core::{extensions::ExtensionsRef as _, io::AbortIo};
    use rama_http::io::upgrade::handle_upgrade;
    use tokio::io::AsyncReadExt as _;
    tokio::time::timeout(LIMIT, async {
        let pair = Pair::new(None, None).await;
        let (mut client, client_driver) =
            client::handshake::<Body, _>(pair.client.clone(), Config::default(), Executor::new())
                .unwrap();
        let (mut server, server_driver) =
            server::handshake(pair.server.clone(), Config::default()).unwrap();
        let client_driver = spawn(client_driver.run());
        let server_driver = spawn(server_driver.run());
        let (ready, acknowledged) = tokio::sync::oneshot::channel();
        let serve = spawn(async move {
            let (request, response) = server.accept().await.unwrap().resolve().await.unwrap();
            let upgrade = handle_upgrade(request);
            response
                .send_response(Response::new(Body::empty()))
                .await
                .unwrap();
            let tunnel = upgrade.await.unwrap();
            acknowledged.await.unwrap();
            tunnel
                .extensions()
                .self_get_arc::<AbortIo>()
                .unwrap()
                .abort();
            drop(tunnel);
        });
        let response = client
            .send_request(
                Request::builder()
                    .method("CONNECT")
                    .uri(
                        rama_net::uri::Uri::parse_http_request_target("localhost:443", true)
                            .unwrap(),
                    )
                    .body(Body::empty())
                    .unwrap(),
            )
            .await
            .unwrap();
        let mut tunnel = handle_upgrade(response).await.unwrap();
        ready.send(()).unwrap();
        let error = tunnel.read_u8().await.unwrap_err();
        assert_eq!(
            error
                .get_ref()
                .and_then(|error| error.downcast_ref::<super::Error>())
                .unwrap()
                .code(),
            Code::H3_CONNECT_ERROR
        );
        serve.await.unwrap();
        drop(tunnel);
        pair.client.close(0u32, b"done");
        _ = client_driver.await;
        _ = server_driver.await;
        pair.close().await;
    })
    .await
    .unwrap();
}

/// As on TCP and HTTP/2, a write followed by a read needs no flush: the tunnel sends what a
/// write queued without waiting for the next write.
#[tokio::test]
async fn tunnel_writes_are_sent_without_an_explicit_flush() {
    use rama_http::io::upgrade::handle_upgrade;
    use tokio::io::{AsyncReadExt as _, AsyncWriteExt as _};
    tokio::time::timeout(LIMIT, async {
        let pair = Pair::new(None, None).await;
        let (mut client, client_driver) =
            client::handshake::<Body, _>(pair.client.clone(), Config::default(), Executor::new())
                .unwrap();
        let (mut server, server_driver) =
            server::handshake(pair.server.clone(), Config::default()).unwrap();
        let client_driver = spawn(client_driver.run());
        let server_driver = spawn(server_driver.run());
        let (received_tx, received) = tokio::sync::oneshot::channel();
        let serve = spawn(async move {
            let (request, response) = server.accept().await.unwrap().resolve().await.unwrap();
            let upgrade = handle_upgrade(request);
            response
                .send_response(Response::new(Body::empty()))
                .await
                .unwrap();
            let mut tunnel = upgrade.await.unwrap();
            let mut ping = [0; 4];
            tunnel.read_exact(&mut ping).await.unwrap();
            assert_eq!(&ping, b"ping");
            received_tx.send(()).unwrap();
            tunnel.write_all(b"pong").await.unwrap();
            // Wait for the client's end before ending in turn.
            assert_eq!(tunnel.read(&mut ping).await.unwrap(), 0);
            tunnel.shutdown().await.unwrap();
        });
        let response = client
            .send_request(
                Request::builder()
                    .method("CONNECT")
                    .uri(
                        rama_net::uri::Uri::parse_http_request_target("localhost:443", true)
                            .unwrap(),
                    )
                    .body(Body::empty())
                    .unwrap(),
            )
            .await
            .unwrap();
        let mut tunnel = handle_upgrade(response).await.unwrap();
        tunnel.write_all(b"ping").await.unwrap();
        // Not polled again until the server saw the write: only the write itself can send it.
        received.await.unwrap();
        let mut pong = [0; 4];
        tunnel.read_exact(&mut pong).await.unwrap();
        assert_eq!(&pong, b"pong");
        tunnel.shutdown().await.unwrap();
        serve.await.unwrap();
        drop(tunnel);
        pair.client.close(0u32, b"done");
        _ = client_driver.await;
        _ = server_driver.await;
        pair.close().await;
    })
    .await
    .unwrap();
}

#[tokio::test]
async fn saturated_admission_observes_connection_close() {
    tokio::time::timeout(LIMIT, async {
        let pair = Pair::new(None, None).await;
        let (mut server, driver) = server::handshake(
            pair.server.clone(),
            Config {
                max_requests: 1,
                ..Config::default()
            },
        )
        .unwrap();
        let driver = spawn(driver.run());
        let (mut send, _recv) = pair.client.open_bi().await.unwrap();
        send.write_all(b"x").await.unwrap();
        let held = server.accept().await.unwrap();
        pair.client.close(0u32, b"closed with admission held");
        assert_eq!(
            server.accept().await.err().unwrap().scope(),
            super::qpack::ErrorScope::Connection
        );
        drop(held);
        _ = driver.await;
        pair.close().await;
    })
    .await
    .unwrap();
}

#[tokio::test]
async fn early_response_survives_peer_stopping_request_upload() {
    use rama_core::bytes::BytesMut;
    use rama_http_types::proto::h3::{FrameHeader, FrameType};
    for stop_after_headers in [false, true] {
        tokio::time::timeout(LIMIT, async {
            let pair = Pair::new(None, None).await;
            let (mut client, client_driver) = client::handshake::<Body, _>(
                pair.client.clone(),
                Config::default(),
                Executor::new(),
            )
            .unwrap();
            let (_server, server_driver) =
                server::handshake(pair.server.clone(), Config::default()).unwrap();
            let client_driver = spawn(client_driver.run());
            let server_driver = spawn(server_driver.run());
            let (head_received, receive_head) = tokio::sync::oneshot::channel();
            let raw = pair.server.clone();
            let serve = spawn(async move {
                let (mut send, mut recv) = raw.accept_bi().await.unwrap();
                let mut encoder = super::qpack::Encoder::before_peer_settings(
                    super::qpack::EncoderConfig::default(),
                );
                let head = encoder
                    .encode(0, [(":status", "413"), ("content-length", "8")])
                    .unwrap();
                if !stop_after_headers {
                    recv.stop(Code::H3_NO_ERROR.value() as u32).unwrap();
                }
                let mut wire = BytesMut::new();
                FrameHeader::new(FrameType::HEADERS, head.len() as u64)
                    .encode(&mut wire)
                    .unwrap();
                wire.extend_from_slice(&head);
                send.write_chunk(wire.freeze()).await.unwrap();
                if stop_after_headers {
                    receive_head.await.unwrap();
                    recv.stop(Code::H3_NO_ERROR.value() as u32).unwrap();
                }
                send.write_all(b"\x00\x08too much").await.unwrap();
                send.finish().unwrap();
            });
            let frames = rama_core::futures::stream::repeat_with(|| {
                Ok::<_, std::convert::Infallible>(Frame::data(Bytes::from_static(
                    &[42; rama_utils::octets::kib(16)],
                )))
            });
            let response = client
                .send_request(
                    Request::builder()
                        .method("POST")
                        .uri("https://localhost/upload")
                        .body(Body::from_frame_stream(frames))
                        .unwrap(),
                )
                .await
                .unwrap();
            if stop_after_headers {
                head_received.send(()).unwrap();
            }
            assert_eq!(response.status().as_u16(), 413);
            assert_eq!(
                response.into_body().collect().await.unwrap().to_bytes(),
                "too much"
            );
            serve.await.unwrap();
            pair.client.close(0u32, b"done");
            _ = client_driver.await;
            _ = server_driver.await;
            pair.close().await;
        })
        .await
        .unwrap();
    }
}

#[tokio::test]
async fn cancelled_push_resets_even_when_sender_is_idle() {
    for goaway in [false, true] {
        tokio::time::timeout(LIMIT, async {
            let pair = Pair::new(None, None).await;
            let shared = super::connection::Shared::new(
                Config {
                    max_pushes: 1,
                    ..Config::default()
                },
                super::control::Role::Server,
                Default::default(),
            )
            .unwrap();
            let mut send = pair.server.open_uni().await.unwrap();
            send.write_all(b"push prefix").await.unwrap();
            let mut recv = pair.client.accept_uni().await.unwrap();
            {
                let mut pushes = shared.pushes.lock();
                pushes.max_id(0);
                let id = pushes.allocate(1, None).unwrap();
                pushes.mark_promised(id);
                pushes.attach_stream(id, u64::from(send.id()), Arc::new(send.handle()));
            }
            if goaway {
                shared.pushes.lock().reject_from(0);
            } else {
                shared.cancel_push(0, false).unwrap();
            }
            loop {
                match recv.read_chunk(64, true).await {
                    Ok(Some(_)) => (),
                    Err(rama_quic::ReadError::Reset(code)) => {
                        assert_eq!(u64::from(code), Code::H3_REQUEST_CANCELLED.value());
                        break;
                    }
                    other => panic!("expected reset while sender is retained: {other:?}"),
                }
            }
            drop(send);
            pair.close().await;
        })
        .await
        .unwrap();
    }
}

mod peer_settings;

mod priority_relay;
