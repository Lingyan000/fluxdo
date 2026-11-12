//! 出站：选址与握手的统一入口。
//!
//! 镜像（WebView）与客户端（dio）共用这里，保证两者出口一致。一次出站包含：
//!
//! 1. 选址：应用内上游代理 > 系统代理（按目标求值，含 PAC）> IP 字面量 >
//!    用户指定 IP > 粘性 IP 与 DNS 解析结果（按 RTT 排序、双协议族交错）；
//! 2. 建连：候选地址按 Happy Eyeballs 并发竞速（TCP 层），先连上的先交付；
//! 3. 握手：由调用方传入（镜像要把入站一起握手，客户端只握上游），**串行**执行——
//!    镜像的入站句柄同一时刻只能交给一次握手，不能并发；
//! 4. 失败重试：可恢复的传输失败换下一个地址；只有经过 TLS 认证的 ECH 拒绝
//!    才允许按服务端返回的配置重连一次，普通网络错误不改变 ECH 策略。
//!
//! 证书校验走平台校验器（企业 / 用户安装的 CA、系统吊销策略都算数），
//! 没有平台校验器的 Linux 由 rama 自动退回系统信任库。

use std::{
    fmt,
    future::Future,
    net::{IpAddr, SocketAddr},
    pin::Pin,
    sync::{
        Arc,
        atomic::{AtomicBool, Ordering as AtomicOrdering},
    },
    time::{Duration, Instant},
};

use tokio::net::TcpStream;
use tokio::sync::{mpsc, watch};
use tracing::{info, warn};

use crate::dns::DnsResolver;
use crate::error::{NetError, Result};
use crate::system_proxy::{self, ProxyChoice};
use crate::upstream::connect_tunnel;
use crate::{BoxStream, UpstreamProxyConfig};

/// 单个地址的 TCP 连接超时。
const TCP_TIMEOUT: Duration = Duration::from_secs(5);
/// 单次 TLS 握手的超时，由调用方的握手实现负责遵守。
pub const EGRESS_TLS_TIMEOUT: Duration = Duration::from_secs(10);
/// 一次出站（含解析、全部候选与备用握手）的总时限，到期取消在途工作。
const EGRESS_BUDGET: Duration = Duration::from_secs(25);
/// Happy Eyeballs：候选地址之间错开发起的间隔。
const ATTEMPT_STAGGER: Duration = Duration::from_millis(250);
/// 客户端 TLS 握手卡住多久后起备用握手，见 [`EgressConnector::connect_client`]。
const CLIENT_TLS_BACKUP_DELAY: Duration = Duration::from_millis(1500);
/// 一个候选上游。代理项自带要用的配置：出口可能来自应用内代理，也可能来自
/// 按目标求值的系统代理（含 PAC），两者在这里统一。
#[derive(Debug, Clone)]
pub enum EgressTarget {
    /// 经代理隧道，由代理负责解析目标域名
    Proxy(Arc<UpstreamProxyConfig>),
    /// 插件经可信代理出站时仍固定目标 IP，不让代理重新解析域名。
    PinnedProxy(Arc<UpstreamProxyConfig>, IpAddr),
    /// 直连已解析的地址；`sticky` 表示来自最近一次成功记录
    Addr { addr: SocketAddr, sticky: bool },
}

impl fmt::Display for EgressTarget {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Proxy(proxy) => write!(f, "proxy {}:{}", proxy.host, proxy.port),
            Self::PinnedProxy(proxy, ip) => {
                write!(f, "proxy {}:{} -> {ip}", proxy.host, proxy.port)
            }
            Self::Addr { addr, .. } => write!(f, "{addr}"),
        }
    }
}

/// 一次握手的失败。`retryable` 为真表示失败发生在出站一侧，可以换地址重试；
/// 为假时立即放弃（例如镜像的入站已经开始握手，换地址会把客户端的连接搞坏）。
#[derive(Debug)]
pub struct HandshakeFailure {
    pub error: NetError,
    pub retryable: bool,
    /// 仅由 TLS 后端认证过的 ECH_REJECTED 填入；空配置表示服务端指示禁用 ECH。
    ech_retry_configs: Option<Vec<u8>>,
}

impl HandshakeFailure {
    pub fn retry(error: NetError) -> Self {
        // 证书错误不能通过换地址或关闭 ECH 变成“可恢复”的握手失败。
        let retryable = !matches!(error, NetError::Certificate(_) | NetError::Cancelled);
        Self {
            error,
            retryable,
            ech_retry_configs: None,
        }
    }

    pub fn abort(error: NetError) -> Self {
        Self {
            error,
            retryable: false,
            ech_retry_configs: None,
        }
    }

    pub(crate) fn authenticated_ech_retry(configs: Vec<u8>) -> Self {
        Self {
            error: NetError::Proxy("Authenticated ECH rejection".into()),
            retryable: true,
            ech_retry_configs: Some(configs),
        }
    }

    #[cfg(test)]
    pub(crate) fn ech_retry_configs(&self) -> Option<&[u8]> {
        self.ech_retry_configs.as_deref()
    }
}

/// 出站连接器：所有出站共用一份，持有 DNS 解析器与代理配置。
pub struct EgressConnector {
    pinned: Option<Vec<IpAddr>>,
    proxy_resolves_host: bool,
    dns: Option<Arc<DnsResolver>>,
    /// 应用内代理设置（用户在设置页配置的）
    upstream_proxy: Option<UpstreamProxyConfig>,
    /// 宿主下发的系统代理（安卓 / Windows），苹果与 Linux 由 [`system_proxy`] 自行求值
    system_proxy: Option<UpstreamProxyConfig>,
    /// 用户指定的服务端 IP，跳过 DNS 解析
    server_ip: Option<IpAddr>,
    timeout: Duration,
}

