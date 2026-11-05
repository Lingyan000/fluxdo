use std::{
    cmp::{Ordering, max},
    collections::{BinaryHeap, binary_heap::PeekMut},
    mem,
};

use rama_core::bytes::{Buf, Bytes, BytesMut};

use rama_quic_proto::range_set::RangeSet;

use super::retained::{Retained, retain};

/// Helper to assemble unordered stream frames into an ordered stream
#[derive(Debug, Default)]
pub(super) struct Assembler {
    state: State,
    data: BinaryHeap<Buffer>,
    /// Total number of buffered bytes, including duplicates in ordered mode.
    buffered: usize,
    /// Estimated number of allocated bytes, will never be less than `buffered`.
    allocated: usize,
    /// Number of bytes read by the application. When only ordered reads have been used, this is the
    /// length of the contiguous prefix of the stream which has been consumed by the application,
    /// aka the stream offset.
    bytes_read: u64,
    end: u64,
}

impl Assembler {
    pub(super) fn new() -> Self {
        Self::default()
    }

    #[cfg(all(
        test,
        any(
            feature = "boring",
            all(feature = "rustls", any(feature = "aws-lc", feature = "ring"))
        )
    ))]
    pub(super) fn retained_bytes(&self) -> usize {
        self.allocated
    }

    /// Reset to the initial state
    pub(super) fn reinit(&mut self) {
        let old_data = mem::take(&mut self.data);
        *self = Self::default();
        self.data = old_data;
        self.data.clear();
    }

    pub(super) fn ensure_ordering(&mut self, ordered: bool) -> Result<(), IllegalOrderedRead> {
        if ordered && !self.state.is_ordered() {
            return Err(IllegalOrderedRead);
        } else if !ordered && self.state.is_ordered() {
            // Enter unordered mode
            if !self.data.is_empty() {
                // Get rid of possible duplicates, including copies of what was already read
                self.defragment(self.bytes_read);
            }
            let mut recvd = RangeSet::new();
            recvd.insert(0..self.bytes_read);
            for chunk in &self.data {
                recvd.insert(chunk.offset..chunk.offset + chunk.bytes.len() as u64);
            }
            self.state = State::Unordered { recvd };
        }
        Ok(())
    }

    /// Get the the next chunk
    pub(super) fn read(&mut self, max_length: usize, ordered: bool) -> Option<Chunk> {
        loop {
            let mut chunk = self.data.peek_mut()?;

            if ordered {
                if chunk.offset > self.bytes_read {
                    // Next chunk is after current read index
                    return None;
                } else if (chunk.offset + chunk.bytes.len() as u64) <= self.bytes_read {
                    // Next chunk is useless as the read index is beyond its end
                    self.buffered -= chunk.bytes.len();
                    self.allocated -= chunk.allocation_size;
                    PeekMut::pop(chunk);
                    continue;
                }

                // Determine `start` and `len` of the slice of useful data in chunk
                let start = (self.bytes_read - chunk.offset) as usize;
                if start > 0 {
                    chunk.bytes.advance(start);
                    chunk.offset += start as u64;
                    self.buffered -= start;
                }
            }

            return Some(if max_length < chunk.bytes.len() {
                self.bytes_read += max_length as u64;
                let offset = chunk.offset;
                chunk.offset += max_length as u64;
                self.buffered -= max_length;
                Chunk::new(offset, chunk.bytes.split_to(max_length))
            } else {
                self.bytes_read += chunk.bytes.len() as u64;
                self.buffered -= chunk.bytes.len();
                self.allocated -= chunk.allocation_size;
                let chunk = PeekMut::pop(chunk);
                Chunk::new(chunk.offset, chunk.bytes)
            });
        }
    }

    /// Copy fragmented chunk data to new chunks backed by a single buffer
    ///
    /// This makes sure we're not unnecessarily holding on to many larger allocations.
    /// We merge contiguous chunks in the process of doing so. Bytes before `start` are treated
    /// as already delivered and discarded.
    fn defragment(&mut self, start: u64) {
        // Chunks smaller than min_chunk_size are merged regardless of fragmentation
        let min_chunk_size = max(self.buffered.div_ceil(MAX_CHUNKS), MIN_RETAINED_CHUNK_SIZE);
        let new = BinaryHeap::with_capacity(self.data.len());
        let old = mem::replace(&mut self.data, new);
        let mut buffers = old.into_sorted_vec();
        self.buffered = 0;
        let mut fragmented_buffered = 0;
        let mut offset = start;
        for chunk in buffers.iter_mut().rev() {
            chunk.try_mark_defragment(offset);
            let size = chunk.bytes.len();
            offset = chunk.offset + size as u64;
            self.buffered += size;
            if !chunk.defragmented || size < min_chunk_size {
                fragmented_buffered += size;
            }
        }
        self.allocated = self.buffered;
        let mut buffer = BytesMut::with_capacity(fragmented_buffered);
        let mut offset = 0;
        for chunk in buffers.into_iter().rev() {
            // bytes might be empty after try_mark_defragment
            if chunk.bytes.is_empty() {
                continue;
            }
            if chunk.defragmented && chunk.bytes.len() >= min_chunk_size {
                self.data.push(chunk);
                continue;
            }
            // Overlap is resolved by try_mark_defragment
            if chunk.offset != offset + (buffer.len() as u64) {
                if !buffer.is_empty() {
                    self.data
                        .push(Buffer::new_defragmented(offset, buffer.split().freeze()));
                }
                offset = chunk.offset;
            }
            buffer.extend_from_slice(&chunk.bytes);
        }
        if !buffer.is_empty() {
            self.data
                .push(Buffer::new_defragmented(offset, buffer.split().freeze()));
        }
    }

    // Note: If a packet contains many frames from the same stream, the estimated over-allocation
    // will be much higher because we are counting the same allocation multiple times.
    pub(super) fn insert(
        &mut self,
        mut offset: u64,
        bytes: Bytes,
        allocated: usize,
    ) -> Result<(), TooManyChunks> {
        let Retained {
            mut bytes,
            charge: allocation_size,
        } = retain(bytes, allocated);
        self.end = self.end.max(offset + bytes.len() as u64);
        if let State::Unordered { ref mut recvd } = self.state {
            // Discard duplicate data
            for duplicate in recvd.replace(offset..offset + bytes.len() as u64) {
                if duplicate.start > offset {
                    let buffer = Buffer::new(
                        offset,
                        bytes.split_to((duplicate.start - offset) as usize),
                        allocation_size,
                    );
                    self.buffered += buffer.bytes.len();
                    self.allocated += buffer.allocation_size;
                    self.data.push(buffer);
                    offset = duplicate.start;
                }
                bytes.advance((duplicate.end - offset) as usize);
                offset = duplicate.end;
            }
            // Delivered spans leave the data but stay here, so the gaps they mark need their own cap.
            if recvd.len() > MAX_CHUNKS {
                return Err(TooManyChunks);
            }
        } else if offset < self.bytes_read {
            if (offset + bytes.len() as u64) <= self.bytes_read {
                return Ok(());
            } else {
                let diff = self.bytes_read - offset;
                offset += diff;
                bytes.advance(diff as usize);
            }
        }

        // No early return when empty: the dedup loop above may already have pushed chunks.
        if !bytes.is_empty() {
            let buffer = Buffer::new(offset, bytes, allocation_size);
            self.buffered += buffer.bytes.len();
            self.allocated += buffer.allocation_size;
            self.data.push(buffer);
        }
        // `self.buffered` also counts duplicate bytes, therefore we use
        // `self.end - self.bytes_read` as an upper bound of buffered unique
        // bytes. This will cause a defragmentation if the amount of duplicate
        // bytes exceedes a proportion of the receive window size.
        let buffered = self.buffered.min((self.end - self.bytes_read) as usize);
        let over_allocation = self.allocated - buffered;
        // Rationale: on the one hand, we want to defragment rarely, ideally never
        // in non-pathological scenarios. However, a pathological or malicious
        // peer could send us one-byte frames, and since we use reference-counted
        // buffers in order to prevent copying, this could result in keeping a lot
        // of memory allocated. This limits over-allocation in proportion to the
        // buffered data. The constants are chosen somewhat arbitrarily and try to
        // balance between defragmentation overhead and over-allocation.
        let threshold = 32768.max(buffered * 3 / 2);
        // Small gapped frames hold over-allocation below the threshold, so bound the count too.
        if over_allocation > threshold || self.data.len() > COMPACT_THRESHOLD {
            self.defragment(0);
            // ngtcp2 uses a threshold of 4000 -- try to be a little more conservative?
            if self.data.len() > MAX_CHUNKS {
                return Err(TooManyChunks);
            }
        }

        Ok(())
    }

    /// Number of bytes consumed by the application
    pub(super) fn bytes_read(&self) -> u64 {
        self.bytes_read
    }

    /// Check completeness while discarding buffers already owned by a stopped stream.
    /// Ordered buffers can overlap; their summed lengths are not evidence of coverage.
    /// Popping the existing heap visits offsets in order without another allocation.
    pub(super) fn discard_received_to(&mut self, final_offset: u64) -> bool {
        let complete = match &self.state {
            State::Unordered { recvd } => {
                final_offset == 0
                    || recvd
                        .iter()
                        .next()
                        .is_some_and(|range| range.start == 0 && range.end >= final_offset)
            }
            State::Ordered => {
                let mut contiguous = self.bytes_read;
                while let Some(buffer) = self.data.pop() {
                    if buffer.offset > contiguous {
                        break;
                    }
                    contiguous = contiguous.max(buffer.offset + buffer.bytes.len() as u64);
                    if contiguous >= final_offset {
                        break;
                    }
                }
                contiguous >= final_offset
            }
        };
        self.clear();
        complete
    }

    /// Discard all buffered data
    pub(super) fn clear(&mut self) {
        self.data.clear();
        self.buffered = 0;
        self.allocated = 0;
    }
}

