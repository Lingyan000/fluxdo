//! QUIC version 2 (RFC 9369): the wire constants against the RFC's own vectors, through the
//! provider traits so every TLS backend is held to them, and a v2 handshake end to end.

use std::assert_matches;

use rama_core::bytes::BytesMut;
use rama_quic_proto::{
    ConnectionId, Dir, Side, VarInt, Version,
    version::{ClientVersionPolicy, LongKind, ServerVersionPolicy, VersionPreference},
};

use super::*;

/// Non-empty parameters: BoringSSL refuses to start a QUIC session without any.
fn client_params(cid: ConnectionId) -> TransportParameters {
    TransportParameters {
        initial_src_cid: Some(cid),
        ..TransportParameters::default()
    }
}

fn hex(input: &str) -> Vec<u8> {
    rama_utils::hex::decode(input.split_whitespace().collect::<String>())
        .expect("valid hex in an RFC vector")
}

/// RFC 9369 Appendix A.3: the server Initial protected with v2 Initial keys.
const SERVER_INITIAL_HEADER: &str = "d16b3343cf0008f067a5502a4262b50040750001";
const SERVER_INITIAL_PAYLOAD: &str =
    "02000000000600405a020000560303ee fce7f7b37ba1d1632e96677825ddf739
    88cfc79825df566dc5430b9a045a1200 130100002e00330024001d00209d3c94
    0d89690b84d08a60993c144eca684d10 81287c834d5311bcf32bb9da1a002b00 020304";
const SERVER_INITIAL_PROTECTED: &str =
    "dc6b3343cf0008f067a5502a4262b500 4075d92faaf16f05d8a4398c47089698
    baeea26b91eb761d9b89237bbf872630 17915358230035f7fd3945d88965cf17
    f9af6e16886c61bfc703106fbaf3cb4c fa52382dd16a393e42757507698075b2
    c984c707f0a0812d8cd5a6881eaf21ce da98f4bd23f6fe1a3e2c43edd9ce7ca8 4bed8521e2e140";

/// RFC 9369 Appendix A.4: a Retry for the client Initial of A.2.
const RETRY_WITHOUT_TAG: &str = "cf6b3343cf0008f067a5502a4262b574 6f6b656e";
const RETRY_TAG: &str = "c8646ce8bfe33952d955543665dcc7b6";

#[test]
fn rfc9369_server_initial_is_protected_with_v2_salt_and_labels() {
    let cid = ConnectionId::new(&hex("8394c8f03e515708"));
    let header = hex(SERVER_INITIAL_HEADER);
    let payload = hex(SERVER_INITIAL_PAYLOAD);
    let server = server_config()
        .crypto
        .initial()
        .initial_keys(Version::V2, &cid)
        .unwrap();
    let mut packet = header.clone();
    packet.extend_from_slice(&payload);
    packet.resize(packet.len() + server.local.packet.tag_len(), 0);
    server
        .local
        .packet
        .encrypt(1, &mut packet, header.len())
        .unwrap();
    server.local.header.encrypt(header.len() - 2, &mut packet);
    assert_eq!(packet, hex(SERVER_INITIAL_PROTECTED));

    // The client derives the same keys for the same version from a started session.
    let client = client_config()
        .crypto
        .start_session(Version::V2, "localhost", &client_params(cid))
        .unwrap();
    let read = client
        .initial_keys(Version::V2, &cid, Side::Client)
        .unwrap()
        .remote
        .unwrap();
    read.header.decrypt(header.len() - 2, &mut packet);
    assert_eq!(&packet[..header.len()], header);
    let mut decrypted = BytesMut::from(&packet[header.len()..]);
    read.packet.decrypt(1, &header, &mut decrypted).unwrap();
    assert_eq!(decrypted, payload);
}

#[test]
fn v1_initial_keys_do_not_open_a_v2_initial() {
    let cid = ConnectionId::new(&hex("8394c8f03e515708"));
    let header = hex(SERVER_INITIAL_HEADER);
    let mut packet = hex(SERVER_INITIAL_PROTECTED);
    let read = server_config()
        .crypto
        .initial()
        .initial_keys(Version::V1, &cid)
        .unwrap()
        .remote
        .unwrap();
    read.header.decrypt(header.len() - 2, &mut packet);
    let mut decrypted = BytesMut::from(&packet[header.len()..]);
    assert!(read.packet.decrypt(1, &header, &mut decrypted).is_err());
}

