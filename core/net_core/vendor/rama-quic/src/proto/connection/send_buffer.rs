use std::{collections::VecDeque, ops::Range};

use rama_core::bytes::{Buf, Bytes};
use rama_quic_proto::{VarInt, range_set::RangeSet};

/// Buffer of outgoing retransmittable stream data
#[derive(Default, Debug)]
pub(super) struct SendBuffer {
    /// Data queued by the application but not yet acknowledged. May or may not have been sent.
    unacked_segments: VecDeque<Segment>,
    /// Total size of `unacked_segments`
    unacked_len: usize,
    /// Acknowledged bytes removed from the first segment's view but still held by its allocation
    front_trimmed: usize,
    /// The first offset that hasn't been written by the application, i.e. the offset past the end of `unacked`
    offset: u64,
    /// The first offset that hasn't been sent
    ///
    /// Always lies in (offset - unacked.len())..offset
    unsent: u64,
    /// Acknowledged ranges which couldn't be discarded yet as they don't include the earliest
    /// offset in `unacked`
    // TODO: Recover storage from these by compacting (#700)
    acks: RangeSet,
    /// Previously transmitted ranges deemed lost
    retransmits: RangeSet,
}

#[derive(Debug)]
struct Segment {
    /// Absolute end offset, unchanged when a partial ACK advances `data`.
    end: u64,
    data: Bytes,
}

impl SendBuffer {
    /// Construct an empty buffer at the initial offset
    pub(super) fn new() -> Self {
        Self::default()
    }

    /// Append application data to the end of the stream
    pub(super) fn write(&mut self, data: Bytes) {
        self.unacked_len += data.len();
        self.offset += data.len() as u64;
        self.unacked_segments.push_back(Segment {
            end: self.offset,
            data,
        });
    }

    /// Discard a range of acknowledged stream data
    pub(super) fn ack(&mut self, mut range: Range<u64>) {
        // An ACK can settle an original copy after a PTO queued another copy.
        // The ordinary ACK path has no queued retransmission to search.
        if !self.retransmits.is_empty() {
            self.retransmits.remove(range.clone());
        }
        // Clamp the range to data which is still tracked
        let base_offset = self.offset - self.unacked_len as u64;
        range.start = base_offset.max(range.start);
        range.end = base_offset.max(range.end);

        self.acks.insert(range);

        while self.acks.min() == Some(self.offset - self.unacked_len as u64) {
            #[expect(
                clippy::unwrap_used,
                reason = "the `while` condition just observed `acks.min() == Some(..)`"
            )]
            let prefix = self.acks.pop_min().unwrap();
            let mut to_advance = (prefix.end - prefix.start) as usize;

