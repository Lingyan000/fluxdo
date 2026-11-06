//! CONNECT-IP over real HTTP wire engines, with IP packets supplied in memory.
use interop_common::{
    backend::{self, VerifyBackend as _},
    identity,
};
use rama::{
    ServiceInput,
    bytes::Bytes,
    crypto::pem::PemEncode as _,
    error::BoxError,
    extensions::ExtensionsRef as _,
    http::{
        Version,
        client::{Http3Transport, http_connect},
        core::h3::{connection::Config, transport::BoxedConnection},
        server::HttpServer,
    },
    net::{
        address::ip::ipnet::IpNet,
        ip::{IpPacket, IpProtocol, Ipv4Header, Ipv6Header},
        tls::ApplicationProtocol,
    },
    quic::{Endpoint, TransportConfig},
    rt::Executor,
    service::service_fn,
    tls::{SecureTransport, client::TlsClientConfig, server::TlsServerConfig},
    utils::fs::tempdir,
};
use rama_masque::connect_ip::*;
use std::{
    convert::Infallible,
    net::{Ipv4Addr, SocketAddr},
    process::Stdio,
    sync::Arc,
    time::Duration,
};
use tokio::{
    io::{AsyncBufReadExt as _, BufReader},
    time::timeout,
};

fn prefix(s: &str) -> IpNet {
    s.parse().unwrap()
}

fn config() -> ConnectIpSessionConfig {
    let mut policy = ConnectIpPolicy::new();
    let direction = IpDirectionPolicy {
        sources: IpSourcePolicy::Static(vec![prefix("192.0.2.0/24"), prefix("2001:db8::/32")]),
        destinations: vec![
            IpRoute::from_prefix(prefix("192.0.2.0/24"), None).unwrap(),
            IpRoute::from_prefix(prefix("2001:db8::/32"), None).unwrap(),
        ],
        require_advertised_route: false,
    };
    policy.send = direction.clone();
    policy.receive = direction;
    let mut config = ConnectIpSessionConfig::new(policy);
    config = config.try_with_ipv6_link_mtu(1350).unwrap();
    config
}

fn packets() -> Vec<Bytes> {
    let mut raw = [0; 1400];
    let mut out = Vec::new();
    let n = Ipv4Header::new(
        Ipv4Addr::new(192, 0, 2, 1),
        Ipv4Addr::new(192, 0, 2, 2),
        IpProtocol::UDP,
    )
    .encode(&[], b"CONNECT-IP IPv4 packet", &mut raw)
    .unwrap();
    out.push(Bytes::copy_from_slice(&raw[..n]));
    let n = Ipv6Header::new(
        "2001:db8::1".parse().unwrap(),
        "2001:db8::2".parse().unwrap(),
        IpProtocol::UDP,
    )
    .encode(&[0x5a; 1240], &mut raw)
    .unwrap();
    out.push(Bytes::copy_from_slice(&raw[..n]));
    out
}

