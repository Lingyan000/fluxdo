//! Building what goes on the wire: the datagrams one pass produces, the challenges that go
//! out on their own, and the sizes a 1-RTT packet has to fit.

use std::{cmp, num::NonZeroUsize};

use rama_core::{
    bytes::Bytes,
    telemetry::tracing::{debug, trace},
};

use crate::proto::{
    Duration, Instant, MIN_INITIAL_SIZE, TIMER_GRANULARITY, Transmit,
    connection::{
        Connection, State,
        migration::{PrevCid, PrevPath},
        packet_builder::PacketBuilder,
        spaces::{SendableFrames, ThinRetransmits},
        state,
        streams::StreamsState,
        timer::Timer,
    },
};
use rama_quic_proto::{
    EcnCodepoint, MAX_CID_SIZE, TransportErrorCode, VarInt,
    coding::BufMutExt as _,
    frame::{self, FrameStruct, StreamMetaVec},
    packet::{PacketNumber, SpaceId},
    profile::PaddingPlacement,
};

impl Connection {
    fn loss_probe_size(&self, space: SpaceId, segment_size: usize) -> usize {
        let minimum = if space == SpaceId::Initial {
            PacketBuilder::initial_probe_size(self).unwrap_or(segment_size)
        } else {
            0
        };
        // A loss probe must still carry its token and a useful frame.
        cmp::min(segment_size, minimum.max(usize::from(self.config.min_mtu)))
    }

