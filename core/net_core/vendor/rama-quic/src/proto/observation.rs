//! Bounded first-flight recording from authenticated packets.

use rama_core::{bytes::BytesMut, extensions::Extensions};
use rama_quic_proto::{
    ConnectionId,
    capture::{
        self, CaptureCompleteness, CaptureError, CaptureLimits, FirstFlight, ObservedFrame,
        PacketKind, QuicObservation,
    },
    frame::{self, Frame},
    packet::{Header, Packet},
    profile::PaddingPlacement,
};
use rama_tls::{SecureTransport, client::ClientHello};

use super::{
    Connection,
    first_flight::{ClientHelloPeek, HelloAssembly},
};

#[derive(Debug)]
struct Datagram {
    size: usize,
    trailing: usize,
    coalesced: bool,
}

/// Allocated only for servers explicitly configured to retain observations.
#[derive(Debug)]
pub(crate) struct ServerObservation {
    limits: CaptureLimits,
    hello: HelloAssembly,
    value: QuicObservation,
    pending: Option<Datagram>,
    bytes: usize,
    datagrams: usize,
    frames: usize,
    fragments: usize,
    done: bool,
    defer_completion: bool,
    parsed: Option<ClientHello>,
}

impl ServerObservation {
    pub(crate) fn new(limits: CaptureLimits, first: &[u8], rest: Option<&[u8]>) -> Self {
        Self::new_parts(limits, &[first, rest.unwrap_or_default()])
    }

    pub(crate) fn new_parts(limits: CaptureLimits, parts: &[&[u8]]) -> Self {
        let mut this = Self {
            limits,
            hello: HelloAssembly::with_limits(&limits),
            value: QuicObservation {
                connection_id: Vec::new(),
                attempt_id: Vec::new(),
                retry_parent: None,
                first_flight: None,
                transport_parameters: Vec::new(),
                client_hello_message: Vec::new(),
                completeness: CaptureCompleteness {
                    datagrams: true,
                    frames: true,
                    original_attempt: true,
                    ..CaptureCompleteness::default()
                },
            },
            pending: None,
            bytes: 0,
            datagrams: 0,
            frames: 0,
            fragments: 0,
            done: false,
            defer_completion: true,
            parsed: None,
        };
        this.begin_parts(parts);
        this
    }

    pub(crate) fn identify(
        &mut self,
        local: ConnectionId,
        attempt: ConnectionId,
        original: ConnectionId,
        retried: bool,
    ) {
        self.value.connection_id = local.to_vec();
        self.value.attempt_id = attempt.to_vec();
        if retried {
            self.value.retry_parent = Some(original.to_vec());
            self.value.completeness.original_attempt = false;
        }
    }

    pub(crate) fn begin_datagram(&mut self, first: &[u8], rest: Option<&[u8]>) {
        self.begin_parts(&[first, rest.unwrap_or_default()]);
    }

    fn begin_parts(&mut self, parts: &[&[u8]]) {
        self.pending = None;
        if self.done {
            return;
        }
        let size = parts
            .iter()
            .fold(0usize, |size, part| size.saturating_add(part.len()));
        if self.datagrams >= self.limits.datagrams
            || size > self.limits.bytes.saturating_sub(self.bytes)
        {
            self.value.completeness.datagrams = false;
            self.done = true;
            return;
        }
        self.datagrams += 1;
        self.bytes += size;
        // Check the remaining byte budget before joining the split decoder buffers.
        let mut wire = Vec::with_capacity(size);
        for part in parts {
            wire.extend_from_slice(part);
        }
        match capture::observe_with_limits(&wire, &self.limits) {
            Ok(observed) => {
                self.pending = Some(Datagram {
                    size,
                    trailing: observed.trailing,
                    coalesced: observed
                        .packets
                        .iter()
                        .any(|p| p.kind != PacketKind::Initial),
                })
            }
            Err(error) => {
                self.value.completeness.datagrams = false;
                if matches!(error, CaptureError::LimitExceeded("packets")) {
                    self.value.completeness.frames = false;
                }
                self.done = true;
            }
        }
    }

