//! A pending attempt's ClientHello, reassembled from the Initial packets of its first flight
//! before the attempt is accepted.

use std::{
    sync::atomic::{AtomicBool, AtomicU64, Ordering},
    task::Waker,
};

use parking_lot::Mutex;
use rama_core::bytes::Bytes;
use rama_quic_proto::capture::{CaptureLimits, ClientHelloAssembly};
use rama_tls::client::{ClientHelloHandshakePrefix, parse_client_hello_message_prefix};
use rama_utils::octets;

use crate::proto::crypto::ClientHelloMessage;

/// A ClientHello larger than this is not looked at.
pub(crate) const LIMIT: usize = octets::kib(16);

/// CRYPTO fragments held beyond a gap; their bytes stay within [`LIMIT`] as well.
const AHEAD_LIMIT: usize = 128;

/// How much of a client's ClientHello its first flight has delivered so far.
pub(crate) enum ClientHelloPeek {
    /// The whole ClientHello.
    Complete(ClientHelloMessage),
    /// The start of a ClientHello whose remainder has not arrived.
    Incomplete,
    /// Bytes that cannot become a ClientHello within the assembly's configured limit, or that
    /// contradict each other.
    Invalid,
}

/// The start of a pending attempt's CRYPTO stream, taken in packet by packet.
///
/// Every packet is opened once, whatever the number of looks.
#[derive(Debug)]
pub(crate) struct HelloAssembly {
    /// The first packet, and what was coalesced behind it, are taken in.
    pub(crate) started: bool,
    /// Buffered datagrams already taken in.
    pub(crate) taken: usize,
    assembly: ClientHelloAssembly,
    invalid: bool,
}

impl Default for HelloAssembly {
    fn default() -> Self {
        Self::with_limits(&CaptureLimits {
            client_hello_bytes: LIMIT,
            crypto_fragments: AHEAD_LIMIT,
            ..CaptureLimits::default()
        })
    }
}

impl HelloAssembly {
    pub(crate) fn with_limits(limits: &CaptureLimits) -> Self {
        Self {
            started: false,
            taken: 0,
            assembly: ClientHelloAssembly::new(limits),
            invalid: false,
        }
    }

    /// Take in CRYPTO data at `offset`.
    pub(crate) fn take_in(&mut self, offset: u64, data: &[u8]) {
        if !self.invalid && self.assembly.take_in(offset, data).is_err() {
            self.invalid = true;
        }
    }

    /// What the stream holds of the ClientHello so far.
    pub(crate) fn peek(&self) -> ClientHelloPeek {
        if self.invalid {
            return ClientHelloPeek::Invalid;
        }
        // The assembly already rejects anything but a ClientHello header; the message itself
        // is parsed once, when complete.
        let Some(message) = self.assembly.client_hello() else {
            return ClientHelloPeek::Incomplete;
        };
        match parse_client_hello_message_prefix(message) {
            ClientHelloHandshakePrefix::Complete(hello) => ClientHelloPeek::Complete(
                ClientHelloMessage::new(Bytes::copy_from_slice(message), hello),
            ),
            ClientHelloHandshakePrefix::Incomplete | ClientHelloHandshakePrefix::Invalid => {
                ClientHelloPeek::Invalid
            }
        }
    }
}

/// What a pending attempt shares with the application holding it: whether it is still
/// pending, and a wake-up when more of its first flight arrived or it will not progress any
/// further.
#[derive(Debug)]
pub(crate) struct IncomingProgress {
    live: AtomicBool,
    generation: AtomicU64,
    waker: Mutex<Option<Waker>>,
}

impl IncomingProgress {
    pub(crate) fn new() -> Self {
        Self {
            live: AtomicBool::new(true),
            generation: AtomicU64::new(0),
            waker: Mutex::new(None),
        }
    }

