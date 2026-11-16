use super::*;
use rama_net::address::Domain;

use crate::dep::boring::{
    asn1::Asn1Time,
    ec::{EcGroup, EcKey},
    hash::MessageDigest,
    nid::Nid,
    pkey::Id,
    x509::{
        X509Extension, X509NameBuilder,
        extension::{BasicConstraints, KeyUsage, SubjectAlternativeName},
    },
};

#[derive(Clone, Default)]
struct TestCertData {
    organisation_name: Option<String>,
    common_name: Option<Domain>,
    subject_alternative_names: Option<Vec<Domain>>,
    subject_alternative_ip_addresses: Option<Vec<std::net::IpAddr>>,
    key_kind: CertificateKeyKind,
}

fn ca_config(data: &TestCertData) -> SelfSignedCaConfig {
    SelfSignedCaConfig {
        subject: CertificateSubject {
            organisation_name: data.organisation_name.clone(),
            common_name: data
                .common_name
                .as_ref()
                .map(|domain| domain.as_str().to_owned()),
        },
        key_kind: data.key_kind,
        ..Default::default()
    }
}

fn leaf_request(data: &TestCertData) -> LeafCertRequest {
    let mut identities = Vec::new();
    if let Some(domain) = data.common_name.clone() {
        identities.push(CertificateIdentity::from(domain));
    }
    identities.extend(
        data.subject_alternative_names
            .iter()
            .flatten()
            .cloned()
            .map(CertificateIdentity::from),
    );
    identities.extend(
        data.subject_alternative_ip_addresses
            .iter()
            .flatten()
            .copied()
            .map(CertificateIdentity::Ip),
    );
    if identities.is_empty() {
        identities.push(CertificateIdentity::Dns(Domain::from_static("localhost")));
    }
    LeafCertRequest {
        config: crate::cert::LeafCertConfig {
            subject: ca_config(data).subject,
            key_kind: data.key_kind,
            ..Default::default()
        },
        identities,
    }
}

fn generate_test_ca(data: &TestCertData) -> Result<(X509, PKey<Private>), BoxError> {
    generate_certificate_authority_x509(&ca_config(data))
}

fn issue_test_leaf(
    data: &TestCertData,
    ca_cert: &X509,
    ca_key: &PKey<Private>,
) -> Result<(X509, PKey<Private>), BoxError> {
    issue_leaf_certificate(&leaf_request(data), ca_cert, ca_key)
}

fn generate_test_server_auth(
    data: &TestCertData,
) -> Result<(Vec<CertificateDer<'static>>, PrivateKeyDer<'static>), BoxError> {
    generate_server_auth(GeneratedServerAuthConfig::GeneratedCa {
        ca: ca_config(data),
        leaf: leaf_request(data),
    })
}

fn sample_data(common_name: &'static str) -> TestCertData {
    TestCertData {
        common_name: Some(Domain::from_static(common_name)),
        organisation_name: Some("Rama Test".to_owned()),
        ..Default::default()
    }
}

fn ext_by_nid(cert: &X509Ref, nid: Nid) -> Vec<&crate::dep::boring::x509::X509ExtensionRef> {
    cert.extensions()
        .filter(|ext| ext.object().nid() == nid)
        .collect()
}

fn build_self_signed_source_with_pkey(
    pkey: &PKey<Private>,
    common_name: &str,
) -> Result<X509, BoxError> {
    let mut x509_name = X509NameBuilder::new().context("create x509 name builder")?;
    x509_name
        .append_entry_by_nid(Nid::COMMONNAME, common_name)
        .context("append common name to x509 name builder")?;
    let x509_name = x509_name.build();

    let mut cert_builder = X509::builder().context("create x509 cert builder")?;
    cert_builder
        .set_version(2)
        .context("set version on source cert")?;
    let serial_number = {
        let mut serial = BigNum::new().context("create source serial big num")?;
        serial
            .rand(159, MsbOption::MAYBE_ZERO, false)
            .context("randomise source serial")?;
        serial
            .to_asn1_integer()
            .context("convert source serial to asn1 integer")?
    };
    cert_builder
        .set_serial_number(&serial_number)
        .context("set source serial number")?;
    cert_builder
        .set_subject_name(&x509_name)
        .context("set source subject")?;
    cert_builder
        .set_issuer_name(&x509_name)
        .context("set source issuer")?;
    cert_builder
        .set_pubkey(pkey)
        .context("set source public key")?;
    let not_before = Asn1Time::days_from_now(0).context("source not before")?;
    cert_builder
        .set_not_before(&not_before)
        .context("set source not before")?;
    let not_after = Asn1Time::days_from_now(30).context("source not after")?;
    cert_builder
        .set_not_after(&not_after)
        .context("set source not after")?;

    let san = SubjectAlternativeName::new()
        .dns(common_name)
        .build(&cert_builder.x509v3_context(None, None))
        .context("build source san")?;
    cert_builder
        .append_extension(san.as_ref())
        .context("append source san")?;

    cert_builder
        .sign(pkey, MessageDigest::sha256())
        .context("sign source cert")?;

    Ok(cert_builder.build())
}

#[test]
fn gen_ca_basics() {
    let data = sample_data("ca.rama.test");
    let (ca_cert, ca_key) = generate_test_ca(&data).expect("generate CA");

    assert_eq!(ca_key.id(), Id::EC); // default key kind is EC P-256
    assert!(ca_cert.verify(&ca_key).expect("verify self-signed ca cert"));
    assert_eq!(
        ca_cert.subject_name().to_der().expect("ca subject der"),
        ca_cert.issuer_name().to_der().expect("ca issuer der")
    );

    let basic_constraints = ext_by_nid(ca_cert.as_ref(), Nid::BASIC_CONSTRAINTS);
    assert_eq!(basic_constraints.len(), 1);
    assert!(basic_constraints[0].critical());
    let key_usage = ext_by_nid(ca_cert.as_ref(), Nid::KEY_USAGE);
    assert_eq!(key_usage.len(), 1);
    assert!(key_usage[0].critical());
}

