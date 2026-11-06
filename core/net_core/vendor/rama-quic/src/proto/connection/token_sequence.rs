//! Exercise token state through authenticated peer packets and subsequent client Initials.

#![expect(
    clippy::unwrap_used,
    reason = "invalid fixed harness setup must fail the fuzz run"
)]

use rama_core::bytes::Bytes;
use rama_quic_proto::{
    ConnectionId, Side, VarInt, Version,
    frame::NewToken,
    packet::{
        FixedLengthConnectionIdParser, Header, InitialHeader, PacketNumber, PartialDecode, SpaceId,
    },
};

use super::fuzz_pair::{Pair, configs};
use crate::proto::{DEFAULT_SUPPORTED_VERSIONS, Duration};

impl Pair {
    fn retry(&mut self, flags: u8, token: &[u8]) {
        let mut packet = Vec::new();
        Header::Retry {
            src_cid: if flags & 8 != 0 {
                self.destination
            } else {
                ConnectionId::new(&[0xa5; 20])
            },
            dst_cid: self.source,
            version: self.version.to_wire().unwrap(),
        }
        .encode(&mut packet);
        packet.extend_from_slice(token);
        let mut tag = self
            .server_config
            .crypto
            .initial()
            .retry_tag(self.version, &self.destination, &packet)
            .unwrap();
        if flags & 16 != 0 {
            tag[0] ^= 1;
        }
        packet.extend_from_slice(&tag);
        self.client.receive(self.now, self.server.address, &packet);
    }

    fn initial(&mut self, payload: &[u8]) {
        let connection = &self.client.connection.as_ref().unwrap().1;
        let keys = connection
            .crypto
            .initial_keys(self.version, &connection.initial_dst_cid, Side::Server)
            .unwrap();
        let mut packet = Vec::new();
        let number = connection.spaces[SpaceId::Initial].rx_packet + 1;
        let header = Header::Initial(InitialHeader {
            dst_cid: self.source,
            src_cid: ConnectionId::new(&[0xa5; 20]),
            token: Bytes::new(),
            number: PacketNumber::U32(number as u32),
            version: self.version.to_wire().unwrap(),
        })
        .encode(&mut packet);
        packet.extend_from_slice(&payload[..payload.len().min(8192)]);
        packet.resize((packet.len() + keys.local.packet.tag_len()).max(1200), 0);
        header
            .finish(
                &mut packet,
                &*keys.local.header,
                Some((number, &*keys.local.packet)),
            )
            .unwrap();
        self.client.receive(self.now, self.server.address, &packet);
    }

    fn new_token(&mut self, token: &[u8], flags: u8) {
        let connection = &self.client.connection.as_ref().unwrap().1;
        let Some(keys) = connection.spaces[SpaceId::Data].crypto.as_ref() else {
            return;
        };
        let Some(remote) = &keys.remote else {
            return;
        };
        let Some((_, server)) = &self.server.connection else {
            return;
        };
        let number = connection.spaces[SpaceId::Data].rx_packet + 1;
        let mut packet = Vec::new();
        let header = Header::Short {
            spin: false,
            key_phase: connection.key_phase,
            dst_cid: server.rem_cids.active(),
            number: PacketNumber::U32(number as u32),
        }
        .encode(&mut packet);
        NewToken {
            token: Bytes::copy_from_slice(token),
        }
        .encode(&mut packet);
        packet.resize(
            packet
                .len()
                .max(header.header_len + remote.header.sample_size())
                + remote.packet.tag_len(),
            0,
        );
        header
            .finish(
                &mut packet,
                &*remote.header,
                Some((number, &*remote.packet)),
            )
            .unwrap();
        if flags & 16 != 0 {
            *packet.last_mut().unwrap() ^= 1;
        }
        self.client.receive(self.now, self.server.address, &packet);
    }
}

/// Input: version byte, then at most 16 `(opcode, u16 length, fill byte)` operations.
/// Opcodes cover Retry, Initial, handshake, NEW_TOKEN, close, timeout, reconnect and raw input.
#[cfg_attr(
    not(fuzzing),
    expect(
        unreachable_pub,
        reason = "also compiled for the harness regression tests"
    )
)]
pub fn token_sequence(input: &[u8]) {
    let _coverage = run(input);
}