    /// Whether the attempt is still pending: neither expired nor taken by the endpoint.
    pub(crate) fn is_live(&self) -> bool {
        self.live.load(Ordering::Acquire)
    }

    /// End the attempt; whether it was still pending.
    pub(crate) fn retire(&self) -> bool {
        self.live.swap(false, Ordering::AcqRel)
    }

    /// Changes whenever the attempt progresses.
    pub(crate) fn generation(&self) -> u64 {
        self.generation.load(Ordering::Acquire)
    }

    /// Record progress and wake the application waiting for it.
    pub(crate) fn advance(&self) {
        self.generation.fetch_add(1, Ordering::AcqRel);
        if let Some(waker) = self.waker.lock().take() {
            waker.wake();
        }
    }

    /// Wake `waker` on the next progress.
    pub(crate) fn register(&self, waker: &Waker) {
        let mut slot = self.waker.lock();
        match slot.as_mut() {
            Some(held) if held.will_wake(waker) => {}
            _ => *slot = Some(waker.clone()),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A ClientHello handshake message with `extensions` bytes of opaque extension payload.
    fn client_hello(extensions: usize) -> Vec<u8> {
        let mut body = vec![0x03, 0x03];
        body.extend_from_slice(&[0x11; 32]); // random
        body.push(0); // legacy session id
        body.extend_from_slice(&[0x00, 0x02, 0x13, 0x01]); // TLS_AES_128_GCM_SHA256
        body.extend_from_slice(&[0x01, 0x00]); // null compression
        let ext_len = 4 + extensions;
        body.extend_from_slice(&(ext_len as u16).to_be_bytes());
        body.extend_from_slice(&[0xfe, 0x00]); // a private extension id
        body.extend_from_slice(&(extensions as u16).to_be_bytes());
        body.extend(std::iter::repeat_n(0x5a, extensions));
        let mut message = vec![0x01];
        message.extend_from_slice(&(body.len() as u32).to_be_bytes()[1..]);
        message.extend_from_slice(&body);
        message
    }

    fn complete(assembly: &HelloAssembly) -> Vec<u8> {
        match assembly.peek() {
            ClientHelloPeek::Complete(message) => message.message().to_vec(),
            ClientHelloPeek::Incomplete => panic!("incomplete"),
            ClientHelloPeek::Invalid => panic!("invalid"),
        }
    }

    fn chunks(message: &[u8], size: usize) -> Vec<(u64, Bytes)> {
        message
            .chunks(size)
            .enumerate()
            .map(|(n, chunk)| ((n * size) as u64, Bytes::copy_from_slice(chunk)))
            .collect()
    }

    #[test]
    fn a_message_in_order_completes() {
        let message = client_hello(2000);
        let mut assembly = HelloAssembly::default();
        let parts = chunks(&message, 1100);
        for (offset, data) in &parts[..parts.len() - 1] {
            assembly.take_in(*offset, data);
            assert!(matches!(assembly.peek(), ClientHelloPeek::Incomplete));
        }
        let (offset, data) = parts.last().unwrap().clone();
        assembly.take_in(offset, &data);
        assert_eq!(complete(&assembly), message);
    }

    #[test]
    fn reordered_duplicated_and_overlapping_data_completes() {
        let message = client_hello(3000);
        let mut assembly = HelloAssembly::default();
        let mut parts = chunks(&message, 700);
        parts.reverse();
        // A retransmission covering already received data, and one overlapping two chunks.
        parts.push((0, Bytes::copy_from_slice(&message[..300])));
        parts.push((650, Bytes::copy_from_slice(&message[650..1500])));
        for (offset, data) in parts.iter().chain(parts.iter()) {
            assembly.take_in(*offset, data);
        }
        assert_eq!(complete(&assembly), message);
    }

    #[test]
    fn a_gap_keeps_it_incomplete() {
        let message = client_hello(2000);
        let mut assembly = HelloAssembly::default();
        assembly.take_in(0, &message[..1000]);
        assembly.take_in(1500, &message[1500..]);
        assert!(matches!(assembly.peek(), ClientHelloPeek::Incomplete));
        assembly.take_in(1000, &message[1000..1500]);
        assert_eq!(complete(&assembly), message);
    }

    #[test]
    fn trailing_data_is_not_part_of_the_message() {
        let message = client_hello(10);
        let mut stream = message.clone();
        stream.extend_from_slice(&[0xaa; 64]);
        let mut assembly = HelloAssembly::default();
        assembly.take_in(0, &stream);
        assert_eq!(complete(&assembly), message);
    }

    #[test]
    fn a_declared_length_past_the_limit_is_invalid_at_once() {
        let mut assembly = HelloAssembly::default();
        let declared = (LIMIT as u32).to_be_bytes();
        assembly.take_in(0, &[0x01, declared[1], declared[2], declared[3]]);
        assert!(matches!(assembly.peek(), ClientHelloPeek::Invalid));
    }

    #[test]
    fn a_message_up_to_the_limit_completes() {
        let message = client_hello(LIMIT - client_hello(0).len());
        assert_eq!(message.len(), LIMIT);
        let mut assembly = HelloAssembly::default();
        for (offset, data) in chunks(&message, 1100) {
            assembly.take_in(offset, &data);
        }
        assert_eq!(complete(&assembly), message);
    }

    #[test]
    fn data_past_the_limit_is_ignored() {
        let mut assembly = HelloAssembly::default();
        assembly.take_in(LIMIT as u64, &[0; 100]);
        assembly.take_in(u64::MAX, &[0; 100]);
        assert!(matches!(assembly.peek(), ClientHelloPeek::Incomplete));
    }

    #[test]
    fn data_ahead_of_a_gap_is_bounded_in_fragments() {
        let mut fragments = HelloAssembly::default();
        for offset in 1..=(AHEAD_LIMIT as u64) {
            fragments.take_in(offset * 10, &[0; 5]);
        }
        assert!(matches!(fragments.peek(), ClientHelloPeek::Incomplete));
        fragments.take_in((AHEAD_LIMIT as u64 + 1) * 10, &[0; 5]);
        assert!(matches!(fragments.peek(), ClientHelloPeek::Invalid));
    }

    #[test]
    fn a_contradicting_retransmission_is_invalid() {
        let message = client_hello(100);
        let mut changed = message.clone();
        // A byte of the random: the changed message is itself well formed.
        changed[20] ^= 1;
        let mut assembly = HelloAssembly::default();
        assembly.take_in(0, &message);
        assembly.take_in(10, &changed[10..30]);
        assert!(matches!(assembly.peek(), ClientHelloPeek::Invalid));
    }

    #[test]
    fn a_message_of_another_type_is_invalid() {
        let mut message = client_hello(10);
        message[0] = 0x02; // ServerHello
        let mut assembly = HelloAssembly::default();
        assembly.take_in(0, &message);
        assert!(matches!(assembly.peek(), ClientHelloPeek::Invalid));
    }

    #[test]
    fn progress_wakes_the_registered_waker() {
        use std::{
            sync::{
                Arc,
                atomic::{AtomicUsize, Ordering},
            },
            task::Wake,
        };

        struct Count(AtomicUsize);
        impl Wake for Count {
            fn wake(self: Arc<Self>) {
                self.0.fetch_add(1, Ordering::SeqCst);
            }
        }
        let count = Arc::new(Count(AtomicUsize::new(0)));
        let waker = Waker::from(count.clone());
        let progress = IncomingProgress::new();
        let before = progress.generation();
        progress.advance();
        assert_eq!(count.0.load(Ordering::SeqCst), 0, "nothing registered yet");
        progress.register(&waker);
        progress.advance();
        assert_eq!(count.0.load(Ordering::SeqCst), 1);
        assert_eq!(progress.generation(), before + 2);
    }
}
