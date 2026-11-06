use rama_utils::collections::smallvec::{SmallVec, smallvec};
use std::{
    collections::{BTreeSet, hash_map},
    convert::TryFrom,
    fmt, mem,
    net::{IpAddr, SocketAddr},
    ops::{Index, IndexMut, Range},
    sync::Arc,
};

use ahash::HashMap;
use rama_core::{
    bytes::{BufMut, Bytes, BytesMut},
    telemetry::tracing::{debug, error, trace, warn},
};
use rama_quic_proto::{
    ConnectionId, EcnCodepoint, MAX_CID_SIZE, RESET_TOKEN_SIZE, ResetToken, Side, TransportError,
    Version,
    coding::BufMutExt,
    frame,
    packet::{
        FixedLengthConnectionIdParser, Header, InitialHeader, InitialPacket, PacketDecodeError,
        PacketNumber, PartialDecode, ProtectedInitialHeader,
    },
    transport_parameters::{PreferredAddress, TransportParameters},
    version::WireVersion,
};
use rama_tls::{ExtensionId, client::ClientHelloExtension};
use rand::{
    Rng, RngExt, SeedableRng,
    rngs::{StdRng, SysRng},
};
use rustc_hash::FxHashMap;
use slab::Slab;

use crate::proto::{
    Admission, AdmissionLease, Decision, Duration, INITIAL_MTU, Instant, MIN_INITIAL_SIZE, Refusal,
    Transmit, TransportConfig,
    cid_generator::ConnectionIdGenerator,
    cid_queue::{CidQueue, RemCid},
    config::{ClientConfig, EndpointConfig, ServerConfig, ServerCrypto},
    connection::{Connection, ConnectionError, SideArgs},
    crypto::{self, Keys},
    first_flight::{ClientHelloPeek, HelloAssembly, IncomingProgress},
    observation::ServerObservation,
    shared::{
        ConnectionEvent, ConnectionEventInner, DatagramConnectionEvent, EndpointEvent,
        EndpointEventInner, IssuedCid,
    },
    token::{IncomingToken, Token, TokenPayload, reset_token},
    transport_parameters::{self},
};

/// The main entry point to the library
///
/// This object performs no I/O whatsoever. Instead, it consumes incoming packets and
/// connection-generated events via `handle` and `handle_event`.
pub(crate) struct Endpoint {
    rng: StdRng,
    index: ConnectionIndex,
    connections: Slab<ConnectionMeta>,
    /// A profiled zero-CID client owns this endpoint until its connection drains.
    exclusive_connection: Option<ConnectionHandle>,
    local_cid_generator: Box<dyn ConnectionIdGenerator>,
    config: Arc<EndpointConfig>,
    server_config: Option<Arc<ServerConfig>>,
    /// Whether the underlying UDP socket promises not to fragment packets
    allow_mtud: bool,
    /// Time at which a stateless reset was most recently sent
    last_stateless_reset: Option<Instant>,
    /// Buffered Initial and 0-RTT messages for pending incoming connections
    incoming_buffers: Slab<IncomingBuffer>,
    incoming_deadlines: BTreeSet<(Instant, usize)>,
    all_incoming_buffers_total_bytes: u64,
    /// Counts attempts in progress and decides how each new one is answered.
    admission: Admission,
    admission_stats: AdmissionStats,
}

/// What admission did with the attempts it did not accept.
#[derive(Debug, Default, Clone, Copy)]
pub(crate) struct AdmissionStats {
    /// Unvalidated attempts answered with a Retry because the endpoint was under load.
    pub(crate) retried: u64,
    /// Attempts refused because the endpoint held as many in progress as it allows.
    pub(crate) refused_at_limit: u64,
    /// Attempts refused because their source held as many in progress as it may.
    pub(crate) refused_per_source: u64,
    /// Unvalidated attempts refused under load, as an endpoint without local connection IDs
    /// cannot answer them with a Retry.
    pub(crate) refused_unvalidated: u64,
}

