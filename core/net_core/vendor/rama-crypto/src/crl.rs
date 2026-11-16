//! Generic X.509 v2 CRL builder (TLS-backend agnostic).
//!
//! DER-encodes a `CertificateList` (RFC 5280 §5.1) signed by its issuer.
//! Hashing and signing are supplied by the caller, so this module pulls in no
//! crypto backend — pure `yasna` assembly, mirroring [`crate::ocsp`].
//!
//! Primary use: a MITM proxy hosting a CA-signed CRL whose distribution point
//! it stamps onto re-signed leaves, so revocation-strict clients (notably
//! libcurl + schannel, which resolves revocation from the cert's own CDP and
//! ignores stapled OCSP) accept the leaf.

use std::time::SystemTime;

use rama_core::error::{BoxError, BoxErrorExt as _, ErrorContext};
use yasna::{
    Tag,
    models::{GeneralizedTime, ObjectIdentifier, UTCTime},
};

fn oid_ecdsa_sha256() -> ObjectIdentifier {
    ObjectIdentifier::from_slice(&[1, 2, 840, 10045, 4, 3, 2])
}
fn oid_rsa_sha256() -> ObjectIdentifier {
    ObjectIdentifier::from_slice(&[1, 2, 840, 113549, 1, 1, 11])
}
fn oid_authority_key_id() -> ObjectIdentifier {
    ObjectIdentifier::from_slice(&[2, 5, 29, 35])
}
fn oid_crl_number() -> ObjectIdentifier {
    ObjectIdentifier::from_slice(&[2, 5, 29, 20])
}

/// Signature algorithm the caller used to sign the `tbsCertList`. It is encoded
/// both inside the signed `tbsCertList` and in the outer `signatureAlgorithm`,
/// so the caller commits to it before signing.
#[derive(Debug, Clone, Copy)]
pub enum CrlSignatureAlgorithm {
    /// `ecdsa-with-SHA256` (1.2.840.10045.4.3.2) — parameters absent.
    EcdsaSha256,
    /// `sha256WithRSAEncryption` (1.2.840.113549.1.1.11) — NULL parameters.
    RsaSha256,
}

/// A single revoked certificate entry.
#[derive(Debug, Clone, Copy)]
pub struct RevokedEntry<'a> {
    /// Revoked serial as a big-endian unsigned magnitude.
    pub serial: &'a [u8],
    /// When the certificate was revoked.
    pub revocation_date: SystemTime,
}

/// Inputs for [`build_crl`]. All identity fields are caller-supplied so this
/// crate needs no hash/key backend.
pub struct CrlParams<'a> {
    /// DER of the issuer's subject `Name` (the full `SEQUENCE` TLV).
    pub issuer_name_der: &'a [u8],
    /// CA `keyIdentifier` bytes, emitted as the CRL `authorityKeyIdentifier`.
    pub authority_key_id: &'a [u8],
    /// `thisUpdate`.
    pub this_update: SystemTime,
    /// `nextUpdate` — governs how long a client caches the CRL.
    pub next_update: SystemTime,
    /// Monotonic `cRLNumber`.
    pub crl_number: u64,
    /// Revoked entries; empty omits the `revokedCertificates` field entirely.
    pub revoked: &'a [RevokedEntry<'a>],
}

/// Build a DER-encoded v2 `CertificateList`.
///
/// `sign_tbs` signs the `tbsCertList` DER with the issuer key. The public
/// surface takes only `std` time types; `time::OffsetDateTime` is an internal
/// detail of the `Time` encoding.
pub fn build_crl(
    params: &CrlParams<'_>,
    alg: CrlSignatureAlgorithm,
    sign_tbs: impl FnOnce(&[u8]) -> Result<Vec<u8>, BoxError>,
) -> Result<Vec<u8>, BoxError> {
    // Times are fallible to encode, so resolve them before the infallible
    // `yasna` writer closures.
    let this_update = x509_time(params.this_update)?;
    let next_update = x509_time(params.next_update)?;
    let revoked = params
        .revoked
        .iter()
        .map(|e| Ok::<_, BoxError>((e.serial, x509_time(e.revocation_date)?)))
        .collect::<Result<Vec<_>, _>>()?;

    // extnValue payloads (the OCTET STRING contents) for the v2 CRL extensions.
    let aki_value = yasna::construct_der(|w| {
        w.write_sequence(|w| {
            w.next()
                .write_tagged_implicit(Tag::context(0), |w| w.write_bytes(params.authority_key_id));
        });
    });
    let crl_number_value = yasna::construct_der(|w| w.write_u64(params.crl_number));

    let tbs_der = yasna::construct_der(|w| {
        w.write_sequence(|w| {
            // version v2 (present because crlExtensions are present)
            w.next().write_i64(1);
            // signature AlgorithmIdentifier (must match the outer one)
            write_alg(w.next(), alg);
            // issuer Name (raw DER)
            w.next().write_der(params.issuer_name_der);
            write_time(w.next(), &this_update);
            write_time(w.next(), &next_update);
            // revokedCertificates ::= SEQUENCE OF SEQUENCE { serial, date }
            if !revoked.is_empty() {
                w.next().write_sequence_of(|w| {
                    for (serial, date) in &revoked {
                        w.next().write_sequence(|w| {
                            w.next().write_bigint_bytes(serial, true);
                            write_time(w.next(), date);
                        });
                    }
                });
            }
            // crlExtensions [0] EXPLICIT Extensions
            w.next().write_tagged(Tag::context(0), |w| {
                w.write_sequence(|w| {
                    w.next().write_sequence(|w| {
                        w.next().write_oid(&oid_authority_key_id());
                        w.next().write_bytes(&aki_value);
                    });
                    w.next().write_sequence(|w| {
                        w.next().write_oid(&oid_crl_number());
                        w.next().write_bytes(&crl_number_value);
                    });
                });
            });
        });
    });

    let signature = sign_tbs(&tbs_der)?;

    Ok(yasna::construct_der(|w| {
        w.write_sequence(|w| {
            w.next().write_der(&tbs_der);
            write_alg(w.next(), alg);
            w.next().write_bitvec_bytes(&signature, signature.len() * 8);
        });
    }))
}