    pub(crate) fn packet(&mut self, packet: &Packet, number: u64) {
        if self.done {
            return;
        }
        let Header::Initial(header) = &packet.header else {
            return;
        };
        let flight = self.value.first_flight.get_or_insert_with(|| FirstFlight {
            datagram_sizes: Vec::new(),
            trailing_bytes: Vec::new(),
            version: header.version.version(),
            dcid_len: header.dst_cid.len(),
            scid_len: header.src_cid.len(),
            token_len: header.token.len(),
            first_packet_number: number,
            packet_number_len: header.number.len() as u8,
            packet_number_lengths: Vec::new(),
            frames: Vec::new(),
            padding: PaddingPlacement::Frames,
            coalesced: false,
            parameters: Vec::new(),
            chosen_version: None,
            available_versions: Vec::new(),
            packet_numbers: Vec::new(),
            complete: false,
        });
        if let Some(datagram) = self.pending.take() {
            flight.datagram_sizes.push(datagram.size);
            flight.trailing_bytes.push(datagram.trailing);
            flight.coalesced |= datagram.coalesced;
            if datagram.trailing > 0 {
                flight.padding = PaddingPlacement::DatagramTail;
            }
        }
        if flight.packet_numbers.len() >= self.limits.packets {
            self.value.completeness.frames = false;
            self.done = true;
            return;
        }
        let duplicate = flight.packet_numbers.contains(&number);
        flight.packet_numbers.push(number);
        flight.packet_number_lengths.push(header.number.len() as u8);
        if duplicate {
            return;
        }
        let mut observed = Vec::new();
        let Ok(iter) = frame::Iter::new(BytesMut::from(&packet.payload[..]).freeze()) else {
            self.value.completeness.frames = false;
            self.done = true;
            return;
        };
        for item in iter {
            let Ok(item) = item else {
                self.value.completeness.frames = false;
                self.done = true;
                break;
            };
            if matches!(item, Frame::Padding)
                && let Some(ObservedFrame::Padding { len }) = observed.last_mut()
            {
                *len += 1;
                continue;
            }
            if self.frames >= self.limits.frames {
                self.value.completeness.frames = false;
                self.done = true;
                break;
            }
            self.frames += 1;
            observed.push(match item {
                Frame::Padding => ObservedFrame::Padding { len: 1 },
                Frame::Ping => ObservedFrame::Ping,
                Frame::Ack(_) => ObservedFrame::Ack,
                Frame::Crypto(crypto) => {
                    if self.fragments >= self.limits.crypto_fragments {
                        self.value.completeness.frames = false;
                        self.done = true;
                        break;
                    }
                    self.fragments += 1;
                    let end = crypto.offset.checked_add(crypto.data.len() as u64);
                    if end.is_none_or(|end| end > self.limits.client_hello_bytes as u64) {
                        self.done = true;
                    } else {
                        self.hello.take_in(crypto.offset, &crypto.data);
                    }
                    ObservedFrame::Crypto {
                        offset: crypto.offset,
                        len: crypto.data.len(),
                    }
                }
                other => ObservedFrame::Other {
                    ty: other.ty().as_u64(),
                },
            });
        }
        flight.frames.push(observed);
    }

