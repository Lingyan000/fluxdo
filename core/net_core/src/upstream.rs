use crate::error::{NetError, Result};
use crate::{BoxStream, UpstreamProxyConfig};
use base64::Engine;
use base64::engine::general_purpose::STANDARD;
use shadowsocks::{
    ProxyClientStream,
    config::{ServerAddr, ServerConfig, ServerType},
    context::Context,
    crypto::CipherKind,
    relay::socks5::Address,
};
use std::net::{IpAddr, SocketAddr};
use tokio::io::{AsyncBufReadExt, AsyncReadExt, AsyncWriteExt, BufReader};
use tokio::net::TcpStream;
use tracing::{debug, info, warn};

impl UpstreamProxyConfig {
    pub fn proxy_url(&self) -> String {
        if self.is_socks5() {
            return format!("socks5h://{}:{}", self.host, self.port);
        }
        if self.is_shadowsocks() {
            return format!("ss://{}:{}", self.host, self.port);
        }

        format!("http://{}:{}", self.host, self.port)
    }

    pub fn basic_auth_header(&self) -> Option<String> {
        let (username, password) = self.auth_pair()?;
        let encoded = STANDARD.encode(format!("{}:{}", username, password));
        Some(format!("Basic {}", encoded))
    }

    fn auth_pair(&self) -> Option<(&str, &str)> {
        let username = self.username.as_deref()?.trim();
        let password = self.password.as_deref().unwrap_or("").trim();
        if username.is_empty() {
            return None;
        }
        Some((username, password))
    }

    fn shadowsocks_password(&self) -> Option<&str> {
        let password = self.password.as_deref()?.trim();
        if password.is_empty() {
            return None;
        }
        Some(password)
    }

    fn shadowsocks_cipher(&self) -> Option<&str> {
        let cipher = self.cipher.as_deref()?.trim();
        if cipher.is_empty() {
            return None;
        }
        Some(cipher)
    }
}

pub async fn connect_tunnel(
    proxy: &UpstreamProxyConfig,
    target_host: &str,
    target_port: u16,
) -> Result<BoxStream> {
    if proxy.is_http() {
        connect_http_tunnel(proxy, target_host, target_port).await
    } else if proxy.is_socks5() {
        connect_socks5_tunnel(proxy, target_host, target_port).await
    } else if proxy.is_shadowsocks() {
        connect_shadowsocks_tunnel(proxy, target_host, target_port).await
    } else {
        Err(NetError::Proxy(format!(
            "Unsupported upstream proxy protocol: {}",
            proxy.protocol()
        )))
    }
}

pub async fn connect_http_tunnel(
    proxy: &UpstreamProxyConfig,
    target_host: &str,
    target_port: u16,
) -> Result<BoxStream> {
    if !proxy.is_http() {
        return Err(NetError::Proxy(format!(
            "Unsupported upstream HTTP proxy protocol: {}",
            proxy.protocol()
        )));
    }

    if !proxy.is_valid() {
        return Err(NetError::Proxy(
            "Invalid upstream proxy configuration".to_string(),
        ));
    }

    let authority = format!("{}:{}", target_host, target_port);
    info!(
        "Connecting to upstream HTTP proxy {} for {}",
        proxy.proxy_url(),
        authority
    );

    let mut stream = TcpStream::connect((proxy.host.as_str(), proxy.port)).await?;
    let mut request = format!(
        "CONNECT {} HTTP/1.1\r\nHost: {}\r\nProxy-Connection: Keep-Alive\r\n",
        authority, authority
    );
    if let Some(auth_header) = proxy.basic_auth_header() {
        request.push_str(&format!("Proxy-Authorization: {}\r\n", auth_header));
    }
    request.push_str("\r\n");

    stream.write_all(request.as_bytes()).await?;
    stream.flush().await?;

    let mut reader = BufReader::new(stream);
    let mut status_line = String::new();
    reader.read_line(&mut status_line).await?;

    if status_line.trim().is_empty() {
        return Err(NetError::Proxy(
            "Empty response from upstream HTTP proxy".to_string(),
        ));
    }

    let status_code = status_line
        .split_whitespace()
        .nth(1)
        .and_then(|value| value.parse::<u16>().ok())
        .ok_or_else(|| {
            NetError::Proxy(format!(
                "Invalid upstream HTTP proxy response status line: {}",
                status_line.trim()
            ))
        })?;

    let mut proxy_authenticate = None;
    loop {
        let mut line = String::new();
        reader.read_line(&mut line).await?;
        let trimmed = line.trim();
        if trimmed.is_empty() {
            break;
        }

        if trimmed
            .to_ascii_lowercase()
            .starts_with("proxy-authenticate:")
        {
            proxy_authenticate = Some(trimmed.to_string());
        }
    }

    let stream = reader.into_inner();
    match status_code {
        200 => {
            debug!("Upstream HTTP proxy tunnel established for {}", authority);
            Ok(Box::new(stream))
        }
        407 => {
            if let Some(header) = proxy_authenticate {
                warn!("Upstream HTTP proxy auth challenge: {}", header);
            }
            Err(NetError::Proxy(
                "Upstream HTTP proxy authentication failed (407)".to_string(),
            ))
        }
        status => Err(NetError::Proxy(format!(
            "Upstream HTTP proxy CONNECT failed with status {}",
            status
        ))),
    }
}

