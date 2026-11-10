//! 宿主（Dart）调用的 C 接口。
//!
//! 请求不经本地 socket：宿主用 [`fluxdo_net_request_start`] 把请求交给核心，
//! 响应头与响应体分块经事件回调流式回传（见 [`EventKind`]）。
//!
//! 内存约定：回调里给出的缓冲区由核心分配，宿主读完后必须调用
//! [`fluxdo_net_buffer_free`] 归还——回调是异步投递到 Dart 事件循环的，
//! 指针必须在那之前保持有效，不能在回调返回时就释放。
//!
//! 所有导出函数都用 `catch_unwind` 兜住：单个请求 panic 不会掀掉宿主进程。

use std::collections::HashMap;
use std::ffi::{CStr, CString, c_char, c_int};
use std::panic::{AssertUnwindSafe, catch_unwind};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, OnceLock};
use std::time::Duration;
use tracing::Instrument as _;

use parking_lot::Mutex;
use rama::extensions::{ExtensionsMut as _, ExtensionsRef as _};
use rama::futures::{FutureExt as _, StreamExt as _};
use rama::http::{Body, HeaderName, HeaderValue, Request};
use serde::{Deserialize, Serialize};
use tokio::runtime::Runtime;
use tokio::sync::{OwnedSemaphorePermit, Semaphore, mpsc, watch};
use tokio_util::sync::CancellationToken;
use tracing::{debug, info, warn};

use crate::NetConfig;
use crate::client::{ExchangeInfo, HttpEgressClient};
use crate::core::Core;
use crate::dns::DnsResolver;
use crate::error::NetError;
use crate::host_callback::HostCallback;

/// 事件类型，与 Dart 侧约定的取值。
#[repr(u8)]
enum EventKind {
    /// 响应头，载荷为 JSON：`{"status":200,"headers":[["name","value"],...]}`
    Head = 0,
    /// 响应体分块，载荷为原始字节
    Data = 1,
    /// 响应结束，无载荷
    Done = 2,
    /// 失败，载荷为 JSON：`{"kind":"timeout","message":"..."}`
    Error = 3,
}

/// 单个响应体事件的合并上限。
const MAX_EVENT_PAYLOAD: usize = 256 * 1024;
/// 每个请求尚未由宿主归还的 DATA 载荷预算；不包含协议栈和解压器内部缓冲。
const MAX_PENDING_RESPONSE_BYTES: usize = 1024 * 1024;
static RESPONSE_PERMITS: Mutex<Option<HashMap<usize, OwnedSemaphorePermit>>> = Mutex::new(None);

/// 日志里的 URL 去掉查询串与片段：查询参数里可能有令牌。
fn redact_url(url: &str) -> &str {
    let end = url.find(['?', '#']).unwrap_or(url.len());
    &url[..end]
}

/// [`fluxdo_net_request_write`] 的返回值：缓冲已满，稍后重试。
pub const WRITE_WOULD_BLOCK: c_int = 1;

/// 事件回调：`(请求 id, 事件类型, 载荷指针, 载荷长度)`。
type EventCallback = extern "C" fn(u64, u8, *mut u8, usize);

static RUNTIME: OnceLock<Runtime> = OnceLock::new();
static CORE: Mutex<Option<Arc<Core>>> = Mutex::new(None);
static CALLBACK: HostCallback<EventCallback> = HostCallback::new();
static REQUESTS: Mutex<Option<HashMap<u64, RequestHandle>>> = Mutex::new(None);
static NEXT_REQUEST_ID: AtomicU64 = AtomicU64::new(1);
static HOST_GENERATION: AtomicU64 = AtomicU64::new(0);

/// 请求始终属于发起它的 isolate，普通网络核心 stop/start 不改变这个归属。
#[derive(Clone, Copy)]
struct RequestEvents {
    id: u64,
    host_generation: u64,
}

impl RequestEvents {
    fn new(id: u64) -> Self {
        Self {
            id,
            host_generation: HOST_GENERATION.load(Ordering::Acquire),
        }
    }
}

/// 一个在途请求的控制面。
struct RequestHandle {
    /// 请求体分块的写入端；无请求体时为 None
    body: Option<mpsc::Sender<Vec<u8>>>,
    cancel: CancellationToken,
    /// 响应体背压：宿主的流被暂停时置位，核心停止往外推数据块。
    /// 停读后 HTTP/2 流控会把压力传回上游，下载大文件不会整份堆进内存。
    paused: watch::Sender<bool>,
}

fn runtime() -> &'static Runtime {
    RUNTIME.get_or_init(|| {
        tokio::runtime::Builder::new_multi_thread()
            .enable_all()
            .thread_name("fluxdo-net")
            .build()
            .expect("Failed to create Tokio runtime")
    })
}

fn requests() -> parking_lot::MappedMutexGuard<'static, HashMap<u64, RequestHandle>> {
    parking_lot::MutexGuard::map(REQUESTS.lock(), |slot| {
        slot.get_or_insert_with(HashMap::new)
    })
}

/// 把载荷交给宿主。缓冲区所有权随之移交，宿主负责调用 [`fluxdo_net_buffer_free`]。
fn emit(events: RequestEvents, kind: EventKind, payload: Vec<u8>) {
    emit_with_permit(events, kind, payload, None);
}