async fn echo(mut session: ConnectIpSession) -> Result<(), BoxError> {
    session
        .send_control(ConnectIpCapsule::AddressAssign(vec![AddressAssignment {
            request_id: None,
            prefix: prefix("192.0.2.1/32"),
        }]))
        .await?;
    session
        .send_control(ConnectIpCapsule::RouteAdvertisement(vec![
            IpRoute::from_prefix(prefix("192.0.2.0/24"), None).unwrap(),
        ]))
        .await?;
    let mut echoed = 0;
    loop {
        let event = match session.recv().await {
            Ok(Some(event)) => event,
            Ok(None) | Err(_) if echoed == 2 => break,
            Ok(None) => return Err("peer closed before both packets".into()),
            Err(error) => return Err(error.into()),
        };
        match event {
            ConnectIpEvent::Packet { packet, .. } => {
                if let IpPacket::V6(ip) = IpPacket::parse(&packet)?
                    && ip.protocol() == Some(IpProtocol::ICMPV6)
                    && ip.payload()[0] == 128
                {
                    let echo = rama::net::ip::icmp::Icmpv6Echo::parse(ip)?;
                    let mut reply = [0; 1280];
                    let n = echo
                        .reply()
                        .encode(ip.destination(), ip.source(), &mut reply)?;
                    assert!(matches!(
                        session
                            .send_packet(Bytes::copy_from_slice(&reply[..n]), IpPacketOrigin::Local)
                            .await?,
                        IpPacketSend::Sent(_)
                    ));
                    continue;
                }
                assert!(matches!(
                    session.send_packet(packet, IpPacketOrigin::Local).await?,
                    IpPacketSend::Sent(_)
                ));
                echoed += 1;
            }
            ConnectIpEvent::Control(ConnectIpCapsule::AddressRequest(requests)) => {
                session
                    .send_control(ConnectIpCapsule::AddressAssign(
                        requests
                            .into_iter()
                            .map(|r| AddressAssignment {
                                request_id: Some(r.request_id),
                                prefix: if r.prefix.addr().is_ipv4() {
                                    prefix("192.0.2.1/32")
                                } else {
                                    prefix("2001:db8::1/128")
                                },
                            })
                            .collect(),
                    ))
                    .await?;
            }
            ConnectIpEvent::Dropped(reason) => panic!("unexpected server packet drop: {reason:?}"),
            _ => (),
        }
    }
    session
        .send_control(ConnectIpCapsule::RouteAdvertisement(vec![]))
        .await?;
    session.close().await?;
    Ok(())
}

async fn exercise(mut session: ConnectIpSession, native: bool) -> Result<(), BoxError> {
    for _ in 0..2 {
        assert!(matches!(
            session.recv().await?,
            Some(ConnectIpEvent::Control(_))
        ));
    }
    session
        .send_control(ConnectIpCapsule::AddressRequest(vec![AddressRequest {
            request_id: AddressRequestId::from_static(1),
            prefix: prefix("::/128"),
        }]))
        .await?;
    assert!(matches!(
        session.recv().await?,
        Some(ConnectIpEvent::Control(ConnectIpCapsule::AddressAssign(_)))
    ));
    assert_eq!(
        session.state().local_addresses()[0].prefix,
        prefix("2001:db8::1/128")
    );
    if native {
        assert!(
            session
                .probe_ipv6_mtu("2001:db8::1".parse()?, "2001:db8::2".parse()?, [42; 16])
                .await?
                .is_empty()
        );
    }
    for packet in packets() {
        let sent = session
            .send_packet(packet.clone(), IpPacketOrigin::Local)
            .await?;
        assert_eq!(
            sent,
            IpPacketSend::Sent(if native {
                rama::http::datagram::DatagramTransport::Native
            } else {
                rama::http::datagram::DatagramTransport::Capsule
            })
        );
        let Some(ConnectIpEvent::Packet {
            packet: received, ..
        }) = session.recv().await?
        else {
            panic!("missing echoed IP packet")
        };
        assert_eq!(received, packet);
    }
    session.close().await?;
    assert!(
        matches!(session.recv().await?, Some(ConnectIpEvent::Control(ConnectIpCapsule::RouteAdvertisement(routes))) if routes.is_empty())
    );
    assert!(session.recv().await?.is_none());
    Ok(())
}

