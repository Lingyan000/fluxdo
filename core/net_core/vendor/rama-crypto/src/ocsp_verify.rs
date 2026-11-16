//! 已通过平台证书链验证之后的 OCSP staple 校验。
//!
//! 不建立新的信任锚点，不访问响应中的网络地址；签名和摘要全部交给 BoringSSL。
//! issuer 必须来自平台构建的可信链，不能取自 OCSP 响应自带的证书。

use rama_boring::{
    hash::{MessageDigest, hash},
    pkey::{Id, PKeyRef, Public},
    rsa::Padding,
    sign::{RsaPssSaltlen, Verifier},
    x509::X509,
};
use x509_parser::{extensions::ParsedExtension, prelude::*};
use yasna::{
    ASN1Error, ASN1ErrorKind, ASN1Result, BERReader as DERReader, Tag, models::ObjectIdentifier,
};

const MAX_RESPONSE_BYTES: usize = 256 * 1024;
const MAX_RESPONSES: usize = 64;
const MAX_CERTIFICATES: usize = 16;
const CLOCK_SKEW: i64 = 300;
// 没有 nextUpdate 也不能无限重放旧的 good 响应。
const MAX_AGE: i64 = 7 * 24 * 60 * 60;

/// 失败原因不包含证书、域名、响应内容或网络地址。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Error {
    Encoding,
    ResponseStatus,
    UnsupportedAlgorithm,
    CriticalExtension,
    NoMatchingCertificate,
    InvalidTime,
    UnauthorizedSigner,
    InvalidSignature,
    Revoked,
    Unknown,
}

impl std::fmt::Display for Error {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "OCSP staple rejected: {self:?}")
    }
}
impl std::error::Error for Error {}

type Result<T> = std::result::Result<T, Error>;

struct Algorithm {
    oid: String,
    parameters: Option<Vec<u8>>,
}

fn read_algorithm(r: DERReader<'_, '_>) -> ASN1Result<Algorithm> {
    r.read_sequence(|r| {
        Ok(Algorithm {
            oid: r.next().read_oid()?.to_string(),
            parameters: r.read_optional(|r| r.read_der())?,
        })
    })
}

fn invalid() -> ASN1Error {
    ASN1Error::new(ASN1ErrorKind::Invalid)
}

// 未识别的非关键扩展可忽略；关键扩展不能忽略。拒绝重复 OID。
fn extensions(r: DERReader<'_, '_>) -> ASN1Result<bool> {
    let mut seen = std::collections::HashSet::new();
    let mut critical = false;
    r.read_sequence_of(|r| {
        r.read_sequence(|r| {
            if !seen.insert(r.next().read_oid()?) {
                return Err(invalid());
            }
            critical |= r.read_optional(|r| r.read_bool())?.unwrap_or(false);
            r.next().read_bytes()?;
            Ok(())
        })
    })?;
    Ok(critical)
}

enum Responder {
    Name(Vec<u8>),
    Key(Vec<u8>),
}

struct Single {
    digest: Algorithm,
    name_hash: Vec<u8>,
    key_hash: Vec<u8>,
    serial: Vec<u8>,
    status: u8,
    this_update: i64,
    next_update: Option<i64>,
    critical: bool,
}

struct Response {
    tbs: Vec<u8>,
    algorithm: Algorithm,
    signature: Vec<u8>,
    certs: Vec<Vec<u8>>,
    responder: Responder,
    produced_at: i64,
    responses: Vec<Single>,
    critical: bool,
}

fn time(r: DERReader<'_, '_>) -> ASN1Result<i64> {
    Ok(r.read_generalized_time()?.datetime().unix_timestamp())
}