fn emit_with_permit(
    events: RequestEvents,
    kind: EventKind,
    payload: Vec<u8>,
    permit: Option<OwnedSemaphorePermit>,
) {
    CALLBACK.with(|callback| {
        // 旧任务即使稍后才退出，也不能投递给新 isolate。
        // 普通 shutdown 仍需向当前 isolate 投递取消错误，不能用请求表是否清空判断。
        if events.host_generation != HOST_GENERATION.load(Ordering::Acquire) {
            return;
        }
        let id = events.id;
        if matches!(kind, EventKind::Done) {
            callback(id, kind as u8, std::ptr::null_mut(), 0);
            return;
        }
        let (ptr, len) = transfer_payload(payload, permit);
        callback(id, kind as u8, ptr, len);
    });
}

fn transfer_payload(payload: Vec<u8>, permit: Option<OwnedSemaphorePermit>) -> (*mut u8, usize) {
    let mut payload = payload.into_boxed_slice();
    let (ptr, len) = (payload.as_mut_ptr(), payload.len());
    if let Some(permit) = permit {
        RESPONSE_PERMITS
            .lock()
            .get_or_insert_with(HashMap::new)
            .insert(ptr as usize, permit);
    }
    std::mem::forget(payload);
    (ptr, len)
}

fn emit_error(events: RequestEvents, error: &NetError) {
    let payload = serde_json::json!({
        "kind": error.kind(),
        "message": error.to_string(),
    });
    emit(events, EventKind::Error, payload.to_string().into_bytes());
}

/// 宿主发起请求时给出的元信息。
#[derive(Debug, Deserialize)]
struct RequestMeta {
    method: String,
    url: String,
    #[serde(default)]
    headers: Vec<(String, String)>,
    /// 是否随后用 [`fluxdo_net_request_write`] 写入请求体
    #[serde(default)]
    has_body: bool,
    /// 新宿主订阅响应流后才恢复读取；旧宿主未传此项时保持原协议。
    #[serde(default)]
    defer_response_body: bool,
    /// 建连时限（dio 的 connectTimeout）
    #[serde(default)]
    connect_timeout_ms: Option<u64>,
    /// 连接就绪后整个上传阶段的时限（dio 的 sendTimeout）。
    #[serde(default)]
    send_timeout_ms: Option<u64>,
    /// 等响应的时限（dio 的 receiveTimeout）：无请求体时管等响应头，
    /// 之后管相邻两个数据块的间隔。有请求体时不管等头——那段含上传耗时。
    #[serde(default)]
    receive_timeout_ms: Option<u64>,
}

impl RequestMeta {
    fn connect_timeout(&self) -> Option<Duration> {
        self.connect_timeout_ms
            .filter(|ms| *ms > 0)
            .map(Duration::from_millis)
    }

    fn receive_timeout(&self) -> Option<Duration> {
        self.receive_timeout_ms
            .filter(|ms| *ms > 0)
            .map(Duration::from_millis)
    }
}

/// 响应头事件的载荷。
#[derive(Debug, Serialize)]
struct ResponseHead {
    connection_id: Option<u64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    request_trace: Option<crate::request_trace::PreparedRequestTrace>,
    status: u16,
    headers: Vec<(String, String)>,
    /// 协商出的协议：`"1.1"` / `"2.0"`，与 dio 的 `httpVersion` 约定一致
    http_version: &'static str,
    /// 连接是复用的（不是为这次请求新建的）
    reused: bool,
    /// 连接的 TLS 握手恢复了之前的会话
    tls_resumed: bool,
    ech_applied: bool,
    ech_accepted: bool,
    /// 取得连接的耗时
    connect_ms: u64,
    /// 请求开始到收到响应头的耗时
    ttfb_ms: u64,
}

fn c_str(ptr: *const c_char) -> Option<String> {
    (!ptr.is_null())
        .then(|| unsafe { CStr::from_ptr(ptr) }.to_str().ok())
        .flatten()
        .map(str::to_owned)
}

fn into_c_string(value: String) -> *mut c_char {
    CString::new(value)
        .map(CString::into_raw)
        .unwrap_or(std::ptr::null_mut())
}

fn json_error(message: &str) -> *mut c_char {
    into_c_string(serde_json::json!({ "ok": false, "error": message }).to_string())
}

/// 初始化日志。重复调用无副作用。
///
/// 系统日志（logcat / stderr）只收 info 及以上；交给宿主应用日志的部分另有级别，
/// 由 [`fluxdo_net_set_log_level`] 跟随宿主的详细日志开关调整。
#[unsafe(no_mangle)]
pub extern "C" fn fluxdo_net_init_logging() {
    let _ = catch_unwind(|| {
        use tracing_subscriber::{EnvFilter, Layer as _, filter::LevelFilter, prelude::*};
        // 全局放到 debug，各层再按自己的级别过滤：宿主开详细日志时不用重建订阅者
        let filter = EnvFilter::builder()
            .with_default_directive(LevelFilter::WARN.into())
            .from_env_lossy()
            .add_directive("fluxdo_net=debug".parse().unwrap())
            .add_directive("rama=warn".parse().unwrap());
        #[cfg(target_os = "android")]
        let system = tracing_android::layer("FluxdoNet")
            .ok()
            .map(|layer| layer.with_filter(LevelFilter::INFO));
        #[cfg(not(target_os = "android"))]
        let system = Some(
            tracing_subscriber::fmt::layer()
                .with_ansi(false)
                .with_filter(LevelFilter::INFO),
        );
        let _ = tracing_subscriber::registry()
            .with(filter)
            .with(system)
            .with(crate::log::HostLayer)
            .try_init();
    });
}

/// 注册日志回调，见 [`crate::log::LogCallback`]。传空指针注销。
#[unsafe(no_mangle)]
pub extern "C" fn fluxdo_net_set_log_callback(callback: Option<crate::log::LogCallback>) {
    crate::log::set_callback(callback);
}

