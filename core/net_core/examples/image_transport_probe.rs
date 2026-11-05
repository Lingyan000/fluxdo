//! Read-only transport sample; not an Android rendering benchmark.
use fluxdo_net::{
    client::{ExchangeInfo, HttpEgressClient},
    dns::DnsResolver,
    egress::EgressConnector,
};
use rama::{
    extensions::ExtensionsRef,
    http::{Body, Request, body::util::BodyExt},
};
use std::{
    sync::Arc,
    time::{Duration, Instant},
};

#[tokio::main]
async fn main() -> Result<(), rama::error::BoxError> {
    tracing_subscriber::fmt()
        .with_env_filter("fluxdo_net=info")
        .with_target(false)
        .init();
    let doh = std::env::args().any(|arg| arg == "--doh");
    let url = std::env::args()
        .find(|arg| arg.starts_with("https://"))
        .unwrap_or_else(|| "https://www.cloudflare.com/favicon.ico".into());
    let dns = if doh {
        Some(Arc::new(
            DnsResolver::new("https://dns.alidns.com/dns-query", None, false, None, None).await?,
        ))
    } else {
        None
    };
    let client = HttpEgressClient::new(
        Arc::new(EgressConnector::new(
            dns,
            None,
            None,
            None,
            Duration::from_secs(8),
        )),
        None,
    );
    let mut times = Vec::new();
    for index in 0..8 {
        let start = Instant::now();
        let request = Request::builder().uri(url.as_str()).body(Body::empty())?;
        let response = client
            .send(
                request,
                Some(Duration::from_secs(12)),
                Some(Duration::from_secs(8)),
            )
            .await?;
        let info = response.extensions().get_ref::<ExchangeInfo>().cloned();
        let status = response.status();
        let version = response.version();
        let body = response.into_body().collect().await?.to_bytes();
        let elapsed = start.elapsed().as_millis();
        times.push(elapsed);
        let hash: String = rama_crypto::dep::boring::sha::sha256(&body)
            .iter()
            .map(|b| format!("{b:02x}"))
            .collect();
        println!(
            "sample={index} doh={doh} status={status} version={version:?} elapsed_ms={elapsed} bytes={} sha256={hash} connection={info:?}",
            body.len()
        );
        // Give bounded background protocol discovery a chance between independent requests.
        if index == 0 {
            tokio::time::sleep(Duration::from_secs(4)).await;
        }
    }
    times.sort();
    println!(
        "samples={} p50_ms={} p95_ms={} h2={} h3={} established={}",
        times.len(),
        times[3],
        times[7],
        client.pooled_connections().0,
        client.pooled_http3_connections(),
        client.established_connections()
    );
    client.reset_connections().await;
    Ok(())
}