fn parse(raw: &[u8]) -> Result<Response> {
    if raw.is_empty() || raw.len() > MAX_RESPONSE_BYTES {
        return Err(Error::Encoding);
    }
    let (status, basic) = yasna::parse_der(raw, |r| {
        r.read_sequence(|r| {
            let status = r.next().read_enum()?;
            let basic = r.read_optional(|r| {
                r.read_tagged(Tag::context(0), |r| {
                    r.read_sequence(|r| {
                        let oid = r.next().read_oid()?;
                        if oid != ObjectIdentifier::from_slice(&[1, 3, 6, 1, 5, 5, 7, 48, 1, 1]) {
                            return Err(invalid());
                        }
                        r.next().read_bytes()
                    })
                })
            })?;
            Ok((status, basic))
        })
    })
    .map_err(|_| Error::Encoding)?;
    if status != 0 {
        return Err(Error::ResponseStatus);
    }
    let basic = basic.ok_or(Error::Encoding)?;
    let (tbs, algorithm, signature, certs) = yasna::parse_der(&basic, |r| {
        r.read_sequence(|r| {
            let tbs = r.next().read_der()?;
            let alg = read_algorithm(r.next())?;
            let (sig, bits) = r.next().read_bitvec_bytes()?;
            if sig.is_empty() || bits != sig.len() * 8 {
                return Err(invalid());
            }
            let certs = r
                .read_optional(|r| {
                    r.read_tagged(Tag::context(0), |r| {
                        let mut certs = Vec::new();
                        r.read_sequence_of(|r| {
                            if certs.len() >= MAX_CERTIFICATES {
                                return Err(invalid());
                            }
                            certs.push(r.read_der()?);
                            Ok(())
                        })?;
                        Ok(certs)
                    })
                })?
                .unwrap_or_default();
            Ok((tbs, alg, sig, certs))
        })
    })
    .map_err(|_| Error::Encoding)?;
    let (responder, produced_at, responses, critical) = yasna::parse_der(&tbs, |r| {
        r.read_sequence(|r| {
            let version = r.read_optional(|r| r.read_tagged(Tag::context(0), |r| r.read_u64()))?;
            if version.unwrap_or(0) != 0 {
                return Err(invalid());
            }
            let responder = r.next();
            let responder = match responder.lookahead_tag()? {
                tag if tag == Tag::context(1) => {
                    Responder::Name(responder.read_tagged(tag, |r| r.read_der())?)
                }
                tag if tag == Tag::context(2) => {
                    Responder::Key(responder.read_tagged(tag, |r| r.read_bytes())?)
                }
                _ => return Err(invalid()),
            };
            let produced_at = time(r.next())?;
            let mut responses = Vec::new();
            r.next().read_sequence_of(|r| {
                if responses.len() >= MAX_RESPONSES {
                    return Err(invalid());
                }
                responses.push(r.read_sequence(|r| {
                    let (digest, name_hash, key_hash, serial) = r.next().read_sequence(|r| {
                        let alg = read_algorithm(r.next())?;
                        let name = r.next().read_bytes()?;
                        let key = r.next().read_bytes()?;
                        let (serial, positive) = r.next().read_bigint_bytes()?;
                        if !positive || serial.is_empty() {
                            return Err(invalid());
                        }
                        Ok((alg, name, key, serial))
                    })?;
                    let status = r.next();
                    let status = match status.lookahead_tag()? {
                        tag if tag == Tag::context(0) => {
                            status.read_tagged_implicit(tag, |r| r.read_null())?;
                            0
                        }
                        tag if tag == Tag::context(1) => {
                            status.read_tagged_implicit(tag, |r| {
                                r.read_sequence(|r| {
                                    time(r.next())?;
                                    r.read_optional(|r| {
                                        r.read_tagged(Tag::context(0), |r| r.read_enum())
                                    })?;
                                    Ok(())
                                })
                            })?;
                            1
                        }
                        tag if tag == Tag::context(2) => {
                            status.read_tagged_implicit(tag, |r| r.read_null())?;
                            2
                        }
                        _ => return Err(invalid()),
                    };
                    let this_update = time(r.next())?;
                    let next_update = r.read_optional(|r| r.read_tagged(Tag::context(0), time))?;
                    let critical = r
                        .read_optional(|r| r.read_tagged(Tag::context(1), extensions))?
                        .unwrap_or(false);
                    Ok(Single {
                        digest,
                        name_hash,
                        key_hash,
                        serial,
                        status,
                        this_update,
                        next_update,
                        critical,
                    })
                })?);
                Ok(())
            })?;
            if responses.is_empty() {
                return Err(invalid());
            }
            let critical = r
                .read_optional(|r| r.read_tagged(Tag::context(1), extensions))?
                .unwrap_or(false);
            Ok((responder, produced_at, responses, critical))
        })
    })
    .map_err(|_| Error::Encoding)?;
    Ok(Response {
        tbs,
        algorithm,
        signature,
        certs,
        responder,
        produced_at,
        responses,
        critical,
    })
}

fn digest(oid: &str) -> Result<MessageDigest> {
    match oid {
        "1.3.14.3.2.26" => Ok(MessageDigest::sha1()),
        "2.16.840.1.101.3.4.2.1" => Ok(MessageDigest::sha256()),
        "2.16.840.1.101.3.4.2.2" => Ok(MessageDigest::sha384()),
        "2.16.840.1.101.3.4.2.3" => Ok(MessageDigest::sha512()),
        _ => Err(Error::UnsupportedAlgorithm),
    }
}

fn null_or_absent(alg: &Algorithm) -> Result<()> {
    if alg.parameters.as_deref().is_none_or(|p| p == [5, 0]) {
        Ok(())
    } else {
        Err(Error::Encoding)
    }
}