/// A chunk of data from the receive stream
#[derive(Debug, PartialEq, Eq)]
pub struct Chunk {
    /// The offset in the stream
    pub offset: u64,
    /// The contents of the chunk
    pub bytes: Bytes,
}

impl Chunk {
    fn new(offset: u64, bytes: Bytes) -> Self {
        Self { offset, bytes }
    }
}

#[derive(Debug, Eq)]
struct Buffer {
    offset: u64,
    bytes: Bytes,
    /// Size of the allocation behind `bytes`, if `defragmented == false`.
    /// Otherwise this will be set to `bytes.len()` by `try_mark_defragment`.
    /// Will never be less than `bytes.len()`.
    allocation_size: usize,
    defragmented: bool,
}

impl Buffer {
    /// Constructs a new fragmented Buffer
    fn new(offset: u64, bytes: Bytes, allocation_size: usize) -> Self {
        Self {
            offset,
            bytes,
            allocation_size,
            defragmented: false,
        }
    }

    /// Constructs a new defragmented Buffer
    fn new_defragmented(offset: u64, bytes: Bytes) -> Self {
        let allocation_size = bytes.len();
        Self {
            offset,
            bytes,
            allocation_size,
            defragmented: true,
        }
    }

    /// Discards data before `offset` and flags `self` as defragmented if it has good utilization
    fn try_mark_defragment(&mut self, offset: u64) {
        let duplicate = offset.saturating_sub(self.offset);
        self.offset = self.offset.max(offset);
        if duplicate >= self.bytes.len() as u64 {
            // All bytes are duplicate
            self.bytes = Bytes::new();
            self.defragmented = true;
            self.allocation_size = 0;
            return;
        }
        self.bytes.advance(duplicate as usize);
        // Make sure that fragmented buffers with high utilization become defragmented and
        // defragmented buffers remain defragmented
        self.defragmented = self.defragmented || self.bytes.len() * 6 / 5 >= self.allocation_size;
        if self.defragmented {
            // Make sure that defragmented buffers do not contribute to over-allocation
            self.allocation_size = self.bytes.len();
        }
    }
}

