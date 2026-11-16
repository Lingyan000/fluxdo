//! Deadlines exercise real QUIC streams, admission leases and QPACK cancellation.

use super::Pair;
use crate::{
    h3::{
        Error, client,
        connection::{Config, Shared},
        control::Role,
        qpack::{Encoder, EncoderConfig},
        quic::RecvStream,
        server,
        stream::{HeadDeadline, Reader},
    },
    server::conn::{HeaderReadTimeout, IdleTimeout, timeout::HeadBudget},
};
use rama_core::{
    bytes::{Bytes, BytesMut},
    extensions::ExtensionsRef as _,
    futures::FutureExt as _,
    rt::{Executor, spawn},
};
use rama_http::io::upgrade::handle_upgrade;
use rama_http_types::{
    Body, Method, Request, Response,
    proto::{
        ext::Protocol,
        h3::{Code, FrameHeader, FrameType},
    },
};
use rama_quic::Connection as QuicConnection;
use rama_utils::octets::kib;
use std::{
    task::{Context, Poll},
    time::Duration,
};
use tokio::{
    io::{AsyncReadExt as _, AsyncWriteExt as _},
    time::{Instant, advance, pause, resume, timeout},
};

const GRACE: Duration = Duration::from_millis(100);

fn config() -> Config {
    Config {
        max_requests: 1,
        header_read_timeout: Some(HeaderReadTimeout {
            grace: GRACE,
            min_rate: u32::MAX,
            ceiling: Duration::from_secs(1),
        }),
        idle_timeout: Some(IdleTimeout {
            first_request: GRACE,
            idle: Duration::from_millis(500),
        }),
        ..Config::default()
    }
}

fn frame(fields: &[u8]) -> Bytes {
    let mut bytes = BytesMut::new();
    FrameHeader::new(FrameType::HEADERS, fields.len() as u64)
        .encode(&mut bytes)
        .unwrap();
    bytes.extend_from_slice(fields);
    bytes.freeze()
}

fn head(id: u64, dynamic: bool) -> Bytes {
    let mut encoder = if dynamic {
        Encoder::new(EncoderConfig::default())
    } else {
        Encoder::before_peer_settings(EncoderConfig::default())
    };
    let fields = encoder
        .encode(
            id,
            [
                (":method", "GET"),
                (":scheme", "https"),
                (":authority", "localhost"),
                (":path", "/"),
                ("x-timeout", "waiting for encoder instructions"),
            ],
        )
        .unwrap();
    if dynamic {
        assert_eq!(encoder.tracked_section_count(), 1);
    }
    frame(&fields)
}

/// Complete one request so that the connection earned its idle budget.
async fn earn(pair: &Pair, server: &mut server::Connection<QuicConnection>) {
    let (mut send, _recv) = pair.client.open_bi().await.unwrap();
    send.write_chunk(head(u64::from(send.id()), false))
        .await
        .unwrap();
    drop(server.accept().await.unwrap().resolve().await.unwrap());
}

#[tokio::test]
async fn incomplete_and_qpack_blocked_heads_reject_and_release_admission() {
    for dynamic in [false, true] {
        let pair = Pair::in_memory(None, None).await;
        let (mut server, driver) = server::handshake(pair.server.clone(), config()).unwrap();
        let driver = spawn(driver.run());
        earn(&pair, &mut server).await;
        let (mut send, _recv) = pair.client.open_bi().await.unwrap();
        let id = u64::from(send.id());
        send.write_chunk(if dynamic {
            head(id, true)
        } else {
            Bytes::from_static(b"\x01")
        })
        .await
        .unwrap();
        let request = server.accept().await.unwrap();
        pause();
        let mut resolving = Box::pin(request.resolve());
        assert!(resolving.as_mut().now_or_never().is_none());
        advance(GRACE * 2 + Duration::from_millis(1)).await;
        assert_eq!(
            resolving.await.err().unwrap().code(),
            Code::H3_REQUEST_REJECTED
        );
        resume();
        assert_eq!(
            send.stopped().await.unwrap().map(u64::from),
            Some(Code::H3_REQUEST_REJECTED.value())
        );
        let (mut next, _next_recv) = pair.client.open_bi().await.unwrap();
        next.write_chunk(head(u64::from(next.id()), false))
            .await
            .unwrap();
        let (request, response) = server.accept().await.unwrap().resolve().await.unwrap();
        assert_eq!(request.uri().request_target(), "/");
        drop((request, response));
        pair.client.close(0u32, b"done");
        _ = driver.await;
        pair.close().await;
    }
}

