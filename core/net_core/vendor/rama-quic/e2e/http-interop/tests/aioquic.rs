//! aioquic client against Rama's HTTP/3 server; the reverse role lives in dynamic_qpack.
use interop_common::{backend, identity};
use rama::{
    bytes::Bytes,
    crypto::pem::PemEncode as _,
    error::BoxError,
    extensions::ExtensionsRef as _,
    futures::stream,
    http::{
        Body, HeaderMap, Request, Response, Version,
        body::{Frame, util::BodyExt as _},
        server::HttpServer,
    },
    net::tls::ApplicationProtocol,
    quic::{Endpoint, TransportConfig},
    rt::Executor,
    service::service_fn,
    tls::server::TlsServerConfig,
    utils::fs::tempdir,
};
use std::{
    convert::Infallible,
    net::SocketAddr,
    path::Path,
    sync::{
        Arc,
        atomic::{AtomicUsize, Ordering},
    },
    time::Duration,
};
use tokio::{process::Command, time::timeout};

#[tokio::test]
#[ignore = "requires uv and the locked aioquic peer; run the http3-interop recipe"]
async fn aioquic_uploads_and_trailers_against_rama() -> Result<(), BoxError> {
    timeout(Duration::from_secs(45), async {
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
                            .with_stream_receive_window(16384u32)
                            .with_receive_window(65536u32),
                    )),
            )
            .bind_address("127.0.0.1:0".parse::<SocketAddr>()?)
            .await?;
        let count = Arc::new(AtomicUsize::new(0));
        let service = service_fn({
            let count = count.clone();
            move |request: Request| {
                let count = count.clone();
                async move {
                    assert_eq!(request.version(), Version::HTTP_3);
                    assert_eq!(
                        request.headers()["x-dynamic-request"],
                        "independent-qpack-".repeat(24)
                    );
                    let index: usize = request
                        .uri()
                        .path_or_root()
                        .strip_prefix("/echo/")
                        .unwrap()
                        .parse()
                        .unwrap();
                    assert!(index < 5);
                    let collected = request.into_body().collect().await.unwrap();
                    assert_eq!(collected.trailers().unwrap()["x-upload-complete"], "yes");
                    let data = collected.to_bytes();
                    assert_eq!(data.len(), 131072 + index);
                    assert!(
                        data.iter()
                            .enumerate()
                            .all(|(offset, byte)| *byte == ((offset + index) % 251) as u8)
                    );
                    count.fetch_add(1, Ordering::SeqCst);
                    let mut frames = data
                        .chunks(4096)
                        .map(|chunk| {
                            Ok::<_, Infallible>(Frame::data(Bytes::copy_from_slice(chunk)))
                        })
                        .collect::<Vec<_>>();
                    let mut trailers = HeaderMap::new();
                    trailers.insert("x-download-complete", "yes".parse().unwrap());
                    frames.push(Ok(Frame::trailers(trailers)));
                    Ok::<_, Infallible>(
                        Response::builder()
                            .header("x-dynamic-response", "independent-qpack-".repeat(24))
                            .body(Body::from_frame_stream(stream::iter(frames)))
                            .unwrap(),
                    )
                }
            }
        });
        let serve = async {
            let connection = endpoint.accept().await.ok_or("missing connection")?.await?;
            assert_eq!(
                connection
                    .extensions()
                    .get_ref::<rama::quic::NegotiatedTlsParameters>()
                    .unwrap()
                    .application_layer_protocol,
                Some(ApplicationProtocol::HTTP_3)
            );
            HttpServer::new_http3(executor)
                .serve(connection, service)
                .await?;
            Ok::<_, BoxError>(())
        };
        let root = Path::new(env!("CARGO_MANIFEST_DIR"));
        let run = async {
            let result = Command::new("uv")
                .args(["run", "--frozen", "--project"])
                .arg(root.join("../aioquic-interop"))
                .arg("python")
                .arg(root.join("peer/request_peer.py"))
                .arg("--ca")
                .arg(cert)
                .arg("--port")
                .arg(endpoint.local_addr()?.port().to_string())
                .stderr(std::process::Stdio::inherit())
                .kill_on_drop(true)
                .output()
                .await?;
            assert!(
                result.status.success(),
                "{}",
                String::from_utf8_lossy(&result.stderr)
            );
            let report: serde_json::Value = serde_json::from_slice(&result.stdout)?;
            assert_eq!(report["alpn"], "h3");
            assert_eq!(report["requests"], 5);
            Ok::<_, BoxError>(())
        };
        tokio::try_join!(serve, run)?;
        assert_eq!(count.load(Ordering::SeqCst), 5);
        endpoint.close(0_u32, b"done");
        Ok::<_, BoxError>(())
    })
    .await?
}
