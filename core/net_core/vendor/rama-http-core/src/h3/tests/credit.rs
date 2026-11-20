//! Exercise advertised stream-credit boundaries on the actual control stream.

use super::{LIMIT, Pair};
use crate::h3::{
    client,
    connection::{Config, initial_control},
    control::Role,
    server,
};
use rama_core::{
    bytes::BytesMut,
    extensions::{Extensions, ExtensionsRef},
    rt::{Executor, spawn},
};
use rama_http_types::{
    Body,
    proto::h3::{Code, FrameHeader, FrameType, StreamType},
};
use rama_net::{
    client::{
        ConnectionError, ConnectionErrorDomain, ConnectionErrorKind,
        pool::{ConnID, ConnectionResult, MultiplexPool, Pool},
    },
    conn::ConnectionHealthWatcher,
};
use rama_quic::{Connection, TransportConfig};
use rama_quic_proto::{Dir, Side, StreamId, coding::Codec as _};
use rama_utils::reactive::{Change, ChangeListener};
use std::assert_matches;
use std::{
    future::Future,
    num::NonZeroUsize,
    pin::pin,
    sync::{
        Arc, Weak,
        atomic::{AtomicU64, Ordering},
    },
    task::{Context, Poll, Wake, Waker},
};
use tokio::sync::oneshot;

#[tokio::test(start_paused = true)]
async fn priority_update_checks_exact_advertised_stream_limit() {
    tokio::time::timeout(LIMIT, async {
        for at_limit in [false, true] {
            let pair = Pair::in_memory(None, None).await;
            let (_server, driver) =
                server::handshake(pair.server.clone(), Config::default()).unwrap();
            let driver = spawn(driver.run());
            let limit = pair.server.remote_stream_limit(Dir::Bi);
            let index = if at_limit { limit } else { limit - 1 };
            let mut payload = BytesMut::new();
            StreamId::new(Side::Client, Dir::Bi, index).encode(&mut payload);
            payload.extend_from_slice(b"u=1");
            let mut bytes = BytesMut::from(
                initial_control(&Config::default(), Role::Client, false)
                    .unwrap()
                    .as_ref(),
            );
            FrameHeader::new(FrameType::PRIORITY_UPDATE_REQUEST, payload.len() as u64)
                .encode(&mut bytes)
                .unwrap();
            bytes.extend_from_slice(&payload);
            // An invalid control-stream DATA frame is a processing barrier. The
            // valid update below the limit must reach it; the exact-limit ID
            // must fail first, independently of priority-field parsing.
            FrameHeader::new(FrameType::DATA, 0)
                .encode(&mut bytes)
                .unwrap();
            let mut control = pair.client.open_uni().await.unwrap();
            control.write_all(&bytes).await.unwrap();
            assert_eq!(
                driver.await.unwrap().unwrap_err().code(),
                if at_limit {
                    Code::H3_ID_ERROR
                } else {
                    Code::H3_FRAME_UNEXPECTED
                }
            );
            pair.close().await;
        }
    })
    .await
    .unwrap();
}

#[tokio::test(start_paused = true)]
async fn priority_updates_cover_transport_credit_beyond_application_admission() {
    tokio::time::timeout(LIMIT, async {
        for concurrency in [128u32, 256] {
            let mut transport = TransportConfig::default();
            Config::default()
                .configure_transport(&mut transport)
                .unwrap();
            transport.set_max_concurrent_bidi_streams(concurrency);
            let pair = Pair::in_memory(None, Some(transport)).await;
            let (_server, driver) =
                server::handshake(pair.server.clone(), Config::default()).unwrap();
            let driver = spawn(driver.run());
            let limit = pair.server.remote_stream_limit(Dir::Bi);
            let mut bytes = BytesMut::from(
                initial_control(&Config::default(), Role::Client, false)
                    .unwrap()
                    .as_ref(),
            );
            for index in 0..limit {
                let mut payload = BytesMut::new();
                StreamId::new(Side::Client, Dir::Bi, index).encode(&mut payload);
                payload.extend_from_slice(b"u=1");
                FrameHeader::new(FrameType::PRIORITY_UPDATE_REQUEST, payload.len() as u64)
                    .encode(&mut bytes)
                    .unwrap();
                bytes.extend_from_slice(&payload);
            }
            FrameHeader::new(FrameType::DATA, 0)
                .encode(&mut bytes)
                .unwrap();
            let mut control = pair.client.open_uni().await.unwrap();
            control.write_all(&bytes).await.unwrap();
            let code = driver.await.unwrap().unwrap_err().code();
            // Every update targets a stream within the advertised limit; only the DATA barrier is invalid.
            assert_eq!(code, Code::H3_FRAME_UNEXPECTED, "concurrency {concurrency}");
            pair.close().await;
        }
    })
    .await
    .unwrap();
}

