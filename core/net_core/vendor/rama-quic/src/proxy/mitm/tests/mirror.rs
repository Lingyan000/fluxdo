use rama_core::service::RejectService;
use rama_crypto::dep::boring::ssl::SslContentType;
use rama_quic_proto::{
    capture::{
        CaptureLimits, FirstFlight, QuicObservation, RawParameter, transport_parameters_from_hello,
        transport_parameters_iter_from_hello, version_information,
    },
    peek::InitialPeek,
    profile::TransportLimits,
    transport_parameters::TransportParameterId,
    version::{Version as QuicVersion, VersionInformation},
};
use rama_tls::{
    client::{
        ClientHello, ClientHelloExtension, ClientHelloHandshakePrefix,
        parse_client_hello_message_prefix,
    },
    server::TlsServerConfig,
};

use super::*;
use crate::{profile::capture::ProviderKeys, proxy::peek::NoQuicRejectError};

/// Chrome 153's QUIC ClientHello, from its captured first flight.
fn chrome_peeked() -> PeekedClientHello {
    let identity = identity();
    let server = crate::test_helpers::server(&identity).crypto.into_fixed();
    let keys = ProviderKeys(server.as_ref());
    let mut peek = InitialPeek::new_with_first_flight(
        CaptureLimits::default(),
        std::time::Instant::now() + Duration::from_secs(5),
    );
    for datagram in chrome_flight() {
        if let Some(peeked) = peek
            .inspect(std::time::Instant::now(), &datagram, &keys)
            .unwrap()
        {
            return peeked;
        }
    }
    panic!("no ClientHello in Chrome's flight");
}

fn chrome_client_hello() -> ClientHello {
    chrome_peeked().client_hello
}

/// What a hello shows that is not drawn per connection: every list with its GREASE values,
/// and the extensions in order; key shares by group, ECH GREASE and transport parameters by
/// presence (those are compared on their own).
fn shape(hello: &ClientHello) -> Vec<String> {
    let mut shape = vec![format!("{:?}", hello.cipher_suites())];
    for ext in hello.extensions() {
        shape.push(match ext {
            ClientHelloExtension::EncryptedClientHello(_) => "ech".to_owned(),
            ClientHelloExtension::Opaque { id, .. } if *id == rama_tls::ExtensionId::KEY_SHARE => {
                format!("key_share {:?}", hello.ext_key_share_groups())
            }
            ClientHelloExtension::Opaque { id, .. }
                if *id == rama_tls::ExtensionId::QUIC_TRANSPORT_PARAMETERS =>
            {
                "quic_transport_parameters".to_owned()
            }
            other => format!("{other:?}"),
        });
    }
    shape
}

/// Transport parameters without the values every connection draws or a relay sets itself.
fn parameters(hello: &ClientHello) -> Vec<RawParameter> {
    let mut parameters = transport_parameters_from_hello(hello, &CaptureLimits::default()).unwrap();
    for parameter in &mut parameters {
        if matches!(
            parameter.id,
            TransportParameterId::InitialSourceConnectionId
                | TransportParameterId::VersionInformation
        ) {
            parameter.value.clear();
        }
    }
    parameters
}