#[test]
fn rfc9369_retry_tag_uses_the_v2_key_and_nonce() {
    let cid = ConnectionId::new(&hex("8394c8f03e515708"));
    let packet = hex(RETRY_WITHOUT_TAG);
    let server = server_config();
    assert_eq!(
        server
            .crypto
            .initial()
            .retry_tag(Version::V2, &cid, &packet)
            .unwrap()[..],
        hex(RETRY_TAG)[..]
    );
    assert_ne!(
        server
            .crypto
            .initial()
            .retry_tag(Version::V1, &cid, &packet)
            .unwrap()[..],
        hex(RETRY_TAG)[..]
    );

    // A client session started in v2 accepts it; one started in v1 does not.
    let mut payload = hex("746f6b656e");
    payload.extend_from_slice(&hex(RETRY_TAG));
    let header = hex("cf6b3343cf0008f067a5502a4262b5");
    for (version, valid) in [(Version::V2, true), (Version::V1, false)] {
        let session = client_config()
            .crypto
            .start_session(version, "localhost", &client_params(cid))
            .unwrap();
        assert_eq!(
            session.is_valid_retry(&cid, &header, &payload),
            valid,
            "{version}"
        );
    }
}

#[test]
fn unknown_versions_are_refused_by_the_provider() {
    let cid = ConnectionId::new(&hex("8394c8f03e515708"));
    let reserved = Version::from_u32(0x0a1a_2a3a);
    assert!(matches!(
        server_config()
            .crypto
            .initial()
            .initial_keys(reserved, &cid),
        Err(crypto::InitialKeysError::UnsupportedVersion)
    ));
    assert_matches!(
        client_config()
            .crypto
            .start_session(reserved, "localhost", &client_params(cid))
            .map(drop),
        Err(ConnectError::UnsupportedVersion),
    );
}

/// A whole connection in version 2: the long headers carry the v2 type bits and version, and
/// data flows both ways.
#[test]
fn v2_handshake_completes_with_v2_long_headers() {
    let _guard = subscribe();
    let mut pair = Pair::default();
    let mut config = client_config();
    config.set_version(Version::V2).unwrap();
    let (client_ch, server_ch) = pair.connect_with(config);

    let wire = Version::V2.wire().unwrap();
    let mut kinds = Vec::new();
    for sent in pair.client_sent.iter().chain(&pair.server_sent) {
        let Some(version) = sent.version else {
            continue;
        };
        assert_eq!(version, Version::V2, "every long header carries v2");
        kinds.push(wire.long_kind(sent.first_byte));
    }
    // Handshake packets ride coalesced behind an Initial, so only Initials lead a datagram.
    assert!(kinds.contains(&LongKind::Initial));
    assert!(!kinds.contains(&LongKind::ZeroRtt) && !kinds.contains(&LongKind::Retry));

    const MSG: &[u8] = b"over version two";
    let s = pair.client_streams(client_ch).open(Dir::Bi).unwrap();
    pair.client_send(client_ch, s).write(MSG).unwrap();
    pair.client_send(client_ch, s).finish().unwrap();
    pair.drive();
    assert_eq!(pair.server_streams(server_ch).accept(Dir::Bi), Some(s));
    let mut recv = pair.server_recv(server_ch, s);
    let mut chunks = recv.read(true).unwrap();
    assert_eq!(chunks.next(usize::MAX).unwrap().unwrap().bytes[..], MSG[..]);
    let _transmit = chunks.finalize();
}

/// Both endpoints can initiate a key update after a v2 handshake, without
/// depending on the randomized threshold for the first automatic update.
#[test]
fn v2_key_updates_carry_stream_data_from_either_initiator() {
    let _guard = subscribe();
    for initiator in [Side::Client, Side::Server] {
        let mut pair = Pair::default();
        let mut config = client_config();
        config.set_version(Version::V2).unwrap();
        let (client, server) = pair.connect_with(config);
        let client_before = pair.client_conn_mut(client).stats().key_updates;
        let server_before = pair.server_conn_mut(server).stats().key_updates;
        let now = pair.time;
        let connection = match initiator {
            Side::Client => pair.client_conn_mut(client),
            Side::Server => pair.server_conn_mut(server),
        };
        assert!(connection.force_key_update(now));
        connection.ping();
        pair.drive();
        exchange(&mut pair, client, server);
        assert_eq!(
            pair.client_conn_mut(client).stats().key_updates,
            client_before + 1
        );
        assert_eq!(
            pair.server_conn_mut(server).stats().key_updates,
            server_before + 1
        );
    }
}

