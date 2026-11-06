use rama_core::{
    bytes::Bytes,
    telemetry::tracing::{debug, trace, trace_span},
};

mod chaos;

use rand::RngExt;
use std::net::SocketAddr;

use super::{Connection, spaces::SentPacket};

use crate::proto::{Instant, connection::ConnectionSide};
use rama_quic_proto::{
    ConnectionId, TransportError,
    frame::{self, Close, FrameStruct},
    packet::{
        FIXED_BIT, Header, InitialHeader, LongType, MAX_PACKET_NUMBER_DISTANCE, PacketNumber,
        PartialEncode, SpaceId,
    },
    profile::InitialFlightLayout,
};

/// Packet numbers kept back for closing once acknowledgements stop keeping up; closing answers
/// what the peer sends ever less often, so this lasts far longer than the close does.
const PACKET_NUMBER_CLOSE_MARGIN: u64 = 1 << 16;

fn packet_numbers_outran_acknowledgements() -> TransportError {
    TransportError::INTERNAL_ERROR("packet numbers outran acknowledgements")
}

pub(super) struct PacketBuilder {
    pub(super) datagram_start: usize,
    pub(super) space: SpaceId,
    pub(super) partial_encode: PartialEncode,
    pub(super) ack_eliciting: bool,
    pub(super) exact_number: u64,
    pub(super) short_header: bool,
    /// Smallest absolute position in the associated buffer that must be occupied by this packet's
    /// frames
    pub(super) min_size: usize,
    /// Largest absolute position in the associated buffer that may be occupied by this packet's
    /// frames
    pub(super) max_size: usize,
    pub(super) tag_len: usize,
    pub(super) _span: rama_core::telemetry::tracing::span::EnteredSpan,
}

use crate::proto::connection::transmit::SentFrames;

