//! Test-only external GnuTLS provider. QUIC v1, TLS 1.3, AES128-GCM/SHA256,
//! X25519, certificate authentication, no resumption or 0-RTT.
mod native;
mod packet;
use std::{collections::VecDeque, sync::Arc, task::Context};

pub use native::{GnuTlsError, version};
use parking_lot::Mutex;
use rama::{
    crypto::pki_types::CertificateDer,
    net::tls::ApplicationProtocol,
    quic::{
        self, ConnectError,
        proto::{
            ConnectionId, Side, TransportError, TransportErrorCode, Version,
            crypto::{CryptoError, HeaderKey, PacketKey},
            packet::SpaceId as EncryptionLevel,
            transport_parameters::TransportParameters,
        },
        tls::provider::{self, *},
    },
    tls::{ProtocolVersion, client::NegotiatedTlsParameters},
};

pub struct Client {
    pub ca: String,
    pub alpn: Vec<u8>,
}

pub struct Server {
    pub certificate: String,
    pub key: String,
    pub alpn: Vec<u8>,
}

impl Client {
    pub fn config(self) -> quic::ClientConfig {
        quic::ClientConfig::new(Arc::new(self))
    }
}

impl Server {
    pub fn config(self) -> Result<quic::ServerConfig, GnuTlsError> {
        Ok(quic::ServerConfig::new(
            Arc::new(self),
            Arc::new(packet::TokenKey::new()?),
        ))
    }
}

fn failure(error: GnuTlsError) -> TransportError {
    TransportError::new(TransportErrorCode::INTERNAL_ERROR, error.to_string()).with_cause(error)
}

impl provider::ClientConfig for Client {
    fn start_session(
        self: Arc<Self>,
        version: Version,
        name: &str,
        params: &TransportParameters,
    ) -> Result<Box<dyn provider::Session>, ConnectError> {
        if version != Version::V1 {
            return Err(ConnectError::UnsupportedVersion);
        }
        let mut parameters = Vec::new();
        params.write(&mut parameters);
        let native = native::NativeSession::new(native::Options {
            server: false,
            ca: &self.ca,
            certificate: "",
            key: "",
            name,
            alpn: &self.alpn,
            parameters: &parameters,
        })
        .map_err(|e| ConnectError::Crypto(failure(e)))?;
        Ok(Box::new(
            Session::new(native, Side::Client).map_err(ConnectError::Crypto)?,
        ))
    }

    fn supports_version_switch(&self) -> bool {
        false
    }

    fn resumable_version(&self, _: &str) -> Option<Version> {
        None
    }
}

impl provider::InitialServerConfig for Server {
    fn initial_keys(&self, version: Version, cid: &ConnectionId) -> Result<Keys, InitialKeysError> {
        if version != Version::V1 {
            return Err(InitialKeysError::UnsupportedVersion);
        }
        packet::initial(cid, Side::Server).map_err(|e| InitialKeysError::Crypto(e.into()))
    }

    fn retry_tag(
        &self,
        _: Version,
        cid: &ConnectionId,
        packet: &[u8],
    ) -> Result<[u8; 16], CryptoError> {
        packet::retry_tag(cid, packet).map_err(|_| CryptoError::new())
    }
}

impl provider::ServerConfig for Server {
    fn start_session(
        self: Arc<Self>,
        _: Version,
        params: &TransportParameters,
    ) -> Result<Box<dyn provider::Session>, TransportError> {
        let mut parameters = Vec::new();
        params.write(&mut parameters);
        let native = native::NativeSession::new(native::Options {
            server: true,
            ca: "",
            certificate: &self.certificate,
            key: &self.key,
            name: "",
            alpn: &self.alpn,
            parameters: &parameters,
        })
        .map_err(failure)?;
        Ok(Box::new(Session::new(native, Side::Server)?))
    }

    fn supports_compatible_negotiation(&self) -> bool {
        false
    }

    fn start_negotiated_session(
        self: Arc<Self>,
        _: Version,
        _: Version,
        _: &TransportParameters,
    ) -> Result<Box<dyn provider::Session>, TransportError> {
        Err(TransportError::INTERNAL_ERROR(
            "GnuTLS sessions stay in the version they start in",
        ))
    }
}

struct Session {
    native: Mutex<native::NativeSession>,
    side: Side,
    complete: bool,
    alpn: Option<Vec<u8>>,
    certificates: Vec<CertificateDer<'static>>,
    output: VecDeque<HandshakeEvent>,
    pending_read: [Option<DirectionalKeys>; 3],
    write_ready: [bool; 3],
    local_secret: Option<packet::Secret>,
    remote_secret: Option<packet::Secret>,
}

fn level(level: i32) -> Result<EncryptionLevel, TransportError> {
    match level {
        0 => Ok(EncryptionLevel::Initial),
        2 => Ok(EncryptionLevel::Handshake),
        3 => Ok(EncryptionLevel::Data),
        _ => Err(TransportError::new(
            TransportErrorCode::INTERNAL_ERROR,
            "unexpected GnuTLS encryption level",
        )),
    }
}

fn native_level(level: EncryptionLevel) -> i32 {
    match level {
        EncryptionLevel::Initial => 0,
        EncryptionLevel::Handshake => 2,
        EncryptionLevel::Data => 3,
    }
}

impl Session {
    fn new(native: native::NativeSession, side: Side) -> Result<Self, TransportError> {
        let mut session = Self {
            native: Mutex::new(native),
            side,
            complete: false,
            alpn: None,
            certificates: Vec::new(),
            output: VecDeque::new(),
            pending_read: [None, None, None],
            write_ready: [false; 3],
            local_secret: None,
            remote_secret: None,
        };
        session.advance(EncryptionLevel::Initial, &[])?;
        Ok(session)
    }

