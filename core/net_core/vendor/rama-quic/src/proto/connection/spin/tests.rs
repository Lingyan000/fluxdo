use super::*;
use crate::proto::{
    Endpoint, EndpointConfig, Instant,
    connection::migration::PreviousPath,
    endpoint::ConnectionHandle,
    tests::{
        Pair,
        util::{client_config, server_config},
    },
};
use rama_core::bytes::BytesMut;
use rama_quic_proto::{
    Version,
    packet::{
        FixedLengthConnectionIdParser, Header, PacketNumber, PartialDecode, SPIN_BIT, SpaceId,
    },
    version::ClientVersionPolicy,
};
use rand::SeedableRng;
use std::sync::Arc;

fn pair(
    seed: u8,
    allow: [bool; 2],
    version: Version,
) -> (Pair, ConnectionHandle, ConnectionHandle) {
    let endpoint = EndpointConfig::try_with_rand_key()
        .expect("test reset key")
        .with_rng_seed([seed; 32]);
    let mut server = server_config();
    Arc::make_mut(&mut server.transport).set_allow_spin(allow[1]);
    let mut client = client_config();
    Arc::make_mut(&mut client.transport).set_allow_spin(allow[0]);
    client
        .set_versions(ClientVersionPolicy::new(version).expect("supported test version"))
        .expect("test version policy");
    let server_endpoint = Arc::new(endpoint.clone().with_rng_seed([seed.wrapping_add(64); 32]));
    let mut pair = Pair::new_from_endpoint(
        Endpoint::new(Arc::new(endpoint), None, true, None),
        Endpoint::new(server_endpoint, Some(Arc::new(server)), true, None),
    );
    let (client, server) = pair.connect_with(client);
    assert_eq!(pair.client_conn_mut(client).version(), version);
    (pair, client, server)
}

/// Select a fixed-seed fixture, never force the production suppression decision.
fn selected(
    allow: [bool; 2],
    enabled: [bool; 2],
    version: Version,
) -> (Pair, ConnectionHandle, ConnectionHandle) {
    for seed in 0..=255 {
        let (mut pair, client, server) = pair(seed, allow, version);
        if [
            pair.client_conn_mut(client).spin_enabled,
            pair.server_conn_mut(server).spin_enabled,
        ] == enabled
        {
            return (pair, client, server);
        }
    }
    panic!("fixed seed population has no requested fixture {enabled:?}");
}

/// Protect deliberate peer input with real keys. Flipping the wire bit afterwards would
/// invalidate the AEAD tag, which is tested separately below.
fn packet(peer: &Connection, number: u64, spin: bool) -> BytesMut {
    let keys = &peer.spaces[SpaceId::Data]
        .crypto
        .as_ref()
        .expect("established peer keys")
        .local;
    let mut bytes = Vec::new();
    let header = Header::Short {
        dst_cid: peer.rem_cids.active(),
        number: PacketNumber::U32(number as u32),
        spin,
        key_phase: peer.key_phase,
    }
    .encode(&mut bytes);
    bytes.push(1); // PING
    bytes.resize(bytes.len() + 32 + keys.packet.tag_len(), 0);
    header
        .finish(&mut bytes, &*keys.header, Some((number, &*keys.packet)))
        .expect("protect test packet");
    bytes.as_slice().into()
}

fn receive(
    conn: &mut Connection,
    now: Instant,
    from: SocketAddr,
    local: Option<SocketAddr>,
    packet: BytesMut,
) {
    let (decoded, rest) = PartialDecode::new(
        packet,
        &FixedLengthConnectionIdParser::new(conn.local_cid_state.cid_len()),
        &[Version::V1, Version::V2],
        true,
    )
    .expect("decode protected test packet");
    assert!(rest.is_none());
    conn.handle_decode(now, from, local, None, decoded);
}

fn wire_spin(conn: &mut Connection, now: Instant) -> bool {
    let bytes = conn.encode_peer_packet_for_test(now, conn.rem_cids.active(), &[1]);
    assert_eq!(bytes[0] & 0x80, 0, "a short header");
    bytes[0] & SPIN_BIT != 0
}