impl EgressConnector {
    pub fn new(
        dns: Option<Arc<DnsResolver>>,
        upstream_proxy: Option<UpstreamProxyConfig>,
        system_proxy: Option<UpstreamProxyConfig>,
        server_ip: Option<&str>,
        timeout: Duration,
    ) -> Self {
        let server_ip = server_ip
            .map(str::trim)
            .filter(|value| !value.is_empty())
            .and_then(|value| {
                value.parse::<IpAddr>().ok().or_else(|| {
                    warn!("Invalid server_ip '{value}', ignoring");
                    None
                })
            });
        Self {
            pinned: None,
            proxy_resolves_host: false,
            dns,
            upstream_proxy: upstream_proxy.filter(UpstreamProxyConfig::is_valid),
            system_proxy: system_proxy.filter(UpstreamProxyConfig::is_valid),
            server_ip,
            timeout,
        }
    }

    /// 固定 TCP 代理无需发起 QUIC 探测；PAC 仍保留逐目标出口检查。
    pub fn has_fixed_proxy(&self) -> bool {
        self.upstream_proxy.is_some() || self.system_proxy.is_some()
    }

    pub fn with_pins(mut self, ips: Vec<IpAddr>) -> Self {
        self.pinned = Some(ips);
        self
    }

    /// 宿主显式选择由用户配置的代理解析域名，直连仍限于 pins。
    pub fn with_proxy_resolution(mut self, enabled: bool) -> Self {
        self.proxy_resolves_host = enabled;
        self
    }

    pub fn is_pinned(&self) -> bool {
        self.pinned.is_some()
    }

    pub fn dns(&self) -> Option<&Arc<DnsResolver>> {
        self.dns.as_ref()
    }

    /// 站点的 ECHConfigList（HTTPS 记录）；未启用 DoH 或无配置时为 None。
    pub async fn ech_config_list(&self, host: &str) -> Option<Vec<u8>> {
        let resolver = self.dns.as_ref()?;
        match resolver.lookup_ech_config(host).await {
            Ok(config) => config,
            Err(e) => {
                warn!("ECH lookup failed for {host}, proceeding without ECH: {e}");
                None
            }
        }
    }

    /// 建立到 `host:port` 的裸 TCP 出站（不做 TLS）。CF 验证域的隧道直连走这里：
    /// 选址与代理跟随规则同普通出站，但两端 TLS 保持端到端，中间不插手。
    pub async fn connect_raw(&self, host: &str, port: u16) -> Result<BoxStream> {
        self.connect_with_handshake(host, port, |stream, _| async move { Ok(stream) })
            .await
    }

