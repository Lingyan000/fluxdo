//! 日志出口：核心日志除了进系统日志（logcat / stderr），还交给宿主写进应用日志。
//!
//! 用户在应用里导出日志排查网络问题时，建连、选址、DNS、探针这些核心内部过程
//! 必须在里面——只进 logcat 的话，桌面端和 iOS 上的用户根本拿不到。

use std::collections::HashMap;
use std::fmt::Write as _;
use std::sync::Arc;
use std::sync::atomic::{AtomicU8, AtomicU64, Ordering};

use crate::host_callback::HostCallback;
use parking_lot::Mutex;
use tracing::field::{Field, Visit};
use tracing::{Event, Level, Subscriber};
use tracing_subscriber::layer::Context;
use tracing_subscriber::{Layer, registry::LookupSpan};

/// 日志回调：`(级别, 载荷指针, 载荷长度)`。载荷是 JSON
/// `{"target":"fluxdo_net::client","message":"..."}`，缓冲区由宿主经
/// `fluxdo_net_buffer_free` 归还。级别：1 error、2 warn、3 info、4 debug。
pub type LogCallback = extern "C" fn(u8, *mut u8, usize);

// 锁定的 TLS 依赖在这个模块以 debug 记录平台/证书策略拒绝。
const CERTIFICATE_VERIFY_TARGET: &str = "rama_tls_boring::client::verify";

static CALLBACK: HostCallback<LogCallback> = HostCallback::new();
static LOG_HOSTS: Mutex<Option<HashMap<u64, Arc<HostCallback<LogCallback>>>>> = Mutex::new(None);
static NEXT_LOG_HOST_ID: AtomicU64 = AtomicU64::new(1);
/// 交给宿主的最低级别，取值同回调级别；0 表示不交给宿主。
static HOST_LEVEL: AtomicU8 = AtomicU8::new(3);

pub fn set_callback(callback: Option<LogCallback>) {
    CALLBACK.set(callback);
}

/// 为单个 Dart isolate 注册独立的日志回调，返回宿主 id（>= 1），不覆盖同进程其他宿主。
pub fn register_callback(callback: LogCallback) -> u64 {
    let host_id = NEXT_LOG_HOST_ID.fetch_add(1, Ordering::Relaxed);
    LOG_HOSTS
        .lock()
        .get_or_insert_with(HashMap::new)
        .insert(host_id, Arc::new(HostCallback::with_value(callback)));
    host_id
}

/// 注销指定宿主的日志回调，并等待该宿主正在执行的投递返回。
pub fn unregister_callback(host_id: u64) {
    if host_id == 0 {
        return;
    }
    let removed = LOG_HOSTS
        .lock()
        .as_mut()
        .and_then(|map| map.remove(&host_id));
    if let Some(entry) = removed {
        entry.set(None);
    }
}

/// 注销全部日志回调（供原生宿主在热重启前统一清理）。
pub fn clear_all_callbacks() {
    CALLBACK.set(None);
    let removed: Vec<_> = {
        let mut guard = LOG_HOSTS.lock();
        guard
            .as_mut()
            .map(|map| map.drain().map(|(_, entry)| entry).collect())
            .unwrap_or_default()
    };
    for entry in removed {
        entry.set(None);
    }
}

fn deliver_payload(target: &HostCallback<LogCallback>, code: u8, payload: Vec<u8>) {
    target.with(|callback| {
        let mut payload = payload.into_boxed_slice();
        let (ptr, len) = (payload.as_mut_ptr(), payload.len());
        std::mem::forget(payload);
        callback(code, ptr, len);
    });
}

pub fn set_host_level(level: u8) {
    HOST_LEVEL.store(level.min(4), Ordering::Relaxed);
}

fn level_code(level: &Level) -> u8 {
    match *level {
        Level::ERROR => 1,
        Level::WARN => 2,
        Level::INFO => 3,
        _ => 4,
    }
}