#[test]
fn spin_reflects_or_inverts_only_new_authenticated_1rtt_on_its_path() {
    for version in [Version::V1, Version::V2] {
        for client_receives in [false, true] {
            let (mut pair, client, server) = selected([true; 2], [true; 2], version);
            let now = pair.time;
            let peer = if client_receives {
                pair.server_conn_mut(server)
            } else {
                pair.client_conn_mut(client)
            };
            let packets = [
                packet(peer, 1000, false),
                packet(peer, 1002, true),
                packet(peer, 1001, false),
                packet(peer, 1003, false),
            ];
            let conn = if client_receives {
                pair.client_conn_mut(client)
            } else {
                pair.server_conn_mut(server)
            };
            let (remote, local) = (conn.path.remote, conn.path.local);
            receive(conn, now, remote, local, packets[0].clone());
            assert_eq!(wire_spin(conn, now), client_receives);
            receive(conn, now, remote, local, packets[1].clone());
            assert_eq!(wire_spin(conn, now), !client_receives);
            for bytes in [packets[0].clone(), packets[2].clone()] {
                receive(conn, now, remote, local, bytes);
                assert_eq!(
                    wire_spin(conn, now),
                    !client_receives,
                    "duplicate/reordering"
                );
            }
            let mut invalid = packets[3].clone();
            invalid[0] ^= SPIN_BIT;
            let failures = conn.authentication_failures;
            receive(conn, now, remote, local, invalid);
            assert_eq!(conn.authentication_failures, failures + 1);
            assert_eq!(wire_spin(conn, now), !client_receives, "AEAD failure");
            for space in [SpaceId::Initial, SpaceId::Handshake, SpaceId::Data] {
                conn.on_packet_authenticated(now, space, None, Some(10_000), false);
                assert_eq!(
                    wire_spin(conn, now),
                    !client_receives,
                    "non-1-RTT space {space:?}"
                );
            }
            receive(conn, now, remote, local, packets[3].clone());
            assert_eq!(
                wire_spin(conn, now),
                client_receives,
                "spin has its own 1-RTT watermark"
            );
            assert!(!conn.is_closed());
        }
    }
}

#[test]
fn spin_disabled_and_suppressed_ignore_input_and_draw_from_rng() {
    for (allow, desired) in [
        ([false, true], [false, true]),
        ([true, false], [true, false]),
        ([true; 2], [false; 2]),
        ([true; 2], [false, true]),
        ([true; 2], [true, false]),
    ] {
        let (mut pair, client, server) = selected(allow, desired, Version::V1);
        for client_side in [true, false] {
            let conn = if client_side {
                pair.client_conn_mut(client)
            } else {
                pair.server_conn_mut(server)
            };
            if conn.spin_enabled {
                continue;
            }
            assert!(conn.spins.is_empty());
            let (remote, local, cid) = (conn.path.remote, conn.path.local, conn.rem_cids.active());
            conn.rng = rand::rngs::StdRng::from_seed([42; 32]);
            let mut expected = rand::rngs::StdRng::from_seed([42; 32]);
            for number in 0..32 {
                conn.receive_spin(remote, local, number, number % 2 == 0);
                assert_eq!(
                    conn.send_spin(remote, local, cid),
                    expected.random::<bool>()
                );
            }
            assert!(
                conn.spins.is_empty(),
                "disabled input does not even retain dead state"
            );
        }
    }
}

#[test]
fn spin_cid_rotation_resets_without_reopening_the_reordering_window() {
    for version in [Version::V1, Version::V2] {
        let (mut pair, client, server) = selected([true; 2], [true; 2], version);
        let now = pair.time;
        for client_side in [true, false] {
            let conn = if client_side {
                pair.client_conn_mut(client)
            } else {
                pair.server_conn_mut(server)
            };
            let (remote, local) = (conn.path.remote, conn.path.local);
            conn.receive_spin(remote, local, 1000, !client_side);
            assert!(wire_spin(conn, now));
            assert!(conn.update_rem_cid(now));
            assert!(!wire_spin(conn, now), "CID-only change");
            conn.receive_spin(remote, local, 999, !client_side);
            assert!(!wire_spin(conn, now));
            conn.receive_spin(remote, local, 1001, !client_side);
            assert!(wire_spin(conn, now));
            assert!(conn.update_rem_cid(now));
            conn.receive_spin(remote, local, 1002, !client_side);
            assert!(
                wire_spin(conn, now),
                "post-change reception precedes first send"
            );
            let seq = conn.rem_cids.active_seq() + 10;
            conn.apply_new_cid(
                now,
                rama_quic_proto::frame::NewConnectionId {
                    sequence: seq,
                    retire_prior_to: seq,
                    id: ConnectionId::new(&[42; 8]),
                    reset_token: rama_quic_proto::ResetToken::from([42; 16]),
                },
            )
            .unwrap();
            assert!(
                !wire_spin(conn, now),
                "retire_prior_to changes the destination CID"
            );
            assert!(
                conn.spin_enabled,
                "the lifetime suppression choice does not change"
            );
        }
    }
}