    /// 建立到 `host:port` 的出站连接，握手由 `handshake` 完成。
    ///
    /// 返回显式 `Send` 的装箱 future：调用方（镜像、客户端）的 future 叠在 rama 服务里，
    /// 由自动 trait 推断时编译器无法证明它们对所有生命周期 Send。
    pub fn connect_with_handshake<'a, T, F, Fut>(
        &'a self,
        host: &'a str,
        port: u16,
        handshake: F,
    ) -> Pin<Box<dyn Future<Output = Result<T>> + Send + 'a>>
    where
        T: Send + 'a,
        F: FnMut(BoxStream, Option<Vec<u8>>) -> Fut + Send + 'a,
        Fut: Future<Output = std::result::Result<T, HandshakeFailure>> + Send + 'a,
    {
        Box::pin(self.with_budget(host, port, self.connect_inner(host, port, handshake)))
    }

    /// 客户端出站：在 [`Self::connect_with_handshake`] 的基础上，TLS 握手卡住
    /// [`CLIENT_TLS_BACKUP_DELAY`] 后再起一路备用握手，先成功的胜出。
    ///
    /// 建连慢由 TCP 层的 Happy Eyeballs 兜（250ms 错开），这里只兜「TCP 通了、握手丢包
    /// 卡住」的情形。备用要等主路径进入握手阶段后才计时，且远长于 TCP 错开间隔：
    /// 高 RTT 网络下一次 TCP+TLS 本就要几百毫秒，提前起备用会让每个冷连接都握两次。
    /// 镜像不能用这个入口：它的入站句柄同一时刻只能交给一次握手。
    pub fn connect_client<'a, T, F, Fut>(
        &'a self,
        host: &'a str,
        port: u16,
        handshake: F,
    ) -> Pin<Box<dyn Future<Output = Result<T>> + Send + 'a>>
    where
        T: Send + 'a,
        F: FnMut(BoxStream, Option<Vec<u8>>) -> Fut + Clone + Send + 'a,
        Fut: Future<Output = std::result::Result<T, HandshakeFailure>> + Send + 'a,
    {
        Box::pin(self.with_budget(host, port, async move {
            let (targets, ech, connected, first) = self.prepare_egress(host, port).await?;
            // 备用从下一个候选开始；单候选时重连同一地址（握手丢包多半只是这条连接倒霉）
            let mut backup_targets = targets.clone();
            if backup_targets.len() > 1 {
                backup_targets.rotate_left(1);
            }

            let (handshaking_tx, mut handshaking) = watch::channel(false);
            let primary = {
                let mut handshake = handshake.clone();
                self.connect_ready(
                    host,
                    port,
                    connected,
                    first,
                    ech.clone(),
                    move |stream, ech| {
                        handshaking_tx.send_replace(true);
                        handshake(stream, ech)
                    },
                )
            };
            let backup_started = AtomicBool::new(false);
            let backup = async {
                // 主路径连 TCP 都没连上时不起备用，交给它自己的地址竞速与超时
                if handshaking.wait_for(|started| *started).await.is_err() {
                    std::future::pending::<()>().await;
                }
                tokio::time::sleep(CLIENT_TLS_BACKUP_DELAY).await;
                backup_started.store(true, AtomicOrdering::Relaxed);
                info!(
                    "TLS to {host}:{port} still pending after {CLIENT_TLS_BACKUP_DELAY:?}, starting backup handshake"
                );
                self.connect_targets(host, port, backup_targets, ech, handshake)
                    .await
            };
            tokio::pin!(primary, backup);

            tokio::select! {
                result = &mut primary => match result {
                    Ok(value) => Ok(value),
                    Err(error @ (NetError::Certificate(_) | NetError::Cancelled)) => Err(error),
                    // 备用已经在握手：主路径失败不代表备用也会失败，等它的结果
                    Err(error) if backup_started.load(AtomicOrdering::Relaxed) => {
                        backup.await.map_err(|_| error)
                    }
                    Err(error) => Err(error),
                },
                result = &mut backup => match result {
                    Ok(value) => {
                        info!("Backup handshake to {host}:{port} won");
                        Ok(value)
                    }
                    Err(error @ (NetError::Certificate(_) | NetError::Cancelled)) => Err(error),
                    Err(_) => primary.await,
                },
            }
        }))
    }

    /// 在最外层约束整次出站，备用连接和换地址不能重新获得完整预算。
    /// future 被取消时，其持有的 socket、ConnectRace 与握手任务一起释放。
    async fn with_budget<T>(
        &self,
        host: &str,
        port: u16,
        work: impl Future<Output = Result<T>>,
    ) -> Result<T> {
        let budget = self.timeout.min(EGRESS_BUDGET);
        tokio::time::timeout(budget, work).await.map_err(|_| {
            warn!("Egress to {host}:{port} exceeded total budget {budget:?}");
            NetError::Timeout
        })?
    }

    async fn connect_inner<T, F, Fut>(&self, host: &str, port: u16, handshake: F) -> Result<T>
    where
        F: FnMut(BoxStream, Option<Vec<u8>>) -> Fut,
        Fut: Future<Output = std::result::Result<T, HandshakeFailure>>,
    {
        let (_, ech, connected, first) = self.prepare_egress(host, port).await?;
        self.connect_ready(host, port, connected, first, ech, handshake)
            .await
    }

    /// 地址就绪即可建 TCP；ECH 查询与 TCP 重叠，TLS 仍等待 ECH 完成。
    /// race 与已连接 socket 由本 future 持有，取消会同时关闭它们。
    async fn prepare_egress(
        &self,
        host: &str,
        port: u16,
    ) -> Result<(
        Vec<EgressTarget>,
        Option<Vec<u8>>,
        ConnectRace,
        Option<(EgressTarget, Result<BoxStream>)>,
    )> {
        self.prepare_egress_with_ech(host, port, self.ech_config_list(host))
            .await
    }
    async fn prepare_egress_with_ech<F: Future<Output = Option<Vec<u8>>>>(
        &self,
        host: &str,
        port: u16,
        lookup: F,
    ) -> Result<(
        Vec<EgressTarget>,
        Option<Vec<u8>>,
        ConnectRace,
        Option<(EgressTarget, Result<BoxStream>)>,
    )> {
        let started = Instant::now();
        let transport = async {
            let targets = self.egress_targets(host, port).await?;
            let address_ms = started.elapsed().as_millis();
            let mut connected = self.race_connect(host, port, targets.clone());
            let first = connected.next().await;
            info!(
                "Egress TCP for {host}:{port}: address_ms={address_ms}, ready_ms={}",
                started.elapsed().as_millis()
            );
            Ok::<_, NetError>((targets, connected, first))
        };
        let ech = async {
            let ech = lookup.await;
            info!(
                "Egress ECH for {host}:{port}: ready_ms={}, available={}",
                started.elapsed().as_millis(),
                ech.is_some()
            );
            ech
        };
        let (transport, ech) = tokio::join!(transport, ech);
        let (targets, connected, first) = transport?;
        Ok((targets, ech, connected, first))
    }

    pub(crate) async fn resolve_egress(
        &self,
        host: &str,
        port: u16,
    ) -> Result<(Vec<EgressTarget>, Option<Vec<u8>>)> {
        let started = Instant::now();
        let (targets, ech) =
            tokio::join!(self.egress_targets(host, port), self.ech_config_list(host));
        let targets = targets?;
        info!(
            "Egress resolution for {host}:{port} completed in {}ms (candidates: {}, ECH: {})",
            started.elapsed().as_millis(),
            targets.len(),
            ech.is_some()
        );
        Ok((targets, ech))
    }

    /// 按候选地址依次握手，见 [`Self::connect_with_handshake`]。
    async fn connect_targets<T, F, Fut>(
        &self,
        host: &str,
        port: u16,
        targets: Vec<EgressTarget>,
        ech: Option<Vec<u8>>,
        handshake: F,
    ) -> Result<T>
    where
        F: FnMut(BoxStream, Option<Vec<u8>>) -> Fut,
        Fut: Future<Output = std::result::Result<T, HandshakeFailure>>,
    {
        self.connect_ready(
            host,
            port,
            self.race_connect(host, port, targets),
            None,
            ech,
            handshake,
        )
        .await
    }

    async fn connect_ready<T, F, Fut>(
        &self,
        host: &str,
        port: u16,
        mut connected: ConnectRace,
        mut first: Option<(EgressTarget, Result<BoxStream>)>,
        ech: Option<Vec<u8>>,
        mut handshake: F,
    ) -> Result<T>
    where
        F: FnMut(BoxStream, Option<Vec<u8>>) -> Fut,
        Fut: Future<Output = std::result::Result<T, HandshakeFailure>>,
    {
        let started = Instant::now();
        let mut ech = ech;
        let mut ech_retried = false;
        let mut last_error = None;
        // TCP 并发竞速、TLS 串行：镜像的入站句柄同一时刻只能交给一次握手
        while let Some((target, stream)) = match first.take() {
            Some(first) => Some(first),
            None => connected.next().await,
        } {
            let target = &target;
            match stream {
                Ok(stream) => {
                    let mut stream = Some(stream);
                    let mut attempt_ech = ech.clone();
                    // 整次建连只接受一次经过认证的 ECH 配置更新。
                    while let Some(ready) = stream.take() {
                        let attempt_started = Instant::now();
                        let used_ech = attempt_ech.is_some();
                        match handshake(ready, attempt_ech.clone()).await {
                            Ok(value) => {
                                info!(
                                    "Egress {host}:{port} via {target} ready in {}ms (handshake {}ms, ECH requested: {used_ech})",
                                    started.elapsed().as_millis(),
                                    attempt_started.elapsed().as_millis()
                                );
                                self.record_success(host, target, attempt_started.elapsed());
                                return Ok(value);
                            }
                            Err(failure) if !failure.retryable => return Err(failure.error),
                            Err(failure) => {
                                warn!(
                                    "Egress TLS to {host}:{port} via {target} failed (ECH requested: {used_ech}): {}",
                                    failure.error
                                );
                                last_error = Some(failure.error);
                                if used_ech
                                    && !ech_retried
                                    && let Some(configs) = failure.ech_retry_configs
                                {
                                    ech_retried = true;
                                    ech = (!configs.is_empty()).then_some(configs);
                                    attempt_ech = ech.clone();
                                    info!(
                                        "Authenticated ECH retry for {host}:{port} (ECH requested: {})",
                                        attempt_ech.is_some()
                                    );
                                    match open_target(target, host, port, self.timeout).await {
                                        Ok(retry) => stream = Some(retry),
                                        Err(e) => last_error = Some(e),
                                    }
                                }
                            }
                        }
                    }
                    self.record_failure(host, target);
                }
                Err(e) => {
                    warn!("Egress TCP to {host}:{port} via {target} failed: {e}");
                    last_error = Some(e);
                    self.record_failure(host, target);
                }
            }
        }

        Err(last_error
            .unwrap_or_else(|| NetError::Dns(format!("No reachable upstream for {host}:{port}"))))
    }

    /// Happy Eyeballs：候选地址按 [`ATTEMPT_STAGGER`] 错开并发建连，按连上的先后交付。
    /// 单个候选（代理、IP 字面量）时退化为直接连接，不额外开任务。
    fn race_connect(&self, host: &str, port: u16, targets: Vec<EgressTarget>) -> ConnectRace {
        if targets.len() <= 1 {
            return ConnectRace::Single {
                host: host.to_owned(),
                port,
                timeout: self.timeout,
                target: targets.into_iter().next(),
            };
        }
        let (tx, rx) = mpsc::channel(targets.len());
        let mut tasks = Vec::with_capacity(targets.len());
        for (index, target) in targets.into_iter().enumerate() {
            let tx = tx.clone();
            let host = host.to_owned();
            let timeout = self.timeout;
            tasks.push(tokio::spawn(async move {
                if index > 0 {
                    tokio::time::sleep(ATTEMPT_STAGGER * index as u32).await;
                }
                let result = open_target(&target, &host, port, timeout).await;
                let _ = tx.send((target, result)).await;
            }));
        }
        ConnectRace::Racing {
            rx,
            tasks: Some(tasks),
        }
    }

    /// 候选上游，按优先级排列。
    async fn egress_targets(&self, host: &str, port: u16) -> Result<Vec<EgressTarget>> {
        if let Some(ips) = &self.pinned {
            let proxy = self
                .upstream_proxy
                .clone()
                .or_else(
                    || match system_proxy::choose(self.system_proxy.as_ref(), host, port) {
                        ProxyChoice::Proxy(proxy) => Some(proxy),
                        _ => None,
                    },
                )
                .map(Arc::new);
            if self.proxy_resolves_host
                && let Some(proxy) = &proxy
            {
                return Ok(vec![EgressTarget::Proxy(proxy.clone())]);
            }
            if ips.is_empty() {
                return Err(NetError::Dns(format!(
                    "No approved direct address for {host}"
                )));
            }
            let ordered =
                interleave_families(ips.clone(), ips.first().is_some_and(IpAddr::is_ipv6));
            return Ok(ordered
                .into_iter()
                .map(|ip| match &proxy {
                    Some(proxy) => EgressTarget::PinnedProxy(proxy.clone(), ip),
                    None => EgressTarget::Addr {
                        addr: SocketAddr::new(ip, port),
                        sticky: false,
                    },
                })
                .collect());
        }
        // 应用内代理优先：用户显式配置的出口
        if let Some(proxy) = self.upstream_proxy.clone() {
            return Ok(vec![EgressTarget::Proxy(Arc::new(proxy))]);
        }
        // 系统代理：WebView 跟随它，dio 也必须跟随，否则两者出口 IP 不同
        if let ProxyChoice::Proxy(proxy) =
            system_proxy::choose(self.system_proxy.as_ref(), host, port)
        {
            return Ok(vec![EgressTarget::Proxy(Arc::new(proxy))]);
        }

        let addr = |ip: IpAddr, sticky: bool| EgressTarget::Addr {
            addr: SocketAddr::new(ip, port),
            sticky,
        };
        if let Ok(ip) = host.parse::<IpAddr>() {
            return Ok(vec![addr(ip, false)]);
        }
        if let Some(ip) = self.server_ip {
            return Ok(vec![addr(ip, false)]);
        }

        let Some(resolver) = self.dns.as_ref() else {
            let ips = self.system_dns(host, port).await?;
            return Ok(interleave_families(ips, false)
                .into_iter()
                .map(|ip| addr(ip, false))
                .collect());
        };

        let ips = match resolver.lookup_ip(host).await {
            Ok(ips) if !ips.is_empty() => ips,
            Ok(_) => {
                warn!("DoH returned no IP for {host}, falling back to system DNS");
                self.system_dns(host, port).await?
            }
            Err(e) => {
                warn!("DoH lookup failed for {host} ({e}), falling back to system DNS");
                self.system_dns(host, port).await?
            }
        };

        // 粘性 IP 排头，其余按 RTT 排序后双协议族交错（RFC 8305）
        Ok(dns_targets(resolver, host, port, ips))
    }

    async fn system_dns(&self, host: &str, port: u16) -> Result<Vec<IpAddr>> {
        let addrs = tokio::time::timeout(self.timeout, tokio::net::lookup_host((host, port)))
            .await
            .map_err(|_| NetError::Timeout)?
            .map_err(NetError::Io)?;
        let addrs: Vec<_> = addrs.map(|addr| addr.ip()).collect();
        if addrs.is_empty() {
            return Err(NetError::Dns(format!("No IP found for {host}")));
        }
        Ok(addrs)
    }

    fn record_success(&self, host: &str, target: &EgressTarget, rtt: Duration) {
        if let (Some(resolver), EgressTarget::Addr { addr, .. }) = (self.dns.as_ref(), target) {
            resolver.record_host_success(host, addr.ip());
            resolver.record_ip_rtt(addr.ip(), rtt);
        }
    }

    fn record_failure(&self, host: &str, target: &EgressTarget) {
        if let (Some(resolver), EgressTarget::Addr { sticky: true, .. }) =
            (self.dns.as_ref(), target)
        {
            resolver.clear_preferred_host_ip(host);
        }
    }
}