#[tokio::test]
async fn h1_h2_h3_carriers_exchange_control_and_dual_stack_packets() -> Result<(), BoxError> {
    timeout(Duration::from_secs(30), async {
        for (version, native) in [
            (Version::HTTP_11, false),
            (Version::HTTP_2, false),
            (Version::HTTP_3, false),
            (Version::HTTP_3, true),
        ] {
            let exec = Executor::new();
            let template = ConnectIpTemplate::try_new("https://localhost/vpn")?;
            let (finished, mut completion) = tokio::sync::mpsc::unbounded_channel();
            let service = ConnectIpService::new(
                template.clone(),
                service_fn(async |_: ConnectIpRequest| Ok::<_, Infallible>(config())),
                service_fn(move |s: ConnectIpSession| {
                    let finished = finished.clone();
                    async move {
                        finished
                            .send(echo(s).await.map_err(|e| e.to_string()))
                            .unwrap();
                        Ok::<_, Infallible>(())
                    }
                }),
                exec.clone(),
            );
            let request = template.request(&ConnectIpScope::default(), version)?;
            if version == Version::HTTP_3 {
                let auth = identity::server_identity();
                let transport = Arc::new(TransportConfig::default().with_initial_mtu(1400));
                let mut server_config = backend::server_tls_provider().server_config(
                    &TlsServerConfig::new()
                        .with_server_auth(auth.clone())
                        .with_alpn([ApplicationProtocol::HTTP_3].into_iter().collect())
                        .verify_backend(),
                    backend::options(),
                )?;
                server_config.set_transport_config(transport.clone());
                let mut client_config = backend::tls_provider().client_config(
                    &TlsClientConfig::new()
                        .try_with_server_trust_anchors(auth.cert_chain.clone())?
                        .with_alpn([ApplicationProtocol::HTTP_3].into_iter().collect())
                        .verify_backend(),
                    backend::options(),
                )?;
                client_config.set_transport_config(transport);
                let server = Endpoint::build(exec.clone())
                    .with_server_config(server_config)
                    .bind_address("127.0.0.1:0".parse::<SocketAddr>()?)
                    .await?;
                let client = Endpoint::build(exec.clone())
                    .bind_address("127.0.0.1:0".parse::<SocketAddr>()?)
                    .await?;
                let (connection, accepted) = tokio::join!(
                    client.connect_with(client_config, server.local_addr()?, "localhost")?,
                    async { server.accept().await.unwrap().await }
                );
                let connection = connection?;
                let accepted = accepted?;
                let mut http = HttpServer::new_http3(exec.clone());
                http.http3_mut().extended_connect = true;
                http.http3_mut().datagrams = native.then(Default::default);
                let serving = tokio::spawn(async move { http.serve(accepted, service).await });
                let transport = Http3Transport {
                    connection: BoxedConnection::new(connection.clone()),
                    config: Arc::new(Config {
                        datagrams: native.then(Default::default),
                        ..Config::default()
                    }),
                };
                let established = http_connect(transport, request, exec.clone()).await?;
                let client_http = established.conn;
                let request = established.input;
                let mut session_config = config();
                if native {
                    session_config = session_config.try_without_ipv6_link_mtu().unwrap();
                }
                exercise(
                    ConnectIpRequestBuilder::try_from_request(&template, request, session_config)?
                        .connect(&client_http)
                        .await?,
                    native,
                )
                .await?;
                completion
                    .recv()
                    .await
                    .ok_or("missing server completion")?
                    .map_err(std::io::Error::other)?;
                connection.close(0u32, b"done");
                serving.abort();
                client.close(0u32, b"done");
                server.close(0u32, b"done");
            } else {
                let (a, b) = tokio::io::duplex(65536);
                // Memory carriers test HTTP semantics; TLS-listener metadata is
                // supplied by the fixture. Separate unit tests reject its absence.
                let server_io = ServiceInput::new(b);
                server_io.extensions().insert(SecureTransport::default());
                let exec_server = exec.clone();
                let serving = tokio::spawn(async move {
                    if version == Version::HTTP_2 {
                        let mut http = HttpServer::new_h2(exec_server);
                        http.h2_mut().set_enable_connect_protocol();
                        http.serve(server_io, service).await
                    } else {
                        HttpServer::new_http1(exec_server)
                            .serve(server_io, service)
                            .await
                    }
                });
                let established = http_connect(ServiceInput::new(a), request, exec).await?;
                let client_http = established.conn;
                let request = established.input;
                exercise(
                    ConnectIpRequestBuilder::try_from_request(&template, request, config())?
                        .connect(&client_http)
                        .await?,
                    false,
                )
                .await?;
                completion
                    .recv()
                    .await
                    .ok_or("missing server completion")?
                    .map_err(std::io::Error::other)?;
                serving.abort();
            }
        }
        Ok::<_, BoxError>(())
    })
    .await?
}