#[test]
fn gen_leaf_signed_by_ca_covers_requested_identity() {
    let ca_data = sample_data("ca.rama.test");
    let (ca_cert, ca_key) = generate_test_ca(&ca_data).expect("generate CA");

    let leaf_data = sample_data("leaf.rama.test");
    let (leaf_cert, leaf_key) =
        issue_test_leaf(&leaf_data, &ca_cert, &ca_key).expect("generate leaf");

    assert_eq!(leaf_key.id(), Id::EC); // default key kind is EC P-256
    assert_eq!(ca_cert.issued(&leaf_cert), Ok(()));
    assert_eq!(
        leaf_cert.issuer_name().to_der().expect("leaf issuer der"),
        ca_cert.subject_name().to_der().expect("ca subject der")
    );

    let cn = leaf_cert
        .subject_name()
        .entries_by_nid(Nid::COMMONNAME)
        .next()
        .expect("leaf common name");
    assert_eq!(
        cn.data()
            .as_utf8()
            .expect("leaf common name utf8")
            .to_string(),
        "leaf.rama.test"
    );

    let san = leaf_cert.subject_alt_names().expect("leaf SAN");
    assert!(
        san.iter()
            .any(|name| name.dnsname() == Some("leaf.rama.test"))
    );
}

#[test]
fn mirror_preserves_subject_validity_and_issuer() {
    let ca_data = sample_data("ca.rama.test");
    let (ca_cert, ca_key) = generate_test_ca(&ca_data).expect("generate CA");
    let source_data = sample_data("source.rama.test");
    let (source_cert, _) = issue_test_leaf(&source_data, &ca_cert, &ca_key).expect("source cert");

    let (mirrored_cert, mirrored_key) =
        self_signed_server_auth_mirror_cert(source_cert.as_ref(), &ca_cert, &ca_key)
            .expect("mirror cert");

    assert_eq!(ca_cert.issued(&mirrored_cert), Ok(()));
    assert_eq!(
        source_cert
            .subject_name()
            .to_der()
            .expect("source subject der"),
        mirrored_cert
            .subject_name()
            .to_der()
            .expect("mirrored subject der")
    );
    assert_eq!(source_cert.not_before(), mirrored_cert.not_before());
    assert_eq!(source_cert.not_after(), mirrored_cert.not_after());
    assert_eq!(
        mirrored_cert
            .issuer_name()
            .to_der()
            .expect("mirrored issuer der"),
        ca_cert.subject_name().to_der().expect("ca subject der")
    );
    // source was gen'd with the default key kind (EC P-256), so the mirror
    // matches it.
    assert_eq!(mirrored_key.id(), Id::EC);
}

#[test]
fn mirror_copies_extensions_and_regenerates_key_ids() {
    let ca_data = sample_data("ca.rama.test");
    let (ca_cert, ca_key) = generate_test_ca(&ca_data).expect("generate CA");
    let source_data = sample_data("source.rama.test");
    let (source_cert, _) = issue_test_leaf(&source_data, &ca_cert, &ca_key).expect("source cert");
    let (mirrored_cert, _) =
        self_signed_server_auth_mirror_cert(source_cert.as_ref(), &ca_cert, &ca_key)
            .expect("mirror cert");

    let source_exts: Vec<_> = source_cert.extensions().collect();
    let mirrored_exts: Vec<_> = mirrored_cert.extensions().collect();

    for source_ext in source_exts {
        let nid = source_ext.object().nid();
        if nid == Nid::SUBJECT_KEY_IDENTIFIER || nid == Nid::AUTHORITY_KEY_IDENTIFIER {
            continue;
        }
        let found = mirrored_exts.iter().any(|mirrored_ext| {
            mirrored_ext.object().nid() == nid
                && mirrored_ext.critical() == source_ext.critical()
                && mirrored_ext.data().as_slice() == source_ext.data().as_slice()
        });
        assert!(found, "missing mirrored extension for nid={nid:?}");
    }

    let source_skid = ext_by_nid(source_cert.as_ref(), Nid::SUBJECT_KEY_IDENTIFIER);
    let mirror_skid = ext_by_nid(mirrored_cert.as_ref(), Nid::SUBJECT_KEY_IDENTIFIER);
    assert_eq!(source_skid.len(), 1);
    assert_eq!(mirror_skid.len(), 1);
    assert_ne!(
        source_skid[0].data().as_slice(),
        mirror_skid[0].data().as_slice()
    );

    let source_akid = ext_by_nid(source_cert.as_ref(), Nid::AUTHORITY_KEY_IDENTIFIER);
    let mirror_akid = ext_by_nid(mirrored_cert.as_ref(), Nid::AUTHORITY_KEY_IDENTIFIER);
    assert_eq!(source_akid.len(), 1);
    assert_eq!(mirror_akid.len(), 1);
}

fn build_source_with_ski_only(
    ca_cert: &X509,
    ca_privkey: &PKey<Private>,
    common_name: &str,
) -> Result<(X509, PKey<Private>), BoxError> {
    let rsa = Rsa::generate(2048).context("generate source rsa")?;
    let privkey = PKey::from_rsa(rsa).context("source pkey")?;

    let mut x509_name = X509NameBuilder::new().context("source name builder")?;
    x509_name
        .append_entry_by_nid(Nid::COMMONNAME, common_name)
        .context("source cn")?;
    let x509_name = x509_name.build();

    let mut cert_builder = X509::builder().context("source builder")?;
    cert_builder.set_version(2).context("source version")?;
    let serial_number = {
        let mut serial = BigNum::new().context("source serial bn")?;
        serial
            .rand(159, MsbOption::MAYBE_ZERO, false)
            .context("source serial rand")?;
        serial.to_asn1_integer().context("source serial asn1")?
    };
    cert_builder
        .set_serial_number(&serial_number)
        .context("source serial")?;
    cert_builder
        .set_subject_name(&x509_name)
        .context("source subject")?;
    cert_builder
        .set_issuer_name(ca_cert.subject_name())
        .context("source issuer")?;
    cert_builder.set_pubkey(&privkey).context("source pubkey")?;
    let not_before = Asn1Time::days_from_now(0).context("source nb")?;
    cert_builder
        .set_not_before(&not_before)
        .context("source set nb")?;
    let not_after = Asn1Time::days_from_now(30).context("source na")?;
    cert_builder
        .set_not_after(&not_after)
        .context("source set na")?;

    let san = SubjectAlternativeName::new()
        .dns(common_name)
        .build(&cert_builder.x509v3_context(Some(ca_cert), None))
        .context("source san")?;
    cert_builder
        .append_extension(san.as_ref())
        .context("append source san")?;

    let ski = SubjectKeyIdentifier::new()
        .build(&cert_builder.x509v3_context(Some(ca_cert), None))
        .context("source ski")?;
    cert_builder
        .append_extension(ski.as_ref())
        .context("append source ski")?;

    cert_builder
        .sign(ca_privkey, MessageDigest::sha256())
        .context("sign source")?;

    Ok((cert_builder.build(), privkey))
}

