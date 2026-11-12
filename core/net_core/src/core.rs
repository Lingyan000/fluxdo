//! 核心实例：把出站、客户端、本地监听与指纹模板装配在一起。
//!
//! 宿主每次配置变化都整体重建（[`Core::start`]），不做增量更新——配置项之间
//! 互相牵连（DoH 换了要换解析器、代理换了要清连接池），整体重建比逐项同步可靠。

use std::sync::Arc;
use std::time::Duration;

use tracing::info;

use crate::NetConfig;
use crate::cert;
use crate::client::HttpEgressClient;
use crate::dns::DnsResolver;
use crate::egress::EgressConnector;
use crate::error::Result;
use crate::listener::Listener;
use crate::mirror::{FingerprintTemplates, MirrorRelay};
use crate::system_proxy;

pub struct Core {
    client: Arc<HttpEgressClient>,
    /// DoH 解析器（未启用 DoH 时为 None），切网时一并清它到 DoH 服务器的连接
    dns: Option<Arc<crate::dns::DnsResolver>>,
    listener: Arc<Listener>,
    /// 接受连接的任务；停止时等它退出，确保端口真正释放后才能重绑
    serve_task: parking_lot::Mutex<Option<tokio::task::JoinHandle<()>>>,
    templates: Arc<FingerprintTemplates>,
    config: NetConfig,
}

impl Core {
    pub fn verify_webview_leaf(&self, der: &[u8], host: &str) -> bool {
        if !self.config.webview_mitm {
            return false;
        }
        let ca = match (&self.config.ca_cert_pem, &self.config.ca_key_pem) {
            (Some(cert), Some(_)) => cert.as_str(),
            _ => crate::cert::embedded_ca_pem(),
        };
        crate::cert::verify_webview_leaf(ca, der, host)
    }

    pub async fn start(config: NetConfig) -> Result<Arc<Self>> {
        let templates = Arc::new(FingerprintTemplates::with_selection(
            config
                .fingerprint_cache_path
                .as_ref()
                .map(std::path::PathBuf::from),
            config
                .fingerprint_platform
                .as_deref()
                .unwrap_or(std::env::consts::OS),
            config.fingerprint_user_agent.as_deref(),
            config.fingerprint_preset.as_deref(),
        )?);

        // DoH 开启时才建解析器；关闭时出站走系统 DNS
        let dns = match (config.enable_doh, config.doh_server.as_deref()) {
            (true, Some(server)) => Some(
                DnsResolver::shared_with_policy(
                    server,
                    config.doh_server_ech.as_deref(),
                    config.prefer_ipv6,
                    config.upstream_proxy.clone(),
                    config.system_proxy.clone(),
                    config.ech_dns_policy.clone(),
                )
                .await?,
            ),
            _ => None,
        };

        let connector = Arc::new(EgressConnector::new(
            dns,
            config.upstream_proxy.clone(),
            config.system_proxy.clone(),
            config.server_ip.as_deref(),
            Duration::from_secs(config.timeout_secs),
        ));
        let namespace = serde_json::to_string(&(
            config.enable_doh,
            &config.doh_server,
            &config.doh_server_ech,
            &config.ech_dns_policy,
            &config.server_ip,
            config.upstream_proxy.as_ref().map(|p| p.cache_key()),
            config.system_proxy.as_ref().map(|p| p.cache_key()),
        ))
        .unwrap_or_default();
        let mut sessions = crate::browser_tls::ClientSessions::default();
        if let (Some(path), Some(key)) = (
            &config.tls_session_cache_path,
            &config.tls_session_cache_key,
        ) {
            match crate::session_cache::TicketStore::open(path.into(), key) {
                Ok(store) => {
                    sessions = sessions.with_persistence(store, namespace.clone());
                }
                Err(_) => tracing::warn!("TLS ticket storage unavailable; using memory sessions"),
            }
        }
        let client = Arc::new(
            HttpEgressClient::new(connector.clone(), Some(templates.clone()))
                .with_sessions(sessions)
                .with_http3_cache(config.http3_cache_path.as_deref(), &namespace),
        );
        let dns = connector.dns().cloned();

        // WebView 经本地监听做 MITM 时才需要镜像出口；直连模式只保留采样端点
        let mirror = if config.webview_mitm {
            let (cert_pem, key_pem) = match (&config.ca_cert_pem, &config.ca_key_pem) {
                (Some(cert), Some(key)) => (cert.as_str(), key.as_str()),
                _ => (cert::embedded_ca_pem(), cert::embedded_ca_key_pem()),
            };
            info!("WebView MITM uses browser fingerprint mirror egress");
            Some(Arc::new(MirrorRelay::new(
                cert_pem,
                key_pem,
                templates.clone(),
            )?))
        } else {
            None
        };

        let listener = Arc::new(Listener::new(connector, mirror, templates.clone())?);
        let socket = listener.bind(&config.bind_addr, config.bind_port).await?;
        let serve_task = tokio::spawn(listener.clone().serve(socket));

        Ok(Arc::new(Self {
            client,
            dns,
            listener,
            serve_task: parking_lot::Mutex::new(Some(serve_task)),
            templates,
            config,
        }))
    }