fn ip_peer() -> tokio::process::Command {
    let mut command =
        tokio::process::Command::new(std::env::var("RAMA_CONNECT_IP_INTEROP_PEER").expect(
            "build examples/tests/masque_interop/ip-peer and set RAMA_CONNECT_IP_INTEROP_PEER",
        ));
    command.kill_on_drop(true);
    command
}

fn reversed(packet: &[u8], hop: u8) -> Bytes {
    let mut out = packet.to_vec();
    if out[0] >> 4 == 4 {
        out[12..16].copy_from_slice(&packet[16..20]);
        out[16..20].copy_from_slice(&packet[12..16]);
        out[8] = hop;
        out[10..12].fill(0);
        let length = usize::from(out[0] & 15) * 4;
        let checksum = rama::net::ip::internet_checksum(&out[..length]);
        out[10..12].copy_from_slice(&checksum.to_be_bytes());
    } else {
        out[8..24].copy_from_slice(&packet[24..40]);
        out[24..40].copy_from_slice(&packet[8..24]);
        out[7] = hop;
    }
    out.into()
}

fn assignments(requests: &[AddressRequest]) -> ConnectIpCapsule {
    ConnectIpCapsule::AddressAssign(
        requests
            .iter()
            .map(|r| AddressAssignment {
                request_id: Some(r.request_id),
                prefix: prefix(if r.prefix.addr().is_ipv4() {
                    "192.0.2.1/32"
                } else {
                    "2001:db8::1/128"
                }),
            })
            .collect(),
    )
}

fn peer_routes() -> ConnectIpCapsule {
    ConnectIpCapsule::RouteAdvertisement(vec![
        IpRoute::from_prefix(prefix("192.0.2.2/32"), None).unwrap(),
        IpRoute::from_prefix(prefix("2001:db8::2/128"), None).unwrap(),
    ])
}

fn address_requests() -> Vec<AddressRequest> {
    vec![
        AddressRequest {
            request_id: AddressRequestId::from_static(1),
            prefix: prefix("0.0.0.0/32"),
        },
        AddressRequest {
            request_id: AddressRequestId::from_static(2),
            prefix: prefix("::/128"),
        },
    ]
}