fn signature(response: &Response, key: &PKeyRef<Public>) -> Result<()> {
    let alg = &response.algorithm;
    let mut verifier = if alg.oid == "1.2.840.113549.1.1.10" {
        if !matches!(key.id(), Id::RSA | Id::RSAPSS) {
            return Err(Error::UnsupportedAlgorithm);
        }
        let params = alg.parameters.as_deref().ok_or(Error::Encoding)?;
        let (hash_alg, mgf, salt, trailer) = yasna::parse_der(params, |r| {
            r.read_sequence(|r| {
                let hash_alg =
                    r.read_optional(|r| r.read_tagged(Tag::context(0), read_algorithm))?;
                let mgf = r.read_optional(|r| r.read_tagged(Tag::context(1), read_algorithm))?;
                let salt = r
                    .read_optional(|r| r.read_tagged(Tag::context(2), |r| r.read_u64()))?
                    .unwrap_or(20);
                let trailer = r
                    .read_optional(|r| r.read_tagged(Tag::context(3), |r| r.read_u64()))?
                    .unwrap_or(1);
                Ok((hash_alg, mgf, salt, trailer))
            })
        })
        .map_err(|_| Error::Encoding)?;
        let md = if let Some(alg) = hash_alg {
            null_or_absent(&alg)?;
            digest(&alg.oid)?
        } else {
            MessageDigest::sha1()
        };
        let mgf_md = if let Some(mgf) = mgf {
            if mgf.oid != "1.2.840.113549.1.1.8" {
                return Err(Error::UnsupportedAlgorithm);
            }
            let alg = yasna::parse_der(
                mgf.parameters.as_deref().ok_or(Error::Encoding)?,
                read_algorithm,
            )
            .map_err(|_| Error::Encoding)?;
            null_or_absent(&alg)?;
            digest(&alg.oid)?
        } else {
            MessageDigest::sha1()
        };
        if trailer != 1 || salt > i32::MAX as u64 {
            return Err(Error::UnsupportedAlgorithm);
        }
        let mut v = Verifier::new(md, key).map_err(|_| Error::InvalidSignature)?;
        v.set_rsa_padding(Padding::PKCS1_PSS)
            .map_err(|_| Error::InvalidSignature)?;
        v.set_rsa_mgf1_md(mgf_md)
            .map_err(|_| Error::InvalidSignature)?;
        v.set_rsa_pss_saltlen(RsaPssSaltlen::custom(salt as i32))
            .map_err(|_| Error::InvalidSignature)?;
        v
    } else if alg.oid == "1.3.101.112" {
        if key.id() != Id::ED25519 || alg.parameters.is_some() {
            return Err(Error::UnsupportedAlgorithm);
        }
        Verifier::new_without_digest(key).map_err(|_| Error::InvalidSignature)?
    } else {
        let (kind, md) = match alg.oid.as_str() {
            "1.2.840.113549.1.1.5" => (Id::RSA, MessageDigest::sha1()),
            "1.2.840.113549.1.1.11" => (Id::RSA, MessageDigest::sha256()),
            "1.2.840.113549.1.1.12" => (Id::RSA, MessageDigest::sha384()),
            "1.2.840.113549.1.1.13" => (Id::RSA, MessageDigest::sha512()),
            "1.2.840.10045.4.1" => (Id::EC, MessageDigest::sha1()),
            "1.2.840.10045.4.3.2" => (Id::EC, MessageDigest::sha256()),
            "1.2.840.10045.4.3.3" => (Id::EC, MessageDigest::sha384()),
            "1.2.840.10045.4.3.4" => (Id::EC, MessageDigest::sha512()),
            _ => return Err(Error::UnsupportedAlgorithm),
        };
        if key.id() != kind {
            return Err(Error::UnsupportedAlgorithm);
        }
        if kind == Id::RSA {
            null_or_absent(alg)?;
        } else if alg.parameters.is_some() {
            return Err(Error::Encoding);
        }
        Verifier::new(md, key).map_err(|_| Error::InvalidSignature)?
    };
    if verifier
        .verify_oneshot(&response.signature, &response.tbs)
        .unwrap_or(false)
    {
        Ok(())
    } else {
        Err(Error::InvalidSignature)
    }
}

fn certificate(der: &[u8]) -> Result<X509Certificate<'_>> {
    let (rest, cert) = X509Certificate::from_der(der).map_err(|_| Error::Encoding)?;
    if !rest.is_empty() {
        return Err(Error::Encoding);
    }
    Ok(cert)
}

fn responder_matches(response: &Response, cert: &X509Certificate<'_>) -> bool {
    match &response.responder {
        Responder::Name(name) => name == cert.subject().as_raw(),
        Responder::Key(key) => hash(
            MessageDigest::sha1(),
            &cert.public_key().subject_public_key.data,
        )
        .is_ok_and(|h| h.as_ref() == key),
    }
}

