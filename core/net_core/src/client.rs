//! HTTP 客户端：核心对外发请求的统一出口。
//!
//! 两类调用方共用这里：
//! - dio 的请求（经 [`crate::ffi`] 进来）：带指纹模板，TLS 握手与 HTTP/2 设置复刻
//!   WebView，请求头按 WebView fetch 请求的顺序重排；
//! - DoH 查询（[`crate::dns`]）：不带模板，用标准 BoringSSL 配置即可。
//!
//! 连接按「站点 + 模板的建连特征」复用：HTTP/2 多路复用一条连接，HTTP/1.1 走 keep-alive，
//! 与浏览器的连接行为一致；WebView 升级使握手或 HTTP/2 设置变化后，旧指纹的连接不再复用。

use std::{
    collections::{HashMap, HashSet},
    future::Future,
    pin::Pin,
    sync::{
        Arc, Weak,
        atomic::{AtomicU64, Ordering},
    },
    time::{Duration, Instant},
};

use rama::{
    Layer, Service, ServiceInput,
    error::BoxError,
    extensions::{Extension, Extensions, ExtensionsRef},
    http::{
        Body, HeaderMap, HeaderName, HeaderValue, Request, Response, StreamingBody, Version,
        body::{Frame, SizeHint},
        conn::H2ClientContextParams,
        layer::decompression::DecompressionLayer,
    },
    net::{
        address::{Host, HostWithPort},
        client::{ConnectRequest, pool::ConnectionAdmission},
        conn::{ConnectionHealth, ConnectionHealthWatcher},
        http::TargetHttpVersion,
        tls::ApplicationProtocol,
    },
    rt::Executor,
    tls::{
        boring::client::{TlsConnectError, TlsConnectorData, tls_connect},
        client::{ClientHello, TlsClientConfig},
    },
};
use rama_http_backend::client::{HttpClientService, http_connect};
use tokio::sync::{OwnedSemaphorePermit, Semaphore};
use tracing::{debug, info, warn};

#[path = "http3.rs"]
mod h3;

use crate::BoxStream;
use crate::browser_tls::{self, ClientSessions};
use crate::egress::{EGRESS_TLS_TIMEOUT, EgressConnector, HandshakeFailure};
use crate::error::NetError;
use crate::mirror::{FingerprintTemplate, FingerprintTemplates};

/// 逐跳头：不随请求转发到上游。
const HOP_BY_HOP: [&str; 8] = [
    "host",
    "connection",
    "keep-alive",
    "proxy-connection",
    "transfer-encoding",
    "upgrade",
    "te",
    "trailer",
];

/// 同站点 HTTP/1.1 并发连接上限，与浏览器每站点 6 条一致。
const HTTP1_MAX_PER_HOST: usize = 6;
/// 空闲 keep-alive 连接保留多久。服务端常在更短时间内关掉空闲连接，复用时撞上
/// 已关闭的连接由 [`HttpEgressClient::send`] 对无请求体请求的一次重试兜住。
const HTTP1_IDLE_TIMEOUT: Duration = Duration::from_secs(90);
const MAX_POOL_HOSTS: usize = 32;
const MAX_CONNECTIONS: usize = 64;

/// 池化连接：记下协商出的协议版本，请求必须按它发——
/// HTTP/2 连接拒收标着 HTTP/1.1 的请求，反之亦然。
static NEXT_CONNECTION_ID: AtomicU64 = AtomicU64::new(1);

struct Conn {
    _h3_endpoint: Option<Arc<rama::quic::Endpoint>>,
    id: u64,
    service: HttpClientService<Body>,
    version: Version,
    /// TLS 握手恢复了之前的会话（省掉证书校验与完整密钥交换）
    resumed: bool,
    ech_applied: bool,
    ech_accepted: bool,
    tls_backend: &'static str,
    _capacity: Option<OwnedSemaphorePermit>,
}

type Sender = Arc<Conn>;

/// rama 的 HTTP 握手需要连接扩展；明文出口仍使用同一套代理与 DNS 选址。
struct PlainHttpStream(BoxStream, Extensions);
impl ExtensionsRef for PlainHttpStream {
    fn extensions(&self) -> &Extensions {
        &self.1
    }
}
impl tokio::io::AsyncRead for PlainHttpStream {
    fn poll_read(
        mut self: Pin<&mut Self>,
        cx: &mut std::task::Context<'_>,
        buf: &mut tokio::io::ReadBuf<'_>,
    ) -> std::task::Poll<std::io::Result<()>> {
        Pin::new(&mut self.0).poll_read(cx, buf)
    }
}
impl tokio::io::AsyncWrite for PlainHttpStream {
    fn poll_write(
        mut self: Pin<&mut Self>,
        cx: &mut std::task::Context<'_>,
        buf: &[u8],
    ) -> std::task::Poll<std::io::Result<usize>> {
        Pin::new(&mut self.0).poll_write(cx, buf)
    }
    fn poll_flush(
        mut self: Pin<&mut Self>,
        cx: &mut std::task::Context<'_>,
    ) -> std::task::Poll<std::io::Result<()>> {
        Pin::new(&mut self.0).poll_flush(cx)
    }
    fn poll_shutdown(
        mut self: Pin<&mut Self>,
        cx: &mut std::task::Context<'_>,
    ) -> std::task::Poll<std::io::Result<()>> {
        Pin::new(&mut self.0).poll_shutdown(cx)
    }
}

/// 一个站点（连接身份）的连接。
struct HostPool {
    /// HTTP/2：一条连接多路复用，所有请求共享
    shared: Option<Sender>,
    /// HTTP/1.1：空闲的 keep-alive 连接。借出时独占，响应体读完归还
    idle: Vec<(Sender, Instant)>,
    /// 站点谈出的是 HTTP/1.1：之后的冷请求各建各的，不再排队等多路复用
    http1: bool,
    /// HTTP/1.1 在用连接（含建连中）的名额
    slots: Arc<Semaphore>,
    touched: Instant,
}

impl Default for HostPool {
    fn default() -> Self {
        Self {
            shared: None,
            idle: Vec::new(),
            http1: false,
            slots: Arc::new(Semaphore::new(HTTP1_MAX_PER_HOST)),
            touched: Instant::now(),
        }
    }
}

/// 连接池。独立成 `Arc`：借出的 HTTP/1.1 连接归还时要找回这里。
struct PoolState {
    hosts: parking_lot::Mutex<HashMap<String, HostPool>>,
    /// 清池计数：清池前借出或开始建立的连接不再回到新池
    epoch: AtomicU64,
    capacity: Arc<Semaphore>,
}
impl Default for PoolState {
    fn default() -> Self {
        Self {
            hosts: Default::default(),
            epoch: AtomicU64::new(0),
            capacity: Arc::new(Semaphore::new(MAX_CONNECTIONS)),
        }
    }
}

impl PoolState {
    fn prune(hosts: &mut HashMap<String, HostPool>, make_room: bool) {
        hosts.retain(|_, host| {
            host.idle
                .retain(|(conn, since)| since.elapsed() < HTTP1_IDLE_TIMEOUT && is_alive(conn));
            let inactive = host.slots.available_permits() == HTTP1_MAX_PER_HOST
                && host
                    .shared
                    .as_ref()
                    .is_none_or(|conn| Arc::strong_count(conn) == 1);
            !inactive || host.touched.elapsed() < HTTP1_IDLE_TIMEOUT
        });
        if make_room && hosts.len() >= MAX_POOL_HOSTS {
            let oldest = hosts
                .iter()
                .filter(|(_, host)| {
                    host.slots.available_permits() == HTTP1_MAX_PER_HOST
                        && host
                            .shared
                            .as_ref()
                            .is_none_or(|conn| Arc::strong_count(conn) == 1)
                })
                .min_by_key(|(_, host)| host.touched)
                .map(|(key, _)| key.clone());
            if let Some(key) = oldest {
                hosts.remove(&key);
            }
        }
    }
    fn epoch(&self) -> u64 {
        self.epoch.load(Ordering::Relaxed)
    }

    /// 可共享的 HTTP/2 连接；已失效的顺手移除。
    fn shared(&self, key: &str) -> Option<Sender> {
        let mut hosts = self.hosts.lock();
        Self::prune(&mut hosts, false);
        let host = hosts.get_mut(key)?;
        host.touched = Instant::now();
        match &host.shared {
            Some(conn) if is_alive(conn) => Some(conn.clone()),
            Some(_) => {
                debug!("Pooled HTTP/2 connection for {key} closed, reconnecting");
                host.shared = None;
                None
            }
            None => None,
        }
    }

    fn is_http1(&self, key: &str) -> bool {
        self.hosts.lock().get(key).is_some_and(|host| host.http1)
    }

    fn slots(&self, key: &str) -> Arc<Semaphore> {
        let mut hosts = self.hosts.lock();
        let new = !hosts.contains_key(key);
        Self::prune(&mut hosts, new);
        if new && hosts.len() >= MAX_POOL_HOSTS {
            return Arc::new(Semaphore::new(HTTP1_MAX_PER_HOST));
        }
        let host = hosts.entry(key.to_owned()).or_default();
        host.touched = Instant::now();
        host.slots.clone()
    }

    /// 取一条可用的空闲 HTTP/1.1 连接，后进先出（最近用过的最可能还活着）。
    fn take_idle(&self, key: &str) -> Option<Sender> {
        let mut hosts = self.hosts.lock();
        let idle = &mut hosts.get_mut(key)?.idle;
        while let Some((conn, since)) = idle.pop() {
            if since.elapsed() < HTTP1_IDLE_TIMEOUT && is_alive(&conn) {
                return Some(conn);
            }
        }
        None
    }

    /// 收下新建的连接。`identity` 为当前模板的连接身份，其他身份的站点整体淘汰。
    fn admit(&self, key: &str, conn: &Sender, identity: Option<u64>) {
        let mut hosts = self.hosts.lock();
        if let Some(identity) = identity {
            // 模板的建连特征变了，旧指纹的连接不再复用
            let suffix = format!("#{identity}");
            hosts.retain(|existing, _| existing.ends_with(&suffix));
        }
        let new = !hosts.contains_key(key);
        Self::prune(&mut hosts, new);
        if new && hosts.len() >= MAX_POOL_HOSTS {
            return;
        }
        let host = hosts.entry(key.to_owned()).or_default();
        host.touched = Instant::now();
        if matches!(conn.version, Version::HTTP_2 | Version::HTTP_3) {
            host.shared = Some(conn.clone());
        } else {
            host.http1 = true;
        }
    }

    /// 请求失败后连接已失效：移出连接池（只移这一条，别的请求可能已经换了新连接）。
    fn evict(&self, key: &str, conn: &Sender) {
        if is_alive(conn) {
            return;
        }
        self.discard(key, conn);
    }

    fn discard(&self, key: &str, conn: &Sender) {
        let mut hosts = self.hosts.lock();
        if let Some(host) = hosts.get_mut(key)
            && host
                .shared
                .as_ref()
                .is_some_and(|shared| Arc::ptr_eq(shared, conn))
        {
            host.shared = None;
        }
    }