impl Endpoint {
    /// Create a new endpoint
    ///
    /// `allow_mtud` enables path MTU detection when requested by `Connection` configuration for
    /// better performance. This requires that outgoing packets are never fragmented, which can be
    /// achieved via e.g. the `IPV6_DONTFRAG` socket option.
    ///
    /// If `rng_seed` is provided, it will be used to initialize the endpoint's rng (having priority
    /// over the rng seed configured in [`EndpointConfig`]). Note that the `rng_seed` parameter will
    /// be removed in a future release, so prefer setting it to `None` and configuring rng seeds
    /// using [`EndpointConfig::rng_seed`].
    #[expect(
        clippy::expect_used,
        reason = "an endpoint cannot operate without randomness; failing to read the OS RNG is not recoverable here"
    )]
    pub(crate) fn new(
        config: Arc<EndpointConfig>,
        server_config: Option<Arc<ServerConfig>>,
        allow_mtud: bool,
        rng_seed: Option<[u8; 32]>,
    ) -> Self {
        Self {
            rng: match rng_seed.or(config.rng_seed) {
                Some(seed) => StdRng::from_seed(seed),
                None => StdRng::try_from_rng(&mut SysRng)
                    .expect("failed to seed random number generator from system"),
            },
            index: ConnectionIndex::default(),
            connections: Slab::new(),
            exclusive_connection: None,
            local_cid_generator: (config.connection_id_generator_factory.as_ref())(),
            config,
            server_config,
            allow_mtud,
            last_stateless_reset: None,
            incoming_buffers: Slab::new(),
            incoming_deadlines: BTreeSet::new(),
            all_incoming_buffers_total_bytes: 0,
            admission: Admission::default(),
            admission_stats: AdmissionStats::default(),
        }
    }

    /// Replace the server configuration, affecting new incoming connections only
    pub(crate) fn set_server_config(&mut self, server_config: Option<Arc<ServerConfig>>) {
        self.server_config = server_config;
    }

    /// Stop advertising `address` as preferred: the endpoint no longer owns a usable socket there,
    /// so connections that have not handshaked yet must not be sent to it. Connections already
    /// established keep whatever path they have; their transport parameters are long since sent.
    pub(crate) fn stop_advertising(&mut self, address: SocketAddr) {
        let Some(config) = self.server_config.as_ref() else {
            return;
        };
        let advertises = match address {
            SocketAddr::V4(address) => config.preferred_address_v4 == Some(address),
            SocketAddr::V6(address) => config.preferred_address_v6 == Some(address),
        };
        if !advertises {
            return;
        }
        let mut updated = ServerConfig::clone(config);
        match address {
            SocketAddr::V4(_) => updated.preferred_address_v4 = None,
            SocketAddr::V6(_) => updated.preferred_address_v6 = None,
        }
        self.server_config = Some(Arc::new(updated));
    }

    /// Tests: the addresses this endpoint advertises as preferred.
    #[cfg(test)]
    pub(crate) fn advertised_preferred(&self) -> Vec<SocketAddr> {
        let Some(config) = self.server_config.as_ref() else {
            return Vec::new();
        };
        config
            .preferred_address_v4
            .map(SocketAddr::V4)
            .into_iter()
            .chain(config.preferred_address_v6.map(SocketAddr::V6))
            .collect()
    }

    /// How long a Retry token issued now stays valid, when configured to serve.
    pub(crate) fn retry_token_lifetime(&self) -> Option<Duration> {
        self.server_config
            .as_ref()
            .map(|config| config.retry_token_lifetime)
    }

    /// Attempts in progress, and the retry threshold the current configuration gives at `now`
    /// (zero while admission is disabled).
    pub(crate) fn admission_load(&self, now: Instant) -> (usize, usize) {
        let config = self
            .server_config
            .as_ref()
            .and_then(|config| config.admission.as_ref());
        self.admission.load(now, config)
    }

    /// What admission did with the attempts it did not accept.
    pub(crate) fn admission_stats(&self) -> AdmissionStats {
        self.admission_stats
    }

    /// Tests: which connection a reset carrying `token` from `remote` would reach.
    #[cfg(test)]
    pub(crate) fn reset_route_for(
        &self,
        remote: SocketAddr,
        token: ResetToken,
    ) -> Option<ConnectionHandle> {
        self.index
            .connection_reset_tokens
            .0
            .get(&remote)
            .and_then(|tokens| tokens.get(&token))
            .copied()
    }

    /// Tests: how many stateless-reset routes the endpoint's index holds.
    #[cfg(test)]
    pub(crate) fn reset_route_count(&self) -> usize {
        self.index
            .connection_reset_tokens
            .0
            .values()
            .map(|tokens| tokens.len())
            .sum()
    }

    /// Process `EndpointEvent`s emitted from related `Connection`s
    ///
    /// In turn, processing this event may return a `ConnectionEvent` for the same `Connection`.
    pub(crate) fn handle_event(
        &mut self,
        ch: ConnectionHandle,
        event: EndpointEvent,
    ) -> Option<ConnectionEvent> {
        match event.0 {
            EndpointEventInner::NeedIdentifiers(now, n) => {
                return Some(self.send_new_identifiers(now, ch, n));
            }
            EndpointEventInner::ResetTokenUsed(remote, seq, token, generation) => {
                // An identifier can be recognised at more than one address, since a rebinding
                // keeps it while the previous path may still answer. Associations are therefore
                // keyed by identifier and address, and installing one does not delete another
                // (RFC 9000 §10.3.1). The engine releases what it stops using, which bounds this
                // table by what the engine holds.
                match self.connections[ch]
                    .reset_tokens
                    .insert(seq, remote, token, generation)
                {
                    Installed::New => {
                        if self.index.connection_reset_tokens.insert(remote, token, ch) {
                            warn!("duplicate reset token");
                        }
                    }
                    Installed::Refreshed => {}
                    // Refuse installation when full: acknowledging it would permit use of
                    // a route that does not exist.
                    Installed::Full => {
                        return Some(ConnectionEvent(ConnectionEventInner::ResetRouteRefused(
                            remote, seq, generation,
                        )));
                    }
                }
                // The route exists now, which is what the connection is waiting for before it
                // sends anything with this identifier to this address.
                return Some(ConnectionEvent(ConnectionEventInner::ResetRouteInstalled(
                    remote, seq, generation,
                )));
            }
            EndpointEventInner::ResetTokenReleased(remote, seq, token, generation) => {
                if self.connections[ch]
                    .reset_tokens
                    .release(seq, remote, generation)
                {
                    self.index.connection_reset_tokens.remove(remote, token);
                }
            }
            EndpointEventInner::ResetTokensRetired(seqs) => {
                for (remote, token) in self.connections[ch].reset_tokens.remove_range(seqs) {
                    self.index.connection_reset_tokens.remove(remote, token);
                }
            }
            EndpointEventInner::RetireConnectionId(now, seq, allow_more_cids) => {
                if let Some(cid) = self.connections[ch].loc_cids.remove(&seq) {
                    trace!("peer retired CID {}: {}", seq, cid);
                    self.index.retire(cid);
                    if allow_more_cids {
                        return Some(self.send_new_identifiers(now, ch, 1));
                    }
                }
            }
            EndpointEventInner::Drained => {
                if let Some(conn) = self.connections.try_remove(ch.0) {
                    self.index.remove(ch, &conn);
                    if self.exclusive_connection == Some(ch) {
                        self.exclusive_connection = None;
                    }
                } else {
                    // This indicates a bug in downstream code, which could cause spurious
                    // connection loss instead of this error if the CID was (re)allocated prior to
                    // the illegal call.
                    error!(id = ch.0, "unknown connection drained");
                }
            }
        }
        None
    }

    /// Process an incoming UDP datagram
    pub(crate) fn handle(
        &mut self,
        now: Instant,
        remote: SocketAddr,
        local: Option<SocketAddr>,
        ecn: Option<EcnCodepoint>,
        data: BytesMut,
        buf: &mut Vec<u8>,
    ) -> Option<DatagramEvent> {
        // Partially decode packet or short-circuit if unable
        let datagram_len = data.len();
        let event = match PartialDecode::new(
            data,
            &FixedLengthConnectionIdParser::new(self.local_cid_generator.cid_len()),
            &self.config.supported_versions,
            self.config.grease_quic_bit,
        ) {
            Ok((first_decode, remaining)) => DatagramConnectionEvent {
                now,
                remote,
                local,
                ecn,
                first_decode,
                remaining,
            },
            Err(PacketDecodeError::UnsupportedVersion {
                src_cid,
                dst_cid,
                version,
            }) => {
                if self.server_config.is_none() {
                    debug!("dropping packet with unsupported version");
                    return None;
                }
                // RFC 9000 §5.2.2: "Servers MUST drop smaller packets that specify unsupported
                // versions." Responding to short packets would let a spoofed source elicit a
                // Version Negotiation packet larger than the datagram that triggered it.
                if datagram_len < MIN_INITIAL_SIZE as usize {
                    debug!("dropping short packet with unsupported version");
                    return None;
                }
                trace!("sending version negotiation");
                // Negotiate versions
                Header::VersionNegotiate {
                    random: self.rng.random::<u8>() | 0x40,
                    src_cid: dst_cid,
                    dst_cid: src_cid,
                }
                .encode(buf);
                // Grease with a reserved version
                buf.write(Version::grease(version));
                let offered = self
                    .server_config
                    .as_ref()
                    .map(|config| config.versions.offered(&self.config.supported_versions))
                    .unwrap_or(&self.config.supported_versions);
                for &version in offered {
                    buf.write(version);
                }
                return Some(DatagramEvent::Response(Transmit {
                    destination: remote,
                    ecn: None,
                    size: buf.len(),
                    segment_size: None,
                    local,
                    // A response the endpoint sends itself carries no identifier of ours.
                    cid_used: None,
                }));
            }
            Err(e) => {
                trace!("malformed header: {}", e);
                return None;
            }
        };

        let addresses = FourTuple { remote, local };
        let dst_cid = event.first_decode.dst_cid();

        if let Some(route_to) = self.index.get(&addresses, &event.first_decode) {
            // Handle packet on existing connection
            match route_to {
                RouteDatagramTo::Incoming(incoming_idx) => {
                    // A pending attempt outlives a server config cleared after it arrived; it
                    // buffers nothing more then, as the config is what bounds that buffer.
                    let incoming_buffer = &mut self.incoming_buffers[incoming_idx];
                    let Some(config) = self.server_config.as_ref() else {
                        if let Some(observation) = &mut incoming_buffer.observation {
                            observation.lost_datagram();
                        }
                        trace!("dropping a datagram for a pending connection: no server config");
                        return None;
                    };

                    let charge = incoming_datagram_charge(datagram_len);
                    if incoming_buffer
                        .total_bytes
                        .checked_add(charge)
                        .is_some_and(|n| n <= config.incoming_buffer_size)
                        && self
                            .all_incoming_buffers_total_bytes
                            .checked_add(charge)
                            .is_some_and(|n| n <= config.incoming_buffer_size_total)
                    {
                        incoming_buffer.datagrams.push(event);
                        incoming_buffer.total_bytes += charge;
                        self.all_incoming_buffers_total_bytes += charge;
                        incoming_buffer.progress.advance();
                    } else if let Some(observation) = &mut incoming_buffer.observation {
                        observation.lost_datagram();
                    }

                    None
                }
                RouteDatagramTo::Connection(ch) => Some(DatagramEvent::ConnectionEvent(
                    ch,
                    ConnectionEvent(ConnectionEventInner::Datagram(event)),
                )),
            }
        } else if event.first_decode.initial_header().is_some() {
            // Potentially create a new connection

            self.handle_first_packet(datagram_len, event, addresses, buf)
        } else if event.first_decode.has_long_header() {
            debug!(
                "ignoring non-initial packet for unknown connection {}",
                dst_cid
            );
            None
        } else if !event.first_decode.is_initial()
            && self.local_cid_generator.validate(dst_cid).is_err()
        {
            debug!("dropping packet with invalid CID");
            None
        } else if dst_cid.is_empty() {
            trace!("dropping unrecognized short packet without ID");
            None
        } else {
            // If we got this far, we're receiving a seemingly valid packet for an unknown
            // connection. Send a stateless reset if possible.
            self.stateless_reset(now, datagram_len, addresses, *dst_cid, buf)
                .map(DatagramEvent::Response)
        }
    }

    fn stateless_reset(
        &mut self,
        now: Instant,
        inciting_dgram_len: usize,
        addresses: FourTuple,
        dst_cid: ConnectionId,
        buf: &mut Vec<u8>,
    ) -> Option<Transmit> {
        if self
            .last_stateless_reset
            .is_some_and(|last| last + self.config.min_reset_interval > now)
        {
            debug!("ignoring unexpected packet within minimum stateless reset interval");
            return None;
        }

        /// Minimum amount of padding for the stateless reset to look like a short-header packet
        const MIN_PADDING_LEN: usize = 5;

        // Prevent amplification attacks and reset loops by ensuring we pad to at most 1 byte
        // smaller than the inciting packet.
        let max_padding_len = match inciting_dgram_len.checked_sub(RESET_TOKEN_SIZE) {
            Some(headroom) if headroom > MIN_PADDING_LEN => headroom - 1,
            _ => {
                debug!(
                    "ignoring unexpected {} byte packet: not larger than minimum stateless reset size",
                    inciting_dgram_len
                );
                return None;
            }
        };

        debug!(
            "sending stateless reset for {} to {}",
            dst_cid, addresses.remote
        );
        self.last_stateless_reset = Some(now);
        // Resets with at least this much padding can't possibly be distinguished from real packets
        const IDEAL_MIN_PADDING_LEN: usize = MIN_PADDING_LEN + MAX_CID_SIZE;
        let padding_len = if max_padding_len <= IDEAL_MIN_PADDING_LEN {
            max_padding_len
        } else {
            self.rng
                .random_range(IDEAL_MIN_PADDING_LEN..max_padding_len)
        };
        buf.reserve(padding_len + RESET_TOKEN_SIZE);
        buf.resize(padding_len, 0);
        self.rng.fill_bytes(&mut buf[0..padding_len]);
        buf[0] = 0b0100_0000 | (buf[0] >> 2);
        buf.extend_from_slice(&reset_token(&self.config.reset_key, dst_cid));

        debug_assert!(buf.len() < inciting_dgram_len);

        Some(Transmit {
            destination: addresses.remote,
            ecn: None,
            size: buf.len(),
            segment_size: None,
            local: addresses.local,
            cid_used: None,
        })
    }

    /// Initiate a connection
    pub(crate) fn connect(
        &mut self,
        now: Instant,
        config: ClientConfig,
        remote: SocketAddr,
        server_name: &str,
    ) -> Result<(ConnectionHandle, Connection), ConnectError> {
        // Validate before allocating a CID or starting TLS. A transport-only
        // profile must not silently inherit incompatible endpoint wire settings.
        config
            .transport
            .wire
            .validate_endpoint(&self.config, self.local_cid_generator.cid_len())
            .map_err(ConnectError::ProfileEndpointMismatch)?;

        let dedicated = config.transport.wire.requires_dedicated_endpoint();
        if self.cids_exhausted() {
            return Err(ConnectError::CidsExhausted);
        }
        if self.zero_cid_route_in_use(remote)
            || self.exclusive_connection.is_some()
            || (dedicated && !self.connections.is_empty())
        {
            return Err(ConnectError::EndpointInUse);
        }
        if remote.port() == 0 || remote.ip().is_unspecified() {
            return Err(ConnectError::InvalidRemoteAddress(remote));
        }
        // Every version the policy can end up in must be one this endpoint decodes.
        if config
            .versions
            .all_versions()
            .any(|version| !self.config.supported_versions.contains(&version))
        {
            return Err(ConnectError::UnsupportedVersion);
        }
        // A held ticket resumes only its own version (RFC 9369 §5); a policy that follows
        // tickets starts there. A restart after Version Negotiation keeps what it selected.
        let mut config = config;
        if config.negotiation_offer.is_none() {
            let ticket = config.crypto.resumable_version(server_name);
            config.versions = config.versions.for_ticket(ticket);
        }
        let version = config.versions.original();

        let remote_id = (config.initial_dst_cid_provider)();
        trace!(initial_dcid = %remote_id);

        let ch = ConnectionHandle(self.connections.vacant_key());
        let loc_cid = self.new_cid(RouteDatagramTo::Connection(ch));
        let mut params = transport_parameters::new(
            &config.transport,
            &self.config,
            self.local_cid_generator.as_ref(),
            loc_cid,
            None,
            &mut self.rng,
        );
        params.version_information = config
            .versions
            .advertises_version_information()
            .then(|| config.versions.information(Version::grease(version)));
        let tls = match config.crypto.start_session(version, server_name, &params) {
            Ok(tls) => tls,
            Err(error) => {
                self.index.connection_ids.remove(&loc_cid);
                return Err(error);
            }
        };

        let conn = self
            .add_connection(
                ch,
                version,
                remote_id,
                loc_cid,
                remote_id,
                FourTuple {
                    remote,
                    local: None,
                },
                now,
                tls,
                config.transport,
                SideArgs::Client {
                    token_store: config.token_store,
                    server_name: server_name.into(),
                    preferred_address_policy: config.preferred_address_policy,
                    versions: config.versions,
                    negotiation_offer: config.negotiation_offer,
                    time_source: config.time_source,
                },
            )
            .map_err(|error| {
                self.index.connection_ids.remove(&loc_cid);
                ConnectError::Crypto(error)
            })?;
        // Reserve only after successful TLS/connection construction. A failed dial
        // must leave an application-supplied endpoint available for another attempt.
        if dedicated {
            self.exclusive_connection = Some(ch);
        }
        conn.qlog_local_parameters(now, &params);
        Ok((ch, conn))
    }

    fn send_new_identifiers(
        &mut self,
        now: Instant,
        ch: ConnectionHandle,
        num: u64,
    ) -> ConnectionEvent {
        let mut ids = vec![];
        for _ in 0..num {
            let id = self.new_cid(RouteDatagramTo::Connection(ch));
            let meta = &mut self.connections[ch];
            let sequence = meta.cids_issued;
            meta.cids_issued += 1;
            meta.loc_cids.insert(sequence, id);
            ids.push(IssuedCid {
                sequence,
                id,
                reset_token: reset_token(&self.config.reset_key, id),
            });
        }
        ConnectionEvent(ConnectionEventInner::NewIdentifiers(ids, now))
    }

    /// Generate a connection ID whose datagrams go to `route`
    fn new_cid(&mut self, route: RouteDatagramTo) -> ConnectionId {
        loop {
            let cid = self.local_cid_generator.generate_cid();
            if cid.is_empty() {
                // Zero-length CID; nothing to track
                debug_assert_eq!(self.local_cid_generator.cid_len(), 0);
                return cid;
            }
            if let hash_map::Entry::Vacant(e) = self.index.connection_ids.entry(cid) {
                e.insert(route);
                break cid;
            }
        }
    }

    fn handle_first_packet(
        &mut self,
        datagram_len: usize,
        event: DatagramConnectionEvent,
        addresses: FourTuple,
        buf: &mut Vec<u8>,
    ) -> Option<DatagramEvent> {
        let dst_cid = event.first_decode.dst_cid();
        #[expect(
            clippy::unwrap_used,
            reason = "`handle` only dispatches here for Initial packets (`first_decode.is_initial()`)"
        )]
        let header = event.first_decode.initial_header().unwrap();

        let Some(server_config) = &self.server_config else {
            debug!("packet for unrecognized connection {}", dst_cid);
            return self
                .stateless_reset(event.now, datagram_len, addresses, *dst_cid, buf)
                .map(DatagramEvent::Response);
        };

        if datagram_len < MIN_INITIAL_SIZE as usize {
            debug!("ignoring short initial for connection {}", dst_cid);
            return None;
        }

        // Saturation only happens under heavy load, where deriving initial keys per Initial just to
        // reply with CONNECTION_REFUSED would starve packet processing for existing connections.
        if self.cids_exhausted() || self.incoming_buffers.len() >= server_config.max_incoming {
            debug!(
                "ignoring initial for connection {} due to saturation",
                dst_cid
            );
            return None;
        }

        let crypto = match server_config
            .crypto
            .initial()
            .initial_keys(header.version.version(), dst_cid)
        {
            Ok(keys) => keys,
            Err(error) => {
                match error {
                    crypto::InitialKeysError::UnsupportedVersion => debug!(
                        "ignoring initial packet version {} unsupported by cryptographic layer",
                        header.version
                    ),
                    crypto::InitialKeysError::Crypto(error) => {
                        debug!(%error, "unable to derive Initial packet keys")
                    }
                }
                return None;
            }
        };

        if let Err(reason) = self.early_validate_first_packet(header) {
            return self
                .initial_close(
                    header.version,
                    addresses,
                    &crypto,
                    &header.src_cid,
                    reason,
                    buf,
                )
                .map(DatagramEvent::Response);
        }

        let Some(remote) = crypto.remote.as_ref() else {
            trace!("initial packet has no remote header protection key");
            return None;
        };
        let observation = server_config.capture.map(|limits| {
            Box::new(ServerObservation::new(
                limits,
                event.first_decode.data(),
                event.remaining.as_deref(),
            ))
        });
        let packet = match event.first_decode.finish_protected(remote.header.as_ref()) {
            Ok(packet) => packet,
            Err(e) => {
                trace!("unable to decode initial packet: {}", e);
                return None;
            }
        };

        if !packet.reserved_bits_valid() {
            debug!("dropping connection attempt with invalid reserved bits");
            return None;
        }

        #[expect(
            clippy::panic,
            reason = "`handle_first_packet` is only called for Initial packets, so `finish` decoded an Initial header"
        )]
        let Header::Initial(header) = packet.header else {
            panic!("non-initial packet in handle_first_packet()");
        };

        #[expect(
            clippy::unwrap_used,
            reason = "the `let Some(server_config)` check at the top of this function returned when no server config is set"
        )]
        let server_config = self.server_config.as_ref().unwrap().clone();

        let Ok(token) = IncomingToken::from_header(&header, &server_config, addresses.remote)
        else {
            debug!("rejecting invalid retry token");
            return self
                .initial_close(
                    header.version,
                    addresses,
                    &crypto,
                    &header.src_cid,
                    TransportError::INVALID_TOKEN(""),
                    buf,
                )
                .map(DatagramEvent::Response);
        };

        let deadline = event.now.checked_add(self.config.handshake_timeout)?;
        let admission = match self.admission.arrive(
            event.now,
            server_config.admission.as_ref(),
            addresses.remote.ip(),
            token.validated,
        ) {
            Decision::Admit(lease) => lease,
            Decision::Retry if self.local_cid_generator.cid_len() == 0 => {
                // Without local connection IDs the client's follow-up Initials to a Retry carry
                // an empty destination and could not find the pending attempt.
                self.admission_stats.refused_unvalidated += 1;
                debug!(remote = %addresses.remote, "under load: refusing unvalidated attempt without local connection ids");
                return self
                    .initial_close(
                        header.version,
                        addresses,
                        &crypto,
                        &header.src_cid,
                        TransportError::CONNECTION_REFUSED(""),
                        buf,
                    )
                    .map(DatagramEvent::Response);
            }
            Decision::Retry => {
                // The driver keeps the receiving socket for the token's lifetime, so the
                // client's return must be representable on its clock.
                if event
                    .now
                    .checked_add(server_config.retry_token_lifetime)
                    .is_none()
                {
                    debug!("retry token lifetime exceeds the clock; attempt dropped under load");
                    return None;
                }
                trace!(remote = %addresses.remote, "under load: answering unvalidated attempt with Retry");
                let transmit = self
                    .retry_packet(&server_config, addresses, &header, buf)
                    .ok()?;
                self.admission_stats.retried += 1;
                return Some(DatagramEvent::Retry(transmit));
            }
            Decision::Refuse(refusal) => {
                match refusal {
                    Refusal::Limit => self.admission_stats.refused_at_limit += 1,
                    Refusal::Source => self.admission_stats.refused_per_source += 1,
                }
                debug!(remote = %addresses.remote, ?refusal, "under load: refusing attempt");
                return self
                    .initial_close(
                        header.version,
                        addresses,
                        &crypto,
                        &header.src_cid,
                        TransportError::CONNECTION_REFUSED(""),
                        buf,
                    )
                    .map(DatagramEvent::Response);
            }
        };
        let progress = Arc::new(IncomingProgress::new());
        let incoming_idx = self.incoming_buffers.insert(IncomingBuffer {
            deadline,
            dst_cid: header.dst_cid,
            datagrams: Vec::new(),
            total_bytes: 0,
            progress: progress.clone(),
            hello: HelloAssembly::default(),
            admission,
            accepting: None,
            observation,
        });
        let resolving = matches!(server_config.crypto, ServerCrypto::Resolver(_))
            .then(|| server_config.clone());
        self.incoming_deadlines.insert((deadline, incoming_idx));
        self.index
            .insert_initial_incoming(header.dst_cid, incoming_idx);

        Some(DatagramEvent::NewConnection(Incoming {
            received_at: event.now,
            addresses,
            ecn: event.ecn,
            packet: InitialPacket {
                header,
                header_data: packet.header_data,
                payload: packet.payload,
                allocated: packet.allocated,
            },
            rest: event.remaining,
            crypto,
            token,
            incoming_idx,
            deadline,
            progress,
            resolving,
            improper_drop_warner: ImproperDropWarner::armed(
                "Incoming dropped without passing to Endpoint::accept/refuse/retry/ignore \
                 (may cause memory leak and eventual inability to accept new connections)",
            ),
        }))
    }

    /// Attempt to accept this incoming connection (an error may still occur).
    ///
    /// [`Self::start_accept`], [`Accepting::accept`] and [`Self::finish_accept`] in one go.
    /// The attempt's admission lease comes with the connection: it stays in progress until
    /// its handshake completes or fails.
    #[cfg(test)]
    pub(crate) fn accept(
        &mut self,
        incoming: Incoming,
        now: Instant,
        buf: &mut Vec<u8>,
        server_config: Option<Arc<ServerConfig>>,
    ) -> Result<(ConnectionHandle, Connection, AdmissionLease), AcceptError> {
        let accepting = self.start_accept(incoming, now, buf, server_config)?;
        self.finish_accept(accepting.accept(), buf)
            .map(Registered::replayed)
    }

    /// Begin accepting an attempt with the part that needs the endpoint: validation and the
    /// connection's identifiers, which route to the attempt's incoming buffer meanwhile so
    /// its datagrams keep collecting there. TLS setup and first-flight processing are left to
    /// [`Accepting::accept`], which needs no endpoint; its outcome goes to
    /// [`Self::finish_accept`] or [`Self::abandon_accept`]. Until then the attempt stays
    /// pending: in progress for admission, and expired or discarded like any other.
    ///
    /// On error nothing stays reserved.
    pub(crate) fn start_accept(
        &mut self,
        mut incoming: Incoming,
        now: Instant,
        buf: &mut Vec<u8>,
        server_config: Option<Arc<ServerConfig>>,
    ) -> Result<Accepting, AcceptError> {
        let remote_address_validated = incoming.remote_address_validated();
        if incoming.is_expired() || now >= incoming.deadline {
            return Err(self.reject_accept(incoming, ConnectionError::TimedOut, None));
        }
        let Some(server_config) = server_config.or_else(|| self.server_config.clone()) else {
            return Err(self.reject_accept(incoming, ConnectionError::LocallyClosed, None));
        };
        // The application may supply a different server configuration at accept; a local
        // setup error releases the attempt without answering the client.
        if let Err(error) = server_config
            .transport
            .wire
            .validate_endpoint(&self.config, self.local_cid_generator.cid_len())
        {
            let cause =
                ConnectionError::TransportError(TransportError::INTERNAL_ERROR(error.to_string()));
            return Err(self.reject_accept(incoming, cause, None));
        }

        let packet_number = incoming.packet.header.number.expand(0);
        let InitialHeader {
            src_cid,
            dst_cid,
            version: wire_version,
            ..
        } = incoming.packet.header;
        let version = wire_version.version();
        if server_config
            .transport
            .max_idle_timeout
            .is_some_and(|timeout| {
                incoming.received_at + Duration::from_millis(timeout.into()) <= now
            })
        {
            debug!("abandoning accept of stale initial");
            return Err(self.reject_accept(incoming, ConnectionError::TimedOut, None));
        }

        let refusal = if self.cids_exhausted() {
            Some(ConnectionError::CidsExhausted)
        } else if self.zero_cid_client_route_in_use(incoming.addresses.remote)
            || self.zero_cid_incoming_route_in_use(&incoming.addresses)
            || self.exclusive_connection.is_some()
        {
            Some(ConnectionError::EndpointInUse)
        } else {
            None
        };
        if let Some(refusal) = refusal {
            debug!("refusing connection");
            let response = self.initial_close(
                wire_version,
                incoming.addresses,
                &incoming.crypto,
                &src_cid,
                TransportError::CONNECTION_REFUSED(""),
                buf,
            );
            return Err(self.reject_accept(incoming, refusal, response));
        }

        if let Some(incoming_buffer) = self.incoming_buffers.get_mut(incoming.incoming_idx) {
            let datagrams_complete = incoming_buffer
                .observation
                .as_ref()
                .is_some_and(|observation| observation.datagrams_complete());
            incoming_buffer.observation = server_config.capture.map(|limits| {
                let mut observation = Box::new(ServerObservation::new_parts(
                    limits,
                    &[
                        &incoming.packet.header_data,
                        &incoming.packet.payload,
                        incoming.rest.as_deref().unwrap_or_default(),
                    ],
                ));
                // Capture enabled only at accept cannot account for earlier buffer drops.
                if !datagrams_complete {
                    observation.lost_datagram();
                }
                observation
            });
        }

        if incoming.crypto.remote.as_ref().is_none_or(|keys| {
            keys.packet
                .decrypt(
                    packet_number,
                    &incoming.packet.header_data,
                    &mut incoming.packet.payload,
                )
                .is_err()
        }) {
            debug!(packet_number, "failed to authenticate initial packet");
            return Err(self.reject_accept(
                incoming,
                TransportError::PROTOCOL_VIOLATION("authentication failed").into(),
                None,
            ));
        };

        // RFC 9368 §2.3: a server that prefers another compatible version needs the client's
        // offer, which is in the ClientHello. It is looked for in what has arrived so far; a
        // ClientHello still incomplete leaves the connection in the client's version.
        let negotiated = if matches!(
            &server_config.crypto,
            ServerCrypto::Fixed(crypto) if crypto.supports_compatible_negotiation()
        ) && server_config.versions.may_switch()
        {
            let flight = FirstFlight {
                version,
                crypto: &incoming.crypto,
                rest: incoming.rest.as_ref(),
                parser: FixedLengthConnectionIdParser::new(self.local_cid_generator.cid_len()),
                grease_quic_bit: self.config.grease_quic_bit,
            };
            let offer = self
                .incoming_buffers
                .get_mut(incoming.incoming_idx)
                .and_then(|buffer| client_offer(&flight, &incoming.packet.payload, buffer));
            match offer {
                // A ticket belongs to the version the client initiated in, and a ticket this
                // connection issues would belong to the negotiated one (RFC 9369 §5); no TLS
                // stack serves both from one session, so a resuming client keeps its version.
                Some(offer) if !offer.resuming => server_config.versions.negotiate(
                    version,
                    Some(&offer.available),
                    &self.config.supported_versions,
                ),
                _ => version,
            }
        } else {
            version
        };
        if negotiated != version {
            trace!(from = %version, to = %negotiated, "compatible version negotiation");
        }

        let route = RouteDatagramTo::Incoming(incoming.incoming_idx);
        let loc_cid = self.new_cid(route);
        let mut params = transport_parameters::new(
            &server_config.transport,
            &self.config,
            self.local_cid_generator.as_ref(),
            loc_cid,
            Some(&server_config),
            &mut self.rng,
        );
        params.stateless_reset_token = Some(reset_token(&self.config.reset_key, loc_cid));
        params.original_dst_cid = Some(incoming.token.orig_dst_cid);
        params.retry_src_cid = incoming.token.retry_src_cid;
        params.version_information = Some(server_config.versions.information(
            negotiated,
            &self.config.supported_versions,
            Version::grease(negotiated),
        ));
        let mut pref_addr_cid = None;
        // A preferred address needs an identifier of its own (RFC 9000 §5.1.1), so an endpoint
        // whose connection IDs are zero length keeps its clients where they are.
        if server_config.has_preferred_address() && self.local_cid_generator.cid_len() != 0 {
            let cid = self.new_cid(route);
            pref_addr_cid = Some(cid);
            params.preferred_address = Some(PreferredAddress {
                address_v4: server_config.preferred_address_v4,
                address_v6: server_config.preferred_address_v6,
                connection_id: cid,
                stateless_reset_token: reset_token(&self.config.reset_key, cid),
            });
        }
        let cids = AcceptCids {
            local: loc_cid,
            preferred: pref_addr_cid,
        };
        // The buffer owns the minted identifiers from here: whoever removes it retires them.
        let Some(buffer) = self.incoming_buffers.get_mut(incoming.incoming_idx) else {
            self.index.retire_accept(cids);
            return Err(self.reject_accept(incoming, ConnectionError::TimedOut, None));
        };
        buffer.accepting = Some(cids);
        let mut observation = buffer.observation.take();
        if let Some(observation) = &mut observation {
            observation.identify(
                loc_cid,
                dst_cid,
                incoming.token.orig_dst_cid,
                incoming.token.retry_src_cid.is_some(),
            );
        }
        // What already arrived is processed with the first packet, so a ClientHello spanning
        // several Initials completes there; its bytes stay charged until the accept settles.
        let early = mem::take(&mut buffer.datagrams);
        let mut rng_seed = [0; 32];
        self.rng.fill_bytes(&mut rng_seed);
        let Incoming {
            received_at,
            addresses,
            ecn,
            packet,
            rest,
            crypto,
            token,
            incoming_idx,
            progress,
            improper_drop_warner,
            ..
        } = incoming;
        improper_drop_warner.dismiss();
        Ok(Accepting {
            reservation: Reservation {
                incoming_idx,
                progress,
                init_cid: dst_cid,
                src_cid,
                cids,
                addresses,
                wire_version,
                crypto,
                improper_drop_warner: ImproperDropWarner::armed(
                    "Accepting or Accepted dropped without Endpoint::finish_accept/abandon_accept \
                     (its identifiers and buffered datagrams stay until the attempt's deadline)",
                ),
            },
            endpoint_config: self.config.clone(),
            server_config,
            version,
            negotiated,
            params,
            cid_len: self.local_cid_generator.cid_len(),
            cid_lifetime: self.local_cid_generator.cid_lifetime(),
            allow_mtud: self.allow_mtud,
            rng_seed,
            received_at,
            ecn,
            packet_number,
            packet,
            rest,
            early,
            observation,
            path_validated: remote_address_validated,
            orig_dst_cid: token.orig_dst_cid,
        })
    }

    /// Complete an accept begun by [`Self::start_accept`]: register the connection and hand
    /// back the datagrams that arrived for it since, or release what was reserved and answer
    /// the client with the failure. An attempt that expired or was discarded while its
    /// handshake ran fails as timed out; its reservation went with it.
    pub(crate) fn finish_accept(
        &mut self,
        accepted: Accepted,
        buf: &mut Vec<u8>,
    ) -> Result<Registered, AcceptError> {
        let Accepted {
            reservation,
            result,
        } = accepted;
        let Reservation {
            incoming_idx,
            progress,
            init_cid,
            src_cid,
            cids,
            addresses,
            wire_version,
            crypto,
            improper_drop_warner,
        } = reservation;
        improper_drop_warner.dismiss();
        let buffer = self.take_buffer(incoming_idx, &progress);
        // An attempt that started before another from its addresses was established.
        let result = result.and_then(|conn| {
            if self.zero_cid_incoming_route_in_use(&addresses) {
                Err(ConnectionError::TransportError(
                    TransportError::CONNECTION_REFUSED("addresses in use"),
                ))
            } else {
                Ok(conn)
            }
        });
        match (result, buffer) {
            (Ok(conn), Some(buffer)) => {
                // Install address routes only after TLS and the first flight succeeded. A
                // failed fresh handshake must not displace an established zero-CID route.
                let ch = ConnectionHandle(self.connections.vacant_key());
                self.register_connection(
                    ch,
                    init_cid,
                    cids.local,
                    cids.preferred,
                    addresses,
                    Side::Server,
                    conn.remote_cid_limit(),
                );
                self.index.insert_initial(init_cid, ch);
                trace!(id = ch.0, icid = %init_cid, "new connection");
                let IncomingBuffer {
                    datagrams,
                    admission,
                    ..
                } = buffer;
                Ok(Registered {
                    handle: ch,
                    connection: conn,
                    admission,
                    late: datagrams
                        .into_iter()
                        .map(|event| ConnectionEvent(ConnectionEventInner::Datagram(event)))
                        .collect(),
                })
            }
            (result, buffer) => {
                let cause = result.err().unwrap_or(ConnectionError::TimedOut);
                debug!("handshake failed: {}", cause);
                let response = match (&cause, &buffer) {
                    (ConnectionError::TransportError(error), Some(_)) => self.initial_close(
                        wire_version,
                        addresses,
                        &crypto,
                        &src_cid,
                        error.clone(),
                        buf,
                    ),
                    _ => None,
                };
                if let Some(buffer) = buffer {
                    self.release_routes(&buffer);
                }
                Err(AcceptError { cause, response })
            }
        }
    }

    /// Release an accept begun by [`Self::start_accept`] without completing it or answering
    /// the client, as the endpoint stopped while its handshake ran.
    pub(crate) fn abandon_accept(&mut self, accepted: Accepted) {
        let Reservation {
            incoming_idx,
            progress,
            improper_drop_warner,
            ..
        } = accepted.reservation;
        improper_drop_warner.dismiss();
        if let Some(buffer) = self.take_buffer(incoming_idx, &progress) {
            self.release_routes(&buffer);
        }
    }

    /// Settle an attempt that cannot be accepted before anything was reserved for it.
    fn reject_accept(
        &mut self,
        incoming: Incoming,
        cause: ConnectionError,
        response: Option<Transmit>,
    ) -> AcceptError {
        self.clean_up_incoming(&incoming);
        incoming.improper_drop_warner.dismiss();
        AcceptError { cause, response }
    }

    /// The client's ClientHello, as far as the first flight of a pending attempt has
    /// arrived, without accepting the attempt.
    pub(crate) fn client_hello(&mut self, incoming: &Incoming) -> ClientHelloPeek {
        if incoming.is_expired() {
            return ClientHelloPeek::Invalid;
        }
        let flight = FirstFlight {
            version: incoming.packet.header.version.version(),
            crypto: &incoming.crypto,
            rest: incoming.rest.as_ref(),
            parser: FixedLengthConnectionIdParser::new(self.local_cid_generator.cid_len()),
            grease_quic_bit: self.config.grease_quic_bit,
        };
        let Some(buffer) = self.incoming_buffers.get_mut(incoming.incoming_idx) else {
            return ClientHelloPeek::Invalid;
        };
        // The first packet stays protected until accepted, so a copy is opened.
        let first = || {
            let keys = incoming.crypto.remote.as_ref()?;
            let mut payload = incoming.packet.payload.clone();
            keys.packet
                .decrypt(
                    incoming.packet.header.number.expand(0),
                    &incoming.packet.header_data,
                    &mut payload,
                )
                .ok()?;
            Some(payload.freeze())
        };
        assemble_client_hello(&mut buffer.hello, &buffer.datagrams, &flight, first)
    }

    /// Wake every application waiting on a pending attempt: none of them will progress.
    pub(crate) fn wake_pending_incoming(&self) {
        for (_, buffer) in &self.incoming_buffers {
            buffer.progress.advance();
        }
    }

    /// Check if we should refuse a connection attempt regardless of the packet's contents
    fn early_validate_first_packet(
        &self,
        header: &ProtectedInitialHeader,
    ) -> Result<(), TransportError> {
        // RFC9000 §7.2 dictates that initial (client-chosen) destination CIDs must be at least 8
        // bytes. If this is a Retry packet, then the length must instead match our usual CID
        // length. If we ever issue non-Retry address validation tokens via `NEW_TOKEN`, then we'll
        // also need to validate CID length for those after decoding the token.
        if header.dst_cid.len() < 8
            && (header.token_pos.is_empty()
                || header.dst_cid.len() != self.local_cid_generator.cid_len())
        {
            debug!(
                "rejecting connection due to invalid DCID length {}",
                header.dst_cid.len()
            );
            return Err(TransportError::PROTOCOL_VIOLATION(
                "invalid destination CID length",
            ));
        }

        Ok(())
    }

    /// Reject this incoming connection attempt
    pub(crate) fn refuse(&mut self, incoming: Incoming, buf: &mut Vec<u8>) -> Option<Transmit> {
        self.clean_up_incoming(&incoming);
        incoming.improper_drop_warner.dismiss();

        self.initial_close(
            incoming.packet.header.version,
            incoming.addresses,
            &incoming.crypto,
            &incoming.packet.header.src_cid,
            TransportError::CONNECTION_REFUSED(""),
            buf,
        )
    }

    /// Respond with a retry packet, requiring the client to retry with address validation
    ///
    /// Errors if `incoming.may_retry()` is false.
    pub(crate) fn retry(
        &mut self,
        incoming: Incoming,
        buf: &mut Vec<u8>,
    ) -> Result<Transmit, RetryError> {
        if !incoming.may_retry() {
            return Err(RetryError::new(incoming, RetryRefused::AlreadyRetried));
        }

        let Some(server_config) = self.server_config.clone() else {
            return Err(RetryError::new(incoming, RetryRefused::NoServerConfig));
        };

        // The packet is sealed before the attempt is touched, so a provider failure hands the
        // attempt back intact for the application to accept, refuse or ignore instead.
        let transmit = match self.retry_packet(
            &server_config,
            incoming.addresses,
            &incoming.packet.header,
            buf,
        ) {
            Ok(transmit) => transmit,
            Err(reason) => return Err(RetryError::new(incoming, reason)),
        };
        self.clean_up_incoming(&incoming);
        incoming.improper_drop_warner.dismiss();
        Ok(transmit)
    }

    /// Write a Retry answering the Initial `header` that arrived from `addresses` into `buf`
    /// (RFC 9000 §8.1.2). Nothing is left in `buf` when it fails.
    fn retry_packet(
        &mut self,
        server_config: &ServerConfig,
        addresses: FourTuple,
        header: &InitialHeader,
        buf: &mut Vec<u8>,
    ) -> Result<Transmit, RetryRefused> {
        let payload = TokenPayload::Retry {
            address: addresses.remote,
            orig_dst_cid: header.dst_cid,
            issued: server_config.time_source.now(),
            version: header.version.version(),
        };
        let token = match Token::new(payload, &mut self.rng).encode(&*server_config.token_key) {
            Ok(token) => token,
            Err(error) => {
                debug!(%error, "retry token could not be sealed");
                return Err(RetryRefused::TokenSealing);
            }
        };

        // The peer will use this as the DCID of its following Initials. Initial DCIDs are
        // looked up separately from Handshake/Data DCIDs, so there is no risk of collision
        // with established connections. In the unlikely event that a collision occurs
        // between two connections in the initial phase, both will fail fast and may be
        // retried by the application layer.
        let loc_cid = self.local_cid_generator.generate_cid();

        let retry = Header::Retry {
            src_cid: loc_cid,
            dst_cid: header.src_cid,
            version: header.version,
        };

        let original_len = buf.len();
        retry.encode(buf);
        buf.put_slice(&token);
        let tag = match server_config.crypto.initial().retry_tag(
            header.version.version(),
            &header.dst_cid,
            &buf[original_len..],
        ) {
            Ok(tag) => tag,
            Err(error) => {
                debug!(%error, "retry integrity protection failed");
                buf.truncate(original_len);
                return Err(RetryRefused::IntegrityProtection);
            }
        };
        buf.extend_from_slice(&tag);

        Ok(Transmit {
            destination: addresses.remote,
            ecn: None,
            size: buf.len(),
            segment_size: None,
            local: addresses.local,
            cid_used: None,
        })
    }

    /// Ignore this incoming connection attempt, not sending any packet in response
    ///
    /// This promptly retires the endpoint's pending state. Otherwise that state
    /// remains until the handshake deadline or endpoint shutdown.
    pub(crate) fn ignore(&mut self, incoming: Incoming) {
        self.clean_up_incoming(&incoming);
        incoming.improper_drop_warner.dismiss();
    }

    /// Clean up endpoint data structures associated with an `Incoming`.
    fn clean_up_incoming(&mut self, incoming: &Incoming) {
        if let Some(buffer) = self.take_buffer(incoming.incoming_idx, &incoming.progress) {
            self.release_routes(&buffer);
        }
    }

    /// Remove the routes a removed incoming buffer received datagrams by.
    fn release_routes(&mut self, buffer: &IncomingBuffer) {
        self.index.remove_initial(buffer.dst_cid);
        if let Some(cids) = buffer.accepting {
            self.index.retire_accept(cids);
        }
    }

    fn take_buffer(&mut self, index: usize, progress: &IncomingProgress) -> Option<IncomingBuffer> {
        // An expired attempt may outlive its slot and must never remove its replacement.
        if !progress.retire() {
            return None;
        }
        let buffer = self.incoming_buffers.remove(index);
        self.incoming_deadlines.remove(&(buffer.deadline, index));
        self.all_incoming_buffers_total_bytes -= buffer.total_bytes;
        Some(buffer)
    }

    pub(crate) fn pending_incoming(&self) -> usize {
        self.incoming_buffers.len()
    }

    /// Earliest pending admission deadline, for the endpoint driver's real timer.
    pub(crate) fn poll_incoming_timeout(&self) -> Option<Instant> {
        self.incoming_deadlines.first().map(|entry| entry.0)
    }

    /// Expire a bounded number of pending handshakes without requiring application polling.
    pub(crate) fn expire_incoming(&mut self, now: Instant, limit: usize) -> usize {
        let mut expired = 0;
        while expired < limit {
            let Some(&(deadline, index)) = self.incoming_deadlines.first() else {
                break;
            };
            if deadline > now {
                break;
            }
            self.incoming_deadlines.pop_first();
            self.discard_incoming_buffer(index);
            expired += 1;
        }
        expired
    }

    /// Retire pending admission state during shutdown; application-held handles become stale.
    pub(crate) fn discard_incoming(&mut self, limit: usize) {
        for _ in 0..limit {
            let Some((_, index)) = self.incoming_deadlines.pop_first() else {
                break;
            };
            self.discard_incoming_buffer(index);
        }
    }

    /// Release every pending admission regardless of the deadline index.
    ///
    /// Only the shutdown supervisor uses this, after `discard_incoming` stopped making
    /// progress; the work is bounded by the number of live admissions.
    pub(crate) fn discard_all_incoming(&mut self) {
        self.incoming_deadlines.clear();
        let indices: Vec<usize> = self
            .incoming_buffers
            .iter()
            .map(|(index, _)| index)
            .collect();
        for index in indices {
            self.discard_incoming_buffer(index);
        }
    }

    /// Test seam: break the invariant that every pending admission has a deadline entry.
    #[cfg(test)]
    pub(crate) fn forget_incoming_deadlines(&mut self) {
        self.incoming_deadlines.clear();
    }

    fn discard_incoming_buffer(&mut self, index: usize) {
        let buffer = self.incoming_buffers.remove(index);
        buffer.progress.retire();
        buffer.progress.advance();
        self.all_incoming_buffers_total_bytes -= buffer.total_bytes;
        self.release_routes(&buffer);
    }

    fn add_connection(
        &mut self,
        ch: ConnectionHandle,
        version: Version,
        init_cid: ConnectionId,
        loc_cid: ConnectionId,
        rem_cid: ConnectionId,
        addresses: FourTuple,
        now: Instant,
        tls: Box<dyn crypto::Session>,
        transport_config: Arc<TransportConfig>,
        side_args: SideArgs,
    ) -> Result<Connection, TransportError> {
        let mut rng_seed = [0; 32];
        self.rng.fill_bytes(&mut rng_seed);
        let side = side_args.side();
        let pref_addr_cid = side_args.pref_addr_cid();
        let conn = Connection::new(
            self.config.clone(),
            transport_config,
            init_cid,
            loc_cid,
            rem_cid,
            addresses.remote,
            addresses.local,
            tls,
            self.local_cid_generator.cid_len(),
            self.local_cid_generator.cid_lifetime(),
            now,
            version,
            self.allow_mtud,
            rng_seed,
            side_args,
        )?;
        self.register_connection(
            ch,
            init_cid,
            loc_cid,
            pref_addr_cid,
            addresses,
            side,
            conn.remote_cid_limit(),
        );
        Ok(conn)
    }

    /// Record connection `ch` and route its first identifiers (or, when they are zero length,
    /// its addresses) to it, including ones minted for it before it existed. `ch` must be the
    /// slab's vacant key.
    fn register_connection(
        &mut self,
        ch: ConnectionHandle,
        init_cid: ConnectionId,
        loc_cid: ConnectionId,
        pref_addr_cid: Option<ConnectionId>,
        addresses: FourTuple,
        side: Side,
        remote_cid_limit: usize,
    ) {
        let mut cids_issued = 0;
        let mut loc_cids = FxHashMap::default();

        loc_cids.insert(cids_issued, loc_cid);
        cids_issued += 1;

        if let Some(cid) = pref_addr_cid {
            debug_assert_eq!(cids_issued, 1, "preferred address cid seq must be 1");
            loc_cids.insert(cids_issued, cid);
            cids_issued += 1;
        }

        let id = self.connections.insert(ConnectionMeta {
            init_cid,
            cids_issued,
            loc_cids,
            addresses,
            side,
            reset_tokens: UsedResetTokens::new(remote_cid_limit),
        });
        debug_assert_eq!(id, ch.0, "connection handle allocation out of sync");

        self.index.insert_conn(addresses, loc_cid, ch, side);
        if let Some(cid) = pref_addr_cid {
            self.index
                .connection_ids
                .insert(cid, RouteDatagramTo::Connection(ch));
        }
    }

    fn initial_close(
        &mut self,
        version: WireVersion,
        addresses: FourTuple,
        crypto: &Keys,
        remote_id: &ConnectionId,
        reason: TransportError,
        buf: &mut Vec<u8>,
    ) -> Option<Transmit> {
        // We don't need to worry about CID collisions in initial closes because the peer
        // shouldn't respond, and if it does, and the CID collides, we'll just drop the
        // unexpected response.
        let local_id = self.local_cid_generator.generate_cid();
        let number = PacketNumber::U8(0);
        let header = Header::Initial(InitialHeader {
            dst_cid: *remote_id,
            src_cid: local_id,
            number,
            token: Bytes::new(),
            version,
        });

        let partial_encode = header.encode(buf);
        let max_len =
            INITIAL_MTU as usize - partial_encode.header_len - crypto.local.packet.tag_len();
        frame::Close::from(reason).encode(buf, max_len);
        buf.resize(buf.len() + crypto.local.packet.tag_len(), 0);
        if let Err(error) =
            partial_encode.finish(buf, &*crypto.local.header, Some((0, &*crypto.local.packet)))
        {
            debug!(%error, "cannot encrypt initial close");
            buf.clear();
            return None;
        }
        Some(Transmit {
            destination: addresses.remote,
            ecn: None,
            size: buf.len(),
            segment_size: None,
            local: addresses.local,
            cid_used: None,
        })
    }

    /// Access the configuration used by this endpoint
    pub(crate) fn config(&self) -> &EndpointConfig {
        &self.config
    }

    /// Number of connections that are currently open; one still being accepted is not yet.
    pub(crate) fn open_connections(&self) -> usize {
        self.connections.len()
    }

    #[cfg(all(
        test,
        any(
            feature = "boring",
            all(feature = "rustls", any(feature = "aws-lc", feature = "ring"))
        )
    ))]
    /// Counter for the number of bytes currently used
    /// in the buffers for Initial and 0-RTT messages for pending incoming connections
    pub(crate) fn incoming_buffer_bytes(&self) -> u64 {
        self.all_incoming_buffers_total_bytes
    }

    #[cfg(test)]
    pub(crate) fn known_connections(&self) -> usize {
        let x = self.connections.len();
        debug_assert_eq!(x, self.index.connection_ids_initial.len());
        // Not all connections have known reset tokens
        debug_assert!(x >= self.index.connection_reset_tokens.0.len());
        // Not all connections have unique remotes, and 0-length CIDs might not be in use.
        debug_assert!(x >= self.index.incoming_connection_remotes.len());
        debug_assert!(x >= self.index.outgoing_connection_remotes.len());
        x
    }

    #[cfg(test)]
    pub(crate) fn known_cids(&self) -> usize {
        self.index.connection_ids.len()
    }

    /// Tests: the connection IDs a datagram can be addressed to to reach `ch`.
    #[cfg(test)]
    pub(crate) fn cids_routing_to(&self, ch: ConnectionHandle) -> Vec<ConnectionId> {
        self.index
            .connection_ids
            .iter()
            .filter(|&(_, &route)| route == RouteDatagramTo::Connection(ch))
            .map(|(&cid, _)| cid)
            .collect()
    }

    /// A zero-length CID leaves only addresses to distinguish connections, and client routes
    /// lack a local-address key, so a client route to `remote` overlaps every route to that peer.
    fn zero_cid_route_in_use(&self, remote: SocketAddr) -> bool {
        self.zero_cid_client_route_in_use(remote)
            || (self.local_cid_generator.cid_len() == 0
                && self
                    .index
                    .incoming_connection_remotes
                    .keys()
                    .any(|addresses| addresses.remote == remote))
    }

    /// Whether this zero-CID endpoint already routes `addresses` to an accepted connection. A
    /// fresh attempt from them is refused: an unvalidated sender could otherwise take the route
    /// of the connection whose packets it cannot be told apart from.
    fn zero_cid_incoming_route_in_use(&self, addresses: &FourTuple) -> bool {
        self.local_cid_generator.cid_len() == 0
            && self
                .index
                .incoming_connection_remotes
                .contains_key(addresses)
    }

    /// Whether this zero-CID endpoint already dialed `remote`: an incoming connection from that
    /// peer could not be told apart from it.
    fn zero_cid_client_route_in_use(&self, remote: SocketAddr) -> bool {
        self.local_cid_generator.cid_len() == 0
            && self.index.outgoing_connection_remotes.contains_key(&remote)
    }

    /// Whether we've used up 3/4 of the available CID space
    ///
    /// We leave some space unused so that `new_cid` can be relied upon to finish quickly. We don't
    /// bother to check when CID longer than 4 bytes are used because 2^40 connections is a lot.
    fn cids_exhausted(&self) -> bool {
        cid_space_exhausted(
            self.local_cid_generator.cid_len(),
            self.index.connection_ids.len(),
        )
    }
}

