//! 真实 TLS 回环实验：只替换服务端信任根，不修改系统信任或生产安全策略。
use fluxdo_net::{
    NetError,
    egress::{EgressConnector, HandshakeFailure},
};
use rama::{
    ServiceInput,
    net::address::{Domain, Host},
    tls::{
        boring::{
            client::{TlsConnectorData, tls_connect},
            core::{
                pkey::PKey,
                ssl::{SslAcceptor, SslMethod},
                tokio::accept,
                x509::X509,
            },
        },
        client::TlsClientConfig,
    },
};
use std::{
    sync::{
        Arc,
        atomic::{AtomicUsize, Ordering},
    },
    time::{Duration, Instant},
};
use tokio::io::AsyncReadExt;

#[tokio::main(worker_threads = 2)]
async fn main() -> Result<(), rama::error::BoxError> {
    let args: Vec<_> = std::env::args().collect();
    let backup = args.get(1).is_some_and(|v| v == "backup");
    let scenario = args.get(2).map(String::as_str).unwrap_or("normal");
    assert!(["normal", "slow", "stall"].contains(&scenario));
    let count: usize = args.get(3).map_or(Ok(20), |v| v.parse())?;
    let (chain, key) = rama_crypto::cert::generate_server_auth(
        rama_crypto::cert::GeneratedServerAuthConfig::generated_ca_for(Domain::from_static(
            "localhost",
        )),
    )?;
    let mut server = SslAcceptor::mozilla_intermediate_v5(SslMethod::tls())?;
    let cert = X509::from_der(chain[0].as_ref())?;
    let key = PKey::private_key_from_der(key.secret_der())?;
    server.set_certificate(&cert)?;
    server.set_private_key(&key)?;
    let server = Arc::new(server.build());
    let config = TlsClientConfig::new()
        .with_server_name(Host::from_static("localhost"))
        .try_with_server_trust_anchors([chain.last().unwrap().clone()])?;
    let mut times = Vec::new();
    let connections = Arc::new(AtomicUsize::new(0));
    let active = Arc::new(AtomicUsize::new(0));
    let peak = Arc::new(AtomicUsize::new(0));
    let mut successes = 0;
    for _ in 0..count {
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await?;
        let port = listener.local_addr()?.port();
        let server = server.clone();
        let connections = connections.clone();
        let server_active = active.clone();
        let peak = peak.clone();
        let stall = scenario == "stall";
        let slow = scenario == "slow";
        let serving = tokio::spawn(async move {
            let mut tasks = tokio::task::JoinSet::new();
            let mut first = true;
            loop {
                tokio::select! {
                    socket = listener.accept() => {
                        let (mut socket, _) = socket.unwrap();
                        connections.fetch_add(1, Ordering::SeqCst);
                        peak.fetch_max(server_active.fetch_add(1, Ordering::SeqCst) + 1, Ordering::SeqCst);
                        let server = server.clone();
                        let active = server_active.clone();
                        let blackhole = first && stall;
                        first = false;
                        tasks.spawn(async move {
                            if blackhole {
                                let mut buf = [0u8; 8192];
                                while socket.read(&mut buf).await.unwrap_or(0) > 0 {}
                            } else {
                                if slow { tokio::time::sleep(Duration::from_millis(600)).await; }
                                if let Ok(mut tls) = accept(&server, socket).await {
                                    let mut buf = [0u8; 16];
                                    let _ = tls.read(&mut buf).await;
                                }
                            }
                            active.fetch_sub(1, Ordering::SeqCst);
                        });
                    }
                    _ = tasks.join_next(), if !tasks.is_empty() => {}
                }
            }
        });
        let connector = EgressConnector::new(None, None, None, None, Duration::from_secs(3));
        let config = config.clone();
        let handshake = move |socket, _| {
            let data = TlsConnectorData::try_from(&config).unwrap();
            async move {
                tls_connect(ServiceInput::new(socket), Some(data))
                    .await
                    .map_err(|e| HandshakeFailure::retry(NetError::Proxy(e.to_string())))
            }
        };
        let started = Instant::now();
        let result = if backup {
            connector.connect_client("127.0.0.1", port, handshake).await
        } else {
            connector
                .connect_with_handshake("127.0.0.1", port, handshake)
                .await
        };
        times.push(started.elapsed().as_secs_f64() * 1000.0);
        successes += usize::from(result.is_ok());
        drop(result);
        tokio::time::timeout(Duration::from_secs(1), async {
            while active.load(Ordering::SeqCst) != 0 {
                tokio::task::yield_now().await;
            }
        })
        .await
        .expect("落败与获胜 socket 均应关闭");
        serving.abort();
        let _ = serving.await;
    }
    times.sort_by(f64::total_cmp);
    println!(
        "{}",
        serde_json::json!({"backup": backup, "scenario": scenario,
        "count": count, "successes": successes, "p50_ms": times[(count - 1) / 2],
        "p95_ms": times[(count * 95 / 100).min(count - 1)],
        "connections": connections.load(Ordering::SeqCst), "peak_connections": peak.load(Ordering::SeqCst),
        "remaining_connections": active.load(Ordering::SeqCst)})
    );
    Ok(())
}