#[tokio::test(start_paused = true)]
async fn peer_must_grant_credit_for_all_three_critical_streams() {
    tokio::time::timeout(LIMIT, async {
        let mut transport = TransportConfig::default();
        transport.set_max_concurrent_uni_streams(2u32);
        let pair = Pair::in_memory(Some(transport), None).await;
        let (_server, driver) = server::handshake(pair.server.clone(), Config::default()).unwrap();
        assert_eq!(
            driver.run().await.unwrap_err().code(),
            Code::H3_STREAM_CREATION_ERROR
        );
        pair.close().await;
    })
    .await
    .unwrap();
}

#[tokio::test(start_paused = true)]
async fn stream_budget_watcher_observes_peer_credit_increase() {
    tokio::time::timeout(LIMIT, async {
        for initial in [0u32, 1] {
            let mut transport = TransportConfig::default();
            transport.set_max_concurrent_bidi_streams(initial);
            let pair = Pair::in_memory(None, Some(transport)).await;
            assert_eq!(pair.client.available_streams(Dir::Bi), u64::from(initial));
            let mut changed = pair.client.stream_budget_watch(Dir::Bi);
            pair.server.set_max_concurrent_bi_streams(initial + 1);
            changed.changed().await.unwrap();
            assert_eq!(
                pair.client.available_streams(Dir::Bi),
                u64::from(initial + 1)
            );
            pair.close().await;
        }
    })
    .await
    .unwrap();
}

#[tokio::test(start_paused = true)]
async fn goaway_rejected_streams_release_peer_qpack_sections() {
    tokio::time::timeout(LIMIT, async {
        let pair = Pair::in_memory(None, None).await;
        let (mut server, driver) =
            server::handshake(pair.server.clone(), Config::default()).unwrap();
        let driver = spawn(driver.run());
        let mut critical = Vec::new();
        let mut decoder = None;
        for _ in 0..3 {
            let mut recv = pair.client.accept_uni().await.unwrap();
            let ty = recv.read_chunk(1, true).await.unwrap().unwrap().bytes[0];
            if u64::from(ty) == StreamType::QPACK_DECODER.value() {
                decoder = Some(recv);
            } else {
                critical.push(recv);
            }
        }
        let mut decoder = decoder.unwrap();
        for (id, shutdown) in [(0, false), (4, true)] {
            if shutdown {
                server.shutdown().unwrap();
            }
            let (mut send, recv) = pair.client.open_bi().await.unwrap();
            send.write_all(&[FrameType::HEADERS.value() as u8])
                .await
                .unwrap();
            if !shutdown {
                drop(server.accept().await.unwrap());
            }
            assert_eq!(
                send.stopped().await.unwrap().unwrap().into_inner(),
                Code::H3_REQUEST_REJECTED.value()
            );
            drop(recv);
            let feedback = decoder.read_chunk(1, true).await.unwrap().unwrap().bytes;
            assert_eq!(feedback.as_ref(), &[0x40 | id]);
        }
        pair.client
            .close(Code::H3_NO_ERROR.value() as u32, b"complete");
        driver.await.unwrap().unwrap();
        drop(critical);
        pair.close().await;
    })
    .await
    .unwrap();
}

