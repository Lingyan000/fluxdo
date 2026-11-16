//! MITM 用的 CA 证书。
//!
//! 编译期嵌入 `certs/` 下的 CA（由 `cargo run --bin gen_ca` 或 build.rs 生成），
//! 宿主也可在运行时下发 per-device CA。叶子证书由 rama 的 MITM issuer 按上游证书
//! 镜像签发（见 [`crate::mirror`]），这里只负责 CA 本身。

use rama::tls::boring::core::{pkey::{PKey, Private}, x509::X509};
use rama_crypto::cert::{CertificateSubject, SelfSignedCaConfig, generate_certificate_authority};
use rama_crypto::dep::x509_parser::{certificate::X509Certificate, prelude::FromDer as _};

use crate::error::{NetError, Result};

/// 编译期嵌入的 CA 证书（WebView 需信任它才能做 MITM）
const CA_CERT_PEM: &str = include_str!("../certs/ca.crt");
/// 编译期嵌入的 CA 私钥
const CA_KEY_PEM: &str = include_str!("../certs/ca.key");

/// 编译期嵌入的 CA 证书 PEM
pub fn embedded_ca_pem() -> &'static str {
    CA_CERT_PEM
}

/// 编译期嵌入的 CA 私钥 PEM
pub fn embedded_ca_key_pem() -> &'static str {
    CA_KEY_PEM
}

/// 生成一份新的自签 CA，返回 (证书 PEM, 私钥 PEM)。
///
/// 用于 `gen_ca` 构建步骤与 per-device CA。主体名沿用历史取值：iOS/macOS 的
/// per-device 描述文件和设置页的安装指引都按这个名字告诉用户去哪里找，改名即对不上。
/// 密钥默认 ECDSA P-256，与旧实现一致。
pub fn generate_ca_pem() -> Result<(String, String)> {
    let config = SelfSignedCaConfig {
        subject: CertificateSubject {
            organisation_name: Some("DOH Proxy".to_owned()),
            common_name: Some("DOH Proxy CA".to_owned()),
        },
        ..Default::default()
    };
    let ca = generate_certificate_authority(config)
        .map_err(|e| NetError::Certificate(format!("Generate CA: {e}")))?;

    let (chain, key) = ca.into_parts();
    let cert_der = chain
        .first()
        .ok_or_else(|| NetError::Certificate("Generated CA has no certificate".to_owned()))?;
    let cert_pem = X509::from_der(cert_der.as_ref())
        .and_then(|cert| cert.to_pem())
        .map_err(|e| NetError::Certificate(format!("Encode CA certificate: {e}")))?;
    let key_pem = PKey::private_key_from_der(key.secret_der())
        .and_then(|key| key.private_key_to_pem_pkcs8())
        .map_err(|e| NetError::Certificate(format!("Encode CA key: {e}")))?;

    let to_string = |bytes: Vec<u8>, what: &str| {
        String::from_utf8(bytes)
            .map_err(|e| NetError::Certificate(format!("Encode {what} as PEM text: {e}")))
    };
    Ok((
        to_string(cert_pem, "CA certificate")?,
        to_string(key_pem, "CA key")?,
    ))
}

/// 在监听前验证签发材料，避免启动成功后才发现密钥不匹配或 CA 不可用。
pub(crate) fn parse_mitm_ca(cert_pem: &str, key_pem: &str) -> Result<(X509, PKey<Private>)> {
    let cert = X509::from_pem(cert_pem.as_bytes())
        .map_err(|e| NetError::Certificate(format!("Invalid CA certificate: {e}")))?;
    let key = PKey::private_key_from_pem(key_pem.as_bytes())
        .map_err(|e| NetError::Certificate(format!("Invalid CA key: {e}")))?;
    let public_key = cert.public_key()
        .map_err(|e| NetError::Certificate(format!("Invalid CA public key: {e}")))?;
    if !key.public_eq(&public_key) {
        return Err(NetError::Certificate("CA certificate and private key do not match".into()));
    }
    let der = cert.to_der().map_err(|e| NetError::Certificate(format!("Invalid CA encoding: {e}")))?;
    let (_, parsed) = X509Certificate::from_der(&der)
        .map_err(|_| NetError::Certificate("Invalid CA encoding".into()))?;
    let is_ca = parsed.basic_constraints().is_ok_and(|v| v.is_some_and(|v| v.value.ca));
    let can_sign = parsed.key_usage().is_ok_and(|v| v.is_none_or(|v| v.value.key_cert_sign()));
    if !is_ca || !can_sign || !permits_server_auth(&parsed) || !parsed.validity().is_valid() {
        return Err(NetError::Certificate("CA constraints, signing usage or validity rejected".into()));
    }
    Ok((cert, key))
}

