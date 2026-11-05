use std::{
    collections::VecDeque,
    sync::Arc,
    task::{Context, Poll, Waker},
};

use parking_lot::Mutex;
use rama_core::{
    conversion::RamaFrom as _,
    error::{ArcError, BoxError},
    telemetry::tracing::debug,
};
use rama_crypto::{
    dep::boring::{
        error::ErrorStack,
        memcmp,
        ssl::{
            NameType, Ssl, SslCipherRef,
            quic::{EncryptionLevel, HandshakeStatus, QuicConnection, QuicError, QuicMethod},
        },
    },
    pki_types::CertificateDer,
};
use rama_net::{address::Domain, tls::ApplicationProtocol};
use rama_quic_proto::{
    ConnectionId, Side, TransportError, TransportErrorCode, Version,
    crypto::{HeaderKey, PacketKey},
    packet::SpaceId,
    transport_parameters::TransportParameters,
    version::Wire,
};
use rama_tls::client::NegotiatedTlsAlgorithms;
use rama_tls_boring::{client::ServerAnswerRecorder, type_conversion::peer_certificate_chain};
use zeroize::Zeroizing;

use super::{
    config::{HandshakeInitializer, handshake_completed_hook},
    packet::{self, Secret, Suite},
};

use crate::proto::crypto::{
    self, DirectionalKeys, HandshakeEvent, KeyPair, Keys, UnsupportedVersion,
};

#[cfg(test)]
thread_local! {
    /// Tests: how often this thread parsed a peer's transport parameters.
    pub(super) static PEER_PARAMETER_PARSES: std::cell::Cell<usize> = const { std::cell::Cell::new(0) };
}

enum Event {
    Secret {
        write: bool,
        level: EncryptionLevel,
        suite: u16,
        bytes: Zeroizing<Vec<u8>>,
    },
    Data(EncryptionLevel, Vec<u8>),
}

#[derive(Default)]
struct Output {
    events: VecDeque<Event>,
    alert: Option<u8>,
}

struct Callbacks(Arc<Mutex<Output>>);

impl QuicMethod for Callbacks {
    fn set_read_secret(
        &self,
        level: EncryptionLevel,
        cipher: &SslCipherRef,
        secret: &[u8],
    ) -> Result<(), ErrorStack> {
        self.0.lock().events.push_back(Event::Secret {
            write: false,
            level,
            suite: cipher.protocol_id(),
            bytes: Zeroizing::new(secret.to_vec()),
        });
        Ok(())
    }
    fn set_write_secret(
        &self,
        level: EncryptionLevel,
        cipher: &SslCipherRef,
        secret: &[u8],
    ) -> Result<(), ErrorStack> {
        self.0.lock().events.push_back(Event::Secret {
            write: true,
            level,
            suite: cipher.protocol_id(),
            bytes: Zeroizing::new(secret.to_vec()),
        });
        Ok(())
    }
    fn add_handshake_data(&self, level: EncryptionLevel, bytes: &[u8]) -> Result<(), ErrorStack> {
        self.0
            .lock()
            .events
            .push_back(Event::Data(level, bytes.to_vec()));
        Ok(())
    }
    fn flush_flight(&self) -> Result<(), ErrorStack> {
        Ok(())
    }
    fn send_alert(&self, _: EncryptionLevel, alert: u8) -> Result<(), ErrorStack> {
        self.0.lock().alert = Some(alert);
        Ok(())
    }
}

