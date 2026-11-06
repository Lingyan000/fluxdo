//! 本地监听：只服务本机的 WebView 与指纹采样，固定绑回环地址。
//!
//! 按连接首字节分流：
//! - TLS 握手（0x16）→ 指纹采样端点（[`crate::probe`]），WebView 直接访问
//!   `https://localhost:<端口>/fluxdo-probe`；
//! - `CONNECT host:port` → WebView 的代理请求。DoH / 代理模式下走镜像 MITM
//!   （[`crate::mirror`]），CF 验证域走隧道直连（MITM 会被 Turnstile 识破）；
//! - `GET /__fluxdo/template` → 宿主查询模板状态。
//!
//! dio 的请求**不走**这里，它经 FFI 直接进 [`crate::client`]，不占回环 socket。

use std::{
    io::Cursor,
    net::SocketAddr,
    pin::Pin,
    sync::Arc,
    task::{Context, Poll},
};

use parking_lot::RwLock;
use tokio::{
    io::{AsyncBufReadExt, AsyncRead, AsyncWrite, AsyncWriteExt, BufReader, ReadBuf},
    net::{TcpListener, TcpStream},
};
use tokio_util::sync::CancellationToken;
use tracing::{debug, error, info, warn};

use crate::egress::EgressConnector;
use crate::error::{NetError, Result};
use crate::mirror::{FingerprintTemplates, MirrorRelay};
use crate::probe::{ProbeEndpoint, TLS_HANDSHAKE_RECORD};

/// 宿主查询模板状态的路径。
const TEMPLATE_STATUS_PATH: &str = "/__fluxdo/template";

/// 本地监听器。
pub struct Listener {
    connector: Arc<EgressConnector>,
    /// WebView MITM 的镜像出口；None 表示本次不做 MITM（直连模式）
    mirror: Option<Arc<MirrorRelay>>,
    probe: Arc<ProbeEndpoint>,
    templates: Arc<FingerprintTemplates>,
    local_addr: Arc<RwLock<Option<SocketAddr>>>,
    /// 关停信号。用电平触发的令牌而非广播：广播在订阅前发出就丢了，
    /// 刚启动就重启时监听会永远不退出、端口永远不释放。
    shutdown: CancellationToken,
}

impl Listener {
    pub fn new(
        connector: Arc<EgressConnector>,
        mirror: Option<Arc<MirrorRelay>>,
        templates: Arc<FingerprintTemplates>,
    ) -> Result<Self> {
        Ok(Self {
            connector,
            mirror,
            probe: Arc::new(ProbeEndpoint::new(templates.clone())?),
            templates,
            local_addr: Arc::new(RwLock::new(None)),
            shutdown: CancellationToken::new(),
        })
    }

    pub fn local_addr(&self) -> Option<SocketAddr> {
        *self.local_addr.read()
    }

    pub fn port(&self) -> Option<u16> {
        self.local_addr().map(|addr| addr.port())
    }

    /// 绑定端口。返回后 [`Self::port`] 即可用，调用方再 spawn [`Self::serve`]。
    pub async fn bind(&self, bind_addr: &str, bind_port: u16) -> Result<TcpListener> {
        let listener = TcpListener::bind((bind_addr, bind_port)).await?;
        let local_addr = listener.local_addr()?;
        *self.local_addr.write() = Some(local_addr);
        info!("Local listener on {local_addr}");
        Ok(listener)
    }

    /// 接受连接直到 [`Self::stop`]。
    pub async fn serve(self: Arc<Self>, listener: TcpListener) {
        loop {
            tokio::select! {
                biased;
                () = self.shutdown.cancelled() => {
                    info!("Local listener shutting down");
                    break;
                }
                result = listener.accept() => match result {
                    Ok((stream, peer)) => {
                        let this = self.clone();
                        tokio::spawn(async move {
                            if let Err(e) = this.handle(stream).await {
                                debug!("Connection from {peer} ended: {e}");
                            }
                        });
                    }
                    Err(e) => error!("Accept error: {e}"),
                },
            }
        }
    }

    pub fn stop(&self) {
        self.shutdown.cancel();
    }

