//! WebView 流量镜像：按 WebView 自己的握手连接上游，HTTP 层（含 HTTP/2 帧）原样复刻。
//!
//! 流程：窥探 WebView 的 ClientHello → [`browser_tls::build`] 生成上游配置 →
//! rama `TlsMitmRelay::handshake` 用传入的上游配置建立两侧 TLS（入站证书由应用 CA 签发）→
//! rama `HttpMitmRelay` 转发请求，并镜像 HTTP/2 初始 SETTINGS、早期帧与伪头顺序。
//! 同时把最近一次 WebView 握手存为模板，供网关（dio）回放。

use std::{
    hash::{Hash, Hasher},
    io,
    path::PathBuf,
    pin::Pin,
    sync::{
        Arc,
        atomic::{AtomicBool, AtomicU64, Ordering},
    },
    task::{Context, Poll},
    time::{Duration, Instant},
};

use parking_lot::{Mutex, RwLock};
use rama::{
    Layer, Service, ServiceInput,
    extensions::ExtensionsRef,
    http::{
        Request,
        proto::h2::{PseudoHeaderOrder, frame::EarlyFrameCapture},
        proxy::mitm::{DefaultErrorResponse, HttpMitmRelay},
    },
    io::BridgeIo,
    layer::{ArcLayer, ConsumeErrLayer, consume_err},
    net::{
        address::{Host, HostWithPort},
        client::ConnectorTarget,
    },
    rt::Executor,
    tls::{
        SecureTransport,
        boring::{
            core::{pkey::PKey, x509::X509},
            proxy::{
                HandshakeRelayClassification, TlsMitmRelay, TlsMitmRelayErrorDirection,
                TlsMitmRelayErrorKind,
                cert_issuer::{CachedBoringMitmCertIssuer, InMemoryBoringMitmCertIssuer},
            },
        },
        client::{ClientHello, ClientHelloExtension, ECHClientHello},
        server::peek_client_hello_from_input,
    },
};
use serde::{Deserialize, Serialize};
use tokio::io::{AsyncRead, AsyncWrite, ReadBuf};
use tracing::{debug, info, warn};

use crate::BoxStream;
use crate::browser_tls;
use crate::egress::{EGRESS_TLS_TIMEOUT, EgressConnector, HandshakeFailure};
use crate::error::{NetError, Result};

/// 等待 WebView 发出 ClientHello 的上限。
const PEEK_TIMEOUT: Duration = Duration::from_secs(10);
/// 模板写盘的最小间隔（首次齐全时立即写）。
const PERSIST_INTERVAL: Duration = Duration::from_secs(60);

/// 运行期来源不写入采样文件，避免把预置误标为用户的真实采样。
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub enum TemplateSource {
    #[default]
    Sampled,
    Cached,
    Builtin(&'static str),
}
impl TemplateSource {
    pub fn name(self) -> &'static str {
        match self {
            Self::Sampled => "sampled",
            Self::Cached => "cached",
            Self::Builtin(_) => "builtin",
        }
    }
    pub fn id(self) -> Option<&'static str> {
        match self {
            Self::Builtin(id) => Some(id),
            _ => None,
        }
    }
}

/// 一份可回放的 WebView 指纹模板。
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct FingerprintTemplate {
    #[serde(skip)]
    pub source: TemplateSource,
    /// TLS ClientHello
    pub hello: ClientHello,
    /// HTTP/2 早期帧（初始 SETTINGS、WINDOW_UPDATE、PRIORITY 等，按发送顺序）
    pub early_frames: EarlyFrameCapture,
    /// HTTP/2 伪头顺序
    pub pseudo_order: PseudoHeaderOrder,
    /// fetch 类请求（sec-fetch-mode: cors）的请求头名顺序，小写
    pub fetch_header_order: Vec<String>,
    /// fetch 类请求的 Accept-Encoding
    pub accept_encoding: Option<String>,
    /// 采样时 WebView 的 User-Agent（WebView 升级后 UA 变化，宿主据此决定重采）
    #[serde(default)]
    pub user_agent: Option<String>,
    /// 模板版本：握手变化时递增，回放连接池据此淘汰旧指纹的连接
    #[serde(skip)]
    pub generation: u64,
}