/// 交给宿主的最低日志级别：0 关闭、1 error、2 warn、3 info、4 debug。
#[unsafe(no_mangle)]
pub extern "C" fn fluxdo_net_set_log_level(level: u8) {
    crate::log::set_host_level(level);
}

// Application.onCreate 初始化；发布就绪标记后 Dart 才允许启动核心。
#[cfg(target_os = "android")]
static ANDROID_READY: std::sync::atomic::AtomicBool = std::sync::atomic::AtomicBool::new(false);

/// Kotlin 交入的 Context 是局部引用，必须升级为进程生命周期的全局引用。
///
/// # Safety
/// 参数必须来自 JVM 对 NetCoreBridge.nativeInit 的调用。
#[cfg(target_os = "android")]
#[unsafe(no_mangle)]
pub unsafe extern "system" fn Java_com_github_lingyan000_fluxdo_NetCoreBridge_nativeInit(
    env: *mut jni_sys::JNIEnv,
    _class: jni_sys::jclass,
    context: jni_sys::jobject,
) {
    static INIT: std::sync::Once = std::sync::Once::new();
    let _ = catch_unwind(AssertUnwindSafe(|| {
        if env.is_null() || context.is_null() {
            return;
        }
        INIT.call_once_force(|_| unsafe {
            let functions = &(**env).v1_1;
            let mut vm = std::ptr::null_mut();
            if (functions.GetJavaVM)(env, &mut vm) != jni_sys::JNI_OK || vm.is_null() {
                return;
            }
            let global = (functions.NewGlobalRef)(env, context);
            if global.is_null() {
                return;
            }
            // 全局引用由核心终身持有，避免 Activity 重建或局部引用失效。
            ndk_context::initialize_android_context(vm.cast(), global.cast());
            ANDROID_READY.store(true, std::sync::atomic::Ordering::Release);
        });
    }));
}

/// Dart 只检查就绪状态，不再依赖 libdartjni 的私有导出符号。
#[cfg(target_os = "android")]
#[unsafe(no_mangle)]
pub extern "C" fn fluxdo_net_android_ready() -> c_int {
    i32::from(ANDROID_READY.load(std::sync::atomic::Ordering::Acquire))
}

/// 每个 Dart isolate 用 `NativeCallable.listener` 注册一次，销毁前必须解除回调。
#[unsafe(no_mangle)]
pub extern "C" fn fluxdo_net_set_event_callback(callback: Option<EventCallback>) {
    let _ = catch_unwind(AssertUnwindSafe(|| {
        CALLBACK.set(callback);
    }));
}

/// 启动（或按新配置重启）核心。返回本地监听端口，失败返回 -1。
///
/// # Safety
/// `config_json` 必须是有效的 NUL 结尾字符串，或空指针。
#[unsafe(no_mangle)]
pub unsafe extern "C" fn fluxdo_net_init(config_json: *const c_char) -> c_int {
    catch_unwind(AssertUnwindSafe(|| {
        let Some(json) = c_str(config_json) else {
            warn!("init: missing config");
            return -1;
        };
        let config: NetConfig = match serde_json::from_str(&json) {
            Ok(config) => config,
            Err(e) => {
                warn!("init: invalid config: {e}");
                return -1;
            }
        };
        // 重启：先停旧实例的监听把端口让出来（WebView2 的代理端口定死在环境里，
        // 新实例必须绑回同一个端口），但旧实例留在 CORE 里继续承接请求，
        // 新实例就位后再原子替换——中间没有「核心不在」的空窗。
        let previous = CORE.lock().clone();
        let started = runtime().block_on(async {
            if let Some(previous) = &previous {
                previous.stop_listener().await;
            }
            Core::start(config).await
        });
        match started {
            Ok(core) => {
                let port = core.port().unwrap_or(0);
                *CORE.lock() = Some(core);
                info!("Network core started (listener port {port})");
                c_int::from(port)
            }
            Err(e) => {
                warn!("init: {e}");
                // 旧实例的监听已停，不能再当作完整可用的核心
                *CORE.lock() = None;
                -1
            }
        }
    }))
    .unwrap_or(-1)
}

/// 停止核心并断开所有连接。
#[unsafe(no_mangle)]
pub extern "C" fn fluxdo_net_shutdown() {
    let _ = catch_unwind(AssertUnwindSafe(|| {
        let core = CORE.lock().take();
        if let Some(core) = core {
            runtime().block_on(core.stop_listener());
        }
        for (_, handle) in requests().drain() {
            handle.cancel.cancel();
        }
    }));
}

/// 在旧 Dart isolate 销毁前由原生宿主同步调用，不能等新 main() 启动后再清理。
/// 先断开两个回调出口并等待正在投递的调用退出，再取消请求和停止监听。
/// Tokio runtime 可以复用；新 isolate 会重新注册回调并启动核心。
#[unsafe(no_mangle)]
pub extern "C" fn fluxdo_net_detach_host() {
    let _ = catch_unwind(AssertUnwindSafe(|| {
        CALLBACK.set(None);
        HOST_GENERATION.fetch_add(1, Ordering::AcqRel);
        crate::log::set_callback(None);
        fluxdo_net_shutdown();
    }));
}

/// 当前状态 JSON：监听端口、模板是否就绪、采样时的 UA、是否检测到系统代理。
#[unsafe(no_mangle)]
pub extern "C" fn fluxdo_net_status_json() -> *mut c_char {
    catch_unwind(AssertUnwindSafe(|| {
        let core = CORE.lock().clone();
        let status = match core {
            Some(core) => core.status_json(),
            None => serde_json::json!({ "running": false }).to_string(),
        };
        into_c_string(status)
    }))
    .unwrap_or_else(|_| json_error("status panicked"))
}