impl PacketBuilder {
    /// Write a new packet header to `buffer` and determine the packet's properties
    ///
    /// Marks the connection drained and returns `None` if the confidentiality limit would be
    /// violated, or an Initial token leaves too little space for frames.
    #[expect(
        clippy::unwrap_used,
        clippy::unreachable,
        reason = "the caller selected `space_id` through `space_can_send`, which requires 1-RTT keys or, for the Data space only, the 0-RTT keys"
    )]
    pub(super) fn new(
        now: Instant,
        space_id: SpaceId,
        dst_cid: ConnectionId,
        path: (SocketAddr, Option<SocketAddr>),
        buffer: &mut Vec<u8>,
        buffer_capacity: usize,
        datagram_start: usize,
        ack_eliciting: bool,
        conn: &mut Connection,
    ) -> Option<Self> {
        let version = conn.wire_version;
        // A key phase is retired well before its keys reach their confidentiality limit, so the
        // usual answer to exhaustion is an update. An update that cannot happen — before the
        // handshake is confirmed, or while one is already in flight (RFC 9001 §6, §6.1) — leaves
        // the keys in use, and RFC 9001 §6.6 says those keys must stop being used at the limit.
        // So the limit is checked for every space, including this one.
        let mut sent_with_keys = conn.spaces[space_id].sent_with_keys;
        if space_id == SpaceId::Data && sent_with_keys >= conn.key_phase_size {
            debug!("routine key update due to phase exhaustion");
            if conn.force_key_update(now) {
                // The count belongs to the keys, and these are new ones.
                sent_with_keys = 0;
            }
        }
        let confidentiality_limit = conn.spaces[space_id]
            .crypto
            .as_ref()
            .map_or_else(
                || &conn.zero_rtt_crypto.as_ref().unwrap().packet,
                |keys| &keys.local.packet,
            )
            .confidentiality_limit();
        if sent_with_keys.saturating_add(1) == confidentiality_limit {
            // The budget covers one more packet: this one, which `poll_transmit` turns into the
            // close once the connection is closed here. The application is told the cause too.
            let error = TransportError::AEAD_LIMIT_REACHED("confidentiality limit reached");
            conn.close_inner(now, Close::Connection(error.clone().into()));
            if conn.error.is_none() {
                conn.error = Some(error.into());
            }
        } else if sent_with_keys >= confidentiality_limit {
            // No budget remains, so nothing more is encrypted with these keys.
            conn.kill(
                now,
                TransportError::AEAD_LIMIT_REACHED("confidentiality limit reached").into(),
            );
            return None;
        }

        // Packet numbers may not outrun acknowledgements by more than their encoding covers, so
        // a peer that stops acknowledging gets a close while the close still has numbers to use.
        let space = &conn.spaces[space_id];
        if space
            .next_packet_number
            .saturating_sub(space.largest_acked_packet.unwrap_or(0))
            >= MAX_PACKET_NUMBER_DISTANCE - PACKET_NUMBER_CLOSE_MARGIN
            && !conn.state.is_closed()
        {
            let error = packet_numbers_outran_acknowledgements();
            conn.close_inner(now, Close::Connection(error.clone().into()));
            if conn.error.is_none() {
                conn.error = Some(error.into());
            }
        }

        let recorded = conn.recorded_initial(space_id, conn.spaces[space_id].next_packet_number);
        let recorded_width = recorded.map(|packet| packet.number_len());
        let buffer_capacity = recorded.map_or(buffer_capacity, |packet| {
            buffer_capacity.min(datagram_start + usize::from(packet.packet_size()))
        });
        let grease_quic_bit = conn.may_grease_quic_bit();
        let spin = space_id == SpaceId::Data
            && conn.spaces[space_id].crypto.is_some()
            && conn.send_spin(path.0, path.1, dst_cid);
        let space = &mut conn.spaces[space_id];
        let exact_number = match space_id {
            SpaceId::Data => conn.packet_number_filter.allocate(&mut conn.rng, space),
            _ => space.get_tx_number(),
        };

        let span = trace_span!("send", space = ?space_id, pn = exact_number).entered();

        let Some(number) = PacketNumber::new_at_least(
            exact_number,
            space.largest_acked_packet.unwrap_or(0),
            recorded_width
                .unwrap_or_else(|| conn.config.wire.packetization.min_packet_number_len()),
        ) else {
            // Even the margin above is used up: nothing more can be numbered on this connection.
            conn.kill(now, packet_numbers_outran_acknowledgements().into());
            return None;
        };
        if recorded_width.is_some_and(|width| usize::from(width) != number.len()) {
            conn.kill(
                now,
                TransportError::INTERNAL_ERROR("recorded Initial number width changed").into(),
            );
            return None;
        }
        let header = match space_id {
            SpaceId::Data if space.crypto.is_some() => Header::Short {
                dst_cid,
                number,
                spin,
                key_phase: conn.key_phase,
            },
            // 0-RTT never moves to a negotiated version (RFC 9369 §4.1).
            SpaceId::Data => Header::Long {
                ty: LongType::ZeroRtt,
                src_cid: conn.handshake_cid,
                dst_cid,
                number,
                version: conn.original_wire_version,
            },
            SpaceId::Handshake => Header::Long {
                ty: LongType::Handshake,
                src_cid: conn.handshake_cid,
                dst_cid,
                number,
                version,
            },
            SpaceId::Initial => Header::Initial(InitialHeader {
                src_cid: conn.handshake_cid,
                dst_cid,
                token: match &conn.side {
                    ConnectionSide::Client { token, .. } => token.clone(),
                    ConnectionSide::Server { .. } => Bytes::new(),
                },
                number,
                version,
            }),
        };
        if let Header::Initial(initial) = &header
            && initial
                .encoded_len()
                .is_none_or(|len| len > buffer_capacity.saturating_sub(buffer.len()))
        {
            if Self::drop_optional_token(conn) {
                // Neither a packet number nor an encryption was consumed by the discarded header.
                conn.spaces[space_id].next_packet_number = exact_number;
                conn.spaces[space_id].sent_with_keys = sent_with_keys;
                return Self::new(
                    now,
                    space_id,
                    dst_cid,
                    path,
                    buffer,
                    buffer_capacity,
                    datagram_start,
                    ack_eliciting,
                    conn,
                );
            }
            Self::reject_initial_token(now, conn);
            return None;
        }
        let max_packet_len = buffer_capacity.saturating_sub(buffer.len());
        let partial_encode = header.encode_with_max_packet_len(buffer, max_packet_len);
        if grease_quic_bit && conn.rng.random() {
            buffer[partial_encode.start] ^= FIXED_BIT;
        }

        let (sample_size, tag_len) = if let Some(ref crypto) = space.crypto {
            (
                crypto.local.header.sample_size(),
                crypto.local.packet.tag_len(),
            )
        } else if space_id == SpaceId::Data {
            let zero_rtt = conn.zero_rtt_crypto.as_ref().unwrap();
            (zero_rtt.header.sample_size(), zero_rtt.packet.tag_len())
        } else {
            unreachable!();
        };

        // Each packet must be large enough for header protection sampling, i.e. the combined
        // lengths of the encoded packet number and protected payload must be at least 4 bytes
        // longer than the sample required for header protection. Further, each packet should be at
        // least tag_len + 6 bytes larger than the destination CID on incoming packets so that the
        // peer may send stateless resets that are indistinguishable from regular traffic.

        // pn_len + payload_len + tag_len >= sample_size + 4
        // payload_len >= sample_size + 4 - pn_len - tag_len
        let min_size = Ord::max(
            buffer.len() + (sample_size + 4).saturating_sub(number.len() + tag_len),
            partial_encode.start + dst_cid.len() + 6,
        );
        let max_size = buffer_capacity.saturating_sub(tag_len);
        // Initials need space for a close or a CRYPTO frame that makes progress.
        let required_frame_space = Self::initial_frame_space();
        if space_id == SpaceId::Initial
            && (max_size < min_size || max_size.saturating_sub(buffer.len()) < required_frame_space)
        {
            buffer.truncate(partial_encode.start);
            if Self::drop_optional_token(conn) {
                // Neither a packet number nor an encryption was consumed by the discarded header.
                conn.spaces[space_id].next_packet_number = exact_number;
                conn.spaces[space_id].sent_with_keys = sent_with_keys;
                return Self::new(
                    now,
                    space_id,
                    dst_cid,
                    path,
                    buffer,
                    buffer_capacity,
                    datagram_start,
                    ack_eliciting,
                    conn,
                );
            }
            Self::reject_initial_token(now, conn);
            return None;
        }
        debug_assert!(max_size >= min_size);

        Some(Self {
            datagram_start,
            space: space_id,
            partial_encode,
            exact_number,
            short_header: header.is_short(),
            min_size,
            max_size,
            tag_len,
            ack_eliciting,
            _span: span,
        })
    }

    pub(super) fn initial_probe_size(conn: &Connection) -> Option<usize> {
        let space = &conn.spaces[SpaceId::Initial];
        let keys = space.crypto.as_ref()?;
        let number = PacketNumber::new_at_least(
            space.next_packet_number,
            space.largest_acked_packet.unwrap_or(0),
            conn.config.wire.packetization.min_packet_number_len(),
        )?;
        let header = InitialHeader {
            src_cid: conn.handshake_cid,
            dst_cid: conn.rem_cids.active(),
            token: match &conn.side {
                ConnectionSide::Client { token, .. } => token.clone(),
                ConnectionSide::Server { .. } => Bytes::new(),
            },
            number,
            version: conn.wire_version,
        };
        let tag = keys.local.packet.tag_len();
        let frames = Self::initial_frame_space()
            .max((keys.local.header.sample_size() + 4).saturating_sub(number.len() + tag));
        header.encoded_len()?.checked_add(frames)?.checked_add(tag)
    }

    fn initial_frame_space() -> usize {
        (frame::Crypto::SIZE_BOUND + 1).max(frame::ConnectionClose::SIZE_BOUND)
    }

    /// Give up a client token that leaves the Initial no room when the token is optional: one a
    /// server issued for a later connection (RFC 9000 §8.1.3), not one a Retry asked for. Whether
    /// one was dropped, so the packet can be built again without it.
    fn drop_optional_token(conn: &mut Connection) -> bool {
        let retried = conn.retry_src_cid.is_some();
        match &mut conn.side {
            ConnectionSide::Client { token, .. } if !retried && !token.is_empty() => {
                *token = Bytes::new();
                true
            }
            _ => false,
        }
    }

    fn reject_initial_token(now: Instant, conn: &mut Connection) {
        if let ConnectionSide::Client { token, .. } = &mut conn.side {
            *token = Bytes::new();
        }
        conn.kill(
            now,
            TransportError::PROTOCOL_VIOLATION("Initial token leaves insufficient packet space")
                .into(),
        );
    }

    /// Append the minimum amount of padding to the packet such that, after encryption, the
    /// enclosing datagram will occupy at least `min_size` bytes
    pub(super) fn pad_to(&mut self, min_size: u16) {
        // The datagram might already have a larger minimum size than the caller is requesting, if
        // e.g. we're coalescing packets and have populated more than `min_size` bytes with packets
        // already.
        // An anti-amplification limit can leave a datagram less room than the padding a frame
        // asks for, and the limit wins (RFC 9000 §8.2.1).
        self.min_size = Ord::max(
            self.min_size,
            self.datagram_start + (min_size as usize) - self.tag_len,
        )
        .min(self.max_size);
    }

    pub(super) fn finish_and_track(
        self,
        now: Instant,
        conn: &mut Connection,
        sent: Option<SentFrames>,
        buffer: &mut Vec<u8>,
    ) -> Option<()> {
        let ack_eliciting = self.ack_eliciting;
        let exact_number = self.exact_number;
        let space_id = self.space;
        let is_0rtt = space_id == SpaceId::Data && conn.spaces[SpaceId::Data].crypto.is_none();
        let is_mtu_probe_packet =
            space_id == SpaceId::Data && conn.path.mtud.in_flight_mtu_probe() == Some(exact_number);
        let datagram_start = self.datagram_start;
        let (size, padded) = self.finish(conn, now, buffer)?;
        let Some(sent) = sent else { return Some(()) };

        // What a challenge in this datagram can prove is decided by how large the datagram
        // turned out, after every padding decision (RFC 9000 §8.2.1). Only the first datagram
        // to carry a token counts: the same token can go out again at another size, and a
        // response names neither.
        if let Some(token) = sent.challenge {
            conn.record_challenge_size(token, buffer.len() - datagram_start);
        }

        let size = match padded || ack_eliciting {
            true => size as u16,
            false => 0,
        };

        let packet = SentPacket {
            path_generation: conn.path.generation(),
            largest_acked: sent.largest_acked,
            time_sent: now,
            size,
            ack_eliciting,
            is_0rtt,
            is_mtu_probe_packet,
            retransmits: sent.retransmits,
            stream_frames: sent.stream_frames,
        };

        if ack_eliciting {
            conn.in_flight_ack_eliciting = conn.in_flight_ack_eliciting.saturating_add(1);
        }
        conn.path
            .sent(exact_number, packet, &mut conn.spaces[space_id]);
        conn.stats.path.sent_packets += 1;
        conn.reset_keep_alive(now);
        if size != 0 {
            if ack_eliciting {
                conn.spaces[space_id].time_of_last_ack_eliciting_packet = Some(now);
                if conn.permit_idle_reset {
                    conn.reset_idle_timeout(now, space_id);
                }
                conn.permit_idle_reset = false;
            }
            conn.set_loss_detection_timer(now);
            conn.path.pacing.on_transmit(size);
        }
        Some(())
    }

    /// Encrypt packet, returning the length of the packet and whether padding was added
    #[expect(
        clippy::unwrap_used,
        clippy::unreachable,
        reason = "the caller selected `space_id` through `space_can_send`, which requires 1-RTT keys or, for the Data space only, the 0-RTT keys"
    )]
    pub(super) fn finish(
        self,
        conn: &mut Connection,
        now: Instant,
        buffer: &mut Vec<u8>,
    ) -> Option<(usize, bool)> {
        let recorded = conn
            .recorded_initial(self.space, self.exact_number)
            .map(|packet| (packet.packet_size(), packet.trailing_bytes()));
        if let Some((packet_size, _)) = recorded
            && (buffer.len().saturating_sub(self.datagram_start) + self.tag_len
                != usize::from(packet_size)
                || buffer.len() < self.min_size)
        {
            conn.kill(
                now,
                TransportError::INTERNAL_ERROR("recorded Initial geometry changed").into(),
            );
            buffer.clear();
            return None;
        }
        let pad = buffer.len() < self.min_size;
        if pad {
            trace!("PADDING * {}", self.min_size - buffer.len());
            buffer.resize(self.min_size, 0);
        }
        // A client's Initial frames may be rearranged the way the profile asks, before they
        // are protected (the same bytes, differently laid out).
        if self.space == SpaceId::Initial
            && conn.side.is_client()
            && matches!(
                conn.config.wire.packetization.layout(),
                InitialFlightLayout::Chaos
            )
        {
            let payload_start = self.partial_encode.start + self.partial_encode.header_len;
            chaos::scramble(&mut buffer[payload_start..], &mut conn.rng);
        }

        let space = &conn.spaces[self.space];
        let (header_crypto, packet_crypto) = if let Some(ref crypto) = space.crypto {
            (&*crypto.local.header, &*crypto.local.packet)
        } else if self.space == SpaceId::Data {
            let zero_rtt = conn.zero_rtt_crypto.as_ref().unwrap();
            (&*zero_rtt.header, &*zero_rtt.packet)
        } else {
            unreachable!("tried to send {:?} packet without keys", self.space);
        };

        debug_assert_eq!(
            packet_crypto.tag_len(),
            self.tag_len,
            "Mismatching crypto tag len"
        );

        buffer.resize(buffer.len() + packet_crypto.tag_len(), 0);
        let encode_start = self.partial_encode.start;
        let packet_buf = &mut buffer[encode_start..];
        if let Err(error) = self.partial_encode.finish(
            packet_buf,
            header_crypto,
            Some((self.exact_number, packet_crypto)),
        ) {
            buffer.clear();
            conn.kill(
                now,
                rama_quic_proto::TransportError::INTERNAL_ERROR("packet encryption failed")
                    .with_cause(error)
                    .into(),
            );
            return None;
        }

        let len = buffer.len() - encode_start;
        if self.space == SpaceId::Handshake {
            conn.qlog_handshake_started(now);
        }
        conn.qlog_sink.emit_packet_sent(
            self.exact_number,
            len,
            self.space,
            self.space == SpaceId::Data && conn.spaces[SpaceId::Data].crypto.is_none(),
            self.space == SpaceId::Data
                && conn.path.mtud.in_flight_mtu_probe() == Some(self.exact_number),
            now,
            conn.trace_cid,
        );

        // Only the protected packet is authenticated and logged above. The
        // ignored tail belongs to this one-packet datagram and still consumes
        // congestion credit, pacing and recovery bytes until its packet is ACKed.
        let tail = recorded.map_or(0, |(_, tail)| usize::from(tail));
        if tail != 0 {
            buffer.resize(buffer.len() + tail, 0);
        }
        Some((len + tail, pad || tail != 0))
    }
}