#[tokio::test(start_paused = true)]
async fn unused_stream_reservations_return_credit_without_consuming_ids() {
    tokio::time::timeout(LIMIT, async {
        let mut transport = TransportConfig::default();
        transport.set_max_concurrent_bidi_streams(1u32);
        let pair = Pair::in_memory(None, Some(transport)).await;
        for _ in 0..32 {
            let reserved = pair.client.try_reserve_bi().unwrap().unwrap();
            assert!(pair.client.try_reserve_bi().unwrap().is_none());
            drop(reserved);
        }
        let reserved = pair.client.try_reserve_bi().unwrap().unwrap();
        let (armed_tx, armed_rx) = oneshot::channel();
        let ordinary = spawn({
            let connection = pair.client.clone();
            async move {
                armed_tx.send(()).unwrap();
                connection.open_bi().await
            }
        });
        armed_rx.await.unwrap();
        assert!(
            !ordinary.is_finished(),
            "ordinary opens cannot steal a reservation"
        );
        drop(reserved);
        let (send, recv) = ordinary.await.unwrap().unwrap();
        assert_eq!(
            u64::from(send.id()),
            0,
            "unused reservations do not consume IDs"
        );
        drop((send, recv));
        pair.close().await;
    })
    .await
    .unwrap();
}

#[tokio::test(start_paused = true)]
async fn reservations_consume_distinct_streams_in_dispatch_order() {
    tokio::time::timeout(LIMIT, async {
        let mut transport = TransportConfig::default();
        transport.set_max_concurrent_bidi_streams(2u32);
        let pair = Pair::in_memory(None, Some(transport)).await;
        let first = pair.client.try_reserve_bi().unwrap().unwrap();
        let second = pair.client.try_reserve_bi().unwrap().unwrap();
        assert!(pair.client.try_reserve_bi().unwrap().is_none());
        let (second_send, second_recv) = second.open().unwrap();
        let (first_send, first_recv) = first.open().unwrap();
        assert_eq!(u64::from(second_send.id()), 0);
        assert_eq!(u64::from(first_send.id()), 4);
        drop((first_send, first_recv, second_send, second_recv));
        pair.close().await;
    })
    .await
    .unwrap();
}

#[tokio::test(start_paused = true)]
async fn reserving_and_opening_streams_does_not_wake_credit_waiters() {
    let mut transport = TransportConfig::default();
    transport.set_max_concurrent_bidi_streams(2u32);
    let pair = Pair::in_memory(None, Some(transport)).await;
    let mut changed = pair.client.stream_budget_watch(Dir::Bi);
    let mut changed = pin!(changed.changed());
    let mut cx = Context::from_waker(Waker::noop());
    assert_matches!(changed.as_mut().poll(&mut cx), Poll::Pending);
    let first = pair.client.try_reserve_bi().unwrap().unwrap();
    let second = pair.client.try_reserve_bi().unwrap().unwrap();
    assert_matches!(changed.as_mut().poll(&mut cx), Poll::Pending);
    let (send, recv) = first.open().unwrap();
    assert_matches!(changed.as_mut().poll(&mut cx), Poll::Pending);
    drop(second);
    assert_matches!(changed.as_mut().poll(&mut cx), Poll::Ready(Some(_)));
    drop((send, recv));
    pair.close().await;
}

#[tokio::test(start_paused = true)]
async fn draining_connection_wakes_admission_waiters_without_stream_credit() {
    tokio::time::timeout(LIMIT, async {
        let mut transport = TransportConfig::default();
        transport.set_max_concurrent_bidi_streams(1u32);
        let pair = Pair::in_memory(None, Some(transport)).await;
        let (sender, driver) =
            client::handshake::<Body, _>(pair.client.clone(), Config::default(), Executor::new())
                .unwrap();
        let client_driver = spawn(driver.run());
        let (mut server, driver) =
            server::handshake(pair.server.clone(), Config::default()).unwrap();
        let server_driver = spawn(driver.run());
        let admission = sender.connection_admission();
        let first = admission.try_acquire(&Extensions::new()).unwrap().unwrap();
        assert!(admission.in_use());
        let changed = admission.changed();
        assert!(admission.try_acquire(&Extensions::new()).unwrap().is_none());
        server.shutdown().unwrap();
        changed.await;
        admission.try_acquire(&Extensions::new()).unwrap_err();
        // Its work goes on, but a draining connection is left for the pool to retire.
        assert!(!admission.in_use());
        // Nothing changes any more, so its watch cannot spin pool waiters.
        let mut watch = pin!(admission.changed());
        assert!(
            watch
                .as_mut()
                .poll(&mut Context::from_waker(Waker::noop()))
                .is_pending()
        );
        drop(first);
        pair.close().await;
        _ = client_driver.await;
        _ = server_driver.await;
    })
    .await
    .unwrap();
}