/// 全局过滤配置与宿主导出共用；测试也必须经过这一层，避免只测回调漏掉上游过滤。
pub(crate) fn logging_filter() -> tracing_subscriber::EnvFilter {
    use tracing_subscriber::{EnvFilter, filter::LevelFilter};
    EnvFilter::builder()
        .with_default_directive(LevelFilter::WARN.into())
        .from_env_lossy()
        .add_directive("fluxdo_net=debug".parse().unwrap())
        .add_directive("rama=warn".parse().unwrap())
        .add_directive(format!("{CERTIFICATE_VERIFY_TARGET}=debug").parse().unwrap())
}

/// 把事件转交宿主的 tracing 层。
pub struct HostLayer;

impl<S: Subscriber + for<'a> LookupSpan<'a>> Layer<S> for HostLayer {
    fn on_new_span(
        &self,
        attrs: &tracing::span::Attributes<'_>,
        id: &tracing::span::Id,
        ctx: Context<'_, S>,
    ) {
        let mut visitor = MessageVisitor::default();
        attrs.record(&mut visitor);
        if let Some(span) = ctx.span(id) {
            span.extensions_mut().insert(visitor.values);
        }
    }
    fn on_event(&self, event: &Event<'_>, ctx: Context<'_, S>) {
        let metadata = event.metadata();
        // 只提升带验证名称与错误的证书拒绝事件，其余依赖 debug 仍遵循详细日志开关。
        let certificate_rejection = metadata.target() == CERTIFICATE_VERIFY_TARGET
            && *metadata.level() == Level::DEBUG
            && metadata.fields().field("server_name").is_some()
            && metadata.fields().field("err").is_some();
        let code = if certificate_rejection { 2 } else { level_code(metadata.level()) };
        if code > HOST_LEVEL.load(Ordering::Relaxed) {
            return;
        }
        let hosts: Vec<Arc<HostCallback<LogCallback>>> = {
            let guard = LOG_HOSTS.lock();
            guard
                .as_ref()
                .map(|map| map.values().cloned().collect())
                .unwrap_or_default()
        };
        let has_legacy = CALLBACK.is_set();
        if !has_legacy && hosts.is_empty() {
            return;
        }
        let mut visitor = MessageVisitor::default();
        event.record(&mut visitor);
        let mut fields = serde_json::Map::new();
        if let Some(scope) = ctx.event_scope(event) {
            for span in scope.from_root() {
                if let Some(values) = span
                    .extensions()
                    .get::<serde_json::Map<String, serde_json::Value>>()
                {
                    fields.extend(values.clone());
                }
            }
        }
        fields.extend(visitor.values.clone());
        if certificate_rejection {
            fields.insert("event".into(), "tls_certificate_rejected".into());
        }
        let payload = serde_json::json!({
            "target": metadata.target(),
            "fields": fields,
            "message": visitor.finish(),
        })
        .to_string();
        if hosts.is_empty() {
            deliver_payload(&CALLBACK, code, payload.into_bytes());
            return;
        }
        if !has_legacy && hosts.len() == 1 {
            deliver_payload(&hosts[0], code, payload.into_bytes());
            return;
        }
        let bytes = payload.into_bytes();
        if has_legacy {
            deliver_payload(&CALLBACK, code, bytes.clone());
        }
        for host in &hosts {
            deliver_payload(host, code, bytes.clone());
        }
    }
}

/// 拼出 `message key=value ...`，与 fmt 层的默认输出一致。
#[derive(Default)]
struct MessageVisitor {
    message: String,
    fields: String,
    values: serde_json::Map<String, serde_json::Value>,
}

impl MessageVisitor {
    fn finish(self) -> String {
        if self.fields.is_empty() {
            self.message
        } else {
            format!("{}{}", self.message, self.fields)
        }
    }
}

impl Visit for MessageVisitor {
    fn record_bool(&mut self, field: &Field, value: bool) {
        self.values.insert(field.name().into(), value.into());
        let _ = write!(self.fields, " {}={value}", field.name());
    }

