//! HTTP/3 workloads against the shared, pinned quic-go / masque-go oracle.
use interop_common::{backend, identity};
use rama::{
    bytes::Bytes,
    crypto::pem::PemEncode as _,
    error::BoxError,
    futures::stream,
    http::{
        Body, HeaderMap, Request, Response, Version,
        body::{Frame, util::BodyExt as _},
        core::h3::{client, connection::Config},
        server::HttpServer,
    },
    net::tls::ApplicationProtocol,
    quic::{Endpoint, TransportConfig},
    rt::Executor,
    service::service_fn,
    tls::{client::TlsClientConfig, server::TlsServerConfig},
    utils::{fs::tempdir, octets},
};
use sha2::{Digest, Sha256};
use std::{
    convert::Infallible,
    net::SocketAddr,
    process::Stdio,
    sync::{
        Arc,
        atomic::{AtomicBool, AtomicUsize, Ordering},
    },
    time::Duration,
};
use tokio::{
    io::{AsyncBufReadExt as _, BufReader},
    process::Command,
    task::JoinSet,
    time::timeout,
};

fn peer() -> Command {
    let mut command = Command::new(
        std::env::var("RAMA_HTTP_INTEROP_PEER")
            .expect("build examples/tests/masque_interop/peer and set RAMA_HTTP_INTEROP_PEER"),
    );
    command.arg("coverage").kill_on_drop(true);
    command
}

fn digest(bytes: &[u8]) -> String {
    Sha256::digest(bytes)
        .iter()
        .map(|b| format!("{b:02x}"))
        .collect()
}

fn body(bytes: Vec<u8>) -> Body {
    // Multiple unknown-length DATA frames exercise streaming in both directions.
    let chunks: Vec<_> = bytes.chunks(8192).map(Bytes::copy_from_slice).collect();
    Body::from_frame_stream(stream::iter(
        chunks
            .into_iter()
            .map(|b| Ok::<_, Infallible>(Frame::data(b))),
    ))
}

