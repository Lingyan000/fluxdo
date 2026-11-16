//! 可重复回环诊断：真实浏览器探针采样 → 原生产 Core 客户端 → 本地 TLS/H2 采集。
use fluxdo_net::{
    browser_tls,
    client::{ExchangeInfo, HttpEgressClient},
    egress::EgressConnector,
    mirror::{FingerprintTemplate, FingerprintTemplates},
    probe::ProbeEndpoint,
};
use rama::{
    Layer, Service, ServiceInput,
    extensions::ExtensionsRef,
    http::{Body, Request, Response, body::util::BodyExt, server::HttpServer},
    net::address::{Domain, Host},
    rt::Executor,
    service::service_fn,
    tls::{
        boring::{core::x509::X509, server::TlsAcceptorLayer},
        server::{ServerAuthData, TlsServerConfig, peek_client_hello_from_input},
    },
};
use serde_json::{Value, json};
use std::{convert::Infallible, path::PathBuf, sync::Arc, time::Duration};

fn write_json(path: PathBuf, value: &impl serde::Serialize) {
    std::fs::write(path, serde_json::to_vec_pretty(value).unwrap()).unwrap();
}

/// 真实传输场景复用生产客户端；记录连接身份，不能只用 HTTP 200 判断复用成功。
async fn exchange(
    client: &HttpEgressClient,
    template: &FingerprintTemplate,
    port: u16,
    path: &str,
) -> Result<Value, rama::error::BoxError> {
    let request = Request::builder()
        .uri(format!("https://localhost:{port}/{path}"))
        .header("user-agent", template.user_agent.as_deref().unwrap_or(""))
        .header("accept", "*/*")
        .header("if-none-match", "\"fluxdo-validation\"")
        .header("sec-fetch-mode", "cors")
        .header("sec-ch-ua", "guessed-brand")
        .body(Body::empty())?;
    let response = client
        .send(
            request,
            Some(Duration::from_secs(8)),
            Some(Duration::from_secs(8)),
        )
        .await?;
    let info = response
        .extensions()
        .get_ref::<ExchangeInfo>()
        .expect("生产连接诊断");
    let result = json!({"path":path,"status":response.status().as_u16(),"version":format!("{:?}",response.version()),"connection_id":info.connection_id,"reused":info.reused,"tls_resumed":info.tls_resumed});
    let body = response.into_body().collect().await?.to_bytes();
    assert_eq!(body.as_ref(), b"ok");
    Ok(result)
}