/// What the client sent and what the origin received through a relay that mirrors (or not),
/// after a peek that retains (or not) the client's Initial structure.
async fn through_relay(
    mirror: bool,
    retain: bool,
    port: u16,
    version: QuicVersion,
    advertise_version: bool,
    extra_extension: Option<ClientHelloExtension>,
) -> (ClientHello, ClientHello, Option<FirstFlight>, FirstFlight) {
    let mitm_identity = identity();
    let origin_identity = untrusted_identity();
    // With GREASE added, which Chrome's QUIC hello lacks: the client draws fresh values
    // per connection, and a mirroring relay must repeat exactly those.
    let chrome = chrome_client_hello();
    let mut ciphers = vec![rama_tls::CipherSuite::from(0x0a0a)];
    ciphers.extend_from_slice(chrome.cipher_suites());
    let mut extensions = vec![ClientHelloExtension::Opaque {
        id: rama_tls::ExtensionId::from(0x1a1a),
        data: Vec::new(),
    }];
    extensions.extend(extra_extension);
    extensions.extend_from_slice(chrome.extensions());
    let captured = ClientHello::new(
        chrome.protocol_version(),
        ciphers,
        chrome.compression_algorithms().to_vec(),
        extensions,
    );
    let address = |offset: u16| SocketAddr::from(([127, 0, 0, 1], port + offset));
    let capacity = NonZeroUsize::new(64).unwrap();
    let (client_socket, ingress) = MemoryDatagramSocket::pair(address(0), address(1), capacity);
    let (egress, origin_socket) = MemoryDatagramSocket::pair(address(2), address(3), capacity);

    let origin_tls = TlsServerConfig::new()
        .with_alpn([ApplicationProtocol::HTTP_3].into_iter().collect())
        .with_server_auth(origin_identity.clone());
    let origin = Endpoint::build(Executor::new())
        .with_server_config(
            ServerConfig::try_from_rama_tls_with_provider(
                &origin_tls,
                TlsOptions::default(),
                &BoringTlsProvider,
            )
            .unwrap()
            .maybe_with_capture(Some(CaptureLimits::default())),
        )
        .with_datagram_socket(origin_socket)
        .unwrap();
    let origin_task = tokio::spawn(async move {
        let mut incoming = origin.accept().await.unwrap();
        let hello = incoming.client_hello().await.unwrap().clone();
        let connection = incoming.await.unwrap();
        connection.closed().await;
        let flight = connection
            .extensions()
            .get_ref::<QuicObservation>()
            .unwrap()
            .first_flight
            .clone()
            .unwrap();
        (hello, origin, flight)
    });

    let mut mitm = QuicMitmRelay::new(
        issuer(&mitm_identity),
        Executor::new(),
        trusting_with_alpn(&origin_identity, b"h3"),
        VarInt::from_u32(0x0101),
    );
    mitm.set_mirror_client(mirror);
    let terminate = mitm.into_layer(service_fn(
        async |BridgeIo(ingress, egress): BridgeIo<Connection, Connection>| {
            egress.handshake_confirmed().await?;
            ingress.close(VarInt::from_u32(0), b"checked");
            egress.close(VarInt::from_u32(0), b"checked");
            Ok::<_, BoxError>(())
        },
    ));
    let peek = PeekQuicClientHelloService::new(
        BoringTlsProvider,
        service_fn(async |input: InputWithQuicClientHello<_>| Ok::<_, BoxError>(input)),
    )
    .with_fallback(RejectService::new(NoQuicRejectError))
    .with_first_flight_retention(retain);
    let relaying = tokio::spawn(async move {
        let input = peek.serve(BridgeIo(ingress, egress)).await?;
        let source_flight = input.peeked.first_flight.clone();
        terminate.serve(input).await?;
        Ok::<_, BoxError>(source_flight)
    });

    let sent = Arc::new(Mutex::new(None));
    let kept = sent.clone();
    let client_tls = TlsClientConfig::new_from_client_hello(&captured)
        .with_unknown_values(UnknownValues::Preserve)
        .try_with_server_trust_anchors([mitm_identity.cert_chain.last().unwrap().clone()])
        .unwrap();
    client_tls.insert(HandshakeInitializer(Arc::new(move |ssl: &mut SslRef| {
        let kept = kept.clone();
        ssl.set_msg_callback(move |_, message| {
            if message.is_written()
                && message.content_type() == SslContentType::HANDSHAKE
                && message.bytes().first() == Some(&1)
            {
                *kept.lock() = Some(message.bytes().to_vec());
            }
        });
        Ok(())
    })));
    let versions = ClientVersionPolicy::new(version)
        .unwrap()
        .with_reserved_version_grease(ReservedVersionGrease::First)
        .try_with_version_information(advertise_version)
        .unwrap();
    let profile = crate::profile::browsers::chrome_153()
        .with_versions(versions)
        .with_connection_ids(
            ConnectionIdProfile::standard()
                .try_with_initial_destination_len(10)
                .unwrap()
                .try_with_local_len(4)
                .unwrap(),
        );
    // This relay deliberately disables datagrams; a source advertising them would
    // have that parameter dropped. Keep the compared first flights identical.
    let profile = profile.clone().with_transport_parameters(
        profile
            .transport_parameters()
            .clone()
            .try_with_max_datagram_frame_size(None)
            .unwrap(),
    );
    let mut limits = profile.limits().clone();
    limits.datagram_receive_buffer_size = None;
    let profile = profile.try_with_limits(limits).unwrap();
    let mut config = ClientConfig::try_from_rama_tls_with_provider(
        &client_tls,
        TlsOptions::default(),
        &BoringTlsProvider,
    )
    .unwrap();
    config.apply_quic_profile(&profile).unwrap();
    let mut endpoint_config = crate::EndpointConfig::try_with_rand_key().unwrap();
    endpoint_config.apply_quic_profile(&profile).unwrap();
    let client = Endpoint::build(Executor::new())
        .with_config(endpoint_config)
        .with_datagram_socket(client_socket)
        .unwrap();
    let connection = client
        .connect_with(config, address(1), "localhost")
        .unwrap()
        .await
        .unwrap();
    let source_flight = relaying.await.unwrap().unwrap();
    connection.closed().await;
    let (received, _origin, origin_flight) = origin_task.await.unwrap();
    let ClientHelloHandshakePrefix::Complete(sent) =
        parse_client_hello_message_prefix(&sent.lock().clone().unwrap())
    else {
        panic!("the client wrote a complete ClientHello");
    };
    (sent, received, source_flight, origin_flight)
}