#[derive(Clone, Copy)]
enum TestCaKeyUsage {
    Absent,
    CertificateSigning,
    WithoutCertificateSigning,
}

fn build_ca_without_ski(
    common_name: &str,
    key_usage: TestCaKeyUsage,
) -> Result<(X509, PKey<Private>), BoxError> {
    let rsa = Rsa::generate(2048).context("ca rsa")?;
    let privkey = PKey::from_rsa(rsa).context("ca pkey")?;

    let mut x509_name = X509NameBuilder::new().context("ca name builder")?;
    x509_name
        .append_entry_by_nid(Nid::COMMONNAME, common_name)
        .context("ca cn")?;
    let x509_name = x509_name.build();

    let mut ca_cert_builder = X509::builder().context("ca builder")?;
    ca_cert_builder.set_version(2).context("ca version")?;
    let serial_number = {
        let mut serial = BigNum::new().context("ca serial bn")?;
        serial
            .rand(159, MsbOption::MAYBE_ZERO, false)
            .context("ca serial rand")?;
        serial.to_asn1_integer().context("ca serial asn1")?
    };
    ca_cert_builder
        .set_serial_number(&serial_number)
        .context("ca serial")?;
    ca_cert_builder
        .set_subject_name(&x509_name)
        .context("ca subject")?;
    ca_cert_builder
        .set_issuer_name(&x509_name)
        .context("ca issuer")?;
    ca_cert_builder.set_pubkey(&privkey).context("ca pubkey")?;
    let not_before = Asn1Time::days_from_now(0).context("ca nb")?;
    ca_cert_builder
        .set_not_before(&not_before)
        .context("ca set nb")?;
    let not_after = Asn1Time::days_from_now(365).context("ca na")?;
    ca_cert_builder
        .set_not_after(&not_after)
        .context("ca set na")?;

    ca_cert_builder
        .append_extension(
            BasicConstraints::new()
                .critical()
                .ca()
                .build()
                .context("ca basic constraints")?
                .as_ref(),
        )
        .context("append ca bc")?;
    match key_usage {
        TestCaKeyUsage::Absent => {}
        TestCaKeyUsage::CertificateSigning => {
            ca_cert_builder
                .append_extension(
                    KeyUsage::new()
                        .critical()
                        .key_cert_sign()
                        .crl_sign()
                        .build()
                        .context("ca key usage")?
                        .as_ref(),
                )
                .context("append ca ku")?;
        }
        TestCaKeyUsage::WithoutCertificateSigning => {
            ca_cert_builder
                .append_extension(
                    KeyUsage::new()
                        .critical()
                        .digital_signature()
                        .build()
                        .context("ca key usage")?
                        .as_ref(),
                )
                .context("append ca ku")?;
        }
    }

    ca_cert_builder
        .sign(&privkey, MessageDigest::sha256())
        .context("sign ca")?;

    Ok((ca_cert_builder.build(), privkey))
}

#[test]
fn provided_ca_without_key_usage_is_accepted() {
    let (ca_cert, ca_key) = build_ca_without_ski("no-ku-ca.rama.test", TestCaKeyUsage::Absent)
        .expect("CA without key usage");
    let ca = CertificateAuthorityData::try_new(
        vec![serialize_cert(&ca_cert).expect("serialize CA certificate")],
        serialize_key(&ca_key).expect("serialize CA key"),
    )
    .expect("accept CA without key usage");
    assert_eq!(ca.certificate_chain().len(), 1);
}

#[test]
fn provided_ca_key_usage_without_key_cert_sign_is_rejected() {
    let (ca_cert, ca_key) = build_ca_without_ski(
        "invalid-ku-ca.rama.test",
        TestCaKeyUsage::WithoutCertificateSigning,
    )
    .expect("CA without certificate-signing key usage");
    let error = CertificateAuthorityData::try_new(
        vec![serialize_cert(&ca_cert).expect("serialize CA certificate")],
        serialize_key(&ca_key).expect("serialize CA key"),
    )
    .expect_err("reject CA key usage without keyCertSign");
    assert_eq!(
        error.to_string(),
        "certificate authority chain certificate must permit certificate signing"
    );
}

#[test]
fn mirror_aki_keyid_matches_ca_ski() {
    let ca_data = sample_data("ca.rama.test");
    let (ca_cert, ca_key) = generate_test_ca(&ca_data).expect("generate CA");
    let source_data = sample_data("source.rama.test");
    let (source_cert, _) = issue_test_leaf(&source_data, &ca_cert, &ca_key).expect("source cert");

    let (mirrored_cert, _) =
        self_signed_server_auth_mirror_cert(source_cert.as_ref(), &ca_cert, &ca_key)
            .expect("mirror cert");

    let ca_ski = ca_cert.subject_key_id().expect("ca has ski");
    let mirror_aki = mirrored_cert.authority_key_id().expect("mirror has aki");
    assert_eq!(mirror_aki.as_slice(), ca_ski.as_slice());
}