    pub(crate) fn end_datagram(&mut self) {
        if self.pending.take().is_some() {
            self.value.completeness.datagrams = false;
        }
        if self.defer_completion || self.value.completeness.client_hello {
            return;
        }
        let peek = self.hello.peek();
        if matches!(peek, ClientHelloPeek::Invalid) {
            self.done = true;
        }
        if let ClientHelloPeek::Complete(message) = peek {
            if message.message().len() <= self.limits.client_hello_bytes {
                self.value.client_hello_message = message.message().to_vec();
                self.value.completeness.client_hello = true;
                if let Ok(parameters) =
                    capture::transport_parameters_from_hello(message.client_hello(), &self.limits)
                {
                    if let Some(flight) = self.value.first_flight.as_mut() {
                        flight.complete = true;
                        flight.parameters = parameters.iter().map(|p| p.id).collect();
                        if let Some(info) = capture::version_information(&parameters) {
                            flight.chosen_version = Some(info.chosen());
                            flight.available_versions = info.available().to_vec();
                        }
                    }
                    self.value.transport_parameters = parameters;
                    self.value.completeness.transport_parameters = true;
                }
                self.parsed = Some(message.into_client_hello());
            }
            self.done = true;
        }
        if self.done {
            self.hello = HelloAssembly::default();
        }
    }

    pub(crate) fn finish_buffered(&mut self) {
        self.defer_completion = false;
        self.end_datagram();
    }

    pub(crate) fn finish(&mut self) {
        self.finish_buffered();
        self.done = true;
        self.pending = None;
        self.hello = HelloAssembly::default();
    }

    pub(crate) fn datagrams_complete(&self) -> bool {
        self.value.completeness.datagrams
    }

    pub(crate) fn lost_datagram(&mut self) {
        self.value.completeness.datagrams = false;
    }
}

impl Connection {
    pub(crate) fn publish_observation(
        &mut self,
        extensions: &Extensions,
        initial: bool,
        closed: bool,
    ) {
        let Some(mut observation) = self.observation.take() else {
            return;
        };
        if closed {
            observation.finish();
        }
        if let Some(hello) = observation.parsed.take() {
            extensions.insert(SecureTransport::with_client_hello(hello));
        }
        if observation.done {
            extensions.insert(observation.value);
        } else {
            if initial {
                extensions.insert(observation.value.clone());
            }
            self.observation = Some(observation);
        }
    }
}

#[cfg(fuzzing)]
pub(crate) mod fuzzing {
    use super::*;
    use rama_core::bytes::Bytes;
    use rama_quic_proto::{
        Version,
        packet::{InitialHeader, PacketNumber},
    };

