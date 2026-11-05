//! 只读 DoH 诊断；测本机到阿里云的生产解析路径，不代表手机网络质量。
//! cargo run --manifest-path core/net_core/Cargo.toml --example doh_probe
use std::sync::Arc;
use std::time::Instant;

use fluxdo_net::dns::DnsResolver;
use fluxdo_net::{
    client::{ExchangeInfo, HttpEgressClient},
    egress::EgressConnector,
};
use rama::{
    extensions::ExtensionsRef as _,
    futures::StreamExt as _,
    http::{Body, Request},
};

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    tracing_subscriber::fmt()
        .with_max_level(tracing::Level::DEBUG)
        .init();
    let resolver = Arc::new(
        DnsResolver::new("https://dns.alidns.com/dns-query", None, false, None, None).await?,
    );
    for phase in ["cold", "warm"] {
        let queries = ["linux.do", "cdn.ldstatic.com", "cdn3.ldstatic.com"]
            .into_iter()
            .map(|host| {
                let resolver = resolver.clone();
                async move {
                    let started = Instant::now();
                    match resolver.lookup_host(host, false).await {
                        Ok(result) => serde_json::json!({
                            "phase": phase, "host": host, "ms": started.elapsed().as_millis(),
                            "addresses": result.addrs, "ech": result.ech_config.is_some(),
                        }),
                        Err(error) => serde_json::json!({
                            "phase": phase, "host": host, "ms": started.elapsed().as_millis(),
                            "error": error.to_string(),
                        }),
                    }
                }
            });
        for result in rama::futures::future::join_all(queries).await {
            println!("{result}");
        }
    }
    if std::env::args().any(|arg| arg == "--connect") {
        let client = HttpEgressClient::new(
            Arc::new(EgressConnector::new(
                Some(resolver),
                None,
                None,
                None,
                std::time::Duration::from_secs(5),
            )),
            None,
        );
        for host in ["cdn.ldstatic.com", "cdn3.ldstatic.com"] {
            let started = Instant::now();
            let request = Request::builder()
                .uri(format!("https://{host}/cdn-cgi/trace"))
                .body(Body::empty())
                .unwrap();
            match client
                .send(
                    request,
                    Some(std::time::Duration::from_secs(12)),
                    Some(std::time::Duration::from_secs(8)),
                )
                .await
            {
                Ok(response) => {
                    let info = response.extensions().get_ref::<ExchangeInfo>().cloned();
                    let status = response.status().as_u16();
                    let mut stream = response.into_body().into_data_stream();
                    let mut bytes = 0;
                    // 只计数，不输出公网 IP 等 trace 响应内容。
                    let result = tokio::time::timeout(std::time::Duration::from_secs(8), async {
                        while let Some(chunk) = stream.next().await {
                            bytes += chunk?.len();
                        }
                        Ok::<_, rama::error::BoxError>(())
                    })
                    .await;
                    println!(
                        "{}",
                        serde_json::json!({"phase":"connect", "host":host, "status":status,
                        "ms":started.elapsed().as_millis(), "bytes":bytes,
                        "echApplied":info.as_ref().map(|i|i.ech_applied), "echAccepted":info.as_ref().map(|i|i.ech_accepted),
                        "bodyComplete":matches!(result, Ok(Ok(()))), "fingerprint":"standard"})
                    );
                }
                Err(error) => println!(
                    "{}",
                    serde_json::json!({"phase":"connect", "host":host,
                    "ms":started.elapsed().as_millis(), "error":error.to_string()})
                ),
            }
        }
    }
    Ok(())
}
