//! 系统代理解析。
//!
//! 核心取代系统网络栈（Cronet / URLSession）之后，「跟随系统代理」要由自己实现，
//! 否则配了系统代理的用户 dio 会绕过代理直连，出口与 WebView 不一致（cf_clearance 绑 IP）。
//!
//! 各平台分工：
//! - 苹果：本模块按目标 URL 调 CFNetwork 求值，手动代理与 PAC 自动配置都覆盖，
//!   与 URLSession / WKWebView 读的是同一份设置；
//! - Linux：本模块读 `http_proxy` 等环境变量（与旧的 Dart IO 行为一致，无 PAC 概念）；
//! - 安卓 / Windows：宿主读取后经 [`crate::NetConfig::system_proxy`] 下发
//!   （安卓读 Java 系统属性，系统会把 PAC 转成本机代理；Windows 读注册表）。

use crate::UpstreamProxyConfig;

/// 某个目标该怎么出站。
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ProxyChoice {
    /// 不经代理
    Direct,
    /// 经该代理
    Proxy(UpstreamProxyConfig),
}

/// 本平台是否由核心自行读取系统代理（宿主据此决定要不要下发）。
pub const fn resolves_locally() -> bool {
    cfg!(any(
        target_os = "macos",
        target_os = "ios",
        target_os = "linux"
    ))
}

/// 求值本机系统代理对 `host:port` 的决定。宿主下发的 `configured` 优先
/// （安卓 / Windows 走这条），其余平台按本地设置求值。
pub fn choose(configured: Option<&UpstreamProxyConfig>, host: &str, port: u16) -> ProxyChoice {
    if let Some(proxy) = configured.filter(|proxy| proxy.is_valid()) {
        return ProxyChoice::Proxy(proxy.clone());
    }
    #[cfg(any(target_os = "macos", target_os = "ios"))]
    {
        apple::choose(host, port)
    }
    #[cfg(target_os = "linux")]
    {
        let _ = port;
        linux::choose(host)
    }
    #[cfg(not(any(target_os = "macos", target_os = "ios", target_os = "linux")))]
    {
        let _ = (host, port);
        ProxyChoice::Direct
    }
}

/// 当前是否配置了系统代理（任意目标）。仅用于状态上报与日志。
pub fn configured() -> bool {
    #[cfg(any(target_os = "macos", target_os = "ios"))]
    {
        apple::configured()
    }
    #[cfg(target_os = "linux")]
    {
        linux::any_env_proxy()
    }
    #[cfg(not(any(target_os = "macos", target_os = "ios", target_os = "linux")))]
    {
        false
    }
}

/// 代理地址字符串 → 上游配置。`scheme` 为 `http` 或 `socks5`。
#[cfg_attr(
    not(any(target_os = "macos", target_os = "ios", target_os = "linux")),
    allow(dead_code)
)]
fn proxy_config(scheme: &str, host: &str, port: u16) -> Option<UpstreamProxyConfig> {
    let host = host.trim();
    if host.is_empty() || port == 0 {
        return None;
    }
    let proxy = UpstreamProxyConfig {
        protocol: scheme.to_owned(),
        host: host.to_owned(),
        port,
        username: None,
        password: None,
        cipher: None,
    };
    proxy.is_valid().then_some(proxy)
}

#[cfg(target_os = "linux")]
mod linux {
    use super::{ProxyChoice, proxy_config};

    const PROXY_VARS: [&str; 3] = ["https_proxy", "http_proxy", "all_proxy"];

    pub fn any_env_proxy() -> bool {
        PROXY_VARS
            .iter()
            .flat_map(|name| [name.to_string(), name.to_uppercase()])
            .any(|name| std::env::var(name).is_ok_and(|value| !value.trim().is_empty()))
    }

    pub fn choose(host: &str) -> ProxyChoice {
        if no_proxy_matches(host) {
            return ProxyChoice::Direct;
        }
        for name in PROXY_VARS {
            for name in [name.to_string(), name.to_uppercase()] {
                let Ok(value) = std::env::var(&name) else {
                    continue;
                };
                if let Some(proxy) = parse_proxy_url(value.trim()) {
                    return ProxyChoice::Proxy(proxy);
                }
            }
        }
        ProxyChoice::Direct
    }