async fn open_target(
    target: &EgressTarget,
    host: &str,
    port: u16,
    timeout: Duration,
) -> Result<BoxStream> {
    match target {
        EgressTarget::Proxy(proxy) => {
            tokio::time::timeout(timeout, connect_tunnel(proxy, host, port))
                .await
                .map_err(|_| NetError::Timeout)?
        }
        EgressTarget::PinnedProxy(proxy, ip) => {
            tokio::time::timeout(timeout, connect_tunnel(proxy, &ip.to_string(), port))
                .await
                .map_err(|_| NetError::Timeout)?
        }
        EgressTarget::Addr { addr, .. } => {
            let stream = tokio::time::timeout(TCP_TIMEOUT, TcpStream::connect(*addr))
                .await
                .map_err(|_| NetError::Timeout)?
                .map_err(NetError::Io)?;
            Ok(Box::new(stream))
        }
    }
}

/// 双协议族交错（RFC 8305）：首选族一个、另一族一个，轮流排列。
/// 某一族整体不通时，不必把它的地址全试完才轮到另一族。
fn dns_targets(
    resolver: &DnsResolver,
    host: &str,
    port: u16,
    ips: Vec<IpAddr>,
) -> Vec<EgressTarget> {
    // DNS 答案已改变时不再优先尝试旧地址；粘性地址之后先试另一协议族。
    let sticky = resolver.preferred_host_ip_for_addrs(host, &ips);
    let ordered = resolver.order_addrs_by_rtt(ips);
    let remaining = interleave_families(
        ordered
            .into_iter()
            .filter(|ip| Some(*ip) != sticky)
            .collect(),
        sticky.map_or(resolver.prefer_ipv6(), |ip| ip.is_ipv4()),
    );
    sticky
        .into_iter()
        .chain(remaining)
        .map(|ip| EgressTarget::Addr {
            addr: SocketAddr::new(ip, port),
            sticky: Some(ip) == sticky,
        })
        .collect()
}