/// DER of a `CRLDistributionPoints` extension value with a single
/// `fullName` URI distribution point, for embedding as the `2.5.29.31`
/// extension on a re-signed leaf.
#[must_use]
pub fn crl_distribution_point_der(uri: &str) -> Vec<u8> {
    yasna::construct_der(|w| {
        w.write_sequence(|w| {
            w.next().write_sequence(|w| {
                // distributionPoint [0] EXPLICIT DistributionPointName
                w.next().write_tagged(Tag::context(0), |w| {
                    // fullName [0] IMPLICIT GeneralNames
                    w.write_tagged_implicit(Tag::context(0), |w| {
                        w.write_sequence(|w| {
                            // uniformResourceIdentifier [6] IA5String
                            w.next().write_tagged_implicit(Tag::context(6), |w| {
                                w.write_bytes(uri.as_bytes());
                            });
                        });
                    });
                });
            });
        });
    })
}

fn write_alg(w: yasna::DERWriter<'_>, alg: CrlSignatureAlgorithm) {
    w.write_sequence(|w| match alg {
        CrlSignatureAlgorithm::EcdsaSha256 => {
            w.next().write_oid(&oid_ecdsa_sha256());
        }
        CrlSignatureAlgorithm::RsaSha256 => {
            w.next().write_oid(&oid_rsa_sha256());
            w.next().write_null();
        }
    });
}

/// RFC 5280 `Time`: UTCTime through 2049, GeneralizedTime from 2050.
enum X509Time {
    Utc(UTCTime),
    General(GeneralizedTime),
}

fn x509_time(t: SystemTime) -> Result<X509Time, BoxError> {
    let odt = crate::asn1::datetime(t).context("crl")?;
    let time = if odt.year() < 2050 {
        UTCTime::from_datetime_opt(odt).map(X509Time::Utc)
    } else {
        GeneralizedTime::from_datetime_opt(odt).map(X509Time::General)
    };
    time.ok_or_else(|| BoxError::from_static_str("crl: timestamp past ASN.1 year 9999"))
}