/// Whether `in_use` local connection IDs of `cid_len` bytes leave less than a quarter of the ID
/// space free
///
/// Zero-length IDs address a single connection and IDs longer than 4 bytes have a space too large
/// to exhaust, so neither is ever reported exhausted. The arithmetic is 64-bit so 32-bit targets
/// cannot overflow on 4-byte IDs.
fn cid_space_exhausted(cid_len: usize, in_use: usize) -> bool {
    if cid_len == 0 || cid_len > 4 {
        return false;
    }
    let bits = (cid_len * 8) as u32;
    let space = 1u64 << bits;
    let reserve = 1u64 << (bits - 2);
    in_use as u64 > space - reserve
}

#[cfg(test)]
mod tests {
    use std::net::SocketAddr;

    use super::{
        ConnectionHandle, ConnectionId, ConnectionIndex, ConnectionMeta, FourTuple, FxHashMap,
        Installed, RESET_TOKEN_SIZE, ResetToken, Side, UsedResetTokens, cid_space_exhausted,
    };

    #[test]
    fn retiring_connection_removes_only_its_own_address_routes() {
        for side in [Side::Client, Side::Server] {
            for replaced in [false, true] {
                let mut index = ConnectionIndex::default();
                let addresses = FourTuple {
                    remote: "127.0.0.1:1234".parse().unwrap(),
                    local: Some("127.0.0.1:5678".parse().unwrap()),
                };
                let cid = ConnectionId::new(&[]);
                let old = ConnectionHandle(0);
                let replacement = ConnectionHandle(1);
                index.insert_conn(addresses, cid, old, side);
                if replaced {
                    index.insert_conn(addresses, cid, replacement, side);
                }
                let meta = ConnectionMeta {
                    init_cid: cid,
                    cids_issued: 0,
                    loc_cids: FxHashMap::default(),
                    addresses,
                    side,
                    reset_tokens: UsedResetTokens::default(),
                };
                index.remove_routes(old, &meta);
                let remaining = if side.is_server() {
                    index.incoming_connection_remotes.get(&addresses)
                } else {
                    index.outgoing_connection_remotes.get(&addresses.remote)
                };
                assert_eq!(remaining.copied(), replaced.then_some(replacement));
            }
        }
    }

