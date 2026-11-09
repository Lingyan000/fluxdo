//! Alt-Svc 驱动的有界 H3 建连：已知服务参与冷连接竞速，首次发现仍在后台升级。
//! 只采纳同 origin 主机的替代端口，跨主机 Alt-Svc 保守忽略。
use super::*;
#[path = "http3_cache.rs"]
mod cache;
use rama::http::headers::{AltSvc, HeaderMapExt};
use rama::quic::{
    Endpoint, TransportConfig,
    tls::{
        BoringEchConfigList, BoringEchObservation, BoringTlsProvider, QuicClientConfigProvider,
        TlsOptions,
    },
};
use rama::tls::client::NegotiatedTlsParameters;
use rama_http_backend::client::Http3Transport;
use rama_http_core::h3::{connection::Config, transport::BoxedConnection};

const MAX_ORIGINS: usize = 64;
const PROBE_TIMEOUT: Duration = Duration::from_secs(3);
const BACKOFF: Duration = Duration::from_secs(300);
#[derive(Clone)]
struct Alternative {
    id: u64,
    port: u16,
    expires: Instant,
    persist: bool,
    retry_after: Instant,
    probing: bool,
}

pub(super) struct Http3Upgrade {
    alternatives: parking_lot::Mutex<HashMap<String, Alternative>>,
    endpoints: tokio::sync::Mutex<(Option<Endpoint>, Option<Endpoint>)>,
    probes: Arc<Semaphore>,
    generation: AtomicU64,
    pub(super) established: AtomicU64,
    cancel: parking_lot::Mutex<tokio_util::sync::CancellationToken>,
    next_alternative: AtomicU64,
    cache: Option<(Arc<cache::Store>, String)>,
    #[cfg(test)]
    test_tls: parking_lot::Mutex<Option<TlsClientConfig>>,
}
impl Default for Http3Upgrade {
    fn default() -> Self {
        Self {
            alternatives: Default::default(),
            endpoints: Default::default(),
            probes: Arc::new(Semaphore::new(2)),
            generation: AtomicU64::new(0),
            established: AtomicU64::new(0),
            cancel: parking_lot::Mutex::new(tokio_util::sync::CancellationToken::new()),
            next_alternative: AtomicU64::new(1),
            cache: None,
            #[cfg(test)]
            test_tls: Default::default(),
        }
    }
}
impl Drop for Http3Upgrade {
    fn drop(&mut self) {
        self.cancel.get_mut().cancel();
        let endpoints = self.endpoints.get_mut();
        for endpoint in [endpoints.0.take(), endpoints.1.take()]
            .into_iter()
            .flatten()
        {
            endpoint.close(0u32, b"client dropped");
        }
    }
}
impl Http3Upgrade {
    pub(super) fn with_cache(path: std::path::PathBuf, namespace: &str) -> Self {
        let store = cache::Store::open(path);
        let scope = cache::scope(namespace);
        let mut state = Self::default();
        for (key, saved) in store.entries(&scope) {
            state.alternatives.get_mut().insert(
                key,
                Alternative {
                    id: state.next_alternative.fetch_add(1, Ordering::Relaxed),
                    port: saved.port,
                    expires: Instant::now()
                        + Duration::from_secs(saved.expires.saturating_sub(cache::now())),
                    persist: true,
                    retry_after: Instant::now(),
                    probing: false,
                },
            );
        }
        state.cache = Some((store, scope));
        state
    }

    pub(super) async fn reset(&self) {
        {
            let mut token = self.cancel.lock();
            self.generation.fetch_add(1, Ordering::Relaxed);
            token.cancel();
            *token = tokio_util::sync::CancellationToken::new();
            let now = Instant::now();
            self.alternatives.lock().retain(|_, alt| {
                alt.probing = false;
                alt.retry_after = now;
                alt.persist && alt.expires > now
            });
        }
        let mut endpoints = self.endpoints.lock().await;
        for endpoint in [endpoints.0.take(), endpoints.1.take()]
            .into_iter()
            .flatten()
        {
            endpoint.close(0u32, b"network reset");
        }
    }
    pub(super) fn generation(&self) -> u64 {
        self.generation.load(Ordering::Relaxed)
    }
    pub(super) fn failed(&self, key: &str, generation: u64) {
        let mut alternatives = self.alternatives.lock();
        if generation == self.generation()
            && let Some(alt) = alternatives.get_mut(origin(key))
        {
            alt.retry_after = Instant::now() + BACKOFF;
        }
    }
    #[cfg(test)]
    pub(super) fn observe(&self, key: &str, host: &str, headers: &HeaderMap) {
        self.observe_at(key, host, headers, self.generation());
    }
    pub(super) fn observe_at(
        &self,
        key: &str,
        host: &str,
        headers: &HeaderMap,
        generation: u64,
    ) -> bool {
        let Some(value) = headers.typed_get::<AltSvc>() else {
            return false;
        };
        let key = origin(key);
        let mut alternatives = self.alternatives.lock();
        if generation != self.generation() {
            return false;
        }
        let now = Instant::now();
        alternatives.retain(|_, alt| alt.expires > now || alt.probing);
        if value.is_clear() {
            alternatives.remove(key);
            self.persist(key, None);
            return false;
        }
        let candidate = value.alternatives().and_then(|mut values| {
            values.find(|alt| {
                alt.protocol() == &ApplicationProtocol::HTTP_3
                    && alt
                        .host()
                        .is_none_or(|name| name.to_string().eq_ignore_ascii_case(host))
            })
        });
        let Some(alt) = candidate else {
            // 新公告替换旧公告，即使新列表已不包含我们支持的同源 H3。
            alternatives.remove(key);
            self.persist(key, None);
            return false;
        };
        let age = headers
            .get("age")
            .and_then(|v| v.to_str().ok())
            .and_then(|v| v.parse::<u64>().ok())
            .unwrap_or(0);
        let ttl = alt
            .max_age()
            .saturating_sub(Duration::from_secs(age))
            .min(Duration::from_secs(86400));
        if ttl.is_zero() {
            alternatives.remove(key);
            self.persist(key, None);
            return false;
        }
        if let Some(old) = alternatives.get_mut(key) {
            // 同一端点重复公告不能绕过退避；端口变更令旧探针失效。
            if old.port != alt.port() {
                old.id = self.next_alternative.fetch_add(1, Ordering::Relaxed);
                old.retry_after = now;
                old.probing = false;
            }
            old.port = alt.port();
            old.expires = now + ttl;
            old.persist = alt.persist();
        } else if alternatives.len() < MAX_ORIGINS {
            alternatives.insert(
                key.to_owned(),
                Alternative {
                    id: self.next_alternative.fetch_add(1, Ordering::Relaxed),
                    port: alt.port(),
                    expires: now + ttl,
                    persist: alt.persist(),
                    retry_after: now,
                    probing: false,
                },
            );
        }
        self.persist(
            key,
            alt.persist().then(|| cache::Entry {
                port: alt.port(),
                expires: cache::now() + ttl.as_secs(),
            }),
        );
        true
    }

