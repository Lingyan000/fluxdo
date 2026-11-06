use std::{convert::Infallible, sync::OnceLock};

use rama_crypto::dep::boring::{
    asn1::Asn1Time,
    bn::BigNum,
    ec::{EcGroup, EcKey},
    hash::MessageDigest,
    nid::Nid,
    pkey::Private,
    sign::Signer,
    ssl::{PrivateKeyMethod, PrivateKeyMethodError, SslSignatureAlgorithm, SslVerifyMode},
    stack::Stack,
    x509::{
        X509Name,
        extension::{BasicConstraints, SubjectAlternativeName},
        store::{X509Store, X509StoreBuilder},
    },
};
use rama_quic_proto::Version as QuicVersion;
use rama_tls::server::TlsServerConfig;

use super::*;

const VERSIONS: [QuicVersion; 2] = [QuicVersion::V1, QuicVersion::V2];

struct Identity {
    cert: X509,
    key: PKey<Private>,
}

impl Identity {
    fn new(name: &str, issuer: Option<&Self>) -> Self {
        let key = PKey::from_ec_key(
            EcKey::generate(&EcGroup::from_curve_name(Nid::X9_62_PRIME256V1).unwrap()).unwrap(),
        )
        .unwrap();
        let mut subject = X509Name::builder().unwrap();
        subject.append_entry_by_text("CN", name).unwrap();
        let subject = subject.build();
        let mut cert = X509::builder().unwrap();
        cert.set_version(2).unwrap();
        cert.set_serial_number(&BigNum::from_u32(1).unwrap().to_asn1_integer().unwrap())
            .unwrap();
        cert.set_subject_name(&subject).unwrap();
        cert.set_issuer_name(issuer.map_or(&*subject, |i| i.cert.subject_name()))
            .unwrap();
        cert.set_pubkey(&key).unwrap();
        cert.set_not_before(&Asn1Time::days_from_now(0).unwrap())
            .unwrap();
        cert.set_not_after(&Asn1Time::days_from_now(2).unwrap())
            .unwrap();
        let mut constraints = BasicConstraints::new();
        constraints.critical();
        if issuer.is_none() {
            constraints.ca();
        }
        cert.append_extension(&constraints.build().unwrap())
            .unwrap();
        cert.append_extension(
            &SubjectAlternativeName::new()
                .dns("localhost")
                .build(&cert.x509v3_context(issuer.map(|i| &*i.cert), None))
                .unwrap(),
        )
        .unwrap();
        cert.sign(issuer.map_or(&key, |i| &i.key), MessageDigest::sha256())
            .unwrap();
        Self {
            cert: cert.build(),
            key,
        }
    }

    fn credential(&self) -> SslCredential {
        let mut credential = SslCredential::builder().unwrap();
        credential.set_certificate_chain([&self.cert]).unwrap();
        credential.set_private_key(&self.key).unwrap();
        credential.build()
    }

    fn der(&self) -> Vec<u8> {
        self.cert.to_der().unwrap()
    }
}

struct Material {
    ca: Identity,
    guest: Identity,
    mapped: Identity,
    stranger: Identity,
}

fn material() -> &'static Material {
    static MATERIAL: OnceLock<Material> = OnceLock::new();
    MATERIAL.get_or_init(|| {
        let ca = Identity::new("CA", None);
        let other_ca = Identity::new("other CA", None);
        Material {
            guest: Identity::new("guest", Some(&ca)),
            mapped: Identity::new("mapped", Some(&ca)),
            stranger: Identity::new("stranger", Some(&other_ca)),
            ca,
        }
    })
}

fn store(cert: &X509) -> X509Store {
    let mut store = X509StoreBuilder::new().unwrap();
    store.add_cert(cert.clone()).unwrap();
    store.build()
}

fn required() -> SslVerifyMode {
    SslVerifyMode::PEER | SslVerifyMode::FAIL_IF_NO_PEER_CERT
}

/// Presents `material().guest`'s certificate, but signs with another key.
struct WrongSigner;