#[tokio::test]
#[ignore = "requires the independent Go peer; run with the interop recipe"]
async fn rama_client_against_quic_go() -> Result<(), BoxError> {
    timeout(Duration::from_secs(60), async {
        let directory = tempdir()?;
        let auth = identity::server_identity();
        let cert = directory.path().join("cert.pem");
        let key = directory.path().join("key.pem");
        std::fs::write(
            &cert,
            auth.cert_chain
                .iter()
                .map(|c| c.to_pem())
                .collect::<String>(),
        )?;
        std::fs::write(&key, auth.private_key.to_pem())?;
        let mut process = peer()
            .args(["-mode", "server", "-cert"])
            .arg(&cert)
            .arg("-key")
            .arg(&key)
            .stdout(Stdio::piped())
            .stderr(Stdio::inherit())
            .spawn()?;
        let mut lines = BufReader::new(process.stdout.take().unwrap()).lines();
        let ready: serde_json::Value =
            serde_json::from_str(&lines.next_line().await?.ok_or("missing readiness")?)?;
        let address: SocketAddr = ready["address"]
            .as_str()
            .ok_or("missing address")?
            .parse()?;
        let logs =
            tokio::spawn(async move { while lines.next_line().await.ok().flatten().is_some() {} });
        let executor = Executor::new();
        let endpoint = Endpoint::build(executor.clone())
            .bind_address("127.0.0.1:0".parse::<SocketAddr>()?)
            .await?;
        let tls = TlsClientConfig::new()
            .try_with_server_trust_anchors(auth.cert_chain)?
            .with_alpn([ApplicationProtocol::HTTP_3].into_iter().collect());
        let config = backend::tls_provider()
            .client_config(&tls, backend::options())?
            .with_transport_config(Arc::new(
                TransportConfig::default()
                    .with_stream_receive_window(octets::kib_u32(64))
                    .with_receive_window(octets::kib_u32(256)),
            ));
        let connection = endpoint.connect_with(config, address, "localhost")?.await?;
        let (sender, driver) =
            client::handshake::<Body, _>(connection.clone(), Config::default(), executor)?;
        let drive = tokio::spawn(driver.run());
        let mut jobs = JoinSet::new();
        for i in 0..9 {
            let mut sender = sender.clone();
            jobs.spawn(async move {
                let bytes = vec![
                    i as u8;
                    if i == 0 {
                        octets::mib(2)
                    } else {
                        octets::kib(32) + i
                    }
                ];
                let request = Request::builder()
                    .method("POST")
                    .uri(format!("https://localhost:{}/echo", address.port()))
                    .header("x-repeated-header", "independent-interop-".repeat(32))
                    .body(body(bytes.clone()))?;
                let response = sender.send_request(request).await?;
                assert_eq!(response.status(), 200);
                assert_eq!(response.version(), Version::HTTP_3);
                let collected = response.into_body().collect().await?;
                assert_eq!(
                    collected.trailers().unwrap()["x-body-sha256"],
                    digest(&bytes)
                );
                assert_eq!(collected.to_bytes().as_ref(), bytes);
                Ok::<_, BoxError>(())
            });
        }
        while let Some(result) = jobs.join_next().await {
            result??;
        }
        let mut sender = sender;
        let response = sender
            .send_request(
                Request::builder()
                    .uri(format!("https://localhost:{}/cancel", address.port()))
                    .body(Body::empty())?,
            )
            .await?;
        let mut cancelled = response.into_body();
        assert!(cancelled.frame().await.transpose()?.is_some());
        drop(cancelled);
        let response = sender
            .send_request(
                Request::builder()
                    .uri(format!("https://localhost:{}/status", address.port()))
                    .body(Body::empty())?,
            )
            .await?;
        assert_eq!(response.status(), 418);
        response.into_body().collect().await?;
        let stats = connection.stats();
        assert!(stats.frame_tx.max_data > 0 && stats.frame_tx.max_stream_data > 0);
        assert!(
            stats.frame_tx.stop_sending > 0,
            "cancelled response must signal STOP_SENDING"
        );
        connection.close(0_u32, b"done");
        drop(sender);
        drive.await??;
        process.kill().await?;
        logs.await?;
        Ok::<_, BoxError>(())
    })
    .await?
}