    fn persist(&self, key: &str, value: Option<cache::Entry>) {
        if let Some((store, scope)) = &self.cache {
            store.update(scope, key, value);
        }
    }

    fn reserve(self: &Arc<Self>, key: &str) -> Option<Probe> {
        let permit = self.probes.clone().try_acquire_owned().ok()?;
        // 与 reset 使用相同的锁顺序，防止新探针取得旧取消令牌。
        let cancel = self.cancel.lock();
        let token = cancel.clone();
        let generation = self.generation.load(Ordering::Relaxed);
        let mut alternatives = self.alternatives.lock();
        let key = origin(key);
        let alt = alternatives.get_mut(key)?;
        let now = Instant::now();
        if alt.probing || alt.expires <= now || alt.retry_after > now {
            return None;
        }
        alt.probing = true;
        // TCP 胜出或调用取消也结束本次探测，短期不再为每张图片重复开 UDP。
        // 这是探测冷却，不把竞速落败误报成 QUIC 故障。
        alt.retry_after = now + BACKOFF;
        Some(Probe {
            state: self.clone(),
            key: key.to_owned(),
            alternative: alt.clone(),
            generation,
            token,
            _permit: permit,
        })
    }

    pub(super) async fn connect_or_tcp<F>(
        self: &Arc<Self>,
        target: &Target<'_>,
        egress: &EgressConnector,
        pool: &PoolState,
        exec: Executor,
        tcp: F,
    ) -> Result<Sender, BoxError>
    where
        F: Future<Output = Result<Sender, BoxError>>,
    {
        if egress.has_fixed_proxy() {
            return tcp.await;
        }
        // 竞速的第二条连接也要占全局容量；已饱和时直接使用原 TCP 路径。
        let Ok(_capacity) = pool.capacity.clone().try_acquire_owned() else {
            return tcp.await;
        };
        let Some(probe) = self.reserve(target.key) else {
            return tcp.await;
        };
        let h3 = async {
            let result = tokio::select! {
                _ = probe.token.cancelled() => Err(NetError::Cancelled.into()),
                value = tokio::time::timeout(PROBE_TIMEOUT,
                    self.connect(egress, target.host, target.port, probe.alternative.port, exec)) =>
                    value.map_err(|_| BoxError::from("H3 connect timeout")).and_then(|r| r),
            };
            if result.is_ok() {
                probe.succeeded();
            }
            result
        };
        // TCP 不等待 QUIC 探测截止；仅连接竞速，不在两条连接上发送业务请求。
        race_protocols(tcp, h3).await
    }
    pub(super) fn observe_and_upgrade(
        self: &Arc<Self>,
        target: &Target<'_>,
        headers: &HeaderMap,
        egress: Arc<EgressConnector>,
        pool: Arc<PoolState>,
        exec: Executor,
        generation: u64,
    ) {
        // 固定代理不支持直接 UDP；不占探针名额，不做 DNS 或重复写失败日志。
        if egress.has_fixed_proxy() {
            return;
        }
        if !self.observe_at(target.key, target.host, headers, generation) {
            return;
        }
        let Ok(capacity) = pool.capacity.clone().try_acquire_owned() else {
            return;
        };
        let Some(probe) = self.reserve(target.key) else {
            return;
        };
        let state = self.clone();
        let key = target.key.to_owned();
        let host = target.host.to_owned();
        let origin_port = target.port;
        let epoch = pool.epoch();
        // 后台升级和冷建连共用两个探测名额；超时、切网和 RAII 负责清理。
        tokio::spawn(async move {
            let started = Instant::now();
            let result = tokio::select! {
                _ = probe.token.cancelled() => return,
                result = tokio::time::timeout(PROBE_TIMEOUT, state.connect(&egress, &host, origin_port, probe.alternative.port, exec)) =>
                    result.map_err(|_| BoxError::from("H3 probe timeout")).and_then(|r| r),
            };
            let mut alternatives = state.alternatives.lock();
            if probe.generation != state.generation.load(Ordering::Relaxed) {
                return;
            }
            let Some(alt) = alternatives
                .get_mut(&probe.key)
                .filter(|a| a.id == probe.alternative.id)
            else {
                return;
            };
            alt.probing = false;
            match result {
                Ok(mut conn)
                    if pool.epoch() == epoch
                        && alt.expires > Instant::now()
                        && alt.port == probe.alternative.port =>
                {
                    Arc::get_mut(&mut conn)
                        .expect("new H3 connection")
                        ._capacity = Some(capacity);
                    alt.retry_after = Instant::now();
                    let mut hosts = pool.hosts.lock();
                    // 只替换仍存在的模板身份，旧任务不得重新创建已淘汰的池条目。
                    if let Some(entry) = hosts.get_mut(&key) {
                        entry.shared = Some(conn);
                        state.established.fetch_add(1, Ordering::Relaxed);
                        entry.http1 = false;
                        entry.idle.clear();
                        info!(
                            "HTTP/3 upgrade for {host}:{origin_port} ready in {}ms",
                            started.elapsed().as_millis()
                        );
                    }
                }
                Ok(_) => (),
                Err(error) => {
                    alt.retry_after = Instant::now() + BACKOFF;
                    info!(
                        "HTTP/3 upgrade for {host}:{origin_port} unavailable; keep TCP, retry after {}s: {error}",
                        BACKOFF.as_secs()
                    );
                }
            }
        });
    }
    async fn endpoint(&self, v6: bool, exec: Executor) -> Result<Endpoint, BoxError> {
        let mut endpoints = self.endpoints.lock().await;
        let slot = if v6 {
            &mut endpoints.1
        } else {
            &mut endpoints.0
        };
        if let Some(endpoint) = slot.as_ref().filter(|e| !e.is_closed()) {
            return Ok(endpoint.clone());
        }
        let bind: std::net::SocketAddr = if v6 { "[::]:0" } else { "0.0.0.0:0" }.parse()?;
        let endpoint = Endpoint::bind_client(exec, bind).await?;
        *slot = Some(endpoint.clone());
        Ok(endpoint)
    }
    async fn connect(
        &self,
        egress: &EgressConnector,
        host: &str,
        origin_port: u16,
        alt_port: u16,
        exec: Executor,
    ) -> Result<Sender, BoxError> {
        // Resolve using origin policy first. A proxy route never becomes direct QUIC.
        let (targets, ech) = egress.resolve_egress(host, origin_port).await?;
        if targets
            .iter()
            .any(|target| matches!(target, crate::egress::EgressTarget::Proxy(_)))
        {
            return Err(BoxError::from("configured proxy uses TCP"));
        }
        let addresses = targets
            .iter()
            .filter_map(|target| match target {
                crate::egress::EgressTarget::Addr { addr, .. } => {
                    Some(std::net::SocketAddr::new(addr.ip(), alt_port))
                }
                _ => None,
            })
            .collect::<Vec<_>>();
        let addresses = select_addresses(&addresses);
        race_addresses(addresses, |address| {
            let ech = ech.clone();
            let exec = exec.clone();
            async move {
                let mut tls = TlsClientConfig::default();
                tls.set_platform_verifier();
                #[cfg(test)]
                if let Some(test_tls) = self.test_tls.lock().clone() {
                    tls = test_tls;
                }
                tls.set_server_name(host.parse::<Host>()?);
                tls.set_alpn([ApplicationProtocol::HTTP_3].into_iter().collect());
                if let Some(ech) = &ech {
                    tls.insert(BoringEchConfigList(ech.clone()));
                }
                self.connect_tls(host, origin_port, address, tls, ech.is_some(), exec)
                    .await
            }
        })
        .await
    }
    async fn connect_tls(
        &self,
        host: &str,
        origin_port: u16,
        address: std::net::SocketAddr,
        tls: TlsClientConfig,
        ech_applied: bool,
        exec: Executor,
    ) -> Result<Sender, BoxError> {
        let mut transport = TransportConfig::default();
        transport.set_max_concurrent_bidi_streams(64u32);
        transport.set_max_concurrent_uni_streams(8u32);
        transport.set_stream_receive_window(2u32 * 1024 * 1024);
        transport.set_receive_window(8u32 * 1024 * 1024);
        transport.set_send_window(2 * 1024 * 1024);
        transport.set_max_idle_timeout(Duration::from_secs(60).try_into()?);
        transport.unset_datagram_receive_buffer_size();
        // Fresh peer-bound config: generic Rama TLS cache does not include our ECH extension.
        let ech_observation = Arc::new(std::sync::atomic::AtomicU8::new(0));
        tls.insert(BoringEchObservation(ech_observation.clone()));
        let config = BoringTlsProvider
            .client_config(&tls, TlsOptions::default())?
            .with_transport_config(Arc::new(transport));
        let endpoint = self.endpoint(address.is_ipv6(), exec.clone()).await?;
        let connection = endpoint.connect_with(config, address, host)?.await?;
        let ech_status = ech_observation.load(Ordering::Acquire);
        if ech_status == 0 {
            return Err("H3 TLS completion observation is missing".into());
        }
        let ech_accepted = ech_status == 2;
        if ech_applied && !ech_accepted {
            return Err("H3 ECH acceptance was not confirmed by TLS backend".into());
        }
        rama::tls::client::TlsConnectionReuse::new(BoringTlsProvider, tls.as_extensions())
            .publish(connection.extensions());
        connection
            .extensions()
            .insert(rama::tls::client::TlsServerAuthentication(Some(
                host.parse::<Host>()?,
            )));
        let negotiated = connection
            .extensions()
            .get_ref::<NegotiatedTlsParameters>()
            .cloned();
        let resumed = negotiated.and_then(|n| n.resumed).unwrap_or(false);
        // ECH acceptance above is observed directly from the completed native handshake.
        let input = ConnectRequest::new(HostWithPort::new(host.parse::<Host>()?, origin_port));
        let established = http_connect(
            Http3Transport {
                connection: BoxedConnection::new(connection),
                config: Arc::new(Config {
                    max_requests: 64,
                    max_pending_uni_streams: 8,
                    datagrams: None,
                    ..Config::default()
                }),
            },
            input,
            exec,
        )
        .await?;
        Ok(Arc::new(Conn {
            id: NEXT_CONNECTION_ID.fetch_add(1, Ordering::Relaxed),
            service: established.conn,
            version: Version::HTTP_3,
            resumed,
            ech_applied,
            ech_accepted,
            _capacity: None,
        }))
    }
}