    pub fn client(&self) -> Arc<HttpEgressClient> {
        self.client.clone()
    }

    /// 每次插件请求使用独立客户端，不复用论坛会话、连接池或 Alt-Svc。
    pub fn pinned_client(&self, ips: Vec<std::net::IpAddr>) -> Arc<HttpEgressClient> {
        let connector = EgressConnector::new(
            None,
            self.config.upstream_proxy.clone(),
            self.config.system_proxy.clone(),
            None,
            Duration::from_secs(self.config.timeout_secs),
        )
        .with_pins(ips);
        Arc::new(HttpEgressClient::new(Arc::new(connector), None))
    }

    pub fn port(&self) -> Option<u16> {
        self.listener.port()
    }

    /// 停止本地监听并等端口释放。客户端不受影响：在途请求照常走完，
    /// 重启期间新请求也仍由旧实例承接，直到新实例就位。
    pub async fn stop_listener(&self) {
        self.listener.stop();
        let task = self.serve_task.lock().take();
        if let Some(task) = task {
            let _ = task.await;
        }
    }

    pub async fn reset_connections(&self) {
        self.client.reset_connections().await;
        if let Some(dns) = &self.dns {
            dns.reset_connections().await;
        }
        system_proxy::clear_pac_cache();
    }

    /// 宿主用于判断「dio 现在能不能按浏览器指纹出站」以及是否需要重新采样。
    pub fn status_json(&self) -> String {
        let template = self.templates.snapshot();
        serde_json::json!({
            "running": true,
            "established_connections": self.client.established_connections(),
            "pooled_connections": {
                "http2": self.client.pooled_connections().0,
                "http3": self.client.pooled_http3_connections(),
                "http1_idle": self.client.pooled_connections().1,
            },
            "port": self.port(),
            "template_ready": template.as_ref().is_some_and(|template| template.source.id().is_none()),
            "template_source": template.as_ref().map(|template| template.source.name()),
            "template_mode": if self.config.fingerprint_preset.is_some() { "preset" } else { "auto" },
            "template_preset": template.as_ref().and_then(|template| template.source.id()),
            "user_agent": template.and_then(|template| template.user_agent),
            "webview_mitm": self.config.webview_mitm,
            "doh": self.config.enable_doh,
            "system_proxy": self.config.system_proxy.is_some() || system_proxy::configured(),
        })
        .to_string()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// 重启必须能绑回原端口：Windows 的 WebView2 把代理端口定死在环境里，换端口它就连不上。
    #[tokio::test]
    async fn restart_rebinds_the_same_port() {
        let first = Core::start(NetConfig::default()).await.unwrap();
        let port = first.port().expect("listener bound");

        first.stop_listener().await;
        let second = Core::start(NetConfig {
            bind_port: port,
            ..NetConfig::default()
        })
        .await
        .expect("port released by the previous instance");
        assert_eq!(second.port(), Some(port));
        second.stop_listener().await;
    }
}