    fn give_back(&self, key: &str, conn: Sender, epoch: u64) {
        if self.epoch() != epoch || !is_alive(&conn) {
            return;
        }
        let mut hosts = self.hosts.lock();
        // 站点已被清池或模板换代淘汰：连接随之丢弃
        if let Some(host) = hosts.get_mut(key)
            && host.idle.len() < HTTP1_MAX_PER_HOST
        {
            host.idle.push((conn, Instant::now()));
        }
    }
}

/// 借出的 HTTP/1.1 连接：随响应体走，读完或丢弃时归还连接池。
/// 中途放弃的响应体会让 rama 把连接标成坏的，归还时据此丢弃。
struct Lease {
    conn: Sender,
    key: String,
    epoch: u64,
    pool: Weak<PoolState>,
    _slot: OwnedSemaphorePermit,
}

impl Drop for Lease {
    fn drop(&mut self) {
        if let Some(pool) = self.pool.upgrade() {
            pool.give_back(&self.key, self.conn.clone(), self.epoch);
        }
    }
}

/// 一次取用的连接。
struct Checkout {
    conn: Sender,
    /// HTTP/1.1 独占借用；HTTP/2 共享连接没有
    lease: Option<Lease>,
    /// 连接不是为这次请求新建的
    reused: bool,
}

/// 响应附带的连接信息，供宿主记日志与诊断。
#[derive(Debug, Clone, Extension)]
pub struct ExchangeInfo {
    pub connection_id: u64,
    pub version: Version,
    pub reused: bool,
    /// 连接的 TLS 握手恢复了之前的会话
    pub tls_resumed: bool,
    pub ech_applied: bool,
    pub ech_accepted: bool,
    /// 取得连接的耗时（复用时近乎为零）
    pub connect: Duration,
}

/// 冷建连合并：同一连接身份的并发冷请求排队等第一条连接，谈成 HTTP/2 就共享它。
#[derive(Default)]
struct ConnectionGate {
    lock: Arc<tokio::sync::Mutex<()>>,
    /// 最近一次建连失败：排队期间失败的，同批等待者直接拿这个结果，不再逐个重试
    failure: parking_lot::Mutex<Option<(Instant, NetError)>>,
}

/// 经指纹出口收发 HTTP 的客户端。
pub struct HttpEgressClient {
    egress: Arc<EgressConnector>,
    /// 指纹模板来源；None 表示用标准 TLS 配置（DoH 查询）
    templates: Option<Arc<FingerprintTemplates>>,
    pool: Arc<PoolState>,
    // 只协调同一连接身份的冷建连，不持有池锁做网络 IO。
    connecting: parking_lot::Mutex<HashMap<String, Weak<ConnectionGate>>>,
    established: AtomicU64,
    /// TLS 会话票据，新连接据此恢复会话
    sessions: ClientSessions,
    exec: Executor,
    h3: Arc<h3::Http3Upgrade>,
    #[cfg(test)]
    test_tls: parking_lot::Mutex<Option<TlsClientConfig>>,
}

impl HttpEgressClient {
    pub fn new(egress: Arc<EgressConnector>, templates: Option<Arc<FingerprintTemplates>>) -> Self {
        Self {
            egress,
            templates,
            pool: Arc::default(),
            connecting: parking_lot::Mutex::new(HashMap::new()),
            established: AtomicU64::new(0),
            sessions: ClientSessions::default(),
            exec: Executor::new(),
            h3: Arc::default(),
            #[cfg(test)]
            test_tls: Default::default(),
        }
    }

    pub(crate) fn with_sessions(mut self, sessions: ClientSessions) -> Self {
        self.sessions = sessions;
        self
    }

    pub(crate) fn with_http3_cache(mut self, path: Option<&str>, namespace: &str) -> Self {
        if let Some(path) = path {
            self.h3 = Arc::new(h3::Http3Upgrade::with_cache(path.into(), namespace));
        }
        self
    }

    pub fn established_connections(&self) -> u64 {
        self.established.load(Ordering::Relaxed) + self.h3.established.load(Ordering::Relaxed)
    }

    /// 池中连接数：`(HTTP/2 共享连接, HTTP/1.1 空闲连接)`。
    pub fn pooled_connections(&self) -> (usize, usize) {
        let hosts = self.pool.hosts.lock();
        hosts.values().fold((0, 0), |(h2, h1), host| {
            (
                h2 + usize::from(
                    host.shared
                        .as_ref()
                        .is_some_and(|c| c.version == Version::HTTP_2),
                ),
                h1 + host.idle.len(),
            )
        })
    }

    pub fn pooled_http3_connections(&self) -> usize {
        self.pool
            .hosts
            .lock()
            .values()
            .filter(|host| {
                host.shared
                    .as_ref()
                    .is_some_and(|c| c.version == Version::HTTP_3)
            })
            .count()
    }

    /// 丢弃所有池化连接。网络切换后调用：旧连接绑在旧网络的源地址上，
    /// 复用它们会一直等到 NAT 超时才失败。
    pub async fn reset_connections(&self) {
        self.h3.reset().await;
        let dropped = {
            let mut hosts = self.pool.hosts.lock();
            self.pool.epoch.fetch_add(1, Ordering::Relaxed);
            std::mem::take(&mut *hosts)
        };
        let (h2, h1) = dropped.values().fold((0, 0), |(h2, h1), host| {
            (
                h2 + usize::from(host.shared.is_some()),
                h1 + host.idle.len(),
            )
        });
        if h2 + h1 > 0 {
            info!("Connection pool reset: dropped {h2} HTTP/2 and {h1} idle HTTP/1.1 connections");
        }
    }

    /// 发送一个请求，返回上游响应（响应体已按 Accept-Encoding 解压，
    /// 扩展里带 [`ExchangeInfo`]）。
    ///
    /// `connect_timeout` 只管建连（含选址重试与 TLS），`head_timeout` 只管请求发出后
    /// 等响应头——两者分开，与 dio 的 connectTimeout / receiveTimeout 语义一致。
    /// 超时以 [`NetError`] 装箱返回，调用方可 downcast 区分。
    pub async fn send(
        &self,
        request: Request<Body>,
        connect_timeout: Option<Duration>,
        head_timeout: Option<Duration>,
    ) -> Result<Response, BoxError> {
        let scheme = request.uri().scheme_str().unwrap_or("https");
        if scheme != "http" && scheme != "https" {
            return Err(NetError::InvalidUrl(format!("Unsupported scheme: {scheme}")).into());
        }
        let secure = scheme == "https";
        let (host, port) = authority_of(&request)?;
        let template = self.templates.as_ref().and_then(|t| t.snapshot());
        let h3_profile = template.as_ref().filter(|t| t.is_calibrated()).and_then(|_| {
            self.templates.as_ref()?.h3.snapshot(request.headers().get("user-agent").and_then(|v|v.to_str().ok()))
        });
        let mut key = format!("{scheme}://{}", pool_key(template.as_ref(), &host, port));
        if let Some((revision,_)) = &h3_profile { if let Some(at)=key.rfind('#') {key.insert_str(at,&format!("#h3:{revision}"));} }
        let target = Target {
            key: &key,
            template: template.as_ref(),
            uses_browser_fingerprint: self.templates.is_some(),
            h3_template: h3_profile.map(|(_,p)|p),
            host: &host,
            port,
            secure,
        };

        // 响应丢失不代表服务端未执行；仅对无请求体的幂等方法重放一次。
        let replay =
            (request.method().is_idempotent() && request.body().is_end_stream()).then(|| {
                (
                    request.method().clone(),
                    request.uri().clone(),
                    request.headers().clone(),
                )
            });
        match self
            .exchange(&target, request, connect_timeout, head_timeout, false)
            .await
        {
            Err(Failure::Stale(error)) => match replay {
                Some((method, uri, headers)) => {
                    info!(
                        "Reused connection to {host}:{port} was closed by peer ({error}), retrying"
                    );
                    let mut request = Request::new(Body::empty());
                    *request.method_mut() = method;
                    *request.uri_mut() = uri;
                    *request.headers_mut() = headers;
                    self.exchange(&target, request, connect_timeout, head_timeout, true)
                        .await
                        .map_err(Failure::into_error)
                }
                None => Err(error),
            },
            result => result.map_err(Failure::into_error),
        }
    }

    async fn exchange(
        &self,
        target: &Target<'_>,
        request: Request<Body>,
        connect_timeout: Option<Duration>,
        head_timeout: Option<Duration>,
        fresh: bool,
    ) -> Result<Response, Failure> {
        let started = Instant::now();
        let h3_generation = self.h3.generation();
        let checkout = self.checkout(target, fresh);
        let checkout = match connect_timeout {
            Some(limit) => tokio::time::timeout(limit, checkout)
                .await
                .map_err(|_| Failure::Fatal(NetError::Timeout.into()))?,
            None => checkout.await,
        }
        .map_err(Failure::Fatal)?;
        let info = ExchangeInfo {
            connection_id: checkout.conn.id,
            version: checkout.conn.version,
            reused: checkout.reused,
            tls_resumed: checkout.conn.resumed,
            ech_applied: checkout.conn.ech_applied,
            ech_accepted: checkout.conn.ech_accepted,
            connect: started.elapsed(),
        };
        let mut request = build_request(
            target.template,
            request,
            target.host,
            target.port,
            checkout.conn.version,
        )
        .map_err(Failure::Fatal)?;
        if checkout.conn.version == Version::HTTP_3 && let Some(profile)=&target.h3_template {
            profile.apply_request(&mut request);
        }
        // 建连与连接池排队不消耗上传时限；完整上传阶段只启动一次，不按块续期。
        if let Some(started) = request
            .extensions()
            .get_ref::<crate::upload_timeout::UploadStarted>()
        {
            started.0.send_replace(Some(tokio::time::Instant::now()));
        }
        let request_trace = crate::request_trace::PreparedRequestTrace::capture(&request);
        let client = DecompressionLayer::new()
            .with_insert_accept_encoding_header(false)
            .into_layer(SharedSender(checkout.conn.clone()));
        let exchange = client.serve(request);
        let result = match head_timeout {
            // 等头超时多半是服务端慢，HTTP/2 连接本身未必坏，不移出连接池
            Some(limit) => match tokio::time::timeout(limit, exchange).await {
                Ok(result) => result,
                Err(_) if checkout.conn.version == Version::HTTP_3 => {
                    self.h3.failed(target.key, h3_generation);
                    self.pool.discard(target.key, &checkout.conn);
                    return Err(Failure::Stale(NetError::ReceiveTimeout.into()));
                }
                Err(_) => return Err(Failure::Fatal(NetError::ReceiveTimeout.into())),
            },
            None => exchange.await,
        };
        match result {
            Ok(response) => {
                if target.secure && checkout.conn.version == Version::HTTP_3 {
                    self.h3
                        .observe_at(target.key, target.host, response.headers(), h3_generation);
                }
                if target.secure && checkout.conn.version != Version::HTTP_3 {
                    self.h3.observe_and_upgrade(
                        target,
                        response.headers(),
                        self.egress.clone(),
                        self.pool.clone(),
                        self.exec.clone(),
                        h3_generation,
                    );
                }
                // 解压层换掉了响应体类型，统一回 Body 交给调用方；
                // HTTP/1.1 连接随响应体走，读完才归还
                let response = response.map(|body| {
                    Body::new(LeasedBody {
                        inner: Body::new(body),
                        lease: checkout.lease,
                        shared: Some(checkout.conn.clone()),
                    })
                });
                response.extensions().insert(info);
                if let Some(trace) = request_trace {
                    response.extensions().insert(trace);
                }
                Ok(response)
            }
            Err(error) => {
                // 请求体可能已被消费，这里不重试；是否可重放由调用方判断
                if checkout.conn.version == Version::HTTP_3 {
                    self.h3.failed(target.key, h3_generation);
                    self.pool.discard(target.key, &checkout.conn);
                    return Err(Failure::Stale(error));
                }
                self.pool.evict(target.key, &checkout.conn);
                if checkout.reused && !is_alive(&checkout.conn) {
                    Err(Failure::Stale(error))
                } else {
                    Err(Failure::Fatal(error))
                }
            }
        }
    }