/// 丢弃所有池化连接。网络切换后调用：旧连接绑在旧网络的源地址上，
/// 不主动丢弃会一直等到 NAT 超时才失败。
#[unsafe(no_mangle)]
pub extern "C" fn fluxdo_net_reset_connections() {
    let _ = catch_unwind(AssertUnwindSafe(|| {
        let core = CORE.lock().clone();
        if let Some(core) = core {
            runtime().block_on(core.reset_connections());
        }
    }));
}

/// DNS 缓存概览与明细，供设置页展示：
/// `{"stats":{...},"records":[{"host","kind","values","ttl_ms"},...]}`。
#[unsafe(no_mangle)]
pub extern "C" fn fluxdo_net_dns_cache_json() -> *mut c_char {
    catch_unwind(|| {
        let (stats, records) = runtime().block_on(async {
            (
                DnsResolver::shared_cache_stats().await,
                DnsResolver::shared_cache_records().await,
            )
        });
        into_c_string(
            serde_json::json!({
                "stats": {
                    "resolver_count": stats.resolver_count,
                    "host_count": stats.host_count,
                    "ip_count": stats.ip_count,
                    "ech_count": stats.ech_count,
                    "ech_negative_count": stats.ech_negative_count,
                    "ip_rtt_count": stats.ip_rtt_count,
                    "preferred_ip_count": stats.preferred_ip_count,
                },
                "records": records
                    .into_iter()
                    .map(|record| {
                        serde_json::json!({
                            "host": record.host,
                            "kind": record.kind,
                            "values": record.values,
                            "ttl_ms": record.ttl_ms,
                        })
                    })
                    .collect::<Vec<_>>(),
            })
            .to_string(),
        )
    })
    .unwrap_or_else(|_| json_error("dns_cache panicked"))
}

/// 清空所有 DNS 缓存。
#[unsafe(no_mangle)]
pub extern "C" fn fluxdo_net_clear_dns_cache() {
    let _ = catch_unwind(|| {
        runtime().block_on(DnsResolver::clear_shared_caches());
    });
}

/// 设置公共 ECH 入口策略。返回 0 成功。
///
/// # Safety
/// `policy_json` 必须是有效的 NUL 结尾字符串。
#[unsafe(no_mangle)]
pub unsafe extern "C" fn fluxdo_net_set_ech_dns_policy(policy_json: *const c_char) -> c_int {
    catch_unwind(AssertUnwindSafe(|| {
        let Some(json) = c_str(policy_json) else {
            return -1;
        };
        match serde_json::from_str(&json) {
            Ok(policy) => {
                runtime().block_on(DnsResolver::set_shared_ech_dns_policy(policy));
                0
            }
            Err(e) => {
                warn!("invalid ech dns policy: {e}");
                -1
            }
        }
    }))
    .unwrap_or(-1)
}

/// 生成一份新的 CA，返回 `{"ok":true,"cert":"...","key":"..."}`。
#[unsafe(no_mangle)]
pub extern "C" fn fluxdo_net_generate_ca() -> *mut c_char {
    catch_unwind(|| match crate::cert::generate_ca_pem() {
        Ok((cert, key)) => {
            into_c_string(serde_json::json!({ "ok": true, "cert": cert, "key": key }).to_string())
        }
        Err(e) => json_error(&e.to_string()),
    })
    .unwrap_or_else(|_| json_error("generate_ca panicked"))
}

/// 验证 WebView 提供的叶子证书。缺少核心、数据或证书不匹配均返回 0。
/// # Safety
/// 输入必须是有效 NUL 结尾 JSON 字符串。
#[unsafe(no_mangle)]
pub unsafe extern "C" fn fluxdo_net_verify_webview_certificate(input: *const c_char) -> c_int {
    catch_unwind(AssertUnwindSafe(|| {
        use base64::Engine as _;
        let Some(json) = c_str(input) else { return 0 };
        if json.len() > 100_000 {
            return 0;
        }
        let Ok(value) = serde_json::from_str::<serde_json::Value>(&json) else {
            return 0;
        };
        let (Some(host), Some(encoded)) = (value["host"].as_str(), value["der"].as_str()) else {
            return 0;
        };
        let Ok(der) = base64::engine::general_purpose::STANDARD.decode(encoded) else {
            return 0;
        };
        let Some(core) = CORE.lock().clone() else {
            return 0;
        };
        i32::from(core.verify_webview_leaf(&der, host))
    }))
    .unwrap_or(0)
}

/// 归还 [`fluxdo_net_status_json`] 等返回的字符串。
///
/// # Safety
/// `ptr` 必须是本库返回且尚未归还的字符串指针。
#[unsafe(no_mangle)]
pub unsafe extern "C" fn fluxdo_net_free_string(ptr: *mut c_char) {
    if ptr.is_null() {
        return;
    }
    let _ = catch_unwind(AssertUnwindSafe(|| unsafe {
        drop(CString::from_raw(ptr));
    }));
}

/// 归还事件回调里收到的缓冲区。
///
/// # Safety
/// `ptr` 与 `len` 必须原样来自一次事件回调，且只归还一次。
#[unsafe(no_mangle)]
pub unsafe extern "C" fn fluxdo_net_buffer_free(ptr: *mut u8, len: usize) {
    if ptr.is_null() || len == 0 {
        return;
    }
    let _ = catch_unwind(AssertUnwindSafe(|| unsafe {
        // 先移走许可，再释放地址，避免另一线程复用同一地址时覆盖旧记录。
        let permit = RESPONSE_PERMITS
            .lock()
            .as_mut()
            .and_then(|permits| permits.remove(&(ptr as usize)));
        drop(Box::from_raw(std::ptr::slice_from_raw_parts_mut(ptr, len)));
        drop(permit);
    }));
}

