//! FluxDO 网络核心。
//!
//! 职责：
//! - 作为 dio 的网络栈：宿主经 FFI（[`ffi`]）把请求交给 [`client`]，按浏览器指纹出站；
//! - 为 WebView 提供本地监听（[`listener`]）：DoH / 代理模式下的 CONNECT 走镜像 MITM
//!   （[`mirror`]），CF 验证域走隧道直连；所有模式下提供指纹采样端点（[`probe`]）。
//!
//! 出站统一经 [`egress`]：选址（上游代理 / 系统代理 / DoH / 粘性 IP / Happy Eyeballs）
//! 与 TLS 握手（BoringSSL，按模板复刻 ClientHello，可注入 ECH）在这里收口。

use base64::Engine;
use base64::engine::general_purpose::{STANDARD, URL_SAFE};
use serde::{Deserialize, Serialize};
use tokio::io::{AsyncRead, AsyncWrite};

pub mod browser_tls;
pub mod cert;
pub mod client;
pub mod core;
pub mod dns;
pub mod ech_dns_policy;
pub mod egress;
pub mod error;
pub mod ffi;
pub mod listener;
pub mod log;
pub mod mirror;
mod presets;
pub mod probe;
mod request_trace;
mod session_cache;
pub mod system_proxy;
mod upload_timeout;
pub mod upstream;

pub use error::NetError;

/// Upstream proxy configuration
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct UpstreamProxyConfig {
    /// Upstream proxy protocol. Supports `http`, `socks5` and `shadowsocks`.
    #[serde(default = "default_upstream_protocol")]
    pub protocol: String,
    /// Upstream proxy host
    pub host: String,
    /// Upstream proxy port
    pub port: u16,
    /// Optional username
    #[serde(default)]
    pub username: Option<String>,
    /// Optional password
    #[serde(default)]
    pub password: Option<String>,
    /// Optional cipher for Shadowsocks
    #[serde(default)]
    pub cipher: Option<String>,
}

impl UpstreamProxyConfig {
    pub fn is_valid(&self) -> bool {
        if self.host.trim().is_empty() || self.port == 0 {
            return false;
        }

        if self.is_shadowsocks() {
            let cipher = self.cipher.as_deref().map(str::trim).unwrap_or_default();
            let password = self.password.as_deref().map(str::trim).unwrap_or_default();
            if cipher.is_empty() || password.is_empty() {
                return false;
            }

            if cipher.eq_ignore_ascii_case("2022-blake3-aes-256-gcm") {
                let normalized_password = normalize_base64_padding(password);
                let decoded = STANDARD
                    .decode(normalized_password.as_bytes())
                    .or_else(|_| URL_SAFE.decode(normalized_password.as_bytes()));
                let Ok(decoded) = decoded else {
                    return false;
                };
                return decoded.len() == 32;
            }

            return true;
        }

        true
    }

    pub fn protocol(&self) -> &str {
        let protocol = self.protocol.trim();
        if protocol.is_empty() {
            "http"
        } else {
            protocol
        }
    }

    pub fn is_http(&self) -> bool {
        self.protocol().eq_ignore_ascii_case("http")
    }

    pub fn is_socks5(&self) -> bool {
        matches!(
            self.protocol().to_ascii_lowercase().as_str(),
            "socks" | "socks5" | "socks5h"
        )
    }

    pub fn is_shadowsocks(&self) -> bool {
        matches!(
            self.protocol().to_ascii_lowercase().as_str(),
            "ss" | "shadowsocks"
        )
    }

    pub fn cache_key(&self) -> String {
        let username = self.username.as_deref().map(str::trim).unwrap_or_default();
        let password = self.password.as_deref().map(str::trim).unwrap_or_default();
        let cipher = self.cipher.as_deref().map(str::trim).unwrap_or_default();
        format!(
            "{}|{}|{}|{}|{}|{}",
            self.protocol().to_ascii_lowercase(),
            self.host.trim().to_ascii_lowercase(),
            self.port,
            username,
            password,
            cipher,
        )
    }
}