#[tokio::test]
#[ignore = "requires the independent CONNECT-IP Go peer"]
async fn rama_ip_client_against_connect_ip_go() -> Result<(), BoxError> {
    timeout(Duration::from_secs(40), async {
        let directory = tempdir()?;
        let auth = identity::server_identity();
        let cert = directory.path().join("cert.pem");
        let key = directory.path().join("key.pem");
        std::fs::write(
            &cert,
            auth.cert_chain
                .iter()
                .map(|c| c.to_pem())
                .collect::<String>(),
        )?;
        std::fs::write(&key, auth.private_key.to_pem())?;
        let mut process = ip_peer()
            .args(["-mode", "server", "-cert"])
            .arg(&cert)
            .arg("-key")
            .arg(&key)
            .stdout(Stdio::piped())
            .stderr(Stdio::inherit())
            .spawn()?;
        let mut lines = BufReader::new(process.stdout.take().unwrap()).lines();
        let ready: serde_json::Value =
            serde_json::from_str(&lines.next_line().await?.ok_or("missing readiness")?)?;
        let address: SocketAddr = ready["address"]
            .as_str()
            .ok_or("missing address")?
            .parse()?;
        let exec = Executor::new();
        let endpoint = Endpoint::build(exec.clone())
            .bind_address("127.0.0.1:0".parse::<SocketAddr>()?)
            .await?;
        let tls = TlsClientConfig::new()
            .try_with_server_trust_anchors(auth.cert_chain)?
            .with_alpn([ApplicationProtocol::HTTP_3].into_iter().collect())
            .verify_backend();
        let client_config = backend::tls_provider()
            .client_config(&tls, backend::options())?
            .with_transport_config(Arc::new(TransportConfig::default().with_initial_mtu(1400)));
        let connection = endpoint
            .connect_with(client_config, address, "localhost")?
            .await?;
        let template =
            ConnectIpTemplate::try_new(format!("https://localhost:{}/vpn", address.port()))?;
        let request = template.request(&ConnectIpScope::default(), Version::HTTP_3)?;
        let established = http_connect(
            Http3Transport {
                connection: BoxedConnection::new(connection.clone()),
                config: Arc::new(Config {
                    datagrams: Some(Default::default()),
                    ..Config::default()
                }),
            },
            request,
            exec,
        )
        .await?;
        let mut session =
            ConnectIpRequestBuilder::try_from_request(&template, established.input, config())?
                .connect(&established.conn)
                .await?;
        while session.state().local_addresses().len() != 2
            || session.state().peer_routes().len() != 2
        {
            assert!(matches!(
                session.recv().await?,
                Some(ConnectIpEvent::Control(_))
            ));
        }
        session
            .send_control(ConnectIpCapsule::AddressRequest(address_requests()))
            .await?;
        loop {
            assert!(matches!(
                session.recv().await?,
                Some(ConnectIpEvent::Control(_))
            ));
            let state = session.state();
            if state
                .local_addresses()
                .iter()
                .map(|a| a.request_id.map(AddressRequestId::value))
                .eq([Some(1), Some(2)])
            {
                break;
            }
        }
        for packet in packets() {
            assert!(matches!(
                session
                    .send_packet(packet.clone(), IpPacketOrigin::Local)
                    .await?,
                IpPacketSend::Sent(_)
            ));
            loop {
                match session.recv().await?.ok_or("peer closed before reply")? {
                    ConnectIpEvent::Packet { packet: reply, .. } => {
                        // The Go peer's WritePacket performs a forwarding hop.
                        assert_eq!(reply, reversed(&packet, 63));
                        break;
                    }
                    ConnectIpEvent::Control(_) => (),
                    ConnectIpEvent::Dropped(reason) => panic!("unexpected drop: {reason:?}"),
                }
            }
        }
        while !session.state().peer_routes().is_empty() {
            assert!(matches!(
                session.recv().await?,
                Some(ConnectIpEvent::Control(_))
            ));
        }
        session.close().await?;
        connection.close(0u32, b"done");
        endpoint.close(0u32, b"done");
        process.kill().await?;
        Ok::<_, BoxError>(())
    })
    .await?
}

async fn independent_responder(mut session: ConnectIpSession) -> Result<(), BoxError> {
    let ConnectIpCapsule::AddressAssign(mut initial) = assignments(&address_requests()) else {
        unreachable!("assignment helper returns assignments");
    };
    for assignment in &mut initial {
        assignment.request_id = None;
    }
    session
        .send_control(ConnectIpCapsule::AddressAssign(initial))
        .await?;
    session.send_control(peer_routes()).await?;
    let mut count = 0;
    let mut requested = false;
    loop {
        let event = match session.recv().await {
            Ok(Some(event)) => event,
            Ok(None) | Err(_) if count == 2 && requested => break,
            Ok(None) => return Err("peer closed before exchange completed".into()),
            Err(error) => return Err(error.into()),
        };
        match event {
            ConnectIpEvent::Control(ConnectIpCapsule::AddressRequest(requests)) => {
                assert_eq!(requests.len(), 2);
                session.send_control(assignments(&requests)).await?;
                requested = true;
            }
            ConnectIpEvent::Packet { packet, .. } => {
                assert_eq!(packet, {
                    let mut expected = packets()[count].to_vec();
                    rama::net::ip::decrement_hop_limit(&mut expected)?;
                    Bytes::from(expected)
                });
                assert!(matches!(
                    session
                        .send_packet(reversed(&packet, 64), IpPacketOrigin::Local)
                        .await?,
                    IpPacketSend::Sent(_)
                ));
                count += 1;
                if count == 2 {
                    session
                        .send_control(ConnectIpCapsule::RouteAdvertisement(Vec::new()))
                        .await?;
                }
            }
            ConnectIpEvent::Dropped(reason) => panic!("unexpected drop: {reason:?}"),
            _ => (),
        }
    }
    Ok(())
}