pub(super) struct TlsSession {
    inner: QuicConnection,
    side: Side,
    /// The version whose labels protect this connection; compatible negotiation may move it
    /// once, before any Handshake key exists.
    wire: &'static Wire,
    /// The version 0-RTT keys are labelled with: the client's first flight version, which
    /// never changes (RFC 9369 §4.1).
    early_wire: &'static Wire,
    /// Where a client reports its negotiated version, so its ticket cache files a ticket
    /// under the version that issued it.
    negotiated: Option<Arc<Mutex<Version>>>,
    callbacks: Arc<Mutex<Output>>,
    output: VecDeque<HandshakeEvent>,
    write_ready: [bool; 3],
    pending_read: [Option<DirectionalKeys>; 3],
    local_secret: Option<Secret>,
    remote_secret: Option<Secret>,
    early_keys: Option<(Arc<dyn HeaderKey>, Arc<dyn PacketKey>)>,
    early_rejected: bool,
    got_handshake_data: bool,
    /// An asynchronous callback is waiting, so the driver must keep polling this session.
    pending_callback: bool,
    /// The driver's latest waker, under which a step without a task context resumes work.
    waker: Option<Waker>,
    server_name: Option<Domain>,
    certificates: Option<Vec<CertificateDer<'static>>>,
    /// Put the peer's certificate chain in the handshake summary.
    pub(super) store_peer_chain: bool,
    /// Whether the handshake-completed hook already ran.
    completed: bool,
    remembered: Option<TransportParameters>,
    peer_params: Arc<Mutex<Option<TransportParameters>>>,
}

pub(super) fn crypto_error(error: BoxError) -> TransportError {
    TransportError::INTERNAL_ERROR("Boring QUIC cryptographic operation failed")
        .with_cause(ArcError::from_box_error(error))
}

impl TlsSession {
    pub(super) fn new(
        mut ssl: Ssl,
        side: Side,
        wire: &'static Wire,
        early_wire: &'static Wire,
        params: &TransportParameters,
        early_data: bool,
        initializer: Option<&HandshakeInitializer>,
        remembered: Option<TransportParameters>,
        peer_params: Arc<Mutex<Option<TransportParameters>>>,
    ) -> Result<Self, TransportError> {
        if let Some(initializer) = initializer {
            (initializer.0)(&mut ssl).map_err(crypto_error)?;
        }
        let callbacks = Arc::new(Mutex::new(Output::default()));
        let mut inner = QuicConnection::new(ssl, Arc::new(Callbacks(callbacks.clone())))
            .map_err(|error| crypto_error(error.into()))?;
        if side.is_client() {
            inner.set_connect_state();
        } else {
            inner.set_accept_state();
        }
        let mut encoded = Vec::new();
        params.write(&mut encoded);
        inner
            .set_transport_parameters(&encoded)
            .map_err(|error| crypto_error(error.into()))?;
        if !side.is_client() {
            // Bind early data to stable transport settings, excluding connection-specific values.
            let stable = TransportParameters {
                initial_src_cid: None,
                original_dst_cid: None,
                retry_src_cid: None,
                stateless_reset_token: None,
                preferred_address: None,
                grease_transport_parameter: None,
                extra: Vec::new(),
                write_plan: None,
                // Version negotiation is settled per connection, not a transport setting.
                version_information: None,
                ..params.clone()
            };
            encoded.clear();
            encoded.extend_from_slice(b"rama-quic-v1");
            stable.write(&mut encoded);
            inner
                .set_early_data_context(&encoded)
                .map_err(|error| crypto_error(error.into()))?;
        }
        inner.set_early_data_enabled(early_data);
        let mut session = Self {
            inner,
            side,
            wire,
            early_wire,
            negotiated: None,
            callbacks,
            output: VecDeque::new(),
            write_ready: [false; 3],
            pending_read: [None, None, None],
            local_secret: None,
            remote_secret: None,
            early_keys: None,
            early_rejected: false,
            got_handshake_data: false,
            pending_callback: false,
            waker: None,
            server_name: None,
            certificates: None,
            store_peer_chain: false,
            completed: false,
            remembered,
            peer_params,
        };
        session.drive(None)?;
        Ok(session)
    }

    pub(super) fn track_version(&mut self, negotiated: Arc<Mutex<Version>>) {
        self.negotiated = Some(negotiated);
    }

    fn tls_error(&self, error: QuicError) -> TransportError {
        match self.callbacks.lock().alert {
            Some(alert) => {
                TransportError::new(TransportErrorCode::crypto(alert), "TLS handshake failed")
                    .with_cause(error)
            }
            None => TransportError::PROTOCOL_VIOLATION("TLS handshake failed").with_cause(error),
        }
    }