impl PrivateKeyMethod for WrongSigner {
    fn sign(
        &self,
        _: &mut SslRef,
        input: &[u8],
        _: SslSignatureAlgorithm,
        output: &mut [u8],
    ) -> Result<usize, PrivateKeyMethodError> {
        let mut signer = Signer::new(MessageDigest::sha256(), &material().mapped.key)
            .map_err(|_error| PrivateKeyMethodError::FAILURE)?;
        signer
            .update(input)
            .map_err(|_error| PrivateKeyMethodError::FAILURE)?;
        signer
            .sign(output)
            .map_err(|_error| PrivateKeyMethodError::FAILURE)
    }

    fn decrypt(
        &self,
        _: &mut SslRef,
        _: &[u8],
        _: &mut [u8],
    ) -> Result<usize, PrivateKeyMethodError> {
        Err(PrivateKeyMethodError::FAILURE)
    }

    fn complete(&self, _: &mut SslRef, _: &mut [u8]) -> Result<usize, PrivateKeyMethodError> {
        Err(PrivateKeyMethodError::FAILURE)
    }
}

fn impostor() -> SslCredential {
    let mut credential = SslCredential::builder().unwrap();
    credential
        .set_certificate_chain([&material().guest.cert])
        .unwrap();
    credential.set_private_key_method(WrongSigner).unwrap();
    credential.build()
}

#[derive(Default)]
struct Case {
    policy: Option<TlsMitmClientAuthPolicy>,
    flow_policy: Option<TlsMitmClientAuthPolicy>,
    /// How the origin requests a client certificate; `None` requests none.
    origin_verify: Option<SslVerifyMode>,
    client: Option<SslCredential>,
    handshake_timeout: Option<Duration>,
    shared_egress_sessions: bool,
}

struct Outcome {
    relay: Result<(), BoxError>,
    origin: OriginOutcome,
}

#[derive(Debug, PartialEq, Eq)]
enum OriginOutcome {
    /// With the client certificate it authenticated, if any.
    Established(Option<Vec<u8>>),
    /// Its handshake failed.
    Failed,
    /// No attempt reached it.
    Unreached,
    /// An attempt reached it, but neither completed nor failed.
    Stalled,
}

async fn run(version: QuicVersion, port: u16, case: Case) -> Outcome {
    let mitm_identity = identity();
    let origin_identity = untrusted_identity();
    let address = |offset: u16| SocketAddr::from(([127, 0, 0, 1], port + offset));
    let capacity = NonZeroUsize::new(64).unwrap();
    let (client_socket, ingress) = MemoryDatagramSocket::pair(address(0), address(1), capacity);
    let (egress, origin_socket) = MemoryDatagramSocket::pair(address(2), address(3), capacity);

    let origin_tls = TlsServerConfig::new()
        .with_alpn([ALPN.into()].into_iter().collect())
        .with_server_auth(origin_identity.clone())
        .with_store_client_cert_chain(true);
    if let Some(mode) = case.origin_verify {
        origin_tls.insert(HandshakeInitializer(Arc::new(move |ssl: &mut SslRef| {
            ssl.set_verify_cert_store(store(&material().ca.cert))?;
            let mut names = Stack::new()?;
            names.push(X509Name::from_der(
                &material().ca.cert.subject_name().to_der()?,
            )?)?;
            ssl.set_client_ca_list(names);
            ssl.set_verify(mode);
            Ok(())
        })));
    }
    let origin = Endpoint::build(Executor::new())
        .with_server_config(
            ServerConfig::try_from_rama_tls_with_provider(
                &origin_tls,
                TlsOptions::default(),
                &BoringTlsProvider,
            )
            .unwrap(),
        )
        .with_datagram_socket(origin_socket)
        .unwrap();
    let origin_task = tokio::spawn(async move {
        let Some(incoming) = origin.accept().await else {
            return (OriginOutcome::Unreached, None);
        };
        match incoming.await {
            Ok(connection) => {
                let leaf = connection
                    .extensions()
                    .get_ref::<NegotiatedTlsParameters>()
                    .and_then(|tls| tls.peer_certificate_chain.as_deref())
                    .and_then(|chain| chain.first())
                    .map(|leaf| leaf.as_ref().to_vec());
                (OriginOutcome::Established(leaf), Some((connection, origin)))
            }
            Err(_error) => (OriginOutcome::Failed, None),
        }
    });

    if let Some(policy) = case.flow_policy {
        ingress.extensions().insert(policy);
    }
    let mut egress_tls = trusting(&origin_identity);
    if case.shared_egress_sessions {
        egress_tls.set_overrides(&crate::proto::crypto::boring::SharedClientSessions::defaults());
    }
    let mut mitm = QuicMitmRelay::new(
        issuer(&mitm_identity),
        Executor::new(),
        egress_tls,
        VarInt::from_u32(0x0101),
    )
    .maybe_with_client_auth(case.policy);
    if let Some(budget) = case.handshake_timeout {
        mitm.set_handshake_timeout(budget);
    }
    let service = PeekQuicClientHelloService::new(
        BoringTlsProvider,
        mitm.into_layer(service_fn(
            async |BridgeIo(ingress, egress): BridgeIo<Connection, Connection>| {
                // The origin completes its handshake only with the client's last flight.
                egress.handshake_confirmed().await?;
                ingress.close(VarInt::from_u32(0), b"checked");
                egress.close(VarInt::from_u32(0), b"checked");
                Ok::<_, BoxError>(())
            },
        )),
    );
    let relaying = tokio::spawn(async move { service.serve(BridgeIo(ingress, egress)).await });

    let client_tls = trusting(&mitm_identity);
    if let Some(credential) = case.client {
        client_tls.insert(HandshakeInitializer(Arc::new(move |ssl: &mut SslRef| {
            Ok(ssl.add_credential(&credential)?)
        })));
    }
    let mut config = ClientConfig::try_from_rama_tls_with_provider(
        &client_tls,
        TlsOptions::default(),
        &BoringTlsProvider,
    )
    .unwrap();
    config.set_version(version).unwrap();
    let client = Endpoint::build(Executor::new())
        .with_datagram_socket(client_socket)
        .unwrap();
    let _connecting = client
        .connect_with(config, address(1), "localhost")
        .unwrap();

    let relay = relaying.await.unwrap();
    let origin = match timeout(Duration::from_secs(2), origin_task).await {
        Ok(joined) => joined.unwrap().0,
        Err(_elapsed) => OriginOutcome::Stalled,
    };
    Outcome { relay, origin }
}