/// A server that speaks only v1 answers a v2 first flight with Version Negotiation that lists v1.
#[test]
fn a_v1_only_server_negotiates_a_v2_client_down() {
    let _guard = subscribe();
    let mut server_endpoint = EndpointConfig::try_with_rand_key().unwrap();
    server_endpoint.set_supported_versions(vec![Version::V1]);
    let server = Endpoint::new(
        Arc::new(server_endpoint),
        Some(Arc::new(server_config())),
        true,
        None,
    );
    let client = Endpoint::new(
        Arc::new(EndpointConfig::try_with_rand_key().unwrap()),
        None,
        true,
        None,
    );
    let mut pair = Pair::new_from_endpoint(client, server);
    let mut config = client_config();
    config.set_version(Version::V2).unwrap();
    let client_ch = pair.begin_connect(config);
    pair.drive();
    match pair.client_conn_mut(client_ch).poll() {
        Some(Event::ConnectionLost {
            reason: ConnectionError::VersionMismatch { .. },
        }) => {}
        other => panic!("expected a version mismatch, got {other:?}"),
    }
}

// ---- RFC 9368 compatible version negotiation -------------------------------------------------

fn server_preferring(versions: Vec<Version>) -> ServerConfig {
    let mut config = server_config();
    config.set_versions(
        ServerVersionPolicy::new()
            .try_with_preference(VersionPreference::Prefer(versions))
            .unwrap(),
    );
    config
}

fn pair_with(server: ServerConfig) -> Pair {
    Pair::new(
        Arc::new(EndpointConfig::try_with_rand_key().unwrap()),
        server,
    )
}

fn exchange(pair: &mut Pair, client_ch: ConnectionHandle, server_ch: ConnectionHandle) {
    const MSG: &[u8] = b"after negotiation";
    let s = pair.client_streams(client_ch).open(Dir::Bi).unwrap();
    pair.client_send(client_ch, s).write(MSG).unwrap();
    pair.client_send(client_ch, s).finish().unwrap();
    pair.drive();
    assert_eq!(pair.server_streams(server_ch).accept(Dir::Bi), Some(s));
    let mut recv = pair.server_recv(server_ch, s);
    let mut chunks = recv.read(true).unwrap();
    assert_eq!(chunks.next(usize::MAX).unwrap().unwrap().bytes[..], MSG[..]);
    let _transmit = chunks.finalize();
}

/// A server that prefers v2 moves a client that offered it, when the client's TLS session can
/// follow (Boring); a client that cannot switch only offers v1 and stays there.
#[test]
fn a_server_preferring_v2_moves_a_client_that_offered_it() {
    let _guard = subscribe();
    let mut pair = pair_with(server_preferring(vec![Version::V2]));
    let config = client_config();
    let switchable = config.versions_policy().needs_switch();
    let (client_ch, server_ch) = pair.connect_with(config);
    let expected = if switchable { Version::V2 } else { Version::V1 };

    assert_eq!(pair.client_conn_mut(client_ch).version(), expected);
    assert_eq!(pair.server_conn_mut(server_ch).version(), expected);
    assert_eq!(
        pair.client_conn_mut(client_ch).original_version(),
        Version::V1
    );
    assert_eq!(
        pair.server_conn_mut(server_ch).original_version(),
        Version::V1
    );

    // The first flight is v1; everything the server sends with a long header is the negotiated
    // version, and a moved client follows it.
    assert_eq!(pair.client_sent[0].version, Some(Version::V1));
    assert!(
        pair.server_sent
            .iter()
            .filter_map(|sent| sent.version)
            .all(|v| v == expected)
    );
    if switchable {
        assert!(
            pair.client_sent
                .iter()
                .filter_map(|sent| sent.version)
                .any(|v| v == Version::V2)
        );
    }
    exchange(&mut pair, client_ch, server_ch);
}