    /// Returns packets to transmit
    ///
    /// Connections should be polled for transmit after:
    /// - the application performed some I/O on the connection
    /// - a call was made to `handle_event`
    /// - a call was made to `handle_timeout`
    ///
    /// `max_datagrams` specifies how many datagrams can be returned inside a
    /// single Transmit using GSO. This must be at least 1.
    #[must_use]
    pub(crate) fn poll_transmit(
        &mut self,
        now: Instant,
        max_datagrams: usize,
        buf: &mut Vec<u8>,
    ) -> Option<Transmit> {
        assert!(max_datagrams != 0);
        // A protocol error a timer could not report closes the connection here.
        self.settle_deferred_error(now);
        if self.state.is_closed() {
            self.discard_server_candidate();
        }
        let max_datagrams = match self.config.enable_segmentation_offload {
            false => 1,
            true => max_datagrams,
        };
        // A reordered recorded burst is built in one transmit; the socket splits
        // segments it cannot send together.
        let wire_order = self.recorded_initial_wire_order();
        let max_datagrams = wire_order
            .as_ref()
            .map_or(max_datagrams, |order| max_datagrams.max(order.len()));

        let mut num_datagrams = 0;
        // Position in `buf` of the first byte of the current UDP datagram. When coalescing QUIC
        // packets, this can be earlier than the start of the current QUIC packet.
        let mut datagram_start = 0;
        let mut segment_size = usize::from(self.path.current_mtu());

        if let Some(challenge) = self.send_path_challenge(now, buf) {
            return Some(challenge);
        }

        if let Some(probe) = self.send_preferred_probe(now, buf) {
            return Some(probe);
        }

        if let Some(probe) = self.send_server_candidate(now, buf) {
            return Some(probe);
        }

        if let Some(response) = self.send_off_path_response(now, buf) {
            return Some(response);
        }

        // If we need to send a probe, make sure we have something to send.
        for space in SpaceId::iter() {
            if self.loss_probe_budget == 0 {
                self.spaces[space].loss_probes = 0;
            }
            let request_immediate_ack =
                space == SpaceId::Data && self.peer_supports_ack_frequency();
            self.spaces[space].maybe_queue_probe(
                request_immediate_ack,
                space == SpaceId::Data,
                &mut self.streams,
            );
        }

        // Whether a close frame actually made it into a packet on this pass, which is what
        // counts as one response.
        // Whether the close is done with: the highest space has had one, or the permitted
        // response packet has gone out.
        let mut close_finished = false;

        // Check whether we need to send a close message
        let close = match self.state {
            State::Drained => {
                self.app_limited = true;
                return None;
            }
            State::Draining | State::Closed(_) => {
                // self.close is only reset once the associated packet had been
                // encoded successfully
                if !self.close {
                    self.app_limited = true;
                    return None;
                }
                true
            }
            _ => false,
        };

        // Check whether we need to send an ACK_FREQUENCY frame
        if let Some(config) = &self.config.ack_frequency_config {
            self.spaces[SpaceId::Data].pending.ack_frequency = self
                .ack_frequency
                .should_send_ack_frequency(self.path.rtt.get(), config, &self.peer_params)
                && self.highest_space == SpaceId::Data
                && self.peer_supports_ack_frequency();
        }

        // What may go towards an unvalidated address is bounded in bytes, so plan against a
        // segment that fits the allowance rather than a full one that would exceed it (RFC 9000
        // §8), which keeps a small PATH_CHALLENGE or PATH_RESPONSE reachable. A datagram carrying
        // an Initial is padded to `MIN_INITIAL_SIZE`, so the segment does not shrink past that
        // while this side still has Initial keys (RFC 9000 §14.1); below `MIN_PACKET_SPACE` no
        // packet can be built at all, and the floor leaves the admission check below to block.
        if let Some(remaining) = self.path.anti_amplification_remaining() {
            let remaining = usize::try_from(remaining).unwrap_or(usize::MAX);
            segment_size = segment_size.min(remaining.max(self.min_datagram_size()));
        }

        // Reserving capacity can provide more capacity than we asked for. However, we are not
        // allowed to write more than `segment_size`. Therefore the maximum capacity is tracked
        // separately.
        let mut buf_capacity = 0;

        let mut coalesce = true;
        let mut builder_storage: Option<PacketBuilder> = None;
        let mut sent_frames = None;
        let mut pad_datagram = false;
        let mut pad_datagram_to_mtu = false;
        let mut congestion_blocked = false;

        // Iterate over all spaces and find data to send
        let mut space_idx = 0;
        let spaces = [SpaceId::Initial, SpaceId::Handshake, SpaceId::Data];
        // This loop will potentially spend multiple iterations in the same `SpaceId`,
        // so we cannot trivially rewrite it to take advantage of `SpaceId::iter()`.
        while space_idx < spaces.len() {
            let space_id = spaces[space_idx];
            if space_id == SpaceId::Data
                && self.loss_probe_budget > 0
                && self.spaces[space_id].loss_probes > 0
            {
                // Every probe must elicit ACKs even when a queued FIN or DATAGRAM cannot fit.
                self.spaces[space_id].ping_pending = true;
            }
            // Number of bytes available for frames if this is a 1-RTT packet. We're guaranteed to
            // be able to send an individual frame at least this large in the next 1-RTT
            // packet. This could be generalized to support every space, but it's only needed to
            // handle large fixed-size frames, which only exist in 1-RTT (application datagrams). We
            // don't account for coalesced packets potentially occupying space because frames can
            // always spill into the next datagram.
            let pn = self.packet_number_filter.peek(&self.spaces[SpaceId::Data]);
            let frame_space_1rtt =
                segment_size.saturating_sub(self.predict_1rtt_overhead(Some(pn)));

            // Is there data or a close message to send in this space?
            let can_send = self.space_can_send(space_id, frame_space_1rtt);
            if can_send.is_empty() && (!close || self.spaces[space_id].crypto.is_none()) {
                space_idx += 1;
                continue;
            }
            // A close already carried in an earlier pass is not sent again.
            if close && space_id < self.close_from {
                space_idx += 1;
                continue;
            }

            let mut ack_eliciting = !self.spaces[space_id].pending.is_empty(&self.streams)
                || self.spaces[space_id].ping_pending
                || self.spaces[space_id].immediate_ack_pending;
            let mut ack_only = false;
            if space_id == SpaceId::Data {
                ack_eliciting |= self.can_send_1rtt(frame_space_1rtt);
            }

            pad_datagram_to_mtu |= space_id == SpaceId::Data && self.config.pad_to_mtu;

            // Can we append more data into the current buffer?
            // It is not safe to assume that `buf.len()` is the end of the data,
            // since the last packet might not have been finished.
            let buf_end = if let Some(builder) = &builder_storage {
                buf.len().max(builder.min_size) + builder.tag_len
            } else {
                buf.len()
            };

            #[expect(
                clippy::expect_used,
                clippy::unreachable,
                reason = "`space_can_send` selected this space because it has keys: Initial/Handshake keep `crypto` until discarded and the Data space has 1-RTT keys or, before the handshake completes, the 0-RTT keys"
            )]
            let tag_len = if let Some(ref crypto) = self.spaces[space_id].crypto {
                crypto.local.packet.tag_len()
            } else if space_id == SpaceId::Data {
                self.zero_rtt_crypto.as_ref().expect(
                    "sending packets in the application data space requires known 0-RTT or 1-RTT keys",
                ).packet.tag_len()
            } else {
                unreachable!("tried to send {:?} packet without keys", space_id)
            };
            if !coalesce || buf_capacity - buf_end < MIN_PACKET_SPACE + tag_len {
                // We need to send 1 more datagram and extend the buffer for that.

                // Reserve scarce pre-validation credit for handshake recovery.
                // Server 0.5-RTT controls can use spare room in the flight, but
                // must not displace a complete CRYPTO probe with a standalone
                // datagram. Real early responses and ACK feedback remain usable.
                if space_id == SpaceId::Data
                    && self.side.is_server()
                    && !self.handshake_confirmed()
                    && !self.path.validated
                    && !close
                    && !can_send.acks
                    && !self.streams.can_send_stream_data()
                    && !self.datagrams.outgoing.can_send_1rtt(frame_space_1rtt)
                {
                    space_idx += 1;
                    continue;
                }

                // Is 1 more datagram allowed?
                if num_datagrams >= max_datagrams {
                    // No more datagrams allowed
                    break;
                }

                // Every datagram in a batch before the last occupies a full segment, and a loss
                // probe is clamped to the minimum MTU so it can get through a shrunken path.
                let is_probe = self.loss_probe_budget > 0 && self.spaces[space_id].loss_probes > 0;
                let admitting = if is_probe {
                    self.loss_probe_size(space_id, segment_size)
                } else {
                    segment_size
                };

                // `total_sent` is updated at the end of this method, so what is already
                // built has to be counted here, and the whole of the datagram this admits.
                let planned = (segment_size as u64)
                    .saturating_mul(num_datagrams as u64)
                    .saturating_add(admitting as u64);
                if self.path.anti_amplification_blocked(planned) {
                    trace!("blocked by anti-amplification");
                    break;
                }

                // RFC 9000 §13.2.4: obtain ACK-of-ACK feedback before the bounded
                // history fills. This is opportunistic: ACK-only traffic must
                // still leave immediately when congestion control blocks PING.
                // Waiting a round trip and leaving a non-eliciting packet between
                // probes also prevents turning an ACK exchange into a PING loop.
                const ACK_HISTORY_PING_THRESHOLD: usize = 32;
                let space = &self.spaces[space_id];
                let feedback_due = space_id == SpaceId::Data
                    && !close
                    && !ack_eliciting
                    && self.state.is_established()
                    && buf.is_empty()
                    && builder_storage.is_none()
                    && self.in_flight_ack_eliciting == 0
                    // An upper bound: retired numbers leave the history from its front.
                    && space.non_ack_eliciting_sent.len() >= ACK_HISTORY_PING_THRESHOLD
                    && space
                        .sent_packets
                        .last_key_value()
                        .is_some_and(|(_, packet)| {
                            !packet.ack_eliciting
                                && space
                                    .time_of_last_ack_eliciting_packet
                                    .is_none_or(|sent| packet.time_sent > sent)
                        })
                    && space.time_of_last_ack_eliciting_packet.is_none_or(|sent| {
                        now.saturating_duration_since(sent) >= self.path.rtt.get()
                    });

                if feedback_due
                    && self
                        .path
                        .in_flight
                        .bytes
                        .saturating_add(segment_size as u64)
                        <= self.path.congestion.window()
                    && self
                        .path
                        .pacing
                        .delay(
                            self.path.rtt.get(),
                            segment_size as u64,
                            self.path.current_mtu(),
                            self.path.congestion.window(),
                            now,
                        )
                        .is_none()
                {
                    self.spaces[space_id].ping_pending = true;
                    ack_eliciting = true;
                }

                // Congestion control and pacing checks
                // Tail loss probes must not be blocked by congestion, or a deadlock could arise.
                // Close packets contain only ACKs and CONNECTION_CLOSE, neither of which is
                // congestion controlled, and must not be blocked either: `ack_eliciting` reflects
                // pending frames that will never be sent once closing, and a closed connection no
                // longer processes ACKs, so the window could never drain
                // A client's ACK-only Initial still requires 1200 bytes of
                // padding, which counts in flight. It cannot use the ACK-only
                // congestion exemption; a Handshake ACK or PTO can make progress.
                let initial_padding = space_id == SpaceId::Initial && self.side.is_client();
                if (ack_eliciting || initial_padding) && !is_probe && !close {
                    // Assume the current packet will get padded to fill the segment
                    let untracked_bytes = if let Some(builder) = &builder_storage {
                        buf_capacity - builder.partial_encode.start
                    } else {
                        0
                    } as u64;
                    debug_assert!(untracked_bytes <= segment_size as u64);

                    let bytes_to_send = segment_size as u64 + untracked_bytes;
                    if self.path.in_flight.bytes + bytes_to_send > self.path.congestion.window() {
                        congestion_blocked = true;
                        trace!("blocked by congestion control");
                        if can_send.acks && !initial_padding {
                            // Pending CRYPTO/STREAM must not suppress ACK feedback.
                            // Leave those frames queued and send only the ACK
                            // outside congestion control (RFC 9002 §7).
                            ack_only = true;
                            ack_eliciting = false;
                            pad_datagram_to_mtu = false;
                        } else {
                            space_idx += 1;
                            // Higher spaces may still have loss probes.
                            continue;
                        }
                    }

                    // Check whether the next datagram is blocked by pacing
                    let smoothed_rtt = self.path.rtt.get();
                    if !ack_only
                        && let Some(delay) = self.path.pacing.delay(
                            smoothed_rtt,
                            bytes_to_send,
                            self.path.current_mtu(),
                            self.path.congestion.window(),
                            now,
                        )
                    {
                        self.timers.set(Timer::Pacing, delay);
                        congestion_blocked = true;
                        // Loss probes should be subject to pacing, even though
                        // they are not congestion controlled.
                        trace!("blocked by pacing");
                        break;
                    }
                }

                // Finish current packet
                if let Some(mut builder) = builder_storage.take() {
                    let recorded = self.recorded_initial(builder.space, builder.exact_number);
                    if pad_datagram && recorded.is_none() {
                        builder.pad_to(self.config.min_mtu);
                    }

                    if num_datagrams > 1 || pad_datagram_to_mtu {
                        // If too many padding bytes would be required to continue the GSO batch
                        // after this packet, end the GSO batch here. Ensures that fixed-size frames
                        // with heterogeneous sizes (e.g. application datagrams) won't inadvertently
                        // waste large amounts of bandwidth. The exact threshold is a bit arbitrary
                        // and might benefit from further tuning, though there's no universally
                        // optimal value.
                        //
                        // Additionally, if this datagram is a loss probe and `segment_size` is
                        // larger than `INITIAL_MTU`, then padding it to `segment_size` to continue
                        // the GSO batch would risk failure to recover from a reduction in path
                        // MTU. Loss probes are the only packets for which we might grow
                        // `buf_capacity` by less than `segment_size`.
                        const MAX_PADDING: usize = 16;
                        let packet_len_unpadded = recorded.map_or_else(
                            || {
                                cmp::max(builder.min_size, buf.len()) - datagram_start
                                    + builder.tag_len
                            },
                            |packet| usize::from(packet.datagram_size()),
                        );
                        if (packet_len_unpadded + MAX_PADDING < segment_size
                            && !pad_datagram_to_mtu)
                            || datagram_start + segment_size > buf_capacity
                        {
                            trace!(
                                "GSO truncated by demand for {} padding bytes or loss probe",
                                segment_size - packet_len_unpadded
                            );
                            builder_storage = Some(builder);
                            break;
                        }

                        // Pad the current datagram to GSO segment size so it can be included in the
                        // GSO batch.
                        if recorded.is_none() {
                            builder.pad_to(segment_size as u16);
                        }
                    }

                    builder.finish_and_track(now, self, sent_frames.take(), buf)?;

                    if num_datagrams == 1 {
                        // Set the segment size for this GSO batch to the size of the first UDP
                        // datagram in the batch. Larger data that cannot be fragmented
                        // (e.g. application datagrams) will be included in a future batch. When
                        // sending large enough volumes of data for GSO to be useful, we expect
                        // packet sizes to usually be consistent, e.g. populated by max-size STREAM
                        // frames or uniformly sized datagrams.
                        segment_size = buf.len();
                        // Clip the unused capacity out of the buffer so future packets don't
                        // overrun
                        buf_capacity = buf.len();
                        // A short first packet cannot set a GSO size below the builder's minimum.
                        if segment_size < MIN_PACKET_SPACE {
                            break;
                        }

                        // Check whether the data we planned to send will fit in the reduced segment
                        // size. If not, bail out and leave it for the next GSO batch so we don't
                        // end up trying to send an empty packet. We can't easily compute the right
                        // segment size before the original call to `space_can_send`, because at
                        // that time we haven't determined whether we're going to coalesce with the
                        // first datagram or potentially pad it to `MIN_INITIAL_SIZE`.
                        if space_id == SpaceId::Data {
                            let frame_space_1rtt =
                                segment_size.saturating_sub(self.predict_1rtt_overhead(Some(pn)));
                            if self.space_can_send(space_id, frame_space_1rtt).is_empty() {
                                break;
                            }
                        }
                    }
                }

                // Allocate space for another datagram. `segment_size` may have been clipped to
                // the first datagram of the batch since this one was admitted, so it can only
                // have grown smaller than what the allowance was measured against.
                let next_datagram_size_limit = if is_probe {
                    self.loss_probe_budget -= 1;
                    self.spaces[space_id].loss_probes -= 1;
                    self.loss_probe_size(space_id, segment_size)
                } else {
                    segment_size
                };

                buf_capacity += next_datagram_size_limit;
                if buf.capacity() < buf_capacity {
                    // We reserve the maximum space for sending `max_datagrams` upfront
                    // to avoid any reallocations if more datagrams have to be appended later on.
                    // Benchmarks have shown shown a 5-10% throughput improvement
                    // compared to continuously resizing the datagram buffer.
                    // While this will lead to over-allocation for small transmits
                    // (e.g. purely containing ACKs), modern memory allocators
                    // (e.g. mimalloc and jemalloc) will pool certain allocation sizes
                    // and therefore this is still rather efficient.
                    buf.reserve(max_datagrams * segment_size);
                }
                num_datagrams += 1;
                coalesce = true;
                pad_datagram = false;
                datagram_start = buf.len();

                debug_assert_eq!(
                    datagram_start % segment_size,
                    0,
                    "datagrams in a GSO batch must be aligned to the segment size"
                );
            } else {
                // We can append/coalesce the next packet into the current
                // datagram.
                self.spaces[space_id].loss_probes =
                    self.spaces[space_id].loss_probes.saturating_sub(1);
                // Finish current packet without adding extra padding
                if let Some(builder) = builder_storage.take() {
                    builder.finish_and_track(now, self, sent_frames.take(), buf)?;
                }
            }