#[tokio::test]
#[ignore = "requires the independent Go peer; run with the interop recipe"]
async fn quic_go_client_against_rama() -> Result<(), BoxError> {
    timeout(Duration::from_secs(60), async {
        let directory = tempdir()?;
        let auth = identity::server_identity();
        let cert = directory.path().join("cert.pem");
        std::fs::write(
            &cert,
            auth.cert_chain
                .iter()
                .map(|c| c.to_pem())
                .collect::<String>(),
        )?;
        let executor = Executor::new();
        let tls = TlsServerConfig::new()
            .with_server_auth(auth)
            .with_alpn([ApplicationProtocol::HTTP_3].into_iter().collect());
        let endpoint = Endpoint::build(executor.clone())
            .with_server_config(
                backend::server_tls_provider()
                    .server_config(&tls, backend::options())?
                    .with_transport_config(Arc::new(
                        TransportConfig::default()
                            .with_stream_receive_window(octets::kib_u32(64))
                            .with_receive_window(octets::kib_u32(256)),
                    )),
            )
            .bind_address("127.0.0.1:0".parse::<SocketAddr>()?)
            .await?;
        let accepted = Arc::new(AtomicUsize::new(0));
        let cancel_bytes = Arc::new(AtomicUsize::new(0));
        let cancel_dropped = Arc::new(AtomicBool::new(false));
        let handler = service_fn({
            let cancel_bytes = cancel_bytes.clone();
            let cancel_dropped = cancel_dropped.clone();
            move |request: Request| {
                let cancel_bytes = cancel_bytes.clone();
                let cancel_dropped = cancel_dropped.clone();
                async move {
                    assert_eq!(request.version(), Version::HTTP_3);
                    if request.headers().contains_key("x-after-cancel") {
                        timeout(Duration::from_secs(2), async {
                            while !cancel_dropped.load(Ordering::SeqCst) {
                                tokio::task::yield_now().await;
                            }
                        })
                        .await
                        .expect("cancelled body must drop before the follow-up response");
                    }
                    if request.uri().path_or_root() == "/status" {
                        return Ok::<_, Infallible>(
                            Response::builder().status(418).body(Body::empty()).unwrap(),
                        );
                    }
                    if request.uri().path_or_root() == "/cancel" {
                        let guard = rama::utils::guard::DropGuard::new(move || {
                            cancel_dropped.store(true, Ordering::SeqCst);
                        });
                        return Ok(Response::new(Body::from_frame_stream(stream::unfold(
                            (0, guard),
                            move |(n, guard)| {
                                let count = cancel_bytes.clone();
                                async move {
                                    if n == 1024 {
                                        return None;
                                    }
                                    tokio::time::sleep(Duration::from_millis(1)).await;
                                    count.fetch_add(16384, Ordering::SeqCst);
                                    Some((
                                        Ok::<_, Infallible>(Frame::data(Bytes::from(vec![
                                            0x71;
                                            16384
                                        ]))),
                                        (n + 1, guard),
                                    ))
                                }
                            },
                        ))));
                    }
                    let bytes = request.into_body().collect().await.unwrap().to_bytes();
                    let mut trailers = HeaderMap::new();
                    trailers.insert("x-body-sha256", digest(&bytes).parse().unwrap());
                    let mut frames: Vec<_> = bytes
                        .chunks(8192)
                        .map(|chunk| {
                            Ok::<_, Infallible>(Frame::data(Bytes::copy_from_slice(chunk)))
                        })
                        .collect();
                    frames.push(Ok(Frame::trailers(trailers)));
                    Ok(Response::builder()
                        .header("trailer", "x-body-sha256")
                        .body(Body::from_frame_stream(stream::iter(frames)))
                        .unwrap())
                }
            }
        });
        let server = tokio::spawn({
            let endpoint = endpoint.clone();
            let accepted = accepted.clone();
            async move {
                let mut connections = JoinSet::new();
                while let Some(incoming) = endpoint.accept().await {
                    accepted.fetch_add(1, Ordering::SeqCst);
                    let handler = handler.clone();
                    let executor = executor.clone();
                    connections.spawn(async move {
                        let connection = incoming.await.unwrap();
                        HttpServer::new_http3(executor)
                            .serve(connection.clone(), handler)
                            .await
                            .unwrap();
                        let stats = connection.stats();
                        assert!(
                            stats.frame_tx.max_data > 0 && stats.frame_tx.max_stream_data > 0,
                            "streamed uploads must replenish both receive windows"
                        );
                        assert!(
                            stats.frame_rx.stop_sending > 0 && stats.frame_tx.reset_stream > 0,
                            "STOP_SENDING must receive RESET_STREAM"
                        );
                    });
                }
                while let Some(result) = connections.join_next().await {
                    result.unwrap();
                }
            }
        });
        let result = peer()
            .args([
                "-mode",
                "client",
                "-address",
                &endpoint.local_addr()?.to_string(),
                "-ca",
            ])
            .arg(cert)
            .output()
            .await?;
        assert!(
            result.status.success(),
            "{}",
            String::from_utf8_lossy(&result.stderr)
        );
        assert_eq!(
            accepted.load(Ordering::SeqCst),
            1,
            "parallel requests and post-cancel request reuse one QUIC connection"
        );
        let sent = cancel_bytes.load(Ordering::SeqCst);
        assert!(
            sent > 0 && sent < octets::mib(16),
            "cancel must stop the response producer: {sent}"
        );
        endpoint.close(0_u32, b"done");
        server.await?;
        Ok::<_, BoxError>(())
    })
    .await?
}
