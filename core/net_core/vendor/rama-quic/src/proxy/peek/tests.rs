use std::{num::NonZeroUsize, time::Duration};

use rama_core::{
    Service,
    error::{BoxError, BoxErrorExt as _},
    io::BridgeIo,
    service::service_fn,
};
use rama_net::{
    address::{HostWithPort, SocketAddress},
    client::ConnectorTarget,
    stream::Socket as _,
};
use rama_quic_proto::capture::{CaptureLimits, KeyProvider};
use rama_udp::{
    DatagramMetadata, DatagramSenderExt as _, PrefixedDatagramSocket, SendDatagram,
    UdpPacketSocket, proxy::DatagramToProxyBridge, test_utils::MemoryDatagramSocket,
};
use rama_utils::{hex::decode, octets::kib};
use tokio::time::{advance, timeout};

use super::*;

#[cfg(feature = "boring")]
fn keys() -> impl KeyProvider + Clone {
    crate::tls::BoringTlsProvider
}

#[cfg(not(feature = "boring"))]
fn keys() -> impl KeyProvider + Clone {
    crate::tls::RustlsTlsProvider::new(crate::proto::crypto::rustls::configured_provider())
}

/// The two Initial datagrams of one captured Chrome flight; the ClientHello spans both.
fn chrome_initials() -> [Vec<u8>; 2] {
    [
        include_str!("../../profile/fixtures/chrome-153-initial-1.hex"),
        include_str!("../../profile/fixtures/chrome-153-initial-2.hex"),
    ]
    .map(|hex| decode::<Vec<u8>>(hex.split_whitespace().collect::<String>()).unwrap())
}

fn association() -> (MemoryDatagramSocket, MemoryDatagramSocket) {
    MemoryDatagramSocket::pair(
        SocketAddress::local_ipv4(24000),
        SocketAddress::local_ipv4(24001),
        NonZeroUsize::new(8).unwrap(),
    )
}

fn deliver(ingress: &MemoryDatagramSocket, client: &MemoryDatagramSocket, bytes: &[u8]) {
    let mut metadata = DatagramMetadata::empty();
    metadata.peer = client.local_addr().unwrap();
    metadata.local = ingress.local_addr().unwrap();
    ingress.inject_received(bytes.to_vec(), metadata).unwrap();
}

async fn drain(socket: &mut PrefixedDatagramSocket<MemoryDatagramSocket>) -> Vec<Vec<u8>> {
    let mut buffer = vec![0; kib(64)];
    let mut received = Vec::new();
    while !socket.retained().is_empty() {
        let metadata = socket.recv(&mut buffer).await.unwrap();
        received.push(buffer[..metadata.len].to_vec());
    }
    received
}

#[tokio::test(start_paused = true)]
async fn a_complete_client_hello_reaches_the_inner_service_with_the_flight_replayed() {
    timeout(Duration::from_secs(20), async {
        let (mut client, ingress) = association();
        let initials = chrome_initials();
        for bytes in &initials {
            deliver(&ingress, &client, bytes);
        }
        let peek = PeekQuicClientHelloService::new(
            keys(),
            service_fn(
                async |InputWithQuicClientHello { mut input, peeked }: InputWithQuicClientHello<
                    PrefixedDatagramSocket<MemoryDatagramSocket>,
                >| {
                    let sni = peeked
                        .client_hello
                        .ext_server_name()
                        .map(|name| name.to_string());
                    Ok::<_, BoxError>((sni, drain(&mut input).await))
                },
            ),
        )
        .with_fallback(service_fn(async |_: PrefixedDatagramSocket<_>| {
            Err::<_, BoxError>(BoxError::from_static_str("unexpected fallback"))
        }));
        let (sni, replayed) = peek.serve(ingress).await.unwrap();
        assert!(sni.is_some());
        assert_eq!(replayed, initials);
        // Peeking never answers the client: the association closes without a datagram.
        let mut buffer = [0; 16];
        assert!(matches!(
            client.recv(&mut buffer).await,
            Err(rama_udp::DatagramError::Closed)
        ));
    })
    .await
    .unwrap();
}

