//! The identities and the Rama-side configurations every scenario uses. A peer's own
//! configuration is its adapter's business; what is shared is the identity it presents or
//! trusts, and the protocol both ends must agree on.

use crate::backend::VerifyBackend as _;
use std::{
    fs,
    net::{Ipv4Addr, Ipv6Addr},
    path::{Path, PathBuf},
    sync::Arc,
};

use rama::{
    crypto::{
        cert::{CertificateIdentity, CertificateSubject, LeafCertRequest, SelfSignedCaConfig},
        pem::PemEncode,
        pki_types::CertificateDer,
    },
    net::{address::Domain, tls::ApplicationProtocol},
    quic::{ClientConfig, ServerConfig, TransportConfig},
    tls::{
        client::TlsClientConfig,
        server::{GeneratedServerAuthConfig, ServerAuthData, TlsServerConfig},
    },
    utils::{collections::smallvec::smallvec, fs::TempDir},
};

use crate::scenario::{ANOTHER_NAME, SERVER_NAME};
use crate::support::IDLE_TIMEOUT;

/// The protocol every shared scenario negotiates. A handshake that settles on anything else is
/// a failure, not a variant.
pub const ALPN: &[u8] = b"rama-quic-interop";

/// One generated identity: whichever side is the server presents it, and the other trusts it.
pub type Identity = ServerAuthData;

#[must_use]
pub fn alpn() -> ApplicationProtocol {
    ApplicationProtocol::from(ALPN)
}

#[must_use]
pub fn server_identity() -> Identity {
    ServerAuthData::new_generated(GeneratedServerAuthConfig::default())
        .expect("an identity is generated")
}

/// An identity issued by a certificate authority with a name of its own, so a peer trusting
/// another anchor finds no issuer for it.
#[must_use]
pub fn identity_from_a_stranger(issuer: &str) -> Identity {
    ServerAuthData::new_generated(GeneratedServerAuthConfig::GeneratedCa {
        ca: SelfSignedCaConfig {
            subject: CertificateSubject {
                organisation_name: Some(issuer.to_owned()),
                common_name: Some(issuer.to_owned()),
            },
            ..Default::default()
        },
        leaf: LeafCertRequest::default(),
    })
    .expect("an identity is generated")
}

/// An identity for a name that is not the one a case asks for, for the same-type name
/// mismatch.
#[must_use]
pub fn another_named_identity() -> Identity {
    ServerAuthData::new_self_signed_leaf(LeafCertRequest::new(CertificateIdentity::Dns(
        Domain::from_static(ANOTHER_NAME),
    )))
    .expect("an identity is generated")
}

/// An identity for a loopback address that is not the one a peer binds, for the same-type
/// address mismatch.
#[must_use]
pub fn another_address_identity() -> Identity {
    ServerAuthData::new_self_signed_leaf(LeafCertRequest::new(CertificateIdentity::Ip(
        Ipv4Addr::new(127, 0, 0, 2).into(),
    )))
    .expect("an identity is generated")
}

/// An identity valid for the IPv6 loopback address, for the same over that socket family.
#[must_use]
pub fn address_identity_v6() -> Identity {
    ServerAuthData::new_self_signed_leaf(LeafCertRequest::new(CertificateIdentity::Ip(
        Ipv6Addr::LOCALHOST.into(),
    )))
    .expect("an identity is generated")
}

/// An identity valid for the loopback address, so a client may name the address it connects
/// to.
#[must_use]
pub fn address_identity() -> Identity {
    ServerAuthData::new_self_signed_leaf(LeafCertRequest::new(CertificateIdentity::Ip(
        Ipv4Addr::LOCALHOST.into(),
    )))
    .expect("an identity is generated")
}

/// The anchor a peer has to trust to accept `identity`.
#[must_use]
pub fn anchor_of(identity: &Identity) -> CertificateDer<'static> {
    identity.cert_chain.last().expect("a chain").clone()
}

/// The transport both Rama sides use: the defaults, with an idle timeout above every
/// scenario's deadline so a slow exchange is bounded by the deadline, not cut off mid-flight.
fn interop_transport() -> Arc<TransportConfig> {
    Arc::new(
        TransportConfig::default()
            .with_max_idle_timeout(IDLE_TIMEOUT.try_into().expect("a usable idle timeout")),
    )
}

#[must_use]
pub fn rama_server_config(identity: &Identity) -> ServerConfig {
    let tls = TlsServerConfig::new()
        .with_alpn(smallvec![alpn()])
        .with_server_auth(identity.clone())
        .verify_backend();
    let mut config = crate::backend::server_tls_provider()
        .server_config(&tls, crate::backend::options())
        .expect("the server config is built");
    config.set_transport_config(interop_transport());
    config
}