#[tokio::test]
async fn disabled_head_timeout_allows_a_late_remainder() {
    let pair = Pair::in_memory(None, None).await;
    let (mut server, driver) = server::handshake(
        pair.server.clone(),
        Config {
            header_read_timeout: None,
            ..config()
        },
    )
    .unwrap();
    let driver = spawn(driver.run());
    let (mut send, _recv) = pair.client.open_bi().await.unwrap();
    let wire = head(u64::from(send.id()), false);
    send.write_chunk(wire.slice(..1)).await.unwrap();
    let request = server.accept().await.unwrap();
    pause();
    let mut resolving = Box::pin(request.resolve());
    assert!(resolving.as_mut().now_or_never().is_none());
    advance(Duration::from_secs(2)).await;
    assert!(resolving.as_mut().now_or_never().is_none());
    resume();
    send.write_chunk(wire.slice(1..)).await.unwrap();
    drop(resolving.await.unwrap());
    pair.client.close(0u32, b"done");
    _ = driver.await;
    pair.close().await;
}

#[tokio::test]
async fn first_request_idle_closes_and_can_be_disabled() {
    for enabled in [false, true] {
        let pair = Pair::in_memory(None, None).await;
        let mut config = config();
        if !enabled {
            config.idle_timeout = None;
        }
        let (mut server, driver) = server::handshake(pair.server.clone(), config).unwrap();
        let driver = spawn(driver.run());
        pause();
        let mut accept = Box::pin(server.accept());
        assert!(accept.as_mut().now_or_never().is_none());
        advance(GRACE * 2 + Duration::from_millis(1)).await;
        if enabled {
            assert_eq!(accept.await.err().unwrap().code(), Code::H3_NO_ERROR);
        } else {
            assert!(accept.as_mut().now_or_never().is_none());
            drop(accept);
        }
        resume();
        pair.client.close(0u32, b"done");
        _ = driver.await;
        pair.close().await;
    }
}

#[tokio::test]
async fn completed_head_earns_idle_budget_and_active_response_suspends_it() {
    let pair = Pair::in_memory(None, None).await;
    let (mut server, driver) = server::handshake(
        pair.server.clone(),
        Config {
            max_requests: 2,
            ..config()
        },
    )
    .unwrap();
    let driver = spawn(driver.run());
    let (mut send, _recv) = pair.client.open_bi().await.unwrap();
    send.write_chunk(head(u64::from(send.id()), false))
        .await
        .unwrap();
    let (request, response) = server.accept().await.unwrap().resolve().await.unwrap();
    drop(request);
    pause();
    let mut accept = Box::pin(server.accept());
    assert!(accept.as_mut().now_or_never().is_none());
    advance(Duration::from_secs(2)).await;
    assert!(
        accept.as_mut().now_or_never().is_none(),
        "active response suppresses idle timeout"
    );
    drop(response);
    assert!(accept.as_mut().now_or_never().is_none());
    advance(Duration::from_millis(300)).await;
    assert!(
        accept.as_mut().now_or_never().is_none(),
        "completed head earns more than first-request grace"
    );
    advance(Duration::from_millis(201)).await;
    assert_eq!(accept.await.err().unwrap().code(), Code::H3_NO_ERROR);
    resume();
    pair.client.close(0u32, b"done");
    _ = driver.await;
    pair.close().await;
}

#[tokio::test]
async fn recreating_accept_keeps_the_running_idle_window() {
    let pair = Pair::in_memory(None, None).await;
    let (mut server, driver) = server::handshake(pair.server.clone(), config()).unwrap();
    let driver = spawn(driver.run());
    earn(&pair, &mut server).await;
    pause();
    for _ in 0..4 {
        let mut accept = Box::pin(server.accept());
        assert!(accept.as_mut().now_or_never().is_none());
        advance(Duration::from_millis(100)).await;
        assert!(accept.as_mut().now_or_never().is_none());
    }
    let mut accept = Box::pin(server.accept());
    assert!(accept.as_mut().now_or_never().is_none());
    advance(Duration::from_millis(101)).await;
    // The elapsed window sends GOAWAY on this poll; later accepts see the drain.
    assert!(accept.as_mut().now_or_never().is_none());
    drop(accept);
    assert_eq!(
        server
            .accept()
            .now_or_never()
            .unwrap()
            .err()
            .unwrap()
            .code(),
        Code::H3_NO_ERROR,
        "the earned window counts from the end of the last request"
    );
    resume();
    pair.client.close(0u32, b"done");
    _ = driver.await;
    pair.close().await;
}