/// 最近一次镜像的 WebView 握手与 HTTP 层特征，作为网关（dio）回放的模板。
///
/// 配置了缓存路径时落盘，冷启动即可回放，不必等 WebView 再经过一次镜像。
#[derive(Default)]
pub struct FingerprintTemplates {
    preset: Option<FingerprintTemplate>,
    pinned: bool,
    source: RwLock<TemplateSource>,
    hello: RwLock<Option<ClientHello>>,
    h2: RwLock<Option<(EarlyFrameCapture, PseudoHeaderOrder)>>,
    fetch: RwLock<Option<(Vec<String>, Option<String>)>>,
    user_agent: RwLock<Option<String>>,
    hello_hash: Mutex<Option<u64>>,
    generation: AtomicU64,
    cache_path: Option<PathBuf>,
    last_persist: Mutex<Option<Instant>>,
}

/// 连接身份只比较稳定的浏览器能力，原始模板仍完整保留供新连接回放。
/// SNI、ECH 密文、会话票据、key share 公钥和 GREASE 值不代表浏览器升级。
fn profile_hash(hello: &ClientHello) -> u64 {
    let mut extensions: Vec<_> = hello
        .extensions()
        .iter()
        .filter_map(|ext| {
            if ext.id().is_grease() {
                return None;
            }
            let mut ext = ext.clone();
            match &mut ext {
                ClientHelloExtension::ServerName(name) => *name = None,
                ClientHelloExtension::EncryptedClientHello(ech) => *ech = ECHClientHello::Inner,
                ClientHelloExtension::SupportedGroups(values) => values.retain(|v| !v.is_grease()),
                ClientHelloExtension::SupportedVersions(values) => {
                    values.retain(|v| !v.is_grease())
                }
                ClientHelloExtension::SignatureAlgorithms(values) => {
                    values.retain(|v| !v.is_grease())
                }
                ClientHelloExtension::Opaque { id, data } => match u16::from(*id) {
                    51 => {
                        // key_share: 保留组别和公钥长度，不把随机公钥计入连接身份。
                        let mut groups = Vec::new();
                        let mut offset = 2;
                        while offset + 4 <= data.len() {
                            let group = u16::from_be_bytes([data[offset], data[offset + 1]]);
                            let len =
                                u16::from_be_bytes([data[offset + 2], data[offset + 3]]) as usize;
                            if offset + 4 + len > data.len() {
                                break;
                            }
                            if !rama::tls::is_grease_u16(group) {
                                groups.extend_from_slice(&data[offset..offset + 4]);
                            }
                            offset += 4 + len;
                        }
                        *data = groups;
                    }
                    21 | 35 | 41 | 44 => data.clear(),
                    _ => {}
                },
                _ => {}
            }
            Some(ext)
        })
        .collect();
    if browser_tls::is_chromium(hello) {
        // Chromium 本来就逐连接打乱扩展顺序，出口也开启了同一策略。
        extensions.sort_by_key(|ext| u16::from(ext.id()));
    }
    let profile = ClientHello::new(
        hello.protocol_version(),
        hello
            .cipher_suites()
            .iter()
            .filter(|v| !v.is_grease())
            .copied()
            .collect(),
        hello.compression_algorithms().to_vec(),
        extensions,
    );
    let mut hasher = std::collections::hash_map::DefaultHasher::new();
    profile.hash(&mut hasher);
    hasher.finish()
}

impl FingerprintTemplates {
    /// 创建模板仓库；`cache_path` 存在有效缓存时直接载入。
    pub fn new(cache_path: Option<PathBuf>) -> Self {
        Self::with_profile(cache_path, std::env::consts::OS, None)
    }

    /// 手选模板直接用于核心请求；不读取、采样或覆盖自动模式缓存。
    pub fn with_selection(
        cache_path: Option<PathBuf>,
        platform: &str,
        user_agent: Option<&str>,
        preset_id: Option<&str>,
    ) -> Result<Self> {
        if let Some(id) = preset_id {
            let preset = crate::presets::by_id(id)
                .ok_or_else(|| NetError::Parse(format!("Unknown fingerprint preset: {id}")))?;
            info!("Pinned fingerprint preset: {id}");
            return Ok(Self {
                preset: Some(preset),
                pinned: true,
                ..Self::default()
            });
        }
        Ok(Self::with_profile(cache_path, platform, user_agent))
    }