            debug_assert!(buf_capacity - buf.len() >= MIN_PACKET_SPACE);

            // From here on, we've determined that a packet will definitely be sent.

            if self.spaces[SpaceId::Initial].crypto.is_some()
                && space_id == SpaceId::Handshake
                && self.side.is_client()
            {
                // A client stops both sending and processing Initial packets when it
                // sends its first Handshake packet.
                self.discard_space(now, SpaceId::Initial);
            }
            if let Some(ref mut prev) = self.prev_crypto {
                prev.update_unacked = false;
            }

            debug_assert!(
                builder_storage.is_none() && sent_frames.is_none(),
                "Previous packet must have been finished"
            );

            let builder = builder_storage.insert(PacketBuilder::new(
                now,
                space_id,
                self.rem_cids.active(),
                (self.path.remote, self.path.local),
                buf,
                buf_capacity,
                datagram_start,
                ack_eliciting,
                self,
            )?);
            // The builder closes the connection when this is the last packet its keys may
            // protect (RFC 9001 §6.6). That packet then says why, instead of what was pending.
            let close = close || self.close;
            coalesce = coalesce
                && !ack_only
                && !builder.short_header
                && self.config.wire.packetization.coalesces()
                && self
                    .recorded_initial(space_id, builder.exact_number)
                    .is_none();