#[tokio::test]
#[ignore = "requires the independent CONNECT-IP Go peer"]
async fn rama_ip_server_against_connect_ip_go() -> Result<(), BoxError> {
    timeout(Duration::from_secs(40), async {
        let directory = tempdir()?;
        let auth = identity::server_identity();
        let cert = directory.path().join("cert.pem");
        let packet_file = directory.path().join("packets.json");
        std::fs::write(
            &cert,
            auth.cert_chain
                .iter()
                .map(|c| c.to_pem())
                .collect::<String>(),
        )?;
        let values: Vec<String> = packets()
            .iter()
            .map(|p| p.iter().map(|b| format!("{b:02x}")).collect())
            .collect();
        std::fs::write(&packet_file, serde_json::to_vec(&values)?)?;
        let exec = Executor::new();
        let tls = TlsServerConfig::new()
            .with_server_auth(auth)
            .with_alpn([ApplicationProtocol::HTTP_3].into_iter().collect())
            .verify_backend();
        let server_config = backend::server_tls_provider()
            .server_config(&tls, backend::options())?
            .with_transport_config(Arc::new(TransportConfig::default().with_initial_mtu(1400)));
        let endpoint = Endpoint::build(exec.clone())
            .with_server_config(server_config)
            .bind_address("127.0.0.1:0".parse::<SocketAddr>()?)
            .await?;
        let url = format!("https://localhost:{}/vpn", endpoint.local_addr()?.port());
        let template = ConnectIpTemplate::try_new(url.clone())?;
        let (finished, mut completion) = tokio::sync::mpsc::unbounded_channel();
        let service = ConnectIpService::new(
            template,
            service_fn(async |_: ConnectIpRequest| Ok::<_, Infallible>(config())),
            service_fn(move |s: ConnectIpSession| {
                let finished = finished.clone();
                async move {
                    finished
                        .send(independent_responder(s).await.map_err(|e| e.to_string()))
                        .unwrap();
                    Ok::<_, Infallible>(())
                }
            }),
            exec.clone(),
        );
        let child = ip_peer()
            .args(["-mode", "client", "-cert"])
            .arg(&cert)
            .arg("-url")
            .arg(url)
            .arg("-packets")
            .arg(packet_file)
            .stdout(Stdio::piped())
            .stderr(Stdio::inherit())
            .spawn()?;
        let connection = endpoint.accept().await.ok_or("missing connection")?.await?;
        let mut http = HttpServer::new_http3(exec);
        http.http3_mut().extended_connect = true;
        http.http3_mut().datagrams = Some(Default::default());
        let serving = tokio::spawn(async move { http.serve(connection, service).await });
        let output = child.wait_with_output().await?;
        assert!(
            output.status.success(),
            "Go peer failed: {:?}",
            output.status
        );
        let report: serde_json::Value = serde_json::from_slice(&output.stdout)?;
        assert_eq!(report["ok"], true);
        assert_eq!(report["packets"], 2);
        assert_eq!(report["address_requests"], 2);
        assert_eq!(report["routes_withdrawn"], true);
        completion
            .recv()
            .await
            .ok_or("missing server completion")?
            .map_err(std::io::Error::other)?;
        endpoint.close(0u32, b"done");
        serving.abort();
        Ok::<_, BoxError>(())
    })
    .await?
}