fn assert_mirrored_native_flight(
    sent: &ClientHello,
    received: &ClientHello,
    source_flight: &FirstFlight,
    origin_flight: &FirstFlight,
) {
    assert_eq!(shape(received), shape(sent));
    assert_eq!(parameters(received), parameters(sent));
    let source_parameters =
        transport_parameters_from_hello(sent, &CaptureLimits::default()).unwrap();
    let target_parameters =
        transport_parameters_from_hello(received, &CaptureLimits::default()).unwrap();
    let source_cid = &source_parameters
        .iter()
        .find(|parameter| parameter.id == TransportParameterId::InitialSourceConnectionId)
        .unwrap()
        .value;
    let target_cid = &target_parameters
        .iter()
        .find(|parameter| parameter.id == TransportParameterId::InitialSourceConnectionId)
        .unwrap()
        .value;
    assert_eq!(source_cid.len(), 4);
    assert_eq!(target_cid.len(), 4);
    assert!(
        source_cid != target_cid,
        "origin receives a fresh source CID"
    );
    assert_eq!(
        RecordedInitialFlight::try_from(origin_flight).unwrap(),
        RecordedInitialFlight::try_from(source_flight).unwrap()
    );
    assert_eq!(origin_flight.dcid_len, source_flight.dcid_len);
    assert_eq!(origin_flight.scid_len, source_flight.scid_len);
}

#[tokio::test]
async fn a_mirroring_relay_shows_the_origin_its_clients_first_flight() {
    timeout(LIMIT, async {
        let (sent, received, source_flight, origin_flight) =
            through_relay(true, true, 24900, QuicVersion::V1, true, None).await;
        assert_mirrored_native_flight(&sent, &received, &source_flight.unwrap(), &origin_flight);

        // Without mirroring, the origin sees the relay's own configuration.
        let (sent, received, _, _) =
            through_relay(false, true, 24910, QuicVersion::V1, true, None).await;
        assert_ne!(shape(&received), shape(&sent));
        assert_ne!(parameters(&received), parameters(&sent));

        // Without the retained Initial structure only the transport profile falls back
        // to the relay's own; the association and the mirrored ClientHello remain.
        let (sent, received, source_flight, _) =
            through_relay(true, false, 24980, QuicVersion::V1, true, None).await;
        assert!(source_flight.is_none());
        assert_eq!(shape(&received), shape(&sent));
        assert_ne!(parameters(&received), parameters(&sent));
    })
    .await
    .unwrap();
}