/// 发起一个请求，返回请求 id；0 表示发起失败（核心未启动或元信息非法）。
///
/// # Safety
/// `meta_json` 必须是有效的 NUL 结尾字符串，或空指针。
#[unsafe(no_mangle)]
pub unsafe extern "C" fn fluxdo_net_request_start(meta_json: *const c_char) -> u64 {
    catch_unwind(AssertUnwindSafe(|| {
        let Some(json) = c_str(meta_json) else {
            return 0;
        };
        let meta: RequestMeta = match serde_json::from_str(&json) {
            Ok(meta) => meta,
            Err(e) => {
                warn!("request: invalid meta: {e}");
                return 0;
            }
        };
        let Some(core) = CORE.lock().clone() else {
            warn!("request: core not running");
            return 0;
        };

        let id = NEXT_REQUEST_ID.fetch_add(1, Ordering::Relaxed);
        let events = RequestEvents::new(id);
        let cancel = CancellationToken::new();
        // 请求体分块缓冲：宿主写得快时在这里排队，不会丢
        let (body_tx, body_rx) = if meta.has_body {
            let (tx, rx) = mpsc::channel::<Vec<u8>>(8);
            (Some(tx), Some(rx))
        } else {
            (None, None)
        };
        let (paused_tx, paused_rx) = watch::channel(meta.defer_response_body);
        requests().insert(
            id,
            RequestHandle {
                body: body_tx,
                cancel: cancel.clone(),
                paused: paused_tx,
            },
        );

        let client = core.client();
        runtime().spawn(
            async move {
                let started = std::time::Instant::now();
                let label = format!("{} {}", meta.method, redact_url(&meta.url));
                let outcome = tokio::select! {
                    biased;
                    () = cancel.cancelled() => Err(NetError::Cancelled),
                    outcome = run_request(events, client, meta, body_rx, paused_rx) => outcome,
                };
                match &outcome {
                    Ok(()) => {}
                    // 取消是宿主主动的（长轮询换页、页面关闭），不算故障
                    Err(NetError::Cancelled) => {
                        debug!(
                            "Request #{id} {label} cancelled after {}ms",
                            started.elapsed().as_millis()
                        );
                    }
                    Err(error) => warn!(
                        "Request #{id} {label} failed after {}ms [{}]: {error}",
                        started.elapsed().as_millis(),
                        error.kind()
                    ),
                }
                if let Err(error) = outcome {
                    emit_error(events, &error);
                }
                requests().remove(&id);
            }
            .instrument(tracing::info_span!("request", coreRequestId = id)),
        );
        id
    }))
    .unwrap_or(0)
}