    /// 取（或新建）到站点的连接。
    async fn checkout(&self, target: &Target<'_>, fresh: bool) -> Result<Checkout, BoxError> {
        let key = target.key;
        if !fresh && let Some(conn) = self.pool.shared(key) {
            return Ok(Checkout {
                conn,
                lease: None,
                reused: true,
            });
        }

        // 协议未知（或已知是 HTTP/2）的冷建连：同站点只建一条，等它谈出协议
        if target.secure && !self.pool.is_http1(key) {
            let gate = {
                let mut connecting = self.connecting.lock();
                connecting.retain(|_, weak| weak.strong_count() > 0);
                let gate = connecting
                    .get(key)
                    .and_then(Weak::upgrade)
                    .unwrap_or_default();
                connecting.insert(key.to_owned(), Arc::downgrade(&gate));
                gate
            };
            let waiting_since = Instant::now();
            let guard = gate.lock.clone().lock_owned().await;
            if let Some(conn) = self.pool.shared(key) {
                return Ok(Checkout {
                    conn,
                    lease: None,
                    reused: true,
                });
            }
            if let Some((failed_at, error)) = &*gate.failure.lock()
                && *failed_at >= waiting_since
            {
                return Err(error.replicate().into());
            }
            if !self.pool.is_http1(key) {
                let slot = self.slot(key).await?;
                return match self.establish(target, slot).await {
                    Ok(checkout) => Ok(checkout),
                    Err(error) => {
                        // 同批等待者共享失败，避免不可达站点被串行握手重试 N 次
                        *gate.failure.lock() = Some((Instant::now(), replicate(&error)));
                        Err(error)
                    }
                };
            }
            // 首条连接谈出的是 HTTP/1.1：放开排队，各请求各取连接
            drop(guard);
        }

        // HTTP/1.1：每个请求独占一条连接，同站点最多 HTTP1_MAX_PER_HOST 条
        let slot = self.slot(key).await?;
        if !fresh && let Some(conn) = self.pool.take_idle(key) {
            let lease = self.lease(key, conn.clone(), slot);
            return Ok(Checkout {
                conn,
                lease: Some(lease),
                reused: true,
            });
        }
        self.establish(target, slot).await
    }

    async fn slot(&self, key: &str) -> Result<OwnedSemaphorePermit, BoxError> {
        self.pool
            .slots(key)
            .acquire_owned()
            .await
            .map_err(|_| NetError::Cancelled.into())
    }

    fn lease(&self, key: &str, conn: Sender, slot: OwnedSemaphorePermit) -> Lease {
        Lease {
            conn,
            key: key.to_owned(),
            epoch: self.pool.epoch(),
            pool: Arc::downgrade(&self.pool),
            _slot: slot,
        }
    }

    /// 新建一条连接并收进连接池；HTTP/1.1 的连同名额一起借给这次请求。
    async fn establish(
        &self,
        target: &Target<'_>,
        slot: OwnedSemaphorePermit,
    ) -> Result<Checkout, BoxError> {
        let epoch = self.pool.epoch();
        // Keep cached idle sockets from holding every global permit.
        if self.pool.capacity.available_permits() == 0 {
            let mut hosts = self.pool.hosts.lock();
            for host in hosts.values_mut() {
                host.idle.clear();
            }
        }
        let capacity = self
            .pool
            .capacity
            .clone()
            .acquire_owned()
            .await
            .map_err(|_| NetError::Cancelled)?;
        let mut conn = if target.secure {
            self.h3
                .connect_or_tcp(
                    target,
                    &self.egress,
                    &self.pool,
                    self.exec.clone(),
                    self.connect(target.template, target.host, target.port),
                )
                .await?
        } else {
            self.connect_plain(target.host, target.port).await?
        };
        Arc::get_mut(&mut conn)
            .expect("new connection is uniquely owned")
            ._capacity = Some(capacity);
        self.established.fetch_add(1, Ordering::Relaxed);

        // 切网清池之前开始的连接仍可完成原请求，但不能污染新连接池；
        // 模板的建连特征在建连期间变化时同理
        let current_identity = self
            .templates
            .as_ref()
            .and_then(|t| t.snapshot())
            .map(|current| current.connection_identity());
        let identity = target.template.map(FingerprintTemplate::connection_identity);
        let stale_identity = identity.is_some() && current_identity != identity;
        if self.pool.epoch() == epoch && !stale_identity {
            self.pool.admit(target.key, &conn, identity);
        }
        if matches!(conn.version, Version::HTTP_2 | Version::HTTP_3) {
            return Ok(Checkout {
                conn,
                lease: None,
                reused: false,
            });
        }
        let mut lease = self.lease(target.key, conn.clone(), slot);
        lease.epoch = epoch;
        Ok(Checkout {
            conn,
            lease: Some(lease),
            reused: false,
        })
    }

    async fn connect_plain(&self, host: &str, port: u16) -> Result<Sender, BoxError> {
        let started = Instant::now();
        let extensions = Extensions::new();
        extensions.insert(TargetHttpVersion(Version::HTTP_11));
        let stream = PlainHttpStream(
            self.egress
                .connect_raw(host, port)
                .await
                .map_err(|e| e.with_context(&format!("Connect {host}:{port}")))?,
            extensions,
        );
        let input = ConnectRequest::new(HostWithPort::new(host.parse::<Host>()?, port));
        let established = http_connect(stream, input, self.exec.clone()).await?;
        info!(
            "Connection established for {host}:{port} (HTTP/1.1, plaintext) in {}ms",
            started.elapsed().as_millis()
        );
        Ok(Arc::new(Conn {
            _h3_endpoint: None,
            id: NEXT_CONNECTION_ID.fetch_add(1, Ordering::Relaxed),
            service: established.conn,
            version: Version::HTTP_11,
            resumed: false,
            ech_applied: false,
            ech_accepted: false,
            tls_backend: "plaintext",
            _capacity: None,
        }))
    }

    async fn connect(
        &self,
        template: Option<&FingerprintTemplate>,
        host: &str,
        port: u16,
    ) -> Result<Sender, BoxError> {
        let started = Instant::now();
        let server_host: Host = host.parse()?;
        let hello = template.map(|template| template.hello.clone());
        let permute_extensions = template.is_some_and(|t| t.tls_permute_extensions == Some(true));
        let h2_params = template.map(|template| H2ClientContextParams {
            early_frames: Some(template.early_frames.clone()),
            headers_pseudo_order: Some(template.pseudo_order.clone()),
            ..Default::default()
        });
        let exec = self.exec.clone();
        let sessions = self.sessions.clone();
        #[cfg(target_os = "linux")]
        let use_native = template.is_some_and(|template| template.is_calibrated())
            && hello.as_ref().is_some_and(|hello| crate::linux_tls::matches(hello, permute_extensions));
        #[cfg(test)]
        let test_tls = self.test_tls.lock().clone();
        #[cfg(all(test, target_os = "linux"))]
        let use_native = use_native && test_tls.is_none();

        let attempt = move |stream: BoxStream, ech: Option<Vec<u8>>| {
            let server_host = server_host.clone();
            let hello = hello.clone();
            let h2_params = h2_params.clone();
            let exec = exec.clone();
            let sessions = sessions.clone();
            #[cfg(test)]
            let test_tls = test_tls.clone();
            // 装箱成 `dyn Future + Send`：rama 的握手 future 内部跨 await 持有借用，
            // 留给自动推断时编译器无法证明它对所有生命周期 Send
            Box::pin(async move {
                #[cfg(target_os = "linux")]
                if use_native && ech.is_none() {
                    let tls = tokio::time::timeout(EGRESS_TLS_TIMEOUT,
                        crate::linux_tls::NativeTlsStream::connect(stream, &server_host.to_string(),
                            port, hello.as_ref().expect("native profile checked"), sessions.native.clone()))
                        .await.map_err(|_| HandshakeFailure::retry(NetError::Timeout))?
                        .map_err(|e| match e {
                            NetError::Certificate(_) => HandshakeFailure::abort(e),
                            _ => HandshakeFailure::retry(e),
                        })?;
                    let resumed = tls.resumed();
                    let version = match tls.alpn().as_deref() {
                        Some(b"h2") => Version::HTTP_2,
                        Some(b"http/1.0") => Version::HTTP_10,
                        Some(b"http/1.1") | None => Version::HTTP_11,
                        _ => return Err(HandshakeFailure::abort(NetError::Proxy("unsupported negotiated ALPN".into()))),
                    };
                    let stream = PlainHttpStream(Box::new(tls), Extensions::new());
                    stream.extensions().insert(TargetHttpVersion(version));
                    let input = ConnectRequest::new(HostWithPort::new(server_host, port));
                    if version == Version::HTTP_2 && let Some(params) = h2_params {
                        input.extensions().insert(params);
                    }
                    let established = tokio_util::task::AbortOnDropHandle::new(tokio::spawn(
                        http_connect(stream, input, exec)))
                        .await.map_err(|e| HandshakeFailure::abort(NetError::Proxy(format!("Handshake task: {e}"))))?
                        .map_err(|e| HandshakeFailure::retry(NetError::Proxy(format!("HTTP handshake: {e}"))))?;
                    return Ok((Arc::new(Conn {
                        _h3_endpoint: None,
                        id: NEXT_CONNECTION_ID.fetch_add(1, Ordering::Relaxed),
                        service: established.conn, version, resumed, ech_applied: false,
                        ech_accepted: false, tls_backend: "GnuTLS", _capacity: None,
                    }), version, false, resumed));
                }
                let sessions = sessions.for_peer(
                    &server_host.to_string(),
                    port,
                    hello.as_ref(),
                    ech.as_deref(),
                );
                let (connector_data, ech_applied) = tls_config(
                    hello.as_ref(),
                    server_host.clone(),
                    ech.as_deref(),
                    &sessions,
                    permute_extensions,
                )
                .map_err(|e| {
                    HandshakeFailure::abort(NetError::Proxy(format!("Build egress: {e}")))
                })?;
                #[cfg(test)]
                let connector_data = match test_tls {
                    Some(mut config) => {
                        config.set_server_name(server_host.clone());
                        sessions.connector_data(&config).unwrap()
                    }
                    None => connector_data,
                };
                let tls = tokio::time::timeout(
                    EGRESS_TLS_TIMEOUT,
                    tls_connect(ServiceInput::new(stream), Some(connector_data)),
                )
                .await
                .map_err(|_| HandshakeFailure::retry(NetError::Timeout))?
                .map_err(|e| tls_handshake_failure(&e))?;

                let resumed = tls.ssl_ref().session_reused();
                let ech_accepted = tls.ssl_ref().ech_accepted();
                // 裸 tls_connect 不挂协商参数，直接问 BoringSSL 选中的 ALPN；
                // rama 的 http_connect 据此选 h2 或 h1 的握手实现
                let version = match tls.ssl_ref().selected_alpn_protocol() {
                    Some(protocol) if protocol == ApplicationProtocol::HTTP_2.as_bytes() => {
                        Version::HTTP_2
                    }
                    _ => Version::HTTP_11,
                };
                tls.extensions().insert(TargetHttpVersion(version));
                if version == Version::HTTP_2
                    && let Some(params) = h2_params
                {
                    tls.extensions().insert(params);
                }

                // 握手放进独立任务：rama 的 h2 握手 future 跨 await 持有借用，
                // 直接留在这里会让编译器无法证明本 future 对所有生命周期 Send
                let input = ConnectRequest::new(HostWithPort::new(server_host, port));
                // 当前 rama 的普通 HTTP 握手从 ConnectRequest 读取 H2 参数，
                // 只写到 TLS stream 会静默使用默认 SETTINGS / 窗口 / 伪头顺序。
                if let Some(params) = tls.extensions().get_ref::<H2ClientContextParams>() {
                    input.extensions().insert(params.clone());
                }
                // 普通 JoinHandle 在丢弃时会脱离外层继续运行；取消请求或
                // 备用路径胜出时必须终止这个握手，避免遗留 socket/任务。
                let established = tokio_util::task::AbortOnDropHandle::new(tokio::spawn(
                    http_connect(tls, input, exec),
                ))
                .await
                .map_err(|e| {
                    HandshakeFailure::abort(NetError::Proxy(format!("Handshake task: {e}")))
                })?
                .map_err(|e| {
                    HandshakeFailure::retry(NetError::Proxy(format!("HTTP handshake: {e}")))
                })?;
                let conn = Conn {
                    _h3_endpoint: None,
                    id: NEXT_CONNECTION_ID.fetch_add(1, Ordering::Relaxed),
                    service: established.conn,
                    version,
                    resumed,
                    ech_applied,
                    ech_accepted,
                    tls_backend: "BoringSSL",
                    _capacity: None,
                };
                Ok((Arc::new(conn), version, ech_applied, resumed))
            }) as Pin<Box<dyn Future<Output = _> + Send>>
        };

        let (sender, version, ech_applied, resumed): (Sender, Version, bool, bool) = self
            .egress
            .connect_client(host, port, attempt)
            .await
            .map_err(|e| {
                warn!(
                    "Connect {host}:{port} failed after {}ms: {e}",
                    started.elapsed().as_millis()
                );
                e.with_context(&format!("Connect {host}:{port}"))
            })?;
        info!(
            "Connection established for {host}:{port} ({version:?}, ECH: {ech_applied}, ECH accepted: {}, resumed: {resumed}, fingerprint: {}, h2_template: {}, tls_permute_extensions: {:?}, tls_backend: {}) in {}ms",
            sender.ech_accepted,
            template.map_or("standard", |template| template
                .source
                .id()
                .unwrap_or(template.source.name())),
            template.is_some(),
            template.and_then(|t| t.tls_permute_extensions),
            sender.tls_backend,
            started.elapsed().as_millis()
        );
        Ok(sender)
    }
}