/// A private extension the native TLS engine does not build.
const UNKNOWN_EXTENSION: rama_tls::ExtensionId = rama_tls::ExtensionId::Unknown(0x1234);

#[tokio::test]
async fn a_mirroring_relay_drops_client_values_it_cannot_negotiate() {
    timeout(LIMIT, async {
        let unknown = ClientHelloExtension::Opaque {
            id: UNKNOWN_EXTENSION,
            data: vec![1, 2, 3],
        };
        let (sent, received, _, _) =
            through_relay(true, true, 24990, QuicVersion::V1, true, Some(unknown)).await;
        let has_unknown = |hello: &ClientHello| {
            hello
                .extensions()
                .iter()
                .any(|extension| extension.id() == UNKNOWN_EXTENSION)
        };
        assert!(has_unknown(&sent));
        assert!(!has_unknown(&received));
        // GREASE stays pinned to the client's codepoints.
        assert_eq!(received.cipher_suites()[0], sent.cipher_suites()[0]);
    })
    .await
    .unwrap();
}

#[tokio::test]
async fn mirroring_preserves_native_version_advertisement_and_initial_layout() {
    timeout(LIMIT, async {
        for (index, version) in [QuicVersion::V1, QuicVersion::V2].into_iter().enumerate() {
            for advertise in [false, true] {
                let port = 24920 + index as u16 * 20 + u16::from(advertise) * 10;
                let (sent, received, source, target) =
                    through_relay(true, true, port, version, advertise, None).await;
                let source = source.unwrap();
                assert_eq!(source.version, version);
                assert_eq!(target.version, version);
                assert_mirrored_native_flight(&sent, &received, &source, &target);
                for hello in [&sent, &received] {
                    let parameters =
                        transport_parameters_from_hello(hello, &CaptureLimits::default()).unwrap();
                    let info = version_information(&parameters);
                    assert_eq!(info.is_some(), advertise);
                    if let Some(info) = info {
                        assert_eq!(info.chosen(), version);
                        assert!(info.available().contains(&version));
                    }
                }
            }
        }
    })
    .await
    .unwrap();
}

/// `hello` with its transport parameters replaced by `parameters`.
fn with_parameters(hello: &ClientHello, parameters: &[RawParameter]) -> ClientHello {
    let var = |value: u64, out: &mut Vec<u8>| match value {
        0..64 => out.push(value as u8),
        64..16_384 => out.extend_from_slice(&(value as u16 | 0x4000).to_be_bytes()),
        16_384..1_073_741_824 => out.extend_from_slice(&(value as u32 | 0x8000_0000).to_be_bytes()),
        _ => out.extend_from_slice(&(value | 0xc000_0000_0000_0000).to_be_bytes()),
    };
    let mut body = Vec::new();
    for parameter in parameters {
        var(u64::from(parameter.id), &mut body);
        var(parameter.value.len() as u64, &mut body);
        body.extend_from_slice(&parameter.value);
    }
    with_parameter_body(hello, &body)
}

fn with_parameter_body(hello: &ClientHello, body: &[u8]) -> ClientHello {
    let extensions = hello
        .extensions()
        .iter()
        .map(|ext| match ext {
            ClientHelloExtension::Opaque { id, .. }
                if *id == rama_tls::ExtensionId::QUIC_TRANSPORT_PARAMETERS =>
            {
                ClientHelloExtension::Opaque {
                    id: *id,
                    data: body.to_vec(),
                }
            }
            other => other.clone(),
        })
        .collect();
    ClientHello::new(
        hello.protocol_version(),
        hello.cipher_suites().to_vec(),
        hello.compression_algorithms().to_vec(),
        extensions,
    )
}