    fn record_u64(&mut self, field: &Field, value: u64) {
        self.values.insert(field.name().into(), value.into());
    }

    fn record_str(&mut self, field: &Field, value: &str) {
        if field.name() != "message" {
            self.values
                .insert(field.name().into(), value.to_string().into());
        }
        if field.name() == "message" {
            self.message.push_str(value);
        } else {
            let _ = write!(self.fields, " {}={value}", field.name());
        }
    }

    fn record_debug(&mut self, field: &Field, value: &dyn std::fmt::Debug) {
        if field.name() == "message" {
            let _ = write!(self.message, "{value:?}");
        } else {
            // tracing 的 %Display 字段也走 record_debug；只拼消息会丢失结构化错误原因。
            self.values.insert(field.name().into(), format!("{value:?}").into());
            let _ = write!(self.fields, " {}={value:?}", field.name());
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use tracing_subscriber::prelude::*;

    static SEEN: Mutex<Vec<(u8, String)>> = Mutex::new(Vec::new());

    extern "C" fn capture(level: u8, ptr: *mut u8, len: usize) {
        let payload = unsafe { Box::from_raw(std::ptr::slice_from_raw_parts_mut(ptr, len)) };
        SEEN.lock()
            .push((level, String::from_utf8(payload.into_vec()).unwrap()));
    }

    #[test]
    fn forwards_events_at_or_above_host_level() {
        let _host = crate::host_callback::TEST_HOST_LOCK.lock();
        SEEN.lock().clear();
        let subscriber = tracing_subscriber::registry().with(HostLayer);
        set_callback(Some(capture));
        set_host_level(3);
        tracing::subscriber::with_default(subscriber, || {
            let span = tracing::info_span!("request", coreRequestId = 42u64);
            let _entered = span.enter();
            tracing::info!(host = "linux.do", "Connection established");
            tracing::debug!("noisy detail");
            tracing::warn!("ECH unusable");
        });
        set_callback(None);
        let seen = SEEN.lock();
        assert_eq!(seen.len(), 2);
        assert_eq!(seen[0].0, 3);
        assert!(
            seen[0]
                .1
                .contains(r#""message":"Connection established host=linux.do""#),
            "{}",
            seen[0].1
        );
        assert_eq!(seen[1].0, 2);
        let payload: serde_json::Value = serde_json::from_str(&seen[0].1).unwrap();
        assert_eq!(payload["fields"]["coreRequestId"], 42);
    }

    #[test]
    fn certificate_reason_survives_default_filter_without_verbose_dependency_logs() {
        let _host = crate::host_callback::TEST_HOST_LOCK.lock();
        SEEN.lock().clear();
        let subscriber = tracing_subscriber::registry().with(logging_filter()).with(HostLayer);
        set_callback(Some(capture));
        set_host_level(3);
        tracing::subscriber::with_default(subscriber, || {
            // 与锁定依赖的实际拒绝事件一致；检查全局过滤和宿主级别两道门槛。
            tracing::debug!(target: "rama_tls_boring::client::verify",
                server_name = %"linux.do",
                err = %"platform verifier: certificate issuer is not trusted: Trust anchor for certification path not found.",
                "boring connector: platform verifier rejected the server certificate");
            tracing::debug!(target: "rama_tls_boring::client::verify", server_name = %"linux.do", "unrelated detail");
            tracing::debug!(target: "rama_http", "unrelated dependency detail");
        });
        set_callback(None);
        let seen = SEEN.lock();
        assert_eq!(seen.len(), 1, "普通日志应保留证书拒绝原因，不能放开依赖全量 debug");
        assert_eq!(seen[0].0, 2);
        let payload: serde_json::Value = serde_json::from_str(&seen[0].1).unwrap();
        assert_eq!(payload["fields"]["server_name"], "linux.do");
        assert!(payload["fields"]["err"].as_str().unwrap().contains("Trust anchor"));
    }

    #[tokio::test]
    async fn terminal_certificate_failure_reports_selected_endpoint_before_abort() {
        use tracing::instrument::WithSubscriber;
        use crate::{egress::{EgressConnector, EgressTarget, HandshakeFailure}, error::NetError};
        let _host = crate::host_callback::TEST_HOST_LOCK.lock();
        SEEN.lock().clear();
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let port = listener.local_addr().unwrap().port();
        let connector = EgressConnector::new(None, None, None, Some("127.0.0.1"), std::time::Duration::from_secs(2));
        let subscriber = tracing_subscriber::registry().with(logging_filter()).with(HostLayer);
        set_callback(Some(capture));
        set_host_level(3);
        // 显式使用本地候选，避免测试环境的系统代理影响地址断言或访问外网。
        let result: crate::error::Result<()> = connector.connect_targets("linux.do", port,
            vec![EgressTarget::Addr { addr: listener.local_addr().unwrap(), sticky: false }],
            Some(vec![1]), |_, ech| async move {
            assert_eq!(ech, Some(vec![1]));
            Err(HandshakeFailure::retry(NetError::Certificate("untrusted test peer".into())))
        }).with_subscriber(subscriber).await;
        set_callback(None);
        assert!(matches!(result, Err(NetError::Certificate(_))));
        let payloads: Vec<serde_json::Value> = SEEN.lock().iter()
            .map(|(_, value)| serde_json::from_str(value).unwrap()).collect();
        let failure = payloads.iter().find(|row| row["fields"]["event"] == "egress_tls_rejected")
            .expect("不可重试错误也必须记录选中地址与 ECH 状态");
        assert_eq!(failure["fields"]["host"], "linux.do");
        assert_eq!(failure["fields"]["peerAddr"], format!("127.0.0.1:{port}"));
        assert_eq!(failure["fields"]["addressFamily"], "ipv4");
        assert_eq!(failure["fields"]["echRequested"], true);
        assert!(failure["fields"]["error"].as_str().unwrap().contains("untrusted test peer"));
    }

    #[test]
    fn multiple_log_hosts_receive_events_independently_and_survive_peer_unregister() {
        static SEEN_A: Mutex<Vec<String>> = Mutex::new(Vec::new());
        static SEEN_B: Mutex<Vec<String>> = Mutex::new(Vec::new());
        extern "C" fn capture_a(_: u8, ptr: *mut u8, len: usize) {
            let payload = unsafe { Box::from_raw(std::ptr::slice_from_raw_parts_mut(ptr, len)) };
            SEEN_A.lock().push(String::from_utf8(payload.into_vec()).unwrap());
        }
        extern "C" fn capture_b(_: u8, ptr: *mut u8, len: usize) {
            let payload = unsafe { Box::from_raw(std::ptr::slice_from_raw_parts_mut(ptr, len)) };
            SEEN_B.lock().push(String::from_utf8(payload.into_vec()).unwrap());
        }

        let _host = crate::host_callback::TEST_HOST_LOCK.lock();
        clear_all_callbacks();
        SEEN_A.lock().clear();
        SEEN_B.lock().clear();
        set_host_level(3);

        let host_a = register_callback(capture_a);
        let host_b = register_callback(capture_b);
        assert_ne!(host_a, 0);
        assert_ne!(host_b, 0);
        assert_ne!(host_a, host_b);

        let subscriber = tracing_subscriber::registry().with(HostLayer);
        tracing::subscriber::with_default(subscriber, || {
            tracing::info!("first event");
            unregister_callback(host_b);
            tracing::info!("second event");
        });
        clear_all_callbacks();

        assert_eq!(SEEN_A.lock().len(), 2);
        assert_eq!(SEEN_B.lock().len(), 1);
        assert!(SEEN_A.lock()[1].contains("second event"));
    }

}