/// 一次请求的连接身份与目标。
struct Target<'a> {
    key: &'a str,
    template: Option<&'a FingerprintTemplate>,
    /// 区分尚无样本的浏览器客户端与不使用指纹的普通/DoH 客户端。
    uses_browser_fingerprint: bool,
    h3_template: Option<Arc<crate::h3_template::Profile>>,
    host: &'a str,
    port: u16,
    secure: bool,
}

/// 一次交换的失败。`Stale` 表示复用的连接已被对端关闭，请求未必送达，可安全重放时重试。
enum Failure {
    Stale(BoxError),
    Fatal(BoxError),
}

impl Failure {
    fn into_error(self) -> BoxError {
        match self {
            Self::Stale(error) | Self::Fatal(error) => error,
        }
    }
}

/// 复制一份错误给同批等待者，保留分类（超时仍是超时）。
fn replicate(error: &BoxError) -> NetError {
    match error.downcast_ref::<NetError>() {
        Some(error) => error.replicate(),
        None => NetError::Proxy(error.to_string()),
    }
}

/// TLS 握手失败的分类：证书校验失败单列，宿主据此提示证书问题而不是网络不通。
fn tls_handshake_failure<S>(error: &TlsConnectError<S>) -> HandshakeFailure {
    match error {
        TlsConnectError::Handshake {
            error: handshake, ..
        } if handshake.as_ssl_error_stack().is_some_and(|stack| {
            stack
                .iter()
                .any(|error| error.reason() == Some("ECH_REJECTED"))
        }) =>
        {
            // BoringSSL 只有完成公共名称的证书认证后才返回 ECH_REJECTED。
            // 其他错误不能调用 get_ech_retry_configs，否则会触发 BoringSSL 断言。
            match handshake.ssl() {
                Some(ssl) => HandshakeFailure::authenticated_ech_retry(
                    ssl.get_ech_retry_configs().unwrap_or_default().to_vec(),
                ),
                None => HandshakeFailure::abort(tls_error(&error.to_string())),
            }
        }
        TlsConnectError::Builder(_) => HandshakeFailure::abort(tls_error(&error.to_string())),
        _ => HandshakeFailure::retry(tls_error(&error.to_string())),
    }
}

fn tls_error(message: &str) -> NetError {
    let lower = message.to_ascii_lowercase();
    if lower.contains("certificate") || lower.contains("cert_verify") {
        NetError::Certificate(message.to_owned())
    } else {
        NetError::Proxy(message.to_owned())
    }
}

/// HTTP/1.1 响应体：持有连接借用，读到结尾或被丢弃时归还连接。
struct LeasedBody {
    inner: Body,
    lease: Option<Lease>,
    // H2/H3 responses retain the pool budget until EOF/drop, including paused downloads.
    shared: Option<Sender>,
}

impl StreamingBody for LeasedBody {
    type Data = bytes::Bytes;
    type Error = BoxError;

    fn poll_frame(
        mut self: Pin<&mut Self>,
        cx: &mut std::task::Context<'_>,
    ) -> std::task::Poll<Option<Result<Frame<Self::Data>, Self::Error>>> {
        let polled = Pin::new(&mut self.inner).poll_frame(cx);
        if let std::task::Poll::Ready(None) = polled {
            // 读完立即归还，不等调用方丢弃响应体
            self.lease.take();
            self.shared.take();
        }
        polled
    }

    fn is_end_stream(&self) -> bool {
        self.inner.is_end_stream()
    }

    fn size_hint(&self) -> SizeHint {
        self.inner.size_hint()
    }
}

/// 上游 TLS 配置：有模板时复刻模板的 ClientHello，无模板用标准配置（DoH）。
fn tls_config(
    hello: Option<&ClientHello>,
    server_host: Host,
    ech: Option<&[u8]>,
    sessions: &ClientSessions,
    permute_extensions: bool,
) -> Result<(TlsConnectorData, bool), BoxError> {
    match hello {
        Some(hello) => {
            let built = browser_tls::build_with_permutation(
                hello,
                server_host,
                ech,
                Some(sessions),
                permute_extensions,
            )?;
            Ok((built.connector_data, built.ech_applied))
        }
        None => {
            let mut config = TlsClientConfig::default();
            config.set_server_name(server_host);
            config.set_platform_verifier();
            config.set_alpn(
                [ApplicationProtocol::HTTP_2, ApplicationProtocol::HTTP_11]
                    .into_iter()
                    .collect(),
            );
            let mut data = sessions.connector_data(&config)?;
            if let Some(ech) = ech {
                data.config.set_ech_config_list(ech)?;
            }
            Ok((data, ech.is_some()))
        }
    }
}

fn authority_of<B>(request: &Request<B>) -> Result<(String, u16), BoxError> {
    let authority = request
        .uri()
        .authority()
        .ok_or_else(|| BoxError::from("request URI has no host"))?;
    Ok((
        authority.host().to_string(),
        authority.port().as_u16().unwrap_or_else(|| {
            if request.uri().scheme_str() == Some("http") {
                80
            } else {
                443
            }
        }),
    ))
}

fn pool_key(template: Option<&FingerprintTemplate>, host: &str, port: u16) -> String {
    let identity = template.map_or(0, FingerprintTemplate::connection_identity);
    if host.contains(':') && !host.starts_with('[') {
        format!("[{host}]:{port}#{identity}")
    } else {
        format!("{host}:{port}#{identity}")
    }
}

/// HTTP/2 连接结束后其准入状态随之释放，尝试准入即可判断连接是否仍可用。
fn is_alive(sender: &Sender) -> bool {
    let extensions = sender.service.extensions();
    if extensions
        .get_ref::<ConnectionHealthWatcher>()
        .is_some_and(|watcher| watcher.health() == ConnectionHealth::Broken)
    {
        return false;
    }
    extensions
        .get_ref::<ConnectionAdmission>()
        .is_none_or(|admission| admission.try_acquire(&Extensions::new()).is_ok())
}

/// 让池中共享的发送端可被外层中间件按值持有。
#[derive(Clone)]
struct SharedSender(Sender);

impl Service<Request<Body>> for SharedSender {
    type Output = Response;
    type Error = BoxError;

    async fn serve(&self, request: Request<Body>) -> Result<Self::Output, Self::Error> {
        self.0.service.serve(request).await
    }
}

