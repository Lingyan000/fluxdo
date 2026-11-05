use std::{
    io::{self, IoSliceMut},
    net::{IpAddr, Ipv4Addr, Ipv6Addr},
    sync::Barrier,
    task::{Context, Poll},
    thread,
};

use rama_core::service::service_fn;
use rama_udp::{
    DatagramCapabilities, DatagramError, DatagramMetadata,
    test_utils::{MemoryDatagramSender, MemoryDatagramSocket},
};

use super::*;

fn limits() -> AssociationLimits {
    AssociationLimits {
        active: NonZeroUsize::new(4).unwrap(),
        active_per_source: NonZeroUsize::new(2).unwrap(),
        sources: NonZeroUsize::new(20).unwrap(),
        tuples: NonZeroUsize::new(20).unwrap(),
        starts_per_window: NonZeroUsize::new(8).unwrap(),
        starts_per_source_window: NonZeroUsize::new(4).unwrap(),
        window: Duration::from_secs(10),
        quarantine: Duration::from_secs(2),
    }
}

fn key(source: u8, port: u16) -> AssociationKey {
    AssociationKey {
        ingress: SocketAddress::local_ipv4(443),
        peer: SocketAddress::new(IpAddr::V4(Ipv4Addr::new(192, 0, 2, source)), port),
    }
}

fn admission(limits: AssociationLimits) -> QuicAssociationAdmission {
    QuicAssociationAdmission::try_new(limits).unwrap()
}

#[test]
fn global_and_source_limits_hold_and_refusals_consume_nothing() {
    let admission = admission(limits());
    let a = admission.try_acquire(key(1, 1)).unwrap();
    let b = admission.try_acquire(key(1, 2)).unwrap();
    assert_eq!(
        admission.try_acquire(key(1, 3)).unwrap_err(),
        AdmissionError::SourceLimit
    );
    let c = admission.try_acquire(key(2, 1)).unwrap();
    let d = admission.try_acquire(key(3, 1)).unwrap();
    assert_eq!(
        admission.try_acquire(key(4, 1)).unwrap_err(),
        AdmissionError::ActiveLimit
    );
    assert_eq!(admission.0.state.lock().global.used, 4);
    let stats = admission.stats();
    assert_eq!((stats.refused_source, stats.refused_active), (1, 1));
    drop((a, b, c, d));
    assert_eq!(admission.0.state.lock().active, 0);
    admission.try_acquire(key(4, 1)).unwrap();
}

#[tokio::test(start_paused = true)]
async fn closing_keeps_the_start_counted_and_quarantines_the_addresses() {
    let admission = admission(AssociationLimits {
        starts_per_source_window: NonZeroUsize::new(2).unwrap(),
        ..limits()
    });
    let route = key(1, 1);
    drop(admission.try_acquire(route).unwrap());
    assert_eq!(
        admission.try_acquire(route).unwrap_err(),
        AdmissionError::TupleInUse
    );
    tokio::time::advance(Duration::from_secs(2)).await;
    drop(admission.try_acquire(route).unwrap());
    tokio::time::advance(Duration::from_secs(2)).await;
    assert_eq!(
        admission.try_acquire(route).unwrap_err(),
        AdmissionError::RateLimit
    );
    // Another port cannot erase the source's earlier starts.
    assert_eq!(
        admission.try_acquire(key(1, 2)).unwrap_err(),
        AdmissionError::RateLimit
    );
    tokio::time::advance(Duration::from_secs(6)).await;
    admission.try_acquire(route).unwrap();
}

#[tokio::test(start_paused = true)]
async fn the_global_rate_survives_source_churn() {
    let admission = admission(AssociationLimits {
        starts_per_window: NonZeroUsize::new(5).unwrap(),
        ..limits()
    });
    for source in 1..=5 {
        drop(admission.try_acquire(key(source, 1)).unwrap());
    }
    assert_eq!(
        admission.try_acquire(key(6, 1)).unwrap_err(),
        AdmissionError::RateLimit
    );
    tokio::time::advance(Duration::from_secs(10)).await;
    admission.try_acquire(key(6, 1)).unwrap();
}