/// RFC 9368 §2.3: a corrupt long header in the server's version must not move the client. An
/// on-path attacker (or a bit flip) that garbles the v2 Initial the server sends to a v2-preferring
/// negotiation must leave the client in its first-flight version, not switch it on a packet that
/// never authenticated.
#[test]
fn a_corrupt_version_trigger_does_not_move_the_client() {
    let _guard = subscribe();
    let mut pair = pair_with(server_preferring(vec![Version::V2]));
    // Garble every v2 long header the client is handed, past the cleartext header so it still
    // parses and reaches the switch decision but never decrypts. QUIC v2 is version 0x6b3343cf.
    pair.client.tamper_inbound = Some(Box::new(|datagram| {
        const V2: [u8; 4] = [0x6b, 0x33, 0x43, 0xcf];
        if datagram.len() < 40 || datagram[0] & 0x80 == 0 || datagram[1..5] != V2 {
            return;
        }
        let dcid_len = datagram[5] as usize;
        let scid_off = 6 + dcid_len;
        let Some(&scid_len) = datagram.get(scid_off) else {
            return;
        };
        // A server Initial carries no token (0-length varint) followed by a 2-byte length varint;
        // start past both so the length stays intact and only the protected bytes are ruined.
        let payload_off = scid_off + 1 + scid_len as usize + 1 + 2;
        for byte in datagram.iter_mut().skip(payload_off).take(6) {
            *byte ^= 0xff;
        }
    }));

    let config = client_config();
    let client_ch = pair.begin_connect(config);
    pair.drive_bounded();
    assert_eq!(
        pair.client_conn_mut(client_ch).version(),
        Version::V1,
        "an unauthenticated v2 packet must not switch the version"
    );
}

#[test]
fn a_server_keeping_the_clients_choice_stays_in_the_first_flights_version() {
    let _guard = subscribe();
    let mut pair = Pair::default();
    let (client_ch, server_ch) = pair.connect_with(client_config());
    assert_eq!(pair.client_conn_mut(client_ch).version(), Version::V1);
    assert_eq!(pair.server_conn_mut(server_ch).version(), Version::V1);
    assert!(
        pair.server_sent
            .iter()
            .filter_map(|sent| sent.version)
            .all(|v| v == Version::V1)
    );
}

#[test]
fn a_client_offering_only_its_version_is_not_moved() {
    let _guard = subscribe();
    let mut pair = pair_with(server_preferring(vec![Version::V2]));
    let mut config = client_config();
    config
        .set_versions(ClientVersionPolicy::new(Version::V1).unwrap())
        .unwrap();
    let (client_ch, server_ch) = pair.connect_with(config);
    assert_eq!(pair.client_conn_mut(client_ch).version(), Version::V1);
    assert_eq!(pair.server_conn_mut(server_ch).version(), Version::V1);
    exchange(&mut pair, client_ch, server_ch);
}

/// A client that starts in v2 keeps v1 in its compatible list, so a server preferring v1 can
/// move it down.
#[test]
fn a_client_starting_in_v2_can_be_moved_down_to_v1() {
    let _guard = subscribe();
    let mut pair = pair_with(server_preferring(vec![Version::V1]));
    let mut config = client_config();
    config.set_version(Version::V2).unwrap();
    let switchable = config.versions_policy().needs_switch();
    let (client_ch, server_ch) = pair.connect_with(config);
    let expected = if switchable { Version::V1 } else { Version::V2 };
    assert_eq!(pair.client_conn_mut(client_ch).version(), expected);
    assert_eq!(pair.server_conn_mut(server_ch).version(), expected);
    assert_eq!(pair.client_sent[0].version, Some(Version::V2));
    exchange(&mut pair, client_ch, server_ch);
}

#[test]
fn client_version_information_presence_controls_actual_peer_parameters() {
    let _guard = subscribe();
    for version in [Version::V1, Version::V2] {
        for advertise in [false, true] {
            let policy = ClientVersionPolicy::new(version)
                .unwrap()
                .try_with_version_information(advertise)
                .unwrap();
            let mut config = client_config();
            config.set_versions(policy).unwrap();
            let mut pair = pair_with(server_preferring(vec![Version::V2, Version::V1]));
            let (client, server) = pair.connect_with(config);
            let observed = &pair
                .server_conn_mut(server)
                .peer_params()
                .version_information;
            assert_eq!(
                observed.is_some(),
                advertise,
                "{version}, advertise={advertise}"
            );
            if let Some(observed) = observed {
                assert_eq!(observed.chosen(), version);
            }
            assert_eq!(pair.client_conn_mut(client).version(), version);
            assert_eq!(pair.server_conn_mut(server).version(), version);
            // Client omission must not suppress the independent server advertisement.
            assert!(
                pair.client_conn_mut(client)
                    .peer_params()
                    .version_information
                    .is_some()
            );
            exchange(&mut pair, client, server);
        }
    }
}