    fn drive(&mut self, mut cx: Option<&mut Context<'_>>) -> Result<(), TransportError> {
        loop {
            let status = match self.step(cx.as_deref_mut()) {
                Poll::Pending => {
                    self.pending_callback = true;
                    break;
                }
                Poll::Ready(status) => {
                    self.pending_callback = false;
                    status
                }
            };
            match status.map_err(|error| self.tls_error(error))? {
                HandshakeStatus::EarlyData => {}
                HandshakeStatus::EarlyDataRejected => {
                    debug!(
                        reason = self.inner.ssl().early_data_reason().as_str(),
                        "boring quic: 0-RTT rejected"
                    );
                    self.early_rejected = true;
                    self.inner
                        .reset_early_data_rejection()
                        .map_err(|error| self.tls_error(error))?;
                }
                HandshakeStatus::Complete | HandshakeStatus::WantRead => break,
            }
        }
        self.collect_output()?;
        self.update_metadata()
    }

    /// One handshake step, under `cx` or else the driver's latest waker, so any callback can
    /// wait on asynchronous work: a peer packet read in between must not replace the waker
    /// that work will wake.
    fn step(&mut self, cx: Option<&mut Context<'_>>) -> Poll<Result<HandshakeStatus, QuicError>> {
        if let Some(cx) = cx {
            return self.inner.poll_handshake(cx);
        }
        // Before the driver's first poll nothing can be woken: that poll drives the work.
        let waker = self.waker.clone().unwrap_or_else(|| Waker::noop().clone());
        self.inner.poll_handshake(&mut Context::from_waker(&waker))
    }

    /// Whether handshake metadata became available for the first time.
    fn take_metadata_ready(&mut self) -> bool {
        // Any one of these means there is something to report, and the earliest one wins: a
        // server learns the name and the protocol together from the ClientHello, while a
        // client only ever learns the protocol. A finished handshake is the backstop for a
        // session that agreed neither.
        let ready = self.inner.ssl().selected_alpn_protocol().is_some()
            || self.server_name.is_some()
            || self.inner.ssl().is_init_finished();
        let first = ready && !self.got_handshake_data;
        self.got_handshake_data |= ready;
        first
    }

    fn collect_output(&mut self) -> Result<(), TransportError> {
        loop {
            let Some(event) = self.callbacks.lock().events.pop_front() else {
                break;
            };
            match event {
                Event::Data(level, bytes) => self
                    .output
                    .push_back(HandshakeEvent::Data(space(level)?, bytes)),
                Event::Secret {
                    write,
                    level,
                    suite,
                    bytes,
                } => {
                    let labels = if level == EncryptionLevel::EarlyData {
                        &self.early_wire.labels
                    } else {
                        &self.wire.labels
                    };
                    let secret = Suite::from_id(suite)
                        .and_then(|suite| Secret::new(suite, &bytes, labels))
                        .map_err(crypto_error)?;
                    let keys = secret.directional_keys().map_err(crypto_error)?;
                    if level == EncryptionLevel::EarlyData {
                        if write != self.side.is_client() {
                            return Err(TransportError::INTERNAL_ERROR(
                                "invalid early-data key direction",
                            ));
                        }
                        self.early_keys = Some((Arc::from(keys.header), Arc::from(keys.packet)));
                        continue;
                    }
                    let space = space(level)?;
                    let index = space as usize;
                    // Only the 1-RTT secrets are kept: they seed every later key phase in
                    // `next_1rtt_keys`. Both endpoints deriving updates from the same wrong
                    // secret would still agree, so only a peer that is not this backend can
                    // tell that the wrong one was kept.
                    if space == SpaceId::Data {
                        if write {
                            self.local_secret = Some(secret);
                        } else {
                            self.remote_secret = Some(secret);
                        }
                    }
                    if write {
                        if self.write_ready[index] {
                            return Err(TransportError::INTERNAL_ERROR("duplicate TLS write keys"));
                        }
                        self.write_ready[index] = true;
                        self.output.push_back(HandshakeEvent::Keys(
                            space,
                            Keys {
                                local: keys,
                                remote: self.pending_read[index].take(),
                            },
                        ));
                    } else if self.write_ready[index] {
                        self.output.push_back(HandshakeEvent::ReadKeys(space, keys));
                    } else if self.pending_read[index].replace(keys).is_some() {
                        return Err(TransportError::INTERNAL_ERROR("duplicate TLS read keys"));
                    }
                }
            }
        }
        Ok(())
    }