/// A plan trusting the test CA at ingress, mapping `guest` to the `mapped` credential.
fn mapped_policy(resolved: Arc<AtomicUsize>) -> TlsMitmClientAuthPolicy {
    TlsMitmClientAuthPolicy::new(service_fn(move |input: TlsMitmClientAuthInput| {
        let resolved = resolved.clone();
        async move {
            let request = input
                .request
                .ok_or_else(|| BoxError::from_static_str("no origin request"))?;
            if request.signature_algorithms.is_empty() || request.certificate_authorities.is_empty()
            {
                return Err(BoxError::from_static_str(
                    "missing CertificateRequest metadata",
                ));
            }
            assert_eq!(
                input.server_name,
                Some(Host::Name("localhost".parse().unwrap()))
            );
            Ok(
                TlsMitmClientAuthPlan::new(service_fn(move |identity: TlsMitmClientIdentity| {
                    resolved.fetch_add(1, Ordering::Relaxed);
                    async move {
                        if identity.leaf().map(|leaf| leaf.to_der().unwrap())
                            != Some(material().guest.der())
                        {
                            return Err(BoxError::from_static_str("unmapped ingress identity"));
                        }
                        Ok(Some(material().mapped.credential()))
                    }
                }))
                .with_ingress_trust(store(&material().ca.cert)),
            )
        }
    }))
}

#[tokio::test]
async fn an_origin_certificate_request_fails_without_a_policy() {
    timeout(LIMIT, async {
        for version in VERSIONS {
            for verify in [required(), SslVerifyMode::PEER] {
                let outcome = run(
                    version,
                    24700,
                    Case {
                        origin_verify: Some(verify),
                        client: Some(material().guest.credential()),
                        ..Default::default()
                    },
                )
                .await;
                outcome.relay.unwrap_err();
                assert_eq!(
                    outcome.origin,
                    OriginOutcome::Failed,
                    "{version:?} {verify:?}"
                );
            }
        }
    })
    .await
    .unwrap();
}

