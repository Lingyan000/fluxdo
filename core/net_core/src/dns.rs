//! DNS resolver with DOH and HTTPS record support for ECH config retrieval

use crate::UpstreamProxyConfig;
use crate::client::HttpEgressClient;
use crate::ech_dns_policy::EchDnsPolicy;
use crate::egress::EgressConnector;
use crate::error::{NetError, Result};
use base64::Engine;
use base64::engine::general_purpose::{STANDARD, URL_SAFE_NO_PAD};
use bytes::Bytes;
use hickory_proto::rr::rdata::HTTPS;
use parking_lot::Mutex as FlightMutex;
use parking_lot::RwLock;
use rama::futures::StreamExt as _;
use rama::http::{Body, Request, header};
use rama::net::uri::Uri;
use std::future::Future;
use std::pin::Pin;
use std::sync::atomic::{AtomicU64, Ordering};
use std::{
    collections::{HashMap, HashSet},
    net::IpAddr,
    sync::{Arc, OnceLock, Weak},
    time::Duration,
};
#[cfg(test)]
use tokio::sync::Mutex;
use tokio::sync::{Mutex as AsyncMutex, RwLock as AsyncRwLock};
use tracing::{debug, info, warn};

type Flights = Arc<FlightMutex<HashMap<String, Arc<tokio::sync::watch::Sender<bool>>>>>;

/// 结果通知可在订阅前发生；查询 leader 被取消时也要清理并唤醒等待者。
struct FlightGuard {
    table: Flights,
    key: String,
    signal: Arc<tokio::sync::watch::Sender<bool>>,
}
impl Drop for FlightGuard {
    fn drop(&mut self) {
        let mut table = self.table.lock();
        if table
            .get(&self.key)
            .is_some_and(|v| Arc::ptr_eq(v, &self.signal))
        {
            table.remove(&self.key);
        }
        self.signal.send_replace(true);
    }
}

const FAMILY_GRACE: Duration = Duration::from_millis(100);

fn has_address(result: &Result<Option<hickory_proto::op::Message>>) -> bool {
    result
        .as_ref()
        .ok()
        .and_then(Option::as_ref)
        .is_some_and(|message| {
            message.answers().iter().any(|record| {
                matches!(
                    record.data(),
                    Some(hickory_proto::rr::RData::A(_) | hickory_proto::rr::RData::AAAA(_))
                )
            })
        })
}

/// 一次 DoH GET 的响应。
pub(crate) struct DohResponse {
    pub status: u16,
    pub content_type: Option<String>,
    pub body: Bytes,
}

/// DoH 查询的 HTTP 传输。
///
/// 抽成接口有两个用处：生产实现经 [`HttpEgressClient`] 出站（跟随代理、复用连接），
/// 单测注入内存实现即可验证查询名与缓存行为，不必为此起一套 TLS 服务。
pub(crate) trait DohTransport: Send + Sync {
    fn get<'a>(
        &'a self,
        url: String,
    ) -> Pin<Box<dyn Future<Output = Result<DohResponse>> + Send + 'a>>;

    /// 丢弃到 DoH 服务器的池化连接（网络切换后调用）。
    fn reset_connections<'a>(&'a self) -> Pin<Box<dyn Future<Output = ()> + Send + 'a>> {
        Box::pin(async {})
    }
}

impl DohTransport for HttpEgressClient {
    fn reset_connections<'a>(&'a self) -> Pin<Box<dyn Future<Output = ()> + Send + 'a>> {
        Box::pin(HttpEgressClient::reset_connections(self))
    }

    fn get<'a>(
        &'a self,
        url: String,
    ) -> Pin<Box<dyn Future<Output = Result<DohResponse>> + Send + 'a>> {
        Box::pin(async move {
            let request = Request::builder()
                .method("GET")
                .uri(url.as_str())
                .header(header::ACCEPT, "application/dns-message")
                .body(Body::empty())
                .map_err(|e| NetError::Dns(format!("Failed to build DoH request: {e}")))?;
            // 整体时限由调用方的 resolve_timeout 控制
            let response = self
                .send(request, None, None)
                .await
                .map_err(|e| NetError::Dns(format!("DoH GET failed: {e}")))?;
            let status = response.status().as_u16();
            let content_type = response
                .headers()
                .get(header::CONTENT_TYPE)
                .and_then(|value| value.to_str().ok())
                .map(str::to_owned);
            let mut stream = response.into_body().into_data_stream();
            let mut body = Vec::new();
            while let Some(chunk) = stream.next().await {
                let chunk =
                    chunk.map_err(|e| NetError::Dns(format!("DoH GET read failed: {e}")))?;
                body.extend_from_slice(&chunk);
            }
            let body = Bytes::from(body);
            Ok(DohResponse {
                status,
                content_type,
                body,
            })
        })
    }
}

/// 缓存条目上限
const MAX_CACHE_SIZE: usize = 1000;
/// TTL 下限（秒）
const MIN_TTL_SECS: u64 = 60;
/// TTL 上限（秒）
const MAX_TTL_SECS: u64 = 1800;
/// 默认 TTL（秒），无法获取时使用
const DEFAULT_TTL_SECS: u64 = 300;
/// 每隔多少次查询清理一次过期缓存
const CLEANUP_INTERVAL: u64 = 100;
/// 成功连通后的 host -> ip 粘性缓存时长
const STICKY_IP_TTL_SECS: u64 = 600;
/// ECH 负结果（确定无 ECH）缓存时长，取短值以便域名启用 ECH 后尽快生效
const ECH_NEGATIVE_TTL_SECS: u64 = 60;

type QueryGate = AsyncMutex<Option<Result<hickory_proto::op::Message>>>;

#[derive(Default)]
struct DohQueries {
    /// key 是完整 DoH URL，包含服务商、查询名和记录类型；不跨解析服务共享。
    cache: HashMap<String, CachedDohMessage>,
    flights: HashMap<String, Weak<QueryGate>>,
    generation: u64,
}

struct CachedDohMessage {
    message: hickory_proto::op::Message,
    stored: std::time::Instant,
    expires: std::time::Instant,
}

impl CachedDohMessage {
    fn remaining(&self) -> hickory_proto::op::Message {
        let age = self.stored.elapsed().as_secs().min(u32::MAX as u64) as u32;
        let mut message = self.message.clone();
        for record in message.answers_mut() {
            record.set_ttl(record.ttl().saturating_sub(age));
        }
        for record in message.name_servers_mut() {
            record.set_ttl(record.ttl().saturating_sub(age));
        }
        for record in message.additionals_mut() {
            record.set_ttl(record.ttl().saturating_sub(age));
        }
        message
    }
}

#[cfg(test)]
mod ech_query_tests {
    use super::*;
    use crate::ech_dns_policy::CLOUDFLARE_ECH_QUERY_NAME;
    use hickory_proto::{
        op::{Message, MessageType},
        rr::{
            Name, RData, Record, RecordType,
            rdata::{
                A, AAAA,
                svcb::{EchConfig, SVCB, SvcParamKey, SvcParamValue},
            },
        },
    };

    /// 内存 DoH 上游：记录收到的查询，按记录类型回固定答案。
    /// 公共 ECH 入口（cloudflare-ech.com）与真实域名回不同的 A 记录，便于分辨走了哪条。
    #[derive(Default)]
    struct FakeDoh {
        queries: Arc<Mutex<Vec<(String, RecordType)>>>,
        delay: Duration,
    }