#[test]
fn spin_paths_keep_independent_watermarks_and_late_old_packets_cannot_undo_reset() {
    let (mut pair, _, server) = selected([true; 2], [true; 2], Version::V1);
    let now = pair.time;
    let conn = pair.server_conn_mut(server);
    let (old, local, cid) = (conn.path.remote, conn.path.local, conn.rem_cids.active());
    conn.receive_spin(old, local, 1000, true);
    assert!(conn.send_spin(old, local, cid));
    let mut moved = old;
    moved.set_port(old.port() + 1);
    conn.migrate(
        now,
        moved,
        local,
        PreviousPath::Keep(super::super::migration::PrevCid::Active),
    );
    assert!(
        !conn.send_spin(moved, local, cid),
        "NAT rebinding starts at zero even with same CID"
    );
    conn.receive_spin(old, local, 2000, true);
    assert!(!conn.send_spin(moved, local, cid));
    conn.receive_spin(moved, local, 1500, true);
    assert!(
        conn.send_spin(moved, local, cid),
        "newer on this path, lower than the other path"
    );
    conn.receive_spin(moved, local, 1400, false);
    assert!(conn.send_spin(moved, local, cid));
    assert!(conn.abandon_current_path(now));
    assert!(
        conn.send_spin(old, local, cid),
        "fallback restores that path's signal"
    );
    let mut other_local = local.unwrap();
    other_local.set_port(other_local.port() + 1);
    assert!(
        !conn.send_spin(old, Some(other_local), cid),
        "a different local socket is another path"
    );
}

#[test]
fn spin_state_is_bounded_under_authenticated_path_churn() {
    let (mut pair, _, server) = selected([true; 2], [true; 2], Version::V1);
    let conn = pair.server_conn_mut(server);
    let (remote, local, cid) = (conn.path.remote, conn.path.local, conn.rem_cids.active());
    conn.receive_spin(remote, local, 1000, true);
    for port in 10_000..11_000 {
        let mut off_path = remote;
        off_path.set_port(port);
        conn.receive_spin(off_path, local, u64::from(port), false);
        assert!(conn.spins.len() <= 2);
        assert!(conn.send_spin(remote, local, cid));
    }
}

#[test]
fn spin_first_cid_association_preserves_an_already_received_edge() {
    let mut spin = Spin::default();
    spin.receive(10, true, false);
    let cid = ConnectionId::new(&[1; 8]);
    spin.change_cid(cid);
    assert!(spin.send(cid), "first association is not a CID change");
    spin.change_cid(ConnectionId::new(&[2; 8]));
    assert!(!spin.value);
    spin.receive(9, true, false);
    assert!(!spin.value, "changing CID retains the watermark");
}

#[test]
fn spin_send_and_receive_share_keys_for_all_sending_roles_after_rebind() {
    assert!(
        same_local(
            Some("[::]:4000".parse().unwrap()),
            Some("127.0.0.1:4000".parse().unwrap())
        ),
        "a dual-stack wildcard socket may report an IPv4 local address"
    );
    let (mut pair, client, _) = selected([true; 2], [true; 2], Version::V1);
    let now = pair.time;
    let conn = pair.client_conn_mut(client);
    assert!(
        conn.path.local.is_none(),
        "client transport has no receive binding"
    );
    let original = conn.path.remote;
    let mut current = original;
    current.set_port(original.port() + 1);
    conn.migrate(
        now,
        current,
        None,
        PreviousPath::Keep(super::super::migration::PrevCid::Active),
    );
    let mut preferred = current;
    preferred.set_port(current.port() + 1);
    conn.preferred_address = Some(preferred);
    conn.begin_candidate();
    assert!(conn.candidate.is_some());
    for port in [4000, 4001] {
        let local: SocketAddr = format!("[::1]:{port}").parse().unwrap();
        let wildcard: SocketAddr = format!("[::]:{port}").parse().unwrap();
        for provenance in [None, Some(local), Some(wildcard)] {
            conn.set_spin_local_address(provenance);
            let mut off_path = preferred;
            off_path.set_port(preferred.port() + 1);
            // These are the tuple forms passed by every PacketBuilder caller: main/MTU,
            // previous challenge, preferred probe, off-path response and server candidate.
            for (role, remote, sending_local) in [
                ("main/MTU", current, None),
                ("previous challenge", original, None),
                ("preferred probe", preferred, None),
                ("off-path response", off_path, Some(local)),
                ("server candidate", off_path, Some(local)),
            ] {
                for cid in [ConnectionId::new(&[1; 8]), ConnectionId::new(&[])] {
                    conn.spins.clear();
                    conn.send_spin(remote, sending_local, cid);
                    conn.receive_spin(remote, Some(local), 1000, false);
                    assert!(
                        conn.send_spin(remote, sending_local, cid),
                        "{role}, port {port}, CID {cid:?}"
                    );
                    assert_eq!(
                        conn.spins.len(),
                        1,
                        "receive and send share one key: {role}"
                    );
                }
            }
        }
    }
}