impl Ord for Buffer {
    // Invert ordering based on offset (max-heap, min offset first),
    // prioritize longer chunks at the same offset.
    fn cmp(&self, other: &Self) -> Ordering {
        self.offset
            .cmp(&other.offset)
            .reverse()
            .then(self.bytes.len().cmp(&other.bytes.len()))
    }
}

impl PartialOrd for Buffer {
    fn partial_cmp(&self, other: &Self) -> Option<Ordering> {
        Some(self.cmp(other))
    }
}

impl PartialEq for Buffer {
    fn eq(&self, other: &Self) -> bool {
        (self.offset, self.bytes.len()) == (other.offset, other.bytes.len())
    }
}

#[derive(Debug, Default)]
enum State {
    #[default]
    Ordered,
    Unordered {
        /// The set of offsets that have been received from the peer, including portions not yet
        /// read by the application.
        recvd: RangeSet,
    },
}

impl State {
    fn is_ordered(&self) -> bool {
        matches!(self, Self::Ordered)
    }
}

/// Error indicating that an ordered read was performed on a stream after an unordered read
#[derive(Debug)]
pub(crate) struct IllegalOrderedRead;

/// Error indicating that too many chunks are buffered due to maliciously small/gapped frames
#[derive(Debug)]
pub(crate) struct TooManyChunks;

/// Bound on the number of distinct spans kept for a stream
///
/// Independent of how much memory those spans over-allocate. A frame is rejected only
/// if compaction cannot get the count back down to this.
const MAX_CHUNKS: usize = 1024;

/// Minimum size of a defragmented chunk that is retained without coalescing.
///
/// Chunks below this size will be copied on every compaction. 128 bytes balances
/// being cheap to copy while reducing the overhead of many small buffer nodes.
const MIN_RETAINED_CHUNK_SIZE: usize = 128;

/// Chunk count past which `insert` compacts before deciding whether to reject
///
/// Above `MAX_CHUNKS` so a flood of mergeable frames cannot force a defragmentation
/// per frame.
const COMPACT_THRESHOLD: usize = 2 * MAX_CHUNKS;

#[cfg(test)]
mod test {
    use super::*;

    #[test]
    fn assemble_ordered() {
        let mut x = Assembler::new();
        match next(&mut x, 32) {
            None => {}
            other => panic!("assertion failed: `{other:?}` does not match `None`"),
        }
        x.insert(0, Bytes::from_static(b"123"), 3).unwrap();
        match next(&mut x, 1) {
            Some(ref y) if &y[..] == b"1" => {}
            other => panic!(
                "assertion failed: `{other:?}` does not match `Some(ref y) if &y[..] == b\"1\"`"
            ),
        }
        match next(&mut x, 3) {
            Some(ref y) if &y[..] == b"23" => {}
            other => panic!(
                "assertion failed: `{other:?}` does not match `Some(ref y) if &y[..] == b\"23\"`"
            ),
        }
        x.insert(3, Bytes::from_static(b"456"), 3).unwrap();
        match next(&mut x, 32) {
            Some(ref y) if &y[..] == b"456" => {}
            other => panic!(
                "assertion failed: `{other:?}` does not match `Some(ref y) if &y[..] == b\"456\"`"
            ),
        }
        x.insert(6, Bytes::from_static(b"789"), 3).unwrap();
        x.insert(9, Bytes::from_static(b"10"), 2).unwrap();
        match next(&mut x, 32) {
            Some(ref y) if &y[..] == b"789" => {}
            other => panic!(
                "assertion failed: `{other:?}` does not match `Some(ref y) if &y[..] == b\"789\"`"
            ),
        }
        match next(&mut x, 32) {
            Some(ref y) if &y[..] == b"10" => {}
            other => panic!(
                "assertion failed: `{other:?}` does not match `Some(ref y) if &y[..] == b\"10\"`"
            ),
        }
        match next(&mut x, 32) {
            None => {}
            other => panic!("assertion failed: `{other:?}` does not match `None`"),
        }
    }