    pub fn with_profile(
        cache_path: Option<PathBuf>,
        platform: &str,
        user_agent: Option<&str>,
    ) -> Self {
        let templates = Self {
            preset: crate::presets::select(platform, user_agent),
            cache_path,
            ..Self::default()
        };
        let cached = templates.cache_path.as_ref().and_then(|path| {
            if std::fs::metadata(path).ok()?.len() > 256 * 1024 {
                warn!("Ignore oversized fingerprint template cache");
                return None;
            }
            let text = std::fs::read_to_string(path).ok()?;
            match serde_json::from_str::<FingerprintTemplate>(&text) {
                Ok(template)
                    if user_agent.is_none() || template.user_agent.as_deref() == user_agent =>
                {
                    Some(template)
                }
                Ok(_) => {
                    info!("Fingerprint cache UA changed; using fallback until probe completes");
                    None
                }
                Err(e) => {
                    warn!(
                        "Ignore unreadable fingerprint template cache {}: {e}",
                        path.display()
                    );
                    None
                }
            }
        });
        if let Some(template) = cached {
            info!("Loaded fingerprint template from cache");
            *templates.source.write() = TemplateSource::Cached;
            templates.generation.store(1, Ordering::Relaxed);
            *templates.hello_hash.lock() = Some(profile_hash(&template.hello));
            *templates.hello.write() = Some(template.hello);
            *templates.h2.write() = Some((template.early_frames, template.pseudo_order));
            *templates.fetch.write() =
                Some((template.fetch_header_order, template.accept_encoding));
            *templates.user_agent.write() = template.user_agent;
        }
        templates
    }

    pub fn record_hello(&self, hello: &ClientHello) {
        if self.pinned {
            return;
        }
        let hash = profile_hash(hello);
        let mut previous = self.hello_hash.lock();
        let old_hash = previous.replace(hash);
        if old_hash != Some(hash) {
            self.generation.fetch_add(1, Ordering::Relaxed);
            // 不把新 TLS 与旧 H2/头模板拼成未采集过的组合。
            if old_hash.is_some() {
                *self.h2.write() = None;
                *self.fetch.write() = None;
                *self.user_agent.write() = None;
                *self.last_persist.lock() = None;
            }
        }
        *self.source.write() = TemplateSource::Sampled;
        *self.hello.write() = Some(hello.clone());
        drop(previous);
        self.maybe_persist();
    }

    /// 节流写盘：首次写或距上次写超过间隔时，把当前齐全的模板原子写入缓存文件。
    fn maybe_persist(&self) {
        let Some(path) = self.cache_path.as_ref() else {
            return;
        };
        let mut last = self.last_persist.lock();
        if last.is_some_and(|at| at.elapsed() < PERSIST_INTERVAL) {
            return;
        }
        let Some(template) = self.captured_snapshot() else {
            return;
        };
        let result = serde_json::to_vec(&template)
            .map_err(std::io::Error::other)
            .and_then(|bytes| {
                let tmp = path.with_extension("tmp");
                std::fs::write(&tmp, bytes)?;
                std::fs::rename(&tmp, path)
            });
        match result {
            Ok(()) => *last = Some(Instant::now()),
            Err(e) => warn!("Persist fingerprint template failed: {e}"),
        }
    }