#[tokio::test]
async fn progress_earns_time_but_cannot_exceed_the_ceiling() {
    let pair = Pair::in_memory(None, None).await;
    let (mut server, driver) = server::handshake(
        pair.server.clone(),
        Config {
            header_read_timeout: Some(HeaderReadTimeout {
                grace: GRACE,
                min_rate: 1,
                ceiling: Duration::from_secs(1),
            }),
            ..config()
        },
    )
    .unwrap();
    let driver = spawn(driver.run());
    let (mut send, _recv) = pair.client.open_bi().await.unwrap();
    send.write_all(b"\x01\x04\x00").await.unwrap();
    let request = server.accept().await.unwrap();
    pause();
    let mut resolving = Box::pin(request.resolve());
    assert!(resolving.as_mut().now_or_never().is_none());
    advance(Duration::from_millis(250)).await;
    assert!(
        resolving.as_mut().now_or_never().is_none(),
        "one byte earns a second at one byte per second"
    );
    advance(Duration::from_millis(751)).await;
    assert_eq!(
        resolving.await.err().unwrap().code(),
        Code::H3_REQUEST_REJECTED
    );
    resume();
    pair.client.close(0u32, b"done");
    _ = driver.await;
    pair.close().await;
}

#[tokio::test]
async fn extended_connect_tunnel_stays_usable_past_idle_and_releases_its_budget() {
    let pair = Pair::in_memory(None, None).await;
    let (mut client, client_driver) =
        client::handshake::<Body, _>(pair.client.clone(), Config::default(), Executor::new())
            .unwrap();
    let (mut server, server_driver) = server::handshake(
        pair.server.clone(),
        Config {
            extended_connect: true,
            max_requests: 2,
            ..config()
        },
    )
    .unwrap();
    let client_driver = spawn(client_driver.run());
    let server_driver = spawn(server_driver.run());
    let request = Request::builder()
        .method(Method::CONNECT)
        .uri("https://localhost/idle-tunnel")
        .body(Body::empty())
        .unwrap();
    request
        .extensions()
        .insert(Protocol::from_static("x-idle-test"));
    let (mut server_tunnel, mut client_tunnel) = tokio::join!(
        async {
            let (request, response) = server.accept().await.unwrap().resolve().await.unwrap();
            let upgraded = handle_upgrade(request);
            response
                .send_response(Response::new(Body::empty()))
                .await
                .unwrap();
            upgraded.await.unwrap()
        },
        async {
            let response = client.send_request(request).await.unwrap();
            handle_upgrade(response).await.unwrap()
        },
    );
    pause();
    let mut accept = Box::pin(server.accept());
    assert!(accept.as_mut().now_or_never().is_none());
    advance(Duration::from_secs(2)).await;
    assert!(
        accept.as_mut().now_or_never().is_none(),
        "the tunnel owns its admission permit after the response sender ends"
    );
    timeout(Duration::from_secs(1), async {
        client_tunnel.write_all(b"ping").await.unwrap();
        let mut received = [0; 4];
        server_tunnel.read_exact(&mut received).await.unwrap();
        assert_eq!(&received, b"ping");
        server_tunnel.write_all(b"pong").await.unwrap();
        client_tunnel.read_exact(&mut received).await.unwrap();
        assert_eq!(&received, b"pong");
    })
    .await
    .unwrap();
    drop((server_tunnel, client_tunnel));
    assert!(accept.as_mut().now_or_never().is_none());
    advance(Duration::from_millis(501)).await;
    assert_eq!(accept.await.err().unwrap().code(), Code::H3_NO_ERROR);
    resume();
    pair.client.close(0u32, b"done");
    _ = client_driver.await;
    _ = server_driver.await;
    pair.close().await;
}

#[tokio::test]
async fn stalled_first_head_closes_the_connection_even_while_other_heads_are_open() {
    for overlapping in [false, true] {
        let pair = Pair::in_memory(None, None).await;
        let (mut server, driver) = server::handshake(
            pair.server.clone(),
            Config {
                max_requests: 3,
                ..config()
            },
        )
        .unwrap();
        let driver = spawn(driver.run());
        let (mut first, _first_recv) = pair.client.open_bi().await.unwrap();
        first
            .write_chunk(Bytes::from_static(b"\x01"))
            .await
            .unwrap();
        let first = server.accept().await.unwrap();
        // A second head in progress keeps the connection busy while the first one stalls.
        let mut second = None;
        if overlapping {
            let (mut send, recv) = pair.client.open_bi().await.unwrap();
            send.write_chunk(Bytes::from_static(b"\x01")).await.unwrap();
            second = Some((send, recv, server.accept().await.unwrap()));
        }
        pause();
        let mut resolving = Box::pin(first.resolve());
        assert!(resolving.as_mut().now_or_never().is_none());
        let mut accept = Box::pin(server.accept());
        assert!(accept.as_mut().now_or_never().is_none());
        advance(GRACE * 2 + Duration::from_millis(1)).await;
        assert_eq!(
            resolving.await.err().unwrap().code(),
            Code::H3_REQUEST_REJECTED
        );
        let started = Instant::now();
        let error = accept.await.err().unwrap();
        assert_eq!(error.code(), Code::H3_NO_ERROR, "overlapping={overlapping}");
        assert!(
            Instant::now() - started <= Duration::from_secs(2),
            "closed within the drain, not after another first-request window"
        );
        resume();
        drop(second);
        _ = driver.await;
        pair.close().await;
    }
}