#[tokio::test(start_paused = true)]
async fn non_quic_input_goes_to_the_fallback_intact() {
    timeout(Duration::from_secs(20), async {
        let (client, ingress) = association();
        let dns_query = b"\x12\x34\x01\x00\x00\x01\x00\x00\x00\x00\x00\x00".to_vec();
        deliver(&ingress, &client, &dns_query);
        let peek = PeekQuicClientHelloService::new(
            keys(),
            service_fn(async |_: InputWithQuicClientHello<_>| Ok::<_, BoxError>(Vec::new())),
        )
        .with_fallback(service_fn(
            async |mut input: PrefixedDatagramSocket<MemoryDatagramSocket>| {
                Ok::<_, BoxError>(drain(&mut input).await)
            },
        ));
        assert_eq!(peek.serve(ingress).await.unwrap(), vec![dns_query]);
    })
    .await
    .unwrap();
}

/// The datagrams of a flight ending in `class`, and the limits that end it there.
fn flight_ending_in(class: QuicPeekRejection) -> (Vec<Vec<u8>>, CaptureLimits) {
    let [first, second] = chrome_initials();
    let limits = CaptureLimits::default();
    match class {
        QuicPeekRejection::NotQuic => (
            vec![b"\x12\x34\x01\x00\x00\x01\x00\x00\x00\x00\x00\x00".to_vec()],
            limits,
        ),
        QuicPeekRejection::UnsupportedVersion => {
            let mut unknown = first;
            unknown[1..5].copy_from_slice(&0x1a2a_3a4a_u32.to_be_bytes());
            (vec![unknown], limits)
        }
        QuicPeekRejection::Malformed => {
            let mut forged = first;
            *forged.last_mut().unwrap() ^= 1;
            (vec![forged], limits)
        }
        QuicPeekRejection::Budget => (
            vec![first, second],
            CaptureLimits {
                datagrams: 1,
                ..limits
            },
        ),
        QuicPeekRejection::Deadline => (vec![first], limits),
    }
}

#[tokio::test(start_paused = true)]
async fn each_rejection_reaches_the_fallback_only_when_its_class_is_admitted() {
    timeout(Duration::from_secs(20), async {
        let classes = [
            QuicPeekRejection::NotQuic,
            QuicPeekRejection::UnsupportedVersion,
            QuicPeekRejection::Malformed,
            QuicPeekRejection::Budget,
            QuicPeekRejection::Deadline,
        ];
        let only = |class| QuicPeekFallbackPolicy {
            not_quic: class == QuicPeekRejection::NotQuic,
            unsupported_version: class == QuicPeekRejection::UnsupportedVersion,
            malformed: class == QuicPeekRejection::Malformed,
            budget: class == QuicPeekRejection::Budget,
            deadline: class == QuicPeekRejection::Deadline,
        };
        for class in classes {
            // By default only an association that is not QUIC reaches the fallback.
            let defaults = (
                QuicPeekFallbackPolicy::default(),
                class == QuicPeekRejection::NotQuic,
            );
            for (policy, admitted) in [defaults, (only(class), true)] {
                let (client, ingress) = association();
                let (flight, limits) = flight_ending_in(class);
                for bytes in &flight {
                    deliver(&ingress, &client, bytes);
                }
                let peek = PeekQuicClientHelloService::new(
                    keys(),
                    service_fn(async |_: InputWithQuicClientHello<_>| {
                        Err::<_, BoxError>(BoxError::from_static_str("unexpected ClientHello"))
                    }),
                )
                .with_limits(limits)
                .with_peek_timeout(Duration::from_millis(100))
                .with_fallback_policy(policy)
                .with_fallback(service_fn(
                    async |mut input: PrefixedDatagramSocket<MemoryDatagramSocket>| {
                        let reason = input.extensions().get_ref::<QuicPeekRejection>().copied();
                        Ok::<_, BoxError>((reason, drain(&mut input).await))
                    },
                ));
                let result = peek.serve(ingress).await;
                if admitted {
                    assert_eq!(result.unwrap(), (Some(class), flight), "{class}");
                } else {
                    let error = result.unwrap_err();
                    assert_eq!(
                        error.downcast_ref::<QuicPeekRejectedError>(),
                        Some(&QuicPeekRejectedError(class)),
                        "{class}: {error}"
                    );
                }
                drop(client);
            }
        }
    })
    .await
    .unwrap();
}

#[tokio::test(start_paused = true)]
async fn the_default_fallback_rejects() {
    timeout(Duration::from_secs(20), async {
        let (client, ingress) = association();
        deliver(&ingress, &client, b"not quic");
        let peek = PeekQuicClientHelloService::new(
            keys(),
            service_fn(async |_: InputWithQuicClientHello<_>| Ok::<_, BoxError>(())),
        );
        let error = peek.serve(ingress).await.unwrap_err();
        assert!(
            error.to_string().contains("no complete QUIC ClientHello"),
            "{error}"
        );
    })
    .await
    .unwrap();
}

