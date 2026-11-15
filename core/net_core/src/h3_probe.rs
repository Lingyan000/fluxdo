//! 与 TCP 探针隔离的本机 H3 采样。两个独立 origin 校准，避免连接池复用冒充两次握手。
use crate::{h3_template::Sample, mirror::FingerprintTemplates};
use rama::{
    Layer, Service, ServiceInput,
    error::BoxError,
    extensions::ExtensionsRef,
    http::{Body, Request, Response, server::HttpServer},
    net::tls::ApplicationProtocol,
    quic::{
        Endpoint,
        tls::{BoringTlsProvider, QuicServerConfigProvider, TlsOptions},
    },
    rt::Executor,
    service::service_fn,
    tls::{
        boring::server::TlsAcceptorLayer,
        server::{GeneratedServerAuthConfig, ServerAuthData, TlsServerConfig},
    },
};
use rama_http_core::h3::{
    connection::Config,
    observation::{FirstRequestObservation, H3Observer},
};
use std::{sync::Arc, time::Duration};
use tokio::net::TcpListener;
use tokio_util::sync::CancellationToken;

const PAGE: &str = r#"<!doctype html><title>fluxdo-probe</title><script>
(async()=>{await new Promise(r=>setTimeout(r,400));try{for(let i=0;i<20;i++){try{let r=await fetch('/fluxdo-h3/fetch');
if((await r.text())==='h3-ready')break;}catch(e){}await new Promise(r=>setTimeout(r,250));}}
finally{document.title='fluxdo-probe-done';}})();</script>"#;

pub async fn start(templates: Arc<FingerprintTemplates>, shutdown: CancellationToken) {
    let mut ports = Vec::new();
    for _ in 0..2 {
        match bind(templates.clone(), shutdown.clone()).await {
            Ok(port) => ports.push(port),
            Err(error) => {
                tracing::warn!(%error,"H3 probe unavailable");
                templates.h3.failure(error);
                break;
            }
        }
    }
    templates.h3.ports(ports);
}