    fn advance(
        &mut self,
        encryption: EncryptionLevel,
        bytes: &[u8],
    ) -> Result<bool, TransportError> {
        let native = self.native.get_mut();
        self.complete = native
            .step(native_level(encryption), bytes)
            .map_err(|error| {
                TransportError::new(
                    TransportErrorCode::crypto(native.alert(error.code)),
                    error.to_string(),
                )
                .with_cause(error)
            })?;
        let ready_before = self.alpn.is_some();
        self.alpn = native.alpn();
        self.certificates = native
            .certificates()
            .into_iter()
            .map(CertificateDer::from)
            .collect();
        while let Some(event) = native.event().map_err(failure)? {
            let space = level(event.info.level)?;
            if event.info.kind == 0 {
                self.output
                    .push_back(HandshakeEvent::Data(space, event.data.to_vec()));
                continue;
            }
            let index = space as usize;
            for write in [false, true] {
                let size = if write {
                    event.info.write_size
                } else {
                    event.info.read_size
                };
                if size == 0 {
                    continue;
                }
                let start = if write { event.info.read_size } else { 0 };
                let secret = packet::Secret::new(&event.data[start..start + size]);
                let keys = secret.keys().map_err(failure)?;
                if space == EncryptionLevel::Data {
                    if write {
                        self.local_secret = Some(secret);
                    } else {
                        self.remote_secret = Some(secret);
                    }
                }
                if write {
                    if self.write_ready[index] {
                        return Err(TransportError::new(
                            TransportErrorCode::INTERNAL_ERROR,
                            "duplicate write secret",
                        ));
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
                } else {
                    self.pending_read[index] = Some(keys);
                }
            }
        }
        Ok(!ready_before && self.alpn.is_some())
    }
}

impl provider::Session for Session {
    fn initial_keys(
        &self,
        version: Version,
        cid: &ConnectionId,
        side: Side,
    ) -> Result<Keys, TransportError> {
        if version != Version::V1 {
            return Err(TransportError::new(
                TransportErrorCode::INTERNAL_ERROR,
                "GnuTLS fixture speaks QUIC v1 only",
            ));
        }
        packet::initial(cid, side).map_err(failure)
    }

    fn switch_version(&mut self, _: Version) -> Result<(), UnsupportedVersion> {
        Err(UnsupportedVersion)
    }

    fn handshake_summary(&self) -> Option<NegotiatedTlsParameters> {
        self.alpn.as_ref().map(|alpn| NegotiatedTlsParameters {
            protocol_version: ProtocolVersion::TLSv1_3,
            application_layer_protocol: Some(ApplicationProtocol::from(alpn.as_slice())),
            peer_certificate_chain: (!self.certificates.is_empty())
                .then(|| self.certificates.clone()),
            server_name: None,
            // This independent fixture does not retain the parsed ServerHello.
            server_hello: None,
            resumed: self.complete.then_some(false),
            algorithms: Default::default(),
        })
    }

    fn negotiated_alpn(&self) -> Option<&[u8]> {
        self.alpn.as_deref()
    }

    fn early_crypto(&self) -> Option<(Box<dyn HeaderKey>, Box<dyn PacketKey>)> {
        None
    }

    fn early_data_accepted(&self) -> Option<bool> {
        None
    }

    fn is_handshaking(&self) -> bool {
        !self.complete
    }

    fn read_handshake(
        &mut self,
        level: EncryptionLevel,
        bytes: &[u8],
    ) -> Result<bool, TransportError> {
        self.advance(level, bytes)
    }

    // GnuTLS callbacks here never wait on asynchronous work.
    fn poll_pending_callbacks(
        &mut self,
        _: &mut Context<'_>,
    ) -> Result<Option<bool>, TransportError> {
        Ok(None)
    }

    fn cancel_pending_callbacks(&mut self) {}

    fn transport_parameters(&self) -> Result<Option<TransportParameters>, TransportError> {
        self.native
            .lock()
            .parameters()
            .map(|bytes| {
                TransportParameters::read(self.side, &mut bytes.as_slice()).map_err(|e| {
                    TransportError::new(
                        TransportErrorCode::TRANSPORT_PARAMETER_ERROR,
                        e.to_string(),
                    )
                })
            })
            .transpose()
    }

    fn poll_handshake(&mut self) -> Result<Option<HandshakeEvent>, TransportError> {
        Ok(self.output.pop_front())
    }

    fn next_1rtt_keys(&mut self) -> Result<Option<KeyPair<Box<dyn PacketKey>>>, TransportError> {
        let (Some(local), Some(remote)) = (&self.local_secret, &self.remote_secret) else {
            return Ok(None);
        };
        let local = local.updated().map_err(failure)?;
        let remote = remote.updated().map_err(failure)?;
        let keys = KeyPair {
            local: Box::new(local.packet().map_err(failure)?) as Box<dyn PacketKey>,
            remote: Box::new(remote.packet().map_err(failure)?) as Box<dyn PacketKey>,
        };
        self.local_secret = Some(local);
        self.remote_secret = Some(remote);
        Ok(Some(keys))
    }

    fn is_valid_retry(&self, cid: &ConnectionId, header: &[u8], payload: &[u8]) -> bool {
        packet::valid_retry(cid, header, payload)
    }

    fn export_keying_material(
        &self,
        out: &mut [u8],
        label: &[u8],
        context: &[u8],
    ) -> Result<(), ExportKeyingMaterialError> {
        self.native
            .lock()
            .export(label, context, out)
            .map_err(|_| ExportKeyingMaterialError::new())
    }
}
