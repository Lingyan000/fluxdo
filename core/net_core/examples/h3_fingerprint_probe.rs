//! 仅回环实验：记录真实浏览器的 QUIC Initial、H3 SETTINGS、关键流和 QPACK 表示。
//! SPKI 放行是命令行实验条件，不是移动 WebView 的生产能力，也不构成完整回放验证。
use base64::Engine;
use parking_lot::Mutex;
use rama::http::proto::h3::observation::H3RequestObservation;
use rama::{
    Layer, Service, ServiceInput,
    extensions::ExtensionsRef,
    http::{Body, Request, Response, server::HttpServer},
    net::tls::ApplicationProtocol,
    quic::{
        Endpoint,
        tls::{BoringTlsProvider, QuicServerConfigProvider, TlsOptions},
    },
    rt::Executor,
    service::service_fn,
    tls::{
        boring::{
            core::{sha::sha256, x509::X509},
            server::TlsAcceptorLayer,
        },
        server::{GeneratedServerAuthConfig, ServerAuthData, TlsServerConfig},
    },
};
use rama_http_core::h3::{connection::Config, observation::H3Observer};
use rama_quic_proto::{Side, capture};
use serde_json::json;
use std::{path::PathBuf, sync::Arc, time::Duration};

// 不强迫协议选择，让 WebView 按 Alt-Svc 和自己的信任策略决定是否启用 H3。
const NATIVE_PAGE: &str = r#"<!doctype html><title>fluxdo-probe</title><script>
(async()=>{try{for(let i=0;i<24;i++){let r=await fetch('/fluxdo-probe/fetch?i='+i);
if((await r.text())==='h3'){await fetch('/fluxdo-probe/done');break;}
await new Promise(r=>setTimeout(r,500));}}finally{
await fetch('/fluxdo-probe/finished');document.title='fluxdo-probe-done';}})();
</script>"#;

