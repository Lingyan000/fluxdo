//! MITM 用的 CA 证书。
//!
//! 编译期嵌入 `certs/` 下的 CA（由 `cargo run --bin gen_ca` 或 build.rs 生成），
//! 宿主也可在运行时下发 per-device CA。叶子证书由 rama 的 MITM issuer 按上游证书
//! 镜像签发（见 [`crate::mirror`]），这里只负责 CA 本身。

use rama::tls::boring::core::{pkey::PKey, x509::X509};
use rama_crypto::cert::{CertificateSubject, SelfSignedCaConfig, generate_certificate_authority};

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

/// 仅信任当前核心 CA；校验签名链、有效期和目标主机，不按签发者名称放行。
pub fn verify_webview_leaf(ca_pem: &str, der: &[u8], host: &str) -> bool {
    use rama::tls::boring::core::{
        stack::Stack,
        x509::{X509StoreContext, store::X509StoreBuilder, verify::X509VerifyParam},
    };
    let verify = || -> std::result::Result<bool, rama::tls::boring::core::error::ErrorStack> {
        let leaf = X509::from_der(der)?;
        let ca = X509::from_pem(ca_pem.as_bytes())?;
        let mut store = X509StoreBuilder::new()?;
        store.add_cert(ca)?;
        let mut params = X509VerifyParam::new()?;
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
        && verify().unwrap_or(false)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn leaf(ca_pem: &str, key_pem: &str, expired: bool) -> Vec<u8> {
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
        cert.append_extension(&ExtendedKeyUsage::new().server_auth().build().unwrap())
            .unwrap();
        let san = SubjectAlternativeName::new()
            .dns("image.example")
            .ip("127.0.0.1")
            .build(&cert.x509v3_context(Some(&ca), None))
            .unwrap();
        cert.append_extension(&san).unwrap();
        cert.sign(&key, MessageDigest::sha256()).unwrap();
        cert.build().to_der().unwrap()
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