    /// 从镜像经过的 WebView 请求中采集 HTTP 层特征。
    pub fn observe_request<B>(&self, request: &Request<B>) {
        if self.pinned {
            return;
        }
        let extensions = request.extensions();
        if let (Some(frames), Some(order)) = (
            extensions.get_ref::<EarlyFrameCapture>(),
            extensions.get_ref::<PseudoHeaderOrder>(),
        ) {
            let next = (frames.clone(), order.clone());
            let mut current = self.h2.write();
            if current
                .as_ref()
                .is_some_and(|old| serde_json::to_vec(old).ok() != serde_json::to_vec(&next).ok())
            {
                self.generation.fetch_add(1, Ordering::Relaxed);
            }
            *current = Some(next);
        }
        let headers = request.headers();
        if let Some(ua) = headers
            .get("user-agent")
            .and_then(|value| value.to_str().ok())
        {
            let mut current = self.user_agent.write();
            if current.as_deref().is_some_and(|old| old != ua) {
                self.generation.fetch_add(1, Ordering::Relaxed);
            }
            *current = Some(ua.to_owned());
        }
        let is_fetch = headers
            .get("sec-fetch-mode")
            .is_some_and(|mode| mode.as_bytes() == b"cors");
        if is_fetch {
            let order = headers
                .keys()
                .map(|name| name.as_str().to_owned())
                .collect();
            let accept_encoding = headers
                .get("accept-encoding")
                .and_then(|value| value.to_str().ok())
                .map(str::to_owned);
            *self.fetch.write() = Some((order, accept_encoding));
        }
        self.maybe_persist();
    }

    /// TLS 与 HTTP/2 特征都已采到时返回完整模板；fetch 请求头可缺省。
    pub fn snapshot(&self) -> Option<FingerprintTemplate> {
        if self.pinned {
            return self.preset.clone();
        }
        self.captured_snapshot().or_else(|| self.preset.clone())
    }

    pub fn captured_snapshot(&self) -> Option<FingerprintTemplate> {
        let hello = self.hello.read().clone()?;
        let (early_frames, pseudo_order) = self.h2.read().clone()?;
        let (fetch_header_order, accept_encoding) = self.fetch.read().clone().unwrap_or_default();
        Some(FingerprintTemplate {
            source: *self.source.read(),
            hello,
            early_frames,
            pseudo_order,
            fetch_header_order,
            accept_encoding,
            user_agent: self.user_agent.read().clone(),
            generation: self.generation.load(Ordering::Relaxed),
        })
    }

    /// 供宿主查询的模板状态：是否可回放、采样时的 UA。
    pub fn status_json(&self) -> String {
        let template = self.snapshot();
        serde_json::json!({
            // ready 仅表示真实采样就绪，不能因有预置而跳过后台探针。
            "ready": template.as_ref().is_some_and(|template| template.source.id().is_none()),
            "source": template.as_ref().map(|template| template.source.name()),
            "preset": template.as_ref().and_then(|template| template.source.id()),
            "user_agent": self.user_agent.read().clone(),
            "system_proxy": crate::system_proxy::configured(),
        })
        .to_string()
    }
}

/// 镜像 HTTP 层的采集中间件：请求原样转发，顺带把特征记入模板。
#[derive(Clone)]
struct CaptureLayer {
    templates: Arc<FingerprintTemplates>,
}

impl<S> Layer<S> for CaptureLayer {
    type Service = CaptureService<S>;

    fn layer(&self, inner: S) -> Self::Service {
        CaptureService {
            inner,
            templates: self.templates.clone(),
        }
    }
}

#[derive(Clone)]
struct CaptureService<S> {
    inner: S,
    templates: Arc<FingerprintTemplates>,
}

impl<S, B> Service<Request<B>> for CaptureService<S>
where
    S: Service<Request<B>>,
    B: Send + 'static,
{
    type Output = S::Output;
    type Error = S::Error;

    async fn serve(&self, request: Request<B>) -> std::result::Result<Self::Output, Self::Error> {
        self.templates.observe_request(&request);
        self.inner.serve(request).await
    }
}

type CertIssuer = CachedBoringMitmCertIssuer<InMemoryBoringMitmCertIssuer>;
type SendFuture<'a, T> = Pin<Box<dyn std::future::Future<Output = T> + Send + 'a>>;
type MirrorMiddleware = (
    ConsumeErrLayer<consume_err::Trace, consume_err::StaticOutput<DefaultErrorResponse>>,
    CaptureLayer,
    ArcLayer,
);

/// WebView MITM 的镜像出口。
pub struct MirrorRelay {
    tls: TlsMitmRelay<CertIssuer>,
    /// 浏览器连接：转发并采集模板特征
    http: HttpMitmRelay<MirrorMiddleware>,
    /// 非浏览器连接（如 DoH 模式下经代理的 Dart IO）：只转发，不污染模板
    http_plain: HttpMitmRelay,
    templates: Arc<FingerprintTemplates>,
}