    fn addr(last: u8) -> SocketAddr {
        SocketAddr::from(([127, 0, 0, last], 4433))
    }

    fn token(n: u8) -> ResetToken {
        ResetToken::from([n; RESET_TOKEN_SIZE])
    }

    /// The routing table follows the engine: a release frees the slot it took, an installation of
    /// a pair already held is not a second route, and a release still naming an older
    /// installation cannot take away the one that replaced it.
    #[test]
    fn a_route_is_released_only_by_the_installation_that_owns_it() {
        let mut routes = UsedResetTokens::default();
        assert_eq!(
            routes.insert(1, addr(1), token(1), 10),
            Installed::New,
            "a new route"
        );
        assert_eq!(
            routes.insert(1, addr(1), token(1), 11),
            Installed::Refreshed,
            "the same pair again is not a second route"
        );
        assert!(
            !routes.release(1, addr(1), 10),
            "a release naming the installation that was replaced does nothing"
        );
        assert_eq!(routes.iter().count(), 1, "so the live route is still there");
        assert!(
            routes.release(1, addr(1), 11),
            "the installation that owns it can release it"
        );
        assert_eq!(routes.iter().count(), 0);
        assert!(
            !routes.release(1, addr(1), 11),
            "and releasing it twice is not a route"
        );

        // The same identifier at two addresses is two routes, and one does not remove the other.
        assert_eq!(routes.insert(2, addr(1), token(2), 20), Installed::New);
        assert_eq!(routes.insert(2, addr(2), token(2), 21), Installed::New);
        assert_eq!(routes.iter().count(), 2);
        assert!(routes.release(2, addr(1), 20));
        assert_eq!(routes.iter().count(), 1);
        assert!(
            routes.iter().any(|(remote, _)| remote == addr(2)),
            "the other address keeps its route"
        );

        // Retirement takes every route the identifier had, at every address.
        assert_eq!(routes.insert(3, addr(3), token(3), 30), Installed::New);
        assert_eq!(routes.insert(3, addr(4), token(3), 31), Installed::New);
        let removed = routes.remove_range(3..4).count();
        assert_eq!(removed, 2, "both of the retired identifier's routes go");
        assert_eq!(routes.iter().count(), 1);
    }

