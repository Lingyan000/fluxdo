//! 可重复的传输采样；不包含图片解码和 UI 渲染。
use fluxdo_net::{client::HttpEgressClient, egress::EgressConnector};
use rama::http::{Body, Request, body::util::BodyExt};
use std::{
    sync::Arc,
    time::{Duration, Instant},
};

#[tokio::main(worker_threads = 4)]
async fn main() -> Result<(), rama::error::BoxError> {
    let args: Vec<_> = std::env::args().collect();
    let url = args.get(1).expect("URL").clone();
    let count: usize = args.get(2).map_or(Ok(600), |v| v.parse())?;
    let concurrency: usize = args.get(3).map_or(Ok(12), |v| v.parse())?;
    assert!(count > 0 && concurrency > 0);
    let client = Arc::new(HttpEgressClient::new(
        Arc::new(EgressConnector::new(
            None,
            None,
            None,
            None,
            Duration::from_secs(8),
        )),
        None,
    ));
    let permits = Arc::new(tokio::sync::Semaphore::new(concurrency));
    let started = Instant::now();
    let mut tasks = tokio::task::JoinSet::new();
    for _ in 0..count {
        let permit = permits.clone().acquire_owned().await?;
        let client = client.clone();
        let url = url.clone();
        tasks.spawn(async move {
            let _permit = permit;
            let started = Instant::now();
            let response = client
                .send(
                    Request::builder().uri(url).body(Body::empty())?,
                    Some(Duration::from_secs(12)),
                    Some(Duration::from_secs(8)),
                )
                .await?;
            assert!(response.status().is_success());
            let body = response.into_body().collect().await?.to_bytes();
            Ok::<_, rama::error::BoxError>((started.elapsed().as_secs_f64() * 1000.0, body.len()))
        });
    }
    let mut times = Vec::new();
    let mut bytes = 0;
    while let Some(result) = tasks.join_next().await {
        let (ms, size) = result??;
        times.push(ms);
        bytes += size;
    }
    times.sort_by(f64::total_cmp);
    println!(
        "{}",
        serde_json::json!({
            "requests": count, "concurrency": concurrency, "bytes": bytes,
            "elapsed_ms": started.elapsed().as_secs_f64() * 1000.0,
            "p50_ms": times[(count - 1) / 2], "p95_ms": times[(count * 95 / 100).min(count - 1)],
            "established": client.established_connections(),
        })
    );
    client.reset_connections().await;
    Ok(())
}