#[test]
fn mirror_omits_aki_when_source_has_no_aki() {
    let ca_data = sample_data("ca.rama.test");
    let (ca_cert, ca_key) = generate_test_ca(&ca_data).expect("generate CA");

    let (source_cert, _) =
        build_source_with_ski_only(&ca_cert, &ca_key, "ski-only.rama.test").expect("source cert");
    assert!(source_cert.subject_key_id().is_some());
    assert!(source_cert.authority_key_id().is_none());

    let (mirrored_cert, _) =
        self_signed_server_auth_mirror_cert(source_cert.as_ref(), &ca_cert, &ca_key)
            .expect("mirror cert");

    assert!(mirrored_cert.subject_key_id().is_some());
    assert!(mirrored_cert.authority_key_id().is_none());
}

#[test]
fn mirror_omits_ski_and_aki_when_source_has_neither() {
    let ca_data = sample_data("ca.rama.test");
    let (ca_cert, ca_key) = generate_test_ca(&ca_data).expect("generate CA");

    let rsa = Rsa::generate(2048).expect("source rsa");
    let source_pkey = PKey::from_rsa(rsa).expect("source pkey");
    let source_cert = build_self_signed_source_with_pkey(&source_pkey, "no-keyid.rama.test")
        .expect("source cert");
    assert!(source_cert.subject_key_id().is_none());
    assert!(source_cert.authority_key_id().is_none());

    let (mirrored_cert, _) =
        self_signed_server_auth_mirror_cert(source_cert.as_ref(), &ca_cert, &ca_key)
            .expect("mirror cert");

    assert!(mirrored_cert.subject_key_id().is_none());
    assert!(mirrored_cert.authority_key_id().is_none());
}

#[test]
fn mirror_derives_aki_keyid_when_ca_has_no_ski() {
    let (ca_cert, ca_key) =
        build_ca_without_ski("no-ski-ca.rama.test", TestCaKeyUsage::CertificateSigning)
            .expect("ca without ski");
    assert!(ca_cert.subject_key_id().is_none());

    // Source cert (self-signed) with both SKI and AKI present, so mirror re-emits both. The
    // CA-lacks-SKI fallback must populate AKI keyIdentifier via SHA-1 of the CA pubkey BIT
    // STRING (RFC 5280 §4.2.1.2 method 1), not skip the extension.
    let rsa = Rsa::generate(2048).expect("source rsa");
    let source_pkey = PKey::from_rsa(rsa).expect("source pkey");
    let mut x509_name = X509NameBuilder::new().expect("source name builder");
    x509_name
        .append_entry_by_nid(Nid::COMMONNAME, "with-keyid-source.rama.test")
        .expect("source cn");
    let x509_name = x509_name.build();
    let mut cert_builder = X509::builder().expect("source builder");
    cert_builder.set_version(2).expect("source version");
    let serial = {
        let mut serial = BigNum::new().expect("source serial bn");
        serial
            .rand(159, MsbOption::MAYBE_ZERO, false)
            .expect("source serial rand");
        serial.to_asn1_integer().expect("source serial asn1")
    };
    cert_builder
        .set_serial_number(&serial)
        .expect("source serial");
    cert_builder
        .set_subject_name(&x509_name)
        .expect("source subject");
    cert_builder
        .set_issuer_name(&x509_name)
        .expect("source issuer");
    cert_builder
        .set_pubkey(&source_pkey)
        .expect("source pubkey");
    cert_builder
        .set_not_before(&Asn1Time::days_from_now(0).expect("source nb"))
        .expect("source set nb");
    cert_builder
        .set_not_after(&Asn1Time::days_from_now(30).expect("source na"))
        .expect("source set na");
    let ski = SubjectKeyIdentifier::new()
        .build(&cert_builder.x509v3_context(None, None))
        .expect("source ski");
    cert_builder
        .append_extension(ski.as_ref())
        .expect("append source ski");
    let aki = AuthorityKeyIdentifier::new()
        .keyid(true)
        .build(&cert_builder.x509v3_context(None, None))
        .expect("source aki");
    cert_builder
        .append_extension(aki.as_ref())
        .expect("append source aki");
    cert_builder
        .sign(&source_pkey, MessageDigest::sha256())
        .expect("sign source");
    let source_cert = cert_builder.build();
    assert!(source_cert.subject_key_id().is_some());
    assert!(source_cert.authority_key_id().is_some());

    let (mirrored_cert, _) =
        self_signed_server_auth_mirror_cert(source_cert.as_ref(), &ca_cert, &ca_key)
            .expect("mirror cert succeeds despite CA lacking SKI");

    assert!(mirrored_cert.subject_key_id().is_some());

    let mirror_aki = mirrored_cert
        .authority_key_id()
        .expect("mirror has derived AKI");
    let expected = ca_cert
        .pubkey_digest(MessageDigest::sha1())
        .expect("CA pubkey sha1");
    assert_eq!(expected.len(), 20);
    assert_eq!(mirror_aki.as_slice(), &expected[..]);
}

#[test]
fn gen_cert_derives_aki_keyid_when_ca_has_no_ski() {
    let (ca_cert, ca_key) =
        build_ca_without_ski("no-ski-ca.rama.test", TestCaKeyUsage::CertificateSigning)
            .expect("ca without ski");
    assert!(ca_cert.subject_key_id().is_none());

    let leaf_data = sample_data("leaf.rama.test");
    let (leaf_cert, _) = issue_test_leaf(&leaf_data, &ca_cert, &ca_key).expect("generate leaf");

    assert!(leaf_cert.subject_key_id().is_some());

    let leaf_aki = leaf_cert.authority_key_id().expect("leaf has derived AKI");
    let expected = ca_cert
        .pubkey_digest(MessageDigest::sha1())
        .expect("CA pubkey sha1");
    assert_eq!(leaf_aki.as_slice(), &expected[..]);

    assert_eq!(ca_cert.issued(&leaf_cert), Ok(()));
}