    /// A table with no room reports it, so the caller can refuse rather than acknowledge a route
    /// that is not there. This is the `Full` the endpoint turns into a refusal.
    #[test]
    fn a_full_table_reports_that_it_installed_nothing() {
        for limit in [2, 5, 8, 64] {
            assert!(!UsedResetTokens::new(limit).entries.spilled());
        }
        let mut routes = UsedResetTokens::default();
        assert!(
            std::mem::size_of::<UsedResetTokens>()
                <= 57 * std::mem::size_of::<Option<super::Association>>() + 32
        );
        let slots = super::CidQueue::INLINE_PRESENT * super::RemCid::REMOTES;
        for step in 0..slots {
            assert_eq!(
                routes.insert(step as u64, addr(1), token(step as u8), step as u64),
                Installed::New,
                "slot {step} of {slots}"
            );
        }
        assert_eq!(routes.iter().count(), slots, "the table is full");
        assert_eq!(
            routes.insert(9_999, addr(2), token(7), 9_999),
            Installed::Full,
            "one more route is refused, not squeezed in"
        );
        assert_eq!(
            routes.iter().count(),
            slots,
            "and nothing live was evicted to make room"
        );
        // Releasing one makes room again, so a refusal is about the moment, not the connection.
        assert!(routes.release(0, addr(1), 0));
        assert_eq!(
            routes.insert(9_999, addr(2), token(7), 9_999),
            Installed::New
        );
    }

