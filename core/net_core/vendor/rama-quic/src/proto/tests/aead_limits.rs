//! RFC 9001 §6.6: the limits a provider reports for its keys are the ones the connection
//! enforces, whichever backend supplies them.

use super::*;
use crate::proto::shared::{ConnectionEvent, ConnectionEventInner, DatagramConnectionEvent};
use rama_quic_proto::{
    Dir, TransportError, TransportErrorCode,
    crypto::{CryptoError, PacketKey},
    packet::{FixedLengthConnectionIdParser, PartialDecode},
};

/// The provider's key, reporting limits of the test's choosing.
struct Limited {
    inner: Box<dyn PacketKey>,
    confidentiality: Option<u64>,
    integrity: Option<u64>,
}

impl PacketKey for Limited {
    fn encrypt(&self, packet: u64, buf: &mut [u8], header_len: usize) -> Result<(), CryptoError> {
        self.inner.encrypt(packet, buf, header_len)
    }
    fn decrypt(
        &self,
        packet: u64,
        header: &[u8],
        payload: &mut BytesMut,
    ) -> Result<(), CryptoError> {
        self.inner.decrypt(packet, header, payload)
    }
    fn tag_len(&self) -> usize {
        self.inner.tag_len()
    }
    fn confidentiality_limit(&self) -> u64 {
        self.confidentiality
            .unwrap_or_else(|| self.inner.confidentiality_limit())
    }
    fn integrity_limit(&self) -> u64 {
        self.integrity
            .unwrap_or_else(|| self.inner.integrity_limit())
    }
}

/// Hand `packet` to the client as if the server had sent it.
fn deliver(pair: &mut Pair, client: ConnectionHandle, packet: BytesMut) {
    let (first_decode, remaining) = PartialDecode::new(
        packet,
        &FixedLengthConnectionIdParser::new(8),
        DEFAULT_SUPPORTED_VERSIONS,
        true,
    )
    .unwrap();
    let now = pair.time;
    let remote = pair.server.addr;
    let local = Some(pair.client.addr);
    pair.client_conn_mut(client)
        .handle_event(ConnectionEvent(ConnectionEventInner::Datagram(
            DatagramConnectionEvent {
                now,
                remote,
                local,
                ecn: None,
                first_decode,
                remaining,
            },
        )));
}

/// One 1-RTT packet from the server, taken off the wire before the client saw it.
fn server_packet(pair: &mut Pair, server: ConnectionHandle) -> BytesMut {
    let stream = pair.server_streams(server).open(Dir::Uni).unwrap();
    pair.server_send(server, stream).write(&[42; 128]).unwrap();
    pair.drive_server();
    let datagram = pair
        .client
        .inbound
        .pop_front()
        .expect("the server sent its stream data");
    assert!(pair.client.inbound.is_empty(), "in one datagram");
    assert_eq!(datagram.packet[0] & 0x80, 0, "as a 1-RTT packet");
    datagram.packet
}

/// A copy of `packet` whose AEAD tag is wrong, with the header and its protection sample intact.
fn spoiled(packet: &BytesMut, variant: u8) -> BytesMut {
    let mut copy = packet.clone();
    let last = copy.len() - 1;
    copy[last] ^= variant;
    copy
}

fn lost_because(pair: &mut Pair, ch: ConnectionHandle) -> ConnectionError {
    while let Some(event) = pair.client_conn_mut(ch).poll() {
        if let Event::ConnectionLost { reason } = event {
            return reason;
        }
    }
    panic!("the connection reported its end");
}