fn omitted_restart_config() -> ClientConfig {
    let mut config = client_config();
    config
        .set_versions(
            ClientVersionPolicy::new(Version::V2)
                .unwrap()
                .try_with_supported(vec![Version::V2, Version::V1])
                .unwrap()
                .try_with_version_information(false)
                .unwrap(),
        )
        .unwrap();
    // Reproduce the driver's post-VN restart state without bypassing peer validation.
    config.negotiation_offer = Some(vec![Version::V1]);
    config.set_version(Version::V1).unwrap();
    config
}

#[test]
fn an_omitted_advertisement_survives_a_justified_negotiation_restart() {
    let _guard = subscribe();
    let config = omitted_restart_config();
    assert_eq!(config.versions_policy().compatible(), [Version::V1]);
    let mut server = server_config();
    server.set_versions(
        ServerVersionPolicy::new()
            .try_with_fully_deployed(vec![Version::V1])
            .unwrap(),
    );
    let mut pair = pair_with(server);
    let (client, server) = pair.connect_with(config);
    assert!(
        pair.server_conn_mut(server)
            .peer_params()
            .version_information
            .is_none()
    );
    assert_eq!(pair.client_conn_mut(client).version(), Version::V1);
    exchange(&mut pair, client, server);
}

fn assert_omitted_restart_refused(available: Vec<Version>, expected_reason: &str) {
    let mut server = server_config();
    server.set_versions(
        ServerVersionPolicy::new()
            .try_with_fully_deployed(available)
            .unwrap()
            .with_reserved_version_grease(false),
    );
    let mut pair = pair_with(server);
    let client = pair.begin_connect(omitted_restart_config());
    pair.drive();
    let mut refusal = None;
    while let Some(event) = pair.client_conn_mut(client).poll() {
        match event {
            Event::HandshakeDataReady => {}
            Event::ConnectionLost {
                reason: ConnectionError::TransportError(error),
            } => {
                refusal = Some(error);
                break;
            }
            other => panic!("the native peer must refuse version negotiation, got {other:?}"),
        }
    }
    let refusal = refusal.expect("the actual peer parameters cause a connection refusal");
    assert_eq!(refusal.code, TransportErrorCode::VERSION_NEGOTIATION_ERROR);
    assert_eq!(refusal.reason, expected_reason);
    assert!(pair.client_conn_mut(client).is_closed());
}

#[test]
fn omitted_advertisement_does_not_accept_an_empty_server_list_after_restart() {
    let _guard = subscribe();
    assert_omitted_restart_refused(
        vec![],
        "server's Available Versions is empty after Version Negotiation",
    );
}

#[test]
fn omitted_advertisement_does_not_accept_an_unjustified_downgrade_after_restart() {
    let _guard = subscribe();
    assert_omitted_restart_refused(
        vec![Version::V2, Version::V1],
        "Version Negotiation led to a version the server's list does not justify",
    );
}

#[test]
fn both_sides_record_the_others_version_information() {
    let _guard = subscribe();
    let mut pair = pair_with(server_preferring(vec![Version::V2]));
    let config = client_config();
    let offered = config.versions_policy().compatible().to_vec();
    let (client_ch, server_ch) = pair.connect_with(config);
    let negotiated = pair.client_conn_mut(client_ch).version();

    let from_client = pair
        .server_conn_mut(server_ch)
        .peer_params()
        .version_information
        .clone()
        .expect("the client sends version_information");
    assert_eq!(from_client.chosen(), Version::V1);
    assert!(offered.iter().all(|v| from_client.available().contains(v)));
    assert!(from_client.available().iter().any(|v| v.is_reserved()));

    let from_server = pair
        .client_conn_mut(client_ch)
        .peer_params()
        .version_information
        .clone()
        .expect("the server sends version_information");
    assert_eq!(from_server.chosen(), negotiated);
    assert!(from_server.available().contains(&Version::V1));
    assert!(from_server.available().contains(&Version::V2));
    assert!(from_server.available().iter().any(|v| v.is_reserved()));
}