    impl DohTransport for FakeDoh {
        fn get<'a>(
            &'a self,
            url: String,
        ) -> Pin<Box<dyn Future<Output = Result<DohResponse>> + Send + 'a>> {
            Box::pin(async move {
                let encoded = url.split("?dns=").nth(1).expect("query in url");
                let query = Message::from_vec(&URL_SAFE_NO_PAD.decode(encoded).unwrap()).unwrap();
                let question = query.queries()[0].clone();
                let name = question.name().to_ascii();
                let record_type = question.query_type();
                self.queries.lock().await.push((name.clone(), record_type));
                if !self.delay.is_zero() {
                    tokio::time::sleep(self.delay).await;
                }

                let is_public = name == "cloudflare-ech.com.";
                let data = match record_type {
                    RecordType::A => RData::A(A(if is_public {
                        [192, 0, 2, 10]
                    } else {
                        [192, 0, 2, 11]
                    }
                    .into())),
                    RecordType::AAAA => RData::AAAA(AAAA("2001:db8::10".parse().unwrap())),
                    RecordType::HTTPS => RData::HTTPS(HTTPS(SVCB::new(
                        1,
                        Name::root(),
                        vec![(
                            SvcParamKey::EchConfig,
                            SvcParamValue::EchConfig(EchConfig(vec![0, 3, 1, 2, 3])),
                        )],
                    ))),
                    _ => unreachable!(),
                };
                let mut response = Message::new();
                response
                    .set_id(query.id())
                    .set_message_type(MessageType::Response)
                    .add_query(question.clone())
                    .add_answer(Record::from_rdata(question.name().clone(), 120, data));
                Ok(DohResponse {
                    status: 200,
                    content_type: Some("application/dns-message".to_owned()),
                    body: Bytes::from(response.to_vec().unwrap()),
                })
            })
        }
    }

    #[test]
    fn only_forum_domains_use_public_ech_entry() {
        for host in [
            "linux.do",
            "www.linux.do",
            "a.b.linux.do",
            "LINUX.DO.",
            "ldstatic.com",
            "cdn.ldstatic.com",
            "CDN.LDSTATIC.COM.",
        ] {
            assert_eq!(
                EchDnsPolicy::default().query_name(host),
                CLOUDFLARE_ECH_QUERY_NAME,
                "{host}"
            );
        }
        for host in [
            "",
            "notlinux.do",
            "linux.do.example.com",
            "evil-ldstatic.com",
            "challenges.cloudflare.com",
            "cloudflare-ech.com",
            "example.com.",
            "127.0.0.1",
            "::1",
            "中文.example",
        ] {
            assert_eq!(EchDnsPolicy::default().query_name(host), host, "{host}");
        }
    }

    #[tokio::test]
    async fn shared_resolvers_isolate_caches_between_policies() {
        let enabled = EchDnsPolicy::default();
        let disabled = EchDnsPolicy {
            enabled: false,
            ..Default::default()
        };
        let a = DnsResolver::shared_with_policy(
            "https://127.0.0.1/dns-query",
            None,
            false,
            None,
            None,
            enabled.clone(),
        )
        .await
        .unwrap();
        a.record_host_success("linux.do", "192.0.2.10".parse().unwrap());
        let b = DnsResolver::shared_with_policy(
            "https://127.0.0.1/dns-query",
            None,
            false,
            None,
            None,
            disabled,
        )
        .await
        .unwrap();
        assert!(!Arc::ptr_eq(&a, &b));
        assert!(b.preferred_host_ip_cache.read().is_empty());
        let c = DnsResolver::shared_with_policy(
            "https://127.0.0.1/dns-query",
            None,
            false,
            None,
            None,
            enabled,
        )
        .await
        .unwrap();
        assert!(Arc::ptr_eq(&a, &c));
    }

    struct DelayedDoh {
        slow: RecordType,
        inner: FakeDoh,
    }
    impl DohTransport for DelayedDoh {
        fn get<'a>(
            &'a self,
            url: String,
        ) -> Pin<Box<dyn Future<Output = Result<DohResponse>> + Send + 'a>> {
            Box::pin(async move {
                let encoded = url.split("?dns=").nth(1).unwrap();
                let query = Message::from_vec(&URL_SAFE_NO_PAD.decode(encoded).unwrap()).unwrap();
                if query.queries()[0].query_type() == self.slow {
                    tokio::time::sleep(Duration::from_secs(30)).await;
                }
                self.inner.get(url).await
            })
        }
    }
    fn delayed_resolver(slow: RecordType) -> Arc<DnsResolver> {
        let mut r = DnsResolver::empty(false);
        r.doh_uri_ip = Some("https://doh.test/dns-query".parse().unwrap());
        r.transport = Some(Arc::new(DelayedDoh {
            slow,
            inner: FakeDoh::default(),
        }));
        Arc::new(r)
    }
    #[tokio::test]
    async fn usable_family_does_not_wait_for_stalled_other_family() {
        for slow in [RecordType::A, RecordType::AAAA] {
            let r = delayed_resolver(slow);
            let addresses =
                tokio::time::timeout(Duration::from_secs(1), r.lookup_ip("example.com"))
                    .await
                    .expect("不应等待慢族 30 秒")
                    .unwrap();
            assert!(!addresses.is_empty());
            assert!(r.ip_inflight.lock().is_empty());
        }
    }
    #[tokio::test]
    async fn cancelling_leader_releases_waiters_and_flight_slot() {
        let r = delayed_resolver(RecordType::AAAA);
        let task_r = r.clone();
        let leader = tokio::spawn(async move { task_r.lookup_ip("example.com").await });
        while r.ip_inflight.lock().is_empty() {
            tokio::task::yield_now().await;
        }
        let signal = r.ip_inflight.lock().get("example.com").unwrap().clone();
        leader.abort();
        let _ = leader.await;
        assert!(r.ip_inflight.lock().is_empty());
        // leader 已结束后才订阅，也不能丢失完成通知。
        tokio::time::timeout(Duration::from_millis(100), async {
            let _ = signal.subscribe().wait_for(|done| *done).await;
        })
        .await
        .unwrap();
    }

    // 模拟 DoH 上游，验证实际发出的三个查询及缓存，不依赖公网 DNS。
    #[tokio::test]
    async fn cdn_hosts_reuse_identical_doh_questions() {
        let transport = Arc::new(FakeDoh {
            delay: Duration::from_millis(10),
            ..Default::default()
        });
        let queries = transport.queries.clone();
        let endpoint: Uri = "https://doh.test/dns-query".parse().unwrap();
        let mut resolver = DnsResolver::empty(false);
        resolver.doh_uri_ip = Some(endpoint.clone());
        resolver.doh_uri_ech = Some(endpoint);
        resolver.transport = Some(transport);
        let hosts = [
            "linux.do",
            "cdn.ldstatic.com",
            "cdn2.ldstatic.com",
            "cdn3.ldstatic.com",
            "upload.linux.do",
            "avatar.linux.do",
        ];
        let results = rama::futures::future::join_all(
            hosts.iter().map(|host| resolver.lookup_host(host, false)),
        )
        .await;
        for (host, result) in hosts.iter().zip(results) {
            let result = result.unwrap();
            assert!(result.addrs.contains(&"192.0.2.10".parse().unwrap()));
            assert!(result.ech_config.is_some());
            assert!(resolver.ip_cache.read().contains_key(*host));
            assert!(resolver.ech_cache.read().contains_key(*host));
        }
        assert_eq!(
            queries.lock().await.len(),
            3,
            "同一入口的 A/AAAA/HTTPS 不应按图片域名重复查询"
        );
        resolver
            .lookup_host("cdn4.ldstatic.com", false)
            .await
            .unwrap();
        assert_eq!(
            queries.lock().await.len(),
            3,
            "相同 DNS 答案应按 TTL 跨域名复用"
        );
        resolver.lookup_host("linux.do", true).await.unwrap();
        assert_eq!(queries.lock().await.len(), 6, "强制刷新必须发出新查询");
    }

    struct FailingDoh(std::sync::atomic::AtomicUsize);
    impl DohTransport for FailingDoh {
        fn get<'a>(
            &'a self,
            _: String,
        ) -> Pin<Box<dyn Future<Output = Result<DohResponse>> + Send + 'a>> {
            Box::pin(async move {
                self.0.fetch_add(1, Ordering::Relaxed);
                tokio::time::sleep(Duration::from_millis(20)).await;
                Err(NetError::Dns("upstream unavailable".into()))
            })
        }
    }

    #[tokio::test]
    async fn identical_inflight_failures_are_shared_but_not_cached() {
        let transport = Arc::new(FailingDoh(std::sync::atomic::AtomicUsize::new(0)));
        let mut r = DnsResolver::empty(false);
        r.doh_uri_ech = Some("https://doh.test/dns-query".parse().unwrap());
        r.transport = Some(transport.clone());
        let results = rama::futures::future::join_all(
            ["linux.do", "cdn.ldstatic.com", "cdn3.ldstatic.com"]
                .into_iter()
                .map(|host| r.lookup_ech_config(host)),
        )
        .await;
        assert!(results.iter().all(Result::is_err));
        assert_eq!(transport.0.load(Ordering::Relaxed), 1);
        assert!(r.ech_negative_cache.read().is_empty());
        assert!(r.lookup_ech_config("linux.do").await.is_err());
        assert_eq!(transport.0.load(Ordering::Relaxed), 2);
    }

    #[tokio::test]
    async fn shared_answers_age_and_expire_and_keep_endpoints_separate() {
        let transport = Arc::new(FakeDoh::default());
        let queries = transport.queries.clone();
        let endpoint: Uri = "https://doh.test/dns-query".parse().unwrap();
        let other: Uri = "https://other.test/dns-query".parse().unwrap();
        let mut r = DnsResolver::empty(false);
        r.transport = Some(transport);
        r.doh_get_message_with(Some(&endpoint), "linux.do", RecordType::A)
            .await
            .unwrap();
        for value in r.queries.lock().cache.values_mut() {
            value.stored -= Duration::from_secs(10);
        }
        let cached = r
            .doh_get_message_with(Some(&endpoint), "cdn.ldstatic.com", RecordType::A)
            .await
            .unwrap()
            .unwrap();
        assert!(cached.answers()[0].ttl() <= 110);
        assert_eq!(queries.lock().await.len(), 1);
        r.doh_get_message_with(Some(&other), "linux.do", RecordType::A)
            .await
            .unwrap();
        assert_eq!(queries.lock().await.len(), 2);
        for value in r.queries.lock().cache.values_mut() {
            value.expires = std::time::Instant::now() - Duration::from_secs(1);
        }
        r.doh_get_message_with(Some(&endpoint), "linux.do", RecordType::A)
            .await
            .unwrap();
        assert_eq!(queries.lock().await.len(), 3);
    }

    struct InvalidDoh {
        inner: FakeDoh,
        mismatched: bool,
    }

    #[derive(Default)]
    struct FirstQueryStalls {
        calls: std::sync::atomic::AtomicUsize,
        started: tokio::sync::Notify,
        inner: FakeDoh,
    }
    impl DohTransport for FirstQueryStalls {
        fn get<'a>(
            &'a self,
            url: String,
        ) -> Pin<Box<dyn Future<Output = Result<DohResponse>> + Send + 'a>> {
            Box::pin(async move {
                if self.calls.fetch_add(1, Ordering::Relaxed) == 0 {
                    self.started.notify_one();
                    tokio::time::sleep(Duration::from_secs(30)).await;
                }
                self.inner.get(url).await
            })
        }
    }

    #[tokio::test]
    async fn cancelled_shared_query_owner_does_not_strand_other_hosts() {
        let transport = Arc::new(FirstQueryStalls::default());
        let mut r = DnsResolver::empty(false);
        r.doh_uri_ech = Some("https://doh.test/dns-query".parse().unwrap());
        r.transport = Some(transport.clone());
        let r = Arc::new(r);
        let first = {
            let r = r.clone();
            tokio::spawn(async move { r.lookup_ech_config("linux.do").await })
        };
        transport.started.notified().await;
        let second = {
            let r = r.clone();
            tokio::spawn(async move { r.lookup_ech_config("cdn.ldstatic.com").await })
        };
        tokio::time::timeout(Duration::from_secs(1), async {
            loop {
                if r.queries
                    .lock()
                    .flights
                    .values()
                    .any(|gate| gate.strong_count() >= 2)
                {
                    break;
                }
                tokio::task::yield_now().await;
            }
        })
        .await
        .unwrap();
        first.abort();
        let _ = first.await;
        assert!(
            tokio::time::timeout(Duration::from_secs(1), second)
                .await
                .unwrap()
                .unwrap()
                .unwrap()
                .is_some()
        );
        assert_eq!(transport.calls.load(Ordering::Relaxed), 2);
        assert!(r.ech_inflight.lock().is_empty());
    }
    impl DohTransport for InvalidDoh {
        fn get<'a>(
            &'a self,
            url: String,
        ) -> Pin<Box<dyn Future<Output = Result<DohResponse>> + Send + 'a>> {
            Box::pin(async move {
                let mut response = self.inner.get(url).await?;
                let mut message = Message::from_vec(&response.body).unwrap();
                if self.mismatched {
                    message.set_id(message.id().wrapping_add(1));
                } else {
                    message.set_response_code(hickory_proto::op::ResponseCode::ServFail);
                }
                response.body = Bytes::from(message.to_vec().unwrap());
                Ok(response)
            })
        }
    }

    #[tokio::test]
    async fn invalid_dns_response_is_not_reused_or_negative_cached() {
        for mismatched in [true, false] {
            let mut r = DnsResolver::empty(false);
            r.doh_uri_ech = Some("https://doh.test/dns-query".parse().unwrap());
            r.transport = Some(Arc::new(InvalidDoh {
                inner: FakeDoh::default(),
                mismatched,
            }));
            assert!(r.lookup_ech_config("linux.do").await.is_err());
            assert!(r.queries.lock().cache.is_empty());
            assert!(r.ech_negative_cache.read().is_empty());
        }
    }

    #[tokio::test]
    async fn forum_queries_share_public_entry_and_keep_original_host_cache() {
        let transport = Arc::new(FakeDoh::default());
        let queries = transport.queries.clone();
        let endpoint: Uri = "https://doh.test/dns-query".parse().unwrap();
        let mut resolver = DnsResolver::empty(false);
        resolver.doh_uri_ip = Some(endpoint.clone());
        resolver.doh_uri_ech = Some(endpoint);
        resolver.transport = Some(transport);

        let result = resolver.lookup_host("linux.do", false).await.unwrap();
        assert!(result.addrs.contains(&"192.0.2.10".parse().unwrap()));
        assert_eq!(result.ech_config.unwrap(), vec![0, 3, 1, 2, 3]);
        assert!(result.ttl <= Duration::from_secs(120));
        assert!(result.ttl > Duration::from_secs(110));
        assert!(result.preferred_ip.is_none());
        let mut types = queries.lock().await.clone();
        assert_eq!(types.len(), 3);
        assert!(types.iter().all(|(name, _)| name == "cloudflare-ech.com."));
        types.sort_by_key(|(_, kind)| u16::from(*kind));
        assert_eq!(
            types.iter().map(|(_, kind)| *kind).collect::<Vec<_>>(),
            vec![RecordType::A, RecordType::AAAA, RecordType::HTTPS]
        );
        assert!(resolver.ip_cache.read().contains_key("linux.do"));
        assert!(resolver.ech_cache.read().contains_key("linux.do"));

        resolver.record_host_success("linux.do", "192.0.2.10".parse().unwrap());
        assert!(
            resolver
                .lookup_host("linux.do", false)
                .await
                .unwrap()
                .preferred_ip
                .is_some()
        );
        assert_eq!(queries.lock().await.len(), 3);
        resolver.lookup_host("linux.do", true).await.unwrap();
        assert_eq!(queries.lock().await.len(), 6);

        let unrelated = resolver.lookup_host("example.com", false).await.unwrap();
        assert!(unrelated.addrs.contains(&"192.0.2.11".parse().unwrap()));
        assert!(
            queries.lock().await[6..]
                .iter()
                .all(|(name, _)| name == "example.com.")
        );
        resolver.ech_dns_policy = EchDnsPolicy {
            enabled: true,
            custom_domains: vec!["custom.example".into()],
        };
        resolver
            .lookup_host("cdn.custom.example", true)
            .await
            .unwrap();
        assert!(
            queries.lock().await[9..12]
                .iter()
                .all(|(name, _)| name == "cloudflare-ech.com.")
        );
        resolver.ech_dns_policy.enabled = false;
        let normal = resolver.lookup_host("linux.do", true).await.unwrap();
        assert!(normal.addrs.contains(&"192.0.2.11".parse().unwrap()));
        assert!(
            queries.lock().await[12..15]
                .iter()
                .all(|(name, _)| name == "linux.do.")
        );
    }
}