    /// The engine releases what it displaces, so far more moves than this table has slots still
    /// leave it holding only what is live. This is the endpoint half of the accumulation the
    /// review reproduced: a queue invariant alone cannot show it.
    #[test]
    fn releasing_before_installing_keeps_the_table_from_filling() {
        let mut routes = UsedResetTokens::default();
        let slots = super::CidQueue::INLINE_PRESENT * super::RemCid::REMOTES;
        let home = addr(1);
        assert_eq!(routes.insert(1, home, token(1), 0), Installed::New);
        // One identifier, forty different addresses, two of them always live.
        let mut previous: Option<(SocketAddr, u64)> = None;
        for step in 0..40u64 {
            let remote = addr(10 + step as u8);
            let generation = step + 1;
            assert_eq!(
                routes.insert(1, remote, token(1), generation),
                Installed::New,
                "step {step} installs"
            );
            if let Some((old, old_generation)) = previous.replace((remote, generation)) {
                assert!(
                    routes.release(1, old, old_generation),
                    "step {step} releases the one it displaced"
                );
            }
            assert!(
                routes.iter().count() <= 3,
                "step {step} left {} routes in a table of {slots}",
                routes.iter().count()
            );
        }
        assert!(routes.iter().any(|(remote, _)| remote == home));
    }

    #[test]
    fn cid_space_exhaustion_thresholds() {
        // A quarter of the space is always kept in reserve so `new_cid` stays fast
        for (len, threshold) in [
            (1usize, 192usize),
            (2, 49_152),
            (3, 12_582_912),
            (4, 3_221_225_472),
        ] {
            assert!(!cid_space_exhausted(len, 0));
            assert!(
                !cid_space_exhausted(len, threshold),
                "{len}-byte IDs: {threshold} in use still fit"
            );
            assert!(
                cid_space_exhausted(len, threshold + 1),
                "{len}-byte IDs: {} exhaust the space",
                threshold + 1
            );
        }
        // Zero-length and longer IDs are never exhausted, whatever the count
        for len in [0usize, 5, 8, 20] {
            assert!(!cid_space_exhausted(len, 0));
            assert!(!cid_space_exhausted(len, usize::MAX));
        }
    }
}

impl fmt::Debug for Endpoint {
    fn fmt(&self, fmt: &mut fmt::Formatter<'_>) -> fmt::Result {
        fmt.debug_struct("Endpoint")
            .field("rng", &self.rng)
            .field("index", &self.index)
            .field("connections", &self.connections)
            .field("config", &self.config)
            .field("server_config", &self.server_config)
            // incoming_buffers too large
            .field("incoming_buffers.len", &self.incoming_buffers.len())
            .field(
                "all_incoming_buffers_total_bytes",
                &self.all_incoming_buffers_total_bytes,
            )
            .finish()
    }
}

/// Buffered Initial and 0-RTT messages for a pending incoming connection
struct IncomingBuffer {
    deadline: Instant,
    dst_cid: ConnectionId,
    datagrams: Vec<DatagramConnectionEvent>,
    total_bytes: u64,
    progress: Arc<IncomingProgress>,
    /// The ClientHello taken in so far, packet by packet.
    hello: HelloAssembly,
    /// The attempt's place among those in progress: released with this buffer, or carried on
    /// by the connection it is accepted as.
    admission: AdmissionLease,
    /// The identifiers minted once acceptance began, which route here until the connection is
    /// registered and are retired with this buffer when it never is.
    accepting: Option<AcceptCids>,
    observation: Option<Box<ServerObservation>>,
}

/// The local connection IDs an accept mints for its connection.
#[derive(Debug, Clone, Copy)]
struct AcceptCids {
    local: ConnectionId,
    /// For the preferred address, when one is advertised.
    preferred: Option<ConnectionId>,
}

/// What the client's ClientHello says about versions, when the whole ClientHello has arrived in
/// the first packet and what was buffered behind it (RFC 9368 §2.3).
///
/// The first packet of the attempt is already opened.
fn client_offer(
    flight: &FirstFlight<'_>,
    first_payload: &BytesMut,
    buffer: &mut IncomingBuffer,
) -> Option<ClientOffer> {
    let ClientHelloPeek::Complete(message) =
        assemble_client_hello(&mut buffer.hello, &buffer.datagrams, flight, || {
            Some(first_payload.clone().freeze())
        })
    else {
        return None;
    };
    let hello = message.client_hello();
    let resuming = hello
        .extensions()
        .iter()
        .any(|ext| ext.id() == ExtensionId::PRE_SHARED_KEY);
    let params = hello.extensions().iter().find_map(|ext| match ext {
        ClientHelloExtension::Opaque { id, data }
            if *id == ExtensionId::QUIC_TRANSPORT_PARAMETERS =>
        {
            Some(data)
        }
        _ => None,
    })?;
    let available = TransportParameters::read(Side::Server, &mut &params[..])
        .ok()?
        .version_information?
        .available()
        .to_vec();
    Some(ClientOffer {
        available,
        resuming,
    })
}

/// Take a pending attempt's Initial packets into its ClientHello assembly: the first packet
/// (`first` opens it) and what was coalesced behind it once, then each datagram buffered
/// since the previous look.
struct FirstFlight<'a> {
    version: Version,
    crypto: &'a Keys,
    /// What was coalesced behind the first packet.
    rest: Option<&'a BytesMut>,
    parser: FixedLengthConnectionIdParser,
    grease_quic_bit: bool,
}

/// What buffering a datagram for a pending connection holds: its bytes and its entry, so a
/// flood of tiny datagrams is charged for what it occupies.
pub(crate) fn incoming_datagram_charge(datagram_len: usize) -> u64 {
    datagram_len.saturating_add(size_of::<DatagramConnectionEvent>()) as u64
}

fn assemble_client_hello(
    assembly: &mut HelloAssembly,
    datagrams: &[DatagramConnectionEvent],
    flight: &FirstFlight<'_>,
    first: impl FnOnce() -> Option<Bytes>,
) -> ClientHelloPeek {
    if !assembly.started {
        let Some(payload) = first() else {
            return ClientHelloPeek::Invalid;
        };
        take_in_frames(assembly, payload);
        if let Some(rest) = flight.rest {
            take_in_initials(assembly, rest.clone(), flight);
        }
        assembly.started = true;
    }
    for event in datagrams.get(assembly.taken..).unwrap_or_default() {
        take_in_initials(assembly, BytesMut::from(event.first_decode.data()), flight);
        if let Some(rest) = &event.remaining {
            take_in_initials(assembly, rest.clone(), flight);
        }
    }
    assembly.taken = datagrams.len();
    assembly.peek()
}

/// Open the Initial packets of a datagram copy and take in their CRYPTO frames.
fn take_in_initials(assembly: &mut HelloAssembly, mut bytes: BytesMut, flight: &FirstFlight<'_>) {
    let Some(keys) = flight.crypto.remote.as_ref() else {
        return;
    };
    let allocated = bytes.len();
    loop {
        let Ok((decode, rest)) = PartialDecode::new_within(
            bytes,
            allocated,
            &flight.parser,
            &[flight.version],
            flight.grease_quic_bit,
        ) else {
            return;
        };
        if decode.is_initial()
            && let Ok(mut packet) = decode.finish_protected(&*keys.header)
            && let Some(number) = packet.header.number()
            && keys
                .packet
                .decrypt(number.expand(0), &packet.header_data, &mut packet.payload)
                .is_ok()
        {
            take_in_frames(assembly, packet.payload.freeze());
        }
        match rest {
            Some(rest) => bytes = rest,
            None => return,
        }
    }
}

fn take_in_frames(assembly: &mut HelloAssembly, payload: Bytes) {
    if let Ok(frames) = frame::Iter::new(payload) {
        for frame in frames.flatten() {
            if let frame::Frame::Crypto(frame::Crypto { offset, data }) = frame {
                assembly.take_in(offset, &data);
            }
        }
    }
}

/// What a client's first flight offers for version negotiation.
struct ClientOffer {
    /// The versions its first flight is compatible with.
    available: Vec<Version>,
    /// Whether it presents a session ticket, which binds it to the version it started in.
    resuming: bool,
}

/// Part of protocol state incoming datagrams can be routed to
#[derive(Copy, Clone, Debug, PartialEq, Eq)]
enum RouteDatagramTo {
    Incoming(usize),
    Connection(ConnectionHandle),
}

/// Maps packets to existing connections
#[derive(Default, Debug)]
struct ConnectionIndex {
    /// Identifies connections based on the initial DCID the peer utilized
    ///
    /// Uses a standard `HashMap` to protect against hash collision attacks.
    ///
    /// Used by the server, not the client.
    connection_ids_initial: HashMap<ConnectionId, RouteDatagramTo>,
    /// Identifies connections based on locally created CIDs, and attempts being accepted by the
    /// CIDs minted for them
    ///
    /// Uses a cheaper hash function since keys are locally created
    connection_ids: FxHashMap<ConnectionId, RouteDatagramTo>,
    /// Identifies incoming connections with zero-length CIDs
    ///
    /// Uses a standard `HashMap` to protect against hash collision attacks.
    incoming_connection_remotes: HashMap<FourTuple, ConnectionHandle>,
    /// Identifies outgoing connections with zero-length CIDs
    ///
    /// We don't yet support explicit source addresses for client connections, and zero-length CIDs
    /// require a unique four-tuple, so at most one client connection with zero-length local CIDs
    /// may be established per remote. We must omit the local address from the key because we don't
    /// necessarily know what address we're sending from, and hence receiving at.
    ///
    /// Uses a standard `HashMap` to protect against hash collision attacks.
    outgoing_connection_remotes: HashMap<SocketAddr, ConnectionHandle>,
    /// Reset tokens provided by the peer for the CID each connection is currently sending to
    ///
    /// Incoming stateless resets do not have correct CIDs, so we need this to identify the correct
    /// recipient, if any.
    connection_reset_tokens: ResetTokenTable,
}

impl ConnectionIndex {
    /// Associate an incoming connection with its initial destination CID
    fn insert_initial_incoming(&mut self, dst_cid: ConnectionId, incoming_key: usize) {
        if dst_cid.is_empty() {
            return;
        }
        self.connection_ids_initial
            .insert(dst_cid, RouteDatagramTo::Incoming(incoming_key));
    }

    /// Remove an association with an initial destination CID
    fn remove_initial(&mut self, dst_cid: ConnectionId) {
        if dst_cid.is_empty() {
            return;
        }
        let removed = self.connection_ids_initial.remove(&dst_cid);
        debug_assert!(removed.is_some());
    }

    /// Associate a connection with its initial destination CID
    fn insert_initial(&mut self, dst_cid: ConnectionId, connection: ConnectionHandle) {
        if dst_cid.is_empty() {
            return;
        }
        self.connection_ids_initial
            .insert(dst_cid, RouteDatagramTo::Connection(connection));
    }