/// Project changed transport parameters over a retained, native-readable source shape.
/// These policy tests intentionally do not claim fresh TLS geometry or peer emission.
fn mirrored_transport(hello: &ClientHello) -> Result<TransportConfig, BoxError> {
    let base = TransportConfig::default().maybe_with_datagram_receive_buffer_size(Some(65_536));
    let mut peeked = chrome_peeked();
    peeked.client_hello = hello.clone();
    let profile = mirrored_profile(&base, true, &QuicMirrorCeiling::default(), &peeked)?;
    base.try_with_quic_profile(&profile).map_err(Into::into)
}

#[test]
fn mirroring_lowers_limits_and_drops_datagrams_one_relay_transport_lacks() {
    let chrome = chrome_client_hello();
    let mut sent = transport_parameters_from_hello(&chrome, &CaptureLimits::default()).unwrap();
    for parameter in &mut sent {
        if parameter.id == TransportParameterId::InitialMaxData {
            parameter.value = (((1_u64 << 62) - 1) | 0xc000_0000_0000_0000)
                .to_be_bytes()
                .to_vec();
        }
    }
    let lowered = mirrored_transport(&with_parameters(&chrome, &sent)).unwrap();
    assert_eq!(
        lowered.receive_window.into_inner(),
        QuicMirrorCeiling::default().max_data
    );
    let base = TransportConfig::default().maybe_with_datagram_receive_buffer_size(Some(65_536));
    let mut peeked = chrome_peeked();
    for (ingress, egress) in [(false, Some(65_536)), (true, None)] {
        let base = base.clone().maybe_with_datagram_receive_buffer_size(egress);
        let profile =
            mirrored_profile(&base, ingress, &QuicMirrorCeiling::default(), &peeked).unwrap();
        assert_eq!(
            profile.transport_parameters().max_datagram_frame_size(),
            None
        );
        assert_eq!(profile.limits().datagram_receive_buffer_size, None);
        assert!(
            !matches!(
                profile.packetization().layout(),
                InitialFlightLayout::Recorded(_)
            ),
            "lowered transport parameters cannot replay the captured Initial layout"
        );
    }
    let profile = mirrored_profile(&base, true, &QuicMirrorCeiling::default(), &peeked).unwrap();
    assert!(
        profile
            .transport_parameters()
            .max_datagram_frame_size()
            .is_some()
    );
    // The relay then falls back to its egress transport configuration.
    peeked.first_flight = None;
    mirrored_profile(&base, true, &QuicMirrorCeiling::default(), &peeked)
        .expect_err("mirroring needs the retained Initial structure");

    let browser = transport_parameters_from_hello(&chrome, &CaptureLimits::default()).unwrap();
    let limits = TransportLimits::try_from_sent(&browser).unwrap();
    let mirrored = mirrored_transport(&chrome).unwrap();
    assert_eq!(
        mirrored.receive_window.into_inner(),
        limits.initial_max_data
    );
    assert_eq!(
        mirrored.stream_receive_window.into_inner(),
        limits.initial_max_stream_data_bidi_local
    );
    assert_eq!(
        mirrored.max_concurrent_uni_streams.into_inner(),
        limits.initial_max_streams_uni
    );
}