            // https://tools.ietf.org/html/draft-ietf-quic-transport-34#section-14.1
            pad_datagram |=
                space_id == SpaceId::Initial && (self.side.is_client() || ack_eliciting);

            if close {
                trace!("sending CONNECTION_CLOSE");
                // Encode ACKs before the ConnectionClose message, to give the receiver
                // a better approximate on what data has been processed. This is
                // especially important with ack delay, since the peer might not
                // have gotten any other ACK for the data earlier on.
                if !self.spaces[space_id].pending_acks.ranges().is_empty() {
                    // The ACK yields to the close: a large Initial token can leave room for
                    // little more than the close itself.
                    Self::try_populate_acks(
                        now,
                        self.receiving_ecn,
                        &mut SentFrames::default(),
                        &self.spaces[space_id],
                        buf,
                        &mut self.stats,
                        builder
                            .max_size
                            .saturating_sub(frame::ConnectionClose::SIZE_BOUND),
                    );
                }

                let mut encoded = false;
                if builder.max_size.saturating_sub(buf.len()) >= frame::ConnectionClose::SIZE_BOUND
                {
                    encoded = true;
                    // The only place a close frame is written, so the only place one is
                    // counted.
                    self.stats.frame_tx.connection_close =
                        self.stats.frame_tx.connection_close.saturating_add(1);
                    let max_frame_size = builder.max_size - buf.len();
                    match self.state {
                        State::Closed(state::Closed { ref reason }) => {
                            if space_id == SpaceId::Data || reason.is_transport_layer() {
                                reason.encode(buf, max_frame_size)
                            } else {
                                frame::ConnectionClose {
                                    error_code: TransportErrorCode::APPLICATION_ERROR,
                                    frame_type: None,
                                    reason: Bytes::new(),
                                }
                                .encode(buf, max_frame_size)
                            }
                        }
                        State::Draining => frame::ConnectionClose {
                            error_code: TransportErrorCode::NO_ERROR,
                            frame_type: None,
                            reason: Bytes::new(),
                        }
                        .encode(buf, max_frame_size),
                        #[expect(
                            clippy::unreachable,
                            reason = "this block only runs when `close` is true, which `poll_transmit` computes solely for `State::Draining | State::Closed`"
                        )]
                        _ => unreachable!(
                            "tried to make a close packet when the connection wasn't closed"
                        ),
                    }
                }
                if !encoded {
                    // Nothing was written, so nothing has moved on: the same space is due
                    // again on the next pass and the close stays pending.
                    break;
                }
                // One response packet is permitted before draining; no packets follow
                // (RFC 9000 §10.2.2). This state carries that pending response, so the
                // cursor over spaces is only for a close this side is making.
                if space_id == self.highest_space || matches!(self.state, State::Draining) {
                    close_finished = true;
                    break;
                } else {
                    // A close goes in every space that has keys (RFC 9000 §10.2.3).
                    // Send each close separately so it remains reachable when a peer
                    // discards a preceding packet. The close stays pending until the highest
                    // space has had one; the next pass starts at `close_from`.
                    self.close_from = spaces
                        .get(space_idx + 1)
                        .copied()
                        .unwrap_or(self.highest_space);
                    break;
                }
            }

            // Whether this datagram can still reach `MIN_INITIAL_SIZE`, which decides whether
            // a challenge written into it can prove the path's minimum MTU (RFC 9000 §8.2.1).
            let expands = buf_capacity - builder.datagram_start >= usize::from(MIN_INITIAL_SIZE);
            let sent = if ack_only {
                let mut sent = SentFrames::default();
                Self::try_populate_acks(
                    now,
                    self.receiving_ecn,
                    &mut sent,
                    &self.spaces[space_id],
                    buf,
                    &mut self.stats,
                    builder.max_size,
                );
                sent
            } else if self
                .recorded_initial(space_id, builder.exact_number)
                .is_some()
            {
                match self.populate_recorded_initial(buf, builder.max_size, builder.exact_number) {
                    Ok(sent) => sent,
                    Err(error) => {
                        self.kill(now, error.into());
                        buf.clear();
                        return None;
                    }
                }
            } else {
                self.populate_packet(
                    now,
                    space_id,
                    buf,
                    builder.max_size,
                    builder.exact_number,
                    expands,
                )
            };

            // ACK-only packets should only be sent when explicitly allowed. If we write them due to
            // any other reason, there is a bug which leads to one component announcing write
            // readiness while not writing any data. This degrades performance. The condition is
            // only checked if the full MTU is available and when potentially large fixed-size
            // frames aren't queued, so that lack of space in the datagram isn't the reason for just
            // writing ACKs.
            debug_assert!(
                !(!ack_only
                    && sent.is_ack_only(&self.streams)
                    && !can_send.acks
                    && can_send.other
                    && (buf_capacity - builder.datagram_start) == self.path.current_mtu() as usize
                    && self.datagrams.outgoing.is_empty()),
                "SendableFrames was {can_send:?}, but only ACKs have been written"
            );
            pad_datagram |= sent.requires_padding;

            if sent.largest_acked.is_some() {
                self.spaces[space_id].pending_acks.acks_sent();
                self.timers.stop(Timer::MaxAckDelay);
                self.next_bundled_ack_time = Some(now + self.next_bundled_ack_delay());
            }

            // Keep information about the packet around until it gets finalized
            sent_frames = Some(sent);
            if ack_only {
                // GSO would pad this exempt packet to a full segment before
                // appending another datagram. PADDING counts in flight, so
                // finish the compact ACK here and leave later spaces queued.
                break;
            }

            // Don't increment space_idx.
            // We stay in the current space and check if there is more data to send.
        }

        // Finish the last packet
        if let Some(mut builder) = builder_storage {
            let mut tail_to = None;
            let recorded = self
                .recorded_initial(builder.space, builder.exact_number)
                .is_some();
            if pad_datagram && !recorded {
                let size = self
                    .config
                    .wire
                    .packetization
                    .initial_datagram_size()
                    .max(self.config.min_mtu)
                    .max(MIN_INITIAL_SIZE);
                match self.config.wire.packetization.padding() {
                    // Zero bytes after the last packet bring the datagram up to size; a
                    // receiver drops them as not being a packet (RFC 9000 §12.2). The
                    // configured minimum stays inside the packet.
                    PaddingPlacement::DatagramTail => {
                        builder.pad_to(self.config.min_mtu);
                        tail_to = Some((datagram_start + usize::from(size)).min(buf_capacity));
                    }
                    // `Frames`, and any future placement, pad inside the packet.
                    _ => builder.pad_to(size),
                }
            }

            // If this datagram is a loss probe and `segment_size` is larger than `INITIAL_MTU`,
            // then padding it to `segment_size` would risk failure to recover from a reduction in
            // path MTU.
            // Loss probes are the only packets for which we might grow `buf_capacity`
            // by less than `segment_size`.
            if pad_datagram_to_mtu && buf_capacity >= datagram_start + segment_size && !recorded {
                builder.pad_to(segment_size as u16);
            }

            let last_packet_number = builder.exact_number;
            builder.finish_and_track(now, self, sent_frames, buf)?;
            if let Some(target) = tail_to
                && buf.len() < target
            {
                buf.resize(target, 0);
            }
            self.path
                .congestion
                .on_sent(now, buf.len() as u64, last_packet_number);

            self.qlog_sink.emit_recovery_metrics(
                self.pto_count,
                &mut self.path,
                now,
                self.trace_cid,
            );
        }

        self.app_limited = buf.is_empty() && !congestion_blocked;

        // Requiring spare congestion/pacing credit would starve PLPMTUD behind
        // busy streams. RFC 8899 §3 item 7 permits independent probe admission:
        // one outstanding probe until ACK/loss bounds its rate by the RTT, while
        // its bytes still count in flight. Confirmation protects handshake data.
        if buf.is_empty() && self.handshake_confirmed() && self.path.mtu_validated {
            let space_id = SpaceId::Data;
            let probe_size = self
                .path
                .mtud
                .poll_transmit(now, self.packet_number_filter.peek(&self.spaces[space_id]))?;

            let buf_capacity = probe_size as usize;
            buf.reserve(buf_capacity);

            let mut builder = PacketBuilder::new(
                now,
                space_id,
                self.rem_cids.active(),
                (self.path.remote, self.path.local),
                buf,
                buf_capacity,
                0,
                true,
                self,
            )?;

            // We implement MTU probes as ping packets padded up to the probe size
            buf.write(frame::FrameType::PING);
            self.stats.frame_tx.ping += 1;

            // If supported by the peer, we want no delays to the probe's ACK
            if self.peer_supports_ack_frequency() {
                buf.write(frame::FrameType::IMMEDIATE_ACK);
                self.stats.frame_tx.immediate_ack += 1;
            }

            builder.pad_to(probe_size);
            let sent_frames = SentFrames {
                non_retransmits: true,
                ..Default::default()
            };
            builder.finish_and_track(now, self, Some(sent_frames), buf)?;

            self.stats.path.sent_plpmtud_probes += 1;
            num_datagrams = 1;

            trace!(?probe_size, "writing MTUD probe");
        }

        if buf.is_empty() {
            return None;
        }

        // A pass that stopped short leaves the close pending, and the next one carries on
        // from the space it reached.
        if close_finished {
            self.close = false;
            self.close_from = SpaceId::Initial;
            self.close_responses.answered();
        }

        if let Some(order) = wire_order {
            // Only a transmit holding exactly the burst, nothing else, is reordered.
            let built = self.spaces[SpaceId::Initial].next_packet_number;
            let complete = order
                .iter()
                .min()
                .is_some_and(|first| built == first + order.len() as u64);
            if !(complete && reorder_recorded_burst(buf, &order, num_datagrams, segment_size)) {
                debug!("QUIC: recorded Initial burst sent in packet-number order");
            }
        }

        trace!("sending {} bytes in {} datagrams", buf.len(), num_datagrams);
        self.path.total_sent = self.path.total_sent.saturating_add(buf.len() as u64);

        self.stats.udp_tx.on_sent(num_datagrams as u64, buf.len());

        Some(Transmit {
            destination: self.path.remote,
            size: buf.len(),
            cid_used: Some(self.rem_cids.active_seq()),
            ecn: if self.path.sending_ecn {
                Some(EcnCodepoint::Ect0)
            } else {
                None
            },
            // Every datagram is at least the minimum datagram size, so a segment is never empty.
            segment_size: match num_datagrams {
                1 => None,
                _ => NonZeroUsize::new(segment_size),
            },
            local: self.path.local,
        })
    }

    /// Send PATH_CHALLENGE for a previous path if necessary
    fn send_path_challenge(&mut self, now: Instant, buf: &mut Vec<u8>) -> Option<Transmit> {
        if self.state.is_closed() {
            return None;
        }
        let current_pto = self.pto(SpaceId::Data);
        let held = self.rem_cids.held();
        let active = (self.rem_cids.active(), self.rem_cids.active_seq());
        let PrevPath {
            path: prev_path,
            cid,
        } = self.prev_path.as_ref()?;
        let interval =
            current_pto.max(prev_path.rtt.pto_base() + self.ack_frequency.max_ack_delay_for_pto());
        let token = match prev_path.challenge.as_ref() {
            Some(challenge) if challenge.pending() => challenge.token(),
            _ => return None,
        };
        // The previous path is only ever sent with the connection ID bound to it, from the local
        // address that path uses (RFC 9000 §9.5).
        let (prev_cid, prev_seq) = match cid {
            PrevCid::Held => held.map(|held| (held.id, held.seq))?,
            PrevCid::Active => active,
            PrevCid::Gone => return None,
        };
        let local = prev_path.local;
        let destination = prev_path.remote;
        debug_assert_eq!(
            self.highest_space,
            SpaceId::Data,
            "PATH_CHALLENGE queued without 1-RTT keys"
        );
        buf.reserve(MIN_INITIAL_SIZE as usize);

        let buf_capacity = buf.capacity();

        let mut builder = PacketBuilder::new(
            now,
            SpaceId::Data,
            prev_cid,
            (destination, local),
            buf,
            buf_capacity,
            0,
            false,
            self,
        )?;
        trace!("validating previous path with PATH_CHALLENGE {:08x}", token);
        buf.write(frame::FrameType::PATH_CHALLENGE);
        buf.write(token);
        self.stats.frame_tx.path_challenge += 1;

        // An endpoint MUST expand datagrams that contain a PATH_CHALLENGE frame
        // to at least the smallest allowed maximum datagram size of 1200 bytes,
        // unless the anti-amplification limit for the path does not permit
        // sending a datagram of this size
        builder.pad_to(MIN_INITIAL_SIZE);

        builder.finish(self, now, buf)?;
        if let Some(challenge) = self
            .prev_path
            .as_mut()
            .and_then(|prev| prev.path.challenge.as_mut())
        {
            challenge.written(now, interval);
        }
        self.arm_path_challenge_timer();
        self.stats.udp_tx.on_sent(1, buf.len());

        Some(Transmit {
            destination,
            size: buf.len(),
            ecn: None,
            segment_size: None,
            local,
            cid_used: Some(prev_seq),
        })
    }

    /// Answer a PATH_CHALLENGE that arrived on a path other than the current one. The answer
    /// leaves on that path (RFC 9000 §8.2.2) and carries the identifier bound to it (§9.5);
    /// without such an identifier the answer is dropped and counted, because answering with one
    /// this connection sends elsewhere is exactly the reuse §9.5 forbids.
    fn send_off_path_response(&mut self, now: Instant, buf: &mut Vec<u8>) -> Option<Transmit> {
        if self.highest_space != SpaceId::Data || self.state.is_closed() {
            return None;
        }
        let (tokens, remote, local, max_response_size) = self
            .path_responses
            .pop_off_path(self.path.remote, self.path.local)?;
        let max_response_size = self
            .server_candidate
            .as_ref()
            .filter(|c| c.remote == remote && c.local == local)
            .map_or(max_response_size, |c| {
                c.send_capacity().min(max_response_size)
            });
        let Some((cid, seq)) = self.cid_for_path(remote, local) else {
            self.stats.path.unanswered_off_path_challenges += tokens.len() as u64;
            debug!(%remote, ?local, "no connection ID bound to that path: its answer is dropped");
            return None;
        };
        // An off-path response has no validated-path budget to borrow. Its padding must
        // fit one received packet's credit, shared by every token in this batch
        // (RFC 9000 section 8.2.2). Four distinct tokens fit even the credit from
        // a minimum-sized valid PATH_CHALLENGE packet.
        let minimum_size = 1 + cid.len() + 4 + self.tag_len_1rtt() + 9 * tokens.len();
        if max_response_size < minimum_size {
            self.stats.path.unanswered_off_path_challenges += tokens.len() as u64;
            return None;
        }
        buf.reserve(max_response_size);
        let buf_capacity = max_response_size;
        let mut builder = PacketBuilder::new(
            now,
            SpaceId::Data,
            cid,
            (remote, local),
            buf,
            buf_capacity,
            0,
            false,
            self,
        )?;
        for token in tokens {
            trace!(%remote, ?local, "PATH_RESPONSE {:08x} (off-path)", token);
            buf.write(frame::FrameType::PATH_RESPONSE);
            buf.write(token);
            self.stats.frame_tx.path_response += 1;
        }
        builder.pad_to(MIN_INITIAL_SIZE);
        builder.finish(self, now, buf)?;
        if let Some(candidate) = self.server_candidate.as_mut()
            && candidate.remote == remote
            && candidate.local == local
        {
            candidate.sent = candidate.sent.saturating_add(buf.len() as u64);
        }
        self.stats.udp_tx.on_sent(1, buf.len());
        Some(Transmit {
            destination: remote,
            size: buf.len(),
            ecn: None,
            segment_size: None,
            local,
            cid_used: Some(seq),
        })
    }

    /// Indicate what types of frames are ready to send for the given space
    fn space_can_send(&self, space_id: SpaceId, frame_space_1rtt: usize) -> SendableFrames {
        if self.spaces[space_id].crypto.is_none()
            && (space_id != SpaceId::Data
                || self.zero_rtt_crypto.is_none()
                || self.side.is_server())
        {
            // No keys available for this space
            return SendableFrames::empty();
        }
        let mut can_send = self.spaces[space_id].can_send(&self.streams);
        if space_id == SpaceId::Data {
            can_send.other |= self.can_send_1rtt(frame_space_1rtt);
        }
        can_send
    }

    /// The delay to wait after sending an ACK before bundling the next one.
    ///
    /// This delay prevents waste of peer's resources with processing bundled
    /// ACKs unnecessarily frequently.
    ///
    /// If we receive an ack-eliciting packet while this delay is still pending,
    /// `next_bundled_ack_time` is reset to `now`, which means this delay will be ignored.
    /// So this delay only matters when we keep sending but stop receiving ack-eliciting
    /// packets for a while.
    ///
    /// This should be at least `RTT + peer's max_ack_delay`: since a bundled ACK frame rides
    /// along with an ack-eliciting frame, the packet carrying it is itself ack-eliciting.
    /// We should give the peer enough time to acknowledge it.
    /// Otherwise, we risk bundling another ACK before the peer has even had a chance
    /// to acknowledge the previous one, which is a waste of remote peer's resources.
    fn next_bundled_ack_delay(&self) -> Duration {
        self.path.rtt.get() + self.ack_frequency.peer_max_ack_delay + TIMER_GRANULARITY
    }

    /// The smallest datagram this side would build towards the current path: one carrying an
    /// Initial is padded to `MIN_INITIAL_SIZE` (RFC 9000 §14.1), and below `MIN_PACKET_SPACE` no
    /// packet fits at all.
    fn min_datagram_size(&self) -> usize {
        match self.spaces[SpaceId::Initial].crypto.is_some() {
            true => usize::from(MIN_INITIAL_SIZE),
            false => MIN_PACKET_SPACE,
        }
    }

    /// Whether an unvalidated address has left too little allowance for any datagram at all,
    /// which is the point at which `poll_transmit` stops (RFC 9000 §8).
    pub(super) fn amplification_stalled(&self) -> bool {
        self.path
            .anti_amplification_blocked(self.min_datagram_size() as u64)
    }

    /// Returns the detected maximum udp payload size for the current path
    #[cfg(test)]
    pub(crate) fn path_mtu(&self) -> u16 {
        self.path.current_mtu()
    }

    /// Whether we have 1-RTT data to send
    ///
    /// See also `self.space(SpaceId::Data).can_send()`
    fn can_send_1rtt(&self, max_size: usize) -> bool {
        self.streams.can_send_stream_data()
            // STREAMS_BLOCKED belongs only to the application data space. Counting it in
            // every space's retransmits would keep emitting empty handshake packets.
            || self.streams.has_streams_blocked()
            || self.path.challenge.is_some_and(|it| it.pending())
            || self
                .prev_path
                .as_ref()
                .is_some_and(|prev| prev.path.challenge.is_some_and(|it| it.pending()))
            || self.candidate.as_ref().is_some_and(|c| c.pending.is_some())
            || !self.path_responses.is_empty()
            || self.datagrams.outgoing.can_send_1rtt(max_size)
    }

    /// Storage size required for the largest packet known to be supported by the current path
    ///
    /// Buffers passed to [`Connection::poll_transmit`] should be at least this large.
    pub(crate) fn current_mtu(&self) -> u16 {
        self.path.current_mtu()
    }

    /// The largest UDP payload this connection may put on its current path. MTU discovery probes
    /// deliberately search above [`Self::current_mtu`], so this, and not the confirmed MTU, is
    /// what bounds a datagram now. It says nothing about what an earlier path allowed.
    #[cfg(test)]
    pub(crate) fn max_datagram_payload(&self) -> u16 {
        self.path.max_payload()
    }

    /// Size of non-frame data for a 1-RTT packet
    ///
    /// Quantifies space consumed by the QUIC header and AEAD tag. All other bytes in a packet are
    /// frames. Changes if the length of the remote connection ID changes, which is expected to be
    /// rare. If `pn` is specified, may additionally change unpredictably due to variations in
    /// latency and packet loss.
    pub(super) fn predict_1rtt_overhead(&self, pn: Option<u64>) -> usize {
        let pn_len = match pn {
            Some(pn) => PacketNumber::new(
                pn,
                self.spaces[SpaceId::Data].largest_acked_packet.unwrap_or(0),
            )
            .map_or(4, |number| number.len()),
            // Upper bound
            None => 4,
        };

        // 1 byte for flags
        1 + self.rem_cids.active().len() + pn_len + self.tag_len_1rtt()
    }

    pub(super) fn tag_len_1rtt(&self) -> usize {
        let key = match self.spaces[SpaceId::Data].crypto.as_ref() {
            Some(crypto) => Some(&*crypto.local.packet),
            None => self.zero_rtt_crypto.as_ref().map(|x| &*x.packet),
        };
        // If neither Data nor 0-RTT keys are available, make a reasonable tag length guess. As of
        // this writing, all QUIC cipher suites use 16-byte tags. We could return `None` instead,
        // but that would needlessly prevent sending datagrams during 0-RTT.
        key.map_or(16, |x| x.tag_len())
    }
}

