//! 探针采样端点：隐藏 WebView 访问 `https://localhost:<代理端口>/fluxdo-probe`，
//! 核心借此采集 WebView 的 TLS 握手、HTTP/2 早期帧与 fetch 请求头，写入回放模板。
//!
//! 直连模式下 WebView 不经过核心，这是获取模板的唯一途径。端点与代理共用端口：
//! 代理按连接首字节分流，TLS 握手（0x16）进入这里。WebView 对 localhost 的握手与
//! 访问真实站点时一致（实测 Chrome / WKWebView / 安卓 WebView 的 JA4 相同），仅 SNI 不同，
//! 回放时 SNI 由目标站点重填。

use std::{convert::Infallible, sync::Arc, time::Duration};

use rama::{
    Layer, Service, ServiceInput,
    http::{Body, Request, Response, StatusCode, header, server::HttpServer},
    rt::Executor,
    service::service_fn,
    tls::{
        boring::server::TlsAcceptorLayer,
        server::{GeneratedServerAuthConfig, TlsServerConfig, peek_client_hello_from_input},
    },
};
use tokio::net::TcpStream;
use tracing::{debug, info};

use crate::browser_tls;
use crate::error::{NetError, Result};
use crate::mirror::FingerprintTemplates;

/// 探针页路径。
pub const PROBE_PATH: &str = "/fluxdo-probe";
const PROBE_FETCH_PATH: &str = "/fluxdo-probe/fetch";
const PROBE_DONE_PATH: &str = "/fluxdo-probe/done";
const PEEK_TIMEOUT: Duration = Duration::from_secs(10);

/// 探针页：同源 fetch 一次（采 fetch 类请求头），完成后改标题供宿主判断。
const PROBE_PAGE: &str = "<!doctype html><meta charset=\"utf-8\"><title>fluxdo-probe</title>\
<script>fetch('/fluxdo-probe/fetch').then(()=>fetch('/fluxdo-probe/done'))\
.finally(()=>{document.title='fluxdo-probe-done'})</script>";

/// TLS 首字节：握手记录类型。
pub const TLS_HANDSHAKE_RECORD: u8 = 0x16;

/// 采样端点，所有探针连接共享一份 TLS 配置与模板仓库。
pub struct ProbeEndpoint {
    tls: TlsServerConfig,
    templates: Arc<FingerprintTemplates>,
}

impl ProbeEndpoint {
    pub fn new(templates: Arc<FingerprintTemplates>) -> Result<Self> {
        let tls = TlsServerConfig::new()
            .try_with_generated_server_auth(GeneratedServerAuthConfig::default())
            .map_err(|e| NetError::Proxy(format!("Probe certificate: {e}")))?
            .with_alpn_http_auto();
        Ok(Self { tls, templates })
    }

    /// 处理一条已判定为 TLS 的探针连接。
    pub async fn serve(&self, stream: TcpStream) -> Result<()> {
        let (input, hello) =
            peek_client_hello_from_input(ServiceInput::new(stream), Some(PEEK_TIMEOUT)).await?;
        // 探针页只由宿主自己的隐藏 WebView 打开，来源可信，握手一律采用。
        // 不能按 GREASE 过滤：Linux 的 WebKitGTK 走 GnuTLS，握手里没有 GREASE，
        // 过滤后这一端永远采不到模板（镜像入口来源不可控，仍保留过滤）
        if let Some(hello) = hello.as_ref() {
            self.templates.record_hello(hello);
            info!(
                "Probe captured WebView ClientHello (browser-like: {}, chromium: {})",
                browser_tls::is_browser_like(hello),
                browser_tls::is_chromium(hello)
            );
        } else {
            debug!("Probe: connection without ClientHello");
        }

        let templates = self.templates.clone();
        let finished = Arc::new(tokio::sync::Notify::new());
        let done = finished.clone();
        let mut http = HttpServer::auto(Executor::new());
        http.h2_mut().set_observe_early_frames(true);
        let http = http.service(service_fn(move |request: Request| {
            let templates = templates.clone();
            let done = done.clone();
            async move {
                let is_done = request
                    .uri()
                    .path()
                    .is_some_and(|p| p.to_string() == PROBE_DONE_PATH);
                let response = handle(&templates, request);
                if is_done {
                    done.notify_one();
                }
                Ok::<_, Infallible>(response)
            }
        }));
        let service = TlsAcceptorLayer::new(self.tls.clone()).into_layer(http);
        tokio::select! {
            result = service.serve(input) => result.map_err(|e| NetError::Proxy(format!("Probe connection: {e}"))),
            _ = async {
                finished.notified().await;
                // 让完成响应发出后关闭此回环连接，下一轮必须重新握手，
                // 避免 WebView 全局连接池让“两次采样”实际复用同一 TLS。
                tokio::time::sleep(Duration::from_millis(100)).await;
            } => Ok(()),
        }
    }
}

fn handle(templates: &FingerprintTemplates, request: Request) -> Response {
    let path = request
        .uri()
        .path()
        .map(|path| path.to_string())
        .unwrap_or_default();
    if path == PROBE_FETCH_PATH {
        templates.observe_probe_fetch(&request);
    } else if path.starts_with(PROBE_PATH) {
        templates.observe_request(&request);
    }
    match path.as_str() {
        PROBE_PATH => Response::builder()
            .header(header::CONTENT_TYPE, "text/html; charset=utf-8")
            .header(header::CACHE_CONTROL, "no-store")
            .body(Body::from(PROBE_PAGE))
            .unwrap(),
        PROBE_FETCH_PATH | PROBE_DONE_PATH => {
            if path == PROBE_DONE_PATH {
                info!(
                    "Probe finished: template ready = {}",
                    templates
                        .captured_snapshot()
                        .is_some_and(|t| t.is_calibrated())
                );
            }
            Response::builder()
                .status(StatusCode::NO_CONTENT)
                .body(Body::empty())
                .unwrap()
        }
        _ => Response::builder()
            .status(StatusCode::NOT_FOUND)
            .body(Body::empty())
            .unwrap(),
    }
}

#[cfg(test)]
mod scenario_tests {
    use super::*;
    use rama::extensions::ExtensionsMut;

    #[test]
    fn probe_fetch_without_fetch_metadata_still_completes_sampling() {
        // 模拟不发送 Fetch Metadata / Client Hints 的内核，不能伪装成真机证据。
        let reference = crate::presets::by_id("ios-safari18").unwrap();
        let templates = FingerprintTemplates::new(None);
        templates.record_hello(&reference.hello);
        templates.record_hello(&reference.hello);
        for path in [PROBE_PATH, PROBE_FETCH_PATH] {
            let mut request = Request::builder()
                .uri(path)
                .header("user-agent", "Fixture-WebKit/1")
                .header("accept-encoding", "gzip, br")
                .body(Body::empty())
                .unwrap();
            request
                .extensions_mut()
                .insert(reference.early_frames.clone());
            request
                .extensions_mut()
                .insert(reference.pseudo_order.clone());
            handle(&templates, request);
            let status: serde_json::Value = serde_json::from_str(&templates.status_json()).unwrap();
            assert_eq!(status["ready"], path == PROBE_FETCH_PATH);
        }
        assert_eq!(
            templates
                .captured_snapshot()
                .unwrap()
                .low_entropy_client_hints,
            Some(Vec::new())
        );
    }
}