fn verify_signer(
    response: &Response,
    issuer_der: &[u8],
    issuer: &X509Certificate<'_>,
    now: i64,
) -> Result<()> {
    let issuer_x509 = X509::from_der(issuer_der).map_err(|_| Error::Encoding)?;
    let issuer_key = issuer_x509.public_key().map_err(|_| Error::Encoding)?;
    if responder_matches(response, issuer) && signature(response, &issuer_key).is_ok() {
        return Ok(());
    }
    for der in &response.certs {
        let Ok(cert) = certificate(der) else {
            continue;
        };
        if !responder_matches(response, &cert) || cert.issuer() != issuer.subject() {
            continue;
        }
        let valid = [now, response.produced_at]
            .into_iter()
            .all(|t| ASN1Time::from_timestamp(t).is_ok_and(|t| cert.validity().is_valid_at(t)));
        let usage = cert
            .extended_key_usage()
            .is_ok_and(|u| u.is_some_and(|u| u.value.ocsp_signing))
            && cert
                .key_usage()
                .is_ok_and(|u| u.is_none_or(|u| u.value.digital_signature()));
        // 受委托响应者必须由当前 issuer 直接签发，并明确获准签署 OCSP。
        let critical = cert.iter_extensions().any(|e| {
            e.critical
                && !matches!(
                    e.parsed_extension(),
                    ParsedExtension::KeyUsage(_)
                        | ParsedExtension::ExtendedKeyUsage(_)
                        | ParsedExtension::BasicConstraints(_)
                        | ParsedExtension::SubjectKeyIdentifier(_)
                        | ParsedExtension::AuthorityKeyIdentifier(_)
                )
        });
        if !valid || !usage || critical {
            continue;
        }
        let Ok(native) = X509::from_der(der) else {
            continue;
        };
        if !native.verify(&issuer_key).unwrap_or(false) {
            continue;
        }
        let Ok(key) = native.public_key() else {
            continue;
        };
        if signature(response, &key).is_ok() {
            return Ok(());
        }
    }
    Err(Error::UnauthorizedSigner)
}

/// 验证已通过平台信任校验的叶子与其直接签发者对应的 staple。
/// 只有匹配、有效签名、时间有效且状态 good 的响应才成功。
pub fn verify_staple(
    raw: &[u8],
    leaf_der: &[u8],
    issuer_der: &[u8],
    now_epoch_seconds: i64,
) -> Result<()> {
    let response = parse(raw)?;
    let leaf = certificate(leaf_der)?;
    let issuer = certificate(issuer_der)?;
    let now = now_epoch_seconds;
    if now < 0
        || response.produced_at > now.saturating_add(CLOCK_SKEW)
        || !ASN1Time::from_timestamp(response.produced_at)
            .is_ok_and(|t| leaf.validity().is_valid_at(t))
    {
        return Err(Error::InvalidTime);
    }
    if response.critical || response.responses.iter().any(|s| s.critical) {
        return Err(Error::CriticalExtension);
    }
    verify_signer(&response, issuer_der, &issuer, now)?;
    let mut matched = false;
    let mut good = false;
    let mut unknown = false;
    for entry in &response.responses {
        null_or_absent(&entry.digest)?;
        let md = digest(&entry.digest.oid)?;
        let name_hash = hash(md, issuer.subject().as_raw()).map_err(|_| Error::Encoding)?;
        let key_hash =
            hash(md, &issuer.public_key().subject_public_key.data).map_err(|_| Error::Encoding)?;
        let unsigned = |bytes: &[u8]| {
            bytes
                .iter()
                .position(|b| *b != 0)
                .unwrap_or(bytes.len().saturating_sub(1))
        };
        if entry.name_hash != name_hash.as_ref()
            || entry.key_hash != key_hash.as_ref()
            || entry.serial[unsigned(&entry.serial)..]
                != leaf.raw_serial()[unsigned(leaf.raw_serial())..]
        {
            continue;
        }
        matched = true;
        if entry.this_update > now.saturating_add(CLOCK_SKEW)
            || (entry.next_update.is_none()
                && entry.this_update < now.saturating_sub(MAX_AGE + CLOCK_SKEW))
            || entry.this_update > response.produced_at.saturating_add(CLOCK_SKEW)
            || entry
                .next_update
                .is_some_and(|n| n < entry.this_update || n < now.saturating_sub(CLOCK_SKEW))
        {
            continue;
        }
        match entry.status {
            1 => return Err(Error::Revoked),
            2 => unknown = true,
            _ => good = true,
        }
    }
    if unknown {
        Err(Error::Unknown)
    } else if good {
        Ok(())
    } else if matched {
        Err(Error::InvalidTime)
    } else {
        Err(Error::NoMatchingCertificate)
    }
}
