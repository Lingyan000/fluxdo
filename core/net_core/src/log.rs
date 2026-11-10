//! 日志出口：核心日志除了进系统日志（logcat / stderr），还交给宿主写进应用日志。
//!
//! 用户在应用里导出日志排查网络问题时，建连、选址、DNS、探针这些核心内部过程
//! 必须在里面——只进 logcat 的话，桌面端和 iOS 上的用户根本拿不到。

use std::fmt::Write as _;
use std::sync::atomic::{AtomicU8, Ordering};

use crate::host_callback::HostCallback;
#[cfg(test)]
use parking_lot::Mutex;
use tracing::field::{Field, Visit};
use tracing::{Event, Level, Subscriber};
use tracing_subscriber::layer::Context;
use tracing_subscriber::{Layer, registry::LookupSpan};

/// 日志回调：`(级别, 载荷指针, 载荷长度)`。载荷是 JSON
/// `{"target":"fluxdo_net::client","message":"..."}`，缓冲区由宿主经
/// `fluxdo_net_buffer_free` 归还。级别：1 error、2 warn、3 info、4 debug。
pub type LogCallback = extern "C" fn(u8, *mut u8, usize);

static CALLBACK: HostCallback<LogCallback> = HostCallback::new();
/// 交给宿主的最低级别，取值同回调级别；0 表示不交给宿主。
static HOST_LEVEL: AtomicU8 = AtomicU8::new(3);

pub fn set_callback(callback: Option<LogCallback>) {
    CALLBACK.set(callback);
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
        let code = level_code(metadata.level());
        if code > HOST_LEVEL.load(Ordering::Relaxed) {
            return;
        }
        CALLBACK.with(|callback| {
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
            let payload = serde_json::json!({
                "target": metadata.target(),
                "fields": fields,
                "message": visitor.finish(),
            })
            .to_string();
            let mut payload = payload.into_bytes().into_boxed_slice();
            let (ptr, len) = (payload.as_mut_ptr(), payload.len());
            std::mem::forget(payload);
            callback(code, ptr, len);
        });
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
}