static SHARED_RESOLVERS: OnceLock<Arc<AsyncRwLock<HashMap<String, Arc<DnsResolver>>>>> =
    OnceLock::new();

/// DNS resolver with ECH config caching
pub struct DnsResolver {
    ech_dns_policy: EchDnsPolicy,
    // IP 解析用（A/AAAA 查询）
    doh_uri_ip: Option<Uri>,
    // ECH 配置用（HTTPS 记录查询）
    doh_uri_ech: Option<Uri>,
    /// DoH 查询自己的出口：解析 DoH 服务器用系统 DNS（不能再递归到自己），
    /// 但照样跟随上游 / 系统代理，代理环境下 DoH 才通。
    transport: Option<Arc<dyn DohTransport>>,
    queries: FlightMutex<DohQueries>,
    /// Cache for ECH configs (domain -> ECHConfigList)
    ech_cache: Arc<RwLock<HashMap<String, CachedEchConfig>>>,
    /// 确定无 ECH 的域名负缓存 (domain -> 过期时间)，避免每次 connect 重查 HTTPS 记录
    ech_negative_cache: Arc<RwLock<HashMap<String, std::time::Instant>>>,
    /// Cache for IP addresses
    ip_cache: Arc<RwLock<HashMap<String, CachedIpAddrs>>>,
    ech_inflight: Flights,
    ip_inflight: Flights,
    ip_rtt_cache: Arc<RwLock<HashMap<IpAddr, CachedIpRtt>>>,
    preferred_host_ip_cache: Arc<RwLock<HashMap<String, CachedPreferredHostIp>>>,
    prefer_ipv6: bool,
    resolve_timeout: Duration,
    /// 查询计数器，用于定期清理缓存
    query_count: AtomicU64,
}

