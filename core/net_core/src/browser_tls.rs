//! 浏览器 TLS 指纹出口：按参考握手构造上游 BoringSSL 连接配置。
//!
//! 参考握手有两种来源：MITM 时 WebView 当场发来的 ClientHello（镜像），
//! 或之前存下的模板（回放）。两者都经过 [`build`]，规则只在这一处：
//!
//! - 套件默认逐个照抄参考握手（rama 的原样写入）。
//! - 注入真 ECH 时改用 BoringSSL 标准接口：按参考握手的 TLS 1.2 套件顺序写成标准套件名。
//!   rama 的原样写入会把完整套件同时写进 ECH 内外层，内层混入 TLS 1.2 套件，
//!   与真浏览器不符；标准接口下内层由 BoringSSL 原版逻辑只写 TLS 1.3 套件。
//!   Chromium 本身就是 BoringSSL，结果与参考握手逐字相同；Safari 等非 Chromium 客户端
//!   外层会少掉 BoringSSL 不支持的老套件（如 3DES 的 ECDHE 变体），以换取正确的内层。
//! - 所有客户端都注入 ECH（可用性优先）；Chromium 系额外请求 server padding，与 Chrome 一致。
//! - Chromium 系每条连接重新打乱扩展顺序、重新生成 GREASE，与浏览器行为一致。

use std::io::{self, Read, Write};
use std::num::NonZeroUsize;
use std::sync::Arc;

use rama::{
    error::BoxError,
    net::address::Host,
    tls::{
        CipherSuite, ExtensionId,
        boring::{
            client::{
                BoringClientConfigExt as _, TlsClientSessionCache, TlsClientSessionDomain,
                TlsClientSessionStore, TlsConnectorContextBuilder, TlsConnectorData,
            },
            core::ssl::{HandshakeError, SslCipher, UnknownValues},
        },
        client::{ClientHello, TlsClientConfig, parse_client_hello_handshake},
    },
};

/// ALPS 新旧两个码点，只有 Chromium 系发送。
const ALPS_CODEPOINTS: [u16; 2] = [0x44cd, 0x4469];
/// Chrome 启用真 ECH 时一并请求服务端填充（server padding request）。
const SERVER_PADDING_REQUEST: u16 = 0x12e0;

/// 套件写入方式。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum CipherMode {
    /// 逐个照抄参考握手。
    Copy,
    /// 按参考握手的 TLS 1.2 套件顺序经标准接口设置，内层由 BoringSSL 生成（仅注入 ECH 时）。
    Standard,
}

/// 构造结果。
pub struct BrowserEgress {
    pub connector_data: TlsConnectorData,
    pub cipher_mode: CipherMode,
    pub ech_applied: bool,
}

/// 客户端 TLS 会话复用：新连接带上同站点之前拿到的会话票据（TLS 1.3 PSK），
/// 与浏览器一致——浏览器对同一站点的后续连接都会恢复会话，而不是每次完整握手。
///
/// 票据按「会话域 + 安全策略 + 服务器名」存取：每条连接各建一份 BoringSSL 上下文，
/// 同一个域内的上下文之间共享票据；模板换代导致策略变化时自然不再命中。
#[derive(Clone)]
pub struct ClientSessions {
    domain: TlsClientSessionDomain,
    store: Arc<dyn TlsClientSessionStore>,
    persistent: Option<Arc<crate::session_cache::TicketStore>>,
    namespace: Arc<str>,
    scope: Option<String>,
}

impl Default for ClientSessions {
    fn default() -> Self {
        Self {
            domain: TlsClientSessionDomain::new(),
            persistent: None,
            namespace: "".into(),
            scope: None,
            // 每站点留几张：TLS 1.3 票据一次性，服务端通常一次发两张
            store: Arc::new(TlsClientSessionCache::new(
                NonZeroUsize::new(256).unwrap(),
                NonZeroUsize::new(4).unwrap(),
            )),
        }
    }
}

