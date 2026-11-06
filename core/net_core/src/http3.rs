//! Alt-Svc 驱动的有界后台 H3 升级。当前请求继续使用 H2/H1，不重放请求体。
//! 只采纳同 origin 主机的替代端口，跨主机 Alt-Svc 保守忽略。
use super::*;
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
    port: u16,
    expires: Instant,
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
    pub(super) async fn reset(&self) {
        self.generation.fetch_add(1, Ordering::Relaxed);
        {
            let mut token = self.cancel.lock();
            token.cancel();
            *token = tokio_util::sync::CancellationToken::new();
            self.alternatives.lock().clear();
        }
        let mut endpoints = self.endpoints.lock().await;
        for endpoint in [endpoints.0.take(), endpoints.1.take()]
            .into_iter()
            .flatten()
        {
            endpoint.close(0u32, b"network reset");
        }
    }
    pub(super) fn failed(&self, key: &str) {
        if let Some(alt) = self.alternatives.lock().get_mut(key) {
            alt.retry_after = Instant::now() + BACKOFF;
        }
    }
    pub(super) fn observe(&self, key: &str, host: &str, headers: &HeaderMap) {
        let Some(value) = headers.typed_get::<AltSvc>() else {
            return;
        };
        let mut alternatives = self.alternatives.lock();
        let now = Instant::now();
        alternatives.retain(|_, alt| alt.expires > now || alt.probing);
        if value.is_clear() {
            alternatives.remove(key);
            return;
        }
        let candidate = value.alternatives().and_then(|mut values| {
            values.find(|alt| {
                alt.protocol() == &ApplicationProtocol::HTTP_3
                    && alt
                        .host()
                        .is_none_or(|name| name.to_string().eq_ignore_ascii_case(host))
            })
        });
        let Some(alt) = candidate else { return };
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
            return;
        }
        if let Some(old) = alternatives.get_mut(key) {
            // Repeated advertisements cannot reset failure backoff or permit parallel probes.
            old.port = alt.port();
            old.expires = now + ttl;
        } else if alternatives.len() < MAX_ORIGINS {
            alternatives.insert(
                key.to_owned(),
                Alternative {
                    port: alt.port(),
                    expires: now + ttl,
                    retry_after: now,
                    probing: false,
                },
            );
        }
    }
    pub(super) fn observe_and_upgrade(
        self: &Arc<Self>,
        target: &Target<'_>,
        headers: &HeaderMap,
        egress: Arc<EgressConnector>,
        pool: Arc<PoolState>,
        exec: Executor,
    ) {
        // 固定代理不支持直接 UDP；不占探针名额，不做 DNS 或重复写失败日志。
        if egress.has_fixed_proxy() {
            return;
        }
        self.observe(target.key, target.host, headers);
        let Ok(permit) = self.probes.clone().try_acquire_owned() else {
            return;
        };
        let Ok(capacity) = pool.capacity.clone().try_acquire_owned() else {
            return;
        };
        let alternative = {
            let mut alternatives = self.alternatives.lock();
            let Some(alt) = alternatives.get_mut(target.key) else {
                return;
            };
            if alt.probing || alt.expires <= Instant::now() || alt.retry_after > Instant::now() {
                return;
            }
            alt.probing = true;
            alt.clone()
        };
        let state = self.clone();
        let key = target.key.to_owned();
        let host = target.host.to_owned();
        let origin_port = target.port;
        let epoch = pool.epoch();
        let generation = self.generation.load(Ordering::Relaxed);
        let token = self.cancel.lock().clone();
        // Task lifetime bounded by timeout/cancellation; only two probes for all origins.
        tokio::spawn(async move {
            let _permit = permit;
            let started = Instant::now();
            let result = tokio::select! {
                _ = token.cancelled() => return,
                result = tokio::time::timeout(PROBE_TIMEOUT, state.connect(&egress, &host, origin_port, alternative.port, exec)) =>
                    result.map_err(|_| BoxError::from("H3 probe timeout")).and_then(|r| r),
            };
            let mut alternatives = state.alternatives.lock();
            if generation != state.generation.load(Ordering::Relaxed) {
                return;
            }
            let Some(alt) = alternatives.get_mut(&key) else {
                return;
            };
            alt.probing = false;
            match result {
                Ok(mut conn)
                    if pool.epoch() == epoch
                        && alt.expires > Instant::now()
                        && alt.port == alternative.port =>
                {
                    Arc::get_mut(&mut conn)
                        .expect("new H3 connection")
                        ._capacity = Some(capacity);
                    alt.retry_after = Instant::now() + BACKOFF;
                    let mut hosts = pool.hosts.lock();
                    // Only replace an existing identity: a removed generation may never refill.
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

/// At most two distinct destinations, preferring an alternate address family.
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
        state.observe_and_upgrade(&target, &headers, egress, pool.clone(), Executor::new());
        assert!(state.alternatives.lock().is_empty());
        assert_eq!(state.probes.available_permits(), permits);
        assert!(pool.hosts.lock().is_empty());
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
        );
        assert!(!state.alternatives.lock()["key"].probing);
        state
            .alternatives
            .lock()
            .get_mut("key")
            .unwrap()
            .retry_after = Instant::now();
        state.observe_and_upgrade(&target, &headers, egress, pool.clone(), Executor::new());
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