pub struct LookupHostResult {
    pub addrs: Vec<IpAddr>,
    pub ech_config: Option<Vec<u8>>,
    pub preferred_ip: Option<IpAddr>,
    pub ttl: Duration,
}

#[derive(Default, Clone, Copy)]
pub struct DnsCacheStats {
    pub resolver_count: usize,
    pub host_count: usize,
    pub ip_count: usize,
    pub ech_count: usize,
    pub ech_negative_count: usize,
    pub ip_rtt_count: usize,
    pub preferred_ip_count: usize,
}

impl DnsCacheStats {
    pub fn total_entries(&self) -> usize {
        self.ip_count
            + self.ech_count
            + self.ech_negative_count
            + self.ip_rtt_count
            + self.preferred_ip_count
    }
}

pub struct DnsCacheRecord {
    pub host: String,
    pub kind: &'static str,
    pub values: Vec<String>,
    pub ttl_ms: u64,
}

struct CachedEchConfig {
    config: Vec<u8>,
    expires_at: std::time::Instant,
}

struct CachedIpAddrs {
    addrs: Vec<IpAddr>,
    expires_at: std::time::Instant,
}

struct CachedIpRtt {
    rtt_ms: u128,
    expires_at: std::time::Instant,
}

struct CachedPreferredHostIp {
    addr: IpAddr,
    expires_at: std::time::Instant,
}

/// HTTPS 记录中提取的 hint 信息
#[derive(Default)]
pub struct HttpsHints {
    pub ech_config: Option<Vec<u8>>,
    pub ipv4_hints: Vec<IpAddr>,
    pub ipv6_hints: Vec<IpAddr>,
}

static SHARED_ECH_DNS_POLICY: OnceLock<RwLock<EchDnsPolicy>> = OnceLock::new();

impl DnsResolver {
    /// 仅影响后续查询；已有连接持有自己的策略快照。
    pub async fn set_shared_ech_dns_policy(policy: EchDnsPolicy) {
        let policy = policy.normalized();
        {
            let mut current = SHARED_ECH_DNS_POLICY.get_or_init(Default::default).write();
            if *current == policy {
                return;
            }
            *current = policy;
        }
        Self::shared_resolver_holder().write().await.clear();
    }

    fn shared_cache_key(
        doh_url: &str,
        doh_url_ech: Option<&str>,
        prefer_ipv6: bool,
        upstream_proxy: Option<&UpstreamProxyConfig>,
        system_proxy: Option<&UpstreamProxyConfig>,
        ech_dns_policy: &EchDnsPolicy,
    ) -> String {
        // 代理也要进键：DoH 查询本身经代理出站，换了代理就不能复用旧解析器的连接
        let proxy_key = |proxy: Option<&UpstreamProxyConfig>| {
            proxy
                .map(UpstreamProxyConfig::cache_key)
                .unwrap_or_default()
        };
        format!(
            "{}|{}|{}|{}|{}|{}",
            doh_url,
            doh_url_ech.unwrap_or(""),
            if prefer_ipv6 { "v6" } else { "v4" },
            proxy_key(upstream_proxy),
            proxy_key(system_proxy),
            serde_json::to_string(ech_dns_policy).unwrap(),
        )
    }

