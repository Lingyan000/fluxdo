//! Filling a packet: the frames a space has waiting, in the order they go on the wire, and
//! the acknowledgements that ride along.

use std::mem;

use rama_core::telemetry::tracing::{trace, warn};

use crate::proto::{
    Instant,
    connection::{
        Connection, ConnectionSide, Event, spaces::PacketSpace, stats::ConnectionStats,
        transmit::SentFrames,
    },
    token::{Token, TokenPayload},
};
use rama_quic_proto::{
    VarInt,
    coding::BufMutExt as _,
    frame::{self, Datagram, FrameStruct, NewConnectionId, NewToken},
    packet::SpaceId,
    transport_parameters::TransportParameters,
};

impl Connection {
    pub(super) fn populate_packet(
        &mut self,
        now: Instant,
        space_id: SpaceId,
        buf: &mut Vec<u8>,
        max_size: usize,
        pn: u64,
        expands: bool,
    ) -> SentFrames {
        let mut sent = SentFrames::default();
        let challenge_interval = self.pto(SpaceId::Data);
        let space = &mut self.spaces[space_id];
        let is_0rtt = space_id == SpaceId::Data && space.crypto.is_none();
        space.pending_acks.maybe_ack_non_eliciting();

        let pre_payload_len = buf.len();

        // HANDSHAKE_DONE
        if !is_0rtt && mem::replace(&mut space.pending.handshake_done, false) {
            buf.write(frame::FrameType::HANDSHAKE_DONE);
            sent.retransmits.get_or_create().handshake_done = true;
            // This is just a u8 counter and the frame is typically just sent once
            self.stats.frame_tx.handshake_done =
                self.stats.frame_tx.handshake_done.saturating_add(1);
        }

        // PING
        if mem::replace(&mut space.ping_pending, false) {
            trace!("PING");
            buf.write(frame::FrameType::PING);
            sent.non_retransmits = true;
            self.stats.frame_tx.ping += 1;
        }

        // IMMEDIATE_ACK
        if mem::replace(&mut space.immediate_ack_pending, false) {
            trace!("IMMEDIATE_ACK");
            buf.write(frame::FrameType::IMMEDIATE_ACK);
            sent.non_retransmits = true;
            self.stats.frame_tx.immediate_ack += 1;
        }

        // ACK
        if space.pending_acks.can_send() {
            Self::try_populate_acks(
                now,
                self.receiving_ecn,
                &mut sent,
                space,
                buf,
                &mut self.stats,
                max_size,
            );
        }

        // ACK_FREQUENCY
        if mem::replace(&mut space.pending.ack_frequency, false) {
            let sequence_number = self.ack_frequency.next_sequence_number();

            // Safe to unwrap because this is always provided when ACK frequency is enabled
            #[expect(
                clippy::unwrap_used,
                reason = "`pending.ack_frequency` is only set when an `ack_frequency_config` is present (`AckFrequencyState::should_send_ack_frequency`)"
            )]
            let config = self.config.ack_frequency_config.as_ref().unwrap();

            // Ensure the delay is within bounds to avoid a PROTOCOL_VIOLATION error
            let max_ack_delay = self.ack_frequency.candidate_max_ack_delay(
                self.path.rtt.get(),
                config,
                &self.peer_params,
            );

            trace!(?max_ack_delay, "ACK_FREQUENCY");

            frame::AckFrequency {
                sequence: sequence_number,
                ack_eliciting_threshold: config.ack_eliciting_threshold,
                request_max_ack_delay: max_ack_delay.as_micros().try_into().unwrap_or(VarInt::MAX),
                reordering_threshold: config.reordering_threshold,
            }
            .encode(buf);

            sent.retransmits.get_or_create().ack_frequency = true;

