//! Response framing fields on HTTP/3 follow the rule HTTP/1.1 and HTTP/2 share.

use rama_core::{
    bytes::Bytes,
    futures::stream,
    rt::{Executor, spawn},
};
use rama_http::io::upgrade::handle_upgrade;
use rama_http_types::{
    Body, Method, Request, Response, StatusCode,
    body::{Frame, SizeHint, StreamingBody, util::BodyExt},
};
use rama_net::uri::Uri;
use std::{
    convert::Infallible,
    pin::Pin,
    task::{Context, Poll},
};

use super::{LIMIT, Pair};
use crate::h3::{client, connection::Config, server};

#[derive(Debug, Clone, Copy)]
enum Payload {
    Empty,
    Known(&'static [u8]),
    Streamed(&'static [u8]),
}

/// (method, status, fields, payload, expected `Content-Length` on the wire)
type Case = (
    &'static str,
    u16,
    &'static [(&'static str, &'static str)],
    Payload,
    Option<&'static str>,
);

const CASES: &[Case] = &[
    ("HEAD", 200, &[], Payload::Empty, None),
    ("HEAD", 200, &[], Payload::Known(b"hello world"), Some("11")),
    (
        "HEAD",
        200,
        &[("content-length", "1234")],
        Payload::Empty,
        Some("1234"),
    ),
    ("GET", 200, &[], Payload::Known(b"hello"), Some("5")),
    ("GET", 200, &[], Payload::Empty, None),
    ("GET", 200, &[], Payload::Streamed(b"hello"), None),
    (
        "GET",
        204,
        &[("content-length", "10")],
        Payload::Empty,
        None,
    ),
    (
        "GET",
        304,
        &[("content-length", "1234")],
        Payload::Empty,
        Some("1234"),
    ),
    ("GET", 304, &[], Payload::Empty, None),
    ("GET", 204, &[], Payload::Known(b"discard"), None),
    (
        "GET",
        304,
        &[("content-length", "1234")],
        Payload::Known(b"discard"),
        Some("1234"),
    ),
    (
        "CONNECT",
        200,
        &[("transfer-encoding", "chunked")],
        Payload::Empty,
        None,
    ),
    (
        "CONNECT",
        200,
        &[("content-length", "0")],
        Payload::Empty,
        None,
    ),
    (
        "CONNECT",
        200,
        &[("content-length", "5")],
        Payload::Known(b"bytes"),
        None,
    ),
    ("CONNECT", 407, &[], Payload::Known(b"denied"), Some("6")),
];

fn response(case: &Case) -> Response {
    let (_, status, fields, payload, _) = *case;
    let body = match payload {
        Payload::Empty => Body::empty(),
        Payload::Known(bytes) => Body::from(Bytes::from_static(bytes)),
        Payload::Streamed(bytes) => {
            Body::from_stream(stream::iter([Ok::<_, std::convert::Infallible>(
                Bytes::from_static(bytes),
            )]))
        }
    };
    let mut builder = Response::builder().status(status);
    for (name, value) in fields {
        builder = builder.header(*name, *value);
    }
    builder.body(body).unwrap()
}

fn request(index: usize, case: &Case) -> Request {
    let method = Method::from_bytes(case.0.as_bytes()).unwrap();
    let target = if method == Method::CONNECT {
        Uri::parse_http_request_target(format!("localhost:{index}"), true).unwrap()
    } else {
        Uri::parse_http_request_target(format!("https://localhost/?case={index}"), false).unwrap()
    };
    Request::builder()
        .method(method)
        .uri(target)
        .body(Body::empty())
        .unwrap()
}

#[tokio::test]
async fn http3_response_framing_follows_the_shared_rule() {
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
            let mut tunnels = Vec::new();
            for case in CASES {
                let (request, response_stream) =
                    server.accept().await.unwrap().resolve().await.unwrap();
                // Holding the upgrade keeps the tunnel's stream open until the client read the head.
                let upgrade = handle_upgrade(request);
                response_stream.send_response(response(case)).await.unwrap();
                if case.0 == "CONNECT" && (200..300).contains(&case.1) {
                    tunnels.push(upgrade.await.unwrap());
                }
            }
            tunnels
        });
        for (index, case) in CASES.iter().enumerate() {
            let response = client.send_request(request(index, case)).await.unwrap();
            assert_eq!(
                response.status(),
                StatusCode::from_u16(case.1).unwrap(),
                "{case:?}"
            );
            let length = response
                .headers()
                .get("content-length")
                .map(|value| value.to_str().unwrap().to_owned());
            assert_eq!(length.as_deref(), case.4, "{case:?}");
            if case.0 != "CONNECT" || !(200..300).contains(&case.1) {
                let bytes = response.into_body().collect().await.unwrap().to_bytes();
                if case.0 == "HEAD" || matches!(case.1, 204 | 304) {
                    assert!(bytes.is_empty(), "{case:?}: bodyless response sent DATA");
                }
            }
        }
        drop(serve.await.unwrap());
        pair.client.close(0u32, b"test complete");
        _ = client_driver.await.unwrap();
        _ = server_driver.await.unwrap();
        pair.close().await;
    })
    .await
    .unwrap();
}