/// Sources that started just before a global window ends are still remembered in the next
/// one; at the fewest sources the limits accept, every new source is admitted there until the
/// global start cap refuses, never by a full history.
#[tokio::test(start_paused = true)]
async fn sources_started_at_a_window_boundary_never_fill_the_history() {
    let base = AssociationLimits {
        active_per_source: NonZeroUsize::new(1).unwrap(),
        starts_per_source_window: NonZeroUsize::new(1).unwrap(),
        quarantine: Duration::from_secs(1),
        ..limits()
    };
    // The fewest sources the validation accepts.
    let limits = (1..)
        .map(|sources| AssociationLimits {
            sources: NonZeroUsize::new(sources).unwrap(),
            ..base
        })
        .find(|limits| QuicAssociationAdmission::try_new(*limits).is_ok())
        .unwrap();
    let admission = admission(limits);
    tokio::time::advance(Duration::from_millis(9_900)).await;
    for source in 1..=8 {
        drop(admission.try_acquire(key(source, 1)).unwrap());
    }
    tokio::time::advance(Duration::from_millis(200)).await;
    let mut admitted = 0;
    let refusal = loop {
        match admission.try_acquire(key(admitted + 9, 1)) {
            Ok(held) => {
                drop(held);
                admitted += 1;
            }
            Err(error) => break error,
        }
    };
    assert_eq!(refusal, AdmissionError::RateLimit);
    assert_eq!(usize::from(admitted), limits.starts_per_window.get());
}

#[test]
fn an_ipv6_source_is_its_64_and_ipv4_mapped_addresses_are_ipv4() {
    let admission = admission(limits());
    let v6 = |last: u16, prefix: u16| AssociationKey {
        ingress: SocketAddress::local_ipv4(443),
        peer: SocketAddress::new(
            IpAddr::V6(Ipv6Addr::new(0x2001, 0xdb8, 0, prefix, 0, 0, 0, last)),
            1,
        ),
    };
    let _held = [
        admission.try_acquire(v6(1, 1)).unwrap(),
        admission.try_acquire(v6(2, 1)).unwrap(),
    ];
    // Another address of the same /64 is the same source.
    assert_eq!(
        admission.try_acquire(v6(3, 1)).unwrap_err(),
        AdmissionError::SourceLimit
    );
    let _other_prefix = admission.try_acquire(v6(1, 2)).unwrap();

    let original = key(9, 1);
    let _ipv4 = admission.try_acquire(original).unwrap();
    let mapped = AssociationKey {
        ingress: SocketAddress::new(IpAddr::V6(Ipv4Addr::LOCALHOST.to_ipv6_mapped()), 443),
        peer: SocketAddress::new(IpAddr::V6(Ipv4Addr::new(192, 0, 2, 9).to_ipv6_mapped()), 1),
    };
    assert_eq!(
        admission.try_acquire(mapped).unwrap_err(),
        AdmissionError::TupleInUse
    );
}

/// No source can use up what the others need, however it paces its attempts: the others,
/// within their own budgets, are always admitted.
#[tokio::test(start_paused = true)]
async fn one_source_cannot_exhaust_admission_for_another() {
    let admission = admission(limits());
    let mut held = Vec::new();
    for round in 0..40u16 {
        // The flooding source takes every slot and start it can, holding some, closing others.
        for port in 0..16 {
            if let Ok(permit) = admission.try_acquire(key(1, round * 16 + port))
                && port % 2 == 0
            {
                held.push(permit);
            }
        }
        if round % 4 == 0 {
            let other = key(2 + (round / 4 % 2) as u8, round);
            assert!(
                admission.try_acquire(other).is_ok(),
                "round {round}: another source was starved"
            );
        }
        tokio::time::advance(Duration::from_millis(700)).await;
        if held.len() > 4 {
            held.clear();
        }
    }
    assert!(admission.stats().refused_source + admission.stats().refused_rate > 0);
}

#[test]
fn limits_one_source_could_exhaust_are_refused() {
    let starving = [
        AssociationLimits {
            active_per_source: limits().active,
            ..limits()
        },
        AssociationLimits {
            starts_per_source_window: limits().starts_per_window,
            ..limits()
        },
        // Two windows of starts from new sources, plus the active ones, need 20 sources.
        AssociationLimits {
            sources: NonZeroUsize::new(19).unwrap(),
            ..limits()
        },
        // Two windows of starts quarantined, plus the active associations, need 20 tuples.
        AssociationLimits {
            tuples: NonZeroUsize::new(19).unwrap(),
            ..limits()
        },
        AssociationLimits {
            window: Duration::ZERO,
            ..limits()
        },
        AssociationLimits {
            quarantine: Duration::MAX,
            ..limits()
        },
    ];
    for limits in starving {
        assert_eq!(
            QuicAssociationAdmission::try_new(limits).unwrap_err(),
            AdmissionError::InvalidLimits,
            "{limits:?}"
        );
    }
    QuicAssociationAdmission::try_new(limits()).unwrap();
}

#[test]
fn concurrent_starts_have_one_owner_and_release_once() {
    let admission = admission(AssociationLimits {
        active: NonZeroUsize::new(2).unwrap(),
        active_per_source: NonZeroUsize::MIN,
        ..limits()
    });
    let barrier = Arc::new(Barrier::new(8));
    let handles: Vec<_> = (0..8)
        .map(|index| {
            let admission = admission.clone();
            let barrier = barrier.clone();
            thread::spawn(move || {
                barrier.wait();
                let result = admission.try_acquire(key(1, index));
                barrier.wait();
                result
            })
        })
        .collect();
    let results: Vec<_> = handles
        .into_iter()
        .map(|handle| handle.join().unwrap())
        .collect();
    assert_eq!(results.iter().filter(|result| result.is_ok()).count(), 1);
    assert_eq!(admission.0.state.lock().active, 1);
    drop(results);
    assert_eq!(admission.0.state.lock().active, 0);
}