#[tokio::test(start_paused = true)]
async fn reservation_admission_recovers_the_last_completed_stream_credit() {
    tokio::time::timeout(LIMIT, async {
        let mut transport = TransportConfig::default();
        transport.set_max_concurrent_bidi_streams(1u32);
        let pair = Pair::in_memory(None, Some(transport)).await;
        for _ in 0..8 {
            let reserved = loop {
                let mut changed = pair.client.stream_budget_watch(Dir::Bi);
                if let Some(reserved) = pair.client.try_reserve_bi().unwrap() {
                    break reserved;
                }
                changed.changed().await.unwrap();
            };
            let (mut send, mut recv) = reserved.open().unwrap();
            send.finish().unwrap();
            let (mut response, mut request) = pair.server.accept_bi().await.unwrap();
            assert!(request.read_chunk(1, true).await.unwrap().is_none());
            response.finish().unwrap();
            assert!(recv.read_chunk(1, true).await.unwrap().is_none());
            drop((send, recv, response, request));
        }
        let reserved = pair.client.try_reserve_bi().unwrap();
        pair.client.close(Code::H3_NO_ERROR.value() as u32, b"done");
        drop(reserved);
        pair.close().await;
    })
    .await
    .unwrap();
}

#[tokio::test(start_paused = true)]
async fn returned_credit_wakers_can_inspect_the_connection() {
    struct InspectCredit {
        connection: Connection,
        available: AtomicU64,
    }

    impl Wake for InspectCredit {
        fn wake(self: Arc<Self>) {
            self.available
                .store(self.connection.available_streams(Dir::Bi), Ordering::SeqCst);
        }
    }
    let mut transport = TransportConfig::default();
    transport.set_max_concurrent_bidi_streams(1u32);
    let pair = Pair::in_memory(None, Some(transport)).await;
    let reserved = pair.client.try_reserve_bi().unwrap().unwrap();
    let mut changed = pair.client.stream_budget_watch(Dir::Bi);
    let mut changed = pin!(changed.changed());
    let inspector = Arc::new(InspectCredit {
        connection: pair.client.clone(),
        available: AtomicU64::new(0),
    });
    let waker = Waker::from(inspector.clone());
    let mut cx = Context::from_waker(&waker);
    assert!(changed.as_mut().poll(&mut cx).is_pending());
    drop(reserved);
    assert_eq!(inspector.available.load(Ordering::SeqCst), 1);
    pair.close().await;
}

#[tokio::test(start_paused = true)]
async fn admission_after_remote_close_preserves_retryable_transport_classification() {
    tokio::time::timeout(LIMIT, async {
        let pair = Pair::in_memory(None, None).await;
        let (sender, _driver) =
            client::handshake::<Body, _>(pair.client.clone(), Config::default(), Executor::new())
                .unwrap();
        pair.server
            .close(Code::H3_NO_ERROR.value() as u32, b"shutdown");
        pair.client.closed().await;
        let error = sender
            .connection_admission()
            .try_acquire(&Extensions::new())
            .unwrap_err();
        let error = error.downcast_ref::<ConnectionError>().unwrap();
        assert_eq!(error.domain(), ConnectionErrorDomain::Transport);
        assert_eq!(error.kind(), ConnectionErrorKind::Unavailable);
        pair.close().await;
    })
    .await
    .unwrap();
}