            self.ack_frequency.ack_frequency_sent(pn, max_ack_delay);
            self.stats.frame_tx.ack_frequency += 1;
        }

        // PATH_CHALLENGE
        if buf.len() + 9 < max_size && space_id == SpaceId::Data {
            // Packet ACKs do not answer validation. Retry on a PTO-based timer,
            // rather than repeating the token in every packet of a data burst.
            if let Some(challenge) = self.path.challenge.as_mut()
                && challenge.pending()
                && challenge.may_go_in(expands)
            {
                let token = challenge.token();
                challenge.written(now, challenge_interval);
                sent.non_retransmits = true;
                sent.requires_padding = true;
                sent.challenge = Some(token);
                trace!("PATH_CHALLENGE {:08x}", token);
                buf.write(frame::FrameType::PATH_CHALLENGE);
                buf.write(token);
                self.stats.frame_tx.path_challenge += 1;
            }
        }

        // PATH_RESPONSE
        while buf.len() + 9 < max_size
            && space_id == SpaceId::Data
            && let Some(token) = self
                .path_responses
                .pop_on_path(self.path.remote, self.path.local)
        {
            sent.non_retransmits = true;
            sent.requires_padding = true;
            trace!("PATH_RESPONSE {:08x}", token);
            buf.write(frame::FrameType::PATH_RESPONSE);
            buf.write(token);
            self.stats.frame_tx.path_response += 1;
        }

        // CRYPTO
        while buf.len() + frame::Crypto::SIZE_BOUND < max_size && !is_0rtt {
            let Some(mut frame) = space.pending.crypto.pop_front() else {
                break;
            };

            // Calculate the maximum amount of crypto data we can store in the buffer.
            // Since the offset is known, we can reserve the exact size required to encode it.
            // For length we reserve 2bytes which allows to encode up to 2^14,
            // which is more than what fits into normally sized QUIC frames.
            let max_crypto_data_size = max_size
                - buf.len()
                - 1 // Frame Type
                - VarInt::size(VarInt::from_u64(frame.offset).unwrap_or(VarInt::MAX))
                - 2; // Maximum encoded length for frame size, given we send less than 2^14 bytes

            let len = frame
                .data
                .len()
                .min(2usize.pow(14) - 1)
                .min(max_crypto_data_size);

            let data = frame.data.split_to(len);
            let truncated = frame::Crypto {
                offset: frame.offset,
                data,
            };
            trace!(
                "CRYPTO: off {} len {}",
                truncated.offset,
                truncated.data.len()
            );
            truncated.encode(buf);
            self.stats.frame_tx.crypto += 1;
            sent.retransmits.get_or_create().crypto.push_back(truncated);
            if !frame.data.is_empty() {
                frame.offset += len as u64;
                space.pending.crypto.push_front(frame);
            }
        }

        if space_id == SpaceId::Data {
            self.streams.write_control_frames(
                buf,
                &mut space.pending,
                &mut sent.retransmits,
                &mut self.stats.frame_tx,
                max_size,
            );
        }

        // NEW_CONNECTION_ID
        while buf.len() + NewConnectionId::SIZE_BOUND < max_size {
            let Some(issued) = space.pending.new_cids.pop() else {
                break;
            };
            trace!(
                sequence = issued.sequence,
                id = %issued.id,
                "NEW_CONNECTION_ID"
            );
            frame::NewConnectionId {
                sequence: issued.sequence,
                retire_prior_to: self.local_cid_state.retire_prior_to(),
                id: issued.id,
                reset_token: issued.reset_token,
            }
            .encode(buf);
            self.local_cid_state.on_cid_sent(issued.sequence);
            sent.retransmits.get_or_create().new_cids.push(issued);
            self.stats.frame_tx.new_connection_id += 1;
        }

        // RETIRE_CONNECTION_ID
        while buf.len() + frame::RETIRE_CONNECTION_ID_SIZE_BOUND < max_size {
            let Some(seq) = space.pending.retire_cids.pop() else {
                break;
            };
            trace!(sequence = seq, "RETIRE_CONNECTION_ID");
            buf.write(frame::FrameType::RETIRE_CONNECTION_ID);
            buf.write_var(seq);
            sent.retransmits.get_or_create().retire_cids.push(seq);
            self.stats.frame_tx.retire_connection_id += 1;
        }

        // DATAGRAM
        let mut sent_datagrams = false;
        while buf.len() + Datagram::SIZE_BOUND < max_size && space_id == SpaceId::Data {
            match self.datagrams.write(buf, max_size) {
                true => {
                    sent_datagrams = true;
                    sent.non_retransmits = true;
                    self.stats.frame_tx.datagram += 1;
                }
                false => break,
            }
        }
        if self.datagrams.send_blocked && sent_datagrams {
            self.events.push_back(Event::DatagramsUnblocked);
            self.datagrams.send_blocked = false;
        }

        // NEW_TOKEN
        while let Some(remote_addr) = space.pending.new_tokens.pop() {
            debug_assert_eq!(space_id, SpaceId::Data);
            #[expect(
                clippy::panic,
                reason = "only server-side address validation queues `pending.new_tokens`"
            )]
            let ConnectionSide::Server { server_config } = &self.side else {
                panic!("NEW_TOKEN frames should not be enqueued by clients");
            };

            if remote_addr != self.path.remote {
                // NEW_TOKEN frames contain tokens bound to a client's IP address, and are only
                // useful if used from the same IP address.  Thus, we abandon enqueued NEW_TOKEN
                // frames upon an path change. Instead, when the new path becomes validated,
                // NEW_TOKEN frames may be enqueued for the new path instead.
                continue;
            }

            let token = Token::new(
                TokenPayload::Validation {
                    ip: remote_addr.ip(),
                    issued: server_config.time_source.now(),
                    version: self.wire_version.version(),
                },
                &mut self.rng,
            );
            // NEW_TOKEN is an optimisation for the client's next connection: a provider
            // that cannot seal it costs that client a future validation, nothing else.
            let token = match token.encode(&*server_config.token_key) {
                Ok(token) => token,
                Err(error) => {
                    warn!(%error, "validation token could not be sealed; NEW_TOKEN skipped");
                    self.stats.frame_tx.new_token_failed += 1;
                    continue;
                }
            };
            let new_token = NewToken {
                token: token.into(),
            };

            if buf.len() + new_token.size() >= max_size {
                space.pending.new_tokens.push(remote_addr);
                break;
            }

            new_token.encode(buf);
            sent.retransmits
                .get_or_create()
                .new_tokens
                .push(remote_addr);
            self.stats.frame_tx.new_token += 1;
        }

        // STREAM
        if space_id == SpaceId::Data {
            sent.stream_frames = self.streams.write_stream_frames(
                buf,
                max_size,
                self.config.send_fairness,
                self.datagrams.outgoing.drained_to(),
            );
            self.stats.frame_tx.stream += sent.stream_frames.len() as u64;
        }

        // Bundle ACK with other frames when there is room for them.
        // We want to reuse encryption and underlying protocol overhead,
        // but sending multiple ACKs for a single incoming packet is a waste of peer's resources,
        // so we have next_bundled_ack_time to control when to send ACKs.
        let any_frames_sent = buf.len() > pre_payload_len;
        if any_frames_sent
            && sent.largest_acked.is_none()
            && self.next_bundled_ack_time.is_some_and(|time| time <= now)
            && space.pending_acks.can_send_with_other_frames()
        {
            Self::try_populate_acks(
                now,
                self.receiving_ecn,
                &mut sent,
                space,
                buf,
                &mut self.stats,
                max_size,
            );
        }

        self.arm_path_challenge_timer();
        sent
    }

    /// Tries to write pending ACKs into a buffer if there is enough space.
    ///
    /// If the ACK frame does not fit into the buffer, the ACK frame will not
    /// be sent at all.
    ///
    /// This method assumes ACKs are pending, and should only be called if
    /// `!PendingAcks::ranges().is_empty()` returns `true`.
    pub(super) fn try_populate_acks(
        now: Instant,
        receiving_ecn: bool,
        sent: &mut SentFrames,
        space: &PacketSpace,
        buf: &mut Vec<u8>,
        stats: &mut ConnectionStats,
        max_size: usize,
    ) {
        debug_assert!(!space.pending_acks.ranges().is_empty());

        // 0-RTT packets must never carry acks (which would have to be of handshake packets)
        debug_assert!(space.crypto.is_some(), "tried to send ACK in 0-RTT");
        let ecn = if receiving_ecn {
            Some(&space.ecn_counters)
        } else {
            None
        };

        let delay_micros = space.pending_acks.ack_delay(now).as_micros() as u64;

        // TODO: This should come from `TransportConfig` if that gets configurable.
        let ack_delay_exp = TransportParameters::default().ack_delay_exponent;
        let delay = delay_micros >> ack_delay_exp.into_inner();

        trace!(
            "ACK {:?}, Delay = {}us",
            space.pending_acks.ranges(),
            delay_micros
        );

        let no_acks_len = buf.len();
        frame::Ack::encode(delay as _, space.pending_acks.ranges(), ecn, buf);
        if buf.len() > max_size {
            // The ACK frame is too large. Remove it.
            buf.truncate(no_acks_len);
            return;
        }
        sent.largest_acked = space.pending_acks.ranges().max();
        stats.frame_tx.acks += 1;
    }
}