#[tokio::test(start_paused = true)]
async fn the_deadline_is_fixed_when_the_association_is_handed_over() {
    timeout(Duration::from_secs(20), async {
        let (client, ingress) = association();
        let ingress_address = ingress.local_addr().unwrap();
        let [first, second] = chrome_initials();
        deliver(&ingress, &client, &first);
        let peek = PeekQuicClientHelloService::new(
            keys(),
            service_fn(async |_: InputWithQuicClientHello<_>| Ok::<_, BoxError>(())),
        )
        .with_peek_timeout(Duration::from_millis(100));
        let serving = peek.serve(ingress);
        // A late first poll, and the rest of the flight after the deadline, find it expired.
        advance(Duration::from_millis(150)).await;
        client
            .create_sender()
            .send(SendDatagram::new(ingress_address, &second))
            .await
            .unwrap();
        let error = serving.await.unwrap_err();
        assert_eq!(
            error.downcast_ref::<QuicPeekRejectedError>(),
            Some(&QuicPeekRejectedError(QuicPeekRejection::Deadline))
        );
    })
    .await
    .unwrap();
}

#[tokio::test(start_paused = true)]
async fn a_bridge_peeks_ingress_and_keeps_the_prepared_egress() {
    timeout(Duration::from_secs(20), async {
        let (client, ingress) = association();
        let (egress, _origin) = association();
        let egress_local = egress.local_addr().unwrap();
        for bytes in &chrome_initials() {
            deliver(&ingress, &client, bytes);
        }
        let peek = PeekQuicClientHelloService::new(
            keys(),
            service_fn(
                async |InputWithQuicClientHello {
                           input: BridgeIo(_ingress, egress),
                           ..
                       }: InputWithQuicClientHello<
                    BridgeIo<PrefixedDatagramSocket<MemoryDatagramSocket>, MemoryDatagramSocket>,
                >| { Ok::<_, BoxError>(egress.local_addr().unwrap()) },
            ),
        )
        .with_fallback(service_fn(
            async |_: BridgeIo<PrefixedDatagramSocket<_>, _>| {
                Err::<_, BoxError>(BoxError::from_static_str("unexpected fallback"))
            },
        ));
        assert_eq!(
            peek.serve(BridgeIo(ingress, egress)).await.unwrap(),
            egress_local
        );
    })
    .await
    .unwrap();
}

#[tokio::test(start_paused = true)]
async fn a_cut_datagram_ends_the_peek_and_is_replayed_as_received() {
    timeout(Duration::from_secs(20), async {
        let (client, ingress) = association();
        let [first, second] = chrome_initials();
        let mut metadata = DatagramMetadata::empty();
        metadata.peer = client.local_addr().unwrap();
        metadata.local = ingress.local_addr().unwrap();
        metadata.truncated = true;
        metadata.original_len = first.len() + 100;
        ingress.inject_received(first.clone(), metadata).unwrap();
        // Whatever follows, a flight with a cut datagram is never inspected to completion.
        deliver(&ingress, &client, &second);
        let peek = PeekQuicClientHelloService::new(
            keys(),
            service_fn(async |_: InputWithQuicClientHello<_>| Ok::<_, BoxError>(None)),
        )
        .with_fallback_policy(QuicPeekFallbackPolicy {
            malformed: true,
            ..QuicPeekFallbackPolicy::NOT_QUIC
        })
        .with_fallback(service_fn(
            async |mut input: PrefixedDatagramSocket<MemoryDatagramSocket>| {
                let mut buffer = vec![0; kib(64)];
                let metadata = input.recv(&mut buffer).await.unwrap();
                Ok::<_, BoxError>(Some((buffer[..metadata.len].to_vec(), metadata.truncated)))
            },
        ));
        assert_eq!(peek.serve(ingress).await.unwrap(), Some((first, true)));
        drop(client);
    })
    .await
    .unwrap();
}

fn deliver_gro(
    ingress: &MemoryDatagramSocket,
    client: &MemoryDatagramSocket,
    bytes: Vec<u8>,
    segment_size: usize,
) {
    let mut metadata = DatagramMetadata::empty();
    metadata.peer = client.local_addr().unwrap();
    metadata.local = ingress.local_addr().unwrap();
    metadata.segment_size = NonZeroUsize::new(segment_size);
    ingress.inject_received(bytes, metadata).unwrap();
}