/// Append a raw extension (OID + DER payload) to a cert builder. The mirror
/// logic keys off the extension OID, not the payload, so dummy payloads are
/// sufficient to exercise the strip behaviour.
fn append_raw_ext(
    cert_builder: &mut crate::dep::boring::x509::X509Builder,
    oid: &str,
    critical: bool,
    payload: &[u8],
) -> Result<(), BoxError> {
    let obj = Asn1Object::from_str(oid).context("strippable ext oid")?;
    let ext = X509Extension::from_der_payload(obj.as_ref(), critical, payload)
        .context("build strippable ext")?;
    cert_builder
        .append_extension(ext.as_ref())
        .context("append strippable ext")?;
    Ok(())
}

fn has_ext_oid(cert: &X509Ref, oid: &str) -> bool {
    let want = Asn1Object::from_str(oid).expect("resolve oid").to_string();
    cert.extensions()
        .any(|ext| ext.object().to_string() == want)
}

/// Build a self-signed source cert carrying SAN + KeyUsage (which must survive
/// mirroring) plus every extension class that must be stripped from a re-signed
/// MITM leaf: CRL Distribution Points, Authority Information Access, Freshest
/// CRL, RFC 7633 must-staple, and an RFC 6962 embedded SCT list.
fn build_source_with_strippable_exts(common_name: &str) -> Result<X509, BoxError> {
    let rsa = Rsa::generate(2048).context("source rsa")?;
    let pkey = PKey::from_rsa(rsa).context("source pkey")?;

    let mut x509_name = X509NameBuilder::new().context("source name builder")?;
    x509_name
        .append_entry_by_nid(Nid::COMMONNAME, common_name)
        .context("source cn")?;
    let x509_name = x509_name.build();

    let mut cert_builder = X509::builder().context("source builder")?;
    cert_builder.set_version(2).context("source version")?;
    let serial = {
        let mut serial = BigNum::new().context("source serial bn")?;
        serial
            .rand(159, MsbOption::MAYBE_ZERO, false)
            .context("source serial rand")?;
        serial.to_asn1_integer().context("source serial asn1")?
    };
    cert_builder
        .set_serial_number(&serial)
        .context("source serial")?;
    cert_builder
        .set_subject_name(&x509_name)
        .context("source subject")?;
    cert_builder
        .set_issuer_name(&x509_name)
        .context("source issuer")?;
    cert_builder.set_pubkey(&pkey).context("source pubkey")?;
    let not_before = Asn1Time::days_from_now(0).context("source nb")?;
    cert_builder
        .set_not_before(&not_before)
        .context("source set nb")?;
    let not_after = Asn1Time::days_from_now(30).context("source na")?;
    cert_builder
        .set_not_after(&not_after)
        .context("source set na")?;

    // survivors
    let san = SubjectAlternativeName::new()
        .dns(common_name)
        .build(&cert_builder.x509v3_context(None, None))
        .context("source san")?;
    cert_builder
        .append_extension(san.as_ref())
        .context("append source san")?;
    cert_builder
        .append_extension(
            KeyUsage::new()
                .critical()
                .digital_signature()
                .key_encipherment()
                .build()
                .context("source ku")?
                .as_ref(),
        )
        .context("append source ku")?;

    // strippable: issuer-bound revocation / authority pointers
    append_raw_ext(&mut cert_builder, "2.5.29.31", false, &[0x30, 0x00])?; // CRL DP
    append_raw_ext(&mut cert_builder, "1.3.6.1.5.5.7.1.1", false, &[0x30, 0x00])?; // AIA
    append_raw_ext(&mut cert_builder, "2.5.29.46", false, &[0x30, 0x00])?; // Freshest CRL
    // strippable: assertions we cannot honour after re-signing
    append_raw_ext(
        &mut cert_builder,
        "1.3.6.1.5.5.7.1.24",
        true,
        &[0x30, 0x03, 0x02, 0x01, 0x05],
    )?; // must-staple
    append_raw_ext(
        &mut cert_builder,
        "1.3.6.1.4.1.11129.2.4.2",
        false,
        &[0x04, 0x02, 0x00, 0x00],
    )?; // SCT list

    cert_builder
        .sign(&pkey, MessageDigest::sha256())
        .context("sign source")?;

    Ok(cert_builder.build())
}

#[test]
fn mirror_strips_issuer_bound_and_unsatisfiable_extensions() {
    let ca_data = sample_data("ca.rama.test");
    let (ca_cert, ca_key) = generate_test_ca(&ca_data).expect("generate CA");

    let source_cert =
        build_source_with_strippable_exts("strip.rama.test").expect("build source cert");

    // sanity: the source really does carry all of them
    assert!(!ext_by_nid(source_cert.as_ref(), Nid::CRL_DISTRIBUTION_POINTS).is_empty());
    assert!(!ext_by_nid(source_cert.as_ref(), Nid::INFO_ACCESS).is_empty());
    assert!(!ext_by_nid(source_cert.as_ref(), Nid::FRESHEST_CRL).is_empty());
    assert!(has_ext_oid(source_cert.as_ref(), "1.3.6.1.5.5.7.1.24"));
    assert!(has_ext_oid(source_cert.as_ref(), "1.3.6.1.4.1.11129.2.4.2"));

    let (mirrored_cert, _) =
        self_signed_server_auth_mirror_cert(source_cert.as_ref(), &ca_cert, &ca_key)
            .expect("mirror cert");

    // stripped
    assert!(
        ext_by_nid(mirrored_cert.as_ref(), Nid::CRL_DISTRIBUTION_POINTS).is_empty(),
        "CRL Distribution Points must be stripped"
    );
    assert!(
        ext_by_nid(mirrored_cert.as_ref(), Nid::INFO_ACCESS).is_empty(),
        "Authority Information Access must be stripped"
    );
    assert!(
        ext_by_nid(mirrored_cert.as_ref(), Nid::FRESHEST_CRL).is_empty(),
        "Freshest CRL must be stripped"
    );
    assert!(
        !has_ext_oid(mirrored_cert.as_ref(), "1.3.6.1.5.5.7.1.24"),
        "must-staple (TLS Feature) must be stripped"
    );
    assert!(
        !has_ext_oid(mirrored_cert.as_ref(), "1.3.6.1.4.1.11129.2.4.2"),
        "embedded SCT list must be stripped"
    );

    // survivors: identity-bearing extensions are still mirrored
    assert!(
        !ext_by_nid(mirrored_cert.as_ref(), Nid::KEY_USAGE).is_empty(),
        "Key Usage must survive mirroring"
    );
    let san = mirrored_cert.subject_alt_names().expect("mirrored SAN");
    assert!(
        san.iter()
            .any(|name| name.dnsname() == Some("strip.rama.test")),
        "SAN must survive mirroring"
    );

    // and the leaf is still validly issued by our CA
    assert_eq!(ca_cert.issued(&mirrored_cert), Ok(()));
}