#[test]
fn mirroring_retains_version_information_absence_and_drops_wrong_chosen() {
    let mut peeked = chrome_peeked();
    let mut sent =
        transport_parameters_from_hello(&peeked.client_hello, &CaptureLimits::default()).unwrap();
    sent.retain(|parameter| parameter.id != TransportParameterId::VersionInformation);
    peeked.client_hello = with_parameters(&peeked.client_hello, &sent);
    let base = TransportConfig::default().maybe_with_datagram_receive_buffer_size(Some(65_536));
    let profile = mirrored_profile(&base, true, &QuicMirrorCeiling::default(), &peeked).unwrap();
    assert!(!profile.versions().advertises_version_information());
    assert!(!profile.versions().needs_switch());

    let mut body = Vec::new();
    VersionInformation::new(QuicVersion::V2, vec![QuicVersion::V2]).write(&mut body);
    sent.push(RawParameter {
        id: TransportParameterId::VersionInformation,
        value: body,
    });
    peeked.client_hello = with_parameters(&peeked.client_hello, &sent);
    let profile = mirrored_profile(&base, true, &QuicMirrorCeiling::default(), &peeked)
        .expect("version_information naming another version is dropped, not refused");
    assert!(!profile.versions().advertises_version_information());
}

#[test]
fn mirrored_version_lists_preserve_order_or_drop_unsupported_wire_values() {
    let base = TransportConfig::default().maybe_with_datagram_receive_buffer_size(Some(65_536));
    let project = |chosen, available| {
        let mut peeked = chrome_peeked();
        let mut sent =
            transport_parameters_from_hello(&peeked.client_hello, &CaptureLimits::default())
                .unwrap();
        let mut body = Vec::new();
        VersionInformation::new(chosen, available).write(&mut body);
        let parameter = sent
            .iter_mut()
            .find(|parameter| parameter.id == TransportParameterId::VersionInformation)
            .unwrap();
        parameter.value = body;
        peeked.client_hello = with_parameters(&peeked.client_hello, &sent);
        mirrored_profile(&base, true, &QuicMirrorCeiling::default(), &peeked)
    };
    let available = vec![QuicVersion::V2, QuicVersion::V1, QuicVersion::V2];
    let profile = project(QuicVersion::V1, available.clone()).unwrap();
    let emitted = profile
        .versions()
        .information(QuicVersion::grease(QuicVersion::V1));
    assert_eq!(emitted.chosen(), QuicVersion::V1);
    assert_eq!(emitted.available(), available);

    let grease = QuicVersion::from_u32(0x0a1a_2a3a);
    let other_grease = QuicVersion::from_u32(0x0a1a_2a4a);
    // A chosen version absent from the list is malformed client input.
    project(QuicVersion::V1, vec![QuicVersion::V2]).expect_err("chosen missing");
    // Unusable lists drop version_information; extra reserved entries are dropped alone.
    for (name, chosen, versions, advertised) in [
        (
            "wrong chosen",
            QuicVersion::V2,
            vec![QuicVersion::V2, QuicVersion::V1],
            false,
        ),
        (
            "unknown version",
            QuicVersion::V1,
            vec![QuicVersion::V1, QuicVersion::from_u32(0x1234_5678)],
            false,
        ),
        (
            "incompatible draft",
            QuicVersion::V1,
            vec![QuicVersion::V1, QuicVersion::from_u32(0xff00_001d)],
            false,
        ),
        (
            "interior reserved",
            QuicVersion::V1,
            vec![QuicVersion::V1, grease, QuicVersion::V2],
            true,
        ),
        (
            "multiple reserved",
            QuicVersion::V1,
            vec![grease, QuicVersion::V1, other_grease],
            true,
        ),
    ] {
        let profile = project(chosen, versions).unwrap_or_else(|error| panic!("{name}: {error}"));
        assert_eq!(
            profile.versions().advertises_version_information(),
            advertised,
            "{name}"
        );
    }
}