    fn shared_resolver_holder() -> &'static Arc<AsyncRwLock<HashMap<String, Arc<DnsResolver>>>> {
        SHARED_RESOLVERS.get_or_init(|| Arc::new(AsyncRwLock::new(HashMap::new())))
    }

    pub async fn shared(
        doh_url: &str,
        doh_url_ech: Option<&str>,
        prefer_ipv6: bool,
        upstream_proxy: Option<UpstreamProxyConfig>,
        system_proxy: Option<UpstreamProxyConfig>,
    ) -> Result<Arc<Self>> {
        let policy = SHARED_ECH_DNS_POLICY
            .get_or_init(Default::default)
            .read()
            .clone();
        Self::shared_with_policy(
            doh_url,
            doh_url_ech,
            prefer_ipv6,
            upstream_proxy,
            system_proxy,
            policy,
        )
        .await
    }

    pub async fn shared_with_policy(
        doh_url: &str,
        doh_url_ech: Option<&str>,
        prefer_ipv6: bool,
        upstream_proxy: Option<UpstreamProxyConfig>,
        system_proxy: Option<UpstreamProxyConfig>,
        ech_dns_policy: EchDnsPolicy,
    ) -> Result<Arc<Self>> {
        let ech_dns_policy = ech_dns_policy.normalized();
        let normalized_doh_url_ech = doh_url_ech.filter(|value| *value != doh_url);
        let cache_key = Self::shared_cache_key(
            doh_url,
            normalized_doh_url_ech,
            prefer_ipv6,
            upstream_proxy.as_ref(),
            system_proxy.as_ref(),
            &ech_dns_policy,
        );

        {
            let guard = Self::shared_resolver_holder().read().await;
            if let Some(resolver) = guard.get(&cache_key) {
                return Ok(resolver.clone());
            }
        }

        let mut resolver = Self::new(
            doh_url,
            normalized_doh_url_ech,
            prefer_ipv6,
            upstream_proxy.clone(),
            system_proxy.clone(),
        )
        .await?;
        resolver.ech_dns_policy = ech_dns_policy;
        let resolver = Arc::new(resolver);

        let mut guard = Self::shared_resolver_holder().write().await;
        Ok(guard
            .entry(cache_key)
            .or_insert_with(|| resolver.clone())
            .clone())
    }

    pub async fn clear_shared_caches() {
        let guard = Self::shared_resolver_holder().read().await;
        for resolver in guard.values() {
            resolver.clear_all_caches();
        }
    }

    pub async fn shared_cache_stats() -> DnsCacheStats {
        let guard = Self::shared_resolver_holder().read().await;
        let mut stats = DnsCacheStats {
            resolver_count: guard.len(),
            ..Default::default()
        };
        for resolver in guard.values() {
            let item = resolver.cache_stats();
            stats.host_count += item.host_count;
            stats.ip_count += item.ip_count;
            stats.ech_count += item.ech_count;
            stats.ech_negative_count += item.ech_negative_count;
            stats.ip_rtt_count += item.ip_rtt_count;
            stats.preferred_ip_count += item.preferred_ip_count;
        }
        stats
    }

    /// 丢弃到 DoH 服务器的池化连接。DNS 缓存保留：答案与所在网络无关。
    pub async fn reset_connections(&self) {
        if let Some(transport) = &self.transport {
            transport.reset_connections().await;
        }
    }

    pub async fn shared_cache_records() -> Vec<DnsCacheRecord> {
        let guard = Self::shared_resolver_holder().read().await;
        let mut records = Vec::new();
        for resolver in guard.values() {
            records.extend(resolver.cache_records());
        }
        records
    }

    /// Create a new DNS resolver using Cloudflare DOH
    pub async fn new_cloudflare(prefer_ipv6: bool) -> Result<Self> {
        Self::new("cloudflare", None, prefer_ipv6, None, None).await
    }

    /// Create a new DNS resolver with custom DOH server URL
    ///
    /// Supported URL formats:
    /// - `https://dns.example.com/dns-query` - Custom DOH server
    /// - `cloudflare` - Use Cloudflare DOH
    /// - `google` - Use Google DOH
    /// - `quad9` - Use Quad9 DOH
    ///
    /// `doh_url_ech` specifies a separate DOH server for ECH config (HTTPS records).
    /// When None, ECH queries use the same server as DNS queries.
    pub async fn new(
        doh_url: &str,
        doh_url_ech: Option<&str>,
        prefer_ipv6: bool,
        upstream_proxy: Option<UpstreamProxyConfig>,
        system_proxy: Option<UpstreamProxyConfig>,
    ) -> Result<Self> {
        let mut resolver = Self::empty(prefer_ipv6);
        let uri = Self::parse_doh_url(doh_url)?;
        resolver.doh_uri_ip = Some(uri.clone());
        resolver.doh_uri_ech = match doh_url_ech {
            Some(ech_url) => Some(Self::parse_doh_url(ech_url)?),
            None => Some(uri),
        };
        // DoH 服务器自身的地址用系统 DNS 解析（dns=None），否则会递归回自己；
        // 代理照常跟随，两台 DoH 服务器共用一个客户端（按站点分连接池）。
        resolver.transport = Some(Arc::new(HttpEgressClient::new(
            Arc::new(EgressConnector::new(
                None,
                upstream_proxy,
                system_proxy,
                None,
                resolver.resolve_timeout,
            )),
            None,
        )));
        Ok(resolver)
    }

    /// 内置服务商名或自定义 DoH 地址 → DoH 查询 URL
    fn parse_doh_url(doh_url: &str) -> Result<Uri> {
        // Handle built-in providers
        let url_lower = doh_url.to_lowercase();
        let builtin = [
            (
                "cloudflare",
                "cloudflare-dns.com",
                "Cloudflare",
                "https://cloudflare-dns.com/dns-query",
            ),
            (
                "google",
                "dns.google",
                "Google",
                "https://dns.google/dns-query",
            ),
            (
                "quad9",
                "dns.quad9.net",
                "Quad9",
                "https://dns.quad9.net/dns-query",
            ),
        ];
        for (name, host, label, url) in builtin {
            if url_lower == name || url_lower.contains(host) {
                info!("Using {} DOH", label);
                return Ok(url.parse().unwrap());
            }
        }
        // 国内服务商：地址里出现其域名即用标准查询路径
        let domestic = [
            ("doh.pub", "DNSPod", "https://doh.pub/dns-query"),
            ("dns.pub", "Tencent", "https://dns.pub/dns-query"),
            ("alidns.com", "Alibaba", "https://dns.alidns.com/dns-query"),
        ];
        for (host, label, url) in domestic {
            if url_lower.contains(host) {
                info!("Using {} DOH", label);
                return Ok(url.parse().unwrap());
            }
        }

        let uri: Uri = doh_url
            .parse()
            .map_err(|e| NetError::InvalidUrl(format!("Invalid DOH URL '{}': {}", doh_url, e)))?;
        let scheme = uri
            .scheme_str()
            .ok_or_else(|| NetError::InvalidUrl(format!("Missing URL scheme: {}", doh_url)))?;
        if scheme != "https" {
            return Err(NetError::InvalidUrl(format!(
                "Unsupported DOH URL scheme '{}': {}",
                scheme, doh_url
            )));
        }
        if uri.host().is_none() {
            return Err(NetError::InvalidUrl(format!(
                "Missing host in DOH URL: {}",
                doh_url
            )));
        }
        Ok(uri)
    }

    /// 尚未配置 DoH 客户端的空解析器（由 [`Self::new`] 补齐）
    fn empty(prefer_ipv6: bool) -> Self {
        Self {
            ech_dns_policy: EchDnsPolicy::default(),
            doh_uri_ip: None,
            doh_uri_ech: None,
            transport: None,
            queries: FlightMutex::new(DohQueries::default()),
            ech_cache: Arc::new(RwLock::new(HashMap::new())),
            ech_negative_cache: Arc::new(RwLock::new(HashMap::new())),
            ip_cache: Arc::new(RwLock::new(HashMap::new())),
            ech_inflight: Arc::new(FlightMutex::new(HashMap::new())),
            ip_inflight: Arc::new(FlightMutex::new(HashMap::new())),
            ip_rtt_cache: Arc::new(RwLock::new(HashMap::new())),
            preferred_host_ip_cache: Arc::new(RwLock::new(HashMap::new())),
            prefer_ipv6,
            resolve_timeout: Duration::from_secs(5),
            query_count: AtomicU64::new(0),
        }
    }

    /// Lookup ECH config for a domain via HTTPS DNS record
    pub async fn lookup_ech_config(&self, domain: &str) -> Result<Option<Vec<u8>>> {
        // 定期清理过期缓存
        self.maybe_cleanup_caches();

        // Check cache first
        {
            let cache = self.ech_cache.read();
            if let Some(cached) = cache.get(domain) {
                if cached.expires_at > std::time::Instant::now() {
                    debug!("ECH config cache hit for {}", domain);
                    return Ok(Some(cached.config.clone()));
                }
            }
        }

        // 命中负缓存（确定无 ECH）则直接返回，避免重复查 HTTPS 记录
        if self.ech_negative_hit(domain) {
            debug!("ECH negative cache hit for {}", domain);
            return Ok(None);
        }

        let query_name = self.ech_dns_policy.query_name(domain);
        info!(
            "Looking up HTTPS record for ECH config: {} (query: {})",
            domain, query_name
        );

        let (notify, is_leader) = {
            let mut inflight = self.ech_inflight.lock();
            if let Some(existing) = inflight.get(domain) {
                (existing.clone(), false)
            } else {
                let notify = Arc::new(tokio::sync::watch::channel(false).0);
                inflight.insert(domain.to_string(), notify.clone());
                (notify, true)
            }
        };

        if !is_leader {
            let _ = notify.subscribe().wait_for(|done| *done).await;
            let cache = self.ech_cache.read();
            if let Some(cached) = cache.get(domain) {
                if cached.expires_at > std::time::Instant::now() {
                    debug!("ECH config cache hit for {}", domain);
                    return Ok(Some(cached.config.clone()));
                }
            }
            return Ok(None);
        }

        let _flight = FlightGuard {
            table: self.ech_inflight.clone(),
            key: domain.to_owned(),
            signal: notify,
        };
        self.lookup_ech_config_via_doh_get(domain).await
    }

    /// 从 HTTPS/SVCB 记录中提取 ECH 配置和 IP hint
    fn extract_hints_from_https(&self, https: &HTTPS) -> HttpsHints {
        use hickory_proto::rr::rdata::svcb::{SvcParamKey, SvcParamValue};

        let mut hints = HttpsHints::default();

        for (key, value) in https.svc_params().iter() {
            match key {
                SvcParamKey::EchConfig => {
                    if let SvcParamValue::EchConfig(ech_config) = value {
                        let bytes = Self::ensure_ech_config_list_len_prefix(ech_config.0.clone());
                        hints.ech_config = Some(bytes);
                    }
                }
                SvcParamKey::Ipv4Hint => {
                    if let SvcParamValue::Ipv4Hint(ipv4_hint) = value {
                        hints
                            .ipv4_hints
                            .extend(ipv4_hint.0.iter().map(|ip| IpAddr::V4(**ip)));
                    }
                }
                SvcParamKey::Ipv6Hint => {
                    if let SvcParamValue::Ipv6Hint(ipv6_hint) = value {
                        hints
                            .ipv6_hints
                            .extend(ipv6_hint.0.iter().map(|ip| IpAddr::V6(**ip)));
                    }
                }
                _ => {}
            }
        }

        hints
    }

    /// 兼容旧接口：仅提取 ECH 配置
    fn extract_ech_from_https(&self, https: &HTTPS) -> Option<Vec<u8>> {
        self.extract_hints_from_https(https).ech_config
    }

    fn ensure_ech_config_list_len_prefix(bytes: Vec<u8>) -> Vec<u8> {
        if bytes.len() >= 2 {
            let declared = u16::from_be_bytes([bytes[0], bytes[1]]) as usize;
            if declared == bytes.len().saturating_sub(2) {
                return bytes;
            }
        }

        if bytes.len() > u16::MAX as usize {
            warn!(
                "ECH config list too large ({} bytes), returning as-is",
                bytes.len()
            );
            return bytes;
        }

        let mut prefixed = Vec::with_capacity(bytes.len() + 2);
        let len = bytes.len() as u16;
        prefixed.extend_from_slice(&len.to_be_bytes());
        prefixed.extend_from_slice(&bytes);
        prefixed
    }

    /// Lookup IP addresses for a domain
    pub async fn lookup_ip(&self, domain: &str) -> Result<Vec<IpAddr>> {
        // 定期清理过期缓存
        self.maybe_cleanup_caches();

        // Check cache first
        {
            let cache = self.ip_cache.read();
            if let Some(cached) = cache.get(domain) {
                if cached.expires_at > std::time::Instant::now() {
                    debug!("IP cache hit for {}", domain);
                    return Ok(cached.addrs.clone());
                }
            }
        }

        let query_name = self.ech_dns_policy.query_name(domain);
        debug!("Looking up IP for {} (query: {})", domain, query_name);

        let (notify, is_leader) = {
            let mut inflight = self.ip_inflight.lock();
            if let Some(existing) = inflight.get(domain) {
                (existing.clone(), false)
            } else {
                let notify = Arc::new(tokio::sync::watch::channel(false).0);
                inflight.insert(domain.to_string(), notify.clone());
                (notify, true)
            }
        };

        if !is_leader {
            let _ = notify.subscribe().wait_for(|done| *done).await;
            let cache = self.ip_cache.read();
            if let Some(cached) = cache.get(domain) {
                if cached.expires_at > std::time::Instant::now() {
                    debug!("IP cache hit for {}", domain);
                    return Ok(cached.addrs.clone());
                }
            }
            return Err(NetError::Dns(format!("No IP found for {}", domain)));
        }

        let _flight = FlightGuard {
            table: self.ip_inflight.clone(),
            key: domain.to_owned(),
            signal: notify,
        };
        self.lookup_ip_via_doh_get(domain).await
    }

    /// 并行查询 ECH 配置和 IP 地址
    /// 如果 HTTPS 记录中包含 ipv4hint/ipv6hint，将 hint IP 合并到结果前面
    pub async fn lookup_ech_and_ip(&self, domain: &str) -> (Option<Vec<u8>>, Result<Vec<IpAddr>>) {
        let (ech_result, ip_result) =
            tokio::join!(self.lookup_ech_config(domain), self.lookup_ip(domain),);

        let ech_config = match ech_result {
            Ok(config) => config,
            Err(e) => {
                warn!("ECH lookup failed for {}: {}", domain, e);
                None
            }
        };

        // 尝试从 HTTPS 记录中获取 IP hint 并合并
        let ip_result = match ip_result {
            Ok(addrs) => Ok(addrs),
            Err(e) => Err(e),
        };

        (ech_config, ip_result)
    }

    pub async fn lookup_host(&self, domain: &str, force_refresh: bool) -> Result<LookupHostResult> {
        if force_refresh {
            self.clear_host_cache(domain);
        }

        let (ech_config, ip_result) = self.lookup_ech_and_ip(domain).await;
        let addrs = match ip_result {
            Ok(addrs) => self.order_addrs_by_rtt(addrs),
            Err(error) => {
                if ech_config.is_none() {
                    return Err(error);
                }
                warn!(
                    "IP lookup failed for {}, keeping ECH-only result: {}",
                    domain, error
                );
                Vec::new()
            }
        };
        // 只返回已经“实际连通验证过”的 sticky IP。
        // 冷启动时不要把排序后的首个地址直接提升为 preferred_ip，
        // 否则 query 模式会把一个未验证的单 IP 提前钉死给 rhttp，
        // 一旦这个边缘节点不稳定，就会持续触发连接重置/超时。
        let preferred_ip = self.preferred_host_ip_for_addrs(domain, &addrs);
        let ttl = self
            .remaining_ttl_for_host(domain)
            .unwrap_or_else(|| Duration::from_secs(DEFAULT_TTL_SECS));

        Ok(LookupHostResult {
            addrs,
            ech_config,
            preferred_ip,
            ttl,
        })
    }

    /// Set IPv6 preference
    pub fn set_prefer_ipv6(&mut self, prefer: bool) {
        self.prefer_ipv6 = prefer;
        // Clear IP cache when preference changes
        self.ip_cache.write().clear();
    }

    pub fn prefer_ipv6(&self) -> bool {
        self.prefer_ipv6
    }

    pub fn clear_host_cache(&self, domain: &str) {
        self.clear_query_cache();
        self.ip_cache.write().remove(domain);
        self.ech_cache.write().remove(domain);
        self.ech_negative_cache.write().remove(domain);
        self.preferred_host_ip_cache.write().remove(domain);
    }

    pub fn clear_all_caches(&self) {
        self.clear_query_cache();
        self.ip_cache.write().clear();
        self.ech_cache.write().clear();
        self.ech_negative_cache.write().clear();
        self.ip_rtt_cache.write().clear();
        self.preferred_host_ip_cache.write().clear();
    }

    fn clear_query_cache(&self) {
        let mut queries = self.queries.lock();
        queries.generation = queries.generation.wrapping_add(1);
        queries.cache.clear();
        queries.flights.clear();
    }

    pub fn cache_stats(&self) -> DnsCacheStats {
        let now = std::time::Instant::now();
        let mut hosts = HashSet::new();

        let ip_count = {
            let cache = self.ip_cache.read();
            cache
                .iter()
                .filter(|(_, entry)| entry.expires_at > now)
                .map(|(domain, _)| {
                    hosts.insert(domain.clone());
                })
                .count()
        };
        let ech_count = {
            let cache = self.ech_cache.read();
            cache
                .iter()
                .filter(|(_, entry)| entry.expires_at > now)
                .map(|(domain, _)| {
                    hosts.insert(domain.clone());
                })
                .count()
        };
        let ech_negative_count = {
            let cache = self.ech_negative_cache.read();
            cache
                .iter()
                .filter(|(_, expires_at)| **expires_at > now)
                .map(|(domain, _)| {
                    hosts.insert(domain.clone());
                })
                .count()
        };
        let preferred_ip_count = {
            let cache = self.preferred_host_ip_cache.read();
            cache
                .iter()
                .filter(|(_, entry)| entry.expires_at > now)
                .map(|(domain, _)| {
                    hosts.insert(domain.clone());
                })
                .count()
        };

        DnsCacheStats {
            resolver_count: 1,
            host_count: hosts.len(),
            ip_count,
            ech_count,
            ech_negative_count,
            ip_rtt_count: self
                .ip_rtt_cache
                .read()
                .values()
                .filter(|entry| entry.expires_at > now)
                .count(),
            preferred_ip_count,
        }
    }

    pub fn cache_records(&self) -> Vec<DnsCacheRecord> {
        let now = std::time::Instant::now();
        let mut records = Vec::new();

        {
            let cache = self.ip_cache.read();
            for (host, entry) in cache.iter() {
                if entry.expires_at <= now {
                    continue;
                }
                records.push(DnsCacheRecord {
                    host: host.clone(),
                    kind: "ip",
                    values: entry.addrs.iter().map(|addr| addr.to_string()).collect(),
                    ttl_ms: Self::remaining_ttl_ms(entry.expires_at, now),
                });
            }
        }

        {
            let cache = self.ech_cache.read();
            for (host, entry) in cache.iter() {
                if entry.expires_at <= now {
                    continue;
                }
                records.push(DnsCacheRecord {
                    host: host.clone(),
                    kind: "ech",
                    values: vec![STANDARD.encode(entry.config.as_slice())],
                    ttl_ms: Self::remaining_ttl_ms(entry.expires_at, now),
                });
            }
        }

        {
            let cache = self.ech_negative_cache.read();
            for (host, expires_at) in cache.iter() {
                if *expires_at <= now {
                    continue;
                }
                records.push(DnsCacheRecord {
                    host: host.clone(),
                    kind: "ech_negative",
                    values: Vec::new(),
                    ttl_ms: Self::remaining_ttl_ms(*expires_at, now),
                });
            }
        }

        {
            let cache = self.preferred_host_ip_cache.read();
            for (host, entry) in cache.iter() {
                if entry.expires_at <= now {
                    continue;
                }
                records.push(DnsCacheRecord {
                    host: host.clone(),
                    kind: "preferred_ip",
                    values: vec![entry.addr.to_string()],
                    ttl_ms: Self::remaining_ttl_ms(entry.expires_at, now),
                });
            }
        }

        records.sort_by(|a, b| a.host.cmp(&b.host).then(a.kind.cmp(b.kind)));
        records
    }

    fn remaining_ttl_ms(expires_at: std::time::Instant, now: std::time::Instant) -> u64 {
        let ms = expires_at
            .checked_duration_since(now)
            .unwrap_or_default()
            .as_millis();
        ms.min(u64::MAX as u128) as u64
    }

    pub fn preferred_host_ip(&self, domain: &str) -> Option<IpAddr> {
        let now = std::time::Instant::now();
        self.preferred_host_ip_cache
            .read()
            .get(domain)
            .filter(|entry| entry.expires_at > now)
            .map(|entry| entry.addr)
    }

    pub fn preferred_host_ip_for_addrs(&self, domain: &str, addrs: &[IpAddr]) -> Option<IpAddr> {
        let preferred = self.preferred_host_ip(domain)?;
        if addrs.iter().any(|addr| *addr == preferred) {
            Some(preferred)
        } else {
            self.clear_preferred_host_ip(domain);
            None
        }
    }

    pub fn record_host_success(&self, domain: &str, addr: IpAddr) {
        self.preferred_host_ip_cache.write().insert(
            domain.to_string(),
            CachedPreferredHostIp {
                addr,
                expires_at: std::time::Instant::now() + Duration::from_secs(STICKY_IP_TTL_SECS),
            },
        );
    }

    pub fn record_host_preference(&self, domain: &str, addr: IpAddr, ttl: Duration) {
        let ttl = if ttl > Duration::from_secs(STICKY_IP_TTL_SECS) {
            Duration::from_secs(STICKY_IP_TTL_SECS)
        } else if ttl < Duration::from_secs(MIN_TTL_SECS) {
            Duration::from_secs(MIN_TTL_SECS)
        } else {
            ttl
        };

        self.preferred_host_ip_cache.write().insert(
            domain.to_string(),
            CachedPreferredHostIp {
                addr,
                expires_at: std::time::Instant::now() + ttl,
            },
        );
    }

    pub fn clear_preferred_host_ip(&self, domain: &str) {
        self.preferred_host_ip_cache.write().remove(domain);
    }

    pub fn record_ip_rtt(&self, addr: IpAddr, rtt: Duration) {
        let cached = CachedIpRtt {
            rtt_ms: rtt.as_millis(),
            expires_at: std::time::Instant::now() + Duration::from_secs(600),
        };
        self.ip_rtt_cache.write().insert(addr, cached);
    }

    pub fn order_addrs_by_rtt(&self, mut addrs: Vec<IpAddr>) -> Vec<IpAddr> {
        let now = std::time::Instant::now();
        let cache = self.ip_rtt_cache.read();
        addrs.sort_by_key(|addr| {
            let rtt = cache
                .get(addr)
                .filter(|entry| entry.expires_at > now)
                .map(|entry| entry.rtt_ms)
                .unwrap_or(u128::MAX);
            let family_bias = if self.prefer_ipv6 {
                if addr.is_ipv6() { 0 } else { 1 }
            } else {
                if addr.is_ipv4() { 0 } else { 1 }
            };
            (rtt, family_bias)
        });
        addrs
    }

    /// 写入 IP 缓存，超过上限时淘汰过期条目
    fn put_ip_cache(&self, domain: &str, addrs: Vec<IpAddr>, ttl: Duration) {
        let mut cache = self.ip_cache.write();
        cache.insert(
            domain.to_string(),
            CachedIpAddrs {
                addrs,
                expires_at: std::time::Instant::now() + ttl,
            },
        );
        if cache.len() > MAX_CACHE_SIZE {
            Self::evict_expired(&mut cache);
        }
    }

    /// 写入 ECH 缓存，超过上限时淘汰过期条目
    fn put_ech_cache(&self, domain: &str, config: Vec<u8>, ttl: Duration) {
        // 找到 ECH，清除可能存在的负缓存
        self.ech_negative_cache.write().remove(domain);
        let mut cache = self.ech_cache.write();
        cache.insert(
            domain.to_string(),
            CachedEchConfig {
                config,
                expires_at: std::time::Instant::now() + ttl,
            },
        );
        if cache.len() > MAX_CACHE_SIZE {
            Self::evict_expired_ech(&mut cache);
        }
    }

    /// 写入 ECH 负缓存（确定无 ECH 时调用）
    fn put_ech_negative(&self, domain: &str) {
        let expires_at = std::time::Instant::now() + Duration::from_secs(ECH_NEGATIVE_TTL_SECS);
        let mut cache = self.ech_negative_cache.write();
        cache.insert(domain.to_string(), expires_at);
        if cache.len() > MAX_CACHE_SIZE {
            let now = std::time::Instant::now();
            cache.retain(|_, exp| *exp > now);
        }
    }

    /// 查询 ECH 负缓存是否命中且未过期
    fn ech_negative_hit(&self, domain: &str) -> bool {
        let now = std::time::Instant::now();
        self.ech_negative_cache
            .read()
            .get(domain)
            .map(|exp| *exp > now)
            .unwrap_or(false)
    }

    /// 淘汰过期 IP 缓存条目
    fn evict_expired(cache: &mut HashMap<String, CachedIpAddrs>) {
        let now = std::time::Instant::now();
        cache.retain(|_, v| v.expires_at > now);
        // 仍然超限，淘汰最早过期的条目
        if cache.len() > MAX_CACHE_SIZE {
            let remove_count = cache.len() - MAX_CACHE_SIZE + MAX_CACHE_SIZE / 10;
            let mut entries: Vec<_> = cache
                .iter()
                .map(|(k, v)| (k.clone(), v.expires_at))
                .collect();
            entries.sort_by_key(|(_, exp)| *exp);
            for (key, _) in entries.into_iter().take(remove_count) {
                cache.remove(&key);
            }
        }
    }

    /// 淘汰过期 ECH 缓存条目
    fn evict_expired_ech(cache: &mut HashMap<String, CachedEchConfig>) {
        let now = std::time::Instant::now();
        cache.retain(|_, v| v.expires_at > now);
        if cache.len() > MAX_CACHE_SIZE {
            let remove_count = cache.len() - MAX_CACHE_SIZE + MAX_CACHE_SIZE / 10;
            let mut entries: Vec<_> = cache
                .iter()
                .map(|(k, v)| (k.clone(), v.expires_at))
                .collect();
            entries.sort_by_key(|(_, exp)| *exp);
            for (key, _) in entries.into_iter().take(remove_count) {
                cache.remove(&key);
            }
        }
    }

    /// 定期清理所有过期缓存
    fn maybe_cleanup_caches(&self) {
        let count = self.query_count.fetch_add(1, Ordering::Relaxed);
        if count % CLEANUP_INTERVAL != 0 {
            return;
        }
        let now = std::time::Instant::now();
        self.ip_cache.write().retain(|_, v| v.expires_at > now);
        self.ech_cache.write().retain(|_, v| v.expires_at > now);
        self.ech_negative_cache.write().retain(|_, exp| *exp > now);
        self.ip_rtt_cache.write().retain(|_, v| v.expires_at > now);
        self.preferred_host_ip_cache
            .write()
            .retain(|_, v| v.expires_at > now);
    }

    fn remaining_ttl_for_host(&self, domain: &str) -> Option<Duration> {
        let now = std::time::Instant::now();
        let ip_ttl = self
            .ip_cache
            .read()
            .get(domain)
            .and_then(|entry| entry.expires_at.checked_duration_since(now));
        let ech_ttl = self
            .ech_cache
            .read()
            .get(domain)
            .and_then(|entry| entry.expires_at.checked_duration_since(now));

        match (ip_ttl, ech_ttl) {
            (Some(ip), Some(ech)) => Some(ip.min(ech)),
            (Some(ip), None) => Some(ip),
            (None, Some(ech)) => Some(ech),
            (None, None) => None,
        }
    }

    /// 将 TTL 秒数限制在合理范围内
    fn clamp_ttl(ttl_secs: u32) -> Duration {
        let clamped = (ttl_secs as u64).clamp(MIN_TTL_SECS, MAX_TTL_SECS);
        Duration::from_secs(clamped)
    }

    async fn lookup_ech_config_via_doh_get(&self, domain: &str) -> Result<Option<Vec<u8>>> {
        let start = std::time::Instant::now();
        let Some(message) = self
            .doh_get_message_with(
                self.doh_uri_ech.as_ref(),
                domain,
                hickory_proto::rr::RecordType::HTTPS,
            )
            .await?
        else {
            return Ok(None);
        };

        for record in message.answers() {
            if let Some(hickory_proto::rr::RData::HTTPS(https)) = record.data() {
                if let Some(ech_config) = self.extract_ech_from_https(https) {
                    let ttl = Self::clamp_ttl(record.ttl());
                    self.put_ech_cache(domain, ech_config.clone(), ttl);
                    debug!(
                        "ECH DoH GET lookup succeeded for {} in {} ms (TTL: {}s)",
                        domain,
                        start.elapsed().as_millis(),
                        ttl.as_secs(),
                    );
                    return Ok(Some(ech_config));
                }
            }
        }

        // 收到响应但记录中没有 ECH 参数：确定无 ECH，写入负缓存
        self.put_ech_negative(domain);
        Ok(None)
    }

    async fn lookup_ip_via_doh_get(&self, domain: &str) -> Result<Vec<IpAddr>> {
        let start = std::time::Instant::now();
        let mut addrs = Vec::new();
        let mut min_ttl = MAX_TTL_SECS as u32;

        let a = self.doh_get_message_with(
            self.doh_uri_ip.as_ref(),
            domain,
            hickory_proto::rr::RecordType::A,
        );
        let aaaa = self.doh_get_message_with(
            self.doh_uri_ip.as_ref(),
            domain,
            hickory_proto::rr::RecordType::AAAA,
        );
        tokio::pin!(a, aaaa);
        // 有可用地址后仅短暂等待另一族；空答案/失败不能抢先中止有效地址查询。
        let (a_result, aaaa_result) = tokio::select! {
            first = &mut a => {
                let other = if has_address(&first) {
                    tokio::time::timeout(FAMILY_GRACE, &mut aaaa).await.unwrap_or(Ok(None))
                } else { aaaa.await };
                (first, other)
            },
            first = &mut aaaa => {
                let other = if has_address(&first) {
                    tokio::time::timeout(FAMILY_GRACE, &mut a).await.unwrap_or(Ok(None))
                } else { a.await };
                (other, first)
            },
        };

        if let Ok(Some(message)) = a_result {
            for record in message.answers() {
                if let Some(hickory_proto::rr::RData::A(a)) = record.data() {
                    addrs.push(IpAddr::V4(a.0));
                    min_ttl = min_ttl.min(record.ttl());
                }
            }
        }

        if let Ok(Some(message)) = aaaa_result {
            for record in message.answers() {
                if let Some(hickory_proto::rr::RData::AAAA(aaaa)) = record.data() {
                    addrs.push(IpAddr::V6(aaaa.0));
                    min_ttl = min_ttl.min(record.ttl());
                }
            }
        }

        if addrs.is_empty() {
            return Err(NetError::Dns(format!("No IP found for {}", domain)));
        }

        if self.prefer_ipv6 {
            addrs.sort_by_key(|a| if a.is_ipv6() { 0 } else { 1 });
        } else {
            addrs.sort_by_key(|a| if a.is_ipv4() { 0 } else { 1 });
        }

        let ttl = Self::clamp_ttl(min_ttl);
        self.put_ip_cache(domain, addrs.clone(), ttl);

        debug!(
            "IP DoH GET lookup succeeded for {} in {} ms (TTL: {}s)",
            domain,
            start.elapsed().as_millis(),
            ttl.as_secs(),
        );
        Ok(addrs)
    }

    async fn doh_get_message_with(
        &self,
        uri: Option<&Uri>,
        domain: &str,
        record_type: hickory_proto::rr::RecordType,
    ) -> Result<Option<hickory_proto::op::Message>> {
        let (Some(_), Some(uri)) = (self.transport.as_ref(), uri) else {
            return Ok(None);
        };
        let start = std::time::Instant::now();

        use hickory_proto::op::{Edns, Message, Query};
        use hickory_proto::rr::Name;
        use std::str::FromStr;

        // 仅替换 DNS 查询名；缓存、TLS SNI 和证书校验仍使用真实目标域名。
        let query_name = self.ech_dns_policy.query_name(domain);
        let fqdn = if query_name.ends_with('.') {
            query_name.to_string()
        } else {
            format!("{}.", query_name)
        };
        let name = Name::from_str(&fqdn)
            .map_err(|e| NetError::Dns(format!("Invalid domain {}: {}", domain, e)))?;

        let mut request = Message::new();
        request.add_query(Query::query(name, record_type));
        request.set_recursion_desired(true);
        let mut edns = Edns::new();
        edns.set_version(0);
        edns.set_max_payload(1232);
        *request.extensions_mut() = Some(edns);

        let bytes = request
            .to_vec()
            .map_err(|e| NetError::Dns(format!("Failed to encode DNS query: {}", e)))?;
        let encoded = URL_SAFE_NO_PAD.encode(bytes);

        let scheme = uri.scheme_str().unwrap_or("https");
        let authority = uri
            .authority()
            .ok_or_else(|| NetError::InvalidUrl("Missing DOH authority".to_string()))?;
        let path = uri
            .path()
            .map_or_else(|| "/".to_owned(), |path| path.as_encoded_str().into_owned());
        let url = format!("{}://{}{}?dns={}", scheme, authority, path, encoded);

        let (gate, generation) = {
            let mut queries = self.queries.lock();
            if let Some(cached) = queries.cache.get(&url)
                && cached.expires > std::time::Instant::now()
            {
                debug!("DoH answer reused for {domain} {record_type} (query: {query_name})");
                return Ok(Some(cached.remaining()));
            }
            queries.flights.retain(|_, gate| gate.strong_count() > 0);
            let gate = queries
                .flights
                .get(&url)
                .and_then(Weak::upgrade)
                .unwrap_or_else(|| {
                    let gate = Arc::new(AsyncMutex::new(None));
                    queries.flights.insert(url.clone(), Arc::downgrade(&gate));
                    gate
                });
            (gate, queries.generation)
        };
        // 同批调用共享成功或失败；leader 被取消会释放锁，等待者能重新查询。
        // 表里只持弱引用，失败不会变成长时间负缓存，也不会串行重试同一批失败。
        let mut shared_result = gate.lock().await;
        if let Some(result) = shared_result.as_ref() {
            return result
                .as_ref()
                .map(|message| Some(message.clone()))
                .map_err(NetError::replicate);
        }
        let result = self.fetch_doh_message(&url, &request).await;
        if let Ok(message) = &result {
            let ttl = message.answers().iter().map(|r| r.ttl()).min().unwrap_or(0) as u64;
            if ttl > 0 {
                let now = std::time::Instant::now();
                let mut queries = self.queries.lock();
                // 清缓存期间完成的旧查询不得重新填入公共缓存。
                if queries.generation == generation {
                    queries.cache.retain(|_, entry| entry.expires > now);
                    if queries.cache.len() >= MAX_CACHE_SIZE
                        && let Some(oldest) = queries
                            .cache
                            .iter()
                            .min_by_key(|(_, entry)| entry.expires)
                            .map(|(key, _)| key.clone())
                    {
                        queries.cache.remove(&oldest);
                    }
                    queries.cache.insert(
                        url,
                        CachedDohMessage {
                            message: message.clone(),
                            stored: now,
                            expires: now + Duration::from_secs(ttl.min(MAX_TTL_SECS)),
                        },
                    );
                }
            }
        }
        *shared_result = Some(result.as_ref().cloned().map_err(NetError::replicate));
        debug!(
            "DoH GET {domain} {record_type} (query: {query_name}) completed in {} ms",
            start.elapsed().as_millis()
        );
        result.map(Some)
    }

    async fn fetch_doh_message(
        &self,
        url: &str,
        request: &hickory_proto::op::Message,
    ) -> Result<hickory_proto::op::Message> {
        let transport = self
            .transport
            .as_ref()
            .expect("transport checked by caller");

        // RFC 8484 的 GET 形式：查询放在 ?dns= 里，便于 DoH 服务端与 CDN 缓存
        let response = tokio::time::timeout(self.resolve_timeout, transport.get(url.to_owned()))
            .await
            .map_err(|_| NetError::Timeout)??;

        if !(200..300).contains(&response.status) {
            return Err(NetError::Dns(format!(
                "DoH GET http error: {}",
                response.status
            )));
        }
        if let Some(content_type) = response.content_type.as_deref()
            && !content_type.starts_with("application/dns-message")
        {
            return Err(NetError::Dns(format!(
                "Unsupported Content-Type: {content_type}"
            )));
        }
        let body = response.body;

        let message = hickory_proto::op::Message::from_vec(&body)
            .map_err(|e| NetError::Dns(format!("Invalid DNS response: {}", e)))?;

        if message.message_type() != hickory_proto::op::MessageType::Response
            || message.id() != request.id()
            || message.op_code() != request.op_code()
            || message.queries() != request.queries()
            || message.truncated()
        {
            return Err(NetError::Dns("Mismatched or truncated DoH response".into()));
        }
        if message.response_code() != hickory_proto::op::ResponseCode::NoError {
            return Err(NetError::Dns(format!(
                "DoH DNS error: {}",
                message.response_code()
            )));
        }
        Ok(message)
    }
}