    #[test]
    fn assemble_unordered() {
        let mut x = Assembler::new();
        x.ensure_ordering(false).unwrap();
        x.insert(3, Bytes::from_static(b"456"), 3).unwrap();
        match next(&mut x, 32) {
            None => {}
            other => panic!("assertion failed: `{other:?}` does not match `None`"),
        }
        x.insert(0, Bytes::from_static(b"123"), 3).unwrap();
        match next(&mut x, 32) {
            Some(ref y) if &y[..] == b"123" => {}
            other => panic!(
                "assertion failed: `{other:?}` does not match `Some(ref y) if &y[..] == b\"123\"`"
            ),
        }
        match next(&mut x, 32) {
            Some(ref y) if &y[..] == b"456" => {}
            other => panic!(
                "assertion failed: `{other:?}` does not match `Some(ref y) if &y[..] == b\"456\"`"
            ),
        }
        match next(&mut x, 32) {
            None => {}
            other => panic!("assertion failed: `{other:?}` does not match `None`"),
        }
    }

    /// Copies of bytes an ordered read already returned can still be buffered when the stream
    /// switches to unordered reads; they must not be handed back a second time.
    #[test]
    fn unordered_after_ordered_read_drops_already_read_copies() {
        // Frames buffered before any read, the length of the ordered read, what is left unread.
        let cases: [(&[(u64, &'static str)], usize, &str); 3] = [
            (&[(0, "abc"), (0, "abc")], 3, ""),
            (&[(0, "abc"), (0, "abcdef")], 3, "def"),
            (&[(0, "abcd"), (1, "bcdef")], 4, "ef"),
        ];
        for (frames, ordered, rest) in cases {
            let mut x = Assembler::new();
            for &(offset, data) in frames {
                x.insert(offset, Bytes::from_static(data.as_bytes()), data.len())
                    .unwrap();
            }
            let chunk = x
                .read(ordered, true)
                .expect("the prefix is readable in order");
            assert_eq!(
                (chunk.offset, chunk.bytes.len()),
                (0, ordered),
                "{frames:?}"
            );

            x.ensure_ordering(false).unwrap();
            let mut unread = Vec::new();
            while let Some(chunk) = x.read(usize::MAX, false) {
                assert!(
                    chunk.offset >= ordered as u64,
                    "{frames:?}: offset {} was already read",
                    chunk.offset
                );
                unread.push(chunk);
            }
            unread.sort_by_key(|chunk| chunk.offset);
            let unread: Vec<u8> = unread
                .iter()
                .flat_map(|chunk| chunk.bytes.iter().copied())
                .collect();
            assert_eq!(unread, rest.as_bytes(), "{frames:?}");
            assert_eq!(x.bytes_read(), (ordered + rest.len()) as u64, "{frames:?}");
        }
    }

    #[test]
    fn assemble_duplicate() {
        let mut x = Assembler::new();
        x.insert(0, Bytes::from_static(b"123"), 3).unwrap();
        x.insert(0, Bytes::from_static(b"123"), 3).unwrap();
        match next(&mut x, 32) {
            Some(ref y) if &y[..] == b"123" => {}
            other => panic!(
                "assertion failed: `{other:?}` does not match `Some(ref y) if &y[..] == b\"123\"`"
            ),
        }
        match next(&mut x, 32) {
            None => {}
            other => panic!("assertion failed: `{other:?}` does not match `None`"),
        }
    }

    #[test]
    fn assemble_duplicate_compact() {
        let mut x = Assembler::new();
        x.insert(0, Bytes::from_static(b"123"), 3).unwrap();
        x.insert(0, Bytes::from_static(b"123"), 3).unwrap();
        x.defragment(0);
        match next(&mut x, 32) {
            Some(ref y) if &y[..] == b"123" => {}
            other => panic!(
                "assertion failed: `{other:?}` does not match `Some(ref y) if &y[..] == b\"123\"`"
            ),
        }
        match next(&mut x, 32) {
            None => {}
            other => panic!("assertion failed: `{other:?}` does not match `None`"),
        }
    }

    #[test]
    fn assemble_contained() {
        let mut x = Assembler::new();
        x.insert(0, Bytes::from_static(b"12345"), 5).unwrap();
        x.insert(1, Bytes::from_static(b"234"), 3).unwrap();
        match next(&mut x, 32) {
            Some(ref y) if &y[..] == b"12345" => {}
            other => panic!(
                "assertion failed: `{other:?}` does not match `Some(ref y) if &y[..] == b\"12345\"`"
            ),
        }
        match next(&mut x, 32) {
            None => {}
            other => panic!("assertion failed: `{other:?}` does not match `None`"),
        }
    }

    #[test]
    fn assemble_contained_compact() {
        let mut x = Assembler::new();
        x.insert(0, Bytes::from_static(b"12345"), 5).unwrap();
        x.insert(1, Bytes::from_static(b"234"), 3).unwrap();
        x.defragment(0);
        match next(&mut x, 32) {
            Some(ref y) if &y[..] == b"12345" => {}
            other => panic!(
                "assertion failed: `{other:?}` does not match `Some(ref y) if &y[..] == b\"12345\"`"
            ),
        }
        match next(&mut x, 32) {
            None => {}
            other => panic!("assertion failed: `{other:?}` does not match `None`"),
        }
    }

    #[test]
    fn assemble_contains() {
        let mut x = Assembler::new();
        x.insert(1, Bytes::from_static(b"234"), 3).unwrap();
        x.insert(0, Bytes::from_static(b"12345"), 5).unwrap();
        match next(&mut x, 32) {
            Some(ref y) if &y[..] == b"12345" => {}
            other => panic!(
                "assertion failed: `{other:?}` does not match `Some(ref y) if &y[..] == b\"12345\"`"
            ),
        }
        match next(&mut x, 32) {
            None => {}
            other => panic!("assertion failed: `{other:?}` does not match `None`"),
        }
    }

    #[test]
    fn assemble_contains_compact() {
        let mut x = Assembler::new();
        x.insert(1, Bytes::from_static(b"234"), 3).unwrap();
        x.insert(0, Bytes::from_static(b"12345"), 5).unwrap();
        x.defragment(0);
        match next(&mut x, 32) {
            Some(ref y) if &y[..] == b"12345" => {}
            other => panic!(
                "assertion failed: `{other:?}` does not match `Some(ref y) if &y[..] == b\"12345\"`"
            ),
        }
        match next(&mut x, 32) {
            None => {}
            other => panic!("assertion failed: `{other:?}` does not match `None`"),
        }
    }

    #[test]
    fn assemble_overlapping() {
        let mut x = Assembler::new();
        x.insert(0, Bytes::from_static(b"123"), 3).unwrap();
        x.insert(1, Bytes::from_static(b"234"), 3).unwrap();
        match next(&mut x, 32) {
            Some(ref y) if &y[..] == b"123" => {}
            other => panic!(
                "assertion failed: `{other:?}` does not match `Some(ref y) if &y[..] == b\"123\"`"
            ),
        }
        match next(&mut x, 32) {
            Some(ref y) if &y[..] == b"4" => {}
            other => panic!(
                "assertion failed: `{other:?}` does not match `Some(ref y) if &y[..] == b\"4\"`"
            ),
        }
        match next(&mut x, 32) {
            None => {}
            other => panic!("assertion failed: `{other:?}` does not match `None`"),
        }
    }

    #[test]
    fn assemble_overlapping_compact() {
        let mut x = Assembler::new();
        x.insert(0, Bytes::from_static(b"123"), 4).unwrap();
        x.insert(1, Bytes::from_static(b"234"), 4).unwrap();
        x.defragment(0);
        match next(&mut x, 32) {
            Some(ref y) if &y[..] == b"1234" => {}
            other => panic!(
                "assertion failed: `{other:?}` does not match `Some(ref y) if &y[..] == b\"1234\"`"
            ),
        }
        match next(&mut x, 32) {
            None => {}
            other => panic!("assertion failed: `{other:?}` does not match `None`"),
        }
    }

    #[test]
    fn assemble_complex() {
        let mut x = Assembler::new();
        x.insert(0, Bytes::from_static(b"1"), 1).unwrap();
        x.insert(2, Bytes::from_static(b"3"), 1).unwrap();
        x.insert(4, Bytes::from_static(b"5"), 1).unwrap();
        x.insert(0, Bytes::from_static(b"123456"), 6).unwrap();
        match next(&mut x, 32) {
            Some(ref y) if &y[..] == b"123456" => {}
            other => panic!(
                "assertion failed: `{other:?}` does not match `Some(ref y) if &y[..] == b\"123456\"`"
            ),
        }
        match next(&mut x, 32) {
            None => {}
            other => panic!("assertion failed: `{other:?}` does not match `None`"),
        }
    }

    #[test]
    fn assemble_complex_compact() {
        let mut x = Assembler::new();
        x.insert(0, Bytes::from_static(b"1"), 1).unwrap();
        x.insert(2, Bytes::from_static(b"3"), 1).unwrap();
        x.insert(4, Bytes::from_static(b"5"), 1).unwrap();
        x.insert(0, Bytes::from_static(b"123456"), 6).unwrap();
        x.defragment(0);
        match next(&mut x, 32) {
            Some(ref y) if &y[..] == b"123456" => {}
            other => panic!(
                "assertion failed: `{other:?}` does not match `Some(ref y) if &y[..] == b\"123456\"`"
            ),
        }
        match next(&mut x, 32) {
            None => {}
            other => panic!("assertion failed: `{other:?}` does not match `None`"),
        }
    }

    #[test]
    fn assemble_old() {
        let mut x = Assembler::new();
        x.insert(0, Bytes::from_static(b"1234"), 4).unwrap();
        match next(&mut x, 32) {
            Some(ref y) if &y[..] == b"1234" => {}
            other => panic!(
                "assertion failed: `{other:?}` does not match `Some(ref y) if &y[..] == b\"1234\"`"
            ),
        }
        x.insert(0, Bytes::from_static(b"1234"), 4).unwrap();
        match next(&mut x, 32) {
            None => {}
            other => panic!("assertion failed: `{other:?}` does not match `None`"),
        }
    }

    #[test]
    fn compact() {
        let mut x = Assembler::new();
        x.insert(0, Bytes::from_static(b"abc"), 4).unwrap();
        x.insert(3, Bytes::from_static(b"def"), 4).unwrap();
        x.insert(9, Bytes::from_static(b"jkl"), 4).unwrap();
        x.insert(12, Bytes::from_static(b"mno"), 4).unwrap();
        x.defragment(0);
        assert_eq!(
            next_unordered(&mut x),
            Chunk::new(0, Bytes::from_static(b"abcdef"))
        );
        assert_eq!(
            next_unordered(&mut x),
            Chunk::new(9, Bytes::from_static(b"jklmno"))
        );
    }

    #[test]
    fn defrag_with_missing_prefix() {
        let mut x = Assembler::new();
        x.insert(3, Bytes::from_static(b"def"), 3).unwrap();
        x.defragment(0);
        assert_eq!(
            next_unordered(&mut x),
            Chunk::new(3, Bytes::from_static(b"def"))
        );
    }

    #[test]
    fn defrag_read_chunk() {
        let mut x = Assembler::new();
        x.insert(3, Bytes::from_static(b"def"), 4).unwrap();
        x.insert(0, Bytes::from_static(b"abc"), 4).unwrap();
        x.insert(7, Bytes::from_static(b"hij"), 4).unwrap();
        x.insert(11, Bytes::from_static(b"lmn"), 4).unwrap();
        x.defragment(0);
        match x.read(usize::MAX, true) {
            Some(ref y) if &y.bytes[..] == b"abcdef" => {}
            other => panic!(
                "assertion failed: `{other:?}` does not match `Some(ref y) if &y.bytes[..] == b\"abcdef\"`"
            ),
        }
        x.insert(5, Bytes::from_static(b"fghijklmn"), 9).unwrap();
        match x.read(usize::MAX, true) {
            Some(ref y) if &y.bytes[..] == b"ghijklmn" => {}
            other => panic!(
                "assertion failed: `{other:?}` does not match `Some(ref y) if &y.bytes[..] == b\"ghijklmn\"`"
            ),
        }
        x.insert(13, Bytes::from_static(b"nopq"), 4).unwrap();
        match x.read(usize::MAX, true) {
            Some(ref y) if &y.bytes[..] == b"opq" => {}
            other => panic!(
                "assertion failed: `{other:?}` does not match `Some(ref y) if &y.bytes[..] == b\"opq\"`"
            ),
        }
        x.insert(15, Bytes::from_static(b"pqrs"), 4).unwrap();
        match x.read(usize::MAX, true) {
            Some(ref y) if &y.bytes[..] == b"rs" => {}
            other => panic!(
                "assertion failed: `{other:?}` does not match `Some(ref y) if &y.bytes[..] == b\"rs\"`"
            ),
        }
        match x.read(usize::MAX, true) {
            None => {}
            other => panic!("assertion failed: `{other:?}` does not match `None`"),
        }
    }

    #[test]
    fn unordered_happy_path() {
        let mut x = Assembler::new();
        x.ensure_ordering(false).unwrap();
        x.insert(0, Bytes::from_static(b"abc"), 3).unwrap();
        assert_eq!(
            next_unordered(&mut x),
            Chunk::new(0, Bytes::from_static(b"abc"))
        );
        assert_eq!(x.read(usize::MAX, false), None);
        x.insert(3, Bytes::from_static(b"def"), 3).unwrap();
        assert_eq!(
            next_unordered(&mut x),
            Chunk::new(3, Bytes::from_static(b"def"))
        );
        assert_eq!(x.read(usize::MAX, false), None);
    }

    #[test]
    fn unordered_dedup() {
        let mut x = Assembler::new();
        x.ensure_ordering(false).unwrap();
        x.insert(3, Bytes::from_static(b"def"), 3).unwrap();
        assert_eq!(
            next_unordered(&mut x),
            Chunk::new(3, Bytes::from_static(b"def"))
        );
        assert_eq!(x.read(usize::MAX, false), None);
        x.insert(0, Bytes::from_static(b"a"), 1).unwrap();
        x.insert(0, Bytes::from_static(b"abcdefghi"), 9).unwrap();
        x.insert(0, Bytes::from_static(b"abcd"), 4).unwrap();
        assert_eq!(
            next_unordered(&mut x),
            Chunk::new(0, Bytes::from_static(b"a"))
        );
        assert_eq!(
            next_unordered(&mut x),
            Chunk::new(1, Bytes::from_static(b"bc"))
        );
        assert_eq!(
            next_unordered(&mut x),
            Chunk::new(6, Bytes::from_static(b"ghi"))
        );
        assert_eq!(x.read(usize::MAX, false), None);
        x.insert(8, Bytes::from_static(b"ijkl"), 4).unwrap();
        assert_eq!(
            next_unordered(&mut x),
            Chunk::new(9, Bytes::from_static(b"jkl"))
        );
        assert_eq!(x.read(usize::MAX, false), None);
        x.insert(12, Bytes::from_static(b"mno"), 3).unwrap();
        assert_eq!(
            next_unordered(&mut x),
            Chunk::new(12, Bytes::from_static(b"mno"))
        );
        assert_eq!(x.read(usize::MAX, false), None);
        x.insert(2, Bytes::from_static(b"cde"), 3).unwrap();
        assert_eq!(x.read(usize::MAX, false), None);
    }

    #[test]
    fn chunks_dedup() {
        let mut x = Assembler::new();
        x.insert(3, Bytes::from_static(b"def"), 3).unwrap();
        assert_eq!(x.read(usize::MAX, true), None);
        x.insert(0, Bytes::from_static(b"a"), 1).unwrap();
        x.insert(1, Bytes::from_static(b"bcdefghi"), 9).unwrap();
        x.insert(0, Bytes::from_static(b"abcd"), 4).unwrap();
        assert_eq!(
            x.read(usize::MAX, true),
            Some(Chunk::new(0, Bytes::from_static(b"abcd")))
        );
        assert_eq!(
            x.read(usize::MAX, true),
            Some(Chunk::new(4, Bytes::from_static(b"efghi")))
        );
        assert_eq!(x.read(usize::MAX, true), None);
        x.insert(8, Bytes::from_static(b"ijkl"), 4).unwrap();
        assert_eq!(
            x.read(usize::MAX, true),
            Some(Chunk::new(9, Bytes::from_static(b"jkl")))
        );
        assert_eq!(x.read(usize::MAX, true), None);
        x.insert(12, Bytes::from_static(b"mno"), 3).unwrap();
        assert_eq!(
            x.read(usize::MAX, true),
            Some(Chunk::new(12, Bytes::from_static(b"mno")))
        );
        assert_eq!(x.read(usize::MAX, true), None);
        x.insert(2, Bytes::from_static(b"cde"), 3).unwrap();
        assert_eq!(x.read(usize::MAX, true), None);
    }

    #[test]
    fn ordered_eager_discard() {
        let mut x = Assembler::new();
        x.insert(0, Bytes::from_static(b"abc"), 3).unwrap();
        assert_eq!(x.data.len(), 1);
        assert_eq!(
            x.read(usize::MAX, true),
            Some(Chunk::new(0, Bytes::from_static(b"abc")))
        );
        x.insert(0, Bytes::from_static(b"ab"), 2).unwrap();
        assert_eq!(x.data.len(), 0);
        x.insert(2, Bytes::from_static(b"cd"), 2).unwrap();
        assert_eq!(
            x.data.peek(),
            Some(&Buffer::new(3, Bytes::from_static(b"d"), 2))
        );
    }

    #[test]
    fn unordered_transition_discards_consumed_overlaps() {
        for consumed in [2, 3, 6] {
            let mut assembler = Assembler::new();
            assembler
                .insert(0, Bytes::from_static(b"abcdef"), 6)
                .unwrap();
            assembler
                .insert(0, Bytes::from_static(b"abcdef"), 6)
                .unwrap();
            assembler.insert(1, Bytes::from_static(b"bcd"), 3).unwrap();
            let ordered = assembler.read(consumed, true).unwrap();
            assert_eq!(&ordered.bytes[..], &b"abcdef"[..consumed]);
            assembler.ensure_ordering(false).unwrap();
            let mut delivered = Vec::new();
            while let Some(chunk) = assembler.read(2, false) {
                assert_eq!(chunk.offset as usize, consumed + delivered.len());
                delivered.extend_from_slice(&chunk.bytes);
            }
            assert_eq!(delivered, &b"abcdef"[consumed..]);
            assert_eq!(assembler.bytes_read, 6);
            assert_eq!(assembler.buffered, 0);
            assert_eq!(assembler.allocated, 0);
            assembler.insert(6, Bytes::from_static(b"g"), 1).unwrap();
            assert_eq!(assembler.read(1, false).unwrap().offset, 6);
            assert_eq!(assembler.bytes_read, 7);
        }
    }

    #[test]
    fn unordered_compaction_preserves_unread_lower_offsets() {
        let mut assembler = Assembler::new();
        assembler.ensure_ordering(false).unwrap();
        assembler
            .insert(100, Bytes::from_static(b"xyz"), 3)
            .unwrap();
        assert_eq!(assembler.read(3, false).unwrap().offset, 100);
        assert_eq!(assembler.bytes_read, 3);
        assembler
            .insert(0, Bytes::from_static(b"ab"), 40_000)
            .unwrap();
        let chunk = assembler.read(2, false).unwrap();
        assert_eq!(chunk.offset, 0);
        assert_eq!(&chunk.bytes[..], b"ab");
        assert_eq!(assembler.bytes_read, 5);
        assert_eq!(assembler.buffered, 0);
        assert_eq!(assembler.allocated, 0);
    }

    #[test]
    fn ordered_insert_unordered_read() {
        let mut x = Assembler::new();
        x.insert(0, Bytes::from_static(b"abc"), 3).unwrap();
        x.insert(0, Bytes::from_static(b"abc"), 3).unwrap();
        x.ensure_ordering(false).unwrap();
        assert_eq!(
            x.read(3, false),
            Some(Chunk::new(0, Bytes::from_static(b"abc")))
        );
        assert_eq!(x.read(3, false), None);
    }

    #[test]
    fn ordered_lossless_stream_is_not_rejected() {
        const FRAME_LEN: usize = 32;

        let mut x = Assembler::new();
        let data = Bytes::from(vec![0; FRAME_LEN]);
        let mut offset = 0u64;
        while offset < (2 * COMPACT_THRESHOLD * FRAME_LEN) as u64 {
            x.insert(offset, data.clone(), FRAME_LEN)
                .expect("contiguous lossless data must not be rejected");
            offset += FRAME_LEN as u64;
        }
    }

    #[test]
    fn defrag_respects_max_chunks_at_rounding_boundary() {
        let mut x = Assembler::new();
        let data = Bytes::from(vec![0; MIN_RETAINED_CHUNK_SIZE]);
        let mut offset = 0;
        // Fill with minimium sized chunks.
        for _ in 0..MAX_CHUNKS {
            x.insert(offset, data.clone(), data.len()).unwrap();
            offset += data.len() as u64;
        }
        // Add 1 extra chunk, defragment must coalesce the previous
        // chunks to stay within MAX_CHUNKS
        x.insert(offset, Bytes::from_static(b"x"), 1).unwrap();
        x.defragment(0);
        assert!(x.data.len() <= MAX_CHUNKS);
    }

    #[test]
    fn bounded_chunks_under_low_over_allocation() {
        // Gapped frames whose `allocation_size` equals their length hold
        // `over_allocation` at zero, so that trigger never fires.
        let mut x = Assembler::new();
        // Withhold offset 0 so an ordered reader can never drain anything.
        let mut offset = 1u64;
        let mut result = Ok(());
        for _ in 0..(MAX_CHUNKS * 8) {
            result = x.insert(offset, Bytes::from_static(b"gap"), 3);
            if result.is_err() {
                break;
            }
            offset += 3 + 1; // 3 data bytes, 1 byte gap
        }
        match result {
            Err(TooManyChunks) => {}
            other => panic!("assertion failed: `{other:?}` does not match `Err(TooManyChunks)`"),
        }
        assert!(
            x.data.len() <= COMPACT_THRESHOLD + 1,
            "chunk count {} exceeded the bound",
            x.data.len()
        );
    }

    #[test]
    fn bounded_chunks_unordered_overlap_flood() {
        // Overlapping frames whose tail is already received: the dedup loop pushes
        // the fresh head byte and leaves `bytes` empty, and `end` never rises, so
        // the flood costs the peer no flow control.
        let mut x = Assembler::new();
        x.ensure_ordering(false).unwrap();
        let top = 1_000_000u64;
        x.insert(top, Bytes::from_static(b"ab"), 2).unwrap();
        for k in 0..(4 * MAX_CHUNKS as u64) {
            x.insert(top - k - 1, Bytes::from_static(b"ab"), 2).unwrap();
            assert!(
                x.data.len() <= COMPACT_THRESHOLD + 1,
                "chunk count {} exceeded the bound at k={k}",
                x.data.len()
            );
        }
    }

    #[test]
    fn bounded_gaps_when_read_unordered() {
        // An unordered reader drains each island as it lands, so only the received set keeps it.
        let mut x = Assembler::new();
        x.ensure_ordering(false).unwrap();
        let mut result = Ok(());
        let mut islands = 0;
        for i in 0..(MAX_CHUNKS as u64 * 8) {
            result = x.insert(1 + i * 2, Bytes::from_static(b"x"), 1);
            if result.is_err() {
                break;
            }
            islands += 1;
            while x.read(usize::MAX, false).is_some() {}
        }
        match result {
            Err(TooManyChunks) => {}
            other => panic!("assertion failed: `{other:?}` does not match `Err(TooManyChunks)`"),
        }
        assert_eq!(islands, MAX_CHUNKS, "gapped spans kept past the bound");
    }

    #[test]
    fn bounded_chunks_duplicate_flood() {
        // Duplicates against a stream already at the cap. Ordered mode does not dedup,
        // so each one pushes a chunk; they must not be rejected, or compact every frame.
        let mut x = Assembler::new();
        // Withhold offset 0 so nothing can be drained.
        for i in 0..MAX_CHUNKS as u64 {
            x.insert(1 + i * 4, Bytes::from_static(b"abc"), 3).unwrap();
        }
        let mut max_len = x.data.len();
        for _ in 0..(3 * MAX_CHUNKS) {
            x.insert(1, Bytes::from_static(b"abc"), 3)
                .expect("duplicate flood must not be rejected");
            max_len = max_len.max(x.data.len());
            assert!(
                x.data.len() <= COMPACT_THRESHOLD + 1,
                "chunk count {} exceeded the bound",
                x.data.len()
            );
        }
        // Compacting on every frame would pin the count at `MAX_CHUNKS`.
        assert!(
            max_len > MAX_CHUNKS,
            "buffer compacted on every frame (max observed len {max_len})"
        );
    }

    /// Five STREAM frames, two of them empty, read unordered. An empty frame must not leave a
    /// zero-width entry in the set of received offsets; one that did made a later frame's
    /// duplicate scan stop early and hand back inconsistent overlaps, which panicked in `insert`.
    #[test]
    fn empty_unordered_frames_leave_the_received_set_consistent() {
        let mut x = Assembler::new();
        x.ensure_ordering(false).unwrap();
        x.insert(3, Bytes::new(), 0).unwrap();
        x.insert(6, Bytes::from_static(b"6789"), 4).unwrap();
        x.insert(5, Bytes::new(), 0).unwrap();
        x.insert(2, Bytes::from_static(b"23456"), 5).unwrap();
        x.insert(0, Bytes::from_static(b"0123"), 4).unwrap();
        let mut seen = vec![None; 10];
        while let Some(chunk) = x.read(usize::MAX, false) {
            for (i, byte) in chunk.bytes.iter().enumerate() {
                let slot = &mut seen[chunk.offset as usize + i];
                assert!(
                    slot.is_none(),
                    "offset {} delivered twice",
                    chunk.offset as usize + i
                );
                *slot = Some(*byte);
            }
        }
        assert_eq!(
            seen.into_iter().collect::<Option<Vec<u8>>>().as_deref(),
            Some(b"0123456789".as_slice()),
            "every byte is delivered exactly once"
        );
    }

    fn next_unordered(x: &mut Assembler) -> Chunk {
        x.read(usize::MAX, false).unwrap()
    }

    fn next(x: &mut Assembler, size: usize) -> Option<Bytes> {
        x.read(size, true).map(|chunk| chunk.bytes)
    }
}