    /// Associate a connection with its first locally-chosen destination CID if used, or otherwise
    /// its current 4-tuple
    fn insert_conn(
        &mut self,
        addresses: FourTuple,
        dst_cid: ConnectionId,
        connection: ConnectionHandle,
        side: Side,
    ) {
        match dst_cid.len() {
            0 => match side {
                Side::Server => {
                    self.incoming_connection_remotes
                        .insert(addresses, connection);
                }
                Side::Client => {
                    self.outgoing_connection_remotes
                        .insert(addresses.remote, connection);
                }
            },
            _ => {
                self.connection_ids
                    .insert(dst_cid, RouteDatagramTo::Connection(connection));
            }
        }
    }

    /// Discard a connection ID
    fn retire(&mut self, dst_cid: ConnectionId) {
        self.connection_ids.remove(&dst_cid);
    }

    /// Discard the connection IDs minted for an accept that never became a connection
    fn retire_accept(&mut self, cids: AcceptCids) {
        self.retire(cids.local);
        if let Some(cid) = cids.preferred {
            self.retire(cid);
        }
    }

    /// Remove all references to a connection
    fn remove(&mut self, ch: ConnectionHandle, conn: &ConnectionMeta) {
        if conn.side.is_server() {
            self.remove_initial(conn.init_cid);
        }
        self.remove_routes(ch, conn);
    }

    /// Remove the routes a connection's own identifiers, addresses and reset tokens give it.
    fn remove_routes(&mut self, ch: ConnectionHandle, conn: &ConnectionMeta) {
        for cid in conn.loc_cids.values() {
            self.connection_ids.remove(cid);
        }
        // Retiring an older connection must not remove a replacement at the same address,
        // including when server connection IDs are zero length and this is its only route.
        if self.incoming_connection_remotes.get(&conn.addresses) == Some(&ch) {
            self.incoming_connection_remotes.remove(&conn.addresses);
        }
        if self.outgoing_connection_remotes.get(&conn.addresses.remote) == Some(&ch) {
            self.outgoing_connection_remotes
                .remove(&conn.addresses.remote);
        }
        for (remote, token) in conn.reset_tokens.iter() {
            self.connection_reset_tokens.remove(remote, token);
        }
    }

    /// Find the existing connection that `datagram` should be routed to, if any
    fn get(&self, addresses: &FourTuple, datagram: &PartialDecode) -> Option<RouteDatagramTo> {
        if !datagram.dst_cid().is_empty()
            && let Some(&route) = self.connection_ids.get(datagram.dst_cid())
        {
            return Some(route);
        }
        if (datagram.is_initial() || datagram.is_0rtt())
            && let Some(&ch) = self.connection_ids_initial.get(datagram.dst_cid())
        {
            return Some(ch);
        }
        if datagram.dst_cid().is_empty() {
            if let Some(&ch) = self.incoming_connection_remotes.get(addresses) {
                return Some(RouteDatagramTo::Connection(ch));
            }
            if let Some(&ch) = self.outgoing_connection_remotes.get(&addresses.remote) {
                return Some(RouteDatagramTo::Connection(ch));
            }
        }
        let data = datagram.data();
        if data.len() < RESET_TOKEN_SIZE {
            return None;
        }
        self.connection_reset_tokens
            .get(addresses.remote, &data[data.len() - RESET_TOKEN_SIZE..])
            .cloned()
            .map(RouteDatagramTo::Connection)
    }
}

#[derive(Debug)]
pub(crate) struct ConnectionMeta {
    init_cid: ConnectionId,
    /// Number of local connection IDs that have been issued in NEW_CONNECTION_ID frames.
    cids_issued: u64,
    loc_cids: FxHashMap<u64, ConnectionId>,
    /// Remote/local addresses the connection began with
    ///
    /// Only needed to support connections with zero-length CIDs, which cannot migrate, so we don't
    /// bother keeping it up to date.
    addresses: FourTuple,
    side: Side,
    /// The reset tokens this connection may be reset with, one per used, unretired remote CID.
    reset_tokens: UsedResetTokens,
}

/// The reset tokens a connection may be reset with (RFC 9000 §10.3.1): one entry for each
/// (connection ID, address) pair a datagram has actually gone out for and that is not retired.
///
/// An identifier is recognised at more than one address while a rebinding or a fallback keeps the
/// previous path relevant, so the sequence number alone does not identify an entry. The engine
/// bounds the identifiers it holds at once and the addresses it keeps per identifier, so this
/// table is sized for every association the engine can report and does not evict a live route.
#[derive(Debug)]
struct UsedResetTokens {
    entries: SmallVec<[Option<Association>; CidQueue::INLINE_PRESENT * RemCid::REMOTES]>,
    limit: usize,
}

impl Default for UsedResetTokens {
    fn default() -> Self {
        Self::new(CidQueue::INLINE_LIMIT)
    }
}

/// What installing a route did. Only `Full` means the route is absent.
#[derive(Debug, Copy, Clone, PartialEq, Eq)]
enum Installed {
    /// The route is in the table under this installation, and the index needs it.
    New,
    /// The table already had this route with this token; its installation name is updated.
    Refreshed,
    /// There was no room, so the route is **not** installed.
    Full,
}

/// One installed route: the identifier, the address it is sent to, the token a reset would carry,
/// and the name of this installation.
#[derive(Debug, Copy, Clone)]
struct Association {
    seq: u64,
    remote: SocketAddr,
    token: ResetToken,
    generation: u64,
}

impl UsedResetTokens {
    fn new(limit: usize) -> Self {
        Self {
            entries: smallvec![None; limit.min(CidQueue::INLINE_LIMIT) * RemCid::REMOTES],
            limit: limit * RemCid::REMOTES,
        }
    }

    /// Record that the ID with `seq` is sent to `remote`. `true` when this is a new association;
    /// a repetition of one already held changes nothing.
    fn insert(
        &mut self,
        seq: u64,
        remote: SocketAddr,
        token: ResetToken,
        generation: u64,
    ) -> Installed {
        if let Some(held) = self
            .entries
            .iter_mut()
            .flatten()
            .find(|held| held.seq == seq && held.remote == remote)
        {
            // The same pair installed again: this installation's name replaces the older one, so
            // a release still carrying that older name cannot take this route away.
            let known = held.token == token;
            held.generation = generation;
            held.token = token;
            return if known {
                Installed::Refreshed
            } else {
                Installed::New
            };
        }
        if self.entries.iter().all(Option::is_some) && self.entries.len() < self.limit {
            let target = (self.entries.len() * 2).min(self.limit);
            self.entries.reserve_exact(target - self.entries.len());
            self.entries.resize(target, None);
        }
        let Some(slot) = self.entries.iter().position(Option::is_none) else {
            // The engine releases the association it stops using before installing the one that
            // displaced it, so it cannot ask for more routes than there are slots. Refusing keeps
            // every live route instead of dropping one, and is reported to the connection rather
            // than logged and forgotten.
            warn!(seq, %remote, "reset association table full; route not installed");
            return Installed::Full;
        };
        self.entries[slot] = Some(Association {
            seq,
            remote,
            token,
            generation,
        });
        Installed::New
    }

    /// Release the route for `seq` at `remote`, when it is still the installation `generation`
    /// names. `true` when a route was removed.
    fn release(&mut self, seq: u64, remote: SocketAddr, generation: u64) -> bool {
        let Some(slot) = self.entries.iter().position(|e| {
            e.is_some_and(|held| {
                held.seq == seq && held.remote == remote && held.generation == generation
            })
        }) else {
            return false;
        };
        self.entries[slot] = None;
        true
    }

    /// Forget the associations of the IDs with sequence numbers in `seqs`.
    fn remove_range(&mut self, seqs: Range<u64>) -> impl Iterator<Item = (SocketAddr, ResetToken)> {
        self.entries.iter_mut().filter_map(move |entry| {
            if entry.is_some_and(|held| seqs.contains(&held.seq)) {
                entry.take().map(|held| (held.remote, held.token))
            } else {
                None
            }
        })
    }

    fn iter(&self) -> impl Iterator<Item = (SocketAddr, ResetToken)> {
        self.entries
            .iter()
            .flatten()
            .map(|held| (held.remote, held.token))
    }
}

/// Internal identifier for a `Connection` currently associated with an endpoint
#[derive(Debug, Copy, Clone, Eq, PartialEq, Hash, Ord, PartialOrd)]
pub(crate) struct ConnectionHandle(pub(crate) usize);

impl From<ConnectionHandle> for usize {
    fn from(x: ConnectionHandle) -> Self {
        x.0
    }
}

impl Index<ConnectionHandle> for Slab<ConnectionMeta> {
    type Output = ConnectionMeta;
    fn index(&self, ch: ConnectionHandle) -> &ConnectionMeta {
        &self[ch.0]
    }
}

impl IndexMut<ConnectionHandle> for Slab<ConnectionMeta> {
    fn index_mut(&mut self, ch: ConnectionHandle) -> &mut ConnectionMeta {
        &mut self[ch.0]
    }
}

/// Event resulting from processing a single datagram
pub(crate) enum DatagramEvent {
    /// The datagram is redirected to its `Connection`
    ConnectionEvent(ConnectionHandle, ConnectionEvent),
    /// The datagram may result in starting a new `Connection`
    NewConnection(Incoming),
    /// Response generated directly by the endpoint
    Response(Transmit),
    /// A Retry answering an unvalidated attempt while the endpoint is under load. The client
    /// returns to the socket that received the attempt, which must keep receiving for the
    /// Retry token's lifetime.
    Retry(Transmit),
}

/// An incoming connection for which the server has not yet begun its part of the handshake.
pub(crate) struct Incoming {
    received_at: Instant,
    addresses: FourTuple,
    ecn: Option<EcnCodepoint>,
    packet: InitialPacket,
    rest: Option<BytesMut>,
    crypto: Keys,
    token: IncomingToken,
    incoming_idx: usize,
    deadline: Instant,
    progress: Arc<IncomingProgress>,
    /// The server configuration at admission, when its TLS resolves per ClientHello.
    resolving: Option<Arc<ServerConfig>>,
    improper_drop_warner: ImproperDropWarner,
}

impl Incoming {
    /// When the endpoint stops holding this attempt for the application.
    pub(crate) fn deadline(&self) -> Instant {
        self.deadline
    }

    /// Advances as more of the first flight arrives, and when the attempt can no longer
    /// progress.
    pub(crate) fn progress(&self) -> &Arc<IncomingProgress> {
        &self.progress
    }

    /// The server configuration this attempt was admitted under, when its TLS configuration
    /// resolves per ClientHello.
    pub(crate) fn resolving(&self) -> Option<&Arc<ServerConfig>> {
        self.resolving.as_ref()
    }

    /// Whether this admission has expired or already been consumed by the endpoint.
    pub(crate) fn is_expired(&self) -> bool {
        !self.progress.is_live()
    }

    /// The local IP address which was used when the peer established the connection
    ///
    /// This has the same behavior as [`Connection::local_ip`].
    pub(crate) fn local_ip(&self) -> Option<IpAddr> {
        self.addresses
            .local
            .map(|local| local.ip())
            .filter(|ip| !ip.is_unspecified())
    }

    /// The peer's UDP address
    pub(crate) fn remote_address(&self) -> SocketAddr {
        self.addresses.remote
    }

    /// Whether the socket address that is initiating this connection has been validated
    ///
    /// This means that the sender of the initial packet has proved that they can receive traffic
    /// sent to `self.remote_address()`.
    ///
    /// Before expiry, an unvalidated address can be challenged with Retry.
    /// Expired attempts cannot be retried through this handle.
    pub(crate) fn remote_address_validated(&self) -> bool {
        self.token.validated
    }

    /// Whether it is legal to respond with a retry packet
    ///
    /// Before expiry, an unvalidated address can be challenged with Retry.
    /// Expired attempts cannot be retried through this handle.
    pub(crate) fn may_retry(&self) -> bool {
        !self.is_expired() && self.token.retry_src_cid.is_none()
    }

    /// The original destination connection ID sent by the client
    pub(crate) fn orig_dst_cid(&self) -> &ConnectionId {
        &self.token.orig_dst_cid
    }
}

impl fmt::Debug for Incoming {
    fn fmt(&self, f: &mut fmt::Formatter) -> fmt::Result {
        f.debug_struct("Incoming")
            .field("addresses", &self.addresses)
            .field("ecn", &self.ecn)
            // packet doesn't implement debug
            // rest is too big and not meaningful enough
            .field("token", &self.token)
            .field("incoming_idx", &self.incoming_idx)
            // improper drop warner contains no information
            .finish_non_exhaustive()
    }
}

