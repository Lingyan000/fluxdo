#![cfg(any(
    feature = "boring",
    all(feature = "rustls", any(feature = "aws-lc", feature = "ring"))
))]
#![expect(
    clippy::unwrap_used,
    clippy::expect_used,
    reason = "an integration test's fixtures fail the test by panicking; the workspace allows this inside test functions and this file is one, but its helpers are not #[test] themselves"
)]
//! The stream properties a terminating relay is built out of, through the public API: a
//! half-close that lets an answer follow a finished request, and a cancellation that reaches
//! the other end rather than leaving it waiting.
//!
//! These are the primitives, not a second copy of the relay: the relay example composes them
//! and is run as itself.

mod runtime;

use std::assert_matches;
use std::{
    net::{Ipv4Addr, SocketAddr},
    time::Duration,
};

use rama_core::rt::{Executor, spawn};
use rama_quic::{Endpoint, ReadError, WriteError};
use rama_quic_proto::VarInt;

use runtime::{Identities, connect};

const LIMIT: Duration = Duration::from_secs(20);
const READ_CAP: usize = 1024;

fn localhost() -> SocketAddr {
    SocketAddr::new(Ipv4Addr::LOCALHOST.into(), 0)
}

/// A connected pair, and the endpoints that own them.
struct Pair {
    client: Endpoint,
    server: Endpoint,
    from_client: rama_quic::Connection,
    at_server: rama_quic::Connection,
}

impl Pair {
    async fn new(identities: &Identities) -> Self {
        let server = Endpoint::build(Executor::new())
            .with_server_config(identities.server_config())
            .bind_address(localhost())
            .await
            .expect("the server binds");
        let addr = server.local_addr().unwrap();
        let client = Endpoint::build(Executor::new())
            .bind_address(localhost())
            .await
            .expect("the client binds");
        let accepting = spawn({
            let server = server.clone();
            async move {
                server
                    .accept()
                    .await
                    .expect("an attempt arrives")
                    .await
                    .expect("the handshake completes")
            }
        });
        let from_client = connect(&client, identities, addr).await;
        let at_server = tokio::time::timeout(LIMIT, accepting)
            .await
            .expect("the server accepted")
            .unwrap();
        Self {
            client,
            server,
            from_client,
            at_server,
        }
    }

    async fn close(self) {
        self.from_client.close(0u32, b"done");
        tokio::join!(self.client.shutdown(), self.server.shutdown());
    }
}

/// A request finished before its answer begins: the writer half-closes, the reader sees the
/// end, and the answer comes back over the same stream afterwards.
#[tokio::test]
async fn a_half_close_lets_the_answer_follow_the_request() {
    let identities = Identities::new();
    let pair = Pair::new(&identities).await;

    let (mut send, mut recv) = pair.from_client.open_bi().await.expect("a bi stream");
    send.write_all(b"question").await.expect("it is written");
    send.finish().expect("the request ends");

    let (mut answering, mut asked) = pair.at_server.accept_bi().await.expect("it arrives");
    let question = asked.read_to_end(READ_CAP).await.expect("it completes");
    assert_eq!(
        question, b"question",
        "the whole request, ended by the peer"
    );
    answering
        .write_all(b"answer")
        .await
        .expect("the answer is written after the request ended");
    answering.finish().expect("the answer ends");

    let answer = recv.read_to_end(READ_CAP).await.expect("it completes");
    assert_eq!(
        answer, b"answer",
        "which the half-closed stream carried back"
    );
    pair.close().await;
}

/// A reader that stops the stream is a cancellation the writer is told about, by the code the
/// reader gave.
#[tokio::test]
async fn a_reader_that_stops_is_reported_to_the_writer() {
    let identities = Identities::new();
    let pair = Pair::new(&identities).await;

    let (mut send, _recv) = pair.from_client.open_bi().await.expect("a bi stream");
    send.write_all(b"begin").await.expect("it is written");
    let (_answering, mut asked) = pair.at_server.accept_bi().await.expect("it arrives");
    asked.read(&mut [0u8; 8]).await.expect("the start arrives");
    asked.stop(VarInt::from(7u32)).expect("the reader stops it");

    let stopped = tokio::time::timeout(LIMIT, send.stopped())
        .await
        .expect("the writer is told")
        .expect("the stream ended cleanly enough to say so");
    assert_eq!(
        stopped,
        Some(VarInt::from(7u32)),
        "the writer is told the code the reader gave"
    );
    pair.close().await;
}

/// A writer that resets is a cancellation the reader is told about, rather than a stream that
/// simply stops arriving.
#[tokio::test]
async fn a_writer_that_resets_is_reported_to_the_reader() {
    let identities = Identities::new();
    let pair = Pair::new(&identities).await;

    let (mut send, _recv) = pair.from_client.open_bi().await.expect("a bi stream");
    send.write_all(b"begin").await.expect("it is written");
    let (_answering, mut asked) = pair.at_server.accept_bi().await.expect("it arrives");
    asked.read(&mut [0u8; 8]).await.expect("the start arrives");
    send.reset(VarInt::from(9u32))
        .expect("the writer resets it");

    let error = tokio::time::timeout(LIMIT, asked.read_to_end(READ_CAP))
        .await
        .expect("the reader is told")
        .expect_err("a reset stream does not complete");
    assert_matches!(
        error,
        rama_quic::ReadToEndError::Read(ReadError::Reset(code)) if code == VarInt::from(9u32),
        "the reader is told the code the writer gave: {error:?}",
    );
    pair.close().await;
}

/// Writing to a stream the peer has stopped fails rather than blocking, so a copy loop ends
/// instead of holding a task.
#[tokio::test]
async fn a_write_to_a_stopped_stream_ends_the_copy() {
    let identities = Identities::new();
    let pair = Pair::new(&identities).await;

    let (mut send, _recv) = pair.from_client.open_bi().await.expect("a bi stream");
    send.write_all(b"begin").await.expect("it is written");
    let (_answering, mut asked) = pair.at_server.accept_bi().await.expect("it arrives");
    asked.read(&mut [0u8; 8]).await.expect("the start arrives");
    asked.stop(VarInt::from(3u32)).expect("the reader stops it");
    // The stop has to reach this side before the write can be refused for it.
    drop(send.stopped().await);

    let error = tokio::time::timeout(LIMIT, send.write_all(b"more"))
        .await
        .expect("the write returned rather than blocking")
        .expect_err("a stopped stream takes nothing more");
    assert_matches!(
        error,
        WriteError::Stopped(code) if code == VarInt::from(3u32),
        "and says the reader stopped it: {error:?}",
    );
    pair.close().await;
}