impl MirrorRelay {
    /// 用应用 CA（WebView 已信任）签发入站证书。
    pub fn new(
        ca_cert_pem: &str,
        ca_key_pem: &str,
        templates: Arc<FingerprintTemplates>,
    ) -> Result<Self> {
        let crt = X509::from_pem(ca_cert_pem.as_bytes())
            .map_err(|e| NetError::Proxy(format!("Invalid CA certificate: {e}")))?;
        let key = PKey::private_key_from_pem(ca_key_pem.as_bytes())
            .map_err(|e| NetError::Proxy(format!("Invalid CA key: {e}")))?;
        Ok(Self {
            tls: TlsMitmRelay::new_cached_in_memory(crt, key),
            http: HttpMitmRelay::new(Executor::new()).with_http_middleware((
                ConsumeErrLayer::trace_as_debug().with_response(DefaultErrorResponse::new()),
                CaptureLayer {
                    templates: templates.clone(),
                },
                ArcLayer::new(),
            )),
            http_plain: HttpMitmRelay::new(Executor::new()),
            templates,
        })
    }

    /// 镜像一条已建立 CONNECT 隧道的连接：`ingress` 为 WebView 侧，上游由 `connector` 选址连接。
    ///
    /// 返回只持有自有数据的 `'static` future：rama 的服务 future 若借用参数，
    /// 外层 `tokio::spawn` 无法证明 Send 对所有生命周期成立。
    pub fn serve<I>(
        self: &Arc<Self>,
        ingress: I,
        connector: Arc<EgressConnector>,
        host: String,
        port: u16,
    ) -> impl std::future::Future<Output = Result<()>> + Send + 'static
    where
        I: AsyncRead + AsyncWrite + Send + Unpin + 'static,
    {
        let this = self.clone();
        // 擦除入站类型：重试循环与 relay 的 future 叠在泛型上时，编译器无法证明 Send
        let ingress: BoxStream = Box::new(ingress);
        async move { this.serve_owned(ingress, connector, host, port).await }
    }