fn run(input: &[u8]) -> [u64; 4] {
    let mut coverage = [0; 4];
    let Some((&version, input)) = input.split_first() else {
        return coverage;
    };
    let version = if version & 1 == 0 {
        Version::V1
    } else {
        Version::V2
    };
    let (client_config, server_config) = configs(version, b"rama-token-fuzz");
    let mut pair = Pair::new(client_config.clone(), server_config.clone(), version);
    for operation in input.as_chunks::<4>().0.iter().take(16) {
        let flags = operation[0];
        let payload = vec![
            operation[3];
            usize::from(u16::from_le_bytes([operation[1], operation[2]])).min(65_000)
        ];
        let pings_before = pair
            .client
            .connection
            .as_ref()
            .unwrap()
            .1
            .stats()
            .frame_rx
            .ping;
        let tokens_before = pair
            .client
            .connection
            .as_ref()
            .unwrap()
            .1
            .stats()
            .frame_rx
            .new_token;
        let cid_before = pair.client.connection.as_ref().unwrap().1.rem_handshake_cid;
        match flags & 7 {
            0 => pair.retry(flags, &payload),
            1 => pair.initial(&payload),
            2 => pair.drive(),
            3 => pair.new_token(&payload, flags),
            4 => pair.client.connection.as_mut().unwrap().1.close(
                pair.now,
                VarInt::from_u32(0),
                payload.into(),
            ),
            5 => {
                pair.now += Duration::from_secs(1);
                pair.client
                    .connection
                    .as_mut()
                    .unwrap()
                    .1
                    .handle_timeout(pair.now);
            }
            6 => {
                pair = Pair::new(client_config.clone(), server_config.clone(), version);
                if let Some(packet) = pair.client.outgoing.front() {
                    let (packet, _) = PartialDecode::new(
                        packet.as_slice().into(),
                        &FixedLengthConnectionIdParser::new(0),
                        DEFAULT_SUPPORTED_VERSIONS,
                        true,
                    )
                    .unwrap();
                    coverage[2] +=
                        u64::from(!packet.initial_header().unwrap().token_pos.is_empty());
                }
            }
            _ => pair.client.receive(pair.now, pair.server.address, &payload),
        }
        let connection = &pair.client.connection.as_ref().unwrap().1;
        if flags & 7 == 0 && connection.rem_handshake_cid != cid_before {
            coverage[0] += 1;
        }
        if flags & 7 == 1 {
            coverage[3] += connection.stats().frame_rx.ping - pings_before;
        }
        if flags & 7 == 3 {
            coverage[1] += connection.stats().frame_rx.new_token - tokens_before;
        }
        pair.client.transmit(pair.now);
        pair.now += Duration::from_millis(1);
    }
    coverage
}

#[cfg(test)]
mod tests {
    use super::{run, token_sequence};

    #[test]
    fn mixed_sequences_remain_bounded() {
        let mut state = 42u64;
        for _ in 0..256 {
            let mut input = [0u8; 65];
            for byte in &mut input {
                state = state.wrapping_mul(6364136223846793005).wrapping_add(1);
                *byte = (state >> 32) as u8;
            }
            token_sequence(&input);
        }
    }

    #[test]
    fn authenticated_sequences_reach_token_storage_and_initial_construction() {
        for version in [0, 1] {
            assert_eq!(run(&[version, 1, 1, 0, 1])[3], 1);
            let retry = run(&[version, 0, 8, 0, 7]);
            assert_eq!(retry[0], 1);
            for token_len in [1u16, 64, 1119] {
                let [lo, hi] = token_len.to_le_bytes();
                let result = run(&[version, 2, 0, 0, 0, 3, lo, hi, 7, 6, 0, 0, 0]);
                assert_eq!(result[1], 1);
                assert_eq!(result[2], 1);
            }
            for flags in [8, 16] {
                assert_eq!(run(&[version, flags, 8, 0, 7])[0], 0);
            }
            assert_eq!(run(&[version, 2, 0, 0, 0, 19, 8, 0, 7])[1], 0);
        }
    }

    /// A server that greases the QUIC bit and issues a token lets the client's next first flight
    /// grease it as well; the harness reads that flight like any other.
    #[test]
    fn a_greased_first_flight_after_a_stored_token_is_read() {
        token_sequence(&[
            45, 2, 35, 0, 0, 3, 96, 4, 0, 2, 35, 0, 0, 3, 96, 4, 7, 6, 0, 2, 35,
        ]);
    }
}