pub async fn connect_socks5_tunnel(
    proxy: &UpstreamProxyConfig,
    target_host: &str,
    target_port: u16,
) -> Result<BoxStream> {
    if !proxy.is_socks5() {
        return Err(NetError::Proxy(format!(
            "Unsupported upstream SOCKS5 proxy protocol: {}",
            proxy.protocol()
        )));
    }

    if !proxy.is_valid() {
        return Err(NetError::Proxy(
            "Invalid upstream proxy configuration".to_string(),
        ));
    }

    info!(
        "Connecting to upstream SOCKS5 proxy {} for {}:{}",
        proxy.proxy_url(),
        target_host,
        target_port
    );

    let mut stream = TcpStream::connect((proxy.host.as_str(), proxy.port)).await?;
    let has_auth = proxy.auth_pair().is_some();
    let methods = if has_auth {
        vec![0x00, 0x02]
    } else {
        vec![0x00]
    };

    let mut hello = Vec::with_capacity(2 + methods.len());
    hello.push(0x05);
    hello.push(methods.len() as u8);
    hello.extend_from_slice(&methods);
    stream.write_all(&hello).await?;
    stream.flush().await?;

    let mut greet = [0u8; 2];
    stream.read_exact(&mut greet).await?;
    if greet[0] != 0x05 {
        return Err(NetError::Proxy(format!(
            "Invalid SOCKS5 greeting version: {}",
            greet[0]
        )));
    }

    match greet[1] {
        0x00 => {}
        0x02 => {
            let (username, password) = proxy.auth_pair().ok_or_else(|| {
                NetError::Proxy("SOCKS5 proxy requested username/password auth".to_string())
            })?;
            let username_bytes = username.as_bytes();
            let password_bytes = password.as_bytes();
            if username_bytes.len() > u8::MAX as usize || password_bytes.len() > u8::MAX as usize {
                return Err(NetError::Proxy(
                    "SOCKS5 username or password is too long".to_string(),
                ));
            }

            let mut auth = Vec::with_capacity(3 + username_bytes.len() + password_bytes.len());
            auth.push(0x01);
            auth.push(username_bytes.len() as u8);
            auth.extend_from_slice(username_bytes);
            auth.push(password_bytes.len() as u8);
            auth.extend_from_slice(password_bytes);
            stream.write_all(&auth).await?;
            stream.flush().await?;

            let mut auth_reply = [0u8; 2];
            stream.read_exact(&mut auth_reply).await?;
            if auth_reply[1] != 0x00 {
                return Err(NetError::Proxy(
                    "Upstream SOCKS5 authentication failed".to_string(),
                ));
            }
        }
        0xFF => {
            return Err(NetError::Proxy(
                "Upstream SOCKS5 proxy rejected available auth methods".to_string(),
            ));
        }
        method => {
            return Err(NetError::Proxy(format!(
                "Upstream SOCKS5 proxy returned unsupported auth method 0x{:02x}",
                method
            )));
        }
    }

    let host_bytes = target_host.as_bytes();
    if host_bytes.len() > u8::MAX as usize {
        return Err(NetError::Proxy(
            "SOCKS5 target host is too long".to_string(),
        ));
    }

    let mut request = Vec::with_capacity(7 + host_bytes.len());
    request.extend_from_slice(&[0x05, 0x01, 0x00, 0x03, host_bytes.len() as u8]);
    request.extend_from_slice(host_bytes);
    request.push((target_port >> 8) as u8);
    request.push((target_port & 0xff) as u8);
    stream.write_all(&request).await?;
    stream.flush().await?;

    let mut head = [0u8; 4];
    stream.read_exact(&mut head).await?;
    if head[0] != 0x05 {
        return Err(NetError::Proxy(format!(
            "Invalid SOCKS5 CONNECT response version: {}",
            head[0]
        )));
    }
    if head[1] != 0x00 {
        return Err(NetError::Proxy(format!(
            "Upstream SOCKS5 CONNECT failed: {}",
            socks5_reply_message(head[1])
        )));
    }

    match head[3] {
        0x01 => {
            let mut skip = [0u8; 6];
            stream.read_exact(&mut skip).await?;
        }
        0x04 => {
            let mut skip = [0u8; 18];
            stream.read_exact(&mut skip).await?;
        }
        0x03 => {
            let mut len = [0u8; 1];
            stream.read_exact(&mut len).await?;
            let mut skip = vec![0u8; len[0] as usize + 2];
            stream.read_exact(&mut skip).await?;
        }
        atyp => {
            return Err(NetError::Proxy(format!(
                "Upstream SOCKS5 CONNECT returned unknown address type 0x{:02x}",
                atyp
            )));
        }
    }

    debug!(
        "Upstream SOCKS5 tunnel established for {}:{}",
        target_host, target_port
    );
    Ok(Box::new(stream))
}