// 与 TLS 服务器用途一致：未限制 EKU 可以使用；显式限制时必须包含 serverAuth。
fn permits_server_auth(cert: &X509Certificate<'_>) -> bool {
    cert.extended_key_usage().is_ok_and(|usage| usage.is_none_or(|usage| usage.value.server_auth))
}

/// 仅信任当前核心 CA；校验签名链、用途、有效期和 SAN 主机，不按 CN 放行。
pub fn verify_webview_leaf(ca_pem: &str, der: &[u8], host: &str) -> bool {
    use rama::tls::boring::core::{
        stack::Stack,
        x509::{X509StoreContext, store::X509StoreBuilder, verify::{X509CheckFlags, X509VerifyParam}},
    };
    let verify = || -> std::result::Result<bool, rama::tls::boring::core::error::ErrorStack> {
        let leaf = X509::from_der(der)?;
        let ca = X509::from_pem(ca_pem.as_bytes())?;
        let ca_der = ca.to_der()?;
        if !X509Certificate::from_der(&ca_der).is_ok_and(|(_, cert)| permits_server_auth(&cert)) {
            return Ok(false);
        }
        let mut store = X509StoreBuilder::new()?;
        store.add_cert(ca)?;
        let mut params = X509VerifyParam::new()?;
        params.set_hostflags(X509CheckFlags::NEVER_CHECK_SUBJECT | X509CheckFlags::NO_PARTIAL_WILDCARDS);
        if let Ok(ip) = host.parse::<std::net::IpAddr>() {
            params.set_ip(ip)?;
        } else {
            params.set_host(host)?;
        }
        params.set_depth(1);
        store.set_param(&params)?;
        let chain = Stack::new()?;
        X509StoreContext::new()?.init(&store.build(), &leaf, &chain, |ctx| ctx.verify_cert())
    };
    !host.is_empty()
        && host.len() <= 253
        && !der.is_empty()
        && der.len() <= 65536
        && X509Certificate::from_der(der).is_ok_and(|(rest, cert)| {
            rest.is_empty()
                && permits_server_auth(&cert)
                && cert.key_usage().is_ok_and(|usage| usage.is_none_or(|usage| {
                    usage.value.digital_signature() || usage.value.key_encipherment() || usage.value.key_agreement()
                }))
        })
        && verify().unwrap_or(false)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn leaf_with_policy(ca_pem: &str, key_pem: &str, expired: bool, server_auth: bool, dns: Option<&str>) -> Vec<u8> {
        use rama::tls::boring::core::{
            asn1::Asn1Time,
            bn::BigNum,
            hash::MessageDigest,
            x509::{
                X509NameBuilder,
                extension::{BasicConstraints, ExtendedKeyUsage, KeyUsage, SubjectAlternativeName},
            },
        };
        let ca = X509::from_pem(ca_pem.as_bytes()).unwrap();
        let key = PKey::private_key_from_pem(key_pem.as_bytes()).unwrap();
        let mut cert = X509::builder().unwrap();
        cert.set_version(2).unwrap();
        cert.set_serial_number(&BigNum::from_u32(1).unwrap().to_asn1_integer().unwrap())
            .unwrap();
        let mut name = X509NameBuilder::new().unwrap();
        name.append_entry_by_text("CN", "image.example").unwrap();
        cert.set_subject_name(&name.build()).unwrap();
        cert.set_issuer_name(ca.subject_name()).unwrap();
        // 测试只需有效签名；叶子使用此公钥，不对外提供服务器。
        cert.set_pubkey(&key).unwrap();
        cert.set_not_before(&Asn1Time::from_unix(1).unwrap())
            .unwrap();
        let end = if expired {
            Asn1Time::from_unix(2).unwrap()
        } else {
            Asn1Time::days_from_now(1).unwrap()
        };
        cert.set_not_after(&end).unwrap();
        cert.append_extension(&BasicConstraints::new().critical().build().unwrap())
            .unwrap();
        cert.append_extension(&KeyUsage::new().digital_signature().build().unwrap())
            .unwrap();
        let mut usage = ExtendedKeyUsage::new();
        if server_auth { usage.server_auth(); } else { usage.client_auth(); }
        cert.append_extension(&usage.build().unwrap()).unwrap();
        if let Some(dns) = dns {
            let san = SubjectAlternativeName::new().dns(dns).ip("127.0.0.1")
                .build(&cert.x509v3_context(Some(&ca), None)).unwrap();
            cert.append_extension(&san).unwrap();
        }
        cert.sign(&key, MessageDigest::sha256()).unwrap();
        cert.build().to_der().unwrap()
    }

    fn leaf(ca_pem: &str, key_pem: &str, expired: bool) -> Vec<u8> {
        leaf_with_policy(ca_pem, key_pem, expired, true, Some("image.example"))
    }

    #[test]
    fn webview_trust_rejects_client_only_certificates_and_legacy_name_matching() {
        let (ca, key) = generate_ca_pem().unwrap();
        for (server_auth, san) in [(false, Some("image.example")), (true, None), (true, Some("im*.example"))] {
            let der = leaf_with_policy(&ca, &key, false, server_auth, san);
            assert!(!verify_webview_leaf(&ca, &der, "image.example"), "server_auth={server_auth}, SAN={san:?}");
        }
    }

    #[test]
    fn mirror_rejects_mismatched_ca_and_key_before_serving() {
        let (ca, _) = generate_ca_pem().unwrap();
        let (_, wrong_key) = generate_ca_pem().unwrap();
        assert!(crate::mirror::MirrorRelay::new(&ca, &wrong_key,
            std::sync::Arc::new(crate::mirror::FingerprintTemplates::default())).is_err());
    }

    #[test]
    fn mitm_issuer_requires_ca_constraints() {
        let (ca, key) = generate_ca_pem().unwrap();
        assert!(parse_mitm_ca(&ca, &key).is_ok());
        let leaf_pem = String::from_utf8(X509::from_der(&leaf(&ca, &key, false)).unwrap().to_pem().unwrap()).unwrap();
        assert!(parse_mitm_ca(&leaf_pem, &key).is_err());
    }

    #[tokio::test]
    async fn incomplete_custom_ca_never_falls_back_to_embedded_issuer() {
        let (ca, key) = generate_ca_pem().unwrap();
        for (cert, key) in [(Some(ca), None), (None, Some(key))] {
            let result = crate::core::Core::start(crate::NetConfig {
                webview_mitm: true, ca_cert_pem: cert, ca_key_pem: key,
                ..Default::default()
            }).await;
            if let Ok(core) = &result { core.stop_listener().await; }
            assert!(matches!(result, Err(NetError::Certificate(_))));
        }
    }

    #[test]
    fn webview_trust_requires_current_ca_host_time_and_der() {
        let (ca, key) = generate_ca_pem().unwrap();
        let der = leaf(&ca, &key, false);
        assert!(verify_webview_leaf(&ca, &der, "image.example"));
        assert!(verify_webview_leaf(&ca, &der, "127.0.0.1"));
        assert!(!verify_webview_leaf(&ca, &der, "wrong.example"));
        assert!(!verify_webview_leaf(&ca, &der, "127.0.0.2"));
        assert!(!verify_webview_leaf(
            &ca,
            &leaf(&ca, &key, true),
            "image.example"
        ));
        // 两份 CA 的 CN 完全相同，只有签名密钥不同。
        let (other_ca, _) = generate_ca_pem().unwrap();
        assert!(!verify_webview_leaf(&other_ca, &der, "image.example"));
        assert!(!verify_webview_leaf(&ca, &[], "image.example"));
        assert!(!verify_webview_leaf(
            &ca,
            b"not a certificate",
            "image.example"
        ));
        assert!(!verify_webview_leaf(&ca, &der, ""));
    }

    #[test]
    fn generated_ca_is_usable_as_mitm_issuer() {
        let (cert_pem, key_pem) = generate_ca_pem().unwrap();
        assert!(cert_pem.starts_with("-----BEGIN CERTIFICATE-----"));
        assert!(key_pem.contains("PRIVATE KEY-----"));
        // 与 MirrorRelay::new 同一条解析路径
        let cert = X509::from_pem(cert_pem.as_bytes()).unwrap();
        let key = PKey::private_key_from_pem(key_pem.as_bytes()).unwrap();
        assert!(key.public_eq(&cert.public_key().unwrap()));
    }
}