/// A connection whose QUIC transport closed is never busy: its admission watch cannot fire any
/// more, so a busy answer would leave pool waiters for it without a wake.
#[tokio::test(start_paused = true)]
async fn closed_transports_are_never_busy() {
    let pair = Pair::in_memory(None, None).await;
    let (sender, driver) =
        client::handshake::<Body, _>(pair.client.clone(), Config::default(), Executor::new())
            .unwrap();
    let admission = sender.connection_admission();
    let held = admission.try_acquire(&Extensions::new()).unwrap().unwrap();
    assert!(admission.in_use());
    // QUIC records the closure before the HTTP/3 driver observes it.
    pair.client.close(0u32, b"closed");
    assert!(!admission.in_use());
    drop(held);
    assert!(!admission.in_use());
    drop(driver);
    drop(sender);
    pair.close().await;
}

/// Records what a signal tells its listeners.
#[derive(Default)]
struct Told(parking_lot::Mutex<Vec<Change>>);

impl ChangeListener for Told {
    fn changed(&self, change: Change) {
        self.0.lock().push(change);
    }
}

/// Pool admission subscribers learn of a QUIC close pushed by the transport, before the
/// HTTP/3 driver noticed it.
#[tokio::test(start_paused = true)]
async fn closing_the_transport_wakes_admission_subscribers() {
    tokio::time::timeout(LIMIT, async {
        let pair = Pair::in_memory(None, None).await;
        let (sender, driver) =
            client::handshake::<Body, _>(pair.client.clone(), Config::default(), Executor::new())
                .unwrap();
        let admission = sender.connection_admission();
        let held = admission.try_acquire(&Extensions::new()).unwrap().unwrap();
        let told = Arc::new(Told::default());
        admission.subscribe(Arc::downgrade(&told) as Weak<dyn ChangeListener>);
        let changed = admission.changed();
        pair.client.close(0u32, b"closed");
        changed.await;
        assert!(!admission.in_use());
        // The driver notices the close too, and ends admission.
        let _ended = driver.run().await;
        let told = told.0.lock().clone();
        assert!(
            !told.is_empty() && told.iter().all(|change| *change == Change::Other),
            "a close is no freed unit: {told:?}"
        );
        drop((held, sender));
        pair.close().await;
    })
    .await
    .unwrap();
}

/// A full pool whose only connection still holds work on a QUIC transport that closed lets a
/// waiter for another connection proceed, before the HTTP/3 driver noticed the closure.
#[tokio::test(start_paused = true)]
async fn pool_waiters_for_other_ids_pass_a_closed_connection() {
    #[derive(Debug, Clone, PartialEq, Eq, Hash)]
    struct Id(u8);
    impl ConnID for Id {}
    struct Conn(Extensions);
    impl ExtensionsRef for Conn {
        fn extensions(&self) -> &Extensions {
            &self.0
        }
    }

    let pair = Pair::in_memory(None, None).await;
    let (sender, driver) =
        client::handshake::<Body, _>(pair.client.clone(), Config::default(), Executor::new())
            .unwrap();
    let admission = sender.connection_admission();
    let input = Extensions::new();
    // Work that outlives its pool handout, as an upgraded tunnel does.
    let held = admission.try_acquire(&input).unwrap().unwrap();
    let pool = MultiplexPool::new()
        .with_max_streams_per_connection(NonZeroUsize::new(32).unwrap())
        .with_max_connections_total(NonZeroUsize::new(1).unwrap());
    let ConnectionResult::CreatePermit(permit) = pool.get_conn(&Id(0), &input, None).await.unwrap()
    else {
        panic!("a fresh pool creates");
    };
    let extensions = Extensions::new();
    extensions.insert_arc(Arc::new(ConnectionHealthWatcher::default()));
    extensions.insert(admission.clone());
    let handout = pool
        .create(Id(0), Conn(extensions), permit, &input)
        .await
        .unwrap();
    drop(handout);

    pair.client.close(0u32, b"closed");
    let waiting = tokio::time::timeout(LIMIT, pool.get_conn(&Id(1), &input, None))
        .await
        .expect("a waiter for another id is not parked behind a closed connection")
        .unwrap();
    assert_matches!(waiting, ConnectionResult::CreatePermit(_));
    drop(held);
    drop(driver);
    drop(sender);
    pair.close().await;
}