    async fn serve_owned(
        self: Arc<Self>,
        ingress: BoxStream,
        connector: Arc<EgressConnector>,
        host: String,
        port: u16,
    ) -> Result<()> {
        let server_host: Host = host
            .parse()
            .map_err(|e| NetError::Proxy(format!("Invalid host {host}: {e}")))?;

        let peek: SendFuture<'_, _> = Box::pin(peek_client_hello_from_input(
            ServiceInput::new(ingress),
            Some(PEEK_TIMEOUT),
        ));
        let (ingress, hello) = peek.await?;
        let hello = hello.ok_or_else(|| {
            NetError::Proxy(format!("No TLS ClientHello from WebView for {host}"))
        })?;
        let browser = browser_tls::is_browser_like(&hello);
        if browser {
            self.templates.record_hello(&hello);
        } else {
            debug!("Mirror {host}: non-browser client, not used as template");
        }

        // 出站逐个地址重试时，每次把入站句柄交给 relay；出站失败不会动到入站
        let ingress = SharedIngress::new(ingress);
        // 闭包只持有自有数据：借用局部变量会让闭包类型带上生命周期，外层 future 无法证明 Send
        let attempt = {
            let this = self.clone();
            let ingress = ingress.clone();
            let server_host = server_host.clone();
            move |egress: BoxStream, ech: Option<Vec<u8>>| {
                let this = this.clone();
                let ingress = ingress.clone();
                let hello = hello.clone();
                let server_host = server_host.clone();
                async move {
                    let built =
                        browser_tls::build(&hello, server_host.clone(), ech.as_deref(), None)
                            .map_err(|e| {
                                HandshakeFailure::abort(NetError::Proxy(format!(
                                    "Build egress: {e}"
                                )))
                            })?;
                    let ech_applied = built.ech_applied;
                    debug!(
                        "Mirror {server_host}:{port} cipher_mode={:?} ech={ech_applied}",
                        built.cipher_mode
                    );

                    let ingress_input = ServiceInput::new(ingress.clone());
                    ingress_input
                        .extensions()
                        .insert(SecureTransport::with_client_hello(hello));
                    let egress = ServiceInput::new(egress);
                    egress
                        .extensions()
                        .insert(ConnectorTarget(HostWithPort::new(server_host, port)));
                    // 握手放进独立任务：rama 握手 future 内部跨 await 持有借用，
                    // 直接嵌进泛型的重试循环会让编译器无法证明外层 future 对所有生命周期 Send
                    let handshake =
                        tokio_util::task::AbortOnDropHandle::new(tokio::spawn(async move {
                            let handshake = this.tls.handshake(
                                BridgeIo(ingress_input, egress),
                                Some(built.connector_data),
                            );
                            tokio::time::timeout(EGRESS_TLS_TIMEOUT, handshake).await
                        }));
                    let outcome = handshake.await.map_err(|e| {
                        HandshakeFailure::abort(NetError::Proxy(format!(
                            "Mirror handshake task: {e}"
                        )))
                    })?;
                    match outcome {
                        Ok(Ok(tls_bridge)) => Ok((tls_bridge, ech_applied)),
                        Ok(Err(error)) => match error.kind() {
                            TlsMitmRelayErrorKind::Handshake {
                                direction: TlsMitmRelayErrorDirection::Egress,
                                ..
                            } if !ingress.touched() => {
                                Err(HandshakeFailure::retry(NetError::Proxy(error.to_string())))
                            }
                            // WebView 握手中途断开：多为浏览器丢弃多余的并行连接，不算故障
                            TlsMitmRelayErrorKind::Handshake {
                                direction: TlsMitmRelayErrorDirection::Ingress,
                                classification: HandshakeRelayClassification::Transport,
                            } => Err(HandshakeFailure::abort(NetError::Io(io::Error::new(
                                io::ErrorKind::ConnectionAborted,
                                error.to_string(),
                            )))),
                            _ => Err(HandshakeFailure::abort(NetError::Proxy(error.to_string()))),
                        },
                        Err(_) if !ingress.touched() => {
                            Err(HandshakeFailure::retry(NetError::Timeout))
                        }
                        Err(_) => Err(HandshakeFailure::abort(NetError::Timeout)),
                    }
                }
            }
        };
        let (tls_bridge, ech_applied) =
            match connector.connect_with_handshake(&host, port, attempt).await {
                Ok(established) => established,
                Err(NetError::Io(e)) if e.kind() == io::ErrorKind::ConnectionAborted => {
                    debug!("Mirror {host}: client left during handshake: {e}");
                    return Ok(());
                }
                Err(e) => return Err(NetError::Proxy(format!("Mirror TLS for {host}: {e}"))),
            };
        info!("Mirror TLS established for {host}:{port} (ECH: {ech_applied})");

        // TLS 建立后 HTTP 层的结束多为客户端主动关闭（预连接、页面离开），只记调试日志。
        // 装箱成 `dyn Future + Send`，在具体生命周期上检查 Send（同 connect_with_handshake）
        let relay: SendFuture<'_, _> = if browser {
            Box::pin(self.http.serve(tls_bridge))
        } else {
            Box::pin(self.http_plain.serve(tls_bridge))
        };
        let relayed = relay.await;
        if let Err(e) = relayed {
            debug!("Mirror HTTP relay for {host} ended: {e}");
        }
        Ok(())
    }
}

/// 可在多次出站尝试间共用的入站连接。
///
/// relay 在出站握手成功之前不会读写入站，所以出站失败时入站（含已窥探的 ClientHello）
/// 完好如初，可以交给下一次尝试；一旦被读写过（`touched`），入站握手已开始，不能再重试。
struct SharedIngress<I> {
    inner: Arc<Mutex<I>>,
    touched: Arc<AtomicBool>,
}

impl<I> SharedIngress<I> {
    fn new(inner: I) -> Self {
        Self {
            inner: Arc::new(Mutex::new(inner)),
            touched: Arc::new(AtomicBool::new(false)),
        }
    }

    fn touched(&self) -> bool {
        self.touched.load(Ordering::Acquire)
    }