#[tokio::test]
async fn http3_strict_connect_framing_rejects_framing_headers() {
    for (name, value) in [("content-length", "0"), ("transfer-encoding", "chunked")] {
        tokio::time::timeout(LIMIT, async {
            let pair = Pair::new(None, None).await;
            let (mut client, client_driver) = client::handshake::<Body, _>(
                pair.client.clone(),
                Config::default(),
                Executor::new(),
            )
            .unwrap();
            let config = Config {
                strict_connect_framing: true,
                ..Config::default()
            };
            let (mut server, server_driver) =
                server::handshake(pair.server.clone(), config).unwrap();
            let client_driver = spawn(client_driver.run());
            let server_driver = spawn(server_driver.run());
            let serve = spawn(async move {
                let (_request, response_stream) =
                    server.accept().await.unwrap().resolve().await.unwrap();
                let response = Response::builder()
                    .header(name, value)
                    .body(Body::empty())
                    .unwrap();
                response_stream.send_response(response).await.unwrap_err()
            });
            let request = Request::builder()
                .method(Method::CONNECT)
                .uri(Uri::parse_http_request_target("localhost:443", true).unwrap())
                .body(Body::empty())
                .unwrap();
            client.send_request(request).await.unwrap_err();
            let error = serve.await.unwrap();
            assert!(
                error.to_string().contains("CONNECT"),
                "strict mode names the refused framing: {error}"
            );
            pair.client.close(0u32, b"test complete");
            _ = client_driver.await.unwrap();
            _ = server_driver.await.unwrap();
            pair.close().await;
        })
        .await
        .unwrap();
    }
}

struct IncorrectLength {
    remaining: Option<Bytes>,
    length: u64,
}

impl StreamingBody for IncorrectLength {
    type Data = Bytes;
    type Error = Infallible;

    fn poll_frame(
        mut self: Pin<&mut Self>,
        _: &mut Context<'_>,
    ) -> Poll<Option<Result<Frame<Bytes>, Infallible>>> {
        Poll::Ready(self.remaining.take().map(|bytes| Ok(Frame::data(bytes))))
    }

    fn size_hint(&self) -> SizeHint {
        SizeHint::with_exact(self.length)
    }
}

#[tokio::test]
async fn http3_rejects_bodies_that_disagree_with_their_advertised_length() {
    for length in [2, 8] {
        tokio::time::timeout(LIMIT, async {
            let pair = Pair::new(None, None).await;
            let (mut client, client_driver) = client::handshake::<Body, _>(
                pair.client.clone(),
                Config::default(),
                Executor::new(),
            )
            .unwrap();
            let (mut server, server_driver) =
                server::handshake(pair.server.clone(), Config::default()).unwrap();
            let client_driver = spawn(client_driver.run());
            let server_driver = spawn(server_driver.run());
            let serve = spawn(async move {
                let (_, response_stream) = server.accept().await.unwrap().resolve().await.unwrap();
                response_stream
                    .send_response(Response::new(IncorrectLength {
                        remaining: Some(Bytes::from_static(b"hello")),
                        length,
                    }))
                    .await
                    .unwrap_err()
            });
            let request = Request::builder()
                .uri("https://localhost/")
                .body(Body::empty())
                .unwrap();
            if let Ok(response) = client.send_request(request).await {
                response.into_body().collect().await.unwrap_err();
            }
            let error = serve.await.unwrap();
            assert!(error.to_string().contains("content-length"), "{error}");
            pair.client.close(0u32, b"test complete");
            _ = client_driver.await.unwrap();
            _ = server_driver.await.unwrap();
            pair.close().await;
        })
        .await
        .unwrap();
    }
}