/// 服务能力按 origin 保存；连接池仍按模板版本隔离。
fn origin(key: &str) -> &str {
    key.split_once('#').map_or(key, |(origin, _)| origin)
}

struct Probe {
    state: Arc<Http3Upgrade>,
    key: String,
    alternative: Alternative,
    generation: u64,
    token: tokio_util::sync::CancellationToken,
    _permit: OwnedSemaphorePermit,
}
impl Probe {
    fn succeeded(&self) {
        let mut alternatives = self.state.alternatives.lock();
        if self.generation == self.state.generation.load(Ordering::Relaxed)
            && let Some(alt) = alternatives
                .get_mut(&self.key)
                .filter(|a| a.id == self.alternative.id)
        {
            alt.retry_after = Instant::now();
        }
    }
}
impl Drop for Probe {
    fn drop(&mut self) {
        let mut alternatives = self.state.alternatives.lock();
        if self.generation == self.state.generation.load(Ordering::Relaxed)
            && let Some(alt) = alternatives
                .get_mut(&self.key)
                .filter(|a| a.id == self.alternative.id)
        {
            alt.probing = false;
        }
    }
}

/// 首个成功连接胜出，首个失败不会取消仍可能成功的另一条路径。
async fn race_protocols<T>(
    tcp: impl Future<Output = Result<T, BoxError>>,
    h3: impl Future<Output = Result<T, BoxError>>,
) -> Result<T, BoxError> {
    tokio::pin!(tcp, h3);
    tokio::select! {
        result = &mut tcp => match result { Ok(conn) => Ok(conn), Err(tcp_error) => h3.await.or(Err(tcp_error)) },
        result = &mut h3 => match result { Ok(conn) => Ok(conn), Err(_) => tcp.await },
    }
}