/// Warns when something the endpoint must be handed back is dropped instead. It is armed while
/// that is owed and disarmed by whoever settles it, so the warning is a state of this guard
/// rather than a drop that has to be skipped.
struct ImproperDropWarner {
    armed: Option<&'static str>,
}

impl ImproperDropWarner {
    fn armed(message: &'static str) -> Self {
        Self {
            armed: Some(message),
        }
    }

    fn dismiss(mut self) {
        self.armed = None;
    }
}

impl Drop for ImproperDropWarner {
    fn drop(&mut self) {
        if let Some(message) = self.armed.take() {
            warn!("{message}");
        }
    }
}

/// Errors in the parameters being used to create a new connection
///
/// These arise before any I/O has been performed.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ConnectError {
    /// The endpoint can no longer create new connections
    ///
    /// Indicates that a necessary component of the endpoint has been dropped or otherwise disabled.
    EndpointStopping,
    /// The connection could not be created because not enough of the CID space is available
    ///
    /// Try longer connection IDs or a separate endpoint.
    CidsExhausted,
    /// This endpoint cannot take the connection, but another one can: it is reserved for a
    /// connection that needs it alone, or, with zero-length IDs, its route to this address is
    /// already in use.
    EndpointInUse,
    /// The given server name was malformed
    InvalidServerName(String),
    /// The remote [`SocketAddr`] supplied was malformed
    ///
    /// Examples include attempting to connect to port 0, or using an inappropriate address family.
    InvalidRemoteAddress(SocketAddr),
    /// No default client configuration was set up
    ///
    /// Use `Endpoint::connect_with` to specify a client configuration.
    NoDefaultClientConfig,
    /// The cryptographic session could not be initialized
    Crypto(TransportError),
    /// The local endpoint does not support the QUIC version specified in the client configuration
    UnsupportedVersion,
    /// A connection profile requires different endpoint-wide wire settings.
    ProfileEndpointMismatch(crate::profile::ProfileEndpointMismatch),
}

impl core::fmt::Display for ConnectError {
    fn fmt(&self, f: &mut core::fmt::Formatter<'_>) -> core::fmt::Result {
        match self {
            Self::EndpointStopping => f.write_str("endpoint stopping"),
            Self::CidsExhausted => f.write_str("CIDs exhausted"),
            Self::EndpointInUse => f.write_str("endpoint in use"),
            Self::InvalidServerName(field0) => write!(f, "invalid server name: {field0}"),
            Self::InvalidRemoteAddress(field0) => write!(f, "invalid remote address: {field0}"),
            Self::NoDefaultClientConfig => f.write_str("no default client config"),
            Self::Crypto(error) => write!(f, "initialize cryptographic session: {error}"),
            Self::UnsupportedVersion => f.write_str("unsupported QUIC version"),
            Self::ProfileEndpointMismatch(error) => error.fmt(f),
        }
    }
}

impl std::error::Error for ConnectError {
    fn source(&self) -> Option<&(dyn std::error::Error + 'static)> {
        match self {
            Self::Crypto(error) => Some(error),
            Self::ProfileEndpointMismatch(error) => Some(error),
            _ => None,
        }
    }
}

/// A connection [`Endpoint::finish_accept`] registered.
#[derive(Debug)]
pub(crate) struct Registered {
    pub(crate) handle: ConnectionHandle,
    pub(crate) connection: Connection,
    pub(crate) admission: AdmissionLease,
    /// Datagrams that arrived while the handshake ran, possibly the rest of the ClientHello:
    /// the caller feeds them to the connection without the endpoint, before anything newer.
    pub(crate) late: Vec<ConnectionEvent>,
}

impl Registered {
    /// Tests: feed the late datagrams to the connection, as the driver does.
    #[cfg(test)]
    pub(crate) fn replayed(self) -> (ConnectionHandle, Connection, AdmissionLease) {
        let Self {
            handle,
            mut connection,
            admission,
            late,
        } = self;
        for event in late {
            connection.handle_event(event);
        }
        (handle, connection, admission)
    }
}

/// Error type for attempting to accept an [`Incoming`]
#[derive(Debug)]
pub(crate) struct AcceptError {
    /// Underlying error describing reason for failure
    pub(crate) cause: ConnectionError,
    /// Optional response to transmit back
    pub(crate) response: Option<Transmit>,
}

/// An attempt whose acceptance has begun ([`Endpoint::start_accept`]): its endpoint state is
/// reserved, and [`Self::accept`] does the rest without the endpoint.
#[must_use = "must be completed with `Accepting::accept` and `Endpoint::finish_accept`"]
pub(crate) struct Accepting {
    reservation: Reservation,
    endpoint_config: Arc<EndpointConfig>,
    server_config: Arc<ServerConfig>,
    version: Version,
    negotiated: Version,
    params: TransportParameters,
    cid_len: usize,
    cid_lifetime: Option<Duration>,
    allow_mtud: bool,
    rng_seed: [u8; 32],
    received_at: Instant,
    ecn: Option<EcnCodepoint>,
    packet_number: u64,
    packet: InitialPacket,
    rest: Option<BytesMut>,
    /// Datagrams buffered for the attempt before its acceptance began.
    early: Vec<DatagramConnectionEvent>,
    observation: Option<Box<ServerObservation>>,
    path_validated: bool,
    orig_dst_cid: ConnectionId,
}

/// What [`Endpoint::start_accept`] reserved, settled by `finish_accept` or `abandon_accept`.
struct Reservation {
    incoming_idx: usize,
    progress: Arc<IncomingProgress>,
    init_cid: ConnectionId,
    src_cid: ConnectionId,
    cids: AcceptCids,
    addresses: FourTuple,
    /// With the Initial keys, what a close answering a failed handshake needs.
    wire_version: WireVersion,
    crypto: Keys,
    improper_drop_warner: ImproperDropWarner,
}

impl Accepting {
    /// Start the TLS session, build the connection and process the first packet with what
    /// arrived behind it: the costly part of accepting, which needs no endpoint. The outcome
    /// goes back to the endpoint that started it, whether or not it succeeded.
    pub(crate) fn accept(self) -> Accepted {
        let Self {
            reservation,
            endpoint_config,
            server_config,
            version,
            negotiated,
            params,
            cid_len,
            cid_lifetime,
            allow_mtud,
            rng_seed,
            received_at,
            ecn,
            packet_number,
            packet,
            rest,
            early,
            observation,
            path_validated,
            orig_dst_cid,
        } = self;
        let tls = match &server_config.crypto {
            ServerCrypto::Fixed(crypto) if negotiated == version => {
                crypto.clone().start_session(version, &params)
            }
            ServerCrypto::Fixed(crypto) => crypto
                .clone()
                .start_negotiated_session(version, negotiated, &params),
            ServerCrypto::Resolver(_) => Err(TransportError::INTERNAL_ERROR(
                "a resolving configuration needs the ClientHello first: await the Incoming",
            )),
        };
        let FourTuple { remote, local } = reservation.addresses;
        let transport = server_config.transport.clone();
        let result = tls
            .and_then(|tls| {
                Connection::new(
                    endpoint_config,
                    transport,
                    reservation.init_cid,
                    reservation.cids.local,
                    reservation.src_cid,
                    remote,
                    local,
                    tls,
                    cid_len,
                    cid_lifetime,
                    received_at,
                    negotiated,
                    allow_mtud,
                    rng_seed,
                    SideArgs::Server {
                        server_config,
                        pref_addr_cid: reservation.cids.preferred,
                        path_validated,
                        orig_dst_cid,
                        original_version: version,
                    },
                )
            })
            .map_err(ConnectionError::from)
            .and_then(|mut conn| {
                conn.observation = observation;
                conn.qlog_local_parameters(received_at, &params);
                conn.handle_first_packet(
                    received_at,
                    remote,
                    local,
                    ecn,
                    packet_number,
                    packet,
                    rest,
                )
                .map(|()| {
                    for event in early {
                        conn.handle_event(ConnectionEvent(ConnectionEventInner::Datagram(event)));
                    }
                    if let Some(observation) = &mut conn.observation {
                        observation.finish_buffered();
                    }
                    conn
                })
            });
        Accepted {
            reservation,
            result,
        }
    }
}

impl fmt::Debug for Accepting {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("Accepting")
            .field("incoming_idx", &self.reservation.incoming_idx)
            .field("remote", &self.reservation.addresses.remote)
            .finish_non_exhaustive()
    }
}

/// The outcome of [`Accepting::accept`], for [`Endpoint::finish_accept`] or
/// [`Endpoint::abandon_accept`].
#[must_use = "must be passed to `Endpoint::finish_accept` or `Endpoint::abandon_accept`"]
pub(crate) struct Accepted {
    reservation: Reservation,
    result: Result<Connection, ConnectionError>,
}

impl Accepted {
    /// Tests: the connection built between the phases, unless building it failed.
    #[cfg(test)]
    pub(crate) fn connection(&self) -> Option<&Connection> {
        self.result.as_ref().ok()
    }
}

impl fmt::Debug for Accepted {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("Accepted")
            .field("incoming_idx", &self.reservation.incoming_idx)
            .field("remote", &self.reservation.addresses.remote)
            .field("established", &self.result.is_ok())
            .finish_non_exhaustive()
    }
}

/// Error for a Retry that was not sent; the [`Incoming`] is handed back untouched
#[derive(Debug)]
pub(crate) struct RetryError {
    incoming: Box<Incoming>,
    reason: RetryRefused,
}

/// Why a Retry was not sent
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[non_exhaustive]
pub enum RetryRefused {
    /// The attempt already bears a token from a previous Retry
    AlreadyRetried,
    /// The endpoint has no server configuration
    NoServerConfig,
    /// The token key's provider failed to seal the retry token
    TokenSealing,
    /// The crypto provider failed to authenticate the Retry packet.
    IntegrityProtection,
    /// The configured retry token lifetime cannot be represented on the clock that would bound
    /// the return route, so no Retry is issued and the attempt is kept
    LifetimeUnrepresentable,
}

impl core::fmt::Display for RetryError {
    fn fmt(&self, f: &mut core::fmt::Formatter<'_>) -> core::fmt::Result {
        match self.reason {
            RetryRefused::AlreadyRetried => f.write_str("retry() with validated Incoming"),
            RetryRefused::NoServerConfig => f.write_str("retry() without a server config"),
            RetryRefused::TokenSealing => f.write_str("retry token could not be sealed"),
            RetryRefused::IntegrityProtection => {
                f.write_str("retry packet could not be authenticated")
            }
            RetryRefused::LifetimeUnrepresentable => {
                f.write_str("retry token lifetime exceeds the clock")
            }
        }
    }
}

impl std::error::Error for RetryError {}

impl RetryError {
    pub(crate) fn new(incoming: Incoming, reason: RetryRefused) -> Self {
        Self {
            incoming: Box::new(incoming),
            reason,
        }
    }

    /// Why the Retry was not sent
    pub(crate) fn reason(&self) -> RetryRefused {
        self.reason
    }

    /// Get the [`Incoming`]
    pub(crate) fn into_incoming(self) -> Incoming {
        *self.incoming
    }
}

/// Reset Tokens which are associated with peer socket addresses
///
/// The standard `HashMap` is used since both `SocketAddr` and `ResetToken` are
/// peer generated and might be usable for hash collision attacks.
#[derive(Default, Debug)]
struct ResetTokenTable(HashMap<SocketAddr, HashMap<ResetToken, ConnectionHandle>>);

impl ResetTokenTable {
    fn insert(&mut self, remote: SocketAddr, token: ResetToken, ch: ConnectionHandle) -> bool {
        self.0
            .entry(remote)
            .or_default()
            .insert(token, ch)
            .is_some()
    }

    fn remove(&mut self, remote: SocketAddr, token: ResetToken) {
        use std::collections::hash_map::Entry;
        match self.0.entry(remote) {
            Entry::Vacant(_) => {}
            Entry::Occupied(mut e) => {
                e.get_mut().remove(&token);
                if e.get().is_empty() {
                    e.remove_entry();
                }
            }
        }
    }

    fn get(&self, remote: SocketAddr, token: &[u8]) -> Option<&ConnectionHandle> {
        let token = ResetToken::from(<[u8; RESET_TOKEN_SIZE]>::try_from(token).ok()?);
        self.0.get(&remote)?.get(&token)
    }
}

/// Identifies a connection by the combination of remote and local addresses
///
/// Including the local ensures good behavior when the host has multiple IP addresses on the same
/// subnet and zero-length connection IDs are in use.
#[derive(Hash, Eq, PartialEq, Debug, Copy, Clone)]
struct FourTuple {
    remote: SocketAddr,
    /// The receiving local socket address (ip and port); an endpoint may own several sockets.
    local: Option<SocketAddr>,
}
