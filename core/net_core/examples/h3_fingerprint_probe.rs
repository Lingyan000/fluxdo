//! 仅回环实验：记录真实浏览器的 QUIC Initial、H3 SETTINGS、关键流和 QPACK 表示。
//! SPKI 放行是命令行实验条件，不是移动 WebView 的生产能力，也不构成完整回放验证。
use base64::Engine;
use parking_lot::Mutex;
use rama::http::proto::h3::observation::H3RequestObservation;
use rama::{
    extensions::ExtensionsRef,
    http::{Body, Response},
    net::tls::ApplicationProtocol,
    quic::{
        Endpoint,
        tls::{BoringTlsProvider, QuicServerConfigProvider, TlsOptions},
    },
    rt::Executor,
    tls::{
        boring::core::{sha::sha256, x509::X509},
        server::{GeneratedServerAuthConfig, ServerAuthData, TlsServerConfig},
    },
};
use rama_http_core::h3::{connection::Config, observation::H3Observer};
use rama_quic_proto::{Side, capture};
use serde_json::json;
use std::{path::PathBuf, sync::Arc, time::Duration};

#[tokio::main(worker_threads = 4)]
async fn main() -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
    let args: Vec<_> = std::env::args().collect();
    let browser = args.get(1).ok_or("browser executable required")?;
    let version = tokio::process::Command::new(browser)
        .arg("--version")
        .output()
        .await?;
    let version = String::from_utf8_lossy(&version.stdout).trim().to_owned();
    let out = PathBuf::from(args.get(2).ok_or("output directory required")?);
    std::fs::create_dir_all(&out)?;
    let identity = ServerAuthData::new_generated(GeneratedServerAuthConfig::default())?;
    let leaf = X509::from_der(identity.cert_chain[0].as_ref())?;
    let spki = base64::engine::general_purpose::STANDARD
        .encode(sha256(&leaf.public_key()?.public_key_to_der()?));
    let tls = TlsServerConfig::new()
        .with_server_auth(identity)
        .with_alpn([ApplicationProtocol::HTTP_3].into_iter().collect());
    let config = BoringTlsProvider.server_config(&tls, TlsOptions::default())?;
    let endpoint = Endpoint::bind_server(
        Executor::new(),
        config,
        "127.0.0.1:0".parse::<std::net::SocketAddr>()?,
    )
    .await?;
    let destination = endpoint.local_addr()?;
    let proxy = tokio::net::UdpSocket::bind("127.0.0.1:0").await?;
    let port = proxy.local_addr()?.port();
    let packets = Arc::new(Mutex::new(Vec::<Vec<u8>>::new()));
    let packet_sink = packets.clone();
    let forward = tokio::spawn(async move {
        let mut client = None;
        let mut captured_hello = false;
        let mut buffer = vec![0u8; 65536];
        loop {
            let (size, source) = proxy.recv_from(&mut buffer).await?;
            if source == destination {
                if let Some(client) = client {
                    proxy.send_to(&buffer[..size], client).await?;
                }
            } else {
                client = Some(source);
                if !captured_hello && packet_sink.lock().len() < 64 {
                    let mut packets = packet_sink.lock();
                    packets.push(buffer[..size].to_vec());
                    let borrowed: Vec<_> = packets.iter().map(Vec::as_slice).collect();
                    captured_hello = capture::first_flight(&borrowed, &BoringTlsProvider)
                        .is_ok_and(|f| f.complete);
                }
                proxy.send_to(&buffer[..size], destination).await?;
            }
        }
        #[allow(unreachable_code)]
        Ok::<(), std::io::Error>(())
    });
    let observations = Arc::new(Mutex::new(Vec::new()));
    let observation_sink = observations.clone();
    let done = Arc::new(tokio::sync::Notify::new());
    let finished = done.clone();
    let server_endpoint = endpoint.clone();
    let server = tokio::spawn(async move {
        while let Some(incoming) = server_endpoint.accept().await {
            let connection = incoming.await?;
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
                let body = if path == "/" {
                    "<!doctype html><script>fetch('/fetch').then(()=>fetch('/done')).then(()=>document.title='done')</script>"
                } else {
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
                    json!({"path":path,"version":format!("{:?}",request.version()),
                    "connection":observer.map(|o| o.snapshot()),"request":fields}),
                );
                if path == "/done" {
                    finished.notify_one();
                }
            }
            driver.abort();
        }
        Ok::<(), rama::error::BoxError>(())
    });
    let mut command = tokio::process::Command::new(browser);
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
        ))
        .arg(format!("--origin-to-force-quic-on=localhost:{port}"));
    let allow_spki = !args.iter().any(|a| a == "--without-spki");
    if allow_spki {
        command.arg(format!("--ignore-certificate-errors-spki-list={spki}"));
    }
    let mut child = command
        .arg(format!("https://localhost:{port}/"))
        .stdout(std::fs::File::create(out.join("browser.stdout"))?)
        .stderr(std::fs::File::create(out.join("browser.stderr"))?)
        .kill_on_drop(true)
        .spawn()?;
    let completed = tokio::time::timeout(Duration::from_secs(20), done.notified())
        .await
        .is_ok();
    let _ = child.kill().await;
    let datagrams = packets.lock().clone();
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
    let report = json!({"evidence_kind":"native_chromium_local_quic", "browser_version":version,"spki_override":allow_spki,
        "completed":completed,"datagrams":datagrams.len(),"initial":flight.as_ref().ok(),"initial_error":flight.err().map(|e|e.to_string()),
        "transport_parameters":parameters,"tls":tls_shape,"h3":*observations.lock(),
        "limitations":["command_line_test_only","not_a_production_webview_probe","not_a_replay_equivalence_test","no_0rtt_retry_or_migration_test"]});
    std::fs::write(
        out.join("h3-capture.json"),
        serde_json::to_vec_pretty(&report)?,
    )?;
    endpoint.close(0u32, b"probe complete");
    forward.abort();
    server.abort();
    println!(
        "{}",
        json!({"completed":completed,"spki_override":allow_spki,"requests":observations.lock().len()})
    );
    if allow_spki && !completed {
        return Err("native H3 request did not complete".into());
    }
    Ok(())
}