    /// `no_proxy` 的常见约定：逗号分隔，`*` 全部直连，`.suffix` 或 `suffix` 匹配域名后缀。
    fn no_proxy_matches(host: &str) -> bool {
        let Some(value) = ["no_proxy", "NO_PROXY"]
            .iter()
            .find_map(|name| std::env::var(name).ok())
        else {
            return false;
        };
        let host = host.trim_end_matches('.').to_ascii_lowercase();
        value.split(',').any(|entry| {
            let entry = entry.trim().trim_end_matches('.').to_ascii_lowercase();
            if entry.is_empty() {
                return false;
            }
            if entry == "*" {
                return true;
            }
            let entry = entry.strip_prefix('.').unwrap_or(&entry);
            host == entry || host.ends_with(&format!(".{entry}"))
        })
    }

    fn parse_proxy_url(value: &str) -> Option<super::UpstreamProxyConfig> {
        if value.is_empty() {
            return None;
        }
        let (scheme, rest) = match value.split_once("://") {
            Some((scheme, rest)) => (scheme.to_ascii_lowercase(), rest),
            None => ("http".to_owned(), value),
        };
        let scheme = match scheme.as_str() {
            "http" | "https" => "http",
            "socks5" | "socks5h" | "socks" => "socks5",
            _ => return None,
        };
        // 代理 URL 里的认证信息（user:pass@host）暂不支持，交由用户配应用内代理
        let rest = rest.rsplit_once('@').map_or(rest, |(_, host)| host);
        let rest = rest.split('/').next().unwrap_or(rest);
        let (host, port) = rest.rsplit_once(':')?;
        proxy_config(scheme, host.trim_matches(['[', ']']), port.parse().ok()?)
    }

    #[cfg(test)]
    mod tests {
        use super::*;

        #[test]
        fn parses_common_proxy_url_forms() {
            let http = parse_proxy_url("http://127.0.0.1:7890").unwrap();
            assert!(http.is_http() && http.port == 7890);
            assert!(parse_proxy_url("127.0.0.1:7890").unwrap().is_http());
            assert!(
                parse_proxy_url("socks5://127.0.0.1:7891")
                    .unwrap()
                    .is_socks5()
            );
            assert_eq!(
                parse_proxy_url("http://user:pass@10.0.0.1:3128")
                    .unwrap()
                    .host,
                "10.0.0.1"
            );
            // 缺端口或协议不认识时不猜
            assert!(parse_proxy_url("http://127.0.0.1").is_none());
            assert!(parse_proxy_url("ftp://127.0.0.1:21").is_none());
            assert!(parse_proxy_url("").is_none());
        }
    }
}

#[cfg(any(target_os = "macos", target_os = "ios"))]
mod apple {
    use std::ffi::c_void;
    use std::time::{Duration, Instant};

    use core_foundation::{
        array::{CFArray, CFArrayRef},
        base::{CFType, TCFType},
        dictionary::{CFDictionary, CFDictionaryRef},
        error::CFErrorRef,
        number::CFNumber,
        runloop::{CFRunLoop, CFRunLoopSource, CFRunLoopSourceRef},
        string::{CFString, CFStringRef},
        url::{CFURL, CFURLRef},
    };
    use parking_lot::Mutex;
    use tracing::{debug, warn};

    use super::{ProxyChoice, proxy_config};

    // 参数名沿用 CFNetwork 头文件的拼写，便于与苹果文档对照
    #[allow(non_snake_case)]
    #[link(name = "CFNetwork", kind = "framework")]
    unsafe extern "C" {
        fn CFNetworkCopySystemProxySettings() -> CFDictionaryRef;
        fn CFNetworkCopyProxiesForURL(url: CFURLRef, proxySettings: CFDictionaryRef) -> CFArrayRef;
        fn CFNetworkExecuteProxyAutoConfigurationURL(
            proxyAutoConfigURL: CFURLRef,
            targetURL: CFURLRef,
            cb: PacCallback,
            clientContext: *mut CFStreamClientContext,
        ) -> CFRunLoopSourceRef;
        fn CFNetworkExecuteProxyAutoConfigurationScript(
            proxyAutoConfigurationScript: CFStringRef,
            targetURL: CFURLRef,
            cb: PacCallback,
            clientContext: *mut CFStreamClientContext,
        ) -> CFRunLoopSourceRef;

        static kCFProxyTypeKey: CFStringRef;
        static kCFProxyHostNameKey: CFStringRef;
        static kCFProxyPortNumberKey: CFStringRef;
        static kCFProxyAutoConfigurationURLKey: CFStringRef;
        static kCFProxyAutoConfigurationJavaScriptKey: CFStringRef;
        static kCFProxyTypeNone: CFStringRef;
        static kCFProxyTypeHTTP: CFStringRef;
        static kCFProxyTypeHTTPS: CFStringRef;
        static kCFProxyTypeSOCKS: CFStringRef;
        static kCFProxyTypeAutoConfigurationURL: CFStringRef;
        static kCFProxyTypeAutoConfigurationJavaScript: CFStringRef;
    }