    fn mark_touched(&self) {
        self.touched.store(true, Ordering::Release);
    }
}

impl<I> Clone for SharedIngress<I> {
    fn clone(&self) -> Self {
        Self {
            inner: self.inner.clone(),
            touched: self.touched.clone(),
        }
    }
}

impl<I: AsyncRead + Unpin> AsyncRead for SharedIngress<I> {
    fn poll_read(
        self: Pin<&mut Self>,
        cx: &mut Context<'_>,
        buf: &mut ReadBuf<'_>,
    ) -> Poll<io::Result<()>> {
        self.mark_touched();
        Pin::new(&mut *self.inner.lock()).poll_read(cx, buf)
    }
}

impl<I: AsyncWrite + Unpin> AsyncWrite for SharedIngress<I> {
    fn poll_write(
        self: Pin<&mut Self>,
        cx: &mut Context<'_>,
        buf: &[u8],
    ) -> Poll<io::Result<usize>> {
        self.mark_touched();
        Pin::new(&mut *self.inner.lock()).poll_write(cx, buf)
    }

    fn poll_write_vectored(
        self: Pin<&mut Self>,
        cx: &mut Context<'_>,
        bufs: &[io::IoSlice<'_>],
    ) -> Poll<io::Result<usize>> {
        self.mark_touched();
        Pin::new(&mut *self.inner.lock()).poll_write_vectored(cx, bufs)
    }

    fn is_write_vectored(&self) -> bool {
        self.inner.lock().is_write_vectored()
    }

    fn poll_flush(self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<io::Result<()>> {
        Pin::new(&mut *self.inner.lock()).poll_flush(cx)
    }

    fn poll_shutdown(self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<io::Result<()>> {
        self.mark_touched();
        Pin::new(&mut *self.inner.lock()).poll_shutdown(cx)
    }
}

#[cfg(test)]
mod profile_tests {
    use super::*;
    use rama::extensions::ExtensionsMut;
    fn chrome() -> serde_json::Value {
        serde_json::from_str(include_str!(
            "../tests/fixtures/chrome156_linux_do_hello.json"
        ))
        .unwrap()
    }
    #[test]
    fn explicit_preset_ignores_cache_and_capture_without_overwriting_auto_cache() {
        let path = std::env::temp_dir().join(format!("fluxdo-pinned-{}.json", uuid_for_test()));
        let cached = crate::presets::by_id("android-webview133").unwrap();
        let original = serde_json::to_vec(&cached).unwrap();
        std::fs::write(&path, &original).unwrap();
        let pinned = FingerprintTemplates::with_selection(
            Some(path.clone()),
            "android",
            Some("Chrome/156.0"),
            Some("ios-safari26"),
        )
        .unwrap();
        pinned.record_hello(&cached.hello);
        let mut request = Request::builder()
            .header("user-agent", "Chrome/156.0")
            .body(())
            .unwrap();
        request.extensions_mut().insert(cached.early_frames);
        request.extensions_mut().insert(cached.pseudo_order);
        pinned.observe_request(&request);
        pinned.maybe_persist();
        let selected = pinned.snapshot().unwrap();
        assert_eq!(selected.source, TemplateSource::Builtin("ios-safari26"));
        assert_eq!(selected.generation, 0);
        assert!(pinned.captured_snapshot().is_none());
        assert_eq!(std::fs::read(&path).unwrap(), original);
        let auto = FingerprintTemplates::with_selection(Some(path.clone()), "android", None, None)
            .unwrap();
        assert_eq!(auto.snapshot().unwrap().source, TemplateSource::Cached);
        assert!(
            FingerprintTemplates::with_selection(None, "android", None, Some("missing")).is_err()
        );
        std::fs::remove_file(path).unwrap();
    }

    #[test]
    fn fallback_does_not_suppress_probe_or_persist_as_capture() {
        let path = std::env::temp_dir().join(format!("fluxdo-preset-{}.json", uuid_for_test()));
        let templates =
            FingerprintTemplates::with_profile(Some(path.clone()), "android", Some("Chrome/133.0"));
        let preset = templates.snapshot().unwrap();
        assert_eq!(preset.source, TemplateSource::Builtin("android-webview133"));
        assert_eq!(
            serde_json::from_str::<serde_json::Value>(&templates.status_json()).unwrap()["ready"],
            false
        );
        templates.maybe_persist();
        assert!(!path.exists());
        templates.record_hello(&preset.hello);
        assert_eq!(
            templates.snapshot().unwrap().source,
            preset.source,
            "TLS 未配齐 H2 时仍使用完整预置"
        );
        let mut request = Request::builder()
            .header("user-agent", "Chrome/133.0")
            .header("sec-fetch-mode", "cors")
            .header("accept-encoding", "gzip, br")
            .body(())
            .unwrap();
        request.extensions_mut().insert(preset.early_frames);
        request.extensions_mut().insert(preset.pseudo_order);
        templates.observe_request(&request);
        let sampled = templates.snapshot().unwrap();
        assert_eq!(sampled.source, TemplateSource::Sampled);
        assert!(sampled.generation > preset.generation);
        assert!(path.exists());
        let valid =
            FingerprintTemplates::with_profile(Some(path.clone()), "android", Some("Chrome/133.0"));
        assert_eq!(valid.snapshot().unwrap().source, TemplateSource::Cached);
        let changed =
            FingerprintTemplates::with_profile(Some(path.clone()), "android", Some("Chrome/149.0"));
        assert_eq!(
            changed.snapshot().unwrap().source,
            TemplateSource::Builtin("android-chrome149")
        );
        assert!(changed.captured_snapshot().is_none());
        std::fs::remove_file(path).unwrap();
    }
    fn uuid_for_test() -> u128 {
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_nanos()
    }
    #[test]
    fn corrupt_cache_uses_preset_and_missing_platform_uses_standard() {
        let path = std::env::temp_dir().join(format!("fluxdo-bad-preset-{}.json", uuid_for_test()));
        std::fs::write(&path, b"{broken").unwrap();
        let templates = FingerprintTemplates::with_profile(
            Some(path.clone()),
            "ios",
            Some("AppleWebKit/605 Version/26.0"),
        );
        assert_eq!(
            templates.snapshot().unwrap().source,
            TemplateSource::Builtin("ios-safari26")
        );
        let linux = FingerprintTemplates::with_profile(None, "linux", Some("WebKitGTK"));
        assert!(linux.snapshot().is_none());
        std::fs::remove_file(path).unwrap();
    }

    #[test]
    fn connection_randomness_does_not_rotate_profile() {
        let original: ClientHello = serde_json::from_value(chrome()).unwrap();
        let mut next = chrome();
        for ext in next["extensions"].as_array_mut().unwrap() {
            if ext.get("ServerName").is_some() {
                ext["ServerName"] = "cdn.ldstatic.com".into();
            }
            if let Some(ech) = ext.pointer_mut("/EncryptedClientHello/Outer/payload") {
                *ech = serde_json::json!([1, 2, 3]);
            }
            if let Some(opaque) = ext.get_mut("Opaque") {
                if opaque["id"] == 51 {
                    // 改公钥，不改组别/长度
                    let data = opaque["data"].as_array_mut().unwrap();
                    let last = data.len() - 1;
                    data[last] = serde_json::json!(42);
                }
                if opaque["id"] == 56026 {
                    opaque["id"] = serde_json::json!(2570);
                }
            }
        }
        next["extensions"].as_array_mut().unwrap().reverse();
        let next: ClientHello = serde_json::from_value(next).unwrap();
        assert_eq!(profile_hash(&original), profile_hash(&next));
        let templates = FingerprintTemplates::default();
        templates.record_hello(&original);
        templates.record_hello(&next);
        assert_eq!(templates.generation.load(Ordering::Relaxed), 1);
    }
    #[test]
    fn protocol_capability_change_rotates_profile() {
        let original: ClientHello = serde_json::from_value(chrome()).unwrap();
        let mut next = chrome();
        next["cipher_suites"].as_array_mut().unwrap().pop();
        let next: ClientHello = serde_json::from_value(next).unwrap();
        assert_ne!(profile_hash(&original), profile_hash(&next));
    }
}
