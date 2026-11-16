//! 用独立服务端限定算法，验证生产 Core 能实际完成协商，而不只是声明算法编号。
#[cfg(target_os = "linux")]
#[tokio::main]
async fn main() -> Result<(), rama::error::BoxError> {
    use fluxdo_net::{
        browser_tls,
        client::HttpEgressClient,
        egress::EgressConnector,
        mirror::{FingerprintTemplate, FingerprintTemplates},
    };
    use rama::{
        extensions::ExtensionsRef,
        http::{Body, Request, Version, body::util::BodyExt},
    };
    use std::{sync::Arc, time::Duration};
    let port: u16 = std::env::args()
        .nth(1)
        .ok_or("local server port required")?
        .parse()?;
    let samples = std::path::PathBuf::from(
        std::env::args()
            .nth(2)
            .ok_or("real browser sample directory required")?,
    );
    let reference: FingerprintTemplate =
        serde_json::from_slice(&std::fs::read(samples.join("reference.json"))?)?;
    let first: FingerprintTemplate =
        serde_json::from_slice(&std::fs::read(samples.join("browser-sample-0.json"))?)?;
    let second: FingerprintTemplate =
        serde_json::from_slice(&std::fs::read(samples.join("browser-sample-1.json"))?)?;
    let templates = Arc::new(FingerprintTemplates::new(None));
    templates.record_hello(&first.hello);
    templates.record_hello(&second.hello);
    let probe = Request::builder()
        .version(Version::HTTP_2)
        .header("user-agent", reference.user_agent.as_deref().unwrap_or(""))
        .header("accept-encoding", "gzip")
        .body(())?;
    probe.extensions().insert(reference.early_frames.clone());
    probe.extensions().insert(reference.pseudo_order.clone());
    templates.observe_probe_fetch(&probe);
    let template = templates.snapshot().ok_or("missing template")?;
    assert_eq!(
        serde_json::from_str::<serde_json::Value>(&templates.status_json())?["ready"],
        true
    );
    let capability = browser_tls::selected_capability_audit(
        &template.hello,
        template.tls_permute_extensions == Some(true),
    );
    assert_eq!(capability["backend"], "GnuTLS");
    let client = HttpEgressClient::new(
        Arc::new(EgressConnector::new(
            None,
            None,
            None,
            None,
            Duration::from_secs(5),
        )),
        Some(templates),
    );
    let response = client
        .send(
            Request::builder()
                .uri(format!("https://localhost:{port}/"))
                .header("user-agent", reference.user_agent.as_deref().unwrap_or(""))
                .body(Body::empty())?,
            Some(Duration::from_secs(8)),
            Some(Duration::from_secs(8)),
        )
        .await?;
    assert_eq!(response.status().as_u16(), 200);
    let body = response.into_body().collect().await?.to_bytes();
    assert_eq!(body.as_ref(), b"ok");
    println!(
        "{}",
        serde_json::json!({"passed":true,"backend":capability["backend"],
        "scope":"production_core_with_independently_restricted_tls13_server"})
    );
    Ok(())
}
#[cfg(not(target_os = "linux"))]
fn main() {
    eprintln!("此诊断仅验证 Linux 原生 TLS 后端");
}
