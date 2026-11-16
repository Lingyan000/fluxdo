//! 诊断采集：记录真实浏览器的 QUIC Initial、H3 SETTINGS、关键流和 QPACK 表示。
//! SPKI 放行是命令行实验条件，不是移动 WebView 的生产能力，也不构成完整回放验证。
#[path = "support/trusted_origin.rs"]
mod trusted_origin;
use base64::Engine;
use parking_lot::Mutex;
use rama::http::proto::h3::observation::H3RequestObservation;
use rama::{
    Layer, Service, ServiceInput,
    extensions::ExtensionsRef,
    http::{Body, Request, Response, body::util::BodyExt, server::HttpServer},
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

fn body_digest(bytes: &[u8]) -> String {
    sha256(bytes).iter().map(|byte| format!("{byte:02x}")).collect()
}

// 不强迫协议选择，让 WebView 按 Alt-Svc 和自己的信任策略决定是否启用 H3。
const NATIVE_PAGE: &str = r#"<!doctype html><title>fluxdo-probe</title><script>
(async()=>{try{for(let i=0;i<24;i++){try{let r=await fetch('/fluxdo-probe/fetch?i='+i);
if((await r.text())==='h3'){await fetch('/fluxdo-probe/done');break;}}catch(e){}
await new Promise(r=>setTimeout(r,500));}}finally{
await fetch('/fluxdo-probe/finished');document.title='fluxdo-probe-done';}})();
</script>"#;

// 只发送合成请求，覆盖变化的请求字段；不读取登录态或 CSRF。
const QPACK_PAGE: &str = r#"<!doctype html><link rel="icon" href="data:,"><title>fluxdo-probe</title><script>
(async()=>{await new Promise(r=>setTimeout(r,400));try{
let ready=false;for(let i=0;i<24;i++){try{let r=await fetch('/fluxdo-probe/fetch');
if((await r.text())==='h3'){ready=true;break;}}catch(e){}await new Promise(r=>setTimeout(r,300));}
if(!ready)throw Error('no h3');
for(let i=0;i<2;i++)await (await fetch('/fluxdo-probe/qpack/warm-'+i)).text();
const cases=[
['conditional','GET',{'if-none-match':'"fluxdo-lab-etag"'},null],
['form','POST',{'content-type':'application/x-www-form-urlencoded'},'sample=one&value=two'],
['json','POST',{'content-type':'application/json'},'{"sample":1}'],
['range','GET',{'range':'bytes=0-15'},null],
['head','HEAD',{},null],
['conditional-changed','GET',{'if-none-match':'"fluxdo-lab-etag-changed-20261115"'},null],
['form-again','POST',{'content-type':'application/x-www-form-urlencoded'},'sample=two&value=one'],
['conditional-again','GET',{'if-none-match':'"fluxdo-lab-etag"'},null],
['conditional-third','GET',{'if-none-match':'"fluxdo-lab-etag"'},null]];
for(const [name,method,headers,body] of cases){await (await fetch('/fluxdo-probe/qpack/'+name,{method,headers,body})).text();}
await (await fetch('/fluxdo-probe/done')).text();
}finally{await (await fetch('/fluxdo-probe/finished')).text();document.title='fluxdo-probe-done';}})();
</script>"#;

// 请求流可以早于控制流到达。等待同连接发布首请求边界，避免混入后续
// 请求产生的 QPACK 指令；Initial 完整也不能替代控制流和字段的完整性。
fn joint_capture_complete(
    completed: bool,
    observations: &[serde_json::Value],
    flows: &[serde_json::Value],
) -> bool {
    let completeness = serde_json::to_value(
        rama::http::proto::h3::observation::ObservationCompleteness::default(),
    )
    .expect("observation completeness serialization");
    completed
        && !observations.is_empty()
        && observations.iter().all(|request| {
            let Some(id) = request["flow_id"].as_u64() else {
                return false;
            };
            if request["request"]["fields_complete"] != true
                || !flows
                    .iter()
                    .any(|f| f["flow_id"] == id && f["initial"]["complete"] == true)
            {
                return false;
            }
            let boundary = &request["first_request_boundary"];
            let connection = &boundary["snapshot"];
            boundary["status"] == "ready"
                && connection["settings_received"] == true
                && connection["connection_error"].is_null()
                && connection["encoder_bindings"]["complete"] == true
                && completeness
                    .as_object()
                    .unwrap()
                    .keys()
                    .all(|key| connection["completeness"][key] == true)
        })
}

#[tokio::main(worker_threads = 4)]
async fn main() -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
    let args: Vec<_> = std::env::args().collect();
    if args.get(1).is_some_and(|arg| arg == "--audit-capture") {
        let path = args.get(2).ok_or("capture path required")?;
        let capture: serde_json::Value = serde_json::from_slice(&std::fs::read(path)?)?;
        let complete = joint_capture_complete(
            capture["completed"] == true,
            capture["h3"].as_array().ok_or("missing H3 observations")?,
            capture["flows"].as_array().ok_or("missing QUIC flows")?,
        );
        println!(
            "{}",
            json!({"capture":path,"previous_complete":capture["h3_sample_complete"],
            "joint_capture_complete":complete})
        );
        return if complete {
            Ok(())
        } else {
            Err("incomplete joint capture".into())
        };
    }
    let browser = args.get(1).ok_or("browser executable required")?;
    let native_probe = args.iter().any(|a| a == "--native-probe");
    let qpack_cases = args.iter().any(|a| a == "--qpack-scenarios");
    let block_quic = args.iter().any(|a| a == "--block-quic");
    let drop_initial = args.iter().any(|a| a == "--drop-first-initial");
    let require_retry = args.iter().any(|a| a == "--require-retry");
    let drop_post_response = args.iter().any(|a| a == "--drop-post-response");
    let dropped = Arc::new(std::sync::atomic::AtomicU64::new(0));
    let dropped_packets = dropped.clone();
    let retries = Arc::new(std::sync::atomic::AtomicU64::new(0));
    let issued_retries = retries.clone();
    let close_tcp = args.iter().any(|a| a == "--close-tcp");
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
    let trusted = trusted_origin::TrustedOrigin::load()?;
    if trusted.is_some() && (!native_probe || std::env::var("FLUXDO_NATIVE_PROBE_FORCE_QUIC").as_deref() == Ok("1")) {
        return Err("trusted origin requires native driver without forced QUIC".into());
    }
    let hostname = trusted.as_ref().map(|v| v.hostname.as_str()).unwrap_or("localhost");
    let bind_address = trusted.as_ref().map(|v| v.address).unwrap_or(std::net::Ipv4Addr::LOCALHOST);
    let identity = if let Some(origin) = &trusted { origin.identity()? } else {
        ServerAuthData::new_generated(GeneratedServerAuthConfig::generated_ca_for(
            rama::net::address::Domain::from_static("localhost"),
        ))?
    };
    std::fs::write(
        out.join("h3-ca.pem"),
        X509::from_der(identity.cert_chain.last().ok_or("missing lab CA")?.as_ref())?.to_pem()?,
    )?;
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
    let proxy = Arc::new(tokio::net::UdpSocket::bind((bind_address, 0)).await?);
    let port = proxy.local_addr()?.port();
    let tcp_requests = Arc::new(Mutex::new(Vec::new()));
    let native_finished = Arc::new(tokio::sync::Notify::new());
    let tcp_server = if learn_alt_svc {
        let listener = tokio::net::TcpListener::bind((bind_address, port)).await?;
        let tls = TlsServerConfig::new()
            .with_server_auth(identity)
            .with_alpn_http_auto();
        let requests = tcp_requests.clone();
        let finished = native_finished.clone();
        Some(tokio::spawn(async move {
            let mut connections = tokio::task::JoinSet::new();
            let mut connection_id = 0usize;
            loop {
                let (stream, _) = listener.accept().await?;
                let id = connection_id;
                connection_id += 1;
                let close = Arc::new(tokio::sync::Notify::new());
                let close_request = close.clone();
                let requests = requests.clone();
                let finished = finished.clone();
                let http = HttpServer::auto(Executor::new()).service(service_fn(
                    move |mut request: Request| {
                        let path = request
                            .uri()
                            .path()
                            .map(|p| p.to_string())
                            .unwrap_or_default();
                        let mut observation=json!({"connection_id":id,"path":path,"method":request.method().as_str(),"version":format!("{:?}",request.version()),
                            "if_none_match":request.headers().get("if-none-match").and_then(|v|v.to_str().ok()),
                            "content_type":request.headers().get("content-type").and_then(|v|v.to_str().ok())});
                        let requests=requests.clone();
                        let close_request=close_request.clone();
                        let finished=finished.clone();
                        let response = Response::builder()
                            .header("alt-svc", format!("h3=\":{port}\"; ma=60"))
                            .header("cache-control", "no-store")
                            .header("content-type", "text/html")
                            .body(Body::from(if path == "/fluxdo-probe" {
                                if qpack_cases { QPACK_PAGE } else { NATIVE_PAGE }
                            } else {
                                "tcp"
                            }))
                            .unwrap();
                        async move {
                            let bytes=match request.body_mut().collect().await {
                                Ok(body)=>body.to_bytes(),
                                Err(error)=>{
                                    observation["body_error"]=json!(error.to_string());
                                    requests.lock().push(observation);
                                    return Ok::<_,std::convert::Infallible>(Response::builder().status(500).body(Body::empty()).unwrap());
                                }
                            };
                            observation["body_bytes"]=json!(bytes.len());
                            observation["body_sha256"]=json!(body_digest(&bytes));
                            requests.lock().push(observation);
                            close_request.notify_one();
                            if path=="/fluxdo-probe/finished" {finished.notify_one();}
                            Ok::<_, std::convert::Infallible>(response)
                        }
                    },
                ));
                let service = TlsAcceptorLayer::new(tls.clone()).into_layer(http);
                connections.spawn(async move {
                    tokio::select! {
                        result = service.serve(ServiceInput::new(stream)) => { let _ = result; }
                        _ = async {
                            close.notified().await;
                            // 公告和响应体先写出，再关闭旧连接；只测试幂等本地 GET。
                            tokio::time::sleep(Duration::from_millis(200)).await;
                        }, if close_tcp => {}
                    }
                });
            }
            #[allow(unreachable_code)]
            Ok::<(), std::io::Error>(())
        }))
    } else {
        None
    };
    let packets = Arc::new(Mutex::new(
        std::collections::BTreeMap::<usize, Vec<Vec<u8>>>::new(),
    ));
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
                    if capture::first_flight(&borrowed, &BoringTlsProvider)
                        .is_ok_and(|f| f.complete)
                    {
                        completed_flows.insert(*flow_id);
                    }
                }
            }
            if block_quic
                || (drop_initial && dropped_packets.load(std::sync::atomic::Ordering::Relaxed) == 0)
            {
                dropped_packets.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
                continue;
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
            if require_retry && !incoming.remote_address_validated() {
                incoming.retry()?;
                issued_retries.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
                continue;
            }
            // 预连接可能一直没有 HTTP 请求，不能阻塞后续连接的握手与请求。
            let observation_sink = observation_sink.clone();
            let finished = finished.clone();
            let native_done = native_done.clone();
            let error_sink = error_sink.clone();
            let server_routes = server_routes.clone();
            connections.spawn(async move {
                let result: Result<(), rama::error::BoxError> = async {
                    let connection = incoming.await?;
                    let close_connection = connection.clone();
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
                        let (mut request, response) = incoming.resolve().await?;
                        let observer = request.extensions().get_ref::<H3Observer>().cloned();
                        let first_request_boundary = if let Some(observer) = &observer {
                            use rama_http_core::h3::observation::FirstRequestObservation;
                            match observer.first_request(tokio::time::Instant::now() + Duration::from_secs(2)).await {
                                FirstRequestObservation::Ready(snapshot) => json!({"status":"ready","snapshot":snapshot}),
                                FirstRequestObservation::TimedOut(snapshot) => json!({"status":"timed_out","snapshot":snapshot}),
                                FirstRequestObservation::Closed { snapshot, .. } => json!({"status":"closed","snapshot":snapshot}),
                            }
                        } else { serde_json::Value::Null };
                        let fields = request.extensions().get_ref::<H3RequestObservation>()
                            .map(|r| json!({"stream_id":r.stream_id,"fields":r.fields,"fields_complete":r.fields_complete,
                                "names": request.extensions().get_ref::<rama::http::proto::h3::PseudoHeaderOrder>()
                                    .into_iter().flat_map(|order|order.iter().map(|p|p.as_str().to_owned()))
                                    .chain(request.headers().iter().map(|(n,_)|n.as_str().to_owned())).collect::<Vec<_>>(),
                                "priority":r.priority.as_ref().map(|v| String::from_utf8_lossy(v).into_owned())}));
                        let path = request
                            .uri()
                            .path()
                            .map(|p| p.to_string())
                            .unwrap_or_default();
                        let body = if path == "/fluxdo-probe" { if qpack_cases { QPACK_PAGE } else { NATIVE_PAGE } } else if path == "/" {
                            "<!doctype html><script>fetch('/fetch').then(()=>fetch('/done')).then(()=>document.title='done')</script>"
                        } else if path.starts_with("/fluxdo-probe/") { "h3" } else {
                            "ok"
                        };
                        let request_body=request.body_mut().collect().await?.to_bytes();
                        if drop_post_response && request.method()==rama::http::Method::POST {
                            // 服务端已完整接收写入，但不给响应；客户端不得自动重放该 POST。
                            observation_sink.lock().push(json!({"flow_id":flow_id,"path":path,
                                "method":"POST","body_bytes":request_body.len(),"body_sha256":body_digest(&request_body),
                                "response_intentionally_lost":true,"version":format!("{:?}",request.version())}));
                            close_connection.close(0u32,b"lab accepted write response loss");
                            break;
                        }
                        let settled_boundary = if let Some(observer) = &observer {
                            let first=observer.snapshot();
                            // 生产回放的策略已写入 profile；首帧尚未到达也必须按该策略等待。
                            // 原生独立采集没有此文件，继续使用已观察到的控制流策略。
                            let mut expected=native_probe && first.control.iter().any(|frame|
                                frame.frame_type == u64::from(rama::http::proto::h3::FrameType::PRIORITY_UPDATE_REQUEST));
                            if let Some(folder) = std::env::var_os("FLUXDO_H3_OUTPUT") {
                                let profile = PathBuf::from(folder).join("profile.json");
                                if profile.exists() {
                                    let profile: serde_json::Value = serde_json::from_slice(&std::fs::read(profile)?)?;
                                    expected |= profile["boundary"]["control"].as_array().is_some_and(|frames|
                                        frames.iter().any(|frame| frame["frame_type"].as_u64() == Some(0xf0700)));
                                }
                            }
                            let stream_id=request.extensions().get_ref::<H3RequestObservation>().ok_or("missing request observation")?.stream_id;
                            Some(fluxdo_net::h3_template::sampled_request_boundary(observer, stream_id, expected).await?)
                        } else {None};
                        // 先发布已完整接收的请求，客户端读完响应立即退出也不会丢失观测。
                        observation_sink.lock().push(
                            json!({"flow_id":flow_id,"path":path,"method":request.method().as_str(),"body_bytes":request_body.len(),"body_sha256":body_digest(&request_body),"version":format!("{:?}",request.version()),
                            "if_none_match":request.headers().get("if-none-match").and_then(|v|v.to_str().ok()),
                            "content_type":request.headers().get("content-type").and_then(|v|v.to_str().ok()),
                            "range":request.headers().get("range").and_then(|v|v.to_str().ok()),
                            "accept_encoding":request.headers().get("accept-encoding").and_then(|v|v.to_str().ok()),
                            "connection":settled_boundary,"request":fields,
                            "first_request_boundary":first_request_boundary}),
                        );
                        response
                            .send_response(
                                Response::builder()
                                    .header("content-type", "text/html")
                                    .body(if request.method()==rama::http::Method::HEAD {Body::empty()} else {Body::from(body)})?,
                            )
                            .await?;
                        if qpack_cases && path == "/fluxdo-probe" {
                            // 页面导航不占用被比较的 fetch 连接，确保两边请求流序号可比。
                            tokio::time::sleep(Duration::from_millis(150)).await;
                            close_connection.close(0u32,b"fresh qpack fetch connection");
                            break;
                        }
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
        if !learn_alt_svc || qpack_cases {
            command.arg(format!("--origin-to-force-quic-on=localhost:{port}"));
        }
    }
    let allow_spki = !native_probe && !args.iter().any(|a| a == "--without-spki");
    let native_force_quic = native_probe
        && std::env::var("FLUXDO_NATIVE_PROBE_FORCE_QUIC").as_deref() == Ok("1");
    if native_probe {
        command.env("FLUXDO_NATIVE_NETLOG_PATH", out.join("browser-netlog.json"));
    }
    if trusted.is_some() {
        command.env("FLUXDO_TRUSTED_PROBE_HOST", hostname);
        command.env_remove("FLUXDO_NATIVE_PROBE_SPKI");
    }
    if native_force_quic {
        // 原生驱动自行核验临时 CI 与来源限制；传递的是当前采集器的公开证书指纹。
        command.env("FLUXDO_NATIVE_PROBE_SPKI", &spki);
        command.env("FLUXDO_NATIVE_NETLOG_PATH", out.join("browser-netlog.json"));
    }
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
        .arg(format!("https://{hostname}:{port}{path}"))
        .stdout(std::fs::File::create(out.join("browser.stdout"))?)
        .stderr(std::fs::File::create(out.join("browser.stderr"))?)
        .kill_on_drop(true)
        .spawn()?;
    let mut driver_success = None;
    let native_probe_finished = if native_probe {
        match tokio::time::timeout(Duration::from_secs(210), child.wait()).await {
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
    // 客户端收到最后一个响应即可退出，服务端的观测发布可能尚未完成。
    // 等待已发布的 finished 标记，避免把调度竞态误报成缺少第三次请求。
    if native_probe && native_probe_finished {
        let _ = tokio::time::timeout(Duration::from_secs(2), native_finished.notified()).await;
    }
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
    let selected_flow = observations
        .lock()
        .iter()
        .find_map(|r| r["flow_id"].as_u64())
        .map(|id| id as usize);
    let selected_flow = selected_flow.or_else(|| all_packets.keys().next().copied());
    let datagrams = selected_flow
        .and_then(|id| all_packets.get(&id))
        .cloned()
        .unwrap_or_default();
    let flow_summaries: Vec<_> = all_packets
        .iter()
        .map(|(id, packets)| {
            let borrowed: Vec<_> = packets.iter().map(Vec::as_slice).collect();
            let initial = capture::first_flight(&borrowed, &BoringTlsProvider);
            json!({"flow_id":id,"datagrams":packets.len(),"initial":initial.as_ref().ok(),
            "initial_error":initial.err().map(|e| e.to_string())})
        })
        .collect();
    let joint_capture_complete =
        joint_capture_complete(completed, &observations.lock(), &flow_summaries);
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
        .map(|hello| json!({"hello":hello,"cipher_suites":hello.cipher_suites(),"groups":hello.ext_supported_groups(),
            "signature_algorithms":hello.ext_signature_algorithms(),"alpn":hello.ext_alpn(),
            "extension_ids":hello.extensions().iter().map(|e| u16::from(e.id())).collect::<Vec<_>>()}));
    let certificate_rejected = connection_errors
        .lock()
        .iter()
        .any(|error| error.contains("CERTIFICATE_VERIFY_FAILED"));
    let expected_result_observed = if native_force_quic {
        // 直接限定 QUIC 的对照不要求先出现 TCP，但必须收齐实际 H3 证据。
        native_probe_finished && joint_capture_complete
    } else if native_probe {
        native_probe_finished && !tcp_requests.lock().is_empty()
    } else if learn_alt_svc {
        native_probe_finished && joint_capture_complete
    } else if allow_spki {
        completed
            && joint_capture_complete
            && ["/", "/fetch", "/done"].iter().all(|path| {
                observations
                    .lock()
                    .iter()
                    .any(|r| r["path"] == *path && r["version"] == "HTTP/3.0")
            })
    } else {
        !completed && observations.lock().is_empty() && certificate_rejected
    };
    let report = json!({"evidence_kind":if native_force_quic { "native_webview_scoped_quic_control" } else if native_probe { "native_webview_alt_svc" } else { "native_chromium_local_quic" }, "browser_version":version,"spki_override":allow_spki || native_force_quic,
        "expected_result_observed":expected_result_observed,"certificate_rejected":certificate_rejected,
        "native_probe":native_probe,"native_probe_force_quic":native_force_quic,"learn_alt_svc":learn_alt_svc,"native_probe_finished":native_probe_finished,"server_closes_tcp":close_tcp,
        "network_scenario":{"block_quic":block_quic,"drop_first_initial":drop_initial,"require_retry":require_retry,"drop_post_response":drop_post_response,
            "dropped_datagrams":dropped.load(std::sync::atomic::Ordering::Relaxed),"issued_retries":retries.load(std::sync::atomic::Ordering::Relaxed)},
        "trusted_origin":trusted.is_some(),"origin_hostname":hostname,"driver_success":driver_success,"tcp_requests":*tcp_requests.lock(),
        "h3_sample_complete":joint_capture_complete,
        "joint_capture_complete":joint_capture_complete,"selected_flow_id":selected_flow,"flows":flow_summaries,
        "server_error":server_error,"relay_error":relay_error,
        "connection_errors":*connection_errors.lock(),
        "completed":completed,"datagrams":datagrams.len(),"initial":flight.as_ref().ok(),"initial_error":flight.err().map(|e|e.to_string()),
        "transport_parameters":parameters,"tls":tls_shape,"h3":*observations.lock(),
        "limitations":[if trusted.is_some() {"controlled_tailnet_certificate"} else {"local_generated_certificate"},"not_a_production_webview_probe","not_a_replay_equivalence_test","no_0rtt_retry_or_migration_test"]});
    std::fs::write(
        out.join("h3-capture.json"),
        serde_json::to_vec_pretty(&report)?,
    )?;
    endpoint.close(0u32, b"probe complete");
    println!(
        "{}",
        json!({"completed":completed,"spki_override":allow_spki || native_force_quic,"requests":observations.lock().len()})
    );
    if !expected_result_observed {
        return Err(
            "H3 completion or certificate-rejection control did not match expectation".into(),
        );
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn joint_sample_requires_same_connection_complete_control_and_request_fields() {
        let mut complete = serde_json::to_value(
            rama::http::proto::h3::observation::ObservationCompleteness::default(),
        )
        .unwrap();
        for flag in complete.as_object_mut().unwrap().values_mut() {
            *flag = json!(true);
        }
        let last = json!({"flow_id":1,"request":{"fields_complete":true},
            "first_request_boundary":{"status":"ready","snapshot":{
                "settings_received":true,"connection_error":null,
                "encoder_bindings":{"complete":true},"completeness":complete}}});
        let mut early = last.clone();
        early["connection"]["settings_received"] = json!(false);
        early["connection"]["completeness"]["settings"] = json!(false);
        let flows = vec![json!({"flow_id":1,"initial":{"complete":true}})];
        assert!(joint_capture_complete(
            true,
            &[early.clone(), last.clone()],
            &flows
        ));
        assert!(joint_capture_complete(true, &[early.clone()], &flows));
        let mut pending = last.clone();
        pending["first_request_boundary"]["status"] = json!("timed_out");
        assert!(!joint_capture_complete(
            true,
            &[pending, last.clone()],
            &flows
        ));
        let mut other = last.clone();
        other["flow_id"] = json!(2);
        assert!(!joint_capture_complete(true, &[early, other], &flows));
        let mut truncated = last.clone();
        truncated["request"]["fields_complete"] = json!(false);
        assert!(!joint_capture_complete(
            true,
            &[truncated, last.clone()],
            &flows
        ));
        assert!(!joint_capture_complete(true, &[last.clone()], &[]));
        assert!(!joint_capture_complete(false, &[last], &flows));
        assert!(!joint_capture_complete(true, &[], &flows));
    }
}