async fn run_request(
    events: RequestEvents,
    client: Arc<HttpEgressClient>,
    meta: RequestMeta,
    body_rx: Option<mpsc::Receiver<Vec<u8>>>,
    mut paused: watch::Receiver<bool>,
) -> Result<(), NetError> {
    let id = events.id;
    let connect_timeout = meta.connect_timeout();
    let receive_timeout = meta.receive_timeout();
    let send_timeout = meta
        .send_timeout_ms
        .filter(|ms| *ms > 0)
        .map(Duration::from_millis);
    let head_timeout = receive_timeout.filter(|_| !meta.has_body);

    let (upload_done_tx, upload_done_rx) = tokio::sync::oneshot::channel();
    let body = match body_rx {
        Some(rx) => Body::from_stream(
            tokio_stream::wrappers::ReceiverStream::new(rx)
                .map(|chunk| Ok::<_, std::io::Error>(bytes::Bytes::from(chunk)))
                .chain(rama::futures::stream::once(async move {
                    let _ = upload_done_tx.send(());
                    Ok(bytes::Bytes::new())
                })),
        ),
        None => Body::empty(),
    };
    let mut builder = Request::builder()
        .method(meta.method.as_str())
        .uri(meta.url.as_str());
    for (name, value) in &meta.headers {
        match (
            HeaderName::from_bytes(name.as_bytes()),
            HeaderValue::from_str(value),
        ) {
            (Ok(name), Ok(value)) => builder = builder.header(name, value),
            _ => debug!("request {id}: dropping invalid header {name}"),
        }
    }
    let mut request = builder
        .body(body)
        .map_err(|e| NetError::InvalidUrl(format!("Invalid request: {e}")))?;

    // 图片 GET、未配置发送时限的请求不分配额外计时通道。
    let upload_watch = if meta.has_body && send_timeout.is_some() {
        let (upload_started, upload_watch) = watch::channel(None);
        request
            .extensions_mut()
            .insert(crate::upload_timeout::UploadStarted(upload_started));
        Some(upload_watch)
    } else {
        None
    };
    let send_deadline = async move {
        match upload_watch {
            Some(watch) => crate::upload_timeout::wait(watch, send_timeout).await,
            None => std::future::pending::<()>().await,
        }
    };
    let started = std::time::Instant::now();
    let exchange = client.send(request, connect_timeout, head_timeout);
    tokio::pin!(exchange);
    let response = if meta.has_body {
        // 上传不计入 receiveTimeout；请求体送完后等待响应头仍必须有上限。
        tokio::select! {
            biased;
            result = &mut exchange => result,
            _ = upload_done_rx => match receive_timeout {
                Some(limit) => tokio::time::timeout(limit, &mut exchange)
                    .await
                    .map_err(|_| NetError::ReceiveTimeout)?,
                None => exchange.await,
            },
            _ = send_deadline => return Err(NetError::SendTimeout),
        }
    } else {
        exchange.await
    }
    .map_err(|e| match e.downcast::<NetError>() {
        Ok(error) => *error,
        Err(other) => NetError::Proxy(other.to_string()),
    })?;

    let info = response.extensions().get_ref::<ExchangeInfo>().cloned();
    let ttfb = started.elapsed();
    if let Some(info) = &info {
        debug!(
            "Request #{id} {} {} -> {} ({:?}, {}, connect {}ms, ttfb {}ms)",
            meta.method,
            redact_url(&meta.url),
            response.status().as_u16(),
            info.version,
            if info.reused {
                "reused"
            } else {
                "new connection"
            },
            info.connect.as_millis(),
            ttfb.as_millis()
        );
    }
    let head = ResponseHead {
        connection_id: info.as_ref().map(|info| info.connection_id),
        request_trace: response
            .extensions()
            .get_ref::<crate::request_trace::PreparedRequestTrace>()
            .cloned(),
        http_version: match info.as_ref().map(|info| info.version) {
            Some(rama::http::Version::HTTP_2) => "2.0",
            Some(rama::http::Version::HTTP_3) => "3.0",
            Some(rama::http::Version::HTTP_10) => "1.0",
            _ => "1.1",
        },
        reused: info.as_ref().is_some_and(|info| info.reused),
        tls_resumed: info.as_ref().is_some_and(|info| info.tls_resumed),
        ech_applied: info.as_ref().is_some_and(|info| info.ech_applied),
        ech_accepted: info.as_ref().is_some_and(|info| info.ech_accepted),
        connect_ms: info
            .as_ref()
            .map_or(0, |info| info.connect.as_millis() as u64),
        ttfb_ms: ttfb.as_millis() as u64,
        status: response.status().as_u16(),
        headers: response
            .headers()
            .iter()
            // 非 ASCII 的头值（如 content-disposition 里的中文文件名）按 UTF-8 宽松解码，
            // 不能因为不是可见 ASCII 就整条丢掉
            .map(|(name, value)| {
                (
                    name.as_str().to_owned(),
                    String::from_utf8_lossy(value.as_bytes()).into_owned(),
                )
            })
            .collect(),
    };
    emit(
        events,
        EventKind::Head,
        serde_json::to_vec(&head).map_err(|e| NetError::Parse(e.to_string()))?,
    );

    let mut stream = response.into_body().into_data_stream();
    let body_error = |e: rama::error::BoxError| NetError::Io(std::io::Error::other(e.to_string()));
    let budget = Arc::new(Semaphore::new(MAX_PENDING_RESPONSE_BYTES));
    let mut remainder = bytes::Bytes::new();
    let mut finished = false;
    while !finished || !remainder.is_empty() {
        wait_until_resumed(&mut paused).await?;
        if remainder.is_empty() {
            let next = next_response_chunk(&mut stream, &mut paused, receive_timeout).await?;
            let Some(chunk) = next else {
                break;
            };
            remainder = chunk;
        }
        // 已经到手的后续块并成一次回调：HTTP/2 数据帧多在 16KB 以内，
        // 逐帧回调会让一张大图拆成几十次跨线程投递
        let mut payload = Vec::new();
        append_response_chunk(&mut payload, &mut remainder);
        while payload.len() < MAX_EVENT_PAYLOAD {
            match stream.next().now_or_never() {
                Some(Some(more)) => {
                    remainder = more.map_err(body_error)?;
                    append_response_chunk(&mut payload, &mut remainder);
                }
                Some(None) => {
                    finished = true;
                    break;
                }
                None => break,
            }
        }
        if payload.is_empty() {
            continue;
        }
        // 字节预算覆盖异步回调尚未执行的窗口；小块至少占 4 KiB，限制回调数量。
        // 等宿主归还缓冲/恢复读取均不计接收超时，外层 cancellation 仍可中断。
        let permit = budget
            .clone()
            .acquire_many_owned(payload.len().max(4096) as u32)
            .await
            .map_err(|_| NetError::Cancelled)?;
        wait_until_resumed(&mut paused).await?;
        emit_with_permit(events, EventKind::Data, payload, Some(permit));
    }
    emit(events, EventKind::Done, Vec::new());
    Ok(())
}

fn append_response_chunk(payload: &mut Vec<u8>, chunk: &mut bytes::Bytes) {
    let count = chunk.len().min(MAX_EVENT_PAYLOAD - payload.len());
    payload.extend_from_slice(&chunk.split_to(count));
}

async fn wait_until_resumed(paused: &mut watch::Receiver<bool>) -> Result<(), NetError> {
    while *paused.borrow_and_update() {
        paused.changed().await.map_err(|_| NetError::Cancelled)?;
    }
    Ok(())
}

async fn next_response_chunk<S>(
    stream: &mut S,
    paused: &mut watch::Receiver<bool>,
    timeout: Option<Duration>,
) -> Result<Option<bytes::Bytes>, NetError>
where
    S: rama::futures::Stream<Item = Result<bytes::Bytes, rama::error::BoxError>> + Unpin,
{
    loop {
        wait_until_resumed(paused).await?;
        tokio::select! {
            changed = paused.changed() => changed.map_err(|_| NetError::Cancelled)?,
            next = async {
                match timeout {
                    Some(limit) => tokio::time::timeout(limit, stream.next()).await
                        .map_err(|_| NetError::ReceiveTimeout),
                    None => Ok(stream.next().await),
                }
            } => return next?.transpose()
                .map_err(|e| NetError::Io(std::io::Error::other(e.to_string()))),
        }
    }
}

