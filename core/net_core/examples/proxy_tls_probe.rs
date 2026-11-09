//! 隔离代理实验：复用模板构造，测试 CA 仅用于本次进程。
use fluxdo_net::{
    NetError, UpstreamProxyConfig,
    egress::{EgressConnector, HandshakeFailure},
    mirror::FingerprintTemplates,
};
use rama::{
    ServiceInput,
    net::address::Host,
    tls::{
        boring::{
            client::{BoringClientConfigExt as _, TlsConnectorData, tls_connect},
            core::{ssl::UnknownValues, x509::X509},
        },
        client::TlsClientConfig,
    },
};
use std::{
    fs,
    time::{Duration, Instant},
};
use tokio::io::{AsyncReadExt, AsyncWriteExt};

#[tokio::main(worker_threads = 2)]
async fn main() -> Result<(), rama::error::BoxError> {
    let args: Vec<_> = std::env::args().collect();
    let proxy_port: u16 = args[1].parse()?;
    let host = &args[2];
    let port: u16 = args[3].parse()?;
    let pem = fs::read_to_string(&args[4])?;
    let hello =
        FingerprintTemplates::with_selection(None, "android", None, Some("android-chrome149"))?
            .snapshot()
            .unwrap()
            .hello;
    let mut config = TlsClientConfig::new_from_client_hello(&hello)
        .with_unknown_values(UnknownValues::Drop)
        .with_server_name(host.parse::<Host>()?)
        .try_with_server_trust_anchors([X509::from_pem(pem.as_bytes())?.to_der()?.into()])?;
    config.set_permute_extensions(true);
    let connector = EgressConnector::new(
        None,
        Some(UpstreamProxyConfig {
            protocol: "http".into(),
            host: "127.0.0.1".into(),
            port: proxy_port,
            username: None,
            password: None,
            cipher: None,
        }),
        None,
        None,
        Duration::from_secs(6),
    );
    let started = Instant::now();
    let mut tls = connector
        .connect_client(host, port, move |stream, _| {
            let data = TlsConnectorData::try_from(&config).unwrap();
            async move {
                tls_connect(ServiceInput::new(stream), Some(data))
                    .await
                    .map_err(|e| HandshakeFailure::abort(NetError::Proxy(e.to_string())))
            }
        })
        .await?;
    tls.write_all(
        format!("GET / HTTP/1.1\r\nHost: {host}\r\nConnection: close\r\n\r\n").as_bytes(),
    )
    .await?;
    let mut body = Vec::new();
    tokio::time::timeout(Duration::from_secs(5), tls.read_to_end(&mut body)).await??;
    println!(
        "{}",
        serde_json::json!({"elapsed_ms": started.elapsed().as_millis(), "response": String::from_utf8_lossy(&body)})
    );
    Ok(())
}