    fn update_metadata(&mut self) -> Result<(), TransportError> {
        let ssl = self.inner.ssl();
        if !self.side.is_client()
            && self.server_name.is_none()
            && let Some(name) = ssl.servername(NameType::HOST_NAME)
        {
            self.server_name =
                Some(Domain::try_from(name).map_err(|error| crypto_error(error.into()))?);
        }
        // A resumed session reports its ticket's chain until a full handshake may replace it.
        if self.store_peer_chain && self.certificates.is_none() && ssl.is_init_finished() {
            self.certificates = peer_certificate_chain(ssl).map_err(crypto_error)?;
        }
        if !self.completed && ssl.is_init_finished() {
            self.completed = true;
            if let Some(hook) = handshake_completed_hook(ssl) {
                (hook.0)(ssl);
            }
        }
        // The peer's parameters arrive once and never change, so they are parsed once: this runs
        // for every CRYPTO frame, and a large parameter list must not be re-read for each.
        let mut peer_params = self.peer_params.lock();
        if peer_params.is_none() {
            let params = self.inner.peer_transport_parameters();
            if !params.is_empty() || ssl.is_init_finished() {
                #[cfg(test)]
                PEER_PARAMETER_PARSES.with(|parses| parses.set(parses.get() + 1));
                *peer_params = Some(
                    TransportParameters::read(self.side, &mut &params[..])
                        .map_err(TransportError::from)?,
                );
            }
        }
        Ok(())
    }
}

fn space(level: EncryptionLevel) -> Result<SpaceId, TransportError> {
    match level {
        EncryptionLevel::Initial => Ok(SpaceId::Initial),
        EncryptionLevel::Handshake => Ok(SpaceId::Handshake),
        EncryptionLevel::Application => Ok(SpaceId::Data),
        EncryptionLevel::EarlyData => Err(TransportError::INTERNAL_ERROR(
            "TLS handshake bytes at early-data level",
        )),
    }
}

impl crypto::Session for TlsSession {
    fn initial_keys(
        &self,
        version: Version,
        cid: &ConnectionId,
        side: Side,
    ) -> Result<Keys, TransportError> {
        let wire = packet::wire(version)
            .ok_or_else(|| TransportError::INTERNAL_ERROR("unsupported QUIC version"))?;
        packet::initial_keys(wire, cid, side).map_err(crypto_error)
    }
    fn switch_version(&mut self, version: Version) -> Result<(), UnsupportedVersion> {
        // Keys are derived from secrets as they are drained, so re-labelling is free until
        // the first Handshake secret has been turned into keys.
        if self.write_ready[SpaceId::Handshake as usize]
            || self.pending_read[SpaceId::Handshake as usize].is_some()
            || self.local_secret.is_some()
        {
            return Err(UnsupportedVersion);
        }
        self.wire = packet::wire(version).ok_or(UnsupportedVersion)?;
        if let Some(negotiated) = &self.negotiated {
            *negotiated.lock() = version;
        }
        Ok(())
    }
    fn handshake_summary(&self) -> Option<crypto::NegotiatedTlsParameters> {
        self.got_handshake_data
            .then(|| crypto::NegotiatedTlsParameters {
                protocol_version: rama_tls::ProtocolVersion::TLSv1_3,
                peer_certificate_chain: if self.store_peer_chain {
                    self.certificates.clone()
                } else {
                    None
                },
                application_layer_protocol: self
                    .inner
                    .ssl()
                    .selected_alpn_protocol()
                    .map(ApplicationProtocol::from),
                server_name: self.server_name.clone(),
                resumed: self
                    .inner
                    .ssl()
                    .is_init_finished()
                    .then(|| self.inner.ssl().session_reused()),
                algorithms: NegotiatedTlsAlgorithms::rama_from(self.inner.ssl()),
                server_hello: ServerAnswerRecorder::installed(self.inner.ssl())
                    .and_then(|recorder| recorder.server_hello(true)),
            })
    }
    fn negotiated_alpn(&self) -> Option<&[u8]> {
        self.inner.ssl().selected_alpn_protocol()
    }
    #[cfg(test)]
    fn negotiated_key_exchange_group(&self) -> Option<u16> {
        use rama_core::conversion::RamaTryFrom as _;
        self.inner
            .ssl()
            .curve()
            .and_then(|curve| rama_tls::SupportedGroup::rama_try_from(curve).ok())
            .map(u16::from)
    }
    fn early_crypto(&self) -> Option<(Box<dyn HeaderKey>, Box<dyn PacketKey>)> {
        self.early_keys.as_ref().map(|(header, packet)| {
            (
                Box::new(header.clone()) as Box<dyn HeaderKey>,
                Box::new(packet.clone()) as Box<dyn PacketKey>,
            )
        })
    }
    fn early_data_accepted(&self) -> Option<bool> {
        self.inner
            .ssl()
            .is_init_finished()
            .then(|| !self.early_rejected && self.inner.early_data_accepted())
    }
    fn is_handshaking(&self) -> bool {
        !self.inner.ssl().is_init_finished()
    }
    fn read_handshake(&mut self, level: SpaceId, bytes: &[u8]) -> Result<bool, TransportError> {
        let level = match level {
            SpaceId::Initial => EncryptionLevel::Initial,
            SpaceId::Handshake => EncryptionLevel::Handshake,
            SpaceId::Data => EncryptionLevel::Application,
        };
        self.inner
            .provide_data(level, bytes)
            .map_err(|error| self.tls_error(error))?;
        if self.inner.ssl().is_init_finished() {
            self.inner
                .process_post_handshake()
                .map_err(|error| self.tls_error(error))?;
            self.collect_output()?;
            self.update_metadata()?;
        } else {
            self.drive(None)?;
        }
        Ok(self.take_metadata_ready())
    }