async fn bind(
    templates: Arc<FingerprintTemplates>,
    shutdown: CancellationToken,
) -> Result<u16, BoxError> {
    let identity = ServerAuthData::new_generated(GeneratedServerAuthConfig::generated_ca_for(
        rama::net::address::Domain::from_static("localhost"),
    ))?;
    let tls = TlsServerConfig::new()
        .with_server_auth(identity.clone())
        .with_alpn_http_auto();
    use base64::Engine;
    use rama::tls::boring::core::{sha::sha256, x509::X509};
    let leaf = X509::from_der(identity.cert_chain[0].as_ref())?;
    #[cfg(debug_assertions)]
    let probe_ca=String::from_utf8(X509::from_der(identity.cert_chain.last().ok_or("missing probe CA")?.as_ref())?.to_pem()?)?;
    let spki = base64::engine::general_purpose::STANDARD
        .encode(sha256(&leaf.public_key()?.public_key_to_der()?));
    let quic_tls = TlsServerConfig::new()
        .with_server_auth(identity)
        .with_alpn([ApplicationProtocol::HTTP_3].into_iter().collect());
    let config = BoringTlsProvider
        .server_config(
            &quic_tls,
            TlsOptions::default().with_server_session_tickets(false),
        )?
        .with_capture(rama_quic_proto::capture::CaptureLimits::default());
    let endpoint = Endpoint::bind_server(
        Executor::new(),
        config.clone(),
        "127.0.0.1:0".parse::<std::net::SocketAddr>()?,
    )
    .await?;
    let port = endpoint.local_addr()?.port();
    templates.h3.probe_certificate(port, spki);
    #[cfg(debug_assertions)]
    templates.h3.probe_ca(port, probe_ca);
    let tcp = TcpListener::bind(("127.0.0.1", port)).await?;
    // localhost 可能优先解析到 ::1；两个地址使用同一证书和同一 origin。
    let endpoint6 = Endpoint::bind_server(
        Executor::new(),
        config,
        std::net::SocketAddr::new(std::net::Ipv6Addr::LOCALHOST.into(), port),
    )
    .await
    .ok();
    let tcp6 = TcpListener::bind(("::1", port)).await.ok();
    let token = shutdown.clone();
    let activity = templates.clone();
    tokio::spawn(async move {
        let mut tasks = tokio::task::JoinSet::new();
        loop {
            tokio::select! {
                _=token.cancelled()=>break,
                _=tasks.join_next(),if !tasks.is_empty()=>{},
                result=async {
                    if let Some(tcp6)=&tcp6 {tokio::select! {v=tcp.accept()=>v,v=tcp6.accept()=>v}}
                    else {tcp.accept().await}
                }=>{
                    let Ok((stream,_))=result else {break};
                    if tasks.len()>=8 {continue;}
                    let close=Arc::new(tokio::sync::Notify::new());let signal=close.clone();
                    let activity=activity.clone();
                    let service=HttpServer::auto(Executor::new()).service(service_fn(move |request:Request| {
                        activity.h3.activity(port,"tcp_requests");
                        signal.notify_one();
                        let page=request.uri().path().is_some_and(|p| p.to_string()=="/fluxdo-h3");
                        async move {Ok::<_,std::convert::Infallible>(Response::builder()
                            .header("alt-svc",format!("h3=\":{port}\"; ma=30"))
                            .header("cache-control","no-store").header("content-type","text/html")
                            .body(Body::from(if page {PAGE} else {"tcp"})).unwrap())}
                    }));
                    let service=TlsAcceptorLayer::new(tls.clone()).into_layer(service);
                    tasks.spawn(async move {tokio::select! {
                        _=service.serve(ServiceInput::new(stream))=>{},
                        _=async {close.notified().await;tokio::time::sleep(Duration::from_millis(200)).await;}=>{},
                        _=tokio::time::sleep(Duration::from_secs(15))=>{},
                    }});
                }
            }
        }
        tasks.abort_all();
    });
    tokio::spawn(async move {
        let mut tasks = tokio::task::JoinSet::new();
        loop {
            tokio::select! {
                _=shutdown.cancelled()=>break,
                _=tasks.join_next(),if !tasks.is_empty()=>{},
                incoming=async {
                    if let Some(endpoint6)=&endpoint6 {tokio::select! {v=endpoint.accept()=>v,v=endpoint6.accept()=>v}}
                    else {endpoint.accept().await}
                }=>{
                    let Some(incoming)=incoming else {break};
                    if tasks.len()>=8 {continue;}
                    let templates=templates.clone();
                    let epoch=templates.h3.epoch();
                    tasks.spawn(async move {
                        let result=tokio::time::timeout(Duration::from_secs(15),async {
                            let connection=incoming.await?;let close=connection.clone();
                            templates.h3.activity(port,"quic_connections");
                            let quic=connection.extensions().get_ref::<rama_quic_proto::capture::QuicObservation>()
                                .cloned().ok_or("missing native QUIC observation")?;
                            let (mut requests,driver)=rama_http_core::h3::server::handshake(connection,
                                Config {observation:Some(Default::default()),..Config::default().with_browser_qpack_decoder_limits()})?;
                            let mut driver_tasks=tokio::task::JoinSet::new(); driver_tasks.spawn(driver.run());
                            let result:Result<(),BoxError>=async {
                                let (request,response)=requests.accept().await?.resolve().await?;
                                if request.uri().path().is_some_and(|p|p.to_string()=="/fluxdo-h3") {
                                    // 缓存 Alt-Svc 后导航也可能走 H3；页面与首次 fetch 分开建连。
                                    response.send_response(Response::builder().header("content-type","text/html").body(Body::from(PAGE))?).await?;
                                    tokio::time::sleep(Duration::from_millis(150)).await;
                                    close.close(0u32,b"fresh fetch probe");return Ok(());
                                }
                                let valid=request.uri().path().is_some_and(|p|p.to_string()=="/fluxdo-h3/fetch");
                                if !valid {return Err("unexpected H3 probe first request".into());}
                                let observer=request.extensions().get_ref::<H3Observer>().ok_or("missing H3 observer")?;
                                let FirstRequestObservation::Ready(boundary)=observer.first_request(tokio::time::Instant::now()+Duration::from_secs(2)).await
                                    else {return Err("H3 first-request boundary unavailable".into());};
                                let mut sample=Sample::capture_observation(&quic,&request,boundary)?;
                                let status=templates.captured_snapshot().ok_or("TCP fingerprint not calibrated")?;
                                if !status.is_calibrated() || status.user_agent.as_deref()!=Some(sample.user_agent.as_str()) {
                                    return Err("H3 probe UA does not match calibrated TCP sample".into());
                                }
                                response.send_response(Response::builder().header("access-control-allow-origin","*").body(Body::from("h3"))?).await?;
                                for index in 0..2 {
                                    let (request,response)=requests.accept().await?.resolve().await?;
                                    if !request.uri().path().is_some_and(|p|p.to_string()=="/fluxdo-h3/fetch") {return Err("unexpected warm H3 path".into());}
                                    sample.observe_warm(&request)?;
                                    let observer=request.extensions().get_ref::<H3Observer>().ok_or("missing warm H3 observer")?;
                                    sample.warm_boundary=Some(crate::h3_template::sampled_request_boundary(
                                        observer, (index+1)*4, sample.priority_update.is_some()).await?);
                                    if index==1 {templates.h3.record(epoch,port,sample.clone())?;}
                                    response.send_response(Response::builder().header("access-control-allow-origin","*").body(Body::from(if index==1 {"h3-ready"} else {"h3"}))?).await?;
                                }
                                // 响应发出后关闭此独立探针连接；不影响业务连接池。
                                tokio::time::sleep(Duration::from_millis(200)).await;
                                Ok(())
                            }.await;
                            driver_tasks.abort_all();result
                        }).await;
                        if epoch==templates.h3.epoch() {
                            match result {Ok(Ok(()))=>{},Ok(Err(e))=>templates.h3.failure(e),Err(e)=>templates.h3.failure(e)}
                        }
                    });
                }
            }
        }
        tasks.abort_all();
        endpoint.close(0u32, b"probe stopped");
        if let Some(endpoint6) = endpoint6 {
            endpoint6.close(0u32, b"probe stopped");
        }
    });
    Ok(port)
}