impl ClientSessions {
    pub(crate) fn with_persistence(
        mut self,
        store: Arc<crate::session_cache::TicketStore>,
        namespace: String,
    ) -> Self {
        self.persistent = Some(store);
        self.namespace = namespace.into();
        self
    }
    pub(crate) fn for_peer(
        &self,
        host: &str,
        port: u16,
        hello: Option<&ClientHello>,
        ech: Option<&[u8]>,
    ) -> Self {
        let mut scoped = self.clone();
        if self.persistent.is_some() {
            scoped.scope = Some(crate::session_cache::scope(
                &self.namespace,
                host,
                port,
                hello,
                ech,
            ));
        }
        scoped
    }
    /// 按配置构造连接数据，并挂上本域的会话存取。
    pub fn connector_data(&self, config: &TlsClientConfig) -> Result<TlsConnectorData, BoxError> {
        config.insert(self.domain);
        if let (Some(store), Some(scope)) = (&self.persistent, &self.scope) {
            let sink = store.clone();
            let scope_key = scope.clone();
            let builder = TlsConnectorContextBuilder::try_from(config)?.with_new_session_callback(
                move |_, session| sink.put(&scope_key, session.session()),
            );
            let mut data = builder.build().configure()?;
            if let Some(session) = store.take(scope) {
                // SAFETY: authenticated storage is keyed by origin, port, complete template,
                // ECH and network policy. This path always uses platform verification and TCP.
                // No 0-RTT is enabled; BoringSSL checks ticket expiry/version.
                unsafe {
                    data.config.set_session(&session)?;
                }
            }
            return Ok(data);
        }
        TlsConnectorContextBuilder::try_from(config)?
            .with_session_store(self.store.clone())
            .build()
            .configure()
    }
}

/// 按参考握手构造上游连接配置；`ech_config_list` 为服务端 HTTPS 记录里的 ECHConfigList，
/// `sessions` 为会话复用（镜像出口不复用：入站 WebView 自己决定是否恢复会话）。
pub fn build(
    hello: &ClientHello,
    server_name: Host,
    ech_config_list: Option<&[u8]>,
    sessions: Option<&ClientSessions>,
) -> Result<BrowserEgress, BoxError> {
    let chromium = is_chromium(hello);
    let mut config =
        TlsClientConfig::new_from_client_hello(hello).with_unknown_values(UnknownValues::Drop);
    config.set_server_name(server_name);
    // 交给平台校验器：企业与用户自装的 CA、系统的吊销策略都算数，与系统网络栈同待遇
    // （安卓还会遵循 network_security_config）。没有平台校验器的 Linux 由 rama 退回系统信任库。
    config.set_platform_verifier();
    if chromium {
        config.set_permute_extensions(true);
    }

    // 标准套件串为空（参考握手没有 BoringSSL 认识的 TLS 1.2 套件）时无法安全注入 ECH
    let ech = ech_config_list.and_then(|list| {
        let suites = standard_cipher_list(hello);
        if suites.is_none() {
            tracing::warn!("参考握手没有可用的标准套件，本连接不注入 ECH");
        }
        suites.map(|suites| (list, suites))
    });

    let mut connector_data = match sessions {
        Some(sessions) => sessions.connector_data(&config)?,
        None => TlsConnectorData::try_from(&config)?,
    };
    let cipher_mode = match &ech {
        Some((list, suites)) => {
            connector_data.config.set_strict_cipher_list(suites)?;
            if chromium && !has_extension(hello, SERVER_PADDING_REQUEST) {
                connector_data.config.set_server_padding_request(0);
            }
            connector_data.config.set_ech_config_list(list)?;
            CipherMode::Standard
        }
        None => CipherMode::Copy,
    };

    Ok(BrowserEgress {
        connector_data,
        cipher_mode,
        ech_applied: ech.is_some(),
    })
}