#[tokio::test]
async fn unearned_window_is_not_restarted_by_short_streams() {
    let pair = Pair::in_memory(None, None).await;
    let (mut server, driver) = server::handshake(
        pair.server.clone(),
        Config {
            header_read_timeout: None,
            idle_timeout: Some(IdleTimeout {
                first_request: GRACE * 3,
                idle: Duration::from_secs(5),
            }),
            ..config()
        },
    )
    .unwrap();
    let driver = spawn(driver.run());
    pause();
    let started = Instant::now();
    let mut closed = None;
    for _ in 0..10 {
        let mut accept = Box::pin(server.accept());
        assert!(accept.as_mut().now_or_never().is_none());
        advance(GRACE * 2).await;
        // An elapsed window starts closing here, before any further stream.
        assert!(accept.as_mut().now_or_never().is_none());
        resume();
        // A stream that ends before any head, as a scanner would open.
        if let Ok((mut send, _recv)) = pair.client.open_bi().await {
            _ = send.finish();
        }
        match accept.await {
            Ok(request) => assert_eq!(
                request.resolve().await.err().unwrap().code(),
                Code::H3_REQUEST_INCOMPLETE
            ),
            Err(error) => {
                closed = Some(error);
                break;
            }
        }
        pause();
    }
    let error = closed.expect("the first-request window elapsed");
    assert_eq!(error.code(), Code::H3_NO_ERROR);
    assert!(
        Instant::now() - started < GRACE * 3 + Duration::from_secs(3),
        "closed one window after the first idle phase"
    );
    _ = driver.await;
    pair.close().await;
}

struct CoalescedHead(Option<Bytes>);

impl RecvStream for CoalescedHead {
    fn poll_chunk(&mut self, _: &mut Context<'_>, _: usize) -> Poll<Result<Option<Bytes>, Error>> {
        match self.0.take() {
            Some(bytes) => Poll::Ready(Ok(Some(bytes))),
            None => Poll::Pending,
        }
    }

    fn stop(&mut self, _: Code) {}
}

#[tokio::test(start_paused = true)]
async fn qpack_blocked_head_cannot_earn_time_from_coalesced_data_or_extension_frames() {
    for (extension, data) in [(false, false), (true, false), (false, true), (true, true)] {
        let mut wire = BytesMut::new();
        let unrelated = vec![0; kib(16)];
        if extension {
            FrameHeader::new(FrameType::new(0x21), unrelated.len() as u64)
                .encode(&mut wire)
                .unwrap();
            wire.extend_from_slice(&unrelated);
        }
        let field_section = head(0, true);
        assert!(
            field_section.len() < 256,
            "the HEADERS alone cannot earn past grace"
        );
        wire.extend_from_slice(&field_section);
        if data {
            FrameHeader::new(FrameType::DATA, unrelated.len() as u64)
                .encode(&mut wire)
                .unwrap();
            wire.extend_from_slice(&unrelated);
        }
        let shared = Shared::new(
            Config {
                read_chunk_size: kib(64),
                ..Config::default()
            },
            Role::Server,
            Default::default(),
        )
        .unwrap();
        // The mock guarantees one read contains both the head and unrelated bytes.
        let mut reader = Reader::new(CoalescedHead(Some(wire.freeze())), shared, 0);
        let start = Instant::now();
        let mut resolve = Box::pin(reader.headers_within(Some(HeadDeadline {
            accepted: start,
            budget: HeadBudget::new(&HeaderReadTimeout::DEFAULT, Some(Duration::ZERO)),
        })));
        assert!(resolve.as_mut().now_or_never().is_none());
        advance(HeaderReadTimeout::DEFAULT.grace).await;
        assert_eq!(
            resolve.await.err().unwrap().code(),
            Code::H3_REQUEST_REJECTED
        );
        assert_eq!(
            Instant::now() - start,
            HeaderReadTimeout::DEFAULT.grace,
            "extension={extension}, data={data}: unrelated bytes cannot extend grace"
        );
    }
}