    type PacCallback =
        extern "C" fn(client: *mut c_void, proxy_list: CFArrayRef, error: CFErrorRef);

    #[repr(C)]
    struct CFStreamClientContext {
        version: isize,
        info: *mut c_void,
        retain: *const c_void,
        release: *const c_void,
        copy_description: *const c_void,
    }

    /// 与 URLSession / WKWebView 读取同一份系统代理设置。
    const ENABLE_KEYS: [&str; 5] = [
        "HTTPEnable",
        "HTTPSEnable",
        "SOCKSEnable",
        "ProxyAutoConfigEnable",
        "ProxyAutoDiscoveryEnable",
    ];

    /// PAC 脚本执行要起 run loop，开销远大于一次连接；按主机缓存结果。
    /// PAC 几乎都按主机判定，官方浏览器也做同样的缓存。
    const PAC_CACHE_TTL: Duration = Duration::from_secs(300);
    /// PAC 求值上限：超时按直连处理，不拖住请求。
    const PAC_TIMEOUT: Duration = Duration::from_secs(5);

    static PAC_CACHE: Mutex<Option<PacCache>> = Mutex::new(None);

    struct PacCache {
        entries: std::collections::HashMap<String, (ProxyChoice, Instant)>,
    }

    fn settings() -> Option<CFDictionary<CFString, CFType>> {
        let raw = unsafe { CFNetworkCopySystemProxySettings() };
        (!raw.is_null()).then(|| unsafe { CFDictionary::wrap_under_create_rule(raw) })
    }

    pub fn configured() -> bool {
        let Some(settings) = settings() else {
            return false;
        };
        ENABLE_KEYS.iter().any(|key| {
            settings
                .find(CFString::from_static_string(key))
                .and_then(|value| value.downcast::<CFNumber>())
                .and_then(|number| number.to_i32())
                .is_some_and(|enabled| enabled != 0)
        })
    }

    pub fn choose(host: &str, port: u16) -> ProxyChoice {
        let Some(settings) = settings() else {
            return ProxyChoice::Direct;
        };
        // 目标用 https 构造：core 的出站一律是 TLS，PAC 脚本也按此判定
        let Some(url) = cf_url(&format!("https://{}:{}/", bracketed(host), port)) else {
            return ProxyChoice::Direct;
        };

        let raw = unsafe {
            CFNetworkCopyProxiesForURL(url.as_concrete_TypeRef(), settings.as_concrete_TypeRef())
        };
        if raw.is_null() {
            return ProxyChoice::Direct;
        }
        let proxies: CFArray<CFType> = unsafe { CFArray::wrap_under_create_rule(raw) };
        choose_from_list(&proxies, host, &url)
    }

    /// 按系统给出的顺序取第一个可用项；PAC 项现场求值（带缓存）。
    fn choose_from_list(proxies: &CFArray<CFType>, host: &str, url: &CFURL) -> ProxyChoice {
        for proxy in proxies.iter() {
            let Some(proxy) = proxy.downcast::<CFDictionary>() else {
                continue;
            };
            let Some(kind) = dict_string(&proxy, unsafe { kCFProxyTypeKey }) else {
                continue;
            };
            match kind.as_str() {
                t if t == static_string(unsafe { kCFProxyTypeNone }) => {
                    return ProxyChoice::Direct;
                }
                t if t == static_string(unsafe { kCFProxyTypeHTTP })
                    || t == static_string(unsafe { kCFProxyTypeHTTPS }) =>
                {
                    if let Some(proxy) = endpoint(&proxy, "http") {
                        return ProxyChoice::Proxy(proxy);
                    }
                }
                t if t == static_string(unsafe { kCFProxyTypeSOCKS }) => {
                    if let Some(proxy) = endpoint(&proxy, "socks5") {
                        return ProxyChoice::Proxy(proxy);
                    }
                }
                t if t == static_string(unsafe { kCFProxyTypeAutoConfigurationURL })
                    || t == static_string(unsafe { kCFProxyTypeAutoConfigurationJavaScript }) =>
                {
                    if let Some(choice) = pac_choice(&proxy, host, url) {
                        return choice;
                    }
                }
                _ => {}
            }
        }
        ProxyChoice::Direct
    }