fn write_time(w: yasna::DERWriter<'_>, t: &X509Time) {
    match t {
        X509Time::Utc(u) => w.write_utctime(u),
        X509Time::General(g) => w.write_generalized_time(g),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::time::Duration;

    /// ~2027-01-15, comfortably in the UTCTime range.
    const T0: u64 = 1_800_000_000;

    fn params<'a>(issuer: &'a [u8], revoked: &'a [RevokedEntry<'a>]) -> CrlParams<'a> {
        CrlParams {
            issuer_name_der: issuer,
            authority_key_id: &[0xAB; 20],
            this_update: SystemTime::UNIX_EPOCH + Duration::from_secs(T0),
            next_update: SystemTime::UNIX_EPOCH + Duration::from_secs(T0 + 7 * 86_400),
            crl_number: 1,
            revoked,
        }
    }

    /// A `good`/empty CRL is a well-formed `CertificateList` whose embedded
    /// `tbsCertList` round-trips byte-for-byte with what the caller signed.
    #[test]
    fn builds_wellformed_empty_crl() {
        let issuer = yasna::construct_der(|w| w.write_sequence(|_| {}));
        let mut signed_tbs: Vec<u8> = Vec::new();
        let der = build_crl(
            &params(&issuer, &[]),
            CrlSignatureAlgorithm::EcdsaSha256,
            |tbs| {
                signed_tbs = tbs.to_vec();
                Ok(vec![0xDE, 0xAD, 0xBE, 0xEF])
            },
        )
        .expect("build crl");

        assert!(
            !signed_tbs.is_empty(),
            "tbsCertList was handed to the signer"
        );

        yasna::parse_der(&der, |r| {
            r.read_sequence(|r| {
                let tbs = r.next().read_der()?;
                assert_eq!(tbs, signed_tbs, "embedded tbs == signed tbs");
                r.next().read_sequence(|r| {
                    let oid = r.next().read_oid()?;
                    assert_eq!(oid, oid_ecdsa_sha256());
                    Ok(())
                })?;
                let (sig, bits) = r.next().read_bitvec_bytes()?;
                assert_eq!(sig, vec![0xDE, 0xAD, 0xBE, 0xEF]);
                assert_eq!(bits, 32);
                Ok(())
            })
        })
        .expect("parse CertificateList");
    }

    /// A revoked entry lands in `revokedCertificates` with its serial intact.
    #[test]
    fn revoked_serial_present() {
        let issuer = yasna::construct_der(|w| w.write_sequence(|_| {}));
        let revoked = [RevokedEntry {
            serial: &[0x12, 0x34, 0x56],
            revocation_date: SystemTime::UNIX_EPOCH + Duration::from_secs(T0),
        }];
        let der = build_crl(
            &params(&issuer, &revoked),
            CrlSignatureAlgorithm::RsaSha256,
            |_| Ok(vec![0x00]),
        )
        .expect("build crl");

        let serials = yasna::parse_der(&der, |r| {
            r.read_sequence(|r| {
                let serials = r.next().read_sequence(|r| {
                    let _version = r.next().read_i64()?;
                    let _alg = r.next().read_der()?;
                    let _issuer = r.next().read_der()?;
                    let _this = r.next().read_der()?;
                    let _next = r.next().read_der()?;
                    let mut serials: Vec<Vec<u8>> = Vec::new();
                    r.next().read_sequence_of(|r| {
                        r.read_sequence(|r| {
                            let (serial, _pos) = r.next().read_bigint_bytes()?;
                            let _date = r.next().read_der()?;
                            serials.push(serial);
                            Ok(())
                        })
                    })?;
                    let _exts = r.next().read_der()?;
                    Ok(serials)
                })?;
                // signatureAlgorithm + signature complete the CertificateList.
                let _alg = r.next().read_der()?;
                let _sig = r.next().read_bitvec_bytes()?;
                Ok(serials)
            })
        })
        .expect("parse tbsCertList");

        assert_eq!(serials, vec![vec![0x12, 0x34, 0x56]]);
    }

    /// `thisUpdate` and `nextUpdate` TLVs of a CRL without revoked entries.
    fn update_times(der: &[u8]) -> (Vec<u8>, Vec<u8>) {
        yasna::parse_der(der, |r| {
            r.read_sequence(|r| {
                let times = r.next().read_sequence(|r| {
                    let _version = r.next().read_i64()?;
                    let _alg = r.next().read_der()?;
                    let _issuer = r.next().read_der()?;
                    let this = r.next().read_der()?;
                    let next = r.next().read_der()?;
                    let _exts = r.next().read_der()?;
                    Ok((this, next))
                })?;
                let _alg = r.next().read_der()?;
                let _sig = r.next().read_bitvec_bytes()?;
                Ok(times)
            })
        })
        .expect("parse CertificateList")
    }

    fn time_tlv(tag: u8, value: &[u8]) -> Vec<u8> {
        [&[tag, value.len() as u8][..], value].concat()
    }

    #[test]
    fn time_switches_to_generalized_time_in_2050() {
        let issuer = yasna::construct_der(|w| w.write_sequence(|_| {}));
        let mut params = params(&issuer, &[]);
        params.this_update = SystemTime::UNIX_EPOCH + Duration::from_secs(2_524_607_999);
        params.next_update = params.this_update + Duration::from_secs(1);
        let der = build_crl(&params, CrlSignatureAlgorithm::EcdsaSha256, |_| {
            Ok(vec![0x00])
        })
        .expect("build crl");

        let (this, next) = update_times(&der);
        assert_eq!(this, time_tlv(0x17, b"491231235959Z"));
        assert_eq!(next, time_tlv(0x18, b"20500101000000Z"));
    }

    #[test]
    fn times_past_year_9999_error_before_signing() {
        let issuer = yasna::construct_der(|w| w.write_sequence(|_| {}));
        let mut params = params(&issuer, &[]);
        params.next_update = SystemTime::UNIX_EPOCH + Duration::from_secs(253_402_300_799);
        let der = build_crl(&params, CrlSignatureAlgorithm::EcdsaSha256, |_| {
            Ok(vec![0x00])
        })
        .expect("build crl");
        assert_eq!(update_times(&der).1, time_tlv(0x18, b"99991231235959Z"));

        params.next_update += Duration::from_secs(1);
        let mut signed = false;
        build_crl(&params, CrlSignatureAlgorithm::EcdsaSha256, |_| {
            signed = true;
            Ok(vec![0x00])
        })
        .unwrap_err();
        assert!(!signed);
    }

    #[test]
    fn crl_distribution_point_is_a_sequence_carrying_the_uri() {
        let uri = "http://127.0.0.1:9999/abc.crl";
        let der = crl_distribution_point_der(uri);
        yasna::parse_der(&der, |r| {
            r.read_sequence(|r| {
                let _dp = r.next().read_der()?;
                Ok(())
            })
        })
        .expect("CRLDistributionPoints is a SEQUENCE");
        assert!(
            der.windows(uri.len()).any(|w| w == uri.as_bytes()),
            "URI present in the distribution point"
        );
    }
}