/// Packets that fail authentication are dropped without consequence until their number exceeds
/// the integrity limit the provider reports, counted over the connection's life across every
/// key it has used. Then the connection ends naming the limit and processes nothing further.
#[test]
fn authentication_failures_are_counted_across_keys_up_to_the_integrity_limit() {
    let _guard = subscribe();
    const LIMIT: u64 = 4;
    let mut pair = Pair::default();
    let (client, server) = pair.connect();
    pair.drive();
    pair.client_conn_mut(client)
        .wrap_one_rtt_packet_keys(&|inner| {
            Box::new(Limited {
                inner,
                confidentiality: None,
                integrity: Some(LIMIT),
            })
        });
    let genuine = server_packet(&mut pair, server);
    assert_eq!(pair.client_conn_mut(client).authentication_failures(), 0);

    // Half the budget with the first keys.
    for variant in 1..=LIMIT / 2 {
        deliver(&mut pair, client, spoiled(&genuine, variant as u8));
    }
    assert_eq!(
        pair.client_conn_mut(client).authentication_failures(),
        LIMIT / 2
    );
    assert!(!pair.client_conn_mut(client).is_closed());

    // A key update does not start the count over.
    assert!(pair.client_force_key_update(client), "the update starts");
    pair.drive();
    assert_eq!(
        pair.client_conn_mut(client).authentication_failures(),
        LIMIT / 2,
        "the update itself changes nothing"
    );

    // The rest of the budget with the new keys in place: at the limit the connection lives on.
    for variant in LIMIT / 2 + 1..=LIMIT {
        deliver(&mut pair, client, spoiled(&genuine, variant as u8));
    }
    assert_eq!(
        pair.client_conn_mut(client).authentication_failures(),
        LIMIT
    );
    assert!(
        !pair.client_conn_mut(client).is_closed(),
        "reaching the limit is allowed; exceeding it is not"
    );
    let authenticated = pair.client_conn_mut(client).authenticated_packets();

    // One past it, and the connection is gone.
    deliver(&mut pair, client, spoiled(&genuine, LIMIT as u8 + 1));
    assert_eq!(
        pair.client_conn_mut(client).authentication_failures(),
        LIMIT + 1
    );
    match lost_because(&mut pair, client) {
        ConnectionError::TransportError(TransportError {
            code: TransportErrorCode::AEAD_LIMIT_REACHED,
            ref reason,
            ..
        }) if reason == "integrity limit violated" => {}
        other => panic!("the connection ends naming the limit: {other:?}"),
    }
    assert!(pair.client_conn_mut(client).is_drained());

    // Nothing further is processed, whether it authenticates or not.
    deliver(&mut pair, client, genuine.clone());
    deliver(&mut pair, client, spoiled(&genuine, 0x80));
    assert_eq!(
        pair.client_conn_mut(client).authenticated_packets(),
        authenticated
    );
    assert_eq!(
        pair.client_conn_mut(client).authentication_failures(),
        LIMIT + 1
    );
}

/// The confidentiality limit is the provider's number, not a constant of this crate: a key that
/// reports a small budget has it spent exactly, the last packet carrying the close, and the
/// peer is told why.
#[test]
fn a_providers_confidentiality_limit_governs_what_its_keys_protect() {
    let _guard = subscribe();
    let mut pair = Pair::default();
    let (client, server) = pair.connect();
    pair.drive();
    let spent = pair.client_conn_mut(client).packets_sent_with_keys();
    let limit = spent + 2;
    pair.client_conn_mut(client).set_key_phase_size(u64::MAX);
    pair.client_conn_mut(client)
        .wrap_one_rtt_packet_keys(&|inner| {
            Box::new(Limited {
                inner,
                confidentiality: Some(limit),
                integrity: None,
            })
        });
    assert_eq!(pair.client_conn_mut(client).confidentiality_limit(), limit);

    // One packet of ordinary traffic fits.
    let stream = pair.client_streams(client).open(Dir::Uni).unwrap();
    pair.client_send(client, stream)
        .write(b"within budget")
        .unwrap();
    let before = pair.client_sent.len();
    pair.drive_client();
    assert_eq!(pair.client_sent.len() - before, 1);
    assert_eq!(
        pair.client_conn_mut(client).packets_sent_with_keys(),
        limit - 1
    );
    assert!(!pair.client_conn_mut(client).is_closed());

    // The next is the last of the budget, and it is the close.
    pair.client_conn_mut(client).ping();
    let before = pair.client_sent.len();
    pair.drive_client();
    assert_eq!(pair.client_sent.len() - before, 1);
    assert_eq!(pair.client_conn_mut(client).packets_sent_with_keys(), limit);
    match lost_because(&mut pair, client) {
        ConnectionError::TransportError(TransportError {
            code: TransportErrorCode::AEAD_LIMIT_REACHED,
            ref reason,
            ..
        }) if reason == "confidentiality limit reached" => {}
        other => panic!("the connection ends naming the limit: {other:?}"),
    }

    // The peer learns why, and these keys protect nothing more.
    pair.drive();
    assert_eq!(pair.client_conn_mut(client).packets_sent_with_keys(), limit);
    let mut told = None;
    while let Some(event) = pair.server_conn_mut(server).poll() {
        if let Event::ConnectionLost { reason } = event {
            told = Some(reason);
        }
    }
    match told {
        Some(ConnectionError::ConnectionClosed(close))
            if close.error_code == TransportErrorCode::AEAD_LIMIT_REACHED => {}
        other => panic!("the server was told the limit ended it: {other:?}"),
    }
}