#[test]
fn mirror_uses_ec_key_for_ec_source() {
    let ca_data = sample_data("ca.rama.test");
    let (ca_cert, ca_key) = generate_test_ca(&ca_data).expect("generate CA");

    let group = EcGroup::from_curve_name(Nid::X9_62_PRIME256V1).expect("ec group");
    let ec_key = EcKey::generate(&group).expect("generate ec key");
    let source_key = PKey::from_ec_key(ec_key).expect("pkey from ec key");
    let source_cert = build_self_signed_source_with_pkey(&source_key, "ec-source.rama.test")
        .expect("source cert");

    let (_, mirrored_key) =
        self_signed_server_auth_mirror_cert(source_cert.as_ref(), &ca_cert, &ca_key)
            .expect("mirror cert");

    assert_eq!(mirrored_key.id(), Id::EC);
}

/// Build a self-signed Ed25519 CA, signed via the NULL-digest EdDSA path.
fn build_ed25519_ca(common_name: &str) -> Result<(X509, PKey<Private>), BoxError> {
    let mut seed = [0_u8; 32];
    crate::dep::boring::rand::rand_bytes(&mut seed).context("ed25519 ca key bytes")?;
    let privkey = PKey::from_ed25519_private_key(&seed).context("ed25519 ca pkey")?;

    let mut x509_name = X509NameBuilder::new().context("ca name builder")?;
    x509_name
        .append_entry_by_nid(Nid::COMMONNAME, common_name)
        .context("ca cn")?;
    let x509_name = x509_name.build();

    let mut b = X509::builder().context("ca builder")?;
    b.set_version(2).context("ca version")?;
    let serial = {
        let mut serial = BigNum::new().context("ca serial bn")?;
        serial
            .rand(159, MsbOption::MAYBE_ZERO, false)
            .context("ca serial rand")?;
        serial.to_asn1_integer().context("ca serial asn1")?
    };
    b.set_serial_number(&serial).context("ca serial")?;
    b.set_subject_name(&x509_name).context("ca subject")?;
    b.set_issuer_name(&x509_name).context("ca issuer")?;
    b.set_pubkey(&privkey).context("ca pubkey")?;
    let not_before = Asn1Time::days_from_now(0).context("ca nb")?;
    b.set_not_before(&not_before).context("ca set nb")?;
    let not_after = Asn1Time::days_from_now(365).context("ca na")?;
    b.set_not_after(&not_after).context("ca set na")?;
    b.append_extension(
        BasicConstraints::new()
            .critical()
            .ca()
            .build()
            .context("ca bc")?
            .as_ref(),
    )
    .context("append ca bc")?;
    b.append_extension(
        KeyUsage::new()
            .critical()
            .key_cert_sign()
            .crl_sign()
            .build()
            .context("ca ku")?
            .as_ref(),
    )
    .context("append ca ku")?;
    let ski = SubjectKeyIdentifier::new()
        .build(&b.x509v3_context(None, None))
        .context("ca ski")?;
    b.append_extension(ski.as_ref()).context("append ca ski")?;

    b.sign(&privkey, signing_digest_for(&privkey))
        .context("sign ed25519 ca")?;

    Ok((b.build(), privkey))
}

#[test]
fn signing_digest_is_null_for_eddsa_and_sha256_otherwise() {
    let mut seed = [0_u8; 32];
    crate::dep::boring::rand::rand_bytes(&mut seed).expect("seed");
    let ed = PKey::from_ed25519_private_key(&seed).expect("ed25519 key");
    assert!(
        signing_digest_for(&ed).as_ptr().is_null(),
        "EdDSA must sign with a NULL digest"
    );

    let rsa = PKey::from_rsa(Rsa::generate(2048).expect("rsa")).expect("rsa pkey");
    assert_eq!(
        signing_digest_for(&rsa).as_ptr(),
        MessageDigest::sha256().as_ptr(),
        "non-EdDSA keys sign over SHA-256"
    );
}

#[test]
fn gen_and_mirror_with_ed25519_ca_produce_valid_signatures() {
    let (ca_cert, ca_key) = build_ed25519_ca("ed25519-ca.rama.test").expect("ed25519 ca");
    assert_eq!(ca_key.id(), Id::ED25519);
    assert!(
        ca_cert
            .verify(&ca_key)
            .expect("verify self-signed ed25519 ca"),
        "self-signed Ed25519 CA signature must verify"
    );

    // gen_cert signs a fresh leaf with the Ed25519 CA
    let leaf_data = sample_data("leaf.rama.test");
    let (leaf, _) =
        issue_test_leaf(&leaf_data, &ca_cert, &ca_key).expect("gen leaf with ed25519 ca");
    assert_eq!(ca_cert.issued(&leaf), Ok(()));
    assert!(
        leaf.verify(&ca_key).expect("verify leaf sig"),
        "leaf signed by Ed25519 CA must verify"
    );

    // the mirror path must likewise sign correctly with the Ed25519 CA
    let source_pkey =
        PKey::from_rsa(Rsa::generate(2048).expect("source rsa")).expect("source pkey");
    let source =
        build_self_signed_source_with_pkey(&source_pkey, "source.rama.test").expect("source cert");
    let (mirrored, _) = self_signed_server_auth_mirror_cert(source.as_ref(), &ca_cert, &ca_key)
        .expect("mirror with ed25519 ca");
    assert_eq!(ca_cert.issued(&mirrored), Ok(()));
    assert!(
        mirrored.verify(&ca_key).expect("verify mirrored sig"),
        "mirrored leaf signed by Ed25519 CA must verify"
    );
}