    /// PAC 求值：命中缓存直接用，否则执行脚本并缓存本主机的结论。
    fn pac_choice(proxy: &CFDictionary, host: &str, url: &CFURL) -> Option<ProxyChoice> {
        if let Some(cached) = pac_cached(host) {
            return Some(cached);
        }
        let resolved = execute_pac(proxy, url)?;
        // PAC 的结果列表里不会再有 PAC 项，递归不会继续下去
        let choice = choose_from_list(&resolved, host, url);
        pac_store(host, choice.clone());
        debug!("PAC resolved {host} -> {choice:?}");
        Some(choice)
    }

    fn execute_pac(proxy: &CFDictionary, url: &CFURL) -> Option<CFArray<CFType>> {
        let mut result = PacResult::default();
        let mut context = CFStreamClientContext {
            version: 0,
            info: (&raw mut result).cast(),
            retain: std::ptr::null(),
            release: std::ptr::null(),
            copy_description: std::ptr::null(),
        };

        let source = if let Some(script) =
            dict_value(proxy, unsafe { kCFProxyAutoConfigurationJavaScriptKey })
                .and_then(|value| value.downcast::<CFString>())
        {
            unsafe {
                CFNetworkExecuteProxyAutoConfigurationScript(
                    script.as_concrete_TypeRef(),
                    url.as_concrete_TypeRef(),
                    pac_callback,
                    &mut context,
                )
            }
        } else {
            let pac_url = dict_value(proxy, unsafe { kCFProxyAutoConfigurationURLKey })
                .and_then(|value| value.downcast::<CFURL>())?;
            unsafe {
                CFNetworkExecuteProxyAutoConfigurationURL(
                    pac_url.as_concrete_TypeRef(),
                    url.as_concrete_TypeRef(),
                    pac_callback,
                    &mut context,
                )
            }
        };
        if source.is_null() {
            warn!("PAC execution could not be started");
            return None;
        }

        // PAC 执行是 run loop 驱动的异步过程：挂到当前线程的私有 mode 上跑到回调或超时。
        // 私有 mode 保证只处理这一个 source，不会驱动调用线程上的其它 run loop 源。
        let source = unsafe { CFRunLoopSource::wrap_under_create_rule(source) };
        let mode = CFString::from_static_string("FluxdoPacMode");
        let run_loop = CFRunLoop::get_current();
        run_loop.add_source(&source, mode.as_concrete_TypeRef());
        let deadline = Instant::now() + PAC_TIMEOUT;
        while !result.done && Instant::now() < deadline {
            CFRunLoop::run_in_mode(
                mode.as_concrete_TypeRef(),
                deadline.saturating_duration_since(Instant::now()),
                true,
            );
        }
        run_loop.remove_source(&source, mode.as_concrete_TypeRef());

        if !result.done {
            warn!("PAC execution timed out after {PAC_TIMEOUT:?}");
        }
        result.proxies
    }

    #[derive(Default)]
    struct PacResult {
        done: bool,
        proxies: Option<CFArray<CFType>>,
    }

    extern "C" fn pac_callback(client: *mut c_void, proxy_list: CFArrayRef, error: CFErrorRef) {
        let Some(result) = (unsafe { client.cast::<PacResult>().as_mut() }) else {
            return;
        };
        result.done = true;
        if !error.is_null() {
            warn!("PAC execution failed");
            return;
        }
        if !proxy_list.is_null() {
            // 回调拿到的是借用引用，保留一份自己的所有权
            result.proxies = Some(unsafe { CFArray::wrap_under_get_rule(proxy_list) });
        }
    }