pub async fn connect_shadowsocks_tunnel(
    proxy: &UpstreamProxyConfig,
    target_host: &str,
    target_port: u16,
) -> Result<BoxStream> {
    if !proxy.is_shadowsocks() {
        return Err(NetError::Proxy(format!(
            "Unsupported upstream Shadowsocks protocol: {}",
            proxy.protocol()
        )));
    }

    if !proxy.is_valid() {
        return Err(NetError::Proxy(
            "Invalid Shadowsocks configuration".to_string(),
        ));
    }

    let cipher_name = proxy
        .shadowsocks_cipher()
        .ok_or_else(|| NetError::Proxy("Missing Shadowsocks cipher".to_string()))?;
    let cipher = parse_shadowsocks_cipher(cipher_name)?;
    let password = proxy
        .shadowsocks_password()
        .ok_or_else(|| NetError::Proxy("Missing Shadowsocks password".to_string()))?;
    let server_addr = build_server_addr(&proxy.host, proxy.port);
    let server_config = ServerConfig::new(server_addr, password.to_string(), cipher)
        .map_err(|error| NetError::Proxy(format!("Invalid Shadowsocks config: {}", error)))?;
    let context = Context::new_shared(ServerType::Local);
    let target = Address::from((target_host.to_string(), target_port));

    info!(
        "Connecting to upstream Shadowsocks proxy {} for {}:{} with cipher {}",
        proxy.proxy_url(),
        target_host,
        target_port,
        cipher_name
    );

    let stream = ProxyClientStream::connect(context, &server_config, target)
        .await
        .map_err(|error| {
            NetError::Proxy(format!("Upstream Shadowsocks CONNECT failed: {}", error))
        })?;
    Ok(Box::new(stream))
}

fn socks5_reply_message(code: u8) -> &'static str {
    match code {
        0x01 => "general failure",
        0x02 => "connection not allowed by ruleset",
        0x03 => "network unreachable",
        0x04 => "host unreachable",
        0x05 => "connection refused",
        0x06 => "TTL expired",
        0x07 => "command not supported",
        0x08 => "address type not supported",
        _ => "unknown error",
    }
}

fn build_server_addr(host: &str, port: u16) -> ServerAddr {
    match host.parse::<IpAddr>() {
        Ok(ip) => ServerAddr::SocketAddr(SocketAddr::new(ip, port)),
        Err(_) => ServerAddr::DomainName(host.to_string(), port),
    }
}

fn parse_shadowsocks_cipher(cipher: &str) -> Result<CipherKind> {
    match cipher.trim().to_ascii_lowercase().as_str() {
        "aes-128-gcm" => Ok(CipherKind::AES_128_GCM),
        "aes-256-gcm" => Ok(CipherKind::AES_256_GCM),
        "chacha20-ietf-poly1305" => Ok(CipherKind::CHACHA20_POLY1305),
        "2022-blake3-aes-256-gcm" => Ok(CipherKind::AEAD2022_BLAKE3_AES_256_GCM),
        other => Err(NetError::Proxy(format!(
            "Unsupported Shadowsocks cipher: {}",
            other
        ))),
    }
}
