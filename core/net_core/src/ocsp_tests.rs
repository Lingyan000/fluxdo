//! OpenSSL 生成并独立验证的 OCSP 响应，经生产 BoringSSL 验签路径执行。

use rama_crypto::ocsp::verify::{Error, verify_staple};
use std::{collections::BTreeMap, sync::OnceLock};

pub(crate) struct Fixtures {
    pub leaf: Vec<u8>,
    pub issuer: Vec<u8>,
    pub responses: BTreeMap<String, Vec<u8>>,
    pub certificates: BTreeMap<String, Vec<u8>>,
    pub crls: BTreeMap<String, Vec<u8>>,
    pub now: i64,
}

pub(crate) fn fixtures() -> &'static Fixtures {
    static DATA: OnceLock<Fixtures> = OnceLock::new();
    DATA.get_or_init(|| {
        struct Directory(std::path::PathBuf);
        impl Drop for Directory {
            fn drop(&mut self) {
                let _ = std::fs::remove_dir_all(&self.0);
            }
        }
        let dir =
            Directory(std::env::temp_dir().join(format!("fluxdo-ocsp-{}", std::process::id())));
        std::fs::create_dir_all(&dir.0).unwrap();
        let script = dir.0.join("generate.py");
        std::fs::write(&script, include_str!("../tests/fixtures/ocsp_generate.py")).unwrap();
        let output = std::process::Command::new("python3")
            .arg(script)
            .arg(&dir.0)
            .output()
            .unwrap();
        assert!(
            output.status.success(),
            "OCSP 对照生成失败: {}",
            String::from_utf8_lossy(&output.stderr)
        );
        let responses = std::fs::read_dir(&dir.0)
            .unwrap()
            .map(|p| p.unwrap().path())
            .filter(|p| p.extension().is_some_and(|s| s == "ocsp"))
            .map(|p| {
                (
                    p.file_stem().unwrap().to_str().unwrap().to_owned(),
                    std::fs::read(p).unwrap(),
                )
            })
            .collect();
        Fixtures {
            leaf: std::fs::read(dir.0.join("leaf.der")).unwrap(),
            issuer: std::fs::read(dir.0.join("issuer.der")).unwrap(),
            now: serde_json::from_slice(&std::fs::read(dir.0.join("now.json")).unwrap()).unwrap(),
            responses,
            certificates: ["leaf", "aia_issuer", "aia_ocsp", "crl_only", "aia_both", "aia_invalid"]
                .into_iter().map(|name| (name.to_owned(), std::fs::read(dir.0.join(format!("{name}.der"))).unwrap())).collect(),
            crls: ["valid", "revoked"].into_iter()
                .map(|name| (name.to_owned(), std::fs::read(dir.0.join(format!("{name}.crl"))).unwrap())).collect(),
        }
    })
}

#[test]
fn ocsp_responder_detection_distinguishes_ca_issuers_and_crls() {
    use rama_crypto::ocsp::certificate_has_ocsp_responder;
    let f = fixtures();
    for (name, expected) in [
        ("leaf", false),
        ("aia_issuer", false),
        ("crl_only", false),
        ("aia_ocsp", true),
        ("aia_both", true),
    ] {
        assert_eq!(
            certificate_has_ocsp_responder(&f.certificates[name]).unwrap(),
            expected,
            "{name}"
        );
    }
    assert!(certificate_has_ocsp_responder(&f.certificates["aia_invalid"]).is_err());
    assert!(certificate_has_ocsp_responder(&f.leaf[..f.leaf.len() - 1]).is_err());
    let mut trailing = f.leaf.clone();
    trailing.push(0);
    assert!(certificate_has_ocsp_responder(&trailing).is_err());
}

pub(crate) fn expected(name: &str) -> Result<(), Error> {
    match name {
        "good"
        | "by_key"
        | "sha256_id"
        | "delegated"
        | "rsa"
        | "rsa_pss"
        | "noncritical_extension"
        | "missing_next_update" => Ok(()),
        "revoked" => Err(Error::Revoked),
        "unknown" | "conflicting_status" => Err(Error::Unknown),
        "wrong_serial" | "wrong_name_hash" | "wrong_key_hash" => Err(Error::NoMatchingCertificate),
        "critical_extension" | "critical_single" => Err(Error::CriticalExtension),
        "trailing_data" | "truncated" => Err(Error::Encoding),
        "response_error" => Err(Error::ResponseStatus),
        "bad_signature" | "missing_delegate" | "unauthorized" | "expired_signer"
        | "foreign_signer" | "bad_usage" | "wrong_responder" | "pss_wrong_salt"
        | "pss_wrong_trailer" | "pss_wrong_mgf" => Err(Error::UnauthorizedSigner),
        _ => panic!("未声明对照结果: {name}"),
    }
}

#[test]
fn openssl_ocsp_positive_and_negative_vectors() {
    let f = fixtures();
    assert!(f.responses.len() >= 25);
    for (name, response) in &f.responses {
        assert_eq!(
            verify_staple(response, &f.leaf, &f.issuer, f.now),
            expected(name),
            "{name}"
        );
    }
}

#[test]
fn ocsp_rejects_expired_future_and_replayed_responses() {
    let f = fixtures();
    assert_eq!(
        verify_staple(&f.responses["good"], &f.leaf, &f.issuer, f.now + 2 * 86400),
        Err(Error::InvalidTime)
    );
    assert_eq!(
        verify_staple(&f.responses["good"], &f.leaf, &f.issuer, f.now - 86400),
        Err(Error::InvalidTime)
    );
    assert_eq!(
        verify_staple(
            &f.responses["missing_next_update"],
            &f.leaf,
            &f.issuer,
            f.now + 8 * 86400
        ),
        Err(Error::InvalidTime)
    );
}

#[test]
fn malformed_or_oversized_ocsp_never_panics_or_passes() {
    let f = fixtures();
    let good = &f.responses["good"];
    for end in 0..good.len() {
        assert!(verify_staple(&good[..end], &f.leaf, &f.issuer, f.now).is_err());
    }
    assert_eq!(
        verify_staple(&vec![0; 256 * 1024 + 1], &f.leaf, &f.issuer, f.now),
        Err(Error::Encoding)
    );
    // 非关键字段改变后仍可能合法；签名错误另有负对照，这里只验证逐字节损坏不会 panic。
    for index in 0..good.len() {
        let mut damaged = good.clone();
        damaged[index] ^= 0xff;
        let _ = verify_staple(&damaged, &f.leaf, &f.issuer, f.now);
    }
}