#[test]
fn signing_digest_pairs_to_ec_curve() {
    let ec = |nid| {
        let group = EcGroup::from_curve_name(nid).expect("ec group");
        PKey::from_ec_key(EcKey::generate(&group).expect("ec key")).expect("ec pkey")
    };

    assert_eq!(
        signing_digest_for(&ec(Nid::X9_62_PRIME256V1)).as_ptr(),
        MessageDigest::sha256().as_ptr(),
        "P-256 must sign over SHA-256"
    );
    assert_eq!(
        signing_digest_for(&ec(Nid::SECP384R1)).as_ptr(),
        MessageDigest::sha384().as_ptr(),
        "P-384 must sign over SHA-384"
    );
    assert_eq!(
        signing_digest_for(&ec(Nid::SECP521R1)).as_ptr(),
        MessageDigest::sha512().as_ptr(),
        "P-521 must sign over SHA-512"
    );
}

#[test]
fn gen_ca_honors_key_kind() {
    for (kind, want) in [
        (CertificateKeyKind::Rsa2048, Id::RSA),
        (CertificateKeyKind::EcP256, Id::EC),
        (CertificateKeyKind::EcP384, Id::EC),
        (CertificateKeyKind::EcP521, Id::EC),
        (CertificateKeyKind::Ed25519, Id::ED25519),
    ] {
        let data = TestCertData {
            key_kind: kind,
            ..sample_data("ca.rama.test")
        };
        let (ca_cert, ca_key) = generate_test_ca(&data).expect("gen ca");
        assert_eq!(ca_key.id(), want, "kind={kind:?}");
        assert!(
            ca_cert.verify(&ca_key).expect("verify self-signed ca"),
            "self-signed CA of kind={kind:?} must verify"
        );
    }
}

#[test]
fn gen_cert_with_ec_ca_and_ec_leaf_verifies() {
    let ca_data = TestCertData {
        key_kind: CertificateKeyKind::EcP384,
        ..sample_data("ec-ca.rama.test")
    };
    let (ca_cert, ca_key) = generate_test_ca(&ca_data).expect("ec ca");
    assert_eq!(ca_key.id(), Id::EC);

    let leaf_data = TestCertData {
        key_kind: CertificateKeyKind::EcP256,
        ..sample_data("leaf.rama.test")
    };
    let (leaf, leaf_key) = issue_test_leaf(&leaf_data, &ca_cert, &ca_key).expect("ec leaf");
    assert_eq!(leaf_key.id(), Id::EC);
    assert_eq!(ca_cert.issued(&leaf), Ok(()));
    assert!(
        leaf.verify(&ca_key).expect("verify leaf"),
        "leaf signed by P-384 CA must verify"
    );
}

/// Build a source cert whose *subject* public key is `subject_pub`, signed by a
/// separate issuer. Needed for source keys (e.g. X25519) that cannot self-sign.
fn build_source_cert_with_pubkey(
    subject_pub: &PKey<Private>,
    issuer_cert: &X509,
    issuer_key: &PKey<Private>,
    common_name: &str,
) -> Result<X509, BoxError> {
    let mut name = X509NameBuilder::new().context("name builder")?;
    name.append_entry_by_nid(Nid::COMMONNAME, common_name)
        .context("cn")?;
    let name = name.build();

    let mut b = X509::builder().context("builder")?;
    b.set_version(2).context("version")?;
    let serial = {
        let mut s = BigNum::new().context("serial bn")?;
        s.rand(159, MsbOption::MAYBE_ZERO, false)
            .context("serial rand")?;
        s.to_asn1_integer().context("serial asn1")?
    };
    b.set_serial_number(&serial).context("serial")?;
    b.set_subject_name(&name).context("subject")?;
    b.set_issuer_name(issuer_cert.subject_name())
        .context("issuer")?;
    b.set_pubkey(subject_pub).context("pubkey")?;
    let nb = Asn1Time::days_from_now(0).context("nb")?;
    b.set_not_before(&nb).context("set nb")?;
    let na = Asn1Time::days_from_now(30).context("na")?;
    b.set_not_after(&na).context("set na")?;
    b.sign(issuer_key, signing_digest_for(issuer_key))
        .context("sign source")?;
    Ok(b.build())
}

#[test]
fn mirror_falls_back_to_rsa_for_non_signing_source_key() {
    let (ca_cert, ca_key) = generate_test_ca(&sample_data("ca.rama.test")).expect("ca");

    // Source cert whose SUBJECT key is X25519 — a key-agreement-only key that
    // cannot serve as a TLS leaf signing key. Signed by a separate RSA issuer.
    let mut seed = [0_u8; 32];
    crate::dep::boring::rand::rand_bytes(&mut seed).expect("seed");
    let x25519 = PKey::from_x25519_private_key(&seed).expect("x25519 key");
    let (issuer_cert, issuer_key) =
        generate_test_ca(&sample_data("issuer.rama.test")).expect("issuer");
    let source = build_source_cert_with_pubkey(
        &x25519,
        &issuer_cert,
        &issuer_key,
        "x25519-source.rama.test",
    )
    .expect("source cert");
    assert_eq!(source.public_key().expect("source pubkey").id(), Id::X25519);

    let (mirrored, mirrored_key) =
        self_signed_server_auth_mirror_cert(source.as_ref(), &ca_cert, &ca_key).expect("mirror");

    assert_eq!(
        mirrored_key.id(),
        Id::RSA,
        "a non-signing source key must fall back to a functional RSA leaf key"
    );
    assert_eq!(ca_cert.issued(&mirrored), Ok(()));
    assert!(
        mirrored.verify(&ca_key).expect("verify mirrored"),
        "fallback mirrored leaf must verify against the CA"
    );
}