fn interleave_families(addrs: Vec<IpAddr>, prefer_ipv6: bool) -> Vec<IpAddr> {
    let (mut preferred, mut other): (Vec<_>, Vec<_>) = addrs
        .into_iter()
        .partition(|addr| addr.is_ipv6() == prefer_ipv6);
    let mut interleaved = Vec::with_capacity(preferred.len() + other.len());
    let (mut preferred, mut other) = (preferred.drain(..), other.drain(..));
    loop {
        match (preferred.next(), other.next()) {
            (None, None) => break,
            (first, second) => interleaved.extend(first.into_iter().chain(second)),
        }
    }
    interleaved
}

/// 建连竞速的结果流：按连上的先后交付，调用方只取到够用为止。
enum ConnectRace {
    Single {
        host: String,
        port: u16,
        timeout: Duration,
        target: Option<EgressTarget>,
    },
    Racing {
        rx: mpsc::Receiver<(EgressTarget, Result<BoxStream>)>,
        tasks: Option<Vec<tokio::task::JoinHandle<()>>>,
    },
}

impl ConnectRace {
    async fn next(&mut self) -> Option<(EgressTarget, Result<BoxStream>)> {
        match self {
            Self::Single {
                host,
                port,
                timeout,
                target,
            } => {
                let target = target.take()?;
                let stream = open_target(&target, host, *port, *timeout).await;
                Some((target, stream))
            }
            Self::Racing { rx, .. } => rx.recv().await,
        }
    }
}