/// What a fallback or inner service is replayed: each receive with its segment size.
async fn replayed(
    socket: &mut PrefixedDatagramSocket<MemoryDatagramSocket>,
) -> Vec<(Vec<u8>, Option<NonZeroUsize>)> {
    let mut buffer = vec![0; kib(64)];
    let mut received = Vec::new();
    while !socket.retained().is_empty() {
        let metadata = socket.recv(&mut buffer).await.unwrap();
        received.push((buffer[..metadata.len].to_vec(), metadata.segment_size));
    }
    received
}

#[tokio::test(start_paused = true)]
async fn a_gro_receive_is_inspected_and_charged_per_segment() {
    timeout(Duration::from_secs(20), async {
        let [first, second] = chrome_initials();
        // Equal segments, and a first segment padded past its packets, the last one shorter.
        let padded = first.len() + 70;
        let mut padded_flight = first.clone();
        padded_flight.resize(padded, 0);
        padded_flight.extend_from_slice(&second);
        let cases = [
            ([first.as_slice(), &second].concat(), first.len(), 2),
            (padded_flight, padded, 2),
        ];
        for (flight, segment_size, segments) in cases {
            for datagrams in [segments, segments - 1] {
                let (client, ingress) = association();
                deliver_gro(&ingress, &client, flight.clone(), segment_size);
                let peek = PeekQuicClientHelloService::new(
                    keys(),
                    service_fn(
                        async |InputWithQuicClientHello { mut input, .. }: InputWithQuicClientHello<
                            PrefixedDatagramSocket<MemoryDatagramSocket>,
                        >| { Ok::<_, BoxError>((true, replayed(&mut input).await)) },
                    ),
                )
                .with_limits(CaptureLimits {
                    datagrams,
                    ..CaptureLimits::default()
                })
                .with_fallback_policy(QuicPeekFallbackPolicy::ALL)
                .with_fallback(service_fn(
                    async |mut input: PrefixedDatagramSocket<MemoryDatagramSocket>| {
                        assert_eq!(
                            input.extensions().get_ref::<QuicPeekRejection>(),
                            Some(&QuicPeekRejection::Budget)
                        );
                        Ok::<_, BoxError>((false, replayed(&mut input).await))
                    },
                ));
                let (found, replay) = peek.serve(ingress).await.unwrap();
                assert_eq!(found, datagrams == segments, "{datagrams} datagram budget");
                assert_eq!(
                    replay,
                    vec![(flight.clone(), NonZeroUsize::new(segment_size))]
                );
                drop(client);
            }
        }
    })
    .await
    .unwrap();
}

/// Peeking first and bridging after, a transparent proxy creates an egress only for what it
/// routes on, to the association's original destination, with the peeked ClientHello in hand.
#[tokio::test(start_paused = true)]
async fn a_peeked_association_is_bridged_with_its_client_hello() {
    timeout(Duration::from_secs(20), async {
        let (client, ingress) = association();
        let destination = ingress.local_addr().unwrap();
        ingress
            .extensions()
            .insert(ConnectorTarget(HostWithPort::from(destination)));
        let initials = chrome_initials();
        for bytes in &initials {
            deliver(&ingress, &client, bytes);
        }
        let peek = PeekQuicClientHelloService::new(
            keys(),
            DatagramToProxyBridge::extension_connector_target(service_fn(
                async |InputWithQuicClientHello {
                           input: BridgeIo(mut ingress, egress),
                           peeked,
                       }: InputWithQuicClientHello<
                    BridgeIo<PrefixedDatagramSocket<MemoryDatagramSocket>, UdpPacketSocket>,
                >| {
                    Ok::<_, BoxError>((
                        peeked.client_hello.ext_server_name().is_some(),
                        egress.peer_addr().unwrap(),
                        drain(&mut ingress).await,
                    ))
                },
            )),
        )
        .with_fallback(service_fn(async |_: PrefixedDatagramSocket<_>| {
            Err::<_, BoxError>(BoxError::from_static_str("unexpected fallback"))
        }));
        let (named, egress_peer, replayed) = peek.serve(ingress).await.unwrap();
        assert!(named);
        assert_eq!(egress_peer, destination);
        assert_eq!(replayed, initials);
    })
    .await
    .unwrap();
}