/// 暂停响应体推送（宿主的流被暂停时调用）。
#[unsafe(no_mangle)]
pub extern "C" fn fluxdo_net_request_pause(id: u64) {
    set_paused(id, true);
}

/// 恢复响应体推送。
#[unsafe(no_mangle)]
pub extern "C" fn fluxdo_net_request_resume(id: u64) {
    set_paused(id, false);
}

fn set_paused(id: u64, paused: bool) {
    let _ = catch_unwind(AssertUnwindSafe(|| {
        if let Some(handle) = requests().get(&id) {
            let _ = handle.paused.send(paused);
        }
    }));
}

/// 写入一段请求体。
///
/// 返回 0 成功；[`WRITE_WOULD_BLOCK`] 表示缓冲已满，宿主稍后重试（背压）；
/// -1 表示请求已结束或没有请求体。绝不阻塞调用线程——宿主在 UI 线程上调用。
///
/// # Safety
/// `ptr` 必须指向至少 `len` 字节的可读内存，调用期间保持有效。
#[unsafe(no_mangle)]
pub unsafe extern "C" fn fluxdo_net_request_write(id: u64, ptr: *const u8, len: usize) -> c_int {
    catch_unwind(AssertUnwindSafe(|| {
        if ptr.is_null() && len != 0 {
            return -1;
        }
        let Some(sender) = requests().get(&id).and_then(|handle| handle.body.clone()) else {
            return -1;
        };
        // 空块无需排队；也避免对合法的(null, 0)构造Rust slice（这仍是UB）。
        if len == 0 {
            return 0;
        }
        enqueue_body_chunk(&sender, || {
            unsafe { std::slice::from_raw_parts(ptr, len) }.to_vec()
        })
    }))
    .unwrap_or(-1)
}

/// 先取得容量才复制宿主数据：队列满时退避重试不能反复分配并丢弃大块内存。
fn enqueue_body_chunk(sender: &mpsc::Sender<Vec<u8>>, copy: impl FnOnce() -> Vec<u8>) -> c_int {
    match sender.try_reserve() {
        Ok(permit) => {
            permit.send(copy());
            0
        }
        Err(mpsc::error::TrySendError::Full(_)) => WRITE_WOULD_BLOCK,
        Err(mpsc::error::TrySendError::Closed(_)) => -1,
    }
}

/// 声明请求体写完。
#[unsafe(no_mangle)]
pub extern "C" fn fluxdo_net_request_finish(id: u64) {
    let _ = catch_unwind(AssertUnwindSafe(|| {
        if let Some(handle) = requests().get_mut(&id) {
            // 丢掉写入端即为 EOF
            handle.body = None;
        }
    }));
}

/// 取消一个在途请求。取消会一路传到上游连接。
#[unsafe(no_mangle)]
pub extern "C" fn fluxdo_net_request_cancel(id: u64) {
    let _ = catch_unwind(AssertUnwindSafe(|| {
        if let Some(handle) = requests().get(&id) {
            handle.cancel.cancel();
        }
    }));
}

#[cfg(test)]
mod tests {
    use super::*;

    static EVENT_COUNT: AtomicU64 = AtomicU64::new(0);

    extern "C" fn capture_event(_: u64, _: u8, ptr: *mut u8, len: usize) {
        EVENT_COUNT.fetch_add(1, Ordering::Relaxed);
        unsafe { fluxdo_net_buffer_free(ptr, len) };
    }

    fn insert_test_request() -> (u64, CancellationToken) {
        let id = NEXT_REQUEST_ID.fetch_add(1, Ordering::Relaxed);
        let cancel = CancellationToken::new();
        let (paused, _) = watch::channel(false);
        requests().insert(
            id,
            RequestHandle {
                body: None,
                cancel: cancel.clone(),
                paused,
            },
        );
        (id, cancel)
    }

    #[test]
    fn host_detach_cancels_old_requests_and_new_host_can_receive_events() {
        let _host = crate::host_callback::TEST_HOST_LOCK.lock();
        EVENT_COUNT.store(0, Ordering::Relaxed);
        fluxdo_net_set_event_callback(Some(capture_event));
        let (old_id, cancelled) = insert_test_request();
        let old_events = RequestEvents::new(old_id);
        emit(old_events, EventKind::Data, vec![1]);
        assert_eq!(EVENT_COUNT.load(Ordering::Relaxed), 1);

        fluxdo_net_detach_host();
        assert!(cancelled.is_cancelled());
        assert!(!requests().contains_key(&old_id));
        assert!(CALLBACK.with(|_| ()).is_none());
        // 清理可重复调用，且不会销毁进程级 runtime。
        fluxdo_net_detach_host();

        fluxdo_net_set_event_callback(Some(capture_event));
        // 旧任务晚到的数据必须直接丢弃，并归还尚未转移给宿主的字节预算。
        let budget = Arc::new(Semaphore::new(4096));
        let permit = budget.clone().try_acquire_many_owned(4096).unwrap();
        emit_with_permit(old_events, EventKind::Data, vec![2], Some(permit));
        assert_eq!(budget.available_permits(), 4096);
        assert_eq!(EVENT_COUNT.load(Ordering::Relaxed), 1);

        let (new_id, _) = insert_test_request();
        let new_events = RequestEvents::new(new_id);
        emit(new_events, EventKind::Data, vec![3]);
        emit(new_events, EventKind::Done, Vec::new());
        assert_eq!(EVENT_COUNT.load(Ordering::Relaxed), 3);
        fluxdo_net_detach_host();
    }