#[test]
fn spin_inverts_a_new_peer_cid_without_discarding_the_received_edge() {
    for version in [Version::V1, Version::V2] {
        let (mut pair, client, server) = selected([true; 2], [true; 2], version);
        let now = pair.time;
        let before = packet(pair.server_conn_mut(server), 1000, true);
        assert!(pair.server_conn_mut(server).update_rem_cid(now));
        let after = packet(pair.server_conn_mut(server), 1001, false);
        let conn = pair.client_conn_mut(client);
        let (remote, local) = (conn.path.remote, conn.path.local);
        receive(conn, now, remote, local, before);
        assert!(!wire_spin(conn, now));
        receive(conn, now, remote, local, after);
        assert!(wire_spin(conn, now));
    }
}

#[test]
fn spin_server_keys_include_current_previous_and_preferred_local_paths() {
    for wildcard in [false, true] {
        let (mut pair, _, server) = selected([true; 2], [true; 2], Version::V1);
        let now = pair.time;
        let conn = pair.server_conn_mut(server);
        let reported = conn.path.local.unwrap();
        let received_cid = conn.path.received_dcid.unwrap();
        let mut bound = reported;
        if wildcard {
            bound.set_ip(std::net::Ipv6Addr::UNSPECIFIED.into());
        }
        conn.path.local = Some(bound);
        let previous = conn.path.remote;
        let mut current = previous;
        current.set_port(previous.port() + 1);
        conn.migrate(
            now,
            current,
            Some(bound),
            PreviousPath::Keep(super::super::migration::PrevCid::Active),
        );
        assert!(conn.prev_path.is_some());
        let preferred: SocketAddr = "[::1]:4500".parse().unwrap();
        let super::super::ConnectionSide::Server { server_config } = &mut conn.side else {
            panic!("server fixture")
        };
        let SocketAddr::V6(preferred_v6) = preferred else {
            panic!("IPv6 preferred-address fixture")
        };
        Arc::make_mut(server_config).set_preferred_address_v6(preferred_v6);
        conn.observe_server_preferred(
            now,
            current,
            Some(preferred),
            1000,
            received_cid,
            1200,
            false,
        )
        .unwrap();
        let candidate = conn.server_candidate.as_ref().unwrap();
        let candidate_path = (candidate.remote, candidate.local);
        let mut off_path = current;
        off_path.set_port(current.port() + 1);
        for (role, remote, sending_local, received_local) in [
            ("current", current, Some(bound), Some(reported)),
            ("previous challenge", previous, Some(bound), Some(reported)),
            (
                "server preferred candidate",
                candidate_path.0,
                candidate_path.1,
                Some(preferred),
            ),
            (
                "off-path response",
                off_path,
                Some(reported),
                Some(reported),
            ),
        ] {
            conn.spins.clear();
            let cid = conn.rem_cids.active();
            conn.send_spin(remote, sending_local, cid);
            conn.receive_spin(remote, received_local, 1001, true);
            assert!(
                conn.send_spin(remote, sending_local, cid),
                "{role}, wildcard {wildcard}"
            );
            assert_eq!(conn.spins.len(), 1, "{role}");
        }
    }
}

#[test]
fn spin_local_rebind_without_a_cid_and_late_old_socket_packets() {
    use crate::proto::cid_generator::RandomConnectionIdGenerator;
    for seed in 0u8..=255 {
        let mut endpoint = EndpointConfig::try_with_rand_key()
            .unwrap()
            .with_rng_seed([seed; 32]);
        endpoint.set_cid_generator(Arc::new(|| {
            Box::new(RandomConnectionIdGenerator::new(0).unwrap())
        }));
        let mut pair = Pair::new(Arc::new(endpoint), server_config());
        let (client, _) = pair.connect();
        let now = pair.time;
        let conn = pair.client_conn_mut(client);
        if !conn.spin_enabled {
            continue;
        }
        assert!(conn.rem_cids.active().is_empty());
        let remote = conn.path.remote;
        conn.receive_spin(remote, None, 1000, false);
        assert!(wire_spin(conn, now));
        assert!(conn.migrate_local_address(now));
        assert!(
            !wire_spin(conn, now),
            "zero CID still resets without socket provenance"
        );
        let old: SocketAddr = "[::1]:4000".parse().unwrap();
        let new: SocketAddr = "[::1]:4001".parse().unwrap();
        conn.set_spin_local_address(Some("[::]:4000".parse().unwrap()));
        conn.receive_spin(remote, Some(old), 1001, false);
        assert!(wire_spin(conn, now));
        assert!(conn.migrate_local_address(now));
        conn.set_spin_local_address(Some("[::]:4001".parse().unwrap()));
        conn.receive_spin(remote, Some(old), 2000, false);
        assert!(
            !wire_spin(conn, now),
            "old local socket cannot set new path"
        );
        conn.receive_spin(remote, Some(new), 1500, false);
        assert!(
            wire_spin(conn, now),
            "new path has an independent watermark"
        );
        return;
    }
    panic!("no enabled zero-CID fixture");
}