#[cfg(all(
    test,
    any(
        feature = "boring",
        all(feature = "rustls", any(feature = "aws-lc", feature = "ring"))
    )
))]
mod tests;

#[cfg(all(
    test,
    any(
        feature = "boring",
        all(feature = "rustls", any(feature = "ring", feature = "aws-lc"))
    )
))]
mod token_budget_tests {
    use super::PacketBuilder;
    use crate::proto::{Endpoint, EndpointConfig, Instant, connection::ConnectionSide};
    use rama_core::bytes::Bytes;
    use rama_quic_proto::{ConnectionId, Version, packet::SpaceId, version::ClientVersionPolicy};
    use rama_utils::octets::mib;
    use std::sync::Arc;

    struct SuppliedToken(Bytes);

    impl crate::proto::TokenStore for SuppliedToken {
        fn insert(&self, _: &str, _: Version, _: crate::proto::StoredToken) {}

        fn take(&self, _: &str, _: Version) -> Option<crate::proto::StoredToken> {
            Some(crate::proto::StoredToken::new(
                self.0.clone(),
                crate::proto::UNIX_EPOCH,
            ))
        }
    }

    #[test]
    fn custom_token_store_output_obeys_connection_retention_limits() {
        let backing = Bytes::from(vec![7; mib(1)]);
        for length in [64, 65528] {
            let token = backing.slice(100..100 + length);
            let pointer = token.as_ptr();
            let mut config = crate::test_helpers::client(&crate::test_helpers::identity());
            config.set_token_store(Arc::new(SuppliedToken(token)));
            let mut endpoint = Endpoint::new(
                Arc::new(EndpointConfig::try_with_rand_key().unwrap()),
                None,
                true,
                None,
            );
            let (_, conn) = endpoint
                .connect(
                    Instant::now(),
                    config,
                    "[::1]:4433".parse().unwrap(),
                    "localhost",
                )
                .unwrap();
            let ConnectionSide::Client { token, .. } = &conn.side else {
                panic!("client")
            };
            if length == 64 {
                assert_eq!(token.as_ref(), &[7; 64]);
                assert_ne!(token.as_ptr(), pointer);
            } else {
                assert!(token.is_empty());
            }
        }
    }