    #[test]
    fn ordinary_shutdown_still_delivers_cancellation_to_current_host() {
        let _host = crate::host_callback::TEST_HOST_LOCK.lock();
        EVENT_COUNT.store(0, Ordering::Relaxed);
        fluxdo_net_set_event_callback(Some(capture_event));
        let (id, cancelled) = insert_test_request();
        let events = RequestEvents::new(id);
        fluxdo_net_shutdown();
        assert!(cancelled.is_cancelled());
        emit_error(events, &NetError::Cancelled);
        assert_eq!(EVENT_COUNT.load(Ordering::Relaxed), 1);
        fluxdo_net_detach_host();
    }

    #[tokio::test]
    async fn callback_payload_budget_is_released_only_when_host_frees_buffer() {
        let budget = Arc::new(Semaphore::new(MAX_PENDING_RESPONSE_BYTES));
        let mut buffers = Vec::new();
        for _ in 0..4 {
            let permit = budget
                .clone()
                .acquire_many_owned(MAX_EVENT_PAYLOAD as u32)
                .await
                .unwrap();
            buffers.push(transfer_payload(vec![7; MAX_EVENT_PAYLOAD], Some(permit)));
        }
        assert_eq!(budget.available_permits(), 0);
        let next = budget.clone().acquire_many_owned(MAX_EVENT_PAYLOAD as u32);
        tokio::pin!(next);
        assert!(next.as_mut().now_or_never().is_none());
        let (ptr, len) = buffers.pop().unwrap();
        unsafe {
            fluxdo_net_buffer_free(ptr, len);
        }
        let permit = next.await.unwrap();
        assert_eq!(budget.available_permits(), 0);
        drop(permit);
        for (ptr, len) in buffers {
            unsafe {
                fluxdo_net_buffer_free(ptr, len);
            }
        }
        assert_eq!(budget.available_permits(), MAX_PENDING_RESPONSE_BYTES);
    }

    #[test]
    fn oversized_response_chunk_is_split_without_losing_bytes() {
        let original: Vec<_> = (0..MAX_EVENT_PAYLOAD * 2 + 17)
            .map(|i| (i % 251) as u8)
            .collect();
        let mut chunk = bytes::Bytes::from(original.clone());
        let mut output = Vec::new();
        let mut lengths = Vec::new();
        while !chunk.is_empty() {
            let mut payload = Vec::new();
            append_response_chunk(&mut payload, &mut chunk);
            lengths.push(payload.len());
            output.extend(payload);
        }
        assert_eq!(lengths, [MAX_EVENT_PAYLOAD, MAX_EVENT_PAYLOAD, 17]);
        assert_eq!(output, original);
        let mut payload = vec![1; MAX_EVENT_PAYLOAD - 1];
        let mut chunk = bytes::Bytes::from_static(&[2, 3]);
        append_response_chunk(&mut payload, &mut chunk);
        assert_eq!(payload.len(), MAX_EVENT_PAYLOAD);
        assert_eq!(payload.last(), Some(&2));
        assert_eq!(&chunk[..], &[3]);
    }

    #[tokio::test]
    async fn paused_consumer_does_not_spend_receive_timeout() {
        let (tx, mut rx) = watch::channel(false);
        let (body_tx, body_rx) = mpsc::channel(1);
        let mut stream = tokio_stream::wrappers::ReceiverStream::new(body_rx);
        let next = next_response_chunk(&mut stream, &mut rx, Some(Duration::from_millis(30)));
        tokio::pin!(next);
        assert!(next.as_mut().now_or_never().is_none());
        tx.send(true).unwrap();
        assert!(next.as_mut().now_or_never().is_none());
        tokio::time::sleep(Duration::from_millis(60)).await;
        assert!(next.as_mut().now_or_never().is_none());
        body_tx
            .send(Ok(bytes::Bytes::from_static(b"ready")))
            .await
            .unwrap();
        tx.send(false).unwrap();
        assert_eq!(next.await.unwrap().unwrap(), "ready");
    }

    #[test]
    fn upload_backpressure_does_not_copy_until_capacity_is_available() {
        let (tx, mut rx) = mpsc::channel(1);
        tx.try_send(vec![1]).unwrap();
        let copies = std::cell::Cell::new(0);
        for _ in 0..100 {
            assert_eq!(
                enqueue_body_chunk(&tx, || {
                    copies.set(copies.get() + 1);
                    vec![2; 1024 * 1024]
                }),
                WRITE_WOULD_BLOCK
            );
        }
        assert_eq!(copies.get(), 0);
        assert_eq!(rx.try_recv().unwrap(), vec![1]);
        assert_eq!(
            enqueue_body_chunk(&tx, || {
                copies.set(copies.get() + 1);
                vec![2]
            }),
            0
        );
        assert_eq!(copies.get(), 1);
        assert_eq!(rx.try_recv().unwrap(), vec![2]);
        drop(rx);
        assert_eq!(
            enqueue_body_chunk(&tx, || panic!("closed queue must not copy")),
            -1
        );
    }

    #[test]
    fn request_meta_defaults_to_no_body_and_no_headers() {
        let meta: RequestMeta =
            serde_json::from_str(r#"{"method":"GET","url":"https://linux.do/"}"#).unwrap();
        assert_eq!(meta.method, "GET");
        assert!(meta.headers.is_empty());
        assert!(!meta.has_body);
    }

    #[test]
    fn error_payload_carries_stable_kind() {
        let payload = serde_json::json!({
            "kind": NetError::Timeout.kind(),
            "message": NetError::Timeout.to_string(),
        });
        assert_eq!(payload["kind"], "timeout");
    }
}