    /// Exercise incremental authenticated-frame observation independently of TLS admission.
    pub fn observe_sequence(data: &[u8], limits: CaptureLimits) {
        let mut recorder = ServerObservation::new(limits, &[0x40], None);
        recorder.finish_buffered();
        let Some(version) = Version::V1.to_wire() else {
            return;
        };
        for (number, payload) in data.chunks(128).take(64).enumerate() {
            recorder.begin_datagram(&[0x40], None);
            recorder.packet(
                &Packet {
                    header: Header::Initial(InitialHeader {
                        dst_cid: ConnectionId::new(&[]),
                        src_cid: ConnectionId::new(&[]),
                        token: Bytes::new(),
                        number: PacketNumber::U8(number as u8),
                        version,
                    }),
                    header_data: Bytes::new(),
                    payload: BytesMut::from(payload),
                    allocated: payload.len(),
                },
                number as u64,
            );
            recorder.end_datagram();
        }
        recorder.finish();
        assert!(recorder.done);
        assert!(recorder.value.client_hello_message.len() <= limits.client_hello_bytes);
        assert!(recorder.value.transport_parameters.len() <= limits.parameters);
        if let Some(flight) = recorder.value.first_flight {
            assert!(flight.packet_numbers.len() <= limits.packets);
            assert!(flight.frames.iter().map(Vec::len).sum::<usize>() <= limits.frames);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use rama_core::bytes::Bytes;
    use rama_quic_proto::{
        Version,
        packet::{InitialHeader, PacketNumber},
    };
    use rama_utils::octets;

    #[test]
    fn observation_assembly_honors_large_hello_limit_without_provider_admission() {
        let mut body = vec![3, 3];
        body.extend_from_slice(&[0; 32]);
        body.extend_from_slice(&[0, 0, 2, 0x13, 1, 1, 0]);
        let padding = 18_000u16;
        body.extend_from_slice(&(padding + 8).to_be_bytes());
        body.extend_from_slice(&[0, 21]);
        body.extend_from_slice(&padding.to_be_bytes());
        body.resize(body.len() + usize::from(padding), 0);
        body.extend_from_slice(&[0, 0x39, 0, 0]);
        let mut message = vec![1];
        message.extend_from_slice(&(body.len() as u32).to_be_bytes()[1..]);
        message.extend_from_slice(&body);
        let expected = message.len();
        let mut recorder = ServerObservation::new(
            CaptureLimits {
                client_hello_bytes: octets::kib(32),
                ..CaptureLimits::default()
            },
            &[0x40],
            None,
        );
        recorder.hello.take_in(0, &message);
        recorder.finish_buffered();
        assert!(recorder.done);
        assert!(recorder.value.completeness.client_hello);
        assert!(recorder.value.completeness.transport_parameters);
        assert_eq!(recorder.value.client_hello_message.len(), expected);
        assert!(recorder.parsed.is_some());
    }

    #[test]
    fn observation_invalid_hello_is_terminal_and_releases_assembly() {
        let mut recorder = ServerObservation::new(CaptureLimits::default(), &[0x40], None);
        recorder.hello.take_in(0, &[2, 0, 0, 0]);
        recorder.finish_buffered();
        assert!(recorder.done);
        assert!(matches!(recorder.hello.peek(), ClientHelloPeek::Incomplete));
        let inspected = recorder.bytes;
        for _ in 0..100 {
            recorder.begin_datagram(&[0x40; 64], None);
            recorder.end_datagram();
        }
        assert_eq!(recorder.bytes, inspected);
    }

    #[test]
    fn observation_non_initial_datagrams_exhaust_the_work_budget() {
        let mut recorder = ServerObservation::new(
            CaptureLimits {
                datagrams: 2,
                ..CaptureLimits::default()
            },
            &[0x40],
            None,
        );
        recorder.finish_buffered();
        recorder.begin_datagram(&[0x40], None);
        recorder.end_datagram();
        recorder.begin_datagram(&[0x40], None);
        recorder.end_datagram();
        assert!(recorder.done);
        assert!(!recorder.value.completeness.datagrams);
        assert_eq!(recorder.datagrams, 2);
        assert_eq!(recorder.bytes, 2);
    }

    #[test]
    fn incremental_capture_retains_packet_number_widths_including_duplicates() {
        let wire: Vec<u8> = rama_utils::hex::decode(
            include_str!("../profile/fixtures/chrome-155-initial-1.hex")
                .split_whitespace()
                .collect::<String>(),
        )
        .unwrap();
        let mut recorder = ServerObservation::new(CaptureLimits::default(), &wire, None);
        for (index, (number, encoded)) in [
            (7, PacketNumber::U8(7)),
            (8, PacketNumber::U16(8)),
            (7, PacketNumber::U24(7)),
        ]
        .into_iter()
        .enumerate()
        {
            if index != 0 {
                recorder.begin_datagram(&wire, None);
            }
            recorder.packet(
                &Packet {
                    header: Header::Initial(InitialHeader {
                        dst_cid: ConnectionId::new(&[]),
                        src_cid: ConnectionId::new(&[]),
                        token: Bytes::new(),
                        number: encoded,
                        version: Version::V1.to_wire().unwrap(),
                    }),
                    header_data: Bytes::new(),
                    payload: BytesMut::from(&[1][..]),
                    allocated: 1,
                },
                number,
            );
            recorder.end_datagram();
        }
        let flight = recorder.value.first_flight.unwrap();
        assert_eq!(flight.packet_numbers, [7, 8, 7]);
        assert_eq!(flight.packet_number_lengths, [1, 2, 3]);
        assert_eq!(flight.frames.len(), 2, "frame contents remain deduplicated");
    }
}
