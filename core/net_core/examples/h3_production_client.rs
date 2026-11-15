//! 诊断宿主：实际浏览器完成生产 H3 探针后，生产 Core 向独立采集端发送请求。
use fluxdo_net::{
    client::HttpEgressClient,
    egress::EgressConnector,
    listener::Listener,
    mirror::{FingerprintTemplate, FingerprintTemplates},
};
use rama::{
    error::BoxError,
    extensions::ExtensionsRef,
    http::{Body, Request, Version, body::util::BodyExt},
};
use std::{path::PathBuf, sync::Arc, time::Duration};
#[tokio::main]
async fn main() -> Result<(), BoxError> {
    let url = std::env::args().last().ok_or("capture URL required")?;
    let out = PathBuf::from(std::env::var("FLUXDO_H3_OUTPUT")?);
    std::fs::create_dir_all(&out)?;
    let samples = PathBuf::from(std::env::var("FLUXDO_TCP_SAMPLES")?);
    let reference: FingerprintTemplate =
        serde_json::from_slice(&std::fs::read(samples.join("reference.json"))?)?;
    let first: FingerprintTemplate =
        serde_json::from_slice(&std::fs::read(samples.join("browser-sample-0.json"))?)?;
    let second: FingerprintTemplate =
        serde_json::from_slice(&std::fs::read(samples.join("browser-sample-1.json"))?)?;
    let templates = Arc::new(FingerprintTemplates::new(None));
    templates.record_hello(&first.hello);
    templates.record_hello(&second.hello);
    let mut probe = Request::builder()
        .version(Version::HTTP_2)
        .header(
            "user-agent",
            reference.user_agent.as_deref().ok_or("missing UA")?,
        )
        .header(
            "accept-encoding",
            reference
                .accept_encoding
                .as_deref()
                .ok_or("missing sampled Accept-Encoding")?,
        )
        .body(())?;
    for (name, value) in reference.low_entropy_client_hints.iter().flatten() {
        probe.headers_mut().append(
            rama::http::HeaderName::from_bytes(name.as_bytes())?,
            rama::http::HeaderValue::from_str(value)?,
        );
    }
    probe.extensions().insert(reference.early_frames.clone());
    probe.extensions().insert(reference.pseudo_order.clone());
    templates.observe_probe_fetch(&probe);
    let egress = Arc::new(EgressConnector::new(
        None,
        None,
        None,
        None,
        Duration::from_secs(5),
    ));
    let listener = Arc::new(Listener::new(egress.clone(), None, templates.clone())?);
    let socket = listener.bind("127.0.0.1", 0).await?;
    let task = tokio::spawn(listener.clone().serve(socket));
    let state: serde_json::Value = serde_json::from_str(&templates.status_json())?;
    let browser = std::env::var("FLUXDO_H3_BROWSER")?;
    std::fs::write(
        out.join("driver-configuration.json"),
        serde_json::to_vec_pretty(&serde_json::json!({
        "native_driver":std::env::var_os("FLUXDO_H3_NATIVE_DRIVER").is_some(),
        "force_quic":std::env::var_os("FLUXDO_H3_FORCE_QUIC").is_some(),
        "tcp_calibration_source":samples,"probe":"production Listener / HttpEgressClient",
        "physical_device":false}))?,
    )?;
    for (index, port) in state["h3"]["probe_ports"]
        .as_array()
        .ok_or("missing probe ports")?
        .iter()
        .enumerate()
    {
        let port = port.as_u64().unwrap();
        let spki = state["h3"]["probe_spki"][port.to_string()]
            .as_str()
            .ok_or("missing probe SPKI")?;
        let helper = tokio::net::TcpListener::bind("127.0.0.1:0").await?;
        let helper_port = helper.local_addr()?.port();
        let html = format!(
            "<!doctype html><script>(async()=>{{for(let i=0;i<8;i++){{let r=await fetch('https://localhost:{port}/fluxdo-h3/fetch');if(await r.text()==='h3-ready')break;await new Promise(r=>setTimeout(r,150));}}document.title='done';}})()</script>"
        );
        let helper_task = tokio::spawn(async move {
            use rama::{
                Service, ServiceInput,
                http::{Response, server::HttpServer},
                rt::Executor,
                service::service_fn,
            };
            let mut connections = tokio::task::JoinSet::new();
            loop {
                let Ok((stream, _)) = helper.accept().await else {
                    break;
                };
                let html = html.clone();
                connections.spawn(async move {
                    let service =
                        HttpServer::auto(Executor::new()).service(service_fn(move |_: Request| {
                            let html = html.clone();
                            async move {
                                Ok::<_, std::convert::Infallible>(
                                    Response::builder()
                                        .header("content-type", "text/html")
                                        .body(Body::from(html))
                                        .unwrap(),
                                )
                            }
                        }));
                    let _ = tokio::time::timeout(
                        Duration::from_secs(15),
                        service.serve(ServiceInput::new(stream)),
                    )
                    .await;
                });
            }
        });
        let mut command = tokio::process::Command::new(&browser);
        if std::env::var_os("FLUXDO_H3_NATIVE_DRIVER").is_some() {
            // 仅诊断宿主使用：每个独立探针只信任当前临时证书，并保存网络决策证据。
            command.env(
                "FLUXDO_NATIVE_NETLOG_PATH",
                out.join(format!("browser-netlog-{index}.json")),
            );
            if std::env::var("FLUXDO_H3_DIAGNOSTIC_SPKI").as_deref() == Ok("1") {
                command.env("FLUXDO_NATIVE_PROBE_SPKI", spki);
            } else {
                command.env_remove("FLUXDO_NATIVE_PROBE_SPKI");
            }
            command.arg(format!("https://localhost:{port}/fluxdo-h3"));
        } else {
            if std::env::var_os("FLUXDO_H3_FORCE_QUIC").is_some() {
                command.arg(format!("--origin-to-force-quic-on=localhost:{port}"));
            }
            command
                .args([
                    "--headless",
                    "--no-sandbox",
                    "--disable-dev-shm-usage",
                    "--disable-background-networking",
                    "--no-first-run",
                    "--enable-quic",
                    "--remote-debugging-port=0",
                    "--host-resolver-rules=MAP localhost 127.0.0.1",
                ])
                .arg(format!(
                    "--log-net-log={}",
                    out.join(format!("browser-netlog-{index}.json")).display()
                ))
                .arg(format!("--ignore-certificate-errors-spki-list={spki}"))
                .arg(format!(
                    "--user-data-dir={}",
                    out.join(format!("browser-profile-{index}")).display()
                ))
                .arg(format!("http://localhost:{helper_port}/"));
        }
        let mut child = command
            .stdout(std::fs::File::create(
                out.join(format!("browser-{index}.stdout")),
            )?)
            .stderr(std::fs::File::create(
                out.join(format!("browser-{index}.stderr")),
            )?)
            .kill_on_drop(true)
            .spawn()?;
        for _ in 0..90 {
            tokio::time::sleep(Duration::from_millis(200)).await;
            let state: serde_json::Value = serde_json::from_str(&templates.status_json())?;
            std::fs::write(out.join("status.json"), serde_json::to_vec_pretty(&state)?)?;
            if state["h3"]["observations"].as_u64().unwrap_or(0) > index as u64 {
                break;
            }
        }
        if std::env::var_os("FLUXDO_H3_NATIVE_DRIVER").is_some() {
            let _ = tokio::time::timeout(Duration::from_secs(2), child.wait()).await;
        }
        let _ = child.kill().await;
        helper_task.abort();
    }
    let state: serde_json::Value = serde_json::from_str(&templates.status_json())?;
    std::fs::write(out.join("status.json"), serde_json::to_vec_pretty(&state)?)?;
    #[cfg(debug_assertions)]
    std::fs::write(
        out.join("calibration.json"),
        serde_json::to_vec_pretty(&templates.h3.calibration_diagnostics())?,
    )?;
    let (_, profile) = templates
        .h3
        .snapshot(reference.user_agent.as_deref())
        .ok_or("production H3 calibration failed")?;
    std::fs::write(
        out.join("profile.json"),
        serde_json::to_vec_pretty(&serde_json::json!({
        "hello":profile.sample.hello,"flight":profile.sample.flight,"parameters":profile.sample.parameters,
        "boundary":profile.sample.boundary,"warm_boundary":profile.sample.warm_boundary,"wire_fields":profile.sample.wire_fields,"quic":profile.quic,"permute_tls":profile.permute_tls,
        "header_order":profile.sample.header_order,"pseudo_order":profile.sample.pseudo_order}))?,
    )?;
    let client = HttpEgressClient::new(egress, Some(templates));
    let origin = url.trim_end_matches("/fluxdo-probe");
    let scenario = std::env::var("FLUXDO_H3_NETWORK_SCENARIO").unwrap_or_default();
    let expect_tcp = scenario == "blocked";
    let rounds = if scenario == "reset" { 2 } else { 1 };
    let mut results = Vec::new();
    let mut reached = false;
    for round in 0..rounds {
        if round > 0 {
            client.reset_connections().await;
        }
        reached = false;
        for attempt in 0..12 {
            let response = client
                .send(
                    Request::builder()
                        .uri(format!("{origin}/fluxdo-probe/fetch"))
                        .header("user-agent", reference.user_agent.as_deref().unwrap())
                        .header("accept", "*/*")
                        .body(Body::empty())?,
                    Some(Duration::from_secs(5)),
                    Some(Duration::from_secs(5)),
                )
                .await?;
            let version = response.version();
            let info = response
                .extensions()
                .get_ref::<fluxdo_net::client::ExchangeInfo>()
                .cloned();
            let body = response.into_body().collect().await?.to_bytes();
            results.push(serde_json::json!({"round":round,"attempt":attempt,"version":format!("{version:?}"),
                "connection_id":info.as_ref().map(|i|i.connection_id),"resumed":info.as_ref().map(|i|i.tls_resumed),
                "body":String::from_utf8_lossy(&body)}));
            if version == Version::HTTP_3 {
                reached = true;
                break;
            }
            tokio::time::sleep(Duration::from_millis(250)).await;
        }
        if expect_tcp == reached {
            return Err("production protocol did not match scenario expectation".into());
        }
        if !scenario.is_empty() && round + 1 == rounds {
            // 固定合成数据跨越多个 DATA 帧，服务端校验摘要，不能只比较长度。
            let payload = if scenario == "requests" {
                (0..65539).map(|i| (i % 251) as u8).collect::<Vec<_>>()
            } else {
                b"single-write".to_vec()
            };
            let response = client
                .send(
                    Request::builder()
                        .method("POST")
                        .uri(format!("{origin}/fluxdo-probe/write"))
                        .header("user-agent", reference.user_agent.as_deref().unwrap())
                        .header("content-type", "application/octet-stream")
                        .body(Body::from(payload))?,
                    Some(Duration::from_secs(5)),
                    Some(Duration::from_secs(5)),
                )
                .await?;
            let version = response.version();
            response.into_body().collect().await?;
            results.push(serde_json::json!({"method":"POST","version":format!("{version:?}")}));
        }
        if scenario == "requests" {
            let response=client.send(Request::builder()
                .uri(format!("{origin}/fluxdo-probe/conditional"))
                .header("user-agent",reference.user_agent.as_deref().unwrap())
                .header("if-none-match","\"fluxdo-lab-etag\"")
                .body(Body::empty())?,Some(Duration::from_secs(5)),Some(Duration::from_secs(5))).await?;
            let version=response.version();
            response.into_body().collect().await?;
            results.push(serde_json::json!({"scenario":"conditional","version":format!("{version:?}")}));
            let send_parallel=|index| {
                let client=&client;
                let origin=origin.to_owned();
                let ua=reference.user_agent.clone().unwrap();
                async move {
                    let response=client.send(Request::builder().uri(format!("{origin}/fluxdo-probe/parallel-{index}"))
                        .header("user-agent",ua).body(Body::empty())?,Some(Duration::from_secs(5)),Some(Duration::from_secs(5))).await?;
                    let version=response.version();
                    let connection=response.extensions().get_ref::<fluxdo_net::client::ExchangeInfo>().map(|i|i.connection_id);
                    response.into_body().collect().await?;
                    Ok::<_,BoxError>(serde_json::json!({"scenario":"parallel","index":index,"version":format!("{version:?}"),"connection_id":connection}))
                }
            };
            let (a,b,c)=tokio::try_join!(send_parallel(0),send_parallel(1),send_parallel(2))?;
            results.extend([a,b,c]);
        }
        for path in [
            "done",
            if round + 1 == rounds {
                "finished"
            } else {
                "warm"
            },
        ] {
            let response = client
                .send(
                    Request::builder()
                        .uri(format!("{origin}/fluxdo-probe/{path}"))
                        .header("user-agent", reference.user_agent.as_deref().unwrap())
                        .body(Body::empty())?,
                    Some(Duration::from_secs(5)),
                    Some(Duration::from_secs(5)),
                )
                .await?;
            response.into_body().collect().await?;
        }
    }
    std::fs::write(
        out.join("core-requests.json"),
        serde_json::to_vec_pretty(&results)?,
    )?;
    listener.stop();
    task.abort();
    if !reached && !expect_tcp {
        return Err("production core did not negotiate H3".into());
    }
    println!(
        "{}",
        serde_json::json!({"production_h3":reached,"scenario":scenario,"requests":results})
    );
    Ok(())
}