#[test]
fn self_signed_server_auth_produces_leaf_and_ca_der() {
    let data = TestCertData {
        common_name: Some(Domain::from_static("leaf.rama.test")),
        organisation_name: Some("Rama Test".to_owned()),
        ..Default::default()
    };
    let (chain, key) = generate_test_server_auth(&data).expect("generate self-signed");
    assert_eq!(chain.len(), 2, "expected [leaf, ca] chain");
    assert!(!chain[0].as_ref().is_empty());
    assert!(!chain[1].as_ref().is_empty());
    // the returned key is the leaf key as PKCS#8 DER; re-parse to validate.
    let parsed = PKey::private_key_from_pkcs8(match &key {
        PrivateKeyDer::Pkcs8(k) => k.secret_pkcs8_der(),
        _ => panic!("expected PKCS#8 key"),
    })
    .expect("re-parse leaf key");
    assert_eq!(parsed.id(), Id::EC); // default key kind is EC P-256
}

#[test]
fn leaf_san_includes_common_name_and_extra_sans() {
    let data = TestCertData {
        common_name: Some(Domain::from_static("primary.rama.test")),
        subject_alternative_names: Some(vec![
            Domain::from_static("alt-one.rama.test"),
            Domain::from_static("alt-two.rama.test"),
        ]),
        ..Default::default()
    };
    let (ca_cert, ca_key) = generate_test_ca(&data).expect("generate CA");
    let (leaf, _) = issue_test_leaf(&data, &ca_cert, &ca_key).expect("generate leaf");

    let san = leaf.subject_alt_names().expect("leaf has a SAN extension");
    let dns: Vec<String> = san
        .iter()
        .filter_map(|name| name.dnsname().map(str::to_owned))
        .collect();

    assert!(
        dns.iter().any(|n| n == "primary.rama.test"),
        "common name must be present as a SAN; got {dns:?}"
    );
    assert!(
        dns.iter().any(|n| n == "alt-one.rama.test"),
        "extra SAN alt-one.rama.test must be present; got {dns:?}"
    );
    assert!(
        dns.iter().any(|n| n == "alt-two.rama.test"),
        "extra SAN alt-two.rama.test must be present; got {dns:?}"
    );
}

fn build_self_signed_source_with_validity(
    pkey: &PKey<Private>,
    common_name: &str,
    not_before: &Asn1Time,
    not_after: &Asn1Time,
) -> Result<X509, BoxError> {
    let mut x509_name = X509NameBuilder::new().context("create x509 name builder")?;
    x509_name
        .append_entry_by_nid(Nid::COMMONNAME, common_name)
        .context("append common name to x509 name builder")?;
    let x509_name = x509_name.build();

    let mut cert_builder = X509::builder().context("create x509 cert builder")?;
    cert_builder
        .set_version(2)
        .context("set version on source cert")?;
    let serial_number = {
        let mut serial = BigNum::new().context("create source serial big num")?;
        serial
            .rand(159, MsbOption::MAYBE_ZERO, false)
            .context("randomise source serial")?;
        serial
            .to_asn1_integer()
            .context("convert source serial to asn1 integer")?
    };
    cert_builder
        .set_serial_number(&serial_number)
        .context("set source serial number")?;
    cert_builder
        .set_subject_name(&x509_name)
        .context("set source subject")?;
    cert_builder
        .set_issuer_name(&x509_name)
        .context("set source issuer")?;
    cert_builder
        .set_pubkey(pkey)
        .context("set source public key")?;
    cert_builder
        .set_not_before(not_before)
        .context("set source not before")?;
    cert_builder
        .set_not_after(not_after)
        .context("set source not after")?;

    let san = SubjectAlternativeName::new()
        .dns(common_name)
        .build(&cert_builder.x509v3_context(None, None))
        .context("build source san")?;
    cert_builder
        .append_extension(san.as_ref())
        .context("append source san")?;

    cert_builder
        .sign(pkey, MessageDigest::sha256())
        .context("sign source cert")?;

    Ok(cert_builder.build())
}

#[test]
fn mirror_clamps_validity_into_ca_window() {
    let ca_data = sample_data("ca.rama.test");
    let (ca_cert, ca_key) = generate_test_ca(&ca_data).expect("generate CA");

    // A real upstream cert was issued before our fresh CA and may outlive it:
    // notBefore 30 days ago, notAfter 30 years out (well past the CA's 20y).
    let pkey = PKey::from_rsa(Rsa::generate(2048).expect("rsa")).expect("pkey");
    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .expect("now")
        .as_secs();
    let past = Asn1Time::from_unix((now - 30 * 86_400).try_into().expect("time_t"))
        .expect("past not-before");
    let far = Asn1Time::days_from_now(365 * 30).expect("far not-after");
    let source = build_self_signed_source_with_validity(&pkey, "source.rama.test", &past, &far)
        .expect("source cert");
    assert!(
        source.not_before() < ca_cert.not_before() && source.not_after() > ca_cert.not_after(),
        "source must straddle the CA window for this test to mean anything"
    );

    let (mirrored, _) =
        self_signed_server_auth_mirror_cert(source.as_ref(), &ca_cert, &ca_key).expect("mirror");

    // The leaf is fully nested in the CA: notBefore clamped up, notAfter down.
    assert_eq!(
        mirrored.not_before(),
        ca_cert.not_before(),
        "leaf notBefore clamped up to the CA"
    );
    assert_eq!(
        mirrored.not_after(),
        ca_cert.not_after(),
        "leaf notAfter clamped down to the CA"
    );
    assert!(mirrored.not_before() >= ca_cert.not_before());
    assert!(mirrored.not_after() <= ca_cert.not_after());
    assert_eq!(ca_cert.issued(&mirrored), Ok(()));
}