#[tokio::test]
async fn a_fixed_credential_answers_the_origin_without_ingress_authentication() {
    timeout(LIMIT, async {
        for version in VERSIONS {
            let outcome = run(
                version,
                24710,
                Case {
                    policy: Some(TlsMitmClientAuthPolicy::fixed(
                        material().mapped.credential(),
                    )),
                    origin_verify: Some(required()),
                    ..Default::default()
                },
            )
            .await;
            outcome.relay.unwrap();
            assert_eq!(
                outcome.origin,
                OriginOutcome::Established(Some(material().mapped.der()))
            );
        }
    })
    .await
    .unwrap();
}

#[tokio::test]
async fn ingress_authentication_runs_without_an_origin_request() {
    timeout(LIMIT, async {
        for version in VERSIONS {
            for (client, admitted) in [
                (Some(material().guest.credential()), true),
                (Some(material().stranger.credential()), false),
                (None, false),
            ] {
                let seen = Arc::new(Mutex::new(Vec::new()));
                let record = seen.clone();
                let policy = TlsMitmClientAuthPolicy::new(service_fn(
                    move |input: TlsMitmClientAuthInput| {
                        let record = record.clone();
                        async move {
                            assert!(input.request.is_none());
                            Ok::<_, Infallible>(
                                TlsMitmClientAuthPlan::new(service_fn(
                                    move |identity: TlsMitmClientIdentity| {
                                        record.lock().push(
                                            identity.leaf().map(|leaf| leaf.to_der().unwrap()),
                                        );
                                        async { Ok::<_, Infallible>(None) }
                                    },
                                ))
                                .with_ingress_trust(store(&material().ca.cert)),
                            )
                        }
                    },
                ));
                let outcome = run(
                    version,
                    24720,
                    Case {
                        policy: Some(policy),
                        client,
                        ..Default::default()
                    },
                )
                .await;
                assert_eq!(outcome.relay.is_ok(), admitted, "{:?}", outcome.relay);
                let expected = if admitted {
                    vec![Some(material().guest.der())]
                } else {
                    Vec::new()
                };
                assert_eq!(*seen.lock(), expected);
                // The origin requested nothing, so it got nothing either way.
                assert_eq!(outcome.origin, OriginOutcome::Established(None));
            }
        }
    })
    .await
    .unwrap();
}

#[tokio::test]
async fn a_mapped_credential_is_released_only_for_a_trusted_matching_identity() {
    timeout(LIMIT, async {
        for version in VERSIONS {
            for (client, resolved_calls, released) in [
                (Some(material().guest.credential()), 1, true),
                // Trusted, but not mapped: the resolver refuses it.
                (Some(material().mapped.credential()), 1, false),
                (Some(material().stranger.credential()), 0, false),
                (None, 0, false),
            ] {
                let resolved = Arc::new(AtomicUsize::new(0));
                let outcome = run(
                    version,
                    24730,
                    Case {
                        policy: Some(mapped_policy(resolved.clone())),
                        origin_verify: Some(required()),
                        client,
                        ..Default::default()
                    },
                )
                .await;
                assert_eq!(outcome.relay.is_ok(), released, "{:?}", outcome.relay);
                assert_eq!(resolved.load(Ordering::Relaxed), resolved_calls);
                let expected = if released {
                    OriginOutcome::Established(Some(material().mapped.der()))
                } else {
                    OriginOutcome::Failed
                };
                assert_eq!(outcome.origin, expected);
            }
        }
    })
    .await
    .unwrap();
}

#[tokio::test]
async fn an_impostor_with_a_trusted_certificate_gets_no_origin_credential() {
    timeout(LIMIT, async {
        for version in VERSIONS {
            let resolved = Arc::new(AtomicUsize::new(0));
            let outcome = run(
                version,
                24740,
                Case {
                    policy: Some(mapped_policy(resolved.clone())),
                    origin_verify: Some(required()),
                    client: Some(impostor()),
                    ..Default::default()
                },
            )
            .await;
            outcome.relay.unwrap_err();
            assert_eq!(resolved.load(Ordering::Relaxed), 0);
            assert_eq!(outcome.origin, OriginOutcome::Failed);
        }
    })
    .await
    .unwrap();
}