/// 最多两个不同目的地址，优先选择另一地址族。
fn select_addresses(addresses: &[std::net::SocketAddr]) -> Vec<std::net::SocketAddr> {
    let Some(first) = addresses.first().copied() else {
        return Vec::new();
    };
    let second = addresses
        .iter()
        .copied()
        .find(|a| a.is_ipv6() != first.is_ipv6())
        .or_else(|| addresses.iter().copied().find(|a| *a != first));
    std::iter::once(first).chain(second).collect()
}

async fn race_addresses<T, F, Fut>(
    addresses: Vec<std::net::SocketAddr>,
    mut connect: F,
) -> Result<T, BoxError>
where
    F: FnMut(std::net::SocketAddr) -> Fut,
    Fut: std::future::Future<Output = Result<T, BoxError>>,
{
    use rama::futures::{StreamExt, stream::FuturesUnordered};
    let mut attempts = FuturesUnordered::new();
    for (index, address) in addresses.into_iter().take(2).enumerate() {
        let future = connect(address);
        attempts.push(async move {
            if index > 0 {
                tokio::time::sleep(Duration::from_millis(250)).await;
            }
            future.await
        });
    }
    let mut last_error: BoxError = "no H3 address".into();
    while let Some(result) = attempts.next().await {
        match result {
            Ok(value) => return Ok(value),
            Err(error) => last_error = error,
        }
    }
    Err(last_error)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn real_cold_h3_bypasses_tls_blackhole_without_duplicate_requests() {
        use rama::http::body::util::BodyExt;
        use rama::tls::server::{GeneratedServerAuthConfig, ServerAuthData, TlsServerConfig};
        use tokio::io::AsyncReadExt;
        let identity = ServerAuthData::new_generated(GeneratedServerAuthConfig::default()).unwrap();
        let anchor = identity.cert_chain.last().unwrap().clone();
        let server_tls = TlsServerConfig::new()
            .with_server_auth(identity)
            .with_alpn([ApplicationProtocol::HTTP_3].into_iter().collect());
        let config = rama::quic::tls::QuicServerConfigProvider::server_config(
            &BoringTlsProvider,
            &server_tls,
            TlsOptions::default(),
        )
        .unwrap();
        let endpoint = Endpoint::bind_server(
            Executor::new(),
            config,
            "127.0.0.1:0".parse::<std::net::SocketAddr>().unwrap(),
        )
        .await
        .unwrap();
        let tcp = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let origin_port = tcp.local_addr().unwrap().port();
        let tcp_closed = tokio::spawn(async move {
            let (mut socket, _) = tcp.accept().await.unwrap();
            let mut data = Vec::new();
            tokio::time::timeout(Duration::from_secs(2), socket.read_to_end(&mut data))
                .await
                .unwrap()
                .unwrap();
            assert!(!data.is_empty(), "收到 TLS ClientHello 后应关闭落败连接");
        });
        let server = tokio::spawn({
            let endpoint = endpoint.clone();
            async move {
                let connection = endpoint.accept().await.unwrap().await.unwrap();
                let (mut requests, driver) =
                    rama_http_core::h3::server::handshake(connection, Config::default()).unwrap();
                let _driver = tokio_util::task::AbortOnDropHandle::new(tokio::spawn(driver.run()));
                for _ in 0..2 {
                    let (request, respond) =
                        requests.accept().await.unwrap().resolve().await.unwrap();
                    assert_eq!(request.version(), Version::HTTP_3);
                    assert_eq!(
                        request
                            .into_body()
                            .collect()
                            .await
                            .unwrap()
                            .to_bytes()
                            .as_ref(),
                        b"one write"
                    );
                    respond
                        .send_response(Response::new(Body::from("ok")))
                        .await
                        .unwrap();
                }
                // 保持连接直到测试结束，确保两次写请求使用同一条已建立的连接。
                std::future::pending::<()>().await;
            }
        });
        let client = HttpEgressClient::new(
            Arc::new(EgressConnector::new(
                None,
                None,
                None,
                Some("127.0.0.1"),
                Duration::from_secs(3),
            )),
            None,
        );
        *client.h3.test_tls.lock() = Some(
            TlsClientConfig::new()
                .try_with_server_trust_anchors([anchor])
                .unwrap(),
        );
        let key = format!("https://localhost:{origin_port}#0");
        let mut headers = HeaderMap::new();
        headers.insert(
            "alt-svc",
            format!("h3=\":{}\"; ma=600", endpoint.local_addr().unwrap().port())
                .parse()
                .unwrap(),
        );
        client.h3.observe(&key, "localhost", &headers);
        let send = || async {
            let request = Request::builder()
                .method("POST")
                .uri(format!("https://localhost:{origin_port}/write"))
                .body(Body::from("one write"))
                .unwrap();
            let response = client
                .send(
                    request,
                    Some(Duration::from_secs(2)),
                    Some(Duration::from_secs(2)),
                )
                .await
                .unwrap();
            let info = response
                .extensions()
                .get_ref::<ExchangeInfo>()
                .unwrap()
                .clone();
            assert_eq!(
                response
                    .into_body()
                    .collect()
                    .await
                    .unwrap()
                    .to_bytes()
                    .as_ref(),
                b"ok"
            );
            info
        };
        let (first, second) = tokio::join!(send(), send());
        assert_eq!(first.version, Version::HTTP_3);
        assert_eq!(first.connection_id, second.connection_id);
        assert_eq!(client.established_connections(), 1);
        assert_eq!(client.h3.probes.available_permits(), 2);
        assert_eq!(
            client.pool.capacity.available_permits(),
            MAX_CONNECTIONS - 1
        );
        tcp_closed.await.unwrap();
        client.reset_connections().await;
        endpoint.close(0u32, b"test complete");
        server.abort();
    }

    #[tokio::test]
    async fn real_tls_succeeds_without_waiting_for_udp_blackhole() {
        use rama::http::body::util::BodyExt;
        use rama::tls::boring::core::{
            pkey::PKey,
            ssl::{SslAcceptor, SslMethod},
            tokio::accept,
            x509::X509,
        };
        use tokio::io::{AsyncReadExt, AsyncWriteExt};
        let (chain, key) = rama_crypto::cert::generate_server_auth(
            rama_crypto::cert::GeneratedServerAuthConfig::generated_ca_for(
                rama::net::address::Domain::from_static("localhost"),
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
        let tcp = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let origin_port = tcp.local_addr().unwrap().port();
        let udp = tokio::net::UdpSocket::bind("127.0.0.1:0").await.unwrap();
        let udp_port = udp.local_addr().unwrap().port();
        let server = tokio::spawn(async move {
            let (socket, _) = tcp.accept().await.unwrap();
            let mut stream = accept(&acceptor, socket).await.unwrap();
            let mut bytes = Vec::new();
            loop {
                let byte = stream.read_u8().await.unwrap();
                bytes.push(byte);
                if bytes.ends_with(b"\r\n\r\n") {
                    break;
                }
            }
            stream
                .write_all(b"HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nok")
                .await
                .unwrap();
            stream.shutdown().await.unwrap();
        });
        let client = HttpEgressClient::new(
            Arc::new(EgressConnector::new(
                None,
                None,
                None,
                Some("127.0.0.1"),
                Duration::from_secs(3),
            )),
            None,
        );
        *client.test_tls.lock() = Some(
            TlsClientConfig::new()
                .try_with_server_trust_anchors([chain.last().unwrap().clone()])
                .unwrap(),
        );
        let key = format!("https://localhost:{origin_port}#0");
        let mut headers = HeaderMap::new();
        headers.insert(
            "alt-svc",
            format!("h3=\":{udp_port}\"; ma=600").parse().unwrap(),
        );
        client.h3.observe(&key, "localhost", &headers);
        let request = Request::builder()
            .uri(format!("https://localhost:{origin_port}/image"))
            .body(Body::empty())
            .unwrap();
        let response = tokio::time::timeout(
            Duration::from_secs(1),
            client.send(
                request,
                Some(Duration::from_secs(3)),
                Some(Duration::from_secs(1)),
            ),
        )
        .await
        .unwrap()
        .unwrap();
        assert_eq!(response.version(), Version::HTTP_11);
        assert_eq!(
            response
                .into_body()
                .collect()
                .await
                .unwrap()
                .to_bytes()
                .as_ref(),
            b"ok"
        );
        assert_eq!(client.h3.probes.available_permits(), 2);
        assert!(
            client.h3.reserve(&key).is_none(),
            "TCP 胜出后不要为下一张图片立即重复探测"
        );
        server.await.unwrap();
        client.reset_connections().await;
    }

    #[tokio::test]
    async fn persistent_capabilities_survive_reload_without_network_failure_state() {
        let directory = std::env::temp_dir().join(format!(
            "fluxdo-alt-svc-{}-{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        let path = directory.join("services.json");
        let state = Arc::new(Http3Upgrade::with_cache(path.clone(), "direct"));
        let mut headers = HeaderMap::new();
        headers.insert(
            "alt-svc",
            "h3=\":8443\"; ma=600; persist=1".parse().unwrap(),
        );
        state.observe("https://example.com:443#1", "example.com", &headers);
        state.failed("https://example.com:443#1", state.generation());
        state.cache.as_ref().unwrap().0.flush().unwrap();
        let reloaded_path = directory.join("reloaded.json");
        std::fs::copy(&path, &reloaded_path).unwrap();
        let reloaded = Arc::new(Http3Upgrade::with_cache(reloaded_path, "direct"));
        let probe = reloaded.reserve("https://example.com:443#99").unwrap();
        assert_eq!(probe.alternative.port, 8443);
        assert!(probe.alternative.expires < Instant::now() + Duration::from_secs(601));
        assert!(
            Http3Upgrade::with_cache(path.clone(), "other proxy")
                .alternatives
                .lock()
                .is_empty()
        );
        headers.insert("alt-svc", "clear".parse().unwrap());
        state.observe("https://example.com:443#1", "example.com", &headers);
        assert!(
            Http3Upgrade::with_cache(path.clone(), "direct")
                .alternatives
                .lock()
                .is_empty()
        );
        headers.insert("alt-svc", "h3=\":443\"; ma=600".parse().unwrap());
        state.observe("https://example.com:443#1", "example.com", &headers);
        assert!(
            Http3Upgrade::with_cache(path, "direct")
                .alternatives
                .lock()
                .is_empty()
        );
        state.reset().await;
        assert!(state.alternatives.lock().is_empty());
        std::fs::remove_dir_all(directory).unwrap();
    }

    #[tokio::test]
    async fn cold_race_uses_h3_when_tcp_stalls_and_cancels_loser() {
        use std::sync::atomic::AtomicBool;
        struct Dropped(Arc<AtomicBool>);
        impl Drop for Dropped {
            fn drop(&mut self) {
                self.0.store(true, Ordering::Relaxed);
            }
        }
        let dropped = Arc::new(AtomicBool::new(false));
        let guard = Dropped(dropped.clone());
        let tcp = async move {
            let _guard = guard;
            std::future::pending::<Result<u8, BoxError>>().await
        };
        let h3 = async {
            tokio::task::yield_now().await;
            Ok(3)
        };
        assert_eq!(
            tokio::time::timeout(Duration::from_secs(1), race_protocols(tcp, h3))
                .await
                .unwrap()
                .unwrap(),
            3
        );
        assert!(dropped.load(Ordering::Relaxed));
        assert_eq!(
            race_protocols(async { Err("tcp failed".into()) }, async { Ok(3) })
                .await
                .unwrap(),
            3
        );
        assert_eq!(
            race_protocols(async { Ok(2) }, async { Err("udp failed".into()) })
                .await
                .unwrap(),
            2
        );
    }

    #[tokio::test]
    async fn cancelled_cold_race_releases_probe_and_capacity() {
        let blackhole = tokio::net::UdpSocket::bind("127.0.0.1:0").await.unwrap();
        let state = Arc::new(Http3Upgrade::default());
        let pool = PoolState::default();
        let mut headers = HeaderMap::new();
        headers.insert(
            "alt-svc",
            format!("h3=\":{}\"; ma=600", blackhole.local_addr().unwrap().port())
                .parse()
                .unwrap(),
        );
        let target = Target {
            key: "https://127.0.0.1:443#1",
            host: "127.0.0.1",
            port: 443,
            template: None,
            secure: true,
        };
        state.observe(target.key, target.host, &headers);
        let egress = EgressConnector::new(None, None, None, None, Duration::from_secs(2));
        // 用真实 UDP 收包确认 QUIC 已启动，再取消整个调用。
        let mut future = Box::pin(state.connect_or_tcp(
            &target,
            &egress,
            &pool,
            Executor::new(),
            std::future::pending(),
        ));
        let mut bytes = [0; 1500];
        tokio::select! {
            _ = &mut future => panic!("both paths should be pending"),
            packet = tokio::time::timeout(Duration::from_secs(1), blackhole.recv_from(&mut bytes)) => { assert!(packet.unwrap().unwrap().0 > 0); }
        }
        assert_eq!(state.probes.available_permits(), 1);
        drop(future);
        assert_eq!(state.probes.available_permits(), 2);
        assert_eq!(pool.capacity.available_permits(), MAX_CONNECTIONS);
        assert!(!state.alternatives.lock()[origin(target.key)].probing);
        assert!(state.reserve(target.key).is_none());
        let endpoint = state.endpoints.lock().await.0.clone().unwrap();
        tokio::time::timeout(Duration::from_secs(4), async {
            while endpoint.open_connections() != 0 {
                tokio::time::sleep(Duration::from_millis(10)).await;
            }
        })
        .await
        .expect("取消的 QUIC 握手应离开端点连接表");
        state.reset().await;
    }

    #[tokio::test]
    async fn advertisement_replacement_reset_and_probe_drop_are_generation_safe() {
        let state = Arc::new(Http3Upgrade::default());
        let mut headers = HeaderMap::new();
        headers.insert("alt-svc", "h3=\":443\"; ma=600; persist=1".parse().unwrap());
        state.observe("https://example.com:443#1", "example.com", &headers);
        let old = state.reserve("https://example.com:443#2").unwrap();
        let old_generation = state.generation();
        state.reset().await;
        assert!(old.token.is_cancelled());
        state.failed("https://example.com:443#2", old_generation);
        let mut clear = HeaderMap::new();
        clear.insert("alt-svc", "clear".parse().unwrap());
        assert!(!state.observe_at(
            "https://example.com:443#2",
            "example.com",
            &clear,
            old_generation
        ));
        let new = state.reserve("https://example.com:443#3").unwrap();
        drop(old);
        assert!(state.alternatives.lock()["https://example.com:443"].probing);
        drop(new);
        assert!(!state.alternatives.lock()["https://example.com:443"].probing);
        headers.insert("alt-svc", "h2=\":443\"".parse().unwrap());
        state.observe("https://example.com:443#3", "example.com", &headers);
        assert!(state.alternatives.lock().is_empty());
        assert_eq!(state.probes.available_permits(), 2);
    }
    #[tokio::test]
    async fn fixed_proxy_skips_quic_before_dns_or_probe_allocation() {
        let state = Arc::new(Http3Upgrade::default());
        let pool = Arc::new(PoolState::default());
        let proxy: crate::UpstreamProxyConfig = serde_json::from_value(serde_json::json!({
            "host": "127.0.0.1", "port": 7890, "protocol": "http"
        }))
        .unwrap();
        let egress = Arc::new(EgressConnector::new(
            None,
            None,
            Some(proxy),
            None,
            Duration::from_secs(1),
        ));
        let target = Target {
            key: "proxy",
            template: None,
            host: "not-resolved.invalid",
            port: 443,
            secure: true,
        };
        let mut headers = HeaderMap::new();
        headers.insert("alt-svc", "h3=\":443\"; ma=600".parse().unwrap());
        let permits = state.probes.available_permits();
        state.observe_and_upgrade(
            &target,
            &headers,
            egress.clone(),
            pool.clone(),
            Executor::new(),
            state.generation(),
        );
        assert!(state.alternatives.lock().is_empty());
        assert_eq!(state.probes.available_permits(), permits);
        assert!(pool.hosts.lock().is_empty());
        state.observe(target.key, target.host, &headers);
        let result = state
            .connect_or_tcp(&target, &egress, &pool, Executor::new(), async {
                Err::<Sender, BoxError>("TCP sentinel".into())
            })
            .await;
        assert_eq!(result.err().unwrap().to_string(), "TCP sentinel");
        assert_eq!(state.probes.available_permits(), permits);
        assert!(state.endpoints.lock().await.0.is_none());
        assert!(!state.alternatives.lock()[target.key].probing);
    }

    #[tokio::test]
    async fn bounded_h3_race_bypasses_stalled_first_address() {
        let first = "[::1]:443".parse().unwrap();
        let second = "127.0.0.1:443".parse().unwrap();
        assert_eq!(
            select_addresses(&[first, first, second]),
            vec![first, second]
        );
        let value = tokio::time::timeout(
            Duration::from_secs(1),
            race_addresses(vec![first, second], |address| async move {
                if address == first {
                    std::future::pending::<()>().await;
                }
                Ok(address)
            }),
        )
        .await
        .unwrap()
        .unwrap();
        assert_eq!(value, second);
        let error = race_addresses(vec![first, second], |_| async {
            Err::<(), BoxError>("unreachable".into())
        })
        .await;
        assert!(error.is_err());
    }

    #[tokio::test]
    async fn blocked_udp_backs_off_and_reset_cancels_probe() {
        // Bound but never read: packets are silently dropped, rather than an ICMP refusal.
        let blackhole = tokio::net::UdpSocket::bind("127.0.0.1:0").await.unwrap();
        let port = blackhole.local_addr().unwrap().port();
        let state = Arc::new(Http3Upgrade::default());
        let pool = Arc::new(PoolState::default());
        pool.hosts.lock().insert("key".into(), HostPool::default());
        let egress = Arc::new(EgressConnector::new(
            None,
            None,
            None,
            None,
            Duration::from_secs(1),
        ));
        let target = Target {
            key: "key",
            template: None,
            host: "127.0.0.1",
            port,
            secure: true,
        };
        let mut headers = HeaderMap::new();
        headers.insert(
            "alt-svc",
            format!("h3=\":{port}\"; ma=600").parse().unwrap(),
        );
        state.observe_and_upgrade(
            &target,
            &headers,
            egress.clone(),
            pool.clone(),
            Executor::new(),
            state.generation(),
        );
        assert!(state.alternatives.lock()["key"].probing);
        tokio::time::timeout(PROBE_TIMEOUT + Duration::from_secs(2), async {
            while state.alternatives.lock()["key"].probing {
                tokio::time::sleep(Duration::from_millis(20)).await;
            }
        })
        .await
        .unwrap();
        assert!(state.alternatives.lock()["key"].retry_after > Instant::now());
        assert_eq!(pool.capacity.available_permits(), MAX_CONNECTIONS);
        state.observe_and_upgrade(
            &target,
            &headers,
            egress.clone(),
            pool.clone(),
            Executor::new(),
            state.generation(),
        );
        assert!(!state.alternatives.lock()["key"].probing);
        state
            .alternatives
            .lock()
            .get_mut("key")
            .unwrap()
            .retry_after = Instant::now();
        state.observe_and_upgrade(
            &target,
            &headers,
            egress,
            pool.clone(),
            Executor::new(),
            state.generation(),
        );
        state.reset().await;
        tokio::time::timeout(Duration::from_secs(1), async {
            while pool.capacity.available_permits() != MAX_CONNECTIONS {
                tokio::task::yield_now().await;
            }
        })
        .await
        .unwrap();
        assert!(state.alternatives.lock().is_empty());
        assert!(pool.hosts.lock()["key"].shared.is_none());
    }

    #[tokio::test]
    async fn real_h3_requests_share_connection_and_reject_untrusted_certificate() {
        use rama::http::body::util::BodyExt;
        use rama::tls::server::{GeneratedServerAuthConfig, ServerAuthData, TlsServerConfig};
        let identity = ServerAuthData::new_generated(GeneratedServerAuthConfig::default()).unwrap();
        let anchor = identity.cert_chain.last().unwrap().clone();
        let server_tls = TlsServerConfig::new()
            .with_server_auth(identity)
            .with_alpn([ApplicationProtocol::HTTP_3].into_iter().collect());
        let config = rama::quic::tls::QuicServerConfigProvider::server_config(
            &BoringTlsProvider,
            &server_tls,
            TlsOptions::default(),
        )
        .unwrap();
        let endpoint = Endpoint::bind_server(
            Executor::new(),
            config,
            "127.0.0.1:0".parse::<std::net::SocketAddr>().unwrap(),
        )
        .await
        .unwrap();
        let address = endpoint.local_addr().unwrap();
        let server = tokio::spawn({
            let endpoint = endpoint.clone();
            async move {
                while let Some(incoming) = endpoint.accept().await {
                    tokio::spawn(async move {
                        let Ok(connection) = incoming.await else {
                            return;
                        };
                        let (mut requests, driver) =
                            rama_http_core::h3::server::handshake(connection, Config::default())
                                .unwrap();
                        let driver = tokio::spawn(driver.run());
                        while let Ok(request) = requests.accept().await {
                            let (request, respond) = request.resolve().await.unwrap();
                            assert_eq!(request.version(), Version::HTTP_3);
                            assert_eq!(
                                request.uri().authority().unwrap().host().to_string(),
                                "localhost"
                            );
                            respond
                                .send_response(Response::new(Body::from(vec![42u8; 256 * 1024])))
                                .await
                                .unwrap();
                        }
                        driver.abort();
                    });
                }
            }
        });
        let state = Http3Upgrade::default();
        let tls = TlsClientConfig::new()
            .with_alpn([ApplicationProtocol::HTTP_3].into_iter().collect())
            .try_with_server_trust_anchors([anchor])
            .unwrap();
        let conn = tokio::time::timeout(
            Duration::from_secs(5),
            state.connect_tls(
                "localhost",
                address.port(),
                address,
                tls,
                false,
                Executor::new(),
            ),
        )
        .await
        .unwrap()
        .unwrap();
        for _ in 0..2 {
            assert!(is_alive(&conn));
            let request = Request::builder()
                .uri(format!("https://localhost:{}/image", address.port()))
                .version(Version::HTTP_3)
                .body(Body::empty())
                .unwrap();
            let response = conn.service.serve(request).await.unwrap();
            assert_eq!(response.version(), Version::HTTP_3);
            assert_eq!(
                response
                    .into_body()
                    .collect()
                    .await
                    .unwrap()
                    .to_bytes()
                    .as_ref(),
                vec![42u8; 256 * 1024]
            );
        }
        let mut untrusted = TlsClientConfig::default();
        untrusted.set_platform_verifier();
        untrusted.set_alpn([ApplicationProtocol::HTTP_3].into_iter().collect());
        let failure = tokio::time::timeout(
            Duration::from_secs(5),
            state.connect_tls(
                "localhost",
                address.port(),
                address,
                untrusted,
                false,
                Executor::new(),
            ),
        )
        .await
        .unwrap();
        assert!(failure.is_err());
        state.reset().await;
        endpoint.close(0u32, b"test complete");
        server.abort();
    }

    #[test]
    fn alt_svc_ttl_origin_clear_and_backoff() {
        let state = Http3Upgrade::default();
        let mut headers = HeaderMap::new();
        headers.insert("alt-svc", HeaderValue::from_static("h3=\":443\"; ma=600"));
        state.observe("key", "example.com", &headers);
        assert_eq!(state.alternatives.lock()["key"].port, 443);
        let retry = Instant::now() + BACKOFF;
        state
            .alternatives
            .lock()
            .get_mut("key")
            .unwrap()
            .retry_after = retry;
        state.observe("key", "example.com", &headers);
        assert_eq!(state.alternatives.lock()["key"].retry_after, retry);
        headers.insert("alt-svc", HeaderValue::from_static("clear"));
        state.observe("key", "example.com", &headers);
        assert!(state.alternatives.lock().is_empty());
        headers.insert("alt-svc", HeaderValue::from_static("h3=\"other.test:443\""));
        state.observe("key", "example.com", &headers);
        assert!(state.alternatives.lock().is_empty());
        headers.insert("alt-svc", HeaderValue::from_static("h3=\":443\"; ma=1"));
        headers.insert("age", HeaderValue::from_static("2"));
        state.observe("key", "example.com", &headers);
        assert!(state.alternatives.lock().is_empty());
    }
}
