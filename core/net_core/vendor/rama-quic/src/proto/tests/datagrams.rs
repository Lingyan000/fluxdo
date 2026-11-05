//! What a connection does with an unreliable datagram it has no room for.

use super::*;
use rama_quic_proto::{Dir, frame};
use std::assert_matches;

/// A datagram the peer was told it could send does not end the connection when there is no
/// room to hold it. A stream transfer succeeds after the datagram is dropped.
#[test]
fn a_datagram_with_no_room_is_dropped_and_the_connection_carries_on() {
    let _guard = subscribe();
    // Room for the frame on the wire, not for the payload plus a queue entry.
    const WINDOW: usize = 256;
    let server = ServerConfig {
        transport: Arc::new(TransportConfig {
            datagram_receive_buffer_size: Some(WINDOW),
            ..TransportConfig::default()
        }),
        ..server_config()
    };
    let mut pair = Pair::new(
        Arc::new(EndpointConfig::try_with_rand_key().unwrap()),
        server,
    );
    let (client_ch, server_ch) = pair.connect();

    let limit = pair
        .client_conn_mut(client_ch)
        .datagrams()
        .max_size()
        .expect("the peer offered the extension");
    let sent = vec![0xd1; limit];
    pair.client_datagrams(client_ch)
        .send(sent.into(), true)
        .expect("the sending side admits what it says it may send");
    pair.drive();

    assert!(
        !pair.server_conn_mut(server_ch).is_closed(),
        "the server ended the connection over a datagram it told the client it could send"
    );

    // A stream transfer succeeds after the datagram is dropped.
    let stream = pair
        .client_streams(client_ch)
        .open(Dir::Uni)
        .expect("a stream opens");
    const AFTER: &[u8] = b"the connection still carries traffic";
    pair.client_send(client_ch, stream)
        .write(AFTER)
        .expect("the stream takes it");
    pair.client_send(client_ch, stream)
        .finish()
        .expect("the stream ends");
    pair.drive();
    assert_matches!(
        pair.server_conn_mut(server_ch).poll(),
        Some(Event::Stream(StreamEvent::Opened { dir: Dir::Uni })),
    );
    let mut recv = pair.server_recv(server_ch, stream);
    let mut chunks = recv.read(true).expect("the stream is readable");
    let chunk = chunks
        .next(usize::MAX)
        .expect("a chunk arrives")
        .expect("it carries the payload");
    assert_eq!(&chunk.bytes[..], AFTER, "and it is what was written");
    let _transmit = chunks.finalize();
}

#[test]
fn tiny_peer_datagram_limits_never_emit_an_oversized_frame() {
    for limit in 0..=2 {
        let server = ServerConfig {
            transport: Arc::new(TransportConfig {
                datagram_receive_buffer_size: Some(limit),
                ..TransportConfig::default()
            }),
            ..server_config()
        };
        let mut pair = Pair::new(
            Arc::new(EndpointConfig::try_with_rand_key().unwrap()),
            server,
        );
        let (client_ch, server_ch) = pair.connect();
        let sent = pair.client_datagrams(client_ch).send(Bytes::new(), true);
        match limit {
            0 => assert_eq!(sent, Err(SendDatagramError::UnsupportedByPeer)),
            1 => assert_eq!(sent, Err(SendDatagramError::TooLarge)),
            _ => sent.unwrap(),
        }
        assert_eq!(
            pair.client_datagrams(client_ch).max_size(),
            (limit == 2).then_some(0)
        );
        pair.drive();
        assert!(!pair.server_conn_mut(server_ch).is_closed());
    }
}

#[test]
fn dropping_old_datagrams_makes_room_for_the_new_entry_in_both_roles() {
    const PAYLOAD: usize = 64;
    let budget = 2 * (PAYLOAD + Datagrams::ENTRY_OVERHEAD);
    let transport = Arc::new(TransportConfig {
        datagram_send_buffer_size: budget,
        ..TransportConfig::default()
    });
    let mut server = server_config();
    server.transport = transport.clone();
    let mut client = client_config();
    client.transport = transport;
    let mut pair = Pair::new(
        Arc::new(EndpointConfig::try_with_rand_key().unwrap()),
        server,
    );
    let (client_ch, server_ch) = pair.connect_with(client);
    for marker in 1..=3 {
        pair.client_datagrams(client_ch)
            .send(vec![marker; PAYLOAD].into(), true)
            .unwrap();
        pair.server_datagrams(server_ch)
            .send(vec![marker; PAYLOAD].into(), true)
            .unwrap();
    }
    pair.drive();
    for marker in 2..=3 {
        assert_eq!(
            pair.client_datagrams(client_ch).recv().unwrap().as_ref(),
            vec![marker; PAYLOAD]
        );
        assert_eq!(
            pair.server_datagrams(server_ch).recv().unwrap().as_ref(),
            vec![marker; PAYLOAD]
        );
    }
    assert!(pair.client_datagrams(client_ch).recv().is_none());
    assert!(pair.server_datagrams(server_ch).recv().is_none());
}

#[test]
fn an_unsendable_datagram_does_not_evict_queued_data() {
    for drop_oldest in [false, true] {
        let mut pair = Pair::default();
        let mut client = client_config();
        client.transport = Arc::new(TransportConfig {
            datagram_send_buffer_size: 64 + Datagrams::ENTRY_OVERHEAD,
            ..TransportConfig::default()
        });
        let (client_ch, server_ch) = pair.connect_with(client);
        let queued = Bytes::from_static(b"keep this datagram");
        pair.client_datagrams(client_ch)
            .send(queued.clone(), drop_oldest)
            .unwrap();
        assert_eq!(
            pair.client_datagrams(client_ch)
                .send(vec![0; 65].into(), drop_oldest),
            Err(SendDatagramError::TooLarge),
        );
        pair.drive();
        assert_eq!(pair.server_datagrams(server_ch).recv(), Some(queued));
        assert!(pair.server_datagrams(server_ch).recv().is_none());
    }
}

/// The receive queue is bounded by what holding a datagram costs, entry included, so a peer that
/// sends empty DATAGRAM frames cannot grow it past the window: the oldest are dropped instead
/// and the connection carries on.
#[test]
fn empty_datagrams_cannot_grow_the_receive_queue_past_the_window() {
    let _guard = subscribe();
    const WINDOW: usize = 512;
    const COUNT: usize = 1_000;
    let server = ServerConfig {
        transport: Arc::new(TransportConfig {
            datagram_receive_buffer_size: Some(WINDOW),
            ..TransportConfig::default()
        }),
        ..server_config()
    };
    let mut pair = Pair::new(
        Arc::new(EndpointConfig::try_with_rand_key().unwrap()),
        server,
    );
    let (client_ch, server_ch) = pair.connect();

    for _ in 0..COUNT {
        pair.client_datagrams(client_ch)
            .send(Bytes::new(), true)
            .expect("an empty datagram is sendable");
    }
    pair.drive();

    let mut drained = 0;
    while pair.server_datagrams(server_ch).recv().is_some() {
        drained += 1;
    }
    let fits = WINDOW / size_of::<frame::Datagram>();
    assert!(
        drained <= fits,
        "{drained} empty datagrams were queued where at most {fits} fit the window"
    );
    assert!(drained > 0, "the window still holds some of them");
    assert!(!pair.server_conn_mut(server_ch).is_closed());
}