#[test]
fn mirroring_drops_unsupported_parameters_and_refuses_malformed_ones() {
    let chrome = chrome_client_hello();
    let original = transport_parameters_from_hello(&chrome, &CaptureLimits::default()).unwrap();
    let with = |id, value| {
        let mut sent = original.clone();
        sent.retain(|parameter: &RawParameter| parameter.id != id);
        sent.push(RawParameter { id, value });
        with_parameters(&chrome, &sent)
    };
    let project = |hello: &ClientHello| {
        let mut peeked = chrome_peeked();
        peeked.client_hello = hello.clone();
        let base = TransportConfig::default().maybe_with_datagram_receive_buffer_size(Some(65_536));
        mirrored_profile(&base, true, &QuicMirrorCeiling::default(), &peeked)
    };
    // Valid preferences this relay does not implement, and measured or
    // connection-bound values, are dropped; the rest of the order remains.
    for (name, id, value) in [
        (
            "nondefault ACK exponent",
            TransportParameterId::AckDelayExponent,
            vec![4],
        ),
        (
            "client migration flag",
            TransportParameterId::DisableActiveMigration,
            vec![],
        ),
        (
            "minimum ACK delay",
            TransportParameterId::MinAckDelayDraft07,
            vec![1],
        ),
        (
            "measured initial RTT",
            TransportParameterId::InitialRoundTripTime,
            vec![1],
        ),
        ("discarded padding", TransportParameterId::Discard, vec![0]),
        (
            "connection debugging name",
            TransportParameterId::DebuggingSni,
            vec![1],
        ),
        (
            "unimplemented extension",
            TransportParameterId::SconeSupported,
            vec![],
        ),
        (
            "unregistered extension",
            TransportParameterId::from(0x1234),
            vec![1],
        ),
    ] {
        let profile = project(&with(id, value)).unwrap_or_else(|error| panic!("{name}: {error}"));
        let order = format!("{:?}", profile.transport_parameters());
        assert!(
            !order.contains(&format!("Parameter({id:?})")),
            "{name}: {order}"
        );
        assert!(
            order.contains("Parameter(InitialMaxData)"),
            "{name}: {order}"
        );
    }
    let profile = project(&with(
        TransportParameterId::GoogleConnectionOptions,
        b"ORIG".to_vec(),
    ))
    .unwrap();
    assert!(
        format!("{:?}", profile.transport_parameters())
            .contains("Parameter(GoogleConnectionOptions)"),
        "inert connection-option tags stay"
    );
    let profile = project(&with(TransportParameterId::AckDelayExponent, vec![3])).unwrap();
    assert!(
        format!("{:?}", profile.transport_parameters()).contains("Parameter(AckDelayExponent)"),
        "the explicit protocol-default ACK exponent stays"
    );
    // Malformed or server-only client input remains a protocol error.
    for (name, id, value) in [
        (
            "server-only reset token",
            TransportParameterId::StatelessResetToken,
            vec![0; 16],
        ),
        (
            "malformed migration flag",
            TransportParameterId::DisableActiveMigration,
            vec![0],
        ),
        (
            "malformed ACK exponent",
            TransportParameterId::AckDelayExponent,
            vec![],
        ),
    ] {
        project(&with(id, value)).expect_err(name);
    }
}

#[test]
fn mirroring_encodes_wide_native_integers_minimally_but_preserves_opaque_bodies() {
    let chrome = chrome_client_hello();
    let original = transport_parameters_from_hello(&chrome, &CaptureLimits::default()).unwrap();
    for (name, id, value) in [
        (
            "ACK exponent",
            TransportParameterId::AckDelayExponent,
            vec![0x40, 3],
        ),
        (
            "idle timeout",
            TransportParameterId::MaxIdleTimeout,
            vec![0x40, 1],
        ),
        (
            "receive window",
            TransportParameterId::InitialMaxData,
            vec![0x40, 1],
        ),
        (
            "datagram size",
            TransportParameterId::MaxDatagramFrameSize,
            vec![0x40, 1],
        ),
    ] {
        let mut sent = original.clone();
        sent.retain(|parameter| parameter.id != id);
        sent.push(RawParameter { id, value });
        mirrored_transport(&with_parameters(&chrome, &sent))
            .unwrap_or_else(|error| panic!("{name}: {error}"));
    }
    let mut sent = original;
    let opaque = RawParameter {
        id: TransportParameterId::GoogleConnectionOptions,
        value: vec![0x40, 1],
    };
    sent.retain(|parameter| parameter.id != opaque.id);
    sent.push(opaque.clone());
    let mut peeked = chrome_peeked();
    peeked.client_hello = with_parameters(&chrome, &sent);
    let base = TransportConfig::default().maybe_with_datagram_receive_buffer_size(Some(65_536));
    let profile = mirrored_profile(&base, true, &QuicMirrorCeiling::default(), &peeked).unwrap();
    assert!(
        profile
            .transport_parameters()
            .extra()
            .iter()
            .any(|parameter| { parameter.id == opaque.id && parameter.value == opaque.value })
    );
}