    #[test]
    fn initial_token_remains_sendable_in_loss_probes() {
        for min_mtu in [1200, 1500] {
            let mut config = crate::test_helpers::client(&crate::test_helpers::identity());
            let transport = Arc::get_mut(&mut config.transport).unwrap();
            transport.set_initial_mtu(1500).set_min_mtu(min_mtu);
            config.token_store.insert(
                "localhost",
                Version::V1,
                crate::proto::StoredToken::new(vec![0; 1200].into(), crate::proto::UNIX_EPOCH),
            );
            let mut endpoint = Endpoint::new(
                Arc::new(EndpointConfig::try_with_rand_key().unwrap()),
                None,
                true,
                None,
            );
            let now = Instant::now();
            let (_, mut conn) = endpoint
                .connect(now, config, "[::1]:4433".parse().unwrap(), "localhost")
                .unwrap();
            let mut buffer = Vec::new();
            assert!(conn.poll_transmit(now, 1, &mut buffer).is_some());
            assert_eq!(conn.path.current_mtu(), 1500);
            conn.spaces[SpaceId::Initial].loss_probes = 1;
            conn.loss_probe_budget = 1;
            buffer.clear();
            assert!(conn.poll_transmit(now, 1, &mut buffer).is_some());
            assert!(!conn.is_drained());
            assert!(buffer.len() <= 1500);
            assert_eq!(conn.path.current_mtu(), 1500);
        }
    }