impl Drop for ConnectRace {
    fn drop(&mut self) {
        // 已经拿到可用连接：剩下的竞速任务连同它们的半开连接一起取消
        if let Self::Racing { tasks, .. } = self
            && let Some(tasks) = tasks.take()
        {
            for task in tasks {
                task.abort();
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use tokio::io::{AsyncReadExt, AsyncWriteExt};
    use tokio::net::TcpListener;

    #[tokio::test]
    async fn tcp_starts_while_ech_is_pending() {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let port = listener.local_addr().unwrap().port();
        let (ready, wait) = tokio::sync::oneshot::channel();
        let server = tokio::spawn(async move {
            let (stream, _) = tokio::time::timeout(Duration::from_millis(300), listener.accept())
                .await
                .expect("TCP must not wait for ECH")
                .unwrap();
            ready.send(()).unwrap();
            stream
        });
        let egress = connector();
        let result = egress
            .prepare_egress_with_ech("127.0.0.1", port, async {
                wait.await.unwrap();
                Some(vec![1, 2, 3])
            })
            .await
            .unwrap();
        assert_eq!(result.1, Some(vec![1, 2, 3]));
        assert!(result.3.unwrap().1.is_ok());
        drop(server.await.unwrap());
    }

    #[tokio::test]
    async fn sticky_addresses_must_still_be_in_dns_and_alternate_families() {
        let resolver = DnsResolver::new("https://127.0.0.1/dns-query", None, false, None, None)
            .await
            .unwrap();
        let v4a: IpAddr = "192.0.2.1".parse().unwrap();
        let v4b: IpAddr = "192.0.2.2".parse().unwrap();
        let v6: IpAddr = "2001:db8::1".parse().unwrap();
        resolver.record_host_success("example.com", v4a);
        let addresses = |targets: Vec<EgressTarget>| {
            targets
                .into_iter()
                .map(|target| match target {
                    EgressTarget::Addr { addr, .. } => addr.ip(),
                    _ => panic!("direct addresses expected"),
                })
                .collect::<Vec<_>>()
        };
        assert_eq!(
            addresses(dns_targets(
                &resolver,
                "example.com",
                443,
                vec![v4a, v4b, v6]
            )),
            vec![v4a, v6, v4b]
        );
        assert_eq!(
            addresses(dns_targets(&resolver, "example.com", 443, vec![v4b, v6])),
            vec![v4b, v6]
        );
        assert!(resolver.preferred_host_ip("example.com").is_none());
    }

    fn connector() -> EgressConnector {
        EgressConnector::new(None, None, None, None, Duration::from_secs(5))
    }

    /// 模拟上游：`good` 为真时回一个字节（视为握手成功），否则接受后立即断开
    /// （TCP 通、TLS 被掐，正是大陆网络下常见的形态）。
    async fn upstream(good: bool) -> EgressTarget {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let addr = listener.local_addr().unwrap();
        tokio::spawn(async move {
            loop {
                let Ok((mut stream, _)) = listener.accept().await else {
                    return;
                };
                if good {
                    let _ = stream.write_all(b"!").await;
                }
            }
        });
        EgressTarget::Addr {
            addr,
            sticky: false,
        }
    }

    async fn read_marker(mut stream: BoxStream) -> std::result::Result<(), HandshakeFailure> {
        let mut byte = [0u8; 1];
        match stream.read(&mut byte).await {
            Ok(1) => Ok(()),
            _ => Err(HandshakeFailure::retry(NetError::Proxy("reset".into()))),
        }
    }

    #[tokio::test]
    async fn client_backup_bypasses_stalled_handshake() {
        use std::sync::atomic::{AtomicUsize, Ordering};
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let port = listener.local_addr().unwrap().port();
        let server = tokio::spawn(async move {
            while let Ok((mut stream, _)) = listener.accept().await {
                use tokio::io::AsyncWriteExt;
                let _ = stream.write_all(b"ok").await;
            }
        });
        let calls = Arc::new(AtomicUsize::new(0));
        let seen = calls.clone();
        let egress = connector();
        tokio::time::timeout(
            CLIENT_TLS_BACKUP_DELAY + Duration::from_secs(1),
            egress.connect_client("127.0.0.1", port, move |stream, _| {
                let first = seen.fetch_add(1, Ordering::Relaxed) == 0;
                async move {
                    if first {
                        tokio::time::sleep(Duration::from_secs(30)).await;
                    }
                    read_marker(stream).await
                }
            }),
        )
        .await
        .expect("备用握手应绕过慢握手")
        .unwrap();
        assert_eq!(calls.load(Ordering::Relaxed), 2);
        server.abort();
    }

    #[tokio::test]
    async fn client_handshake_within_backup_delay_is_not_duplicated() {
        use std::sync::atomic::{AtomicUsize, Ordering};
        let good = upstream(true).await;
        let EgressTarget::Addr { addr, .. } = good else {
            unreachable!()
        };
        let calls = Arc::new(AtomicUsize::new(0));
        let seen = calls.clone();
        // 高 RTT 网络下的正常握手：慢，但没到备用阈值
        connector()
            .connect_client("127.0.0.1", addr.port(), move |stream, _| {
                seen.fetch_add(1, Ordering::Relaxed);
                async move {
                    tokio::time::sleep(Duration::from_millis(600)).await;
                    read_marker(stream).await
                }
            })
            .await
            .unwrap();
        assert_eq!(calls.load(Ordering::Relaxed), 1, "不该为正常握手起备用");
    }

    #[tokio::test]
    async fn certificate_failure_aborts_an_already_running_backup() {
        use std::sync::atomic::{AtomicUsize, Ordering};
        let EgressTarget::Addr { addr, .. } = upstream(true).await else {
            unreachable!()
        };
        let calls = Arc::new(AtomicUsize::new(0));
        let seen = calls.clone();
        let result: Result<()> = tokio::time::timeout(
            Duration::from_secs(3),
            connector().connect_client("127.0.0.1", addr.port(), move |stream, _| {
                let first = seen.fetch_add(1, Ordering::Relaxed) == 0;
                async move {
                    let _stream = stream;
                    if first {
                        tokio::time::sleep(CLIENT_TLS_BACKUP_DELAY + Duration::from_millis(100))
                            .await;
                        Err(HandshakeFailure::retry(NetError::Certificate(
                            "untrusted".into(),
                        )))
                    } else {
                        std::future::pending().await
                    }
                }
            }),
        )
        .await
        .expect("不能在证书失败后继续等备用超时");
        assert!(matches!(result, Err(NetError::Certificate(_))));
        assert_eq!(calls.load(Ordering::Relaxed), 2);
    }

    #[tokio::test]
    async fn total_budget_cancels_stalled_handshake_and_closes_socket() {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let port = listener.local_addr().unwrap().port();
        let server = tokio::spawn(async move {
            let (mut socket, _) = listener.accept().await.unwrap();
            let mut byte = [0];
            socket.read(&mut byte).await.unwrap()
        });
        let mut connector = connector();
        connector.timeout = Duration::from_millis(100);
        let result: Result<()> = connector
            .connect_client("127.0.0.1", port, |stream, _| async move {
                let _held = stream;
                std::future::pending().await
            })
            .await;
        assert!(matches!(result, Err(NetError::Timeout)));
        assert_eq!(
            tokio::time::timeout(Duration::from_secs(1), server)
                .await
                .unwrap()
                .unwrap(),
            0,
            "截止必须关闭 socket，不能只向调用方报告超时"
        );
    }

    #[tokio::test]
    async fn total_budget_includes_pending_ech_and_releases_ready_tcp() {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let port = listener.local_addr().unwrap().port();
        let server = tokio::spawn(async move {
            let (mut socket, _) = listener.accept().await.unwrap();
            socket.read(&mut [0]).await.unwrap()
        });
        let mut connector = connector();
        connector.timeout = Duration::from_millis(100);
        let result = connector
            .with_budget(
                "127.0.0.1",
                port,
                connector.prepare_egress_with_ech("127.0.0.1", port, std::future::pending()),
            )
            .await;
        assert!(matches!(result, Err(NetError::Timeout)));
        assert_eq!(
            tokio::time::timeout(Duration::from_secs(1), server)
                .await
                .unwrap()
                .unwrap(),
            0
        );
    }

    #[tokio::test]
    async fn backup_shares_primary_deadline_and_both_sockets_close() {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let port = listener.local_addr().unwrap().port();
        let server = tokio::spawn(async move {
            let (mut primary, _) = listener.accept().await.unwrap();
            let (mut backup, _) = listener.accept().await.unwrap();
            let mut a_buf = [0];
            let mut b_buf = [0];
            let (a, b) = tokio::join!(primary.read(&mut a_buf), backup.read(&mut b_buf));
            (a.unwrap(), b.unwrap())
        });
        let mut connector = connector();
        connector.timeout = CLIENT_TLS_BACKUP_DELAY + Duration::from_millis(200);
        let start = Instant::now();
        let result: Result<()> = connector
            .connect_client("127.0.0.1", port, |stream, _| async move {
                let _held = stream;
                std::future::pending().await
            })
            .await;
        assert!(matches!(result, Err(NetError::Timeout)));
        assert!(start.elapsed() < connector.timeout + Duration::from_millis(500));
        assert_eq!(
            tokio::time::timeout(Duration::from_secs(1), server)
                .await
                .unwrap()
                .unwrap(),
            (0, 0)
        );
    }

    #[tokio::test]
    async fn certificate_failure_does_not_try_another_address_or_remove_ech() {
        let good = upstream(true).await;
        let mut attempts = 0;
        let result: Result<()> = connector()
            .connect_targets(
                "example.com",
                443,
                vec![good.clone(), good],
                Some(vec![1]),
                |_, ech| {
                    attempts += 1;
                    assert!(ech.is_some());
                    async {
                        Err(HandshakeFailure::retry(NetError::Certificate(
                            "untrusted".into(),
                        )))
                    }
                },
            )
            .await;
        assert!(matches!(result, Err(NetError::Certificate(_))));
        assert_eq!(attempts, 1);
    }

    #[tokio::test]
    async fn falls_through_to_next_address_after_tls_stage_reset() {
        let bad = upstream(false).await;
        let good = upstream(true).await;
        let mut attempts = 0;
        connector()
            .connect_targets("example.com", 443, vec![bad, good], None, |stream, _| {
                attempts += 1;
                read_marker(stream)
            })
            .await
            .expect("second address should succeed");
        assert_eq!(attempts, 2);
    }

    #[tokio::test]
    async fn authenticated_empty_ech_retry_is_call_local() {
        let good = upstream(true).await;
        let connector = connector();
        let mut seen = Vec::new();
        connector
            .connect_targets(
                "example.com",
                443,
                vec![good.clone()],
                Some(vec![1]),
                |stream, ech| {
                    seen.push(ech.is_some());
                    async move {
                        if ech.is_some() {
                            return Err(HandshakeFailure::authenticated_ech_retry(Vec::new()));
                        }
                        read_marker(stream).await
                    }
                },
            )
            .await
            .expect("plain retry should succeed");
        assert_eq!(seen, [true, false]);
        // 服务器的本次禁用指示不变成跨请求、跨网络的猜测性降级缓存。
        let mut seen = Vec::new();
        connector
            .connect_targets(
                "example.com",
                443,
                vec![good.clone()],
                Some(vec![1]),
                |stream, ech| {
                    seen.push(ech.is_some());
                    read_marker(stream)
                },
            )
            .await
            .unwrap();
        assert_eq!(seen, [true]);
    }

    #[tokio::test]
    async fn transport_failure_keeps_ech_on_the_next_address() {
        let first = upstream(true).await;
        let second = upstream(true).await;
        let mut seen = Vec::new();
        connector()
            .connect_targets(
                "example.com",
                443,
                vec![first, second],
                Some(vec![1]),
                |stream, ech| {
                    seen.push(ech);
                    let first = seen.len() == 1;
                    async move {
                        if first {
                            Err(HandshakeFailure::retry(NetError::Timeout))
                        } else {
                            read_marker(stream).await
                        }
                    }
                },
            )
            .await
            .unwrap();
        assert_eq!(seen, [Some(vec![1]), Some(vec![1])]);
    }

    #[tokio::test]
    async fn authenticated_ech_retry_config_is_applied_once() {
        let target = upstream(true).await;
        let mut seen = Vec::new();
        let result: Result<()> = connector()
            .connect_targets("example.com", 443, vec![target], Some(vec![1]), |_, ech| {
                seen.push(ech);
                async { Err(HandshakeFailure::authenticated_ech_retry(vec![2])) }
            })
            .await;
        assert!(result.is_err());
        assert_eq!(seen, [Some(vec![1]), Some(vec![2])]);
    }

    #[tokio::test]
    async fn abort_stops_without_trying_other_addresses() {
        let good = upstream(true).await;
        let mut attempts = 0;
        let result: Result<()> = connector()
            .connect_targets(
                "example.com",
                443,
                vec![good.clone(), good],
                None,
                |_, _| {
                    attempts += 1;
                    async {
                        Err(HandshakeFailure::abort(NetError::Proxy(
                            "client gone".into(),
                        )))
                    }
                },
            )
            .await;
        assert!(result.is_err());
        assert_eq!(attempts, 1);
    }

    /// 接受连接但永不回应的监听端口。作为 HTTP 代理时，CONNECT 响应永远等不到，
    /// 以此模拟「连接卡住」——不可路由地址在本机不可靠（TUN 设备会直接接受）。
    async fn silent_listener() -> EgressTarget {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let addr = listener.local_addr().unwrap();
        tokio::spawn(async move {
            let mut held = Vec::new();
            while let Ok((stream, _)) = listener.accept().await {
                held.push(stream);
            }
        });
        EgressTarget::Proxy(Arc::new(UpstreamProxyConfig {
            protocol: "http".to_owned(),
            host: addr.ip().to_string(),
            port: addr.port(),
            username: None,
            password: None,
            cipher: None,
        }))
    }

    #[tokio::test]
    async fn pinned_plugin_proxy_uses_only_approved_addresses() {
        let EgressTarget::Proxy(proxy) = silent_listener().await else {
            unreachable!()
        };
        let ips: Vec<IpAddr> = ["1.1.1.1", "2606:4700:4700::1111"]
            .map(|s| s.parse().unwrap())
            .into();
        let connector = EgressConnector::new(
            None,
            Some((*proxy).clone()),
            None,
            Some("127.0.0.1"),
            TCP_TIMEOUT,
        )
        .with_pins(ips.clone());
        let targets = connector
            .egress_targets("service.example", 443)
            .await
            .unwrap();
        let actual: Vec<_> = targets
            .into_iter()
            .map(|t| match t {
                EgressTarget::PinnedProxy(p, ip) if p.port == proxy.port => ip,
                _ => panic!("插件应通过指定代理连接已校验的 IP"),
            })
            .collect();
        assert_eq!(actual, ips);
    }

    #[tokio::test]
    async fn plugin_proxy_receives_original_hostname_even_without_local_addresses() {
        for use_system_proxy in [false, true] {
            let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
            let proxy = UpstreamProxyConfig {
                protocol: "http".into(),
                host: "127.0.0.1".into(),
                port: listener.local_addr().unwrap().port(),
                username: None,
                password: None,
                cipher: None,
            };
            let server = tokio::spawn(async move {
                let (mut stream, _) = listener.accept().await.unwrap();
                let mut header = Vec::new();
                while !header.ends_with(b"\r\n\r\n") {
                    header.push(stream.read_u8().await.unwrap());
                }
                assert!(header.starts_with(b"CONNECT service.example:443 HTTP/1.1\r\n"));
                stream
                    .write_all(b"HTTP/1.1 200 Connection Established\r\n\r\n")
                    .await
                    .unwrap();
            });
            let connector = EgressConnector::new(
                None,
                (!use_system_proxy).then(|| proxy.clone()),
                use_system_proxy.then_some(proxy),
                None,
                TCP_TIMEOUT,
            )
            .with_pins(Vec::new())
            .with_proxy_resolution(true);
            let targets = connector
                .egress_targets("service.example", 443)
                .await
                .unwrap();
            assert_eq!(targets.len(), 1);
            assert!(matches!(targets[0], EgressTarget::Proxy(_)));
            open_target(&targets[0], "service.example", 443, TCP_TIMEOUT)
                .await
                .unwrap();
            server.await.unwrap();
        }
    }

    #[tokio::test]
    async fn plugin_direct_keeps_fake_ip_candidates_and_rejects_empty_addresses() {
        let addresses: Vec<IpAddr> = ["2001:2::6", "198.18.0.6", "2606:4700::1111"]
            .map(|s| s.parse().unwrap())
            .into();
        let connector = EgressConnector::new(None, None, None, None, TCP_TIMEOUT)
            .with_pins(addresses.clone())
            .with_proxy_resolution(true);
        let targets = connector
            .egress_targets("service.example", 443)
            .await
            .unwrap();
        let actual: Vec<_> = targets
            .into_iter()
            .map(|target| match target {
                EgressTarget::Addr { addr, .. } => addr.ip(),
                _ => panic!("直连候选必须保留宿主传入的地址"),
            })
            .collect();
        assert_eq!(actual, addresses);
        let connector = connector.with_pins(Vec::new());
        assert!(matches!(
            connector.egress_targets("service.example", 443).await,
            Err(NetError::Dns(_))
        ));
    }

    #[tokio::test]
    async fn stalled_target_does_not_block_the_reachable_one() {
        let stalled = silent_listener().await;
        let good = upstream(true).await;
        let started = Instant::now();
        connector()
            .connect_targets(
                "example.com",
                443,
                vec![stalled, good],
                None,
                |stream, _| read_marker(stream),
            )
            .await
            .expect("reachable target should win the race");
        // 第二个候选错开 250ms 发起，拿到它不该等第一个走完超时
        let elapsed = started.elapsed();
        assert!(elapsed < Duration::from_secs(1), "waited {elapsed:?}");
    }

    #[test]
    fn families_alternate_starting_with_the_preferred_one() {
        let v4: Vec<IpAddr> = vec!["1.1.1.1".parse().unwrap(), "2.2.2.2".parse().unwrap()];
        let v6: Vec<IpAddr> = vec!["::1".parse().unwrap()];
        let mixed = [v4.clone(), v6.clone()].concat();

        let ordered = interleave_families(mixed.clone(), false);
        assert_eq!(ordered, vec![v4[0], v6[0], v4[1]]);

        let ordered = interleave_families(mixed, true);
        assert_eq!(ordered, vec![v6[0], v4[0], v4[1]]);
    }
}
