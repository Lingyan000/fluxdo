//! Real QUIC readability barriers make the observation cutoff deterministic.

use super::*;
use crate::h3::{
    connection::{Config, initial_control},
    control::Role,
    tests::Pair,
};
use rama_core::extensions::Extensions;
use rama_quic::{SendStream, TransportConfig};
use std::{collections::BTreeMap, future::poll_fn, sync::Arc, task::Wake, time::Duration};
use tokio::{
    sync::Notify,
    time::{Instant, timeout},
};

struct Readable(Notify);

impl Wake for Readable {
    fn wake(self: Arc<Self>) {
        self.0.notify_one();
    }

    fn wake_by_ref(self: &Arc<Self>) {
        self.0.notify_one();
    }
}

async fn expose_empty_handles(
    pair: &Pair,
    stream_count: usize,
) -> (Vec<PendingUni>, Vec<SendStream>, Vec<Arc<Readable>>) {
    let mut writers = Vec::new();
    for _ in 0..stream_count {
        writers.push(pair.client.open_uni().await.unwrap());
    }
    // A higher stream exposes lower allocated IDs, without supplying their type.
    writers
        .last_mut()
        .unwrap()
        .write_all(&[0x21])
        .await
        .unwrap();
    let mut pending = Vec::new();
    for _ in 0..stream_count {
        pending.push(PendingUni {
            stream: Box::new(pair.server.accept_uni().await.unwrap()),
            kind: VarIntDecoder::new(),
        });
    }
    let mut readable = Vec::new();
    for stream in &mut pending[..3] {
        let signal = Arc::new(Readable(Notify::new()));
        let waker = Waker::from(signal.clone());
        let mut cx = Context::from_waker(&waker);
        assert!(stream.stream.poll_read_chunk(&mut cx, 64).is_pending());
        readable.push(signal);
    }
    (pending, writers, readable)
}

#[tokio::test(start_paused = true)]
async fn readable_types_are_drained_before_the_first_request_is_published() {
    for startup in ["empty", "complete", "partial"] {
        timeout(Duration::from_secs(20), async {
            let pair = Pair::in_memory(None, None).await;
            let (pending, mut writers, readable) = expose_empty_handles(&pair, 4).await;
            writers[0]
                .write_all(&initial_control(&Config::default(), Role::Client, false).unwrap())
                .await
                .unwrap();
            readable[0].0.notified().await;
            if startup == "complete" {
                writers[1].write_all(&[2]).await.unwrap();
                writers[2].write_all(&[3]).await.unwrap();
                readable[1].0.notified().await;
                readable[2].0.notified().await;
            } else if startup == "partial" {
                // A legal two-byte encoding of type2, split after its first byte.
                writers[1].write_all(&[0x40]).await.unwrap();
                readable[1].0.notified().await;
            }

            let shared = Shared::new(
                Config {
                    observation: Some(Default::default()),
                    ..Config::default()
                },
                Role::Server,
                Extensions::new(),
            )
            .unwrap();
            let (_, first) = shared.request_observation(0, &[]).unwrap();
            assert!(first.first_request.get().is_none());
            let mut receiver = Observed::new(&pair.server, &shared, |input: TypedUni| {
                receive_uni(
                    &pair.server,
                    shared.clone(),
                    input.stream,
                    (input.kind, input.chunk),
                )
            });
            receiver.pending = pending;
            let before = Instant::now();
            {
                let mut running = pin!(receiver.run());
                poll_fn(|cx| {
                    assert!(running.as_mut().poll(cx).is_pending());
                    if first.first_request.get().is_some() {
                        Poll::Ready(())
                    } else {
                        Poll::Pending
                    }
                })
                .await;
            }
            assert_eq!(
                Instant::now(),
                before,
                "empty optional streams must not require a timeout"
            );
            let boundary = first.first_request.get().unwrap();
            let streams: BTreeMap<_, _> = boundary
                .streams
                .iter()
                .map(|stream| (stream.stream_id, stream.stream_type))
                .collect();
            assert_eq!(streams.get(&2), Some(&0));
            assert_eq!(streams.get(&14), Some(&0x21));
            if startup == "complete" {
                assert_eq!(streams.get(&6), Some(&2));
                assert_eq!(streams.get(&10), Some(&3));
            } else {
                assert!(!streams.contains_key(&6));
                assert!(!streams.contains_key(&10));
            }
            assert!(boundary.settings_received && boundary.completeness.streams);
            if startup == "partial" {
                writers[1].write_all(&[2]).await.unwrap();
                let mut running = pin!(receiver.run());
                poll_fn(|cx| {
                    assert!(running.as_mut().poll(cx).is_pending());
                    if shared
                        .observation_snapshot()
                        .unwrap()
                        .streams
                        .iter()
                        .any(|stream| stream.stream_id == 6)
                    {
                        Poll::Ready(())
                    } else {
                        Poll::Pending
                    }
                })
                .await;
                assert!(!boundary.streams.iter().any(|stream| stream.stream_id == 6));
            }
            let (_, later) = shared.request_observation(4, &[]).unwrap();
            assert!(Arc::ptr_eq(boundary, later.first_request.get().unwrap()));
            drop(receiver);
            drop(writers);
            pair.close().await;
        })
        .await
        .unwrap();
    }
}