/// 整理成发往上游的请求：绝对 URI、去逐跳头、按模板设置 Accept-Encoding 与头顺序。
fn build_request(
    template: Option<&FingerprintTemplate>,
    mut request: Request<Body>,
    host: &str,
    port: u16,
    version: Version,
) -> Result<Request<Body>, BoxError> {
    // 仅默认 fetch 用途复用采样权重；显式优先级优先。采样依赖属于旧连接，
    // 不能复制旧流号：这里先挂根并保留权重与排他标记，由 HTTP/2 层在分配流号时
    // 按 Chromium 规则改挂到同档在途的上一个流，形成先来先服务的链。
    if version == Version::HTTP_2
        && let Some(template) = template.filter(|t| t.is_calibrated())
        && request.uri().scheme_str() == Some("https")
        && template.user_agent.as_deref() == request.headers().get("user-agent").and_then(|v| v.to_str().ok())
        && request.headers().get("sec-fetch-mode").is_some_and(|v| v == "cors")
        && !request.headers().contains_key("priority")
        && !request.extensions().contains::<rama::http::proto::h2::frame::StreamDependency>()
        && !request.extensions().contains::<rama::http::proto::h2::frame::ReceivedStreamDependency>()
        && let Some(priority) = template.fetch_h2_priority.as_ref().and_then(|p| p.dependency.as_ref())
    {
        request.extensions().insert(rama::http::proto::h2::frame::StreamDependency::new(
            rama::http::proto::h2::frame::StreamId::zero(), priority.weight, priority.is_exclusive));
    }
    let uri = request.uri();
    // 保留 wire 原样拼写转发，不做重新编码
    let path = uri
        .path()
        .map(|path| path.as_encoded_str().into_owned())
        .unwrap_or_else(|| "/".to_owned());
    let path_and_query = match uri.query() {
        Some(query) => format!("{path}?{}", query.as_encoded_str()),
        None => path,
    };
    let scheme = uri.scheme_str().unwrap_or("https").to_owned();
    let default_port = if scheme == "http" { 80 } else { 443 };
    let host = if host.contains(':') && !host.starts_with('[') {
        format!("[{host}]")
    } else {
        host.to_owned()
    };
    let authority = if port == default_port {
        host
    } else {
        format!("{host}:{port}")
    };
    *request.uri_mut() = format!("{scheme}://{authority}{path_and_query}").parse()?;
    *request.version_mut() = version;

    let headers = request.headers_mut();
    // Connection 可声明额外的逐跳头；须先读完所有声明，再剔除 Connection 自身。
    let connection_options: Vec<HeaderName> = headers
        .get_all("connection")
        .iter()
        .filter_map(|value| value.to_str().ok())
        .flat_map(|value| value.split(','))
        .filter_map(|name| HeaderName::from_bytes(name.trim().as_bytes()).ok())
        .collect();
    for name in connection_options {
        headers.remove(name);
    }
    for name in HOP_BY_HOP {
        headers.remove(name);
    }
    if let Some(template) = template {
        // UA 推导无法覆盖旧版 GREASE 品牌、Chromium/Chrome 品牌差异，
        // 也无法判断自定义 WebView UA 是否抑制了 Client Hints。
        // 只为同 UA 的 HTTPS 请求复用实际低熵采样；不伪造高熵提示。
        if scheme == "https"
            && template.user_agent.as_deref().is_some_and(|ua| {
                headers.get("user-agent").and_then(|v| v.to_str().ok()) == Some(ua)
            })
            && let Some(hints) = &template.low_entropy_client_hints
        {
            if version == Version::HTTP_2 && template.is_calibrated()
                && let Some(policy) = &template.hpack_indexing
            {
                for (name, value) in headers.iter_mut() {
                    if crate::mirror::hpack_probe_candidate(name) && !value.is_sensitive()
                        && let Some(index) = policy.get(name.as_str())
                    {
                        value.set_hpack_indexing(Some(*index));
                    }
                }
            }
            // 旧 WebKit 的真实 fetch 不发送 Fetch Metadata。仅对同 UA 的 HTTPS
            // cors 请求移除调用方额外添加的这一组头；不从回环探针复制站点关系，
            // 不改 Origin、Referer、Cookie 或 CSRF，也不改导航请求和未校准模板。
            if template.is_calibrated()
                && headers.get("sec-fetch-mode").is_some_and(|v| v == "cors")
                && !template
                    .fetch_header_order
                    .iter()
                    .any(|name| name.eq_ignore_ascii_case("sec-fetch-mode"))
            {
                let unsupported: Vec<_> = headers
                    .keys()
                    .filter(|name| name.as_str().starts_with("sec-fetch-"))
                    .cloned()
                    .collect();
                for name in unsupported {
                    headers.remove(name);
                }
            }
            let supplied: Vec<_> = headers
                .keys()
                .filter(|name| crate::mirror::is_low_entropy_client_hint(name.as_str()))
                .cloned()
                .collect();
            for name in supplied {
                headers.remove(name);
            }
            for (name, value) in hints {
                if crate::mirror::is_low_entropy_client_hint(name)
                    && let (Ok(name), Ok(value)) = (
                        HeaderName::from_bytes(name.as_bytes()),
                        HeaderValue::from_str(value),
                    )
                {
                    headers.insert(name, value);
                }
            }
        }
        if headers.contains_key("range") {
            // 区间请求不能套用普通 fetch 的压缩列表；保留调用方的显式编码协商。
            // 未指定时请求未压缩表示，避免解压后字节偏移与 Range 的表示不一致。
            headers.entry("accept-encoding").or_insert(HeaderValue::from_static("identity"));
        } else if let Some(value) = template
            .accept_encoding
            .as_deref()
            .and_then(|value| HeaderValue::from_str(value).ok())
        {
            headers.insert("accept-encoding", value);
        }
        let reordered = reorder_headers(headers, &template.fetch_header_order);
        *request.headers_mut() = reordered;
    }
    // DoH 等服务可能把账号密钥放在路径内，诊断只记录方法和连接目标。
    debug!(method = %request.method(), authority, "HTTP request prepared");
    Ok(request)
}

/// 按 WebView fetch 请求的头顺序重排：模板里出现的名字按模板顺序在前，其余保持原序在后。
/// HeaderName 按 HTTP 语义忽略大小写；仅改变顺序，不增加或删除原请求的值。
fn reorder_headers(headers: &HeaderMap, order: &[String]) -> HeaderMap {
    let mut reordered = HeaderMap::with_capacity(headers.len());
    let mut ordered_names = HashSet::new();
    for name in order {
        if let Ok(name) = HeaderName::from_bytes(name.as_bytes()) {
            if !ordered_names.insert(name.clone()) {
                continue;
            }
            for value in headers.get_all(&name) {
                reordered.append(name.clone(), value.clone());
            }
        }
    }
    for (name, value) in headers.iter() {
        if !ordered_names.contains(name) {
            reordered.append(name.clone(), value.clone());
        }
    }
    reordered
}

#[cfg(test)]
mod tests {
    use super::*;

    /// 真实 BoringSSL 拒绝路径：公共名称通过证书校验后才可提取重试配置。
    #[tokio::test]
    async fn authenticated_ech_rejection_updates_keys_or_disables_once() {
        use crate::ech_test_keys::{ECH_CONFIG, ECH_KEY};
        use rama::tls::boring::core::{
            hpke::HpkeKey,
            pkey::PKey,
            ssl::{SslAcceptor, SslEchKeys, SslMethod},
            tokio::accept,
            x509::X509,
        };
        let list = |config: &[u8]| {
            let mut list = (config.len() as u16).to_be_bytes().to_vec();
            list.extend_from_slice(config);
            list
        };
        for server_supports_ech in [true, false] {
            let (chain, key) = rama_crypto::cert::generate_server_auth(
                rama_crypto::cert::GeneratedServerAuthConfig::generated_ca_for(
                    rama::net::address::Domain::from_static("ech.com"),
                ),
            )
            .unwrap();
            let mut acceptor = SslAcceptor::mozilla_intermediate_v5(SslMethod::tls()).unwrap();
            acceptor
                .set_certificate(&X509::from_der(chain[0].as_ref()).unwrap())
                .unwrap();
            acceptor
                .set_private_key(&PKey::private_key_from_der(key.secret_der()).unwrap())
                .unwrap();
            let mut new_config = ECH_CONFIG.to_vec();
            new_config[4] = 2; // 服务端轮换 config_id，旧 DNS 配置仍是 1。
            if server_supports_ech {
                let mut keys = SslEchKeys::builder().unwrap();
                keys.add_key(
                    true,
                    &new_config,
                    HpkeKey::dhkem_x25519_sha256(ECH_KEY).unwrap(),
                )
                .unwrap();
                acceptor.set_ech_keys(&keys.build()).unwrap();
            }
            let acceptor = Arc::new(acceptor.build());
            let config = TlsClientConfig::new()
                .with_server_name(Host::from_static("ech.com"))
                .try_with_server_trust_anchors([chain.last().unwrap().clone()])
                .unwrap();
            let mut data = TlsConnectorData::try_from(&config).unwrap();
            data.config.set_ech_config_list(&list(ECH_CONFIG)).unwrap();
            let (client_io, server_io) = tokio::io::duplex(64 * 1024);
            let server = tokio::spawn({
                let acceptor = acceptor.clone();
                async move {
                    let _ = accept(&acceptor, server_io).await;
                }
            });
            let error = match tls_connect(ServiceInput::new(client_io), Some(data)).await {
                Ok(_) => panic!("旧 ECH 配置应该被拒绝"),
                Err(error) => error,
            };
            let failure = tls_handshake_failure(&error);
            assert!(failure.retryable);
            let retry = failure
                .ech_retry_configs()
                .expect("只有认证拒绝可携带重试信息");
            if server_supports_ech {
                assert_eq!(retry, list(&new_config));
            } else {
                assert!(retry.is_empty());
            }
            server.await.unwrap();

            // 新连接使用服务端确认的配置，保留相同证书校验要求。
            let mut data = TlsConnectorData::try_from(&config).unwrap();
            if !retry.is_empty() {
                data.config.set_ech_config_list(retry).unwrap();
            }
            let (client_io, server_io) = tokio::io::duplex(64 * 1024);
            let server = tokio::spawn(async move { accept(&acceptor, server_io).await.is_ok() });
            let tls = tls_connect(ServiceInput::new(client_io), Some(data))
                .await
                .unwrap();
            assert_eq!(tls.ssl_ref().ech_accepted(), server_supports_ech);
            assert!(server.await.unwrap());
        }
    }

    #[tokio::test]
    async fn untrusted_ech_rejection_never_authorizes_retry_without_ech() {
        use crate::ech_test_keys::ECH_CONFIG;
        use rama::tls::boring::core::{
            pkey::PKey,
            ssl::{SslAcceptor, SslMethod},
            tokio::accept,
            x509::X509,
        };
        let (chain, key) = rama_crypto::cert::generate_server_auth(
            rama_crypto::cert::GeneratedServerAuthConfig::generated_ca_for(
                rama::net::address::Domain::from_static("ech.com"),
            ),
        )
        .unwrap();
        let mut acceptor = SslAcceptor::mozilla_intermediate_v5(SslMethod::tls()).unwrap();
        acceptor
            .set_certificate(&X509::from_der(chain[0].as_ref()).unwrap())
            .unwrap();
        acceptor
            .set_private_key(&PKey::private_key_from_der(key.secret_der()).unwrap())
            .unwrap();
        let acceptor = acceptor.build();
        let mut config = TlsClientConfig::new().with_server_name(Host::from_static("ech.com"));
        config.set_platform_verifier();
        let mut data = TlsConnectorData::try_from(&config).unwrap();
        let mut list = (ECH_CONFIG.len() as u16).to_be_bytes().to_vec();
        list.extend_from_slice(ECH_CONFIG);
        data.config.set_ech_config_list(&list).unwrap();
        let (client_io, server_io) = tokio::io::duplex(64 * 1024);
        let server = tokio::spawn(async move {
            let _ = accept(&acceptor, server_io).await;
        });
        let error = match tls_connect(ServiceInput::new(client_io), Some(data)).await {
            Ok(_) => panic!("未信任的公共名称证书不能通过"),
            Err(error) => error,
        };
        let failure = tls_handshake_failure(&error);
        assert!(!failure.retryable);
        assert!(failure.ech_retry_configs().is_none());
        assert!(matches!(failure.error, NetError::Certificate(_)));
        server.await.unwrap();
    }