    async fn handle(&self, stream: TcpStream) -> Result<()> {
        // 首字节是 TLS 握手：采样探针直接以 https 访问本端口
        let mut first = [0u8; 1];
        if matches!(stream.peek(&mut first).await, Ok(1)) && first[0] == TLS_HANDSHAKE_RECORD {
            return self.probe.serve(stream).await;
        }

        let (read_half, mut writer) = stream.into_split();
        let mut reader = BufReader::new(read_half);
        let mut request_line = String::new();
        reader.read_line(&mut request_line).await?;
        let mut parts = request_line.split_whitespace();
        let (Some(method), Some(target)) = (parts.next(), parts.next()) else {
            return Err(NetError::Parse("Invalid request line".to_owned()));
        };
        let (method, target) = (method.to_owned(), target.to_owned());

        match method.as_str() {
            "CONNECT" => self.handle_connect(reader, writer, &target).await,
            "GET" if target.starts_with(TEMPLATE_STATUS_PATH) => {
                let body = self.templates.status_json();
                let response = format!(
                    "HTTP/1.1 200 OK\r\ncontent-type: application/json\r\n\
                     content-length: {}\r\nconnection: close\r\n\r\n{body}",
                    body.len()
                );
                writer.write_all(response.as_bytes()).await?;
                Ok(())
            }
            _ => {
                writer
                    .write_all(b"HTTP/1.1 400 Bad Request\r\nconnection: close\r\n\r\n")
                    .await?;
                Ok(())
            }
        }
    }

    async fn handle_connect(
        &self,
        mut reader: BufReader<tokio::net::tcp::OwnedReadHalf>,
        mut writer: tokio::net::tcp::OwnedWriteHalf,
        target: &str,
    ) -> Result<()> {
        let (host, port) = parse_host_port(target);
        // 请求头读完丢弃：CONNECT 的头对转发没有意义
        loop {
            let mut line = String::new();
            if reader.read_line(&mut line).await? == 0 || line.trim().is_empty() {
                break;
            }
        }

        // CF 验证域必须端到端直连：MITM 会被 Turnstile 识破而拒绝人机验证
        let tunnel = is_cf_challenge_host(&host);
        let mirror = self.mirror.clone().filter(|_| !tunnel);

        if tunnel || mirror.is_none() {
            info!("CONNECT (tunnel) {host}:{port}");
            let upstream = match self.connector.connect_raw(&host, port).await {
                Ok(upstream) => upstream,
                Err(e) => {
                    warn!("Tunnel connect failed {host}:{port}: {e}");
                    writer
                        .write_all(b"HTTP/1.1 502 Bad Gateway\r\nconnection: close\r\n\r\n")
                        .await?;
                    return Err(e);
                }
            };
            writer
                .write_all(b"HTTP/1.1 200 Connection Established\r\n\r\n")
                .await?;
            let mut client = reunite(reader, writer)?;
            let mut upstream = upstream;
            // 双向转发并传递半关闭：一侧读到 EOF 就 shutdown 对侧写端
            let _ = tokio::io::copy_bidirectional(&mut client, &mut upstream).await;
            return Ok(());
        }

        let mirror = mirror.expect("mirror present when not tunnelling");
        info!("CONNECT (mirror) {host}:{port}");
        // 先回 200：镜像要先看到 WebView 的 ClientHello 才能决定怎么连上游
        writer
            .write_all(b"HTTP/1.1 200 Connection Established\r\n\r\n")
            .await?;
        let client = reunite(reader, writer)?;
        mirror
            .serve(client, self.connector.clone(), host, port)
            .await
    }
}

/// 把拆开的读写两半拼回单个流，并带上 BufReader 已经读进缓冲、尚未消费的字节。
fn reunite(
    reader: BufReader<tokio::net::tcp::OwnedReadHalf>,
    writer: tokio::net::tcp::OwnedWriteHalf,
) -> Result<PrefixedStream<TcpStream>> {
    let buffered = reader.buffer().to_vec();
    let stream = reader
        .into_inner()
        .reunite(writer)
        .map_err(|_| NetError::Proxy("Failed to reunite TCP stream halves".to_owned()))?;
    Ok(PrefixedStream::new(stream, buffered))
}