/// 核心配置。宿主每次配置变化都下发完整一份。
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct NetConfig {
    /// 本地监听地址（WebView CONNECT 与指纹采样端点），固定回环
    #[serde(default = "default_bind_addr")]
    pub bind_addr: String,
    /// 本地监听端口，0 为自动选择
    #[serde(default)]
    pub bind_port: u16,
    /// 是否启用 DoH 解析（关闭时用系统 DNS）
    #[serde(default)]
    pub enable_doh: bool,
    /// DoH 服务器地址（A / AAAA 查询）
    #[serde(default)]
    pub doh_server: Option<String>,
    /// ECH 配置（HTTPS 记录）专用的 DoH 服务器，缺省与 [`Self::doh_server`] 相同
    #[serde(default)]
    pub doh_server_ech: Option<String>,
    /// 公共 ECH 入口开关与自定义域名
    #[serde(default)]
    pub ech_dns_policy: ech_dns_policy::EchDnsPolicy,
    /// 是否优先 IPv6
    #[serde(default)]
    pub prefer_ipv6: bool,
    /// 连接与解析超时（秒）
    #[serde(default = "default_timeout_secs")]
    pub timeout_secs: u64,
    /// 用户配置的上游代理（应用内代理设置）
    #[serde(default)]
    pub upstream_proxy: Option<UpstreamProxyConfig>,
    /// 宿主读到的系统代理（Android 经 Java 系统属性、Windows 经注册表）。
    /// 苹果与 Linux 由核心自行读取，见 [`system_proxy`]。
    #[serde(default)]
    pub system_proxy: Option<UpstreamProxyConfig>,
    /// 用户指定的服务端 IP，跳过 DNS 解析
    #[serde(default)]
    pub server_ip: Option<String>,
    /// WebView 是否经本地监听做 MITM（DoH / 代理模式）；关闭时只保留采样端点
    #[serde(default)]
    pub webview_mitm: bool,
    /// 指纹模板缓存文件路径（应用数据目录内），冷启动即可按模板出站
    #[serde(default)]
    pub fingerprint_cache_path: Option<String>,
    /// 宿主当前 WebView UA，用于缓存失效与就近预置选择。
    #[serde(default)]
    pub fingerprint_user_agent: Option<String>,
    #[serde(default)]
    pub fingerprint_platform: Option<String>,
    /// 指定预置 ID；缺省为实时采样/缓存优先的自动模式。
    #[serde(default)]
    pub fingerprint_preset: Option<String>,
    #[serde(default)]
    pub tls_session_cache_path: Option<String>,
    #[serde(default)]
    pub tls_session_cache_key: Option<String>,
    /// 运行时 CA 证书 PEM（per-device CA）
    #[serde(default)]
    pub ca_cert_pem: Option<String>,
    /// 运行时 CA 私钥 PEM（per-device CA）
    #[serde(default)]
    pub ca_key_pem: Option<String>,
}

impl Default for NetConfig {
    fn default() -> Self {
        Self {
            bind_addr: default_bind_addr(),
            bind_port: 0,
            enable_doh: false,
            doh_server: None,
            doh_server_ech: None,
            ech_dns_policy: Default::default(),
            prefer_ipv6: false,
            timeout_secs: default_timeout_secs(),
            upstream_proxy: None,
            system_proxy: None,
            server_ip: None,
            webview_mitm: false,
            fingerprint_cache_path: None,
            fingerprint_user_agent: None,
            fingerprint_platform: None,
            fingerprint_preset: None,
            tls_session_cache_path: None,
            tls_session_cache_key: None,
            ca_cert_pem: None,
            ca_key_pem: None,
        }
    }
}

fn default_upstream_protocol() -> String {
    "http".to_string()
}

fn default_bind_addr() -> String {
    "127.0.0.1".to_string()
}

fn default_timeout_secs() -> u64 {
    30
}

fn normalize_base64_padding(input: &str) -> String {
    let trimmed = input.trim();
    let remainder = trimmed.len() % 4;
    if remainder == 0 {
        return trimmed.to_string();
    }

    let mut normalized = String::with_capacity(trimmed.len() + (4 - remainder));
    normalized.push_str(trimmed);
    for _ in 0..(4 - remainder) {
        normalized.push('=');
    }
    normalized
}

pub trait AsyncReadWrite: AsyncRead + AsyncWrite + Unpin + Send {}
impl<T: AsyncRead + AsyncWrite + Unpin + Send> AsyncReadWrite for T {}

pub type BoxStream = Box<dyn AsyncReadWrite>;