#[tokio::main(worker_threads = 4)]
async fn main() -> Result<(), rama::error::BoxError> {
    let args: Vec<_> = std::env::args().collect();
    let browser = args.get(1).expect("browser executable");
    let out = PathBuf::from(args.get(2).expect("output directory"));
    std::fs::create_dir_all(&out)?;
    // fixture: 仅验证已有模板的真实出站，不冒充对应平台浏览器采样。
    let fixture = browser.strip_prefix("fixture:");
    if let Some(path) = fixture {
        let mut template: FingerprintTemplate = serde_json::from_slice(&std::fs::read(path)?)?;
        template.tls_permute_extensions = Some(browser_tls::is_chromium(&template.hello));
        template.low_entropy_client_hints = Some(Vec::new());
        template.user_agent = Some("FluxDO-Fixture-Lab/1".into());
        template.cache_revision = Some(fluxdo_net::mirror::cache_revision());
        write_json(out.join("template-cache.json"), &template);
    }
    let reference = Arc::new(FingerprintTemplates::new(Some(
        out.join("template-cache.json"),
    )));
    let probe = Arc::new(ProbeEndpoint::new(reference.clone())?);
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await?;
    let port = listener.local_addr()?.port();
    let probe_task = tokio::spawn(async move {
        loop {
            let Ok((socket, _)) = listener.accept().await else {
                break;
            };
            let probe = probe.clone();
            tokio::spawn(async move {
                let _ = probe.serve(socket).await;
            });
        }
    });
    for sample in 0..2 {
        if fixture.is_some() {
            break;
        }
        let previous: Value = serde_json::from_str(&reference.status_json())?;
        let previous_count = previous["tls_observations"].as_u64().unwrap_or(0);
        let mut browser_child = tokio::process::Command::new(browser)
            .args([
                "--headless",
                "--no-sandbox",
                "--disable-dev-shm-usage",
                "--ignore-certificate-errors",
                "--disable-background-networking",
                "--disable-component-update",
                "--no-first-run",
                "--remote-debugging-port=0",
            ])
            .arg(format!(
                "--user-data-dir={}",
                out.join(format!("browser-profile-{sample}")).display()
            ))
            .args(args.iter().skip(3))
            .arg(format!("https://localhost:{port}/fluxdo-probe"))
            .stdout(std::fs::File::create(
                out.join(format!("browser-{sample}.stdout")),
            )?)
            .stderr(std::fs::File::create(
                out.join(format!("browser-{sample}.stderr")),
            )?)
            .kill_on_drop(true)
            .spawn()?;
        let driver_started = std::time::Instant::now();
        if std::env::var_os("FLUXDO_LAB_EXTERNAL_DRIVER").is_some() {
            // 云端模拟器首次启动不属于页面采样耗时，不能在应用尚未启动时就开启下一轮。
            // 外部驱动自行等待页面完成并关闭应用；这里只扩展实验等待，不改生产 15 秒超时。
            let status =
                tokio::time::timeout(Duration::from_secs(95), browser_child.wait()).await??;
            write_json(
                out.join(format!("browser-driver-{sample}.json")),
                &json!({
                    "elapsed_ms":driver_started.elapsed().as_millis(),"success":status.success(),"code":status.code()
                }),
            );
            if !status.success() {
                return Err("external browser driver failed; see browser logs".into());
            }
        } else {
            for _ in 0..100 {
                let status: Value = serde_json::from_str(&reference.status_json())?;
                if status["tls_observations"].as_u64().unwrap_or(0) > previous_count
                    && reference
                        .captured_snapshot()
                        .is_some_and(|t| t.low_entropy_client_hints.is_some())
                {
                    break;
                }
                tokio::time::sleep(Duration::from_millis(150)).await;
            }
            let _ = browser_child.kill().await;
        }
        if let Some(t) = reference.captured_snapshot() {
            write_json(out.join(format!("browser-sample-{sample}.json")), &t);
        }
        let state: Value = serde_json::from_str(&reference.status_json())?;
        write_json(out.join(format!("probe-status-{sample}.json")), &state);
        tokio::time::sleep(Duration::from_millis(150)).await;
    }
    let template = reference
        .captured_snapshot()
        .ok_or("browser probe did not capture TLS/H2")?;
    write_json(out.join("reference.json"), &template);
    let status: Value = serde_json::from_str(&reference.status_json())?;
    assert_eq!(status["ready"], true, "两轮采样仍未完成校准");
    let cached = FingerprintTemplates::with_profile(
        Some(out.join("template-cache.json")),
        std::env::consts::OS,
        template.user_agent.as_deref(),
    );
    let cached_status: Value = serde_json::from_str(&cached.status_json())?;
    assert_eq!(cached_status["ready"], true, "完整缓存必须可恢复校准状态");
    write_json(out.join("cache-status.json"), &cached_status);
    // 只为当前实验进程提供本地信任根；不更改系统证书或生产校验逻辑。
    let (chain, key) = rama_crypto::cert::generate_server_auth(
        rama_crypto::cert::GeneratedServerAuthConfig::generated_ca_for(Domain::from_static(
            "localhost",
        )),
    )?;
    let ca_path = std::env::var("SSL_CERT_FILE").expect("set SSL_CERT_FILE to lab-only path");
    std::fs::write(
        ca_path,
        X509::from_der(chain.last().unwrap().as_ref())?.to_pem()?,
    )?;
    let mut emitted = Vec::new();
    #[cfg(target_os = "linux")]
    if let Ok(hello) = fluxdo_net::linux_tls::emit_for(Some(&template.hello)) {
        write_json(out.join("native-capability-hello.json"), &hello);
    }
    for _ in 0..8 {
        let hello = browser_tls::emit_client_hello(
            browser_tls::build_with_permutation(
                &template.hello,
                Host::from_static("localhost"),
                None,
                None,
                template.tls_permute_extensions == Some(true),
            )?
            .connector_data,
        )?;
        #[cfg(target_os = "linux")]
        let hello = if fluxdo_net::linux_tls::matches(&template.hello, template.tls_permute_extensions == Some(true)) {
            fluxdo_net::linux_tls::emit_for(Some(&template.hello))?
        } else { hello };
        emitted.push(hello);
    }
    write_json(out.join("emitted-hellos.json"), &emitted);
    let mut no_permutation = Vec::new();
    for _ in 0..8 {
        let mut built =
            browser_tls::build(&template.hello, Host::from_static("localhost"), None, None)?;
        built.connector_data.config.set_permute_extensions(false);
        no_permutation.push(browser_tls::emit_client_hello(built.connector_data)?);
    }
    write_json(out.join("emitted-no-permutation.json"), &no_permutation);

    let tls = TlsServerConfig::new()
        .with_server_auth(ServerAuthData::new(chain, key))
        .with_alpn_http_auto();
    let collected = Arc::new(FingerprintTemplates::new(None));
    let collector = collected.clone();
    let observed_headers = Arc::new(parking_lot::Mutex::new(Vec::<Value>::new()));
    let headers_sink = observed_headers.clone();
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await?;
    let sink_port = listener.local_addr()?.port();
    let sink_task = tokio::spawn(async move {
        loop {
            let Ok((socket, _)) = listener.accept().await else {
                break;
            };
            let collector = collector.clone();
            let tls = tls.clone();
            let headers_sink = headers_sink.clone();
            tokio::spawn(async move {
                let (input, hello) = peek_client_hello_from_input(
                    ServiceInput::new(socket),
                    Some(Duration::from_secs(5)),
                )
                .await
                .unwrap();
                if let Some(hello) = hello {
                    collector.record_hello(&hello);
                }
                let mut server = HttpServer::auto(Executor::new());
                server.h2_mut().set_observe_early_frames(true);
                let service = server.service(service_fn(move |request: Request| {
                    // 该回环服务只接收本实验主动发起的 API 请求，不能依赖
                    // Sec-Fetch-Mode 识别它们，否则修复旧 WebKit 后反而漏采。
                    collector.observe_probe_fetch(&request);
                    let headers: Vec<_> = request
                        .headers()
                        .iter()
                        .map(|(k, v)| json!([k.as_str(), v.to_str().unwrap_or("?")]))
                        .collect();
                    let hpack_indexing: std::collections::BTreeMap<_, _> = request.headers().iter()
                        .filter_map(|(name, value)| value.hpack_indexing().map(|index| (name.as_str(), index)))
                        .collect();
                    headers_sink
                        .lock()
                        .push(json!({"uri":request.uri().to_string(),"headers":headers,"hpack_indexing":hpack_indexing}));
                    let delayed = request.uri().to_string().contains("slow-response");
                    async move {
                        if delayed {
                            tokio::time::sleep(Duration::from_millis(200)).await;
                        }
                        Ok::<_, Infallible>(Response::new(Body::from("ok")))
                    }
                }));
                if let Err(e) = TlsAcceptorLayer::new(tls)
                    .into_layer(service)
                    .serve(input)
                    .await
                {
                    eprintln!("collector: {e}");
                }
            });
        }
    });
    let client = HttpEgressClient::new(
        Arc::new(EgressConnector::new(
            None,
            None,
            None,
            None,
            Duration::from_secs(5),
        )),
        Some(reference.clone()),
    );
    let mut results = Vec::new();
    for n in 0..3 {
        let mut request =
            Request::builder().uri(format!("https://localhost:{sink_port}/capture/{n}"));
        // 给生产客户端提供浏览器采样 UA 和常用 fetch 请求头；头部重排仍由生产代码执行。
        request = request
            .header("user-agent", template.user_agent.as_deref().unwrap_or(""))
            .header("accept", "*/*")
            .header("if-none-match", "\"fluxdo-validation\"")
            .header("sec-fetch-mode", "cors")
            .header("sec-fetch-site", "same-origin")
            .header("sec-fetch-dest", "empty")
            .header("accept-language", "en-US")
            .header("sec-ch-ua", "guessed-brand")
            .header("sec-ch-ua-mobile", "?1");
        match client
            .send(
                request.body(Body::empty())?,
                Some(Duration::from_secs(8)),
                Some(Duration::from_secs(8)),
            )
            .await
        {
            Ok(response) => {
                results.push(json!({"status":response.status().as_u16(),"version":format!("{:?}",response.version())}));
                let _ = response.into_body().collect().await?;
            }
            Err(error) => {
                results.push(json!({"error":error.to_string()}));
                break;
            }
        }
        if let Some(t) = collected.captured_snapshot() {
            write_json(out.join(format!("core-{n}.json")), &t);
        }
        client.reset_connections().await;
    }
    let initial = |t: &fluxdo_net::mirror::FingerprintTemplate| {
        serde_json::to_value(&t.early_frames)
            .unwrap()
            .as_array()
            .unwrap()
            .iter()
            .filter(|f| f.get("Settings").is_none_or(|s| s["flags"] != 1))
            .cloned()
            .collect::<Vec<_>>()
    };
    assert_eq!(results.len(), 3);
    for n in 0..3 {
        assert_eq!(results[n]["status"], 200);
        let actual: fluxdo_net::mirror::FingerprintTemplate =
            serde_json::from_slice(&std::fs::read(out.join(format!("core-{n}.json")))?)?;
        assert_eq!(initial(&template), initial(&actual));
        assert_eq!(
            serde_json::to_value(&template.pseudo_order)?,
            serde_json::to_value(&actual.pseudo_order)?
        );
        assert_eq!(
            template.low_entropy_client_hints,
            actual.low_entropy_client_hints
        );
    }
    write_json(out.join("core-headers.json"), &*observed_headers.lock());
    let mut scenarios = Vec::new();
    let first = exchange(&client, &template, sink_port, "warm/first").await?;
    let second = exchange(&client, &template, sink_port, "warm/second").await?;
    assert_eq!(first["connection_id"], second["connection_id"]);
    assert_eq!(second["reused"], true);
    write_json(
        out.join("scenario-reuse-core.json"),
        &collected.captured_snapshot().unwrap(),
    );
    scenarios.push(
        json!({"scenario":"sequential_reuse", "requests":[first.clone(),second],"passed":true}),
    );
    client.reset_connections().await;
    let reconnected = exchange(&client, &template, sink_port, "network-reset").await?;
    assert_ne!(first["connection_id"], reconnected["connection_id"]);
    assert_eq!(reconnected["reused"], false);
    write_json(
        out.join("scenario-reset-core.json"),
        &collected.captured_snapshot().unwrap(),
    );
    scenarios
        .push(json!({"scenario":"connection_pool_reset", "requests":[reconnected],"passed":true}));
    client.reset_connections().await;
    let (a, b, c, d) = tokio::try_join!(
        exchange(&client, &template, sink_port, "parallel/0"),
        exchange(&client, &template, sink_port, "parallel/1"),
        exchange(&client, &template, sink_port, "parallel/2"),
        exchange(&client, &template, sink_port, "parallel/3"),
    )?;
    for item in [&b, &c, &d] {
        assert_eq!(a["connection_id"], item["connection_id"]);
    }
    write_json(
        out.join("scenario-parallel-core.json"),
        &collected.captured_snapshot().unwrap(),
    );
    scenarios.push(json!({"scenario":"cold_parallel_h2", "requests":[a,b,c,d],"passed":true}));
    let restored = HttpEgressClient::new(
        Arc::new(EgressConnector::new(
            None,
            None,
            None,
            None,
            Duration::from_secs(5),
        )),
        Some(Arc::new(cached)),
    );
    let restarted = exchange(&restored, &template, sink_port, "restored-cache").await?;
    let actual = collected
        .captured_snapshot()
        .ok_or("缓存恢复请求缺少采集")?;
    assert_eq!(initial(&template), initial(&actual));
    assert_eq!(
        template.low_entropy_client_hints,
        actual.low_entropy_client_hints
    );
    write_json(out.join("restored-core.json"), &actual);
    scenarios.push(
        json!({"scenario":"new_client_from_disk_cache", "requests":[restarted],"passed":true}),
    );
    let slow = Request::builder()
        .uri(format!("https://localhost:{sink_port}/slow-response"))
        .header("user-agent", template.user_agent.as_deref().unwrap_or(""))
        .header("sec-fetch-mode", "cors")
        .body(Body::empty())?;
    let failure = client
        .send(
            slow,
            Some(Duration::from_secs(8)),
            Some(Duration::from_millis(25)),
        )
        .await
        .expect_err("慢响应必须触发响应头超时");
    assert!(
        failure
            .downcast_ref::<fluxdo_net::NetError>()
            .is_some_and(|e| matches!(e, fluxdo_net::NetError::ReceiveTimeout)),
        "实际错误：{failure}"
    );
    let recovered = exchange(&client, &template, sink_port, "after-timeout").await?;
    write_json(
        out.join("scenario-timeout-core.json"),
        &collected.captured_snapshot().unwrap(),
    );
    scenarios.push(json!({"scenario":"response_timeout_then_success","injected_response_delay_ms":200,"head_timeout_ms":25,"error":failure.to_string(),"requests":[recovered],"passed":true}));
    write_json(out.join("scenarios.json"), &scenarios);
    write_json(out.join("all-core-headers.json"), &*observed_headers.lock());
    let ja4 = |hello: &rama::tls::client::ClientHello| {
        rama::tls::fingerprint::Ja4::compute_from_client_hello(hello)
            .map(|v| v.to_string())
            .ok()
    };
    let summary = json!({"user_agent":template.user_agent, "chromium_detected":browser_tls::is_chromium(&template.hello),
        "calibration":status,"browser_flags":args.iter().skip(3).collect::<Vec<_>>(),"reference_ja4":ja4(&template.hello),"emitted_ja4":emitted.iter().map(ja4).collect::<Vec<_>>(),
        "requests":results,"doh":false,"webview_mitm":false,"evidence_kind":if fixture.is_some(){"fixture_replay"}else{"live_browser"},"fixture":fixture});
    write_json(out.join("summary.json"), &summary);
    println!("{}", serde_json::to_string_pretty(&summary)?);
    probe_task.abort();
    sink_task.abort();
    Ok(())
}