    #[test]
    fn rejected_initial_tokens_preserve_prior_packets_and_release_bytes() {
        for version in [Version::V1, Version::V2] {
            for token_len in [1120, 1200, 65536] {
                for retried in [true, false] {
                    let mut config = crate::test_helpers::client(&crate::test_helpers::identity());
                    config
                        .set_versions(ClientVersionPolicy::new(version).unwrap())
                        .unwrap();
                    let mut endpoint = Endpoint::new(
                        Arc::new(EndpointConfig::try_with_rand_key().unwrap()),
                        None,
                        true,
                        None,
                    );
                    let now = Instant::now();
                    let (_, mut conn) = endpoint
                        .connect(now, config, "[::1]:4433".parse().unwrap(), "localhost")
                        .unwrap();
                    // A Retry token is required to go on; one from an earlier connection is not.
                    if retried {
                        conn.retry_src_cid = Some(ConnectionId::new(&[9; 8]));
                    }
                    let ConnectionSide::Client { token, .. } = &mut conn.side else {
                        panic!("client")
                    };
                    *token = Bytes::from(vec![0; token_len]);
                    let mut buffer = Vec::with_capacity(1300);
                    buffer.extend_from_slice(&[42; 100]);
                    let capacity = buffer.capacity();
                    let built = PacketBuilder::new(
                        now,
                        SpaceId::Initial,
                        ConnectionId::new(&[1; 20]),
                        (conn.path.remote, conn.path.local),
                        &mut buffer,
                        1300,
                        100,
                        true,
                        &mut conn,
                    );
                    assert_eq!(built.is_some(), !retried, "retried: {retried}");
                    assert_eq!(&buffer[..100], &[42; 100]);
                    assert_eq!(buffer.capacity(), capacity);
                    let ConnectionSide::Client { token, .. } = &conn.side else {
                        panic!("client")
                    };
                    assert!(token.is_empty());
                    assert_eq!(conn.is_drained(), retried);
                    if !retried {
                        assert!(buffer.len() > 100, "the header follows the earlier packets");
                        assert_eq!(
                            conn.spaces[SpaceId::Initial].next_packet_number,
                            1,
                            "the rebuilt packet keeps the first number"
                        );
                        assert_eq!(
                            conn.spaces[SpaceId::Initial].sent_with_keys,
                            1,
                            "only the rebuilt packet consumes the key budget"
                        );
                    }
                }
            }
        }
    }
}