    #[test]
    fn standard_tls_applies_ech_before_browser_template_is_available() {
        // 与 browser_tls 测试相同的公开 ECH 测试配置，public_name=ech.com。
        let config: &[u8] = &[
            0xfe, 0x0d, 0x00, 0x3a, 0x01, 0x00, 0x20, 0x00, 0x20, 0x7e, 0xfb, 0x5f, 0xee, 0xa2,
            0xa2, 0x74, 0xb3, 0xff, 0xfe, 0x69, 0x51, 0x9e, 0xfa, 0xe1, 0xfa, 0x49, 0x8c, 0x61,
            0x2c, 0xfa, 0xd0, 0x0f, 0x8c, 0x22, 0x87, 0x0e, 0xbc, 0xb0, 0x2d, 0x76, 0x25, 0x00,
            0x08, 0x00, 0x01, 0x00, 0x01, 0x00, 0x01, 0x00, 0x03, 0x00, 0x07, 0x65, 0x63, 0x68,
            0x2e, 0x63, 0x6f, 0x6d, 0x00, 0x00,
        ];
        let mut list = (config.len() as u16).to_be_bytes().to_vec();
        list.extend_from_slice(config);
        for (ech, expected_sni) in [(None, "linux.do"), (Some(list.as_slice()), "ech.com")] {
            let (data, applied) = tls_config(
                None,
                Host::from_static("linux.do"),
                ech,
                &ClientSessions::default(),
                false,
            )
            .unwrap();
            assert_eq!(applied, ech.is_some());
            let hello = browser_tls::emit_client_hello(data).unwrap();
            let hello = serde_json::to_value(hello).unwrap();
            let sni = hello["extensions"]
                .as_array()
                .unwrap()
                .iter()
                .find_map(|ext| ext.get("ServerName").and_then(|value| value.as_str()));
            assert_eq!(sni, Some(expected_sni));
        }
    }

    #[test]
    fn connection_options_are_not_forwarded() {
        let request = Request::builder()
            .uri("http://localhost/")
            .header("connection", "keep-alive, X-Local")
            .header("connection", "x-another")
            .header("X-Local", "private-hop-value")
            .header("X-Another", "another-hop-value")
            .header("x-end-to-end", "preserved")
            .body(Body::empty())
            .unwrap();
        let mut request = build_request(None, request, "localhost", 80, Version::HTTP_11).unwrap();
        assert!(!request.headers().contains_key("x-local"));
        assert!(!request.headers().contains_key("x-another"));
        assert!(!request.headers().contains_key("connection"));
        assert_eq!(request.headers()["x-end-to-end"], "preserved");
    }

    #[tokio::test]
    async fn accepted_empty_post_is_not_replayed_after_response_loss() {
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let port = listener.local_addr().unwrap().port();
        let seen = Arc::new(AtomicUsize::new(0));
        let count = seen.clone();
        let server = tokio::spawn(async move {
            while let Ok((mut socket, _)) = listener.accept().await {
                let count = count.clone();
                tokio::spawn(async move {
                    loop {
                        let mut head = Vec::new();
                        let mut byte = [0];
                        while !head.ends_with(b"\r\n\r\n") {
                            if socket.read(&mut byte).await.unwrap_or(0) == 0 {
                                return;
                            }
                            head.push(byte[0]);
                        }
                        let received = count.fetch_add(1, Ordering::Relaxed) + 1;
                        // 服务端已执行第二个请求，但响应在返回前丢失。
                        if received == 2 {
                            return;
                        }
                        socket
                            .write_all(b"HTTP/1.1 200 OK\r\ncontent-length: 2\r\n\r\nok")
                            .await
                            .unwrap();
                    }
                });
            }
        });
        let client = plain_client();
        get_ok(&client, port).await;
        let request = Request::builder()
            .method("POST")
            .uri(format!("http://127.0.0.1:{port}/action"))
            .body(Body::empty())
            .unwrap();
        let response = client
            .send(
                request,
                Some(Duration::from_secs(2)),
                Some(Duration::from_secs(2)),
            )
            .await;
        server.abort();
        assert!(response.is_err(), "响应丢失不能把已执行的POST重放成成功");
        assert_eq!(seen.load(Ordering::Relaxed), 2);
    }

    #[test]
    fn range_encoding_is_not_replaced_by_normal_fetch_template() {
        let mut template = crate::presets::by_id("ios-safari18").unwrap();
        template.accept_encoding=Some("gzip, deflate, br".into());
        for version in [Version::HTTP_11,Version::HTTP_2,Version::HTTP_3] {
            for encoding in [None,Some("identity"),Some("gzip")] {
                let mut request=Request::builder().uri("https://example.test/file")
                    .header("range","bytes=0-15").header("if-none-match","\"unchanged\"");
                if let Some(value)=encoding {request=request.header("accept-encoding",value);}
                let built=build_request(Some(&template),request.body(Body::empty()).unwrap(),"example.test",443,version).unwrap();
                assert_eq!(built.headers()["accept-encoding"],encoding.unwrap_or("identity"));
                assert_eq!(built.headers()["range"],"bytes=0-15");
                assert_eq!(built.headers()["if-none-match"],"\"unchanged\"");
            }
        }
    }

    #[test]
    fn sampled_hpack_policy_changes_only_conditional_header_encoding() {
        use rama::http::proto::h2::hpack::{Encoder, Header};
        for index in [false, true] {
            let mut template = crate::presets::by_id("ios-safari18").unwrap();
            template.user_agent = Some("Probe-UA".into());
            template.tls_permute_extensions = Some(false);
            template.low_entropy_client_hints = Some(Vec::new());
            template.hpack_indexing = Some(std::collections::BTreeMap::from([
                ("if-none-match".into(), index), ("x-csrf-token".into(), true),
            ]));
            let make = |scheme: &str, ua: &str, sensitive: bool| {
                let mut request = Request::builder().uri(format!("{scheme}://example.test/topic"))
                    .header("user-agent", ua).header("if-none-match", "\"etag\"")
                    .header("x-csrf-token", "unchanged").body(Body::empty()).unwrap();
                request.headers_mut().get_mut("if-none-match").unwrap().set_sensitive(sensitive);
                build_request(Some(&template), request, "example.test", 443, Version::HTTP_2).unwrap()
            };
            let request = make("https", "Probe-UA", false);
            assert_eq!(request.headers()["if-none-match"], "\"etag\"");
            assert_eq!(request.headers()["if-none-match"].hpack_indexing(), Some(index));
            assert_eq!(request.headers()["x-csrf-token"], "unchanged");
            assert_eq!(request.headers()["x-csrf-token"].hpack_indexing(), None);
            let mut encoder = Encoder::default();
            for repeated in [false, true] {
                let mut bytes = rama::bytes::BytesMut::new();
                encoder.encode([Header::Field { name: Some(HeaderName::from_static("if-none-match")),
                    value: request.headers()["if-none-match"].clone() }], &mut bytes);
                if index { assert_eq!(bytes[0] & 128 != 0, repeated); }
                else { assert_eq!(bytes[0] & 240, 0); }
            }
            for request in [make("http", "Probe-UA", false), make("https", "Other-UA", false), make("https", "Probe-UA", true)] {
                assert_eq!(request.headers()["if-none-match"].hpack_indexing(), None);
            }
        }
    }

    #[test]
    fn reorder_follows_template_then_keeps_rest() {
        let mut headers = HeaderMap::new();
        headers.insert(
            "x-requested-with",
            HeaderValue::from_static("XMLHttpRequest"),
        );
        headers.insert("user-agent", HeaderValue::from_static("ua"));
        headers.insert("discourse-present", HeaderValue::from_static("true"));
        headers.insert("accept", HeaderValue::from_static("application/json"));
        let order = vec![
            "accept".to_owned(),
            "x-requested-with".to_owned(),
            "user-agent".to_owned(),
        ];
        let names: Vec<_> = reorder_headers(&headers, &order)
            .keys()
            .map(|name| name.as_str().to_owned())
            .collect();
        assert_eq!(
            names,
            [
                "accept",
                "x-requested-with",
                "user-agent",
                "discourse-present"
            ]
        );
    }

    #[test]
    fn reorder_matches_custom_header_names_case_insensitively() {
        let mut headers = HeaderMap::new();
        headers.insert(
            HeaderName::from_bytes(b"X-CSRF-Token").unwrap(),
            HeaderValue::from_static("one-masked-token"),
        );
        let order = vec!["x-csrf-token".to_owned()];
        let reordered = reorder_headers(&headers, &order);
        assert_eq!(reordered.get_all("x-csrf-token").iter().count(), 1);
        assert_eq!(reordered["x-csrf-token"], "one-masked-token");
    }

    #[test]
    fn reorder_duplicate_template_names_does_not_multiply_original_values() {
        let mut headers = HeaderMap::new();
        headers.append("x-custom", HeaderValue::from_static("first"));
        headers.append("x-custom", HeaderValue::from_static("second"));
        headers.append("x-unlisted", HeaderValue::from_static("third"));
        headers.append("x-unlisted", HeaderValue::from_static("fourth"));
        let order = vec![
            "x-custom".to_owned(),
            "X-Custom".to_owned(),
            "x-custom".to_owned(),
        ];
        let reordered = reorder_headers(&headers, &order);
        assert_eq!(
            reordered.get_all("x-custom").iter().collect::<Vec<_>>(),
            headers.get_all("x-custom").iter().collect::<Vec<_>>()
        );
        assert_eq!(
            reordered.get_all("x-unlisted").iter().collect::<Vec<_>>(),
            headers.get_all("x-unlisted").iter().collect::<Vec<_>>()
        );
        assert_eq!(reordered.len(), headers.len());
    }

    #[test]
    fn http_and_https_keep_scheme_ports_and_encoded_path() {
        for (url, expected_port) in [
            ("http://localhost/path?q=a%2Fb", 80),
            ("https://localhost/path?q=a%2Fb", 443),
            ("http://localhost:8080/path?q=a%2Fb", 8080),
            ("http://[::1]:8080/path?q=a%2Fb", 8080),
        ] {
            let request = Request::builder().uri(url).body(Body::empty()).unwrap();
            let (host, port) = authority_of(&request).unwrap();
            assert_eq!(port, expected_port);
            let mut request = build_request(None, request, &host, port, Version::HTTP_11).unwrap();
            assert_eq!(request.uri().to_string(), url);
        }
    }

    use std::sync::atomic::AtomicUsize;
    use tokio::io::{AsyncReadExt, AsyncWriteExt};