    fn pac_cached(host: &str) -> Option<ProxyChoice> {
        let mut guard = PAC_CACHE.lock();
        let cache = guard.as_mut()?;
        match cache.entries.get(host) {
            Some((choice, at)) if at.elapsed() < PAC_CACHE_TTL => Some(choice.clone()),
            Some(_) => {
                cache.entries.remove(host);
                None
            }
            None => None,
        }
    }

    fn pac_store(host: &str, choice: ProxyChoice) {
        let mut guard = PAC_CACHE.lock();
        let cache = guard.get_or_insert_with(|| PacCache {
            entries: std::collections::HashMap::new(),
        });
        cache
            .entries
            .retain(|_, (_, at)| at.elapsed() < PAC_CACHE_TTL);
        cache
            .entries
            .insert(host.to_owned(), (choice, Instant::now()));
    }

    /// 系统代理设置变化后作废 PAC 缓存。
    pub fn clear_pac_cache() {
        PAC_CACHE.lock().take();
    }

    fn endpoint(proxy: &CFDictionary, scheme: &str) -> Option<super::UpstreamProxyConfig> {
        let host = dict_string(proxy, unsafe { kCFProxyHostNameKey })?;
        let port = dict_value(proxy, unsafe { kCFProxyPortNumberKey })?
            .downcast::<CFNumber>()?
            .to_i32()?;
        proxy_config(scheme, &host, u16::try_from(port).ok()?)
    }

    /// 无类型 CFDictionary 的取值：拿到裸指针后按 get 规则包成 CFType。
    fn dict_value(dict: &CFDictionary, key: CFStringRef) -> Option<CFType> {
        let raw = *dict.find(key.cast::<c_void>())?;
        (!raw.is_null()).then(|| unsafe { CFType::wrap_under_get_rule(raw.cast()) })
    }

    fn dict_string(dict: &CFDictionary, key: CFStringRef) -> Option<String> {
        dict_value(dict, key)
            .and_then(|value| value.downcast::<CFString>())
            .map(|value| value.to_string())
    }

    fn static_string(value: CFStringRef) -> String {
        unsafe { CFString::wrap_under_get_rule(value) }.to_string()
    }

    fn cf_url(url: &str) -> Option<CFURL> {
        use core_foundation::base::kCFAllocatorDefault;
        let text = CFString::new(url);
        let raw = unsafe {
            core_foundation::url::CFURLCreateWithString(
                kCFAllocatorDefault,
                text.as_concrete_TypeRef(),
                std::ptr::null(),
            )
        };
        (!raw.is_null()).then(|| unsafe { CFURL::wrap_under_create_rule(raw) })
    }

    /// IPv6 字面量在 URL 里要加方括号
    fn bracketed(host: &str) -> String {
        if host.contains(':') && !host.starts_with('[') {
            format!("[{host}]")
        } else {
            host.to_owned()
        }
    }
}

#[cfg(any(target_os = "macos", target_os = "ios"))]
pub use apple::clear_pac_cache;

/// 非苹果平台没有 PAC 缓存，保持同一套调用接口。
#[cfg(not(any(target_os = "macos", target_os = "ios")))]
pub fn clear_pac_cache() {}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn host_config_takes_precedence_over_local_lookup() {
        let proxy = UpstreamProxyConfig {
            protocol: "http".to_owned(),
            host: "127.0.0.1".to_owned(),
            port: 7890,
            username: None,
            password: None,
            cipher: None,
        };
        assert_eq!(
            choose(Some(&proxy), "linux.do", 443),
            ProxyChoice::Proxy(proxy.clone())
        );
        // 无效配置不生效，退回本平台求值
        let invalid = UpstreamProxyConfig { port: 0, ..proxy };
        assert!(matches!(
            choose(Some(&invalid), "linux.do", 443),
            ProxyChoice::Direct | ProxyChoice::Proxy(_)
        ));
    }

    #[test]
    fn rejects_incomplete_endpoints() {
        assert!(proxy_config("http", "", 7890).is_none());
        assert!(proxy_config("http", "127.0.0.1", 0).is_none());
        assert!(proxy_config("socks5", "127.0.0.1", 7891).is_some());
    }
}
