//! WebView 流量镜像：按已采集的握手与 HTTP/2 初始帧、伪头顺序配置上游。
//! 这不代表完整 HPACK、HEADERS 优先级或 QUIC/H3 已获逐字复现。
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
        proto::h2::{PseudoHeaderOrder, frame::{EarlyFrameCapture, StreamDependency}},
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

/// 模板格式、回放策略或依赖变化时淘汰旧缓存；不把应用版本当网络后端版本。
pub fn cache_revision() -> String {
    let mut hash = 0xcbf29ce484222325u64;
    for byte in include_bytes!("../Cargo.lock") {
        hash = (hash ^ u64::from(*byte)).wrapping_mul(0x100000001b3);
    }
    format!("6:{hash:016x}")
}

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
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct H2FetchPriority {
    /// None 是实际观察到未设置 PRIORITY；外层 None 则表示尚未采集。
    pub dependency: Option<StreamDependency>,
}

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
    /// 已确认用途的 fetch 请求头名顺序，小写；旧 WebKit 可以没有 Fetch Metadata。
    pub fetch_header_order: Vec<String>,
    /// fetch 类请求的 Accept-Encoding
    pub accept_encoding: Option<String>,
    /// 采样时 WebView 的 User-Agent（WebView 升级后 UA 变化，宿主据此决定重采）
    #[serde(default)]
    pub user_agent: Option<String>,
    /// 至少两次同能力握手观察到的扩展顺序策略；旧缓存缺省为未校准。
    #[serde(default)]
    pub tls_permute_extensions: Option<bool>,
    /// fetch 实际发送的低熵 Client Hints；Some([]) 表示浏览器没有发送。
    #[serde(default)]
    pub low_entropy_client_hints: Option<Vec<(String, String)>>,
    /// 宿主实际系统版本身份，不从 UA 推导；旧缓存缺失时由宿主身份校验淘汰。
    #[serde(default)]
    pub runtime_identity: Option<String>,
    #[serde(default)]
    pub cache_revision: Option<String>,
    #[serde(default)]
    pub fetch_h2_priority: Option<H2FetchPriority>,
    #[serde(default)]
    pub hpack_indexing: Option<std::collections::BTreeMap<String, bool>>,
    /// 模板版本：握手变化时递增，回放连接池据此淘汰旧指纹的连接
    #[serde(skip)]
    pub generation: u64,
}

/// 最近一次镜像的 WebView 握手与 HTTP 层特征，作为网关（dio）回放的模板。
///
/// 配置了缓存路径时落盘，冷启动即可回放，不必等 WebView 再经过一次镜像。
#[derive(Default)]
pub struct FingerprintTemplates {
    pub h3: crate::h3_template::Templates,
    preset: Option<FingerprintTemplate>,
    pinned: bool,
    source: RwLock<TemplateSource>,
    hello: RwLock<Option<ClientHello>>,
    h2: RwLock<Option<(EarlyFrameCapture, PseudoHeaderOrder)>>,
    fetch: RwLock<Option<(Vec<String>, Option<String>)>>,
    user_agent: RwLock<Option<String>>,
    tls_permute_extensions: RwLock<Option<bool>>,
    low_entropy_client_hints: RwLock<Option<Vec<(String, String)>>>,
    hello_hash: Mutex<Option<u64>>,
    generation: AtomicU64,
    hello_observations: AtomicU64,
    cache_path: Option<PathBuf>,
    last_persist: Mutex<Option<Instant>>,
    runtime_identity: Option<String>,
    cache_state: RwLock<&'static str>,
    fetch_h2_priority: RwLock<Option<H2FetchPriority>>,
    hpack_indexing: RwLock<Option<std::collections::BTreeMap<String, bool>>>,
    capability_audit: RwLock<Option<(u64, serde_json::Value)>>,
}