/// 握手是否来自浏览器（Chromium 与 WebKit 都在套件里放 GREASE；Dart IO、curl 等不放）。
/// 只有浏览器握手才能作为回放模板。
pub fn is_browser_like(hello: &ClientHello) -> bool {
    hello
        .cipher_suites()
        .iter()
        .any(|suite| is_grease(u16::from(*suite)))
}

/// 参考握手是否来自 Chromium 系（发送 GREASE ECH 或 ALPS）。
pub fn is_chromium(hello: &ClientHello) -> bool {
    has_extension(hello, u16::from(ExtensionId::ENCRYPTED_CLIENT_HELLO))
        || ALPS_CODEPOINTS.iter().any(|id| has_extension(hello, *id))
}

fn has_extension(hello: &ClientHello, id: u16) -> bool {
    hello
        .extensions()
        .iter()
        .any(|ext| u16::from(ext.id()) == id)
}

/// 参考握手的 TLS 1.2 套件按原顺序写成 BoringSSL 标准套件名（`:` 分隔）。
/// TLS 1.3 套件由 BoringSSL 固定生成（顺序取决于本机 AES 硬件加速，与同机浏览器一致），
/// GREASE 由 BoringSSL 自行插入；BoringSSL 不支持的套件跳过。
fn standard_cipher_list(hello: &ClientHello) -> Option<String> {
    let names: Vec<&str> = without_grease(hello.cipher_suites())
        .into_iter()
        .filter(|value| value >> 8 != 0x13)
        .filter_map(|value| SslCipher::from_value(value).map(|cipher| cipher.name()))
        .collect();
    (!names.is_empty()).then(|| names.join(":"))
}

fn without_grease(suites: &[CipherSuite]) -> Vec<u16> {
    suites
        .iter()
        .map(|suite| u16::from(*suite))
        .filter(|value| !is_grease(*value))
        .collect()
}

fn is_grease(value: u16) -> bool {
    value & 0x0f0f == 0x0a0a && value >> 8 == value & 0xff
}

/// 不联网取出连接配置将要发出的 ClientHello：对着只收不发的对端开始握手。
pub fn emit_client_hello(data: TlsConnectorData) -> Result<ClientHello, BoxError> {
    let ssl = data.into_ssl()?;
    match ssl.connect(HelloSink::default()) {
        Err(HandshakeError::WouldBlock(stream)) => {
            Ok(parse_client_hello_handshake(&stream.get_ref().0)?)
        }
        _ => Err(BoxError::from("握手未停在等待服务端响应的阶段")),
    }
}

#[derive(Debug, Default)]
struct HelloSink(Vec<u8>);

impl Read for HelloSink {
    fn read(&mut self, _: &mut [u8]) -> io::Result<usize> {
        Err(io::ErrorKind::WouldBlock.into())
    }
}

impl Write for HelloSink {
    fn write(&mut self, bytes: &[u8]) -> io::Result<usize> {
        self.0.extend_from_slice(bytes);
        Ok(bytes.len())
    }