/// Minimal remaining size to allow packet coalescing, excluding cryptographic tag
///
/// This must be at least as large as the header for a well-formed empty packet to be coalesced,
/// plus some space for frames. We only care about handshake headers because short header packets
/// necessarily have smaller headers, and initial packets are only ever the first packet in a
/// datagram (because we coalesce in ascending packet space order and the only reason to split a
/// packet is when packet space changes).
const MIN_PACKET_SPACE: usize = MAX_HANDSHAKE_OR_0RTT_HEADER_SIZE + 32;

/// Largest amount of space that could be occupied by a Handshake or 0-RTT packet's header
///
/// Excludes packet-type-specific fields such as packet number or Initial token
// https://www.rfc-editor.org/rfc/rfc9000.html#name-0-rtt: flags + version + dcid len + dcid +
// scid len + scid + length + pn
const MAX_HANDSHAKE_OR_0RTT_HEADER_SIZE: usize =
    1 + 4 + 1 + MAX_CID_SIZE + 1 + MAX_CID_SIZE + VarInt::from_u32(u16::MAX as u32).size() + 4;

#[derive(Default)]
pub(super) struct SentFrames {
    /// The path-validation token this datagram carried, if any. The finish point records how
    /// large the datagram turned out, which is what a response to that token can prove.
    pub(super) challenge: Option<u64>,
    pub(super) retransmits: ThinRetransmits,
    pub(super) largest_acked: Option<u64>,
    pub(super) stream_frames: StreamMetaVec,
    /// Whether the packet contains non-retransmittable frames (like datagrams)
    pub(super) non_retransmits: bool,
    pub(super) requires_padding: bool,
}

impl SentFrames {
    /// Returns whether the packet contains only ACKs
    fn is_ack_only(&self, streams: &StreamsState) -> bool {
        self.largest_acked.is_some()
            && !self.non_retransmits
            && self.stream_frames.is_empty()
            && self.retransmits.is_empty(streams)
    }
}

/// Put a recorded Initial burst, built in packet-number order, into its wire order.
/// Returns false, leaving `buf` as built, unless it holds the burst in equal segments.
fn reorder_recorded_burst(
    buf: &mut [u8],
    wire_order: &[u64],
    datagrams: usize,
    segment_size: usize,
) -> bool {
    let Some(&first) = wire_order.iter().min() else {
        return false;
    };
    if datagrams != wire_order.len() || Some(buf.len()) != segment_size.checked_mul(datagrams) {
        return false;
    }
    let built = buf.to_vec();
    for (slot, number) in wire_order.iter().enumerate() {
        let index = (number - first) as usize;
        buf[slot * segment_size..(slot + 1) * segment_size]
            .copy_from_slice(&built[index * segment_size..(index + 1) * segment_size]);
    }
    true
}