/// 连接身份只比较稳定的浏览器能力，原始模板仍完整保留供新连接回放。
/// SNI、ECH 密文、会话票据、key share 公钥和 GREASE 值不代表浏览器升级。
pub(crate) fn profile_hash(hello: &ClientHello) -> u64 {
    let mut extensions: Vec<_> = hello
        .extensions()
        .iter()
        .filter_map(|ext| {
            // padding 是否出现取决于本次 ClientHello 长度，同一内核也会变化。
            if ext.id().is_grease() || matches!(u16::from(ext.id()), 21 | 41 | 44) {
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
    // 能力身份与扩展顺序分开：所有内核均由独立握手观察顺序策略。
    // 否则非 Chromium 的顺序变化会被当成升级，清空 HTTP 采样而无法校准。
    extensions.sort_by_key(|ext| u16::from(ext.id()));
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
        Self::with_runtime_selection(cache_path, platform, user_agent, preset_id, None)
    }

    pub fn with_runtime_selection(
        cache_path: Option<PathBuf>,
        platform: &str,
        user_agent: Option<&str>,
        preset_id: Option<&str>,
        runtime_identity: Option<&str>,
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
        Ok(Self::with_runtime_profile(
            cache_path,
            platform,
            user_agent,
            runtime_identity,
        ))
    }

    pub fn with_profile(
        cache_path: Option<PathBuf>,
        platform: &str,
        user_agent: Option<&str>,
    ) -> Self {
        Self::with_runtime_profile(cache_path, platform, user_agent, None)
    }

    fn with_runtime_profile(
        cache_path: Option<PathBuf>,
        platform: &str,
        user_agent: Option<&str>,
        runtime_identity: Option<&str>,
    ) -> Self {
        let templates = Self {
            preset: crate::presets::select(platform, user_agent),
            cache_path,
            runtime_identity: runtime_identity.map(str::to_owned),
            cache_state: RwLock::new("missing"),
            ..Self::default()
        };
        let cached = templates.cache_path.as_ref().and_then(|path| {
            if std::fs::metadata(path).ok()?.len() > 256 * 1024 {
                *templates.cache_state.write() = "oversized";
                warn!("Ignore oversized fingerprint template cache");
                return None;
            }
            let text = std::fs::read_to_string(path).ok()?;
            match serde_json::from_str::<FingerprintTemplate>(&text) {
                Ok(template) => {
                    let reason = if template.cache_revision.as_deref() != Some(&cache_revision()) {
                        "schema_or_backend_changed"
                    } else if user_agent.is_some() && template.user_agent.as_deref() != user_agent {
                        "user_agent_changed"
                    } else if runtime_identity.is_some() && template.runtime_identity.as_deref() != runtime_identity {
                        "runtime_changed"
                    } else if !template.is_calibrated() {
                        "incomplete"
                    } else {
                        "loaded_pending_revalidation"
                    };
                    *templates.cache_state.write() = reason;
                    if reason == "loaded_pending_revalidation" {
                        Some(template)
                    } else {
                        info!("Fingerprint cache invalidated: {reason}");
                        None
                    }
                }
                Err(e) => {
                    *templates.cache_state.write() = "invalid_json";
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
            *templates.tls_permute_extensions.write() = template.tls_permute_extensions;
            *templates.low_entropy_client_hints.write() = template.low_entropy_client_hints;
            *templates.fetch_h2_priority.write() = template.fetch_h2_priority;
            *templates.hpack_indexing.write() = template.hpack_indexing;
        }
        templates
    }

    pub fn record_hello(&self, hello: &ClientHello) {
        if self.pinned {
            return;
        }
        let first_in_process = self.hello_observations.fetch_add(1, Ordering::Relaxed) == 0;
        // 同 UA 的引擎更新/实验变化也要重新比较本次进程内的两次握手。
        // 不把旧缓存的一次握手算作本次校准，也允许过去的乱序策略恢复为固定顺序。
        if first_in_process && *self.source.read() == TemplateSource::Cached {
            *self.tls_permute_extensions.write() = None;
            *self.h2.write() = None;
            *self.fetch.write() = None;
            *self.low_entropy_client_hints.write() = None;
            *self.fetch_h2_priority.write() = None;
                *self.hpack_indexing.write() = None;
            *self.last_persist.lock() = None;
            self.generation.fetch_add(1, Ordering::Relaxed);
        }
        let hash = profile_hash(hello);
        let mut previous = self.hello_hash.lock();
        let old_hash = previous.replace(hash);
        let old_hello = self.hello.read().clone();
        if old_hash != Some(hash) {
            self.h3.reset();
            self.generation.fetch_add(1, Ordering::Relaxed);
            // 不把新 TLS 与旧 H2/头模板拼成未采集过的组合。
            if old_hash.is_some() {
                *self.h2.write() = None;
                *self.fetch.write() = None;
                *self.user_agent.write() = None;
                *self.tls_permute_extensions.write() = None;
                *self.low_entropy_client_hints.write() = None;
                *self.fetch_h2_priority.write() = None;
                *self.hpack_indexing.write() = None;
                *self.last_persist.lock() = None;
            }
        } else if !first_in_process && let Some(old_hello) = old_hello {
            let changed = extension_order(&old_hello) != extension_order(hello);
            let policy_changed = {
                let mut policy = self.tls_permute_extensions.write();
                let next = Some(policy.unwrap_or(false) || changed);
                let changed = *policy != next;
                *policy = next;
                changed
            };
            if policy_changed {
                self.generation.fetch_add(1, Ordering::Relaxed);
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
        // 首个导航请求已经有 TLS/H2，但 fetch 和第二次握手可能尚未到达。
        // 此时写盘会把缺失字段缓存为“已就绪”，之后长期跳过重新采样。
        if !template.is_calibrated() {
            return;
        }
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
        self.observe_request_kind(request, false);
    }

    /// 仅可信本地探针/诊断采集器可显式确认 fetch 用途；普通代理入口须用 observe_request。
    /// 不依赖内核提供 Fetch Metadata，也不向被观察的请求补造任何头。
    pub fn observe_probe_fetch<B>(&self, request: &Request<B>) {
        self.observe_request_kind(request, true);
    }

    /// 编码探针单独采样，不能用带实验字段的请求覆盖普通 fetch 头顺序。
    pub fn observe_probe_hpack<B>(&self, request: &Request<B>) {
        if self.pinned || request.version() != rama::http::Version::HTTP_2 { return; }
        let ua = self.user_agent.read();
        if ua.as_deref() != request.headers().get("user-agent").and_then(|v| v.to_str().ok()) { return; }
        let candidates = hpack_probe_header_names();
        let policy = request.headers().iter().filter(|(name, _)| candidates.contains(name))
            .filter_map(|(name, value)| value.hpack_indexing().map(|index| (name.as_str().to_owned(), index)))
            .collect::<std::collections::BTreeMap<_, _>>();
        drop(ua);
        let mut current = self.hpack_indexing.write();
        if current.as_ref() == Some(&policy) { return; }
        *current = Some(policy);
        drop(current);
        self.generation.fetch_add(1, Ordering::Relaxed);
        *self.last_persist.lock() = None;
        self.maybe_persist();
    }

    fn observe_request_kind<B>(&self, request: &Request<B>, known_probe_fetch: bool) {
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
        let is_fetch = known_probe_fetch
            || headers
                .get("sec-fetch-mode")
                .is_some_and(|mode| mode.as_bytes() == b"cors");
        if is_fetch {
            if known_probe_fetch && request.version() == rama::http::Version::HTTP_2 {
                let next = H2FetchPriority {
                    dependency: extensions.get_ref::<rama::http::proto::h2::frame::ReceivedStreamDependency>().map(|p| p.0.clone()),
                };
                let mut current = self.fetch_h2_priority.write();
                if current.as_ref().is_some_and(|old| old != &next) {
                    self.generation.fetch_add(1, Ordering::Relaxed);
                }
                *current = Some(next);
            }
            let order = headers
                .keys()
                .map(|name| name.as_str().to_owned())
                .collect();
            let accept_encoding = headers
                .get("accept-encoding")
                .and_then(|value| value.to_str().ok())
                .map(str::to_owned);
            let next_fetch = Some((order, accept_encoding));
            {
                let mut current = self.fetch.write();
                if current.is_some() && *current != next_fetch {
                    self.generation.fetch_add(1, Ordering::Relaxed);
                }
                *current = next_fetch;
            }
            let hints = headers
                .iter()
                .filter_map(|(name, value)| {
                    is_low_entropy_client_hint(name.as_str())
                        .then(|| {
                            value
                                .to_str()
                                .ok()
                                .map(|value| (name.as_str().to_owned(), value.to_owned()))
                        })
                        .flatten()
                })
                .collect();
            let mut current = self.low_entropy_client_hints.write();
            if current.as_ref().is_some_and(|old| old != &hints) {
                self.generation.fetch_add(1, Ordering::Relaxed);
            }
            *current = Some(hints);
        }
        self.maybe_persist();
    }

    /// 返回可回放的 TLS/H2 模板；是否完成头部和顺序校准另查 is_calibrated。
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
            tls_permute_extensions: *self.tls_permute_extensions.read(),
            low_entropy_client_hints: self.low_entropy_client_hints.read().clone(),
            runtime_identity: self.runtime_identity.clone(),
            cache_revision: Some(cache_revision()),
            fetch_h2_priority: self.fetch_h2_priority.read().clone(),
            hpack_indexing: self.hpack_indexing.read().clone(),
            generation: self.generation.load(Ordering::Relaxed),
        })
    }

    /// 供宿主查询的模板状态：是否可回放、采样时的 UA。
    pub fn status_json(&self) -> String {
        let template = self.snapshot();
        let capabilities = template.as_ref().map(|template| {
            let mut cached = self.capability_audit.write();
            if cached.as_ref().is_none_or(|(generation, _)| *generation != template.generation) {
                *cached = Some((template.generation, browser_tls::selected_capability_audit(
                    &template.hello, template.tls_permute_extensions == Some(true))));
            }
            cached.as_ref().unwrap().1.clone()
        });
        serde_json::json!({
            // ready 仅表示真实采样就绪，不能因有预置而跳过后台探针。
            "ready": template.as_ref().is_some_and(|template| template.source.id().is_none() && template.is_calibrated()),
            "source": template.as_ref().map(|template| template.source.name()),
            "preset": template.as_ref().and_then(|template| template.source.id()),
            "user_agent": self.user_agent.read().clone(),
            "tls_permute_extensions": *self.tls_permute_extensions.read(),
            "fetch_headers_sampled": self.low_entropy_client_hints.read().is_some(),
            "tls_observations": self.hello_observations.load(Ordering::Relaxed),
            "needs_revalidation": !self.pinned && self.hello_observations.load(Ordering::Relaxed) < 2,
            "cache_state": *self.cache_state.read(),
            "cache_revision": cache_revision(),
            "runtime_identity": self.runtime_identity,
            "tls_capabilities": capabilities,
            "h3": self.h3.status(),
            "coverage": ["tls_client_hello", "h2_initial_frames", "h2_pseudo_order", "fetch_header_presence"],
            "fetch_h2_priority_sampled": self.fetch_h2_priority.read().is_some(),
            "hpack_indexing": self.hpack_indexing.read().clone(),
            // 本地 H3 模板就绪不等于业务请求协议、端到端一致性或站点放行已验证。
            "verification_scope": {
                "h3_template": "local_two_origin_calibration",
                "business_request_protocol": "per_connection_logs",
                "cf_acceptance": "not_verified",
            },
            "not_verified": ["hpack_encoding", "navigation_priority", "quic_h3_end_to_end", "cf_acceptance"],
            "system_proxy": crate::system_proxy::configured(),
        })
        .to_string()
    }
}

impl FingerprintTemplate {
    pub(crate) fn is_calibrated(&self) -> bool {
        self.tls_permute_extensions.is_some()
            && self.low_entropy_client_hints.is_some()
            && self.user_agent.is_some()
    }
}

/// 从编码器的默认特殊策略推导探针字段，不维护浏览器/字段白名单。
pub(crate) fn hpack_probe_header_names() -> Vec<rama::http::HeaderName> {
    use rama::http::{header::StandardHeader, HeaderName};
    StandardHeader::all().map(HeaderName::from).filter(hpack_probe_candidate).collect()
}

pub(crate) fn hpack_probe_candidate(name: &rama::http::HeaderName) -> bool {
    use rama::http::{HeaderValue, proto::h2::hpack::Header};
    !name.is_sensitive() && Header::Field { name: name.clone(), value: HeaderValue::from_static("probe") }.skip_value_index()
}

/// 标准定义的三个低熵字段；高熵字段必须由目标站点的 Accept-CH 决定。
pub(crate) fn is_low_entropy_client_hint(name: &str) -> bool {
    matches!(
        name,
        "sec-ch-ua" | "sec-ch-ua-mobile" | "sec-ch-ua-platform"
    )
}

pub(crate) fn extension_order(hello: &ClientHello) -> Vec<u16> {
    hello
        .extensions()
        .iter()
        .map(|ext| u16::from(ext.id()))
        .filter(|id| !rama::tls::is_grease_u16(*id) && !matches!(*id, 21 | 41 | 44))
        .collect()
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

enum MirrorOutbound<T> {
    Relayed(T, bool),
    #[cfg(target_os = "linux")]
    Native(BoxStream),
}

impl MirrorRelay {
    /// 用应用 CA（WebView 已信任）签发入站证书。
    pub fn new(
        ca_cert_pem: &str,
        ca_key_pem: &str,
        templates: Arc<FingerprintTemplates>,
    ) -> Result<Self> {
        let (crt, key) = crate::cert::parse_mitm_ca(ca_cert_pem, ca_key_pem)?;
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
        if !browser {
            debug!("Mirror {host}: non-browser client, not used as template");
        }

        #[cfg(target_os = "linux")]
        let preserve_native = self.templates.snapshot().is_some_and(|template| {
            template.is_calibrated()
                && crate::linux_tls::matches(&template.hello, template.tls_permute_extensions == Some(true))
        });

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
                    // 已匹配原生后端、无需注入 ECH 时保留浏览器端到端 TLS。
                    // 恢复握手可以合法省略字段，不应因此切回另一套 TLS。
                    // 仍经过同一个 DNS/代理出口；证书由浏览器校验，未经认证的
                    // 窥探握手不写入模板，完整采样仍来自受控探针。
                    #[cfg(target_os = "linux")]
                    if preserve_native && ech.is_none() {
                        return Ok(MirrorOutbound::Native(egress));
                    }
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
                        .insert(SecureTransport::with_client_hello(hello.clone()));
                    let egress = ServiceInput::new(egress);
                    egress
                        .extensions()
                        .insert(ConnectorTarget(HostWithPort::new(server_host, port)));
                    // 握手放进独立任务：rama 握手 future 内部跨 await 持有借用，
                    // 直接嵌进泛型的重试循环会让编译器无法证明外层 future 对所有生命周期 Send
                    let templates = this.templates.clone();
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
                        Ok(Ok(tls_bridge)) => {
                            // 证书拒绝或中途失败的握手不能污染可回放模板。
                            if browser {
                                templates.record_hello(&hello);
                            }
                            Ok(MirrorOutbound::Relayed(tls_bridge, ech_applied))
                        },
                        Ok(Err(error)) => match error.kind() {
                            TlsMitmRelayErrorKind::Handshake {
                                direction: TlsMitmRelayErrorDirection::Egress,
                                classification: HandshakeRelayClassification::CertTrust,
                            } => Err(HandshakeFailure::abort(NetError::Certificate(
                                error.to_string(),
                            ))),
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
        let outbound =
            match connector.connect_with_handshake(&host, port, attempt).await {
                Ok(established) => established,
                Err(NetError::Io(e)) if e.kind() == io::ErrorKind::ConnectionAborted => {
                    debug!("Mirror {host}: client left during handshake: {e}");
                    return Ok(());
                }
                Err(e) => return Err(NetError::Proxy(format!("Mirror TLS for {host}: {e}"))),
            };
        let (tls_bridge, ech_applied) = match outbound {
            MirrorOutbound::Relayed(bridge, ech) => (bridge, ech),
            #[cfg(target_os = "linux")]
            MirrorOutbound::Native(mut egress) => {
                info!("WebView native TLS tunnel for {host}:{port} (ECH injection: false)");
                let mut ingress = ingress;
                tokio::io::copy_bidirectional(&mut ingress, &mut egress).await?;
                return Ok(());
            }
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
    fn status_distinguishes_local_h3_sampling_from_end_to_end_verification() {
        let templates = FingerprintTemplates::new(None);
        templates.h3.failure("UDP unavailable");
        let failed: serde_json::Value = serde_json::from_str(&templates.status_json()).unwrap();
        assert_eq!(failed["h3"]["enabled_for_template"], false);
        assert_eq!(failed["h3"]["error"], "UDP unavailable");
        assert_eq!(failed["verification_scope"]["h3_template"], "local_two_origin_calibration");
        assert_eq!(failed["verification_scope"]["business_request_protocol"], "per_connection_logs");
        assert_eq!(failed["verification_scope"]["cf_acceptance"], "not_verified");
        assert!(failed["not_verified"].as_array().unwrap().contains(&serde_json::json!("quic_h3_end_to_end")));
        assert!(!failed["not_verified"].as_array().unwrap().contains(&serde_json::json!("quic_h3")));
        templates.h3.reset();
        let reset: serde_json::Value = serde_json::from_str(&templates.status_json()).unwrap();
        assert_eq!(reset["h3"]["error"], serde_json::Value::Null);
        assert_eq!(reset["verification_scope"], failed["verification_scope"]);
    }

    #[test]
    fn non_chromium_order_change_is_calibrated_without_losing_http_sample() {
        // 合成顺序变化只验证算法，不声称 Safari 实际开启了乱序。
        let reference = crate::presets::by_id("ios-safari18").unwrap();
        assert!(!browser_tls::is_chromium(&reference.hello));
        let templates = FingerprintTemplates::new(None);
        templates.record_hello(&reference.hello);
        let mut request = Request::builder()
            .header("user-agent", "Fixture-WebKit/1")
            .header("sec-fetch-mode", "cors")
            .body(())
            .unwrap();
        request.extensions_mut().insert(reference.early_frames);
        request.extensions_mut().insert(reference.pseudo_order);
        templates.observe_request(&request);
        let mut next = serde_json::to_value(&reference.hello).unwrap();
        next["extensions"].as_array_mut().unwrap().swap(1, 2);
        templates.record_hello(&serde_json::from_value(next).unwrap());
        let status: serde_json::Value = serde_json::from_str(&templates.status_json()).unwrap();
        assert_eq!(status["tls_permute_extensions"], true);
        assert_eq!(status["ready"], true);
    }

    #[test]
    fn damaged_or_wrong_ua_cache_does_not_suppress_probe() {
        let path =
            std::env::temp_dir().join(format!("fluxdo-cache-scenarios-{}.json", uuid_for_test()));
        for contents in [b"{broken".to_vec(), vec![b'x'; 256 * 1024 + 1], {
            let mut template = crate::presets::by_id("ios-safari18").unwrap();
            template.user_agent = Some("old-runtime".into());
            template.tls_permute_extensions = Some(false);
            template.low_entropy_client_hints = Some(Vec::new());
            serde_json::to_vec(&template).unwrap()
        }] {
            std::fs::write(&path, contents).unwrap();
            let templates = FingerprintTemplates::with_profile(
                Some(path.clone()),
                "linux",
                Some("new-runtime"),
            );
            let status: serde_json::Value = serde_json::from_str(&templates.status_json()).unwrap();
            assert_eq!(status["ready"], false);
            assert!(templates.captured_snapshot().is_none());
        }
        std::fs::remove_file(path).unwrap();
    }
    #[test]
    fn explicit_preset_ignores_cache_and_capture_without_overwriting_auto_cache() {
        let path = std::env::temp_dir().join(format!("fluxdo-pinned-{}.json", uuid_for_test()));
        let mut cached = crate::presets::by_id("android-webview133").unwrap();
        cached.cache_revision = Some(cache_revision());
        cached.tls_permute_extensions = Some(true);
        cached.low_entropy_client_hints = Some(Vec::new());
        cached.user_agent = Some("cached-lab".into());
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
        assert!(!path.exists(), "首个握手不能把未校准模板写入缓存");
        templates.record_hello(&sampled.hello);
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
        // 首次确认乱序策略会淘汰未校准连接；之后的随机值/顺序变化不再换代。
        let calibrated = templates.generation.load(Ordering::Relaxed);
        templates.record_hello(&original);
        templates.record_hello(&next);
        assert_eq!(templates.generation.load(Ordering::Relaxed), calibrated);
    }
    #[test]
    fn hpack_uses_shorter_literals_and_preserves_sensitive_fields() {
        use rama::bytes::BytesMut;
        use rama::http::proto::h2::hpack::{Decoder, Encoder, Header};
        use std::{io::Cursor, ops::ControlFlow};
        for (value, huffman) in [("~~~~", false), ("PATCH", false), ("aaaaaaaa", true), ("", false)] {
            for sensitive in [false, true] {
                let mut value_header = rama::http::HeaderValue::from_str(value).unwrap();
                value_header.set_sensitive(sensitive);
                let name = rama::http::HeaderName::from_static("content-type");
                let mut wire = BytesMut::new();
                Encoder::default().encode([Header::Field { name: Some(name.clone()), value: value_header.clone() }], &mut wire);
                // content-type 的静态表索引为 31；敏感字段的 4-bit 索引需要两个字节。
                let value_offset = if sensitive { 2 } else { 1 };
                assert_eq!(wire[value_offset] & 0x80 != 0, huffman, "value={value:?}, sensitive={sensitive}");
                if !huffman { assert!(wire.ends_with(value.as_bytes())); }
                let mut decoded = Vec::new();
                Decoder::default().decode(&mut Cursor::new(&mut wire), |header| {
                    decoded.push(header); ControlFlow::Continue(())
                }).unwrap();
                assert_eq!(decoded, vec![Header::Field { name, value: value_header }]);
                if let Header::Field { value, .. } = &decoded[0] { assert_eq!(value.is_sensitive(), sensitive); }
            }
        }
    }

    #[test]
    fn explicit_hpack_indexing_respects_capacity_and_sensitive_markers() {
        use rama::http::{HeaderName, HeaderValue, proto::h2::hpack::{Encoder, Header}};
        for length in [3100, 5000] {
            for sensitive in [false, true] {
                let mut value = HeaderValue::from_str(&"e".repeat(length)).unwrap();
                value.set_hpack_indexing(Some(true));
                value.set_sensitive(sensitive);
                let mut encoder = Encoder::default();
                for repeated in [false, true] {
                    let mut bytes = rama::bytes::BytesMut::new();
                    encoder.encode([Header::Field { name: Some(HeaderName::from_static("if-none-match")), value: value.clone() }], &mut bytes);
                    if sensitive { assert_eq!(bytes[0] & 240, 16); }
                    else if length > 4096 { assert_eq!(bytes[0] & 240, 0); }
                    else { assert_eq!(bytes[0] & 128 != 0, repeated); }
                }
            }
        }
    }

    #[test]
    fn native_android_padding_presence_does_not_reset_calibration() {
        let samples: Vec<ClientHello> = serde_json::from_str(include_str!(
            "../tests/fixtures/android124_padding_presence.json"
        )).unwrap();
        let padding = |hello: &ClientHello| hello.extensions().iter().any(|e| u16::from(e.id()) == 21);
        assert!(padding(&samples[0]));
        assert!(!padding(&samples[1]));
        assert_eq!(profile_hash(&samples[0]), profile_hash(&samples[1]));
        let templates = FingerprintTemplates::new(None);
        templates.record_hello(&samples[0]);
        templates.record_hello(&samples[1]);
        assert_eq!(*templates.tls_permute_extensions.read(), Some(true));
    }

    #[test]
    fn protocol_capability_change_rotates_profile() {
        let original: ClientHello = serde_json::from_value(chrome()).unwrap();
        let mut next = chrome();
        next["cipher_suites"].as_array_mut().unwrap().pop();
        let next: ClientHello = serde_json::from_value(next).unwrap();
        assert_ne!(profile_hash(&original), profile_hash(&next));
    }

    #[test]
    fn order_policy_comes_from_observed_connections_not_chromium_brand() {
        let reference: FingerprintTemplate = serde_json::from_str(include_str!(
            "../tests/fixtures/chromium99_linux_probe.json"
        ))
        .unwrap();
        let templates = FingerprintTemplates::new(None);
        templates.record_hello(&reference.hello);
        assert_eq!(*templates.tls_permute_extensions.read(), None);
        templates.record_hello(&reference.hello);
        assert_eq!(*templates.tls_permute_extensions.read(), Some(false));
        let mut shuffled = serde_json::to_value(&reference.hello).unwrap();
        shuffled["extensions"].as_array_mut().unwrap().swap(1, 2);
        let shuffled = serde_json::from_value(shuffled).unwrap();
        let generation = templates.generation.load(Ordering::Relaxed);
        templates.record_hello(&shuffled);
        assert_eq!(*templates.tls_permute_extensions.read(), Some(true));
        assert!(templates.generation.load(Ordering::Relaxed) > generation);
        templates.record_hello(&shuffled);
        assert_eq!(*templates.tls_permute_extensions.read(), Some(true));
    }

    #[test]
    fn legacy_cache_requires_new_backend_calibration() {
        let path = std::env::temp_dir().join(format!("fluxdo-legacy-{}.json", uuid_for_test()));
        std::fs::write(
            &path,
            include_str!("../tests/fixtures/chromium99_linux_probe.json"),
        )
        .unwrap();
        let templates = FingerprintTemplates::new(Some(path.clone()));
        assert!(templates.captured_snapshot().is_none());
        let status: serde_json::Value = serde_json::from_str(&templates.status_json()).unwrap();
        assert_eq!(status["ready"], false);
        assert_eq!(status["cache_state"], "schema_or_backend_changed");
        std::fs::remove_file(path).unwrap();
    }

    #[test]
    fn cached_random_order_is_recalibrated_with_two_current_handshakes() {
        let path = std::env::temp_dir().join(format!("fluxdo-revalidate-{}.json", uuid_for_test()));
        let mut reference: FingerprintTemplate = serde_json::from_str(include_str!(
            "../tests/fixtures/ios15_5_wkwebview_probe.json"
        )).unwrap();
        reference.cache_revision = Some(cache_revision());
        reference.tls_permute_extensions = Some(true);
        std::fs::write(&path, serde_json::to_vec(&reference).unwrap()).unwrap();
        let templates = FingerprintTemplates::new(Some(path.clone()));
        assert_eq!(*templates.source.read(), TemplateSource::Cached);
        templates.record_hello(&reference.hello);
        assert_eq!(*templates.tls_permute_extensions.read(), None);
        templates.record_hello(&reference.hello);
        assert_eq!(*templates.tls_permute_extensions.read(), Some(false));
        let status: serde_json::Value = serde_json::from_str(&templates.status_json()).unwrap();
        assert_eq!(status["needs_revalidation"], false);
        reference.cache_revision = Some("future-or-other-backend".into());
        std::fs::write(&path, serde_json::to_vec(&reference).unwrap()).unwrap();
        assert!(FingerprintTemplates::new(Some(path.clone())).captured_snapshot().is_none());
        std::fs::remove_file(path).unwrap();
    }

    #[test]
    fn headers_priority_is_encoded_before_hpack_without_polluting_continuation() {
        use rama::bytes::{BufMut, BytesMut};
        use rama::http::{HeaderMap, Method};
        use rama::http::proto::h2::{frame::{Headers, Pseudo, StreamId}, hpack};
        for priority in [None, Some(StreamDependency::new(StreamId::zero(), 219, true))] {
            let pseudo = Pseudo::request(Method::GET, &"https://localhost/test".parse().unwrap(), None);
            let mut fields = HeaderMap::new();
            fields.insert("x-test", "a".repeat(40_000).parse().unwrap());
            let frame = Headers::new(StreamId::from(1), pseudo, fields, priority.clone());
            let mut encoder = hpack::Encoder::default();
            let mut buf = BytesMut::new();
            let continuation = frame.encode(&mut encoder, &mut (&mut buf).limit(16_384 + 9)).unwrap();
            assert_eq!(buf[3], 1);
            assert_eq!(buf[4] & 0x20 != 0, priority.is_some());
            if priority.is_some() { assert_eq!(&buf[9..14], &[0x80, 0, 0, 0, 219]); }
            let mut tail = BytesMut::new();
            continuation.encode(&mut (&mut tail).limit(16_384 + 9));
            assert_eq!(tail[3], 9);
            assert_eq!(tail[4] & 0x20, 0);
        }
    }

    #[test]
    fn frozen_ua_does_not_reuse_cache_across_runtime_changes() {
        let path = std::env::temp_dir().join(format!("fluxdo-runtime-{}.json", uuid_for_test()));
        let mut reference: FingerprintTemplate = serde_json::from_str(include_str!(
            "../tests/fixtures/ios15_5_wkwebview_probe.json"
        ))
        .unwrap();
        // 模拟两个实际系统版本返回同一 UA；不把 UA 中的系统字段当真实版本。
        reference.user_agent = Some("frozen-apple-ua".into());
        reference.runtime_identity = Some("ios-runtime-A".into());
        reference.cache_revision = Some(cache_revision());
        std::fs::write(&path, serde_json::to_vec(&reference).unwrap()).unwrap();
        for (runtime, reuse) in [("ios-runtime-A", true), ("ios-runtime-B", false)] {
            let templates = FingerprintTemplates::with_runtime_selection(
                Some(path.clone()),
                "ios",
                Some("frozen-apple-ua"),
                None,
                Some(runtime),
            )
            .unwrap();
            assert_eq!(templates.captured_snapshot().is_some(), reuse);
            let status: serde_json::Value = serde_json::from_str(&templates.status_json()).unwrap();
            assert_eq!(status["ready"], reuse);
        }
        reference.runtime_identity = None;
        std::fs::write(&path, serde_json::to_vec(&reference).unwrap()).unwrap();
        let templates = FingerprintTemplates::with_runtime_selection(
            Some(path.clone()),
            "ios",
            Some("frozen-apple-ua"),
            None,
            Some("ios-runtime-B"),
        )
        .unwrap();
        assert!(
            templates.captured_snapshot().is_none(),
            "旧缓存没有宿主版本时必须重采"
        );
        templates.record_hello(&reference.hello);
        templates.record_hello(&reference.hello);
        let mut request = Request::builder()
            .header("user-agent", "frozen-apple-ua")
            .body(())
            .unwrap();
        request.extensions_mut().insert(reference.early_frames);
        request.extensions_mut().insert(reference.pseudo_order);
        templates.observe_probe_fetch(&request);
        let saved: FingerprintTemplate =
            serde_json::from_slice(&std::fs::read(&path).unwrap()).unwrap();
        assert_eq!(saved.runtime_identity.as_deref(), Some("ios-runtime-B"));
        let restored = FingerprintTemplates::with_runtime_selection(
            Some(path.clone()),
            "ios",
            Some("frozen-apple-ua"),
            None,
            Some("ios-runtime-B"),
        )
        .unwrap();
        assert!(restored.captured_snapshot().is_some());
        std::fs::remove_file(path).unwrap();
    }

    #[test]
    fn navigation_cannot_persist_incomplete_fetch_and_client_hints() {
        let path = std::env::temp_dir().join(format!("fluxdo-fetch-{}.json", uuid_for_test()));
        let reference: FingerprintTemplate = serde_json::from_str(include_str!(
            "../tests/fixtures/chromium99_linux_probe.json"
        ))
        .unwrap();
        let templates = FingerprintTemplates::new(Some(path.clone()));
        templates.record_hello(&reference.hello);
        templates.record_hello(&reference.hello);
        let mut request = Request::builder()
            .header("user-agent", "Chrome/99.0")
            .header("sec-fetch-mode", "navigate")
            .body(())
            .unwrap();
        request.extensions_mut().insert(reference.early_frames);
        request.extensions_mut().insert(reference.pseudo_order);
        templates.observe_request(&request);
        assert!(!path.exists());
        request
            .headers_mut()
            .insert("sec-fetch-mode", "cors".parse().unwrap());
        request
            .headers_mut()
            .insert("sec-ch-ua", "\"Chromium\";v=\"99\"".parse().unwrap());
        request
            .headers_mut()
            .insert("sec-ch-ua-full-version", "99.0.0.0".parse().unwrap());
        templates.observe_request(&request);
        let saved: FingerprintTemplate =
            serde_json::from_slice(&std::fs::read(&path).unwrap()).unwrap();
        assert_eq!(
            saved.low_entropy_client_hints.unwrap(),
            vec![("sec-ch-ua".into(), "\"Chromium\";v=\"99\"".into())]
        );
        assert_eq!(saved.tls_permute_extensions, Some(false));
        assert!(
            serde_json::from_str::<serde_json::Value>(&templates.status_json()).unwrap()["ready"]
                .as_bool()
                .unwrap()
        );
        std::fs::remove_file(path).unwrap();
    }
}