/// A server told to report nothing as fully deployed still names the version in use.
#[test]
fn a_server_may_report_an_empty_fully_deployed_list() {
    let _guard = subscribe();
    let mut server = server_config();
    server.set_versions(
        ServerVersionPolicy::new()
            .try_with_fully_deployed(vec![])
            .unwrap()
            .with_reserved_version_grease(false),
    );
    let mut pair = pair_with(server);
    let (client_ch, _) = pair.connect_with(client_config());
    let from_server = pair
        .client_conn_mut(client_ch)
        .peer_params()
        .version_information
        .clone()
        .unwrap();
    assert_eq!(from_server.chosen(), Version::V1);
    assert!(from_server.available().is_empty());
}

/// A ticket belongs to the version it was issued in (RFC 9369 §5): after a switch it is a
/// ticket for the negotiated version, the next first flight starts in that version, and a
/// server that would prefer another version leaves a resuming connection where it is, so
/// 0-RTT arrives in the version the ticket was issued in.
#[test]
fn a_resumed_connection_keeps_its_ticket_version_and_its_0rtt() {
    let _guard = subscribe();
    let first = server_preferring(vec![Version::V2]);
    // The same TLS configuration, so its tickets stay valid, with the opposite preference.
    let mut second = first.clone();
    second.set_versions(
        ServerVersionPolicy::new()
            .try_with_preference(VersionPreference::Prefer(vec![Version::V1]))
            .unwrap(),
    );
    let mut pair = pair_with(first);
    pair.server.handle_incoming = Box::new(validate_incoming);
    let config = client_config();
    let switchable = config.versions_policy().needs_switch();

    let client_ch = pair.begin_connect(config.clone());
    pair.drive();
    let server_ch = pair.server.assert_accept();
    let ticket_version = pair.server_conn_mut(server_ch).version();
    assert_eq!(
        ticket_version,
        if switchable { Version::V2 } else { Version::V1 }
    );
    let now = pair.time;
    pair.client_conn_mut(client_ch)
        .close(now, VarInt::from_u32(0), [][..].into());
    pair.drive();

    // The server would now rather have v1, but a resuming client is not moved.
    pair.server
        .endpoint
        .set_server_config(Some(Arc::new(second)));
    pair.client.addr = SocketAddr::new(
        Ipv6Addr::LOCALHOST.into(),
        CLIENT_PORTS.lock().next().unwrap(),
    );
    pair.client_sent.clear();
    let client_ch = pair.begin_connect(config);
    assert!(
        pair.client_conn_mut(client_ch).has_0rtt(),
        "the ticket resumes"
    );
    assert_eq!(
        pair.client_conn_mut(client_ch).original_version(),
        ticket_version,
        "the first flight follows the ticket's version"
    );
    let s = pair.client_streams(client_ch).open(Dir::Uni).unwrap();
    pair.client_send(client_ch, s).write(b"early").unwrap();
    pair.drive();
    let server_ch = pair.server.assert_accept();
    pair.drive();

    assert_eq!(pair.client_conn_mut(client_ch).version(), ticket_version);
    assert_eq!(pair.server_conn_mut(server_ch).version(), ticket_version);
    assert!(pair.client_conn_mut(client_ch).accepted_0rtt());
    let zero_rtt: Vec<_> = pair
        .client_sent
        .iter()
        .flat_map(|sent| sent.packets.iter())
        .filter(|packet| packet.long_kind() == Some(LongKind::ZeroRtt))
        .collect();
    assert!(!zero_rtt.is_empty(), "0-RTT was sent");
    assert!(
        zero_rtt
            .iter()
            .all(|packet| packet.version == Some(ticket_version))
    );
    exchange(&mut pair, client_ch, server_ch);
}

// ---- RFC 9369 §5: tickets and tokens belong to one version -----------------------------------