    fn poll_pending_callbacks(
        &mut self,
        cx: &mut Context<'_>,
    ) -> Result<Option<bool>, TransportError> {
        if !self
            .waker
            .as_ref()
            .is_some_and(|waker| waker.will_wake(cx.waker()))
        {
            self.waker = Some(cx.waker().clone());
        }
        if !self.pending_callback {
            return Ok(None);
        }
        self.drive(Some(cx))?;
        Ok(Some(self.take_metadata_ready()))
    }

    fn cancel_pending_callbacks(&mut self) {
        self.pending_callback = false;
        self.waker = None;
        self.inner.abort_handshake();
    }
    fn transport_parameters(&self) -> Result<Option<TransportParameters>, TransportError> {
        Ok(self
            .peer_params
            .lock()
            .clone()
            .or_else(|| self.remembered.clone()))
    }
    fn poll_handshake(&mut self) -> Result<Option<HandshakeEvent>, TransportError> {
        Ok(self.output.pop_front())
    }
    fn next_1rtt_keys(&mut self) -> Result<Option<KeyPair<Box<dyn PacketKey>>>, TransportError> {
        let (Some(local), Some(remote)) = (&self.local_secret, &self.remote_secret) else {
            return Ok(None);
        };
        let local = local.updated().map_err(crypto_error)?;
        let remote = remote.updated().map_err(crypto_error)?;
        let keys = KeyPair {
            local: Box::new(local.packet_key().map_err(crypto_error)?) as Box<dyn PacketKey>,
            remote: Box::new(remote.packet_key().map_err(crypto_error)?) as Box<dyn PacketKey>,
        };
        self.local_secret = Some(local);
        self.remote_secret = Some(remote);
        Ok(Some(keys))
    }
    fn is_valid_retry(&self, cid: &ConnectionId, header: &[u8], payload: &[u8]) -> bool {
        let Some(tag_start) = payload.len().checked_sub(16) else {
            return false;
        };
        let mut packet = header.to_vec();
        packet.extend_from_slice(&payload[..tag_start]);
        packet::retry_tag(self.wire, cid, &packet)
            .is_ok_and(|tag| memcmp::eq(&tag, &payload[tag_start..]))
    }
    fn export_keying_material(
        &self,
        output: &mut [u8],
        label: &[u8],
        context: &[u8],
    ) -> Result<(), crypto::ExportKeyingMaterialError> {
        self.inner
            .ssl()
            .export_keying_material_bytes(output, label, Some(context))
            .map_err(|_error| crypto::ExportKeyingMaterialError)
    }
}