/// Credit a returned reservation frees reaches admission as one unit; a close
/// as a change of any size.
#[tokio::test(start_paused = true)]
async fn returned_stream_credit_reaches_admission_in_units() {
    tokio::time::timeout(LIMIT, async {
        let mut transport = TransportConfig::default();
        transport.set_max_concurrent_bidi_streams(4u32);
        let pair = Pair::in_memory(None, Some(transport)).await;
        let told = Arc::new(Told::default());
        pair.client
            .stream_budget_subscribe(Dir::Bi, Arc::downgrade(&told) as Weak<dyn ChangeListener>);
        let first = pair.client.try_reserve_bi().unwrap().unwrap();
        let second = pair.client.try_reserve_bi().unwrap().unwrap();
        assert!(told.0.lock().is_empty(), "reserving frees nothing");
        drop(first);
        assert_eq!(std::mem::take(&mut *told.0.lock()), [Change::Freed]);
        let (send, recv) = second.open().unwrap();
        assert!(
            told.0.lock().is_empty(),
            "opening a reserved stream frees nothing"
        );
        pair.client.close(0u32, b"done");
        assert_eq!(std::mem::take(&mut *told.0.lock()), [Change::Other]);
        drop((send, recv));
        pair.close().await;
    })
    .await
    .unwrap();
}

#[tokio::test(start_paused = true)]
async fn a_raised_stream_limit_reaches_admission_in_units() {
    tokio::time::timeout(LIMIT, async {
        let mut transport = TransportConfig::default();
        transport.set_max_concurrent_bidi_streams(1u32);
        let pair = Pair::in_memory(None, Some(transport)).await;
        let told = Arc::new(Told::default());
        pair.client
            .stream_budget_subscribe(Dir::Bi, Arc::downgrade(&told) as Weak<dyn ChangeListener>);
        let mut changed = pair.client.stream_budget_watch(Dir::Bi);
        pair.server.set_max_concurrent_bi_streams(4u32);
        changed.changed().await.unwrap();
        assert_eq!(pair.client.available_streams(Dir::Bi), 4);
        assert_eq!(
            std::mem::take(&mut *told.0.lock()),
            [Change::Freed; 3],
            "one per stream"
        );
        pair.close().await;
    })
    .await
    .unwrap();
}

#[tokio::test(start_paused = true)]
async fn admission_without_a_free_permit_leaves_stream_credit_alone() {
    tokio::time::timeout(LIMIT, async {
        let mut transport = TransportConfig::default();
        transport.set_max_concurrent_bidi_streams(2u32);
        let pair = Pair::in_memory(None, Some(transport)).await;
        let config = Config {
            max_requests: 1,
            ..Config::default()
        };
        let (sender, driver) =
            client::handshake::<Body, _>(pair.client.clone(), config, Executor::new()).unwrap();
        let client_driver = spawn(driver.run());
        let (_server, driver) = server::handshake(pair.server.clone(), Config::default()).unwrap();
        let server_driver = spawn(driver.run());
        let admission = sender.connection_admission();
        let held = admission.try_acquire(&Extensions::new()).unwrap().unwrap();
        let mut changed = pair.client.stream_budget_watch(Dir::Bi);
        let mut changed = pin!(changed.changed());
        let mut cx = Context::from_waker(Waker::noop());
        assert_matches!(changed.as_mut().poll(&mut cx), Poll::Pending);
        for _ in 0..4 {
            assert!(admission.try_acquire(&Extensions::new()).unwrap().is_none());
        }
        // No credit was reserved and handed back: its subscribers, the pool's
        // waiters among them, are not woken for nothing.
        assert_matches!(changed.as_mut().poll(&mut cx), Poll::Pending);
        drop(held);
        pair.close().await;
        _ = client_driver.await;
        _ = server_driver.await;
    })
    .await
    .unwrap();
}