#[tokio::test(start_paused = true)]
async fn a_classification_quantum_yields_without_publishing_a_partial_round() {
    timeout(Duration::from_secs(20), async {
        let config = Config {
            observation: Some(Default::default()),
            max_pending_uni_streams: 64,
            ..Config::default()
        };
        let mut transport = TransportConfig::default();
        config.configure_transport(&mut transport).unwrap();
        let pair = Pair::in_memory(None, Some(transport)).await;
        let (pending, mut writers, readable) = expose_empty_handles(&pair, 40).await;
        writers[0]
            .write_all(&initial_control(&Config::default(), Role::Client, false).unwrap())
            .await
            .unwrap();
        readable[0].0.notified().await;
        let shared = Shared::new(config, Role::Server, Extensions::new()).unwrap();
        let (_, first) = shared.request_observation(0, &[]).unwrap();
        let mut receiver = Observed::new(&pair.server, &shared, |input: TypedUni| {
            receive_uni(
                &pair.server,
                shared.clone(),
                input.stream,
                (input.kind, input.chunk),
            )
        });
        receiver.pending = pending;
        {
            let mut running = pin!(receiver.run());
            let waker = Waker::noop();
            let mut cx = Context::from_waker(waker);
            assert!(running.as_mut().poll(&mut cx).is_pending());
            assert!(
                first.first_request.get().is_none(),
                "the first quantum did not inspect all40 handles"
            );
            for _ in 0..4 {
                assert!(running.as_mut().poll(&mut cx).is_pending());
                if first.first_request.get().is_some() {
                    break;
                }
            }
            let boundary = first
                .first_request
                .get()
                .expect("the retained cursor must finish a bounded round");
            assert!(boundary.streams.iter().any(|stream| stream.stream_id == 2));
            assert!(
                boundary
                    .streams
                    .iter()
                    .any(|stream| stream.stream_id == 158)
            );
        }
        drop(receiver);
        drop(writers);
        pair.close().await;
    })
    .await
    .unwrap();
}

#[tokio::test(start_paused = true)]
async fn a_partial_settings_frame_cannot_publish_a_complete_request_boundary() {
    timeout(Duration::from_secs(20), async {
        let pair = Pair::in_memory(None, None).await;
        let (pending, mut writers, readable) = expose_empty_handles(&pair, 4).await;
        let control = initial_control(&Config::default(), Role::Client, false).unwrap();
        writers[0]
            .write_all(&control[..control.len() - 1])
            .await
            .unwrap();
        writers[1].write_all(&[2]).await.unwrap();
        writers[2].write_all(&[3]).await.unwrap();
        for signal in &readable {
            signal.0.notified().await;
        }
        let shared = Shared::new(
            Config {
                observation: Some(Default::default()),
                ..Config::default()
            },
            Role::Server,
            Extensions::new(),
        )
        .unwrap();
        let (_, first) = shared.request_observation(0, &[]).unwrap();
        let mut receiver = Observed::new(&pair.server, &shared, |input: TypedUni| {
            receive_uni(
                &pair.server,
                shared.clone(),
                input.stream,
                (input.kind, input.chunk),
            )
        });
        receiver.pending = pending;
        {
            let mut running = pin!(receiver.run());
            assert!(poll_fn(|cx| Poll::Ready(running.as_mut().poll(cx).is_pending())).await);
            assert!(first.first_request.get().is_none());
            assert!(!shared.observation_snapshot().unwrap().settings_received);
            writers[0]
                .write_all(&control[control.len() - 1..])
                .await
                .unwrap();
            poll_fn(|cx| {
                assert!(running.as_mut().poll(cx).is_pending());
                if first.first_request.get().is_some() {
                    Poll::Ready(())
                } else {
                    Poll::Pending
                }
            })
            .await;
        }
        let boundary = first.first_request.get().unwrap();
        assert!(boundary.settings_received && boundary.completeness.settings);
        assert_eq!(boundary.streams.len(), 4);
        drop(receiver);
        drop(writers);
        pair.close().await;
    })
    .await
    .unwrap();
}