            self.unacked_len -= to_advance;
            while to_advance > 0 {
                #[expect(
                    clippy::expect_used,
                    reason = "`unacked_len` counts exactly the bytes in `unacked_segments`, so `to_advance > 0` implies a front segment"
                )]
                let front = self
                    .unacked_segments
                    .front_mut()
                    .expect("Expected buffered data");

                if front.data.len() <= to_advance {
                    to_advance -= front.data.len();
                    self.unacked_segments.pop_front();
                    self.front_trimmed = 0;

                    if self.unacked_segments.len() * 4 < self.unacked_segments.capacity() {
                        self.unacked_segments.shrink_to_fit();
                    }
                } else {
                    front.data.advance(to_advance);
                    self.front_trimmed += to_advance;
                    to_advance = 0;
                }
            }
        }
    }

    /// Compute the next range to transmit on this stream and update state to account for that
    /// transmission.
    ///
    /// `max_len` here includes the space which is available to transmit the
    /// offset and length of the data to send. The caller has to guarantee that
    /// there is at least enough space available to write maximum-sized metadata
    /// (8 byte offset + 8 byte length).
    ///
    /// The method returns a tuple:
    /// - The first return value indicates the range of data to send
    /// - The second return value indicates whether the length needs to be encoded
    ///   in the STREAM frames metadata (`true`), or whether it can be omitted
    ///   since the selected range will fill the whole packet.
    pub(super) fn poll_transmit(&mut self, mut max_len: usize) -> (Range<u64>, bool) {
        debug_assert!(max_len >= 8 + 8);
        let mut encode_length = false;

        if let Some(range) = self.retransmits.pop_min() {
            // Retransmit sent data

            // When the offset is known, we know how many bytes are required to encode it.
            // Offset 0 requires no space
            if range.start != 0 {
                max_len -= VarInt::size(VarInt::from_u64(range.start).unwrap_or(VarInt::MAX));
            }
            if range.end - range.start < max_len as u64 {
                encode_length = true;
                max_len -= 8;
            }

            let end = range.end.min((max_len as u64).saturating_add(range.start));
            if end != range.end {
                self.retransmits.insert(end..range.end);
            }
            return (range.start..end, encode_length);
        }

        // Transmit new data

        // When the offset is known, we know how many bytes are required to encode it.
        // Offset 0 requires no space
        if self.unsent != 0 {
            max_len -= VarInt::size(VarInt::from_u64(self.unsent).unwrap_or(VarInt::MAX));
        }
        if self.offset - self.unsent < max_len as u64 {
            encode_length = true;
            max_len -= 8;
        }

        let end = self
            .offset
            .min((max_len as u64).saturating_add(self.unsent));
        let result = self.unsent..end;
        self.unsent = end;
        (result, encode_length)
    }

    /// Returns data which is associated with a range
    ///
    /// This function can return a subset of the range, if the data is stored
    /// in noncontiguous fashion in the send buffer. In this case callers
    /// should call the function again with an incremented start offset to
    /// retrieve more data.
    pub(super) fn get(&self, offsets: Range<u64>) -> &[u8] {
        let base_offset = self.offset - self.unacked_len as u64;
        if offsets.start < base_offset {
            return &[];
        }

        let segment = if let Some(front) = self.unacked_segments.front()
            && offsets.start < front.end
        {
            front
        } else {
            // End offsets remain sorted, including across empty writes and partial ACKs.
            let index = self
                .unacked_segments
                .partition_point(|segment| segment.end <= offsets.start);

            let Some(segment) = self.unacked_segments.get(index) else {
                return &[];
            };
            segment
        };

        let segment_offset = segment.end - segment.data.len() as u64;
        let start = (offsets.start - segment_offset) as usize;
        let end = (offsets.end - segment_offset) as usize;

        &segment.data[start..end.min(segment.data.len())]
    }

    /// Queue a range of sent but unacknowledged data to be retransmitted
    pub(super) fn retransmit(&mut self, mut range: Range<u64>) {
        debug_assert!(range.end <= self.unsent, "unsent data can't be lost");
        // Another copy may already have been acknowledged. Never queue bytes
        // which `get` can no longer retrieve, including a released prefix.
        range.start = range.start.max(self.offset - self.unacked_len as u64);
        let (start, end) = (range.start, range.end);
        self.retransmits.insert(range);
        for acked in self
            .acks
            .iter()
            .skip_while(|acked| acked.end <= start)
            .take_while(|acked| acked.start < end)
        {
            self.retransmits.remove(acked);
        }
    }

    pub(super) fn retransmit_all_for_0rtt(&mut self) {
        debug_assert_eq!(self.offset, self.unacked_len as u64);
        self.unsent = 0;
    }

    /// First stream offset unwritten by the application, i.e. the offset that the next write will
    /// begin at
    pub(super) fn offset(&self) -> u64 {
        self.offset
    }

    /// Whether all sent data has been acknowledged
    pub(super) fn is_fully_acked(&self) -> bool {
        self.unacked_len == 0
    }

    /// Whether there's data to send
    ///
    /// There may be sent unacknowledged data even when this is false.
    pub(super) fn has_unsent_data(&self) -> bool {
        self.unsent != self.offset || !self.retransmits.is_empty()
    }

    /// Bytes still retained from application writes, including acknowledged data whose
    /// allocation has not been released yet
    pub(super) fn buffered(&self) -> u64 {
        (self.unacked_len + self.front_trimmed) as u64
    }

    /// Release abandoned data while preserving the final offset for RESET_STREAM
    pub(super) fn discard(&mut self) {
        *self = Self {
            offset: self.offset,
            unsent: self.offset,
            ..Self::default()
        };
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use rama_utils::octets;

    #[test]
    fn fragment_with_length() {
        let mut buf = SendBuffer::new();
        const MSG: &[u8] = b"Hello, world!";
        buf.write(MSG.into());
        // 0 byte offset => 19 bytes left => 13 byte data isn't enough
        // with 8 bytes reserved for length 11 payload bytes will fit
        assert_eq!(buf.poll_transmit(19), (0..11, true));
        assert_eq!(
            buf.poll_transmit(MSG.len() + 16 - 11),
            (11..MSG.len() as u64, true)
        );
        assert_eq!(
            buf.poll_transmit(58),
            (MSG.len() as u64..MSG.len() as u64, true)
        );
    }

    #[test]
    fn fragment_without_length() {
        let mut buf = SendBuffer::new();
        const MSG: &[u8] = b"Hello, world with some extra data!";
        buf.write(MSG.into());
        // 0 byte offset => 19 bytes left => can be filled by 34 bytes payload
        assert_eq!(buf.poll_transmit(19), (0..19, false));
        assert_eq!(
            buf.poll_transmit(MSG.len() - 19 + 1),
            (19..MSG.len() as u64, false)
        );
        assert_eq!(
            buf.poll_transmit(58),
            (MSG.len() as u64..MSG.len() as u64, true)
        );
    }

    #[test]
    fn reserves_encoded_offset() {
        let mut buf = SendBuffer::new();

        // Pretend we have more than 1 GB of data in the buffer
        let chunk: Bytes = Bytes::from_static(&[0; octets::mib(1)]);
        for _ in 0..1025 {
            buf.write(chunk.clone());
        }

        const SIZE1: u64 = 64;
        const SIZE2: u64 = octets::kib_u64(16);
        const SIZE3: u64 = octets::gib_u64(1);

        // Offset 0 requires no space
        assert_eq!(buf.poll_transmit(16), (0..16, false));
        buf.retransmit(0..16);
        assert_eq!(buf.poll_transmit(16), (0..16, false));
        let mut transmitted = 16u64;

        // Offset 16 requires 1 byte
        assert_eq!(
            buf.poll_transmit((SIZE1 - transmitted + 1) as usize),
            (transmitted..SIZE1, false)
        );
        buf.retransmit(transmitted..SIZE1);
        assert_eq!(
            buf.poll_transmit((SIZE1 - transmitted + 1) as usize),
            (transmitted..SIZE1, false)
        );
        transmitted = SIZE1;

        // Offset 64 requires 2 bytes
        assert_eq!(
            buf.poll_transmit((SIZE2 - transmitted + 2) as usize),
            (transmitted..SIZE2, false)
        );
        buf.retransmit(transmitted..SIZE2);
        assert_eq!(
            buf.poll_transmit((SIZE2 - transmitted + 2) as usize),
            (transmitted..SIZE2, false)
        );
        transmitted = SIZE2;

        // Offset 16384 requires requires 4 bytes
        assert_eq!(
            buf.poll_transmit((SIZE3 - transmitted + 4) as usize),
            (transmitted..SIZE3, false)
        );
        buf.retransmit(transmitted..SIZE3);
        assert_eq!(
            buf.poll_transmit((SIZE3 - transmitted + 4) as usize),
            (transmitted..SIZE3, false)
        );
        transmitted = SIZE3;

        // Offset 1GB requires 8 bytes
        assert_eq!(
            buf.poll_transmit(chunk.len() + 8),
            (transmitted..transmitted + chunk.len() as u64, false)
        );
        buf.retransmit(transmitted..transmitted + chunk.len() as u64);
        assert_eq!(
            buf.poll_transmit(chunk.len() + 8),
            (transmitted..transmitted + chunk.len() as u64, false)
        );
    }

    #[test]
    fn multiple_segments() {
        let mut buf = SendBuffer::new();
        const MSG: &[u8] = b"Hello, world!";
        const MSG_LEN: u64 = MSG.len() as u64;

        const SEG1: &[u8] = b"He";
        buf.write(SEG1.into());
        const SEG2: &[u8] = b"llo,";
        buf.write(SEG2.into());
        const SEG3: &[u8] = b" w";
        buf.write(SEG3.into());
        const SEG4: &[u8] = b"o";
        buf.write(SEG4.into());
        const SEG5: &[u8] = b"rld!";
        buf.write(SEG5.into());

        assert_eq!(aggregate_unacked(&buf), MSG);

        assert_eq!(buf.poll_transmit(16), (0..8, true));
        assert_eq!(buf.get(0..5), SEG1);
        assert_eq!(buf.get(2..8), SEG2);
        assert_eq!(buf.get(6..8), SEG3);

        assert_eq!(buf.poll_transmit(16), (8..MSG_LEN, true));
        assert_eq!(buf.get(8..MSG_LEN), SEG4);
        assert_eq!(buf.get(9..MSG_LEN), SEG5);

        assert_eq!(buf.poll_transmit(42), (MSG_LEN..MSG_LEN, true));

        // Now drain the segments
        buf.ack(0..1);
        assert_eq!(aggregate_unacked(&buf), &MSG[1..]);
        buf.ack(0..3);
        assert_eq!(aggregate_unacked(&buf), &MSG[3..]);
        buf.ack(3..5);
        assert_eq!(aggregate_unacked(&buf), &MSG[5..]);
        buf.ack(7..9);
        assert_eq!(aggregate_unacked(&buf), &MSG[5..]);
        buf.ack(4..7);
        assert_eq!(aggregate_unacked(&buf), &MSG[9..]);
        buf.ack(0..MSG_LEN);
        assert_eq!(aggregate_unacked(&buf), &[] as &[u8]);
    }

    #[test]
    fn retransmit() {
        let mut buf = SendBuffer::new();
        const MSG: &[u8] = b"Hello, world with extra data!";
        buf.write(MSG.into());
        // Transmit two frames
        assert_eq!(buf.poll_transmit(16), (0..16, false));
        assert_eq!(buf.poll_transmit(16), (16..23, true));
        // Lose the first, but not the second
        buf.retransmit(0..16);
        // Ensure we only retransmit the lost frame, then continue sending fresh data
        assert_eq!(buf.poll_transmit(16), (0..16, false));
        assert_eq!(buf.poll_transmit(16), (23..MSG.len() as u64, true));
        // Lose the second frame
        buf.retransmit(16..23);
        assert_eq!(buf.poll_transmit(16), (16..23, true));
    }

    #[test]
    fn probing_copies_never_requeue_acknowledged_bytes() {
        for ack_first in [false, true] {
            let mut buf = SendBuffer::new();
            buf.write(Bytes::from_static(b"0123456789abcdef"));
            assert_eq!(buf.poll_transmit(32).0, 0..16);
            if !ack_first {
                buf.retransmit(0..16);
            }
            buf.ack(0..4);
            buf.ack(8..12);
            if ack_first {
                buf.retransmit(0..16);
            }
            assert_eq!(buf.poll_transmit(32).0, 4..8);
            assert_eq!(buf.poll_transmit(32).0, 12..16);
            buf.ack(4..16);
            buf.retransmit(0..16);
            assert!(!buf.has_unsent_data());
            assert_eq!(buf.buffered(), 0);
        }
    }

    #[test]
    fn ack() {
        let mut buf = SendBuffer::new();
        const MSG: &[u8] = b"Hello, world!";
        buf.write(MSG.into());
        assert_eq!(buf.poll_transmit(16), (0..8, true));
        buf.ack(0..8);
        assert_eq!(aggregate_unacked(&buf), &MSG[8..]);
    }

    #[test]
    fn reordered_ack() {
        let mut buf = SendBuffer::new();
        const MSG: &[u8] = b"Hello, world with extra data!";
        buf.write(MSG.into());
        assert_eq!(buf.poll_transmit(16), (0..16, false));
        assert_eq!(buf.poll_transmit(16), (16..23, true));
        buf.ack(16..23);
        assert_eq!(aggregate_unacked(&buf), MSG);
        buf.ack(0..16);
        assert_eq!(aggregate_unacked(&buf), &MSG[23..]);
        assert!(buf.acks.is_empty());
    }

    #[test]
    fn get_empty_and_single_segment() {
        let mut buf = SendBuffer::new();
        assert_eq!(buf.get(0..1), b"");
        buf.write(Bytes::new());
        assert_eq!(buf.get(0..1), b"");
        buf.write(Bytes::from_static(b"hello"));
        buf.write(Bytes::new());
        assert_eq!(buf.get(0..9), b"hello");
        assert_eq!(buf.get(2..4), b"ll");
        assert_eq!(buf.get(2..2), b"");
        assert_eq!(buf.get(5..9), b"");
        assert_eq!(buf.get(9..10), b"");

        buf.poll_transmit(32);
        buf.ack(0..2);
        assert_eq!(buf.get(1..5), b"");
        assert_eq!(buf.get(2..5), b"llo");
        buf.ack(2..5);
        assert_eq!(buf.get(2..5), b"");
        buf.write(Bytes::from_static(b"world"));
        assert_eq!(buf.get(5..20), b"world");
    }

    #[test]
    fn indexed_reads_match_flat_model_after_ack_and_refill() {
        let mut model = SendModel::default();
        model.buf.unacked_segments.reserve(16);
        for len in 1..=5 {
            model.write(len);
        }
        let partial_ack = model.bytes.len() - 1;
        for index in 5..16 {
            model.write(index % 7 + 1);
        }
        model.transmit();
        model.ack(0..partial_ack);
        for len in [2, 7, 3, 1] {
            model.write(len);
        }
        assert!(!model.buf.unacked_segments.as_slices().1.is_empty());
        model.check();
        model.transmit();

        // Keep an acknowledged hole, then close it with overlapping and duplicate ACKs.
        model.ack(partial_ack + 9..partial_ack + 17);
        model.ack(partial_ack + 11..partial_ack + 19);
        model.ack(0..partial_ack);
        model.ack(partial_ack..partial_ack + 12);
        model.ack(0..model.bytes.len());

        // Reuse the buffer at nonzero offsets, with duplicate end offsets from empty writes.
        for len in [0, 0, 3, 0, 19, 1, 0] {
            model.write(len);
            model.check();
        }
        model.transmit();
        let end = model.bytes.len();
        for index in (end - 23..end).rev() {
            model.ack(index..index + 1);
        }
        assert!(model.buf.is_fully_acked());
    }

    #[test]
    fn indexed_reads_match_retransmissions_and_0rtt_reset() {
        let mut model = SendModel::default();
        for len in [0, 1, 7, 0, 11, 3, 29, 0, 5] {
            model.write(len);
        }
        let end = model.bytes.len() as u64;
        let initial = model.transmit();
        assert_eq!(initial, model.bytes);

        model.buf.retransmit_all_for_0rtt();
        assert_eq!(model.transmit(), initial);

        model.buf.retransmit(31..end);
        model.buf.retransmit(9..27);
        model.buf.retransmit(0..5);
        let expected: Vec<_> = model.bytes[..5]
            .iter()
            .chain(&model.bytes[9..27])
            .chain(&model.bytes[31..])
            .copied()
            .collect();
        assert_eq!(model.transmit(), expected);

        model.ack(0..10);
        model.buf.retransmit(10..end);
        assert_eq!(model.transmit(), model.bytes[10..]);
        model.check();
    }

    /// Flat payload and per-byte ACK state, independent of segment indexing and range merging.
    #[derive(Default)]
    struct SendModel {
        buf: SendBuffer,
        bytes: Vec<u8>,
        acked: Vec<bool>,
        /// Where each write ended: a segment is released only once acknowledged whole.
        segment_ends: Vec<usize>,
    }

    impl SendModel {
        fn write(&mut self, len: usize) {
            let start = self.bytes.len();
            self.bytes
                .extend((start..start + len).map(|index| (index * 37 + index / 7) as u8));
            self.acked.resize(self.bytes.len(), false);
            self.buf.write(Bytes::copy_from_slice(&self.bytes[start..]));
            self.segment_ends.push(self.bytes.len());
        }

        fn ack(&mut self, range: Range<usize>) {
            self.acked[range.clone()].fill(true);
            self.buf.ack(range.start as u64..range.end as u64);
            self.check();
        }

        fn read(&self, mut range: Range<u64>) -> Vec<u8> {
            let mut result = Vec::new();
            while range.start < range.end {
                let data = self.buf.get(range.clone());
                assert!(!data.is_empty(), "missing data at {range:?}");
                assert!(data.len() as u64 <= range.end - range.start);
                let start = range.start as usize;
                assert_eq!(data, &self.bytes[start..start + data.len()]);
                result.extend_from_slice(data);
                range.start += data.len() as u64;
            }
            result
        }

        fn transmit(&mut self) -> Vec<u8> {
            let mut result = Vec::new();
            while self.buf.has_unsent_data() {
                let (range, _) = self.buf.poll_transmit(23);
                assert!(!range.is_empty());
                result.extend(self.read(range));
            }
            result
        }

        fn check(&self) {
            let end = self.bytes.len();
            let base = self.acked.iter().position(|acked| !acked).unwrap_or(end);
            assert_eq!(self.buf.offset(), end as u64);
            // Retained: everything from the start of the segment holding the first unacknowledged
            // byte, since acknowledged bytes ahead of it are still held by their allocations.
            let retained = if base == end {
                0
            } else {
                let segment_start = self
                    .segment_ends
                    .iter()
                    .copied()
                    .filter(|&segment_end| segment_end <= base)
                    .max()
                    .unwrap_or(0);
                end - segment_start
            };
            assert_eq!(self.buf.buffered(), retained as u64);
            assert!(
                self.buf.buffered() >= self.acked.iter().filter(|acked| !**acked).count() as u64
            );
            assert_eq!(self.buf.is_fully_acked(), base == end);
            for start in 0..=end + 1 {
                assert!(self.buf.get(start as u64..start as u64).is_empty());
                if start < base || start >= end {
                    assert!(self.buf.get(start as u64..end as u64 + 2).is_empty());
                    continue;
                }
                for len in [1, 3, 17, end - start] {
                    let stop = end.min(start + len);
                    assert_eq!(
                        self.read(start as u64..stop as u64),
                        self.bytes[start..stop]
                    );
                }
                let data = self.buf.get(start as u64..end as u64 + 2);
                assert!(!data.is_empty());
                assert_eq!(data, &self.bytes[start..start + data.len()]);
            }
        }
    }

    fn aggregate_unacked(buf: &SendBuffer) -> Vec<u8> {
        let mut result = Vec::new();
        for segment in buf.unacked_segments.iter() {
            result.extend_from_slice(&segment.data);
        }
        result
    }
}