#[test]
fn ordinary_capture_accepts_wide_parameter_framing_but_mirroring_refuses_it() {
    let chrome = chrome_client_hello();
    let mut parameters =
        transport_parameters_from_hello(&chrome, &CaptureLimits::default()).unwrap();
    let opaque = TransportParameterId::Unknown(33);
    parameters.retain(|parameter| parameter.id != opaque);
    let canonical = with_parameters(&chrome, &parameters);
    let body = transport_parameters_iter_from_hello(&canonical, &CaptureLimits::default())
        .unwrap()
        .as_bytes();
    for (name, encoded) in [
        ("wide identifier", [0x40, 33, 0]),
        ("wide length", [33, 0x40, 0]),
    ] {
        let mut changed = body.to_vec();
        changed.extend_from_slice(&encoded);
        let hello = with_parameter_body(&canonical, &changed);
        let observed = transport_parameters_from_hello(&hello, &CaptureLimits::default()).unwrap();
        assert_eq!(observed.last().unwrap().id, opaque);
        assert!(observed.last().unwrap().value.is_empty());
        mirrored_transport(&hello).expect_err(name);
    }
}

#[test]
fn mirroring_preserves_zero_values_and_rejects_repeated_or_bound_parameters() {
    let chrome = chrome_client_hello();
    let original = transport_parameters_from_hello(&chrome, &CaptureLimits::default()).unwrap();
    let base = TransportConfig::default().maybe_with_datagram_receive_buffer_size(Some(65_536));
    let mut sent = original.clone();
    for id in [
        TransportParameterId::InitialMaxStreamsUni,
        TransportParameterId::MaxDatagramFrameSize,
    ] {
        sent.retain(|parameter| parameter.id != id);
        sent.push(RawParameter { id, value: vec![0] });
    }
    let mut peeked = chrome_peeked();
    peeked.client_hello = with_parameters(&chrome, &sent);
    let profile = mirrored_profile(&base, true, &QuicMirrorCeiling::default(), &peeked).unwrap();
    assert_eq!(profile.limits().initial_max_streams_uni, 0);
    assert_eq!(
        profile.transport_parameters().max_datagram_frame_size(),
        Some(0)
    );
    assert_eq!(
        base.try_with_quic_profile(&profile)
            .unwrap()
            .max_concurrent_uni_streams
            .into_inner(),
        0
    );

    for (name, id, value) in [
        (
            "repeated ACK exponent",
            TransportParameterId::AckDelayExponent,
            vec![3],
        ),
        (
            "repeated empty source CID",
            TransportParameterId::InitialSourceConnectionId,
            vec![],
        ),
        (
            "repeated opaque parameter",
            TransportParameterId::Unknown(0x1234),
            vec![1],
        ),
    ] {
        let mut sent = original.clone();
        sent.retain(|parameter| parameter.id != id);
        sent.extend([
            RawParameter {
                id,
                value: value.clone(),
            },
            RawParameter { id, value },
        ]);
        mirrored_transport(&with_parameters(&chrome, &sent)).expect_err(name);
    }
    // A server-only parameter from a client is malformed input.
    let id = TransportParameterId::OriginalDestinationConnectionId;
    let mut sent = original;
    sent.retain(|parameter| parameter.id != id);
    sent.push(RawParameter { id, value: vec![] });
    mirrored_transport(&with_parameters(&chrome, &sent))
        .expect_err("empty server-only original CID");
}