#[tokio::test]
async fn a_credential_without_an_origin_request_is_a_policy_error() {
    timeout(LIMIT, async {
        for version in VERSIONS {
            let policy = TlsMitmClientAuthPolicy::new(service_fn(|_: TlsMitmClientAuthInput| {
                std::future::ready(Ok::<_, Infallible>(TlsMitmClientAuthPlan::fixed(Some(
                    material().mapped.credential(),
                ))))
            }));
            let outcome = run(
                version,
                24750,
                Case {
                    policy: Some(policy),
                    ..Default::default()
                },
            )
            .await;
            let error = outcome.relay.unwrap_err();
            assert!(
                error.to_string().contains("without an origin request"),
                "{error}"
            );
        }
    })
    .await
    .unwrap();
}

#[tokio::test]
async fn a_flow_policy_overrides_the_relays() {
    timeout(LIMIT, async {
        for version in VERSIONS {
            let refusing = TlsMitmClientAuthPolicy::new(service_fn(|_: TlsMitmClientAuthInput| {
                std::future::ready(Err::<TlsMitmClientAuthPlan, _>(BoxError::from_static_str(
                    "relay policy",
                )))
            }));
            let outcome = run(
                version,
                24760,
                Case {
                    policy: Some(refusing),
                    flow_policy: Some(TlsMitmClientAuthPolicy::fixed(
                        material().mapped.credential(),
                    )),
                    origin_verify: Some(required()),
                    ..Default::default()
                },
            )
            .await;
            outcome.relay.unwrap();
            assert_eq!(
                outcome.origin,
                OriginOutcome::Established(Some(material().mapped.der()))
            );
        }
    })
    .await
    .unwrap();
}

#[tokio::test]
async fn shared_egress_sessions_are_refused_under_a_policy() {
    timeout(LIMIT, async {
        for version in VERSIONS {
            let outcome = run(
                version,
                24770,
                Case {
                    policy: Some(TlsMitmClientAuthPolicy::fixed(
                        material().mapped.credential(),
                    )),
                    origin_verify: Some(required()),
                    shared_egress_sessions: true,
                    ..Default::default()
                },
            )
            .await;
            outcome.relay.unwrap_err();
            assert_eq!(outcome.origin, OriginOutcome::Unreached);
        }
    })
    .await
    .unwrap();
}

struct DropProbe(Arc<AtomicUsize>);

impl Drop for DropProbe {
    fn drop(&mut self) {
        self.0.fetch_add(1, Ordering::Relaxed);
    }
}

#[tokio::test]
async fn the_deadline_cancels_every_policy_wait_and_releases_nothing() {
    timeout(LIMIT, async {
        for version in VERSIONS {
            for resolve_stage in [false, true] {
                let started = Arc::new(AtomicUsize::new(0));
                let dropped = Arc::new(AtomicUsize::new(0));
                let (start, drop) = (started.clone(), dropped.clone());
                let policy =
                    TlsMitmClientAuthPolicy::new(service_fn(move |_: TlsMitmClientAuthInput| {
                        let (start, drop) = (start.clone(), drop.clone());
                        async move {
                            if !resolve_stage {
                                let _probe = DropProbe(drop.clone());
                                start.fetch_add(1, Ordering::Relaxed);
                                std::future::pending::<()>().await;
                            }
                            Ok::<_, Infallible>(TlsMitmClientAuthPlan::new(service_fn(
                                move |_: TlsMitmClientIdentity| {
                                    let (start, drop) = (start.clone(), drop.clone());
                                    async move {
                                        let _probe = DropProbe(drop);
                                        start.fetch_add(1, Ordering::Relaxed);
                                        std::future::pending::<
                                            Result<Option<SslCredential>, Infallible>,
                                        >()
                                        .await
                                    }
                                },
                            )))
                        }
                    }));
                let outcome = run(
                    version,
                    24780,
                    Case {
                        policy: Some(policy),
                        origin_verify: Some(required()),
                        handshake_timeout: Some(Duration::from_millis(300)),
                        ..Default::default()
                    },
                )
                .await;
                let error = outcome.relay.unwrap_err();
                assert!(error.to_string().contains("deadline"), "{error}");
                assert_eq!(started.load(Ordering::Relaxed), 1);
                assert_eq!(dropped.load(Ordering::Relaxed), 1);
                assert_eq!(outcome.origin, OriginOutcome::Failed);
            }
        }
    })
    .await
    .unwrap();
}