/// 解析 CONNECT 的 `host:port`，缺省端口 443。
fn parse_host_port(target: &str) -> (String, u16) {
    if let Some(rest) = target.strip_prefix('[')
        && let Some((host, tail)) = rest.split_once(']')
    {
        let port = tail
            .strip_prefix(':')
            .and_then(|port| port.parse().ok())
            .unwrap_or(443);
        return (host.to_owned(), port);
    }
    match target.rsplit_once(':') {
        Some((host, port)) => (host.to_owned(), port.parse().unwrap_or(443)),
        None => (target.to_owned(), 443),
    }
}

/// 是否为 Cloudflare 验证（Turnstile）基础设施域名。
///
/// challenges.cloudflare.com 是 CF Turnstile 全球统一的固定域名（api.js 与
/// challenge-platform 都在此域，挑战过程还会访问其子域），属协议级常量而非可变业务白名单。
/// 对它做 MITM 会被 CF 挑战平台识破（TLS 指纹 / 证书不符）而拒绝人机验证。
fn is_cf_challenge_host(host: &str) -> bool {
    let host = host.trim_end_matches('.').to_ascii_lowercase();
    host == "challenges.cloudflare.com" || host.ends_with(".challenges.cloudflare.com")
}

/// 读取时先吐出已缓冲的前缀字节，再转到底层流。
struct PrefixedStream<S> {
    prefix: Cursor<Vec<u8>>,
    inner: S,
}

impl<S> PrefixedStream<S> {
    fn new(inner: S, prefix: Vec<u8>) -> Self {
        Self {
            prefix: Cursor::new(prefix),
            inner,
        }
    }
}

impl<S: AsyncRead + Unpin> AsyncRead for PrefixedStream<S> {
    fn poll_read(
        mut self: Pin<&mut Self>,
        cx: &mut Context<'_>,
        buf: &mut ReadBuf<'_>,
    ) -> Poll<std::io::Result<()>> {
        let position = self.prefix.position() as usize;
        let prefix = self.prefix.get_ref();
        if position < prefix.len() {
            let remaining = &prefix[position..];
            let to_copy = remaining.len().min(buf.remaining());
            buf.put_slice(&remaining[..to_copy]);
            self.prefix.set_position((position + to_copy) as u64);
            return Poll::Ready(Ok(()));
        }
        Pin::new(&mut self.inner).poll_read(cx, buf)
    }
}

impl<S: AsyncWrite + Unpin> AsyncWrite for PrefixedStream<S> {
    fn poll_write(
        mut self: Pin<&mut Self>,
        cx: &mut Context<'_>,
        buf: &[u8],
    ) -> Poll<std::io::Result<usize>> {
        Pin::new(&mut self.inner).poll_write(cx, buf)
    }

    fn poll_flush(mut self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<std::io::Result<()>> {
        Pin::new(&mut self.inner).poll_flush(cx)
    }

    fn poll_shutdown(mut self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<std::io::Result<()>> {
        Pin::new(&mut self.inner).poll_shutdown(cx)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn cf_challenge_host_covers_subdomains_only() {
        for host in [
            "challenges.cloudflare.com",
            "Challenges.Cloudflare.com.",
            "brunhild.challenges.cloudflare.com",
        ] {
            assert!(is_cf_challenge_host(host), "{host}");
        }
        for host in [
            "cloudflare.com",
            "evilchallenges.cloudflare.com",
            "challenges.cloudflare.com.evil",
        ] {
            assert!(!is_cf_challenge_host(host), "{host}");
        }
    }

    #[test]
    fn parses_connect_targets() {
        assert_eq!(
            parse_host_port("linux.do:443"),
            ("linux.do".to_owned(), 443)
        );
        assert_eq!(parse_host_port("linux.do"), ("linux.do".to_owned(), 443));
        assert_eq!(parse_host_port("[::1]:8443"), ("::1".to_owned(), 8443));
        assert_eq!(parse_host_port("[::1]"), ("::1".to_owned(), 443));
    }
}