    /// 明文 HTTP/1.1 测试服务：每条连接逐个应答，`delay` 模拟慢响应，
    /// `close_after` 为真时应答完立即关连接（不带 Connection: close，模拟空闲超时竞态）。
    async fn h1_server(delay: Duration, close_after: bool) -> (u16, Arc<AtomicUsize>) {
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let port = listener.local_addr().unwrap().port();
        let accepted = Arc::new(AtomicUsize::new(0));
        let counter = accepted.clone();
        tokio::spawn(async move {
            while let Ok((mut stream, _)) = listener.accept().await {
                counter.fetch_add(1, Ordering::Relaxed);
                tokio::spawn(async move {
                    let mut buf = Vec::new();
                    let mut chunk = [0u8; 1024];
                    loop {
                        while !buf.windows(4).any(|w| w == b"\r\n\r\n") {
                            match stream.read(&mut chunk).await {
                                Ok(0) | Err(_) => return,
                                Ok(n) => buf.extend_from_slice(&chunk[..n]),
                            }
                        }
                        buf.clear();
                        tokio::time::sleep(delay).await;
                        let _ = stream
                            .write_all(b"HTTP/1.1 200 OK\r\ncontent-length: 2\r\n\r\nok")
                            .await;
                        if close_after {
                            return;
                        }
                    }
                });
            }
        });
        (port, accepted)
    }

    fn plain_client() -> HttpEgressClient {
        let egress = EgressConnector::new(None, None, None, None, Duration::from_secs(5));
        HttpEgressClient::new(Arc::new(egress), None)
    }

    async fn get_ok(client: &HttpEgressClient, port: u16) -> ExchangeInfo {
        let request = Request::builder()
            .uri(format!("http://127.0.0.1:{port}/"))
            .body(Body::empty())
            .unwrap();
        let response = client.send(request, None, None).await.unwrap();
        let info = response
            .extensions()
            .get_ref::<ExchangeInfo>()
            .unwrap()
            .clone();
        let mut stream = response.into_body().into_data_stream();
        let mut body = Vec::new();
        while let Some(chunk) = rama::futures::StreamExt::next(&mut stream).await {
            body.extend_from_slice(&chunk.unwrap());
        }
        assert_eq!(body, b"ok");
        info
    }

    #[tokio::test]
    async fn http1_concurrent_requests_do_not_queue_on_one_connection() {
        let (port, accepted) = h1_server(Duration::from_millis(300), false).await;
        let client = plain_client();
        let started = Instant::now();
        let results =
            futures_join_all((0..4).map(|_| get_ok(&client, port)).collect::<Vec<_>>()).await;
        assert_eq!(results.len(), 4);
        // 串行要 1.2s；各取一条连接应接近单次耗时
        assert!(
            started.elapsed() < Duration::from_millis(900),
            "{:?}",
            started.elapsed()
        );
        assert_eq!(accepted.load(Ordering::Relaxed), 4);
    }

    #[tokio::test]
    async fn http1_sequential_requests_reuse_the_idle_connection() {
        let (port, accepted) = h1_server(Duration::ZERO, false).await;
        let client = plain_client();
        let first = get_ok(&client, port).await;
        let second = get_ok(&client, port).await;
        assert!(!first.reused);
        assert!(second.reused);
        assert_eq!(first.connection_id, second.connection_id);
        assert!(first.connection_id > 0);
        assert_eq!(second.version, Version::HTTP_11);
        assert_eq!(accepted.load(Ordering::Relaxed), 1);
        assert_eq!(client.pooled_connections(), (0, 1));
    }

    #[tokio::test]
    async fn bodyless_request_retries_when_reused_connection_was_closed() {
        let (port, accepted) = h1_server(Duration::ZERO, true).await;
        let client = plain_client();
        get_ok(&client, port).await;
        // 让对端的关闭先到达
        tokio::time::sleep(Duration::from_millis(50)).await;
        let info = get_ok(&client, port).await;
        assert!(!info.reused, "应当换新连接重试");
        assert_eq!(accepted.load(Ordering::Relaxed), 2);
    }

    #[tokio::test]
    async fn reset_drops_idle_connections() {
        let (port, accepted) = h1_server(Duration::ZERO, false).await;
        let client = plain_client();
        get_ok(&client, port).await;
        client.reset_connections().await;
        assert_eq!(client.pooled_connections(), (0, 0));
        let info = get_ok(&client, port).await;
        assert!(!info.reused);
        assert_eq!(accepted.load(Ordering::Relaxed), 2);
    }

    #[tokio::test]
    async fn concurrent_tls_blackhole_shares_failure_and_releases_transport() {
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let port = listener.local_addr().unwrap().port();
        let accepted = Arc::new(AtomicUsize::new(0));
        let closed = Arc::new(AtomicUsize::new(0));
        let server = tokio::spawn({
            let accepted = accepted.clone();
            let closed = closed.clone();
            async move {
                while let Ok((mut socket, _)) = listener.accept().await {
                    accepted.fetch_add(1, Ordering::Relaxed);
                    let closed = closed.clone();
                    tokio::spawn(async move {
                        let mut hello = Vec::new();
                        socket.read_to_end(&mut hello).await.unwrap();
                        assert!(!hello.is_empty(), "应确实发出 ClientHello 后卡住");
                        closed.fetch_add(1, Ordering::Relaxed);
                    });
                }
            }
        });
        let egress = EgressConnector::new(None, None, None, None, Duration::from_millis(200));
        let client = HttpEgressClient::new(Arc::new(egress), None);
        let started = Instant::now();
        let responses = futures_join_all(
            (0..12)
                .map(|_| {
                    let request = Request::builder()
                        .uri(format!("https://127.0.0.1:{port}/image"))
                        .body(Body::empty())
                        .unwrap();
                    client.send(request, None, None)
                })
                .collect(),
        )
        .await;
        assert!(responses.iter().all(Result::is_err));
        assert!(started.elapsed() < Duration::from_secs(1));
        assert_eq!(
            accepted.load(Ordering::Relaxed),
            1,
            "同批失败不能串行重复握手"
        );
        tokio::time::timeout(Duration::from_secs(1), async {
            while closed.load(Ordering::Relaxed) != 1 {
                tokio::time::sleep(Duration::from_millis(5)).await;
            }
        })
        .await
        .unwrap();
        assert_eq!(client.pool.capacity.available_permits(), MAX_CONNECTIONS);
        server.abort();
    }

    #[tokio::test]
    async fn network_reset_does_not_repopulate_pool_from_old_inflight_response() {
        let (port, accepted) = h1_server(Duration::from_millis(150), false).await;
        let client = plain_client();
        let first = get_ok(&client, port);
        let reset = async {
            tokio::time::timeout(Duration::from_secs(1), async {
                while accepted.load(Ordering::Relaxed) == 0 {
                    tokio::time::sleep(Duration::from_millis(5)).await;
                }
            })
            .await
            .unwrap();
            client.reset_connections().await;
        };
        tokio::join!(first, reset);
        assert_eq!(client.pooled_connections(), (0, 0));
        let next = get_ok(&client, port).await;
        assert!(!next.reused);
        assert_eq!(accepted.load(Ordering::Relaxed), 2);
    }

    async fn futures_join_all<F: Future>(futures: Vec<F>) -> Vec<F::Output> {
        let mut outputs = Vec::new();
        let mut set = rama::futures::stream::FuturesUnordered::new();
        for future in futures {
            set.push(future);
        }
        while let Some(output) = rama::futures::StreamExt::next(&mut set).await {
            outputs.push(output);
        }
        outputs
    }

    #[test]
    fn pool_host_budget_evicts_inactive_entries_but_preserves_busy_slots() {
        let pool = PoolState::default();
        let held = pool.slots("busy").try_acquire_owned().unwrap();
        for index in 0..200 {
            let _ = pool.slots(&format!("host-{index}"));
        }
        assert!(pool.hosts.lock().len() <= MAX_POOL_HOSTS);
        assert!(pool.hosts.lock().contains_key("busy"));
        drop(held);
        for host in pool.hosts.lock().values_mut() {
            host.touched = Instant::now() - HTTP1_IDLE_TIMEOUT - Duration::from_secs(1);
        }
        PoolState::prune(&mut pool.hosts.lock(), false);
        assert!(pool.hosts.lock().is_empty());
    }

    #[test]
    fn pool_key_separates_generations_and_ports() {
        assert_eq!(pool_key(None, "linux.do", 443), "linux.do:443#0");
        assert_ne!(
            pool_key(None, "linux.do", 443),
            pool_key(None, "linux.do", 8443)
        );
    }

    #[test]
    fn sampled_client_hints_override_guesses_only_for_matching_ua() {
        let mut template: FingerprintTemplate = serde_json::from_str(include_str!(
            "../tests/fixtures/chromium99_linux_probe.json"
        ))
        .unwrap();
        template.user_agent = Some("Chrome/99.0".into());
        for hints in [
            vec![],
            vec![("sec-ch-ua".into(), "\"Chromium\";v=\"99\"".into())],
        ] {
            template.low_entropy_client_hints = Some(hints.clone());
            for ua in ["Chrome/99.0", "different"] {
                let request = Request::builder()
                    .uri("https://localhost/test")
                    .header("user-agent", ua)
                    .header("sec-ch-ua", "guessed")
                    .header("sec-ch-ua-mobile", "?1")
                    .header("sec-ch-ua-full-version", "requested-by-origin")
                    .body(Body::empty())
                    .unwrap();
                let built =
                    build_request(Some(&template), request, "localhost", 443, Version::HTTP_2)
                        .unwrap();
                assert_eq!(
                    built.headers()["sec-ch-ua-full-version"],
                    "requested-by-origin"
                );
                if ua == "different" {
                    assert_eq!(built.headers()["sec-ch-ua"], "guessed");
                } else {
                    assert!(!built.headers().contains_key("sec-ch-ua-mobile"));
                    assert_eq!(
                        built
                            .headers()
                            .get("sec-ch-ua")
                            .map(|v| v.to_str().unwrap()),
                        hints.first().map(|(_, v)| v.as_str())
                    );
                }
            }
        }
    }

    #[test]
    fn legacy_webkit_fetch_metadata_matches_sample_without_changing_security_headers() {
        // 原生 iOS 15.5 云端采样：不发送 Fetch Metadata；不使用 UA 版本阈值。
        let reference: FingerprintTemplate = serde_json::from_str(include_str!(
            "../tests/fixtures/ios15_5_wkwebview_probe.json"
        ))
        .unwrap();
        for (same_ua, calibrated, supports_metadata, scheme, mode, should_remove) in [
            (true, true, false, "https", "cors", true),
            (false, true, false, "https", "cors", false),
            (true, false, false, "https", "cors", false),
            (true, true, true, "https", "cors", false),
            (true, true, false, "http", "cors", false),
            (true, true, false, "https", "navigate", false),
        ] {
            let mut template = reference.clone();
            if !calibrated {
                template.tls_permute_extensions = None;
            }
            if supports_metadata {
                template.fetch_header_order.push("sec-fetch-mode".into());
            }
            let request = Request::builder()
                .uri(format!("{scheme}://localhost/test"))
                .header(
                    "user-agent",
                    if same_ua {
                        reference.user_agent.as_deref().unwrap()
                    } else {
                        "another-client"
                    },
                )
                .header("sec-fetch-mode", mode)
                .header("sec-fetch-site", "same-origin")
                .header("sec-fetch-dest", "empty")
                .header("origin", "https://localhost")
                .header("referer", "https://localhost/topics/1")
                .header("x-csrf-token", "unchanged-token")
                .header("cookie", "session=unchanged")
                .body(Body::empty())
                .unwrap();
            let built =
                build_request(Some(&template), request, "localhost", 443, Version::HTTP_2).unwrap();
            for name in ["sec-fetch-mode", "sec-fetch-site", "sec-fetch-dest"] {
                assert_eq!(
                    built.headers().contains_key(name),
                    !should_remove,
                    "{same_ua}/{calibrated}/{supports_metadata}/{scheme}/{mode}: {name}"
                );
            }
            assert_eq!(built.headers()["origin"], "https://localhost");
            assert_eq!(built.headers()["referer"], "https://localhost/topics/1");
            assert_eq!(built.headers()["x-csrf-token"], "unchanged-token");
            assert_eq!(built.headers()["cookie"], "session=unchanged");
        }
    }