#[tokio::main(worker_threads = 4)]
async fn main() -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
    let args: Vec<_> = std::env::args().collect();
    let browser = args.get(1).ok_or("browser executable required")?;
    let native_probe = args.iter().any(|a| a == "--native-probe");
    let learn_alt_svc = native_probe || args.iter().any(|a| a == "--learn-alt-svc");
    let version = if native_probe {
        String::new()
    } else {
        let output = tokio::process::Command::new(browser)
            .arg("--version")
            .output()
            .await?;
        String::from_utf8_lossy(&output.stdout).trim().to_owned()
    };
    let out = PathBuf::from(args.get(2).ok_or("output directory required")?);
    std::fs::create_dir_all(&out)?;
    let identity = ServerAuthData::new_generated(GeneratedServerAuthConfig::generated_ca_for(
        rama::net::address::Domain::from_static("localhost"),
    ))?;
    std::fs::write(out.join("h3-ca.pem"), X509::from_der(identity.cert_chain.last().ok_or("missing lab CA")?.as_ref())?.to_pem()?)?;
    let leaf = X509::from_der(identity.cert_chain[0].as_ref())?;
    let spki = base64::engine::general_purpose::STANDARD
        .encode(sha256(&leaf.public_key()?.public_key_to_der()?));
    let tls = TlsServerConfig::new()
        .with_server_auth(identity.clone())
        .with_alpn([ApplicationProtocol::HTTP_3].into_iter().collect());
    let config = BoringTlsProvider.server_config(&tls, TlsOptions::default())?;
    let endpoint = Endpoint::bind_server(
        Executor::new(),
        config,
        "127.0.0.1:0".parse::<std::net::SocketAddr>()?,
    )
    .await?;
    let destination = endpoint.local_addr()?;
    let proxy = Arc::new(tokio::net::UdpSocket::bind("127.0.0.1:0").await?);
    let port = proxy.local_addr()?.port();
    let tcp_requests = Arc::new(Mutex::new(Vec::new()));
    let native_finished = Arc::new(tokio::sync::Notify::new());
    let tcp_server = if learn_alt_svc {
        let listener = tokio::net::TcpListener::bind(("127.0.0.1", port)).await?;
        let tls = TlsServerConfig::new()
            .with_server_auth(identity)
            .with_alpn_http_auto();
        let requests = tcp_requests.clone();
        let finished = native_finished.clone();
        Some(tokio::spawn(async move {
            let mut connections = tokio::task::JoinSet::new();
            loop {
                let (stream, _) = listener.accept().await?;
                let requests = requests.clone();
                let finished = finished.clone();
                let http = HttpServer::auto(Executor::new()).service(service_fn(
                    move |request: Request| {
                        let path = request
                            .uri()
                            .path()
                            .map(|p| p.to_string())
                            .unwrap_or_default();
                        requests
                            .lock()
                            .push(json!({"path":path,"version":format!("{:?}",request.version())}));
                        if path == "/fluxdo-probe/finished" {
                            finished.notify_one();
                        }
                        let response = Response::builder()
                            .header("alt-svc", format!("h3=\":{port}\"; ma=60"))
                            .header("cache-control", "no-store")
                            .header("content-type", "text/html")
                            .body(Body::from(if path == "/fluxdo-probe" {
                                NATIVE_PAGE
                            } else {
                                "tcp"
                            }))
                            .unwrap();
                        async move { Ok::<_, std::convert::Infallible>(response) }
                    },
                ));
                let service = TlsAcceptorLayer::new(tls.clone()).into_layer(http);
                connections.spawn(async move { service.serve(ServiceInput::new(stream)).await });
            }
            #[allow(unreachable_code)]
            Ok::<(), std::io::Error>(())
        }))
    } else {
        None
    };
    let packets = Arc::new(Mutex::new(std::collections::BTreeMap::<usize, Vec<Vec<u8>>>::new()));
    let flow_routes = Arc::new(Mutex::new(std::collections::HashMap::new()));
    let server_routes = flow_routes.clone();
    let packet_sink = packets.clone();
    let forward = tokio::spawn(async move {
        let mut clients = std::collections::HashMap::new();
        let mut replies = tokio::task::JoinSet::new();
        let mut completed_flows = std::collections::HashSet::new();
        let mut buffer = vec![0u8; 65536];
        loop {
            let (size, source) = proxy.recv_from(&mut buffer).await?;
            // 浏览器可能同时开启多条 QUIC 连接，回复必须回到原来的 UDP 端口。
            // 不能让后来的探测包覆盖单个全局 client 地址。
            if !clients.contains_key(&source) {
                if clients.len() >= 16 {
                    continue;
                }
                let upstream = Arc::new(tokio::net::UdpSocket::bind("127.0.0.1:0").await?);
                upstream.connect(destination).await?;
                let flow_id = clients.len();
                flow_routes.lock().insert(upstream.local_addr()?, flow_id);
                clients.insert(source, (upstream.clone(), flow_id));
                let downstream = proxy.clone();
                replies.spawn(async move {
                    let mut buffer = vec![0u8; 65536];
                    loop {
                        let size = upstream.recv(&mut buffer).await?;
                        downstream.send_to(&buffer[..size], source).await?;
                    }
                    #[allow(unreachable_code)]
                    Ok::<(), std::io::Error>(())
                });
            }
            let (upstream, flow_id) = &clients[&source];
            if !completed_flows.contains(flow_id) {
                let mut captures = packet_sink.lock();
                let packets = captures.entry(*flow_id).or_default();
                if packets.len() < 64 {
                    packets.push(buffer[..size].to_vec());
                    let borrowed: Vec<_> = packets.iter().map(Vec::as_slice).collect();
                    if capture::first_flight(&borrowed, &BoringTlsProvider).is_ok_and(|f| f.complete) {
                        completed_flows.insert(*flow_id);
                    }
                }
            }
            upstream.send(&buffer[..size]).await?;
        }
        #[allow(unreachable_code)]
        Ok::<(), std::io::Error>(())
    });
    let observations = Arc::new(Mutex::new(Vec::new()));
    let observation_sink = observations.clone();
    let done = Arc::new(tokio::sync::Notify::new());
    let finished = done.clone();
    let native_done = native_finished.clone();
    let server_endpoint = endpoint.clone();
    let connection_errors = Arc::new(Mutex::new(Vec::new()));
    let error_sink = connection_errors.clone();
    let server = tokio::spawn(async move {
        let mut connections = tokio::task::JoinSet::new();
        while let Some(incoming) = server_endpoint.accept().await {
            // 预连接可能一直没有 HTTP 请求，不能阻塞后续连接的握手与请求。
            let observation_sink = observation_sink.clone();
            let finished = finished.clone();
            let native_done = native_done.clone();
            let error_sink = error_sink.clone();
            let server_routes = server_routes.clone();
            connections.spawn(async move {
                let result: Result<(), rama::error::BoxError> = async {
                    let connection = incoming.await?;
                    // 每个转发 socket 对应一条浏览器连接，先关联再接收 HTTP；不能混用预连接的 Initial。
                    let flow_id = server_routes.lock().get(&connection.remote_address()).copied();
                    let (mut requests, driver) = rama_http_core::h3::server::handshake(
                        connection,
                        Config {
                            observation: Some(Default::default()),
                            ..Config::default().with_browser_qpack_decoder_limits()
                        },
                    )?;
                    let driver = tokio::spawn(driver.run());
                    while let Ok(incoming) = requests.accept().await {
                        let (request, response) = incoming.resolve().await?;
                        let observer = request.extensions().get_ref::<H3Observer>().cloned();
                        let fields = request.extensions().get_ref::<H3RequestObservation>()
                            .map(|r| json!({"stream_id":r.stream_id,"fields":r.fields,"fields_complete":r.fields_complete,
                                "priority":r.priority.as_ref().map(|v| String::from_utf8_lossy(v).into_owned())}));
                        let path = request
                            .uri()
                            .path()
                            .map(|p| p.to_string())
                            .unwrap_or_default();
                        let body = if path == "/fluxdo-probe" { NATIVE_PAGE } else if path == "/" {
                            "<!doctype html><script>fetch('/fetch').then(()=>fetch('/done')).then(()=>document.title='done')</script>"
                        } else if path.starts_with("/fluxdo-probe/") { "h3" } else {
                            "ok"
                        };
                        response
                            .send_response(
                                Response::builder()
                                    .header("content-type", "text/html")
                                    .body(Body::from(body))?,
                            )
                            .await?;
                        observation_sink.lock().push(
                            json!({"flow_id":flow_id,"path":path,"version":format!("{:?}",request.version()),
                            "connection":observer.map(|o| o.snapshot()),"request":fields}),
                        );
                        if path == "/fluxdo-probe/finished" { native_done.notify_one(); }
                        if path == "/done" || path == "/fluxdo-probe/done" {
                            finished.notify_one();
                        }
                    }
                    driver.abort();
                    Ok(())
                }.await;
                if let Err(error) = result { error_sink.lock().push(error.to_string()); }
            });
        }
        Ok::<(), rama::error::BoxError>(())
    });
    let mut command = tokio::process::Command::new(browser);
    if !native_probe {
        command
            .args([
                "--headless",
                "--no-sandbox",
                "--disable-dev-shm-usage",
                "--disable-background-networking",
                "--no-first-run",
                "--remote-debugging-port=0",
                "--enable-quic",
                "--host-resolver-rules=MAP localhost 127.0.0.1",
            ])
            .arg(format!(
                "--user-data-dir={}",
                out.join("browser-profile").display()
            ));
        if !learn_alt_svc {
            command.arg(format!("--origin-to-force-quic-on=localhost:{port}"));
        }
    }
    let allow_spki = !native_probe && !args.iter().any(|a| a == "--without-spki");
    if allow_spki {
        command.arg(format!("--ignore-certificate-errors-spki-list={spki}"));
    }
    if !native_probe {
        command.arg(format!(
            "--log-net-log={}",
            out.join("browser-netlog.json").display()
        ));
    }
    let path = if learn_alt_svc { "/fluxdo-probe" } else { "/" };
    let mut child = command
        .arg(format!("https://localhost:{port}{path}"))
        .stdout(std::fs::File::create(out.join("browser.stdout"))?)
        .stderr(std::fs::File::create(out.join("browser.stderr"))?)
        .kill_on_drop(true)
        .spawn()?;
    let mut driver_success = None;
    let native_probe_finished = if native_probe {
        match tokio::time::timeout(Duration::from_secs(95), child.wait()).await {
            Ok(result) => {
                driver_success = Some(result?.success());
                driver_success == Some(true)
            }
            Err(_) => false,
        }
    } else if learn_alt_svc {
        tokio::time::timeout(Duration::from_secs(25), native_finished.notified())
            .await
            .is_ok()
    } else {
        false
    };
    let completed = if learn_alt_svc {
        observations
            .lock()
            .iter()
            .any(|r| r["path"] == "/fluxdo-probe/done")
    } else {
        tokio::time::timeout(Duration::from_secs(20), done.notified())
            .await
            .is_ok()
    };
    let _ = child.kill().await;
    if let Some(tcp_server) = tcp_server {
        tcp_server.abort();
    }
    let server_error = if server.is_finished() {
        Some(format!("{:?}", server.await))
    } else {
        server.abort();
        None
    };
    let relay_error = if forward.is_finished() {
        Some(format!("{:?}", forward.await))
    } else {
        forward.abort();
        None
    };
    let all_packets = packets.lock().clone();
    let selected_flow = observations.lock().iter().find_map(|r| r["flow_id"].as_u64()).map(|id| id as usize);
    let selected_flow = selected_flow.or_else(|| all_packets.keys().next().copied());
    let datagrams = selected_flow.and_then(|id| all_packets.get(&id)).cloned().unwrap_or_default();
    let flow_summaries: Vec<_> = all_packets.iter().map(|(id, packets)| {
        let borrowed: Vec<_> = packets.iter().map(Vec::as_slice).collect();
        let initial = capture::first_flight(&borrowed, &BoringTlsProvider);
        json!({"flow_id":id,"datagrams":packets.len(),"initial":initial.as_ref().ok(),
            "initial_error":initial.err().map(|e| e.to_string())})
    }).collect();
    let joint_capture_complete = completed && observations.lock().iter().all(|r| {
        r["flow_id"].as_u64().is_some_and(|id| flow_summaries.iter().any(|f| {
            f["flow_id"] == id && f["initial"]["complete"] == true
        }))
    });
    let borrowed: Vec<_> = datagrams.iter().map(Vec::as_slice).collect();
    let flight = capture::first_flight(&borrowed, &BoringTlsProvider);
    let mut initials = Vec::new();
    for datagram in &datagrams {
        initials.extend(capture::observe(datagram)?.unprotect_initials(
            datagram,
            &BoringTlsProvider,
            Side::Server,
            None,
        )?);
    }
    let hello = capture::client_hello(&initials);
    let parameters = hello
        .as_ref()
        .map(|hello| capture::transport_parameters(hello))
        .transpose()?;
    let tls_shape = hello.as_ref().and_then(|bytes| bytes.get(4..))
        .map(rama::tls::client::parse_client_hello).transpose()?
        .map(|hello| json!({"cipher_suites":hello.cipher_suites(),"groups":hello.ext_supported_groups(),
            "signature_algorithms":hello.ext_signature_algorithms(),"alpn":hello.ext_alpn(),
            "extension_ids":hello.extensions().iter().map(|e| u16::from(e.id())).collect::<Vec<_>>()}));
    let certificate_rejected = connection_errors
        .lock()
        .iter()
        .any(|error| error.contains("CERTIFICATE_VERIFY_FAILED"));
    let expected_result_observed = if native_probe {
        native_probe_finished && !tcp_requests.lock().is_empty()
    } else if learn_alt_svc {
        native_probe_finished && joint_capture_complete
    } else if allow_spki {
        completed && joint_capture_complete
            && ["/", "/fetch", "/done"].iter().all(|path| {
                observations
                    .lock()
                    .iter()
                    .any(|r| r["path"] == *path && r["version"] == "HTTP/3.0")
            })
    } else {
        !completed && observations.lock().is_empty() && certificate_rejected
    };
    let report = json!({"evidence_kind":if native_probe { "native_webview_alt_svc" } else { "native_chromium_local_quic" }, "browser_version":version,"spki_override":allow_spki,
        "expected_result_observed":expected_result_observed,"certificate_rejected":certificate_rejected,
        "native_probe":native_probe,"learn_alt_svc":learn_alt_svc,"native_probe_finished":native_probe_finished,
        "driver_success":driver_success,"tcp_requests":*tcp_requests.lock(),
        "h3_sample_complete":joint_capture_complete,
        "joint_capture_complete":joint_capture_complete,"selected_flow_id":selected_flow,"flows":flow_summaries,
        "server_error":server_error,"relay_error":relay_error,
        "connection_errors":*connection_errors.lock(),
        "completed":completed,"datagrams":datagrams.len(),"initial":flight.as_ref().ok(),"initial_error":flight.err().map(|e|e.to_string()),
        "transport_parameters":parameters,"tls":tls_shape,"h3":*observations.lock(),
        "limitations":["local_generated_certificate","not_a_production_webview_probe","not_a_replay_equivalence_test","no_0rtt_retry_or_migration_test"]});
    std::fs::write(
        out.join("h3-capture.json"),
        serde_json::to_vec_pretty(&report)?,
    )?;
    endpoint.close(0u32, b"probe complete");
    println!(
        "{}",
        json!({"completed":completed,"spki_override":allow_spki,"requests":observations.lock().len()})
    );
    if !expected_result_observed {
        return Err(
            "H3 completion or certificate-rejection control did not match expectation".into(),
        );
    }
    Ok(())
}
