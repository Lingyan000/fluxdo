//! Bounded fixtures exercising the private stream assembler and retransmission buffer.
#![expect(
    clippy::expect_used,
    reason = "benchmark fixtures require valid protocol operations"
)]

use super::{assembler::Assembler, send_buffer::SendBuffer};
use rama_core::bytes::Bytes;

const PAYLOAD: &[u8; 1200] = &[0x5a; 1200];

/// Receive assembly with preowned payloads; setup allocations are excluded from measurement.
#[derive(Debug)]
pub struct Assembly {
    inner: Assembler,
    input: Vec<(u64, Bytes)>,
    fragmented: bool,
    expected: usize,
    consumed: usize,
}

impl Assembly {
    /// In-order full chunks are read as they arrive. Fragmented chunks arrive in reverse order,
    /// each retaining a distinct 1200-byte allocation for 32 useful bytes, triggering real compaction.
    pub fn new(chunks: usize, fragmented: bool) -> Self {
        assert!((1..=512).contains(&chunks));
        let useful = if fragmented { 32 } else { PAYLOAD.len() };
        let mut input: Vec<_> = (0..chunks)
            .map(|index| {
                let bytes = Bytes::copy_from_slice(PAYLOAD).slice(..useful);
                ((index * useful) as u64, bytes)
            })
            .collect();
        if fragmented {
            input.reverse();
        }
        Self {
            inner: Assembler::new(),
            input,
            fragmented,
            expected: chunks * useful,
            consumed: 0,
        }
    }

    /// Insert and read all input, including compaction and released payload ownership.
    pub fn run(&mut self) -> usize {
        for (offset, bytes) in self.input.drain(..) {
            self.inner
                .insert(offset, bytes, PAYLOAD.len())
                .expect("bounded chunk count");
            if !self.fragmented {
                while let Some(chunk) = self.inner.read(usize::MAX, true) {
                    self.consumed += std::hint::black_box(chunk.bytes.len());
                }
            }
        }
        while let Some(chunk) = self.inner.read(usize::MAX, true) {
            self.consumed += std::hint::black_box(chunk.bytes.len());
        }
        self.consumed
    }

    /// Validate after the measured operation.
    pub fn verify(&mut self) {
        assert_eq!(self.consumed, self.expected);
        assert!(self.input.is_empty());
        assert!(self.inner.read(usize::MAX, true).is_none());
    }
}

/// Stream send-buffer ownership, transmission, retransmission and ACK retirement fixture.
/// This does not measure the connection's packet loss detector or congestion controller.
#[derive(Debug)]
pub struct SendRecovery {
    inner: SendBuffer,
    input: Vec<Bytes>,
    chunks: usize,
    consumed: usize,
}

impl SendRecovery {
    /// Construct owned chunks; `sent` preloads and transmits them for isolated ACK benchmarks.
    pub fn new(chunks: usize, sent: bool) -> Self {
        assert!((1..=512).contains(&chunks));
        let mut result = Self {
            inner: SendBuffer::new(),
            input: (0..chunks)
                .map(|_| Bytes::copy_from_slice(PAYLOAD))
                .collect(),
            chunks,
            consumed: 0,
        };
        if sent {
            result.write_and_transmit();
        }
        result
    }

    fn transmit(&mut self) {
        while self.inner.has_unsent_data() {
            let (range, _) = self.inner.poll_transmit(1216);
            assert!(!range.is_empty(), "transmission must advance");
            let mut offset = range.start;
            while offset < range.end {
                let bytes = self.inner.get(offset..range.end);
                assert!(!bytes.is_empty(), "every transmitted offset is owned");
                self.consumed += std::hint::black_box(bytes.len());
                offset += bytes.len() as u64;
            }
        }
    }

    fn write_and_transmit(&mut self) {
        for bytes in self.input.drain(..) {
            self.inner.write(bytes);
        }
        self.transmit();
    }

    /// Write, transmit, mark alternating chunks lost, retransmit, then retire all owned bytes.
    pub fn recover(&mut self) -> usize {
        self.write_and_transmit();
        for index in (0..self.chunks).step_by(2) {
            let start = (index * PAYLOAD.len()) as u64;
            self.inner.retransmit(start..start + PAYLOAD.len() as u64);
        }
        self.transmit();
        self.inner.ack(0..self.inner.offset());
        self.consumed
    }

    /// Retire individually acknowledged chunks; reverse order accumulates ACK ranges until the
    /// first chunk arrives and releases the prefix, including shrinking segment storage.
    pub fn acknowledge(&mut self, reverse: bool) {
        for step in 0..self.chunks {
            let index = if reverse {
                self.chunks - step - 1
            } else {
                step
            };
            let start = (index * PAYLOAD.len()) as u64;
            self.inner.ack(start..start + PAYLOAD.len() as u64);
        }
    }

    /// Check all bytes were emitted and their owned storage was retired, outside timing.
    pub fn verify(&self, recovered: bool) {
        let emitted = self.chunks
            + if recovered {
                self.chunks.div_ceil(2)
            } else {
                0
            };
        assert_eq!(self.consumed, emitted * PAYLOAD.len());
        assert!(self.input.is_empty());
        assert!(self.inner.is_fully_acked());
        assert_eq!(self.inner.buffered(), 0);
        assert!(!self.inner.has_unsent_data());
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn assembly_and_recovery_fixtures_process_owned_data() {
        for chunks in [16, 128, 512] {
            for fragmented in [false, true] {
                let mut fixture = Assembly::new(chunks, fragmented);
                fixture.run();
                fixture.verify();
            }
            let mut fixture = SendRecovery::new(chunks, false);
            fixture.recover();
            fixture.verify(true);
            for reverse in [false, true] {
                let mut fixture = SendRecovery::new(chunks, true);
                fixture.acknowledge(reverse);
                fixture.verify(false);
            }
        }
    }
}