    #[tokio::test]
    async fn sampled_h2_settings_and_pseudo_order_reach_the_wire() {
        use rama::{
            http::proto::h2::{PseudoHeaderOrder, frame::EarlyFrameCapture},
            http::server::HttpServer,
            service::service_fn,
            tls::{
                boring::server::TlsAcceptorLayer,
                server::{ServerAuthData, TlsServerConfig},
            },
        };
        use std::convert::Infallible;
        let template: FingerprintTemplate = serde_json::from_str(include_str!(
            "../tests/fixtures/chromium99_linux_probe.json"
        ))
        .unwrap();
        let templates = Arc::new(FingerprintTemplates::new(None));
        templates.record_hello(&template.hello);
        templates.record_hello(&template.hello);
        // 原生 Android 样本会依赖旧连接中仍存在的流 5；生产回放保留属性并重挂根。
        let priority = rama::http::proto::h2::frame::StreamDependency::new(
            rama::http::proto::h2::frame::StreamId::from(5), 219, true);
        let sample = Request::builder().version(Version::HTTP_2)
            .header("user-agent", "priority-lab").body(()).unwrap();
        sample.extensions().insert(template.early_frames.clone());
        sample.extensions().insert(template.pseudo_order.clone());
        sample.extensions().insert(rama::http::proto::h2::frame::ReceivedStreamDependency(priority.clone()));
        templates.observe_probe_fetch(&sample);
        let (chain, key) = rama_crypto::cert::generate_server_auth(
            rama_crypto::cert::GeneratedServerAuthConfig::generated_ca_for(
                rama::net::address::Domain::from_static("localhost"),
            ),
        )
        .unwrap();
        let mut trust = TlsClientConfig::new()
            .with_server_name(Host::from_static("localhost"))
            .try_with_server_trust_anchors([chain.last().unwrap().clone()])
            .unwrap();
        trust.set_alpn([ApplicationProtocol::HTTP_2].into_iter().collect());
        let tls = TlsServerConfig::new()
            .with_server_auth(ServerAuthData::new(chain, key))
            .with_alpn_http_auto();
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let port = listener.local_addr().unwrap().port();
        let captured = Arc::new(parking_lot::Mutex::new(None));
        let sink = captured.clone();
        let server = tokio::spawn(async move {
            let (socket, _) = listener.accept().await.unwrap();
            let mut http = HttpServer::auto(Executor::new());
            http.h2_mut().set_observe_early_frames(true);
            let http = http.service(service_fn(move |request: Request| {
                *sink.lock() = Some((
                    request
                        .extensions()
                        .get_ref::<EarlyFrameCapture>()
                        .unwrap()
                        .clone(),
                    request
                        .extensions()
                        .get_ref::<PseudoHeaderOrder>()
                        .unwrap()
                        .clone(),
                    request.extensions().get_ref::<rama::http::proto::h2::frame::ReceivedStreamDependency>().map(|p| p.0.clone()),
                ));
                async { Ok::<_, Infallible>(Response::new(Body::from("ok"))) }
            }));
            let _ = TlsAcceptorLayer::new(tls)
                .into_layer(http)
                .serve(ServiceInput::new(socket))
                .await;
        });
        let client = HttpEgressClient::new(
            Arc::new(EgressConnector::new(
                None,
                None,
                None,
                None,
                Duration::from_secs(3),
            )),
            Some(templates),
        );
        *client.test_tls.lock() = Some(trust);
        let response = client
            .send(
                Request::builder()
                    .uri(format!("https://localhost:{port}/"))
                    .header("user-agent", "priority-lab")
                    .header("sec-fetch-mode", "cors")
                    .body(Body::empty())
                    .unwrap(),
                Some(Duration::from_secs(5)),
                Some(Duration::from_secs(5)),
            )
            .await
            .unwrap();
        assert_eq!(response.version(), Version::HTTP_2);
        let (frames, order, actual_priority) = captured.lock().clone().unwrap();
        assert_eq!(actual_priority, Some(rama::http::proto::h2::frame::StreamDependency::new(
            rama::http::proto::h2::frame::StreamId::zero(), priority.weight, priority.is_exclusive)));
        let initial = |frames: &EarlyFrameCapture| {
            serde_json::to_value(frames)
                .unwrap()
                .as_array()
                .unwrap()
                .iter()
                .filter(|f| f.get("Settings").is_none_or(|s| s["flags"] != 1))
                .cloned()
                .collect::<Vec<_>>()
        };
        assert_eq!(initial(&frames), initial(&template.early_frames));
        assert_eq!(
            serde_json::to_value(order).unwrap(),
            serde_json::to_value(template.pseudo_order).unwrap()
        );
        // 镜像只能跨连接保留根依赖，不能把入站流 3 复制成当前流 3 的自依赖。
        for (dependency_id, expected) in [(0u32, Some(31u8)), (3, None)] {
            let request = Request::builder().uri(format!("https://localhost:{port}/"))
                .header("user-agent", "priority-lab").header("sec-fetch-mode", "cors")
                .body(Body::empty()).unwrap();
            request.extensions().insert(rama::http::proto::h2::frame::ReceivedStreamDependency(
                rama::http::proto::h2::frame::StreamDependency::new(
                    rama::http::proto::h2::frame::StreamId::from(dependency_id), 31, false)));
            let response = client.send(request, Some(Duration::from_secs(5)), Some(Duration::from_secs(5))).await.unwrap();
            assert_eq!(response.status().as_u16(), 200);
            assert_eq!(captured.lock().as_ref().unwrap().2.as_ref().map(|p| p.weight), expected);
        }
        client.reset_connections().await;
        server.abort();
    }

    #[tokio::test]
    async fn concurrent_fetches_chain_priority_in_creation_order() {
        use rama::{
            http::proto::h2::frame::{ReceivedStreamDependency, StreamDependency, StreamId},
            http::server::HttpServer,
            service::service_fn,
            tls::{
                boring::server::TlsAcceptorLayer,
                server::{ServerAuthData, TlsServerConfig},
            },
        };
        use std::convert::Infallible;
        let template: FingerprintTemplate = serde_json::from_str(include_str!(
            "../tests/fixtures/chromium99_linux_probe.json"
        ))
        .unwrap();
        let templates = Arc::new(FingerprintTemplates::new(None));
        templates.record_hello(&template.hello);
        templates.record_hello(&template.hello);
        let sample = Request::builder().version(Version::HTTP_2)
            .header("user-agent", "priority-lab").body(()).unwrap();
        sample.extensions().insert(template.early_frames.clone());
        sample.extensions().insert(template.pseudo_order.clone());
        sample.extensions().insert(ReceivedStreamDependency(
            StreamDependency::new(StreamId::from(5), 219, true)));
        templates.observe_probe_fetch(&sample);
        let (chain, key) = rama_crypto::cert::generate_server_auth(
            rama_crypto::cert::GeneratedServerAuthConfig::generated_ca_for(
                rama::net::address::Domain::from_static("localhost"),
            ),
        )
        .unwrap();
        let mut trust = TlsClientConfig::new()
            .with_server_name(Host::from_static("localhost"))
            .try_with_server_trust_anchors([chain.last().unwrap().clone()])
            .unwrap();
        trust.set_alpn([ApplicationProtocol::HTTP_2].into_iter().collect());
        let tls = TlsServerConfig::new()
            .with_server_auth(ServerAuthData::new(chain, key))
            .with_alpn_http_auto();
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let port = listener.local_addr().unwrap().port();
        let seen = Arc::new(parking_lot::Mutex::new(Vec::new()));
        let release = Arc::new(tokio::sync::Notify::new());
        let (sink, gate) = (seen.clone(), release.clone());
        let server = tokio::spawn(async move {
            let (socket, _) = listener.accept().await.unwrap();
            let http = HttpServer::auto(Executor::new()).service(service_fn(move |request: Request| {
                let path = request
                    .uri()
                    .path()
                    .map(|path| path.as_encoded_str().into_owned())
                    .unwrap_or_default();
                let slow = path == "/slow";
                sink.lock().push((
                    path,
                    request.extensions().get_ref::<ReceivedStreamDependency>().map(|p| p.0.clone()),
                ));
                let gate = gate.clone();
                async move {
                    if slow {
                        gate.notified().await;
                    }
                    Ok::<_, Infallible>(Response::new(Body::from("ok")))
                }
            }));
            let _ = TlsAcceptorLayer::new(tls)
                .into_layer(http)
                .serve(ServiceInput::new(socket))
                .await;
        });
        let client = Arc::new(HttpEgressClient::new(
            Arc::new(EgressConnector::new(None, None, None, None, Duration::from_secs(3))),
            Some(templates),
        ));
        *client.test_tls.lock() = Some(trust);
        let get = |path: &'static str| {
            let client = client.clone();
            async move {
                let response = client
                    .send(
                        Request::builder()
                            .uri(format!("https://localhost:{port}{path}"))
                            .header("user-agent", "priority-lab")
                            .header("sec-fetch-mode", "cors")
                            .body(Body::empty())
                            .unwrap(),
                        Some(Duration::from_secs(5)),
                        Some(Duration::from_secs(5)),
                    )
                    .await
                    .unwrap();
                rama::http::body::util::BodyExt::collect(response.into_body()).await.unwrap();
            }
        };
        let slow = tokio::spawn(get("/slow"));
        tokio::time::timeout(Duration::from_secs(5), async {
            while seen.lock().is_empty() {
                tokio::time::sleep(Duration::from_millis(5)).await;
            }
        })
        .await
        .unwrap();
        get("/fast").await;
        release.notify_one();
        slow.await.unwrap();
        get("/after").await;
        let seen = seen.lock().clone();
        let dependency = |path: &str| {
            seen.iter().find(|(p, _)| p == path).and_then(|(_, d)| d.clone()).unwrap()
        };
        // 在途的 /slow 是流 1：后发的 /fast 排他挂在它身下，而不是把它压到自己身下
        assert_eq!(dependency("/slow"), StreamDependency::new(StreamId::zero(), 219, true));
        assert_eq!(dependency("/fast"), StreamDependency::new(StreamId::from(1), 219, true));
        // 前面的流都已结束，链从根重新开始
        assert_eq!(dependency("/after"), StreamDependency::new(StreamId::zero(), 219, true));
        client.reset_connections().await;
        server.abort();
    }
}