/// A session ticket resumes only a connection in the version that issued it.
#[test]
fn a_ticket_is_not_offered_in_another_version() {
    let _guard = subscribe();
    let mut pair = Pair::default();
    pair.server.handle_incoming = Box::new(validate_incoming);
    let config = client_config();

    let client_ch = pair.begin_connect(config.clone());
    pair.drive();
    pair.server.assert_accept();
    let now = pair.time;
    pair.client_conn_mut(client_ch)
        .close(now, VarInt::from_u32(0), [][..].into());
    pair.drive();

    // The same TLS configuration, starting in v2: nothing to resume with.
    let mut v2 = config.clone();
    v2.set_version(Version::V2).unwrap();
    pair.client.addr = SocketAddr::new(
        Ipv6Addr::LOCALHOST.into(),
        CLIENT_PORTS.lock().next().unwrap(),
    );
    let client_ch = pair.begin_connect(v2);
    assert!(!pair.client_conn_mut(client_ch).has_0rtt());
    pair.drive();
    pair.server.assert_accept();
    let now = pair.time;
    pair.client_conn_mut(client_ch)
        .close(now, VarInt::from_u32(0), [][..].into());
    pair.drive();

    // Back in v1, the v1 ticket is still there.
    pair.client.addr = SocketAddr::new(
        Ipv6Addr::LOCALHOST.into(),
        CLIENT_PORTS.lock().next().unwrap(),
    );
    let client_ch = pair.begin_connect(config);
    assert!(pair.client_conn_mut(client_ch).has_0rtt());
}

/// A NEW_TOKEN token validates an address only for a connection in the version that issued it.
#[test]
fn a_new_token_validates_only_the_version_that_issued_it() {
    let _guard = subscribe();
    let mut pair = Pair::default();
    let config = client_config();

    pair.server.handle_incoming = Box::new(|incoming| {
        assert!(!incoming.remote_address_validated());
        IncomingConnectionBehavior::Accept
    });
    let (client_ch, _) = pair.connect_with(config.clone());
    let now = pair.time;
    pair.client_conn_mut(client_ch)
        .close(now, VarInt::from_u32(0), [][..].into());
    pair.drive();

    // The v1 token is not sent with a v2 first flight, so the address is not validated.
    let mut v2 = config.clone();
    v2.set_version(Version::V2).unwrap();
    pair.server.handle_incoming = Box::new(|incoming| {
        assert!(!incoming.remote_address_validated());
        IncomingConnectionBehavior::Accept
    });
    let (client_ch, _) = pair.connect_with(v2);
    let now = pair.time;
    pair.client_conn_mut(client_ch)
        .close(now, VarInt::from_u32(0), [][..].into());
    pair.drive();

    // In v1 it is, and the server accepts it.
    pair.server.handle_incoming = Box::new(|incoming| {
        assert!(incoming.remote_address_validated());
        IncomingConnectionBehavior::Accept
    });
    let (client_ch, _) = pair.connect_with(config);
    let now = pair.time;
    pair.client_conn_mut(client_ch)
        .close(now, VarInt::from_u32(0), [][..].into());
    pair.drive();
}

/// A Version Negotiation packet is as long as a datagram allows. The longest one is read once, in
/// full, and ends the attempt with every version it offered.
#[test]
fn a_maximal_version_negotiation_is_read_whole() {
    let _guard = subscribe();
    let mut pair = Pair::default();
    let client_ch = pair.begin_connect(client_config());
    pair.drive_client();
    let first = pair
        .server
        .inbound
        .pop_front()
        .expect("the client's Initial")
        .packet;
    pair.server.inbound.clear();
    let dcid_len = usize::from(first[5]);
    let dcid = &first[6..6 + dcid_len];
    let scid_len = usize::from(first[6 + dcid_len]);
    let scid = &first[7 + dcid_len..7 + dcid_len + scid_len];
    let mut negotiation = vec![0x80, 0, 0, 0, 0, scid_len as u8];
    negotiation.extend_from_slice(scid);
    negotiation.push(dcid_len as u8);
    negotiation.extend_from_slice(dcid);
    let count = (usize::from(crate::proto::MAX_UDP_PAYLOAD) - negotiation.len()) / 4;
    for i in 0..count as u32 {
        negotiation.extend_from_slice(&(0xfa00_0000 | i).to_be_bytes());
    }
    for _ in 0..2 {
        pair.client.inbound.push_back(Inbound {
            at: pair.time,
            ecn: None,
            packet: negotiation.as_slice().into(),
            from: None,
            to: None,
        });
    }
    pair.drive_client();
    match pair.client_conn_mut(client_ch).poll() {
        Some(Event::ConnectionLost {
            reason: ConnectionError::VersionMismatch { offered },
        }) => assert_eq!(offered.len(), count),
        other => panic!("expected a version mismatch, got {other:?}"),
    }
    assert!(pair.client_conn_mut(client_ch).poll().is_none());
}
