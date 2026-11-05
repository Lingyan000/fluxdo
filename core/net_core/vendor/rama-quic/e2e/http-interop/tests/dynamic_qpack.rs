//! Both QPACK directions against live aioquic/ls-qpack, with proven blocked resume.
use interop_common::{backend, identity};
use rama::{
    crypto::pem::PemEncode as _,
    error::BoxError,
    http::{
        Body, Request,
        body::util::BodyExt as _,
        core::h3::{client, connection::Config},
    },
    net::tls::ApplicationProtocol,
    quic::{Endpoint, TransportConfig, qlog::QlogConfig},
    rt::Executor,
    tls::client::TlsClientConfig,
    utils::fs::tempdir,
};
use std::{net::SocketAddr, path::Path, process::Stdio, sync::Arc, time::Duration};
use tokio::{
    io::{AsyncBufReadExt as _, AsyncWriteExt as _, BufReader},
    process::Command,
    time::timeout,
};

async fn event_count(path: &Path, name: &str) -> Result<usize, BoxError> {
    let contents = tokio::fs::read_to_string(path).await?;
    let mut count = 0;
    for record in contents
        .split('\u{1e}')
        .map(str::trim)
        .filter(|r| !r.is_empty())
    {
        let event: serde_json::Value = serde_json::from_str(record)?;
        count += usize::from(event["name"] == name);
    }
    Ok(count)
}

#[tokio::test]
#[ignore = "requires uv and the locked aioquic peer; run the http3-interop recipe"]
async fn dynamic_qpack_blocks_and_resumes_against_aioquic() -> Result<(), BoxError> {
    timeout(Duration::from_secs(30), async {
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
        let root = Path::new(env!("CARGO_MANIFEST_DIR"));
        let mut process = Command::new("uv")
            .args(["run", "--frozen", "--project"])
            .arg(root.join("../aioquic-interop"))
            .arg("python")
            .arg(root.join("peer/dynamic_qpack.py"))
            .arg("--cert")
            .arg(&cert)
            .arg("--key")
            .arg(&key)
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::inherit())
            .kill_on_drop(true)
            .spawn()?;
        let mut commands = process.stdin.take().unwrap();
        let mut lines = BufReader::new(process.stdout.take().unwrap()).lines();
        let ready: serde_json::Value =
            serde_json::from_str(&lines.next_line().await?.ok_or("missing readiness")?)?;
        assert_eq!(ready["event"], "listening");
        let address: SocketAddr = format!("127.0.0.1:{}", ready["port"]).parse()?;
        let trace_path = directory.path().join("qpack.qlog");
        let recorder = QlogConfig::default()
            .with_event_schemas(rama::http::core::h3::qlog::EVENT_SCHEMAS)
            .with_writer(Box::new(tokio::fs::File::create(&trace_path).await?))
            .start()?;
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
                TransportConfig::default().with_qlog_recorder(recorder.clone()),
            ));
        let connection = endpoint.connect_with(config, address, "localhost")?.await?;
        let (sender, driver) =
            client::handshake::<Body, _>(connection.clone(), Config::default(), executor)?;
        let drive = tokio::spawn(driver.run());
        let mut barriers = 0;
        let mut dynamic_requests = 0;
        for _ in 0..4 {
            let mut sender = sender.clone();
            let response = tokio::spawn(async move {
                sender
                    .send_request(
                        Request::builder()
                            .uri(format!("https://localhost:{}/", address.port()))
                            .header("x-dynamic-request", "independent-qpack-".repeat(24))
                            .body(Body::empty())?,
                    )
                    .await
                    .map_err(BoxError::from)
            });
            let record: serde_json::Value =
                serde_json::from_str(&lines.next_line().await?.ok_or("missing response record")?)?;
            assert_eq!(record["event"], "response", "{record}");
            dynamic_requests = record["dynamic_requests"].as_u64().unwrap();
            if record["held"] == true {
                barriers += 1;
                timeout(Duration::from_secs(5), async {
                    loop {
                        recorder.flush().await?;
                        if event_count(&trace_path, "rama_qpack:field_section_blocked").await?
                            >= barriers
                        {
                            return Ok::<_, BoxError>(());
                        }
                        tokio::time::sleep(Duration::from_millis(10)).await;
                    }
                })
                .await??;
                assert!(
                    !response.is_finished(),
                    "response cannot decode before dynamic insertions"
                );
                commands.write_all(b"release\n").await?;
            }
            let response = response.await??;
            assert_eq!(response.status(), 200);
            assert_eq!(
                response.headers()["x-dynamic-response"],
                "independent-qpack-".repeat(24)
            );
            assert_eq!(
                response.into_body().collect().await?.to_bytes(),
                "dynamic qpack"
            );
        }
        assert!(
            barriers > 0 && dynamic_requests > 0,
            "real dynamic references in both directions"
        );
        recorder.flush().await?;
        assert_eq!(
            event_count(&trace_path, "rama_qpack:field_section_unblocked").await?,
            barriers
        );
        commands.write_all(b"finish\n").await?;
        let complete: serde_json::Value =
            serde_json::from_str(&lines.next_line().await?.ok_or("missing completion")?)?;
        assert_eq!(complete["event"], "complete");
        assert!(process.wait().await?.success());
        connection.close(0_u32, b"done");
        drop(sender);
        drive.await??;
        Ok::<_, BoxError>(())
    })
    .await?
}