#[must_use]
pub fn rama_client_config(anchor: CertificateDer<'static>) -> ClientConfig {
    let tls = TlsClientConfig::new()
        .with_alpn(smallvec![alpn()])
        .with_store_server_cert_chain(true)
        .try_with_server_trust_anchors([anchor])
        .expect("the trust anchor is accepted")
        .verify_backend();
    let mut config = crate::backend::tls_provider()
        .client_config(&tls, crate::backend::options())
        .expect("the client config is built");
    config.set_transport_config(interop_transport());
    config
}

/// One identity of an issued pair: the material Rama's own side uses, and the same material on
/// disk for a peer that reads PEM files.
#[derive(Debug)]
pub struct IssuedIdentity {
    pub auth: Identity,
    pub certificate: PathBuf,
    pub key: PathBuf,
}

/// Two identities issued by one authority: one carrying the name, one carrying the loopback
/// address.
///
/// A case that swaps one for the other changes only what identity the certificate carries. The
/// issuer stays the same, so a client's trust configuration is untouched between the two and a
/// refusal cannot be the issuer check in disguise.
#[derive(Debug)]
pub struct IssuedIdentities {
    /// Held so the files live as long as the identities do.
    directory: TempDir,
    /// The authority both identities chain to, in PEM, for a peer that trusts a file.
    pub authority: PathBuf,
    /// The same anchor for a peer configured in memory.
    pub anchor: CertificateDer<'static>,
    pub for_name: IssuedIdentity,
    pub for_address: IssuedIdentity,
    /// A second name and a second address, for the same-type mismatches.
    pub for_another_name: IssuedIdentity,
    pub for_another_address: IssuedIdentity,
}

impl IssuedIdentities {
    /// Generate the authority and both identities.
    #[must_use]
    pub fn generate() -> Self {
        let directory =
            TempDir::with_prefix("rama-quic-interop-issued-").expect("a directory of our own");
        let authority =
            rama::crypto::cert::CertificateAuthorityData::generate(SelfSignedCaConfig {
                subject: CertificateSubject {
                    common_name: Some("rama quic interop issuer".into()),
                    ..Default::default()
                },
                ..Default::default()
            })
            .expect("the authority is generated");
        let authority_path = directory.path().join("issuer.pem");
        let anchor = authority.certificate_chain()[0].clone();
        fs::write(&authority_path, anchor.to_pem()).expect("the authority is written");
        let for_name = Self::issue(
            directory.path(),
            "name",
            CertificateIdentity::Dns(SERVER_NAME.parse().unwrap()),
            &authority,
        );
        let for_address = Self::issue(
            directory.path(),
            "address",
            CertificateIdentity::Ip(Ipv4Addr::LOCALHOST.into()),
            &authority,
        );
        let for_another_name = Self::issue(
            directory.path(),
            "another-name",
            CertificateIdentity::Dns(ANOTHER_NAME.parse().unwrap()),
            &authority,
        );
        let for_another_address = Self::issue(
            directory.path(),
            "another-address",
            CertificateIdentity::Ip(Ipv4Addr::new(127, 0, 0, 2).into()),
            &authority,
        );
        let issued = Self {
            directory,
            authority: authority_path,
            anchor,
            for_name,
            for_address,
            for_another_name,
            for_another_address,
        };
        for other in [
            &issued.for_address,
            &issued.for_another_name,
            &issued.for_another_address,
        ] {
            assert_eq!(
                anchor_of(&issued.for_name.auth),
                anchor_of(&other.auth),
                "every identity chains to the one authority"
            );
        }
        issued
    }

    /// One leaf under the authority, written out with its chain so a peer that reads the file
    /// serves the authority alongside the leaf.
    fn issue(
        directory: &Path,
        which: &str,
        identity: CertificateIdentity,
        issuer: &rama::crypto::cert::CertificateAuthorityData,
    ) -> IssuedIdentity {
        let (chain, key) = issuer
            .issue_leaf(LeafCertRequest::new(identity))
            .expect("the leaf is issued");
        let auth = Identity::new(chain, key);
        let certificate_path = directory.join(format!("{which}.pem"));
        let key_path = directory.join(format!("{which}-key.pem"));
        write_pem(&auth, &certificate_path, &key_path);
        IssuedIdentity {
            auth,
            certificate: certificate_path,
            key: key_path,
        }
    }

    /// The directory the files are in, for a peer that needs to name it.
    #[must_use]
    pub fn directory(&self) -> &Path {
        self.directory.path()
    }
}

/// A path as a peer's own API wants it.
#[must_use]
pub fn path_of(path: &Path) -> &str {
    path.to_str().expect("a printable path")
}

pub fn write_pem(identity: &Identity, certificate: &Path, key: &Path) {
    let certificates: String = identity.cert_chain.iter().map(PemEncode::to_pem).collect();
    fs::write(certificate, certificates).expect("the certificate chain is written");
    fs::write(key, identity.private_key.to_pem()).expect("the key is written");
}