    fn flush(&mut self) -> io::Result<()> {
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    // rama-tls-boring 测试用的服务端 ECHConfig（config id 1，public name ech.com）与私钥
    const ECH_CONFIG: &[u8] = &[
        0xfe, 0x0d, 0x00, 0x3a, 0x01, 0x00, 0x20, 0x00, 0x20, 0x7e, 0xfb, 0x5f, 0xee, 0xa2, 0xa2,
        0x74, 0xb3, 0xff, 0xfe, 0x69, 0x51, 0x9e, 0xfa, 0xe1, 0xfa, 0x49, 0x8c, 0x61, 0x2c, 0xfa,
        0xd0, 0x0f, 0x8c, 0x22, 0x87, 0x0e, 0xbc, 0xb0, 0x2d, 0x76, 0x25, 0x00, 0x08, 0x00, 0x01,
        0x00, 0x01, 0x00, 0x01, 0x00, 0x03, 0x00, 0x07, 0x65, 0x63, 0x68, 0x2e, 0x63, 0x6f, 0x6d,
        0x00, 0x00,
    ];
    const ECH_KEY: &[u8] = &[
        0xa7, 0x35, 0x44, 0x24, 0x6c, 0xfe, 0xb0, 0x53, 0x4c, 0x62, 0x7e, 0xca, 0x2e, 0x11, 0x8f,
        0x56, 0x3c, 0xc0, 0x2e, 0x6a, 0xa2, 0xe7, 0xaf, 0x3a, 0x7d, 0xb4, 0x72, 0x13, 0x1e, 0x88,
        0xb6, 0x85,
    ];

    fn chrome156() -> ClientHello {
        serde_json::from_str(include_str!(
            "../tests/fixtures/chrome156_linux_do_hello.json"
        ))
        .expect("parse fixture")
    }

    fn safari27() -> ClientHello {
        serde_json::from_str(include_str!("../tests/fixtures/safari_macos27_hello.json"))
            .expect("parse fixture")
    }

    fn ech_config_list() -> Vec<u8> {
        let mut list = (ECH_CONFIG.len() as u16).to_be_bytes().to_vec();
        list.extend_from_slice(ECH_CONFIG);
        list
    }

    fn ja4(hello: &ClientHello) -> String {
        rama::tls::fingerprint::Ja4::compute_from_client_hello(hello)
            .expect("ja4")
            .to_string()
    }

    fn emitted(egress: BrowserEgress) -> ClientHello {
        emit_client_hello(egress.connector_data).expect("emit hello")
    }

    fn extension_ids(hello: &ClientHello) -> Vec<u16> {
        let mut ids: Vec<u16> = hello
            .extensions()
            .iter()
            .map(|ext| u16::from(ext.id()))
            .filter(|id| !is_grease(*id))
            .collect();
        ids.sort_unstable();
        ids
    }

    /// 进程内持 ECH 私钥的 BoringSSL 服务端：按参考握手注入 ECH 连接，返回服务端解密出的内层。
    async fn ech_inner(hello: &ClientHello) -> (bool, ClientHello) {
        use rama::tls::{
            boring::core::{
                hpke::HpkeKey,
                pkey::PKey,
                ssl::{SslAcceptor, SslEchKeys, SslMethod},
                tokio::{SslStreamBuilder, accept},
                x509::X509,
            },
            client::parse_client_hello,
        };
        use std::sync::{Arc, Mutex};

        // 自签服务端证书（不引 rcgen，与核心生成 CA 走同一套 rama-crypto）
        let (chain, key) = rama_crypto::cert::generate_server_auth(
            rama_crypto::cert::GeneratedServerAuthConfig::generated_ca_for(
                rama::net::address::Domain::from_static("ech.com"),
            ),
        )
        .unwrap();
        let mut keys = SslEchKeys::builder().unwrap();
        keys.add_key(
            true,
            ECH_CONFIG,
            HpkeKey::dhkem_x25519_sha256(ECH_KEY).unwrap(),
        )
        .unwrap();
        let mut acceptor = SslAcceptor::mozilla_intermediate_v5(SslMethod::tls()).unwrap();
        acceptor
            .set_certificate(&X509::from_der(chain[0].as_ref()).unwrap())
            .unwrap();
        acceptor
            .set_private_key(&PKey::private_key_from_der(key.secret_der()).unwrap())
            .unwrap();
        acceptor.set_ech_keys(&keys.build()).unwrap();
        let seen: Arc<Mutex<Option<(bool, ClientHello)>>> = Arc::default();
        let sink = seen.clone();
        acceptor.set_select_certificate_callback(move |hello| {
            let accepted = hello.ssl().ech_accepted();
            if let Ok(parsed) = parse_client_hello(hello.as_bytes()) {
                *sink.lock().unwrap() = Some((accepted, parsed));
            }
            Ok(())
        });
        let acceptor = acceptor.build();

        let (client_io, server_io) = tokio::io::duplex(64 * 1024);
        let server = tokio::spawn(async move {
            let _ = accept(&acceptor, server_io).await;
        });
        let egress = build(
            hello,
            Host::from_static("linux.do"),
            Some(&ech_config_list()),
            None,
        )
        .unwrap();
        assert_eq!(egress.cipher_mode, CipherMode::Standard);
        assert!(egress.ech_applied);
        let ssl = egress.connector_data.into_ssl().unwrap();
        // 自签证书会让客户端校验失败，但服务端此前已在选证书回调里拿到内层
        let _ = SslStreamBuilder::new(ssl, client_io).connect().await;
        let _ = server.await;
        let result = seen.lock().unwrap().take().expect("inner ClientHello");
        result
    }

    /// 每条连接各建一份上下文，同一会话域内仍能恢复上一条连接拿到的会话。
    #[tokio::test]
    async fn sessions_resume_across_connections() {
        use rama::tls::{
            boring::core::{
                pkey::PKey,
                ssl::{SslAcceptor, SslMethod},
                tokio::{SslStreamBuilder, accept},
                x509::X509,
            },
            client::ServerVerifyMode,
        };
        use tokio::io::{AsyncReadExt, AsyncWriteExt};

        let (chain, key) = rama_crypto::cert::generate_server_auth(
            rama_crypto::cert::GeneratedServerAuthConfig::generated_ca_for(
                rama::net::address::Domain::from_static("resume.test"),
            ),
        )
        .unwrap();
        let mut acceptor = SslAcceptor::mozilla_intermediate_v5(SslMethod::tls()).unwrap();
        acceptor
            .set_certificate(&X509::from_der(chain[0].as_ref()).unwrap())
            .unwrap();
        acceptor
            .set_private_key(&PKey::private_key_from_der(key.secret_der()).unwrap())
            .unwrap();
        let acceptor = Arc::new(acceptor.build());

        let sessions = ClientSessions::default();
        let mut resumed = Vec::new();
        for _ in 0..2 {
            let (client_io, server_io) = tokio::io::duplex(64 * 1024);
            let acceptor = acceptor.clone();
            let server = tokio::spawn(async move {
                let mut stream = accept(&acceptor, server_io).await.unwrap();
                stream.write_all(b"!").await.unwrap();
                stream.flush().await.unwrap();
                let mut byte = [0u8; 1];
                let _ = stream.read(&mut byte).await;
            });
            let mut config = TlsClientConfig::default();
            config.set_server_name(Host::from_static("resume.test"));
            config.set_server_verify(ServerVerifyMode::Disable);
            let ssl = sessions
                .connector_data(&config)
                .unwrap()
                .into_ssl()
                .unwrap();
            let mut stream = SslStreamBuilder::new(ssl, client_io)
                .connect()
                .await
                .unwrap();
            // 读到应用数据时，前面的 NewSessionTicket 已经处理完
            let mut byte = [0u8; 1];
            stream.read_exact(&mut byte).await.unwrap();
            resumed.push(stream.ssl().session_reused());
            drop(stream);
            let _ = server.await;
        }
        assert_eq!(resumed, [false, true]);
    }

    #[tokio::test]
    async fn encrypted_sessions_resume_after_store_reload() {
        use rama::tls::{
            boring::core::{
                pkey::PKey,
                ssl::{SslAcceptor, SslMethod},
                tokio::{SslStreamBuilder, accept},
                x509::X509,
            },
            client::ServerVerifyMode,
        };
        use tokio::io::{AsyncReadExt, AsyncWriteExt};

        let (chain, key) = rama_crypto::cert::generate_server_auth(
            rama_crypto::cert::GeneratedServerAuthConfig::generated_ca_for(
                rama::net::address::Domain::from_static("resume.test"),
            ),
        )
        .unwrap();
        let mut acceptor = SslAcceptor::mozilla_intermediate_v5(SslMethod::tls()).unwrap();
        acceptor
            .set_certificate(&X509::from_der(chain[0].as_ref()).unwrap())
            .unwrap();
        acceptor
            .set_private_key(&PKey::private_key_from_der(key.secret_der()).unwrap())
            .unwrap();
        let acceptor = Arc::new(acceptor.build());

        use base64::{Engine as _, engine::general_purpose::STANDARD};
        let root = std::env::temp_dir().join(format!(
            "fluxdo-session-test-{}-{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        let key = STANDARD.encode([9u8; 32]);
        let first_store =
            crate::session_cache::TicketStore::open(root.join("first.bin"), &key).unwrap();
        let mut sessions =
            ClientSessions::default().with_persistence(first_store.clone(), "test-trust".into());
        let mut resumed = Vec::new();
        for i in 0..2 {
            let (client_io, server_io) = tokio::io::duplex(64 * 1024);
            let acceptor = acceptor.clone();
            let server = tokio::spawn(async move {
                let mut stream = accept(&acceptor, server_io).await.unwrap();
                stream.write_all(b"!").await.unwrap();
                stream.flush().await.unwrap();
                let mut byte = [0u8; 1];
                let _ = stream.read(&mut byte).await;
            });
            let mut config = TlsClientConfig::default();
            config.set_server_name(Host::from_static("resume.test"));
            config.set_server_verify(ServerVerifyMode::Disable);
            let ssl = sessions
                .for_peer("resume.test", 443, None, None)
                .connector_data(&config)
                .unwrap()
                .into_ssl()
                .unwrap();
            let mut stream = SslStreamBuilder::new(ssl, client_io)
                .connect()
                .await
                .unwrap();
            // 读到应用数据时，前面的 NewSessionTicket 已经处理完
            let mut byte = [0u8; 1];
            stream.read_exact(&mut byte).await.unwrap();
            resumed.push(stream.ssl().session_reused());
            drop(stream);
            let _ = server.await;
            if i == 0 {
                first_store.flush().unwrap();
                let wire = std::fs::read(root.join("first.bin")).unwrap();
                assert!(!String::from_utf8_lossy(&wire).contains("resume.test"));
                std::fs::write(root.join("reloaded.bin"), &wire).unwrap();
                let restored =
                    crate::session_cache::TicketStore::open(root.join("reloaded.bin"), &key)
                        .unwrap();
                sessions =
                    ClientSessions::default().with_persistence(restored, "test-trust".into());
            }
        }
        assert_eq!(resumed, [false, true]);
        tokio::time::sleep(std::time::Duration::from_millis(1200)).await;
        let _ = std::fs::remove_dir_all(root);
    }

    #[test]
    fn template_connections_offer_stored_sessions() {
        let sessions = ClientSessions::default();
        for hello in [chrome156(), safari27()] {
            let egress =
                build(&hello, Host::from_static("linux.do"), None, Some(&sessions)).unwrap();
            assert!(egress.connector_data.resumes_sessions());
        }
    }

    #[test]
    fn detects_chromium_and_webkit() {
        assert!(is_chromium(&chrome156()));
        assert!(!is_chromium(&safari27()));
    }

    #[test]
    fn only_browser_hellos_qualify_as_templates() {
        assert!(is_browser_like(&chrome156()));
        assert!(is_browser_like(&safari27()));
        // 非浏览器客户端（如 Dart IO）不在套件里放 GREASE
        let plain = ClientHello::new(
            rama::tls::ProtocolVersion::TLSv1_2,
            without_grease(chrome156().cipher_suites())
                .into_iter()
                .map(CipherSuite::from)
                .collect(),
            Vec::new(),
            Vec::new(),
        );
        assert!(!is_browser_like(&plain));
    }

    #[test]
    fn copy_mode_reproduces_reference_cipher_suites() {
        for hello in [chrome156(), safari27()] {
            let egress = build(&hello, Host::from_static("linux.do"), None, None).unwrap();
            assert_eq!(egress.cipher_mode, CipherMode::Copy);
            assert!(!egress.ech_applied);
            assert_eq!(
                without_grease(emitted(egress).cipher_suites()),
                without_grease(hello.cipher_suites())
            );
        }
    }

    /// 注入 ECH 时 Chrome 的外层与参考握手逐字一致（套件与扩展集合、JA4）。
    #[test]
    fn chrome_ech_outer_matches_reference() {
        let reference = chrome156();
        let outer = emitted(
            build(
                &reference,
                Host::from_static("linux.do"),
                Some(&ech_config_list()),
                None,
            )
            .unwrap(),
        );
        assert_eq!(
            without_grease(outer.cipher_suites()),
            without_grease(reference.cipher_suites())
        );
        assert_eq!(extension_ids(&outer), extension_ids(&reference));
        assert_eq!(ja4(&outer), ja4(&reference));
    }

    /// 注入 ECH 时服务端解密出的内层与真 Chrome 156 + ECH 实测一致
    /// （仅 3 个 TLS 1.3 套件，JA4 t13d0314h2_55b375c5d22e_e3c63759931a）。
    #[tokio::test]
    async fn chrome_ech_inner_matches_real_chrome() {
        let (accepted, inner) = ech_inner(&chrome156()).await;
        assert!(accepted, "服务端未接受 ECH");
        assert_eq!(ja4(&inner), "t13d0314h2_55b375c5d22e_e3c63759931a");
    }

    /// Safari 注入 ECH：TLS 1.2 套件保持参考顺序、只少掉 BoringSSL 不支持的老套件；
    /// TLS 1.3 套件集合不变，但顺序由 BoringSSL 固定（Safari 原为 1302,1303,1301），
    /// 这是不改 BoringSSL 时的已知偏差。扩展仅多出 ECH。
    #[test]
    fn safari_ech_outer_keeps_supported_suites() {
        let reference = safari27();
        let outer = emitted(
            build(
                &reference,
                Host::from_static("linux.do"),
                Some(&ech_config_list()),
                None,
            )
            .unwrap(),
        );
        let split = |suites: Vec<u16>| -> (Vec<u16>, Vec<u16>) {
            suites.into_iter().partition(|value| value >> 8 == 0x13)
        };
        let (mut outer13, outer12) = split(without_grease(outer.cipher_suites()));
        let (mut ref13, ref12) = split(without_grease(reference.cipher_suites()));
        let supported12: Vec<u16> = ref12
            .into_iter()
            .filter(|value| SslCipher::from_value(*value).is_some())
            .collect();
        assert_eq!(outer12, supported12);
        outer13.sort_unstable();
        ref13.sort_unstable();
        assert_eq!(outer13, ref13);
        let mut expected = extension_ids(&reference);
        expected.push(u16::from(ExtensionId::ENCRYPTED_CLIENT_HELLO));
        expected.sort_unstable();
        assert_eq!(extension_ids(&outer), expected);
    }

    /// Safari 注入 ECH：内层只有 TLS 1.3 套件，服务端接受 ECH。
    #[tokio::test]
    async fn safari_ech_inner_is_tls13_only() {
        let (accepted, inner) = ech_inner(&safari27()).await;
        assert!(accepted, "服务端未接受 ECH");
        let suites = without_grease(inner.cipher_suites());
        assert!(!suites.is_empty());
        assert!(
            suites.iter().all(|value| value >> 8 == 0x13),
            "内层混入非 TLS 1.3 套件: {suites:x?}"
        );
    }

    /// 标准套件串保持参考握手的 TLS 1.2 顺序（Chrome 恰为 BoringSSL 默认顺序）。
    #[test]
    fn standard_cipher_list_keeps_reference_order() {
        let list = standard_cipher_list(&chrome156()).unwrap();
        assert!(list.starts_with("ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256"));
    }
}