/// A socket that cannot report truncated receives.
#[derive(Debug)]
struct NoTruncation(MemoryDatagramSocket);

impl Socket for NoTruncation {
    fn local_addr(&self) -> io::Result<SocketAddress> {
        self.0.local_addr()
    }

    fn peer_addr(&self) -> io::Result<SocketAddress> {
        self.0.peer_addr()
    }
}

impl DatagramSocket for NoTruncation {
    type Sender = MemoryDatagramSender;

    fn create_sender(&self) -> Self::Sender {
        self.0.create_sender()
    }

    fn capabilities(&self) -> DatagramCapabilities {
        let mut capabilities = self.0.capabilities();
        capabilities.receive_truncation = false;
        capabilities
    }

    fn poll_recv(
        &mut self,
        cx: &mut Context<'_>,
        buffers: &mut [IoSliceMut<'_>],
        metadata: &mut [DatagramMetadata],
    ) -> Poll<Result<usize, DatagramError>> {
        self.0.poll_recv(cx, buffers, metadata)
    }
}

fn association(port: u16) -> MemoryDatagramSocket {
    let (_client, ingress) = MemoryDatagramSocket::pair(
        SocketAddress::new(IpAddr::V4(Ipv4Addr::new(192, 0, 2, 1)), port),
        SocketAddress::local_ipv4(443),
        NonZeroUsize::MIN,
    );
    ingress
}

#[tokio::test]
async fn the_service_admits_before_its_inner_service_and_counts_what_it_refuses() {
    let admission = admission(AssociationLimits {
        active_per_source: NonZeroUsize::MIN,
        ..limits()
    });
    // A socket that cannot report truncation is refused before any slot or start is taken.
    let refused = QuicAdmissionLayer::new(admission.clone())
        .into_layer(service_fn(async |_: NoTruncation| Ok::<_, BoxError>(())))
        .serve(NoTruncation(association(1)))
        .await
        .unwrap_err();
    assert_eq!(
        refused.downcast_ref::<AdmissionError>(),
        Some(&AdmissionError::Capability(
            DatagramFeature::ReceiveTruncation
        ))
    );
    assert_eq!(admission.0.state.lock().global.used, 0);

    // The permit is held while the inner service runs, and released after.
    let inner_admission = admission.clone();
    let service = QuicAdmissionLayer::new(admission.clone()).into_layer(service_fn(
        move |_: MemoryDatagramSocket| {
            let admission = inner_admission.clone();
            async move {
                assert_eq!(
                    admission.try_acquire(key(1, 2)).unwrap_err(),
                    AdmissionError::SourceLimit
                );
                Err::<(), _>(BoxError::from(QuicPeekRejectedError(
                    QuicPeekRejection::Deadline,
                )))
            }
        },
    ));
    service.serve(association(1)).await.unwrap_err();
    assert_eq!(admission.0.state.lock().active, 0);
    let stats = admission.stats();
    assert_eq!(stats.refused_capability, 1);
    assert_eq!(stats.refused_source, 1);
    assert_eq!(stats.rejected_deadline, 1);
    admission.record_dropped_datagrams(3);
    assert_eq!(admission.stats().dropped_datagrams, 3);
}

/// Without address validation a flood from many sources cannot be told from many clients; it
/// is bounded by the global caps, which also bound inspections per window, and counted.
#[tokio::test(start_paused = true)]
async fn a_distributed_flood_stays_within_the_global_start_budget_and_is_counted() {
    let admission = admission(limits());
    for window in 0..3u16 {
        let mut admitted = 0;
        for source in 0..200u16 {
            let key = AssociationKey {
                ingress: SocketAddress::local_ipv4(443),
                peer: SocketAddress::new(
                    IpAddr::V4(Ipv4Addr::new(198, 51, (source >> 8) as u8, source as u8)),
                    window,
                ),
            };
            if admission.try_acquire(key).is_ok() {
                admitted += 1;
            }
        }
        assert!(
            admitted <= limits().starts_per_window.get(),
            "window {window}: {admitted}"
        );
        assert!(admitted > 0, "window {window}");
        tokio::time::advance(limits().window).await;
    }
    let stats = admission.stats();
    let refused = stats.refused_rate + stats.refused_history + stats.refused_active;
    assert_eq!(
        refused,
        3 * 200 - 3 * limits().starts_per_window.get() as u64
    );
}
