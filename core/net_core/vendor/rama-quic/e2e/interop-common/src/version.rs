//! The shared QUIC version cases (RFC 9368, RFC 9369): which version a connection ends up in
//! when the two ends start, offer and prefer different things.
//!
//! A case names what the peer speaks and what Rama's client offers or Rama's server prefers,
//! and the version both ends must settle on, per Rama role. The traffic afterwards is one of
//! the stream scenarios, so a connection that settled on the wrong version still has to carry
//! the right bytes.

use std::net::SocketAddr;

use rama::{extensions::ExtensionsRef as _, quic::NegotiatedTlsParameters};
use rama::{
    net::address::Domain,
    quic::{
        ClientConfig, ConfigError, Connection, Endpoint, EndpointConfig, ServerConfig,
        proto::version::{
            ClientVersionPolicy, ServerVersionPolicy, Version, VersionPolicyError,
            VersionPreference,
        },
    },
    utils::octets,
};

use crate::{
    identity::{anchor_of, rama_client_config, rama_server_config},
    registry::{Case, CaseRun},
    scenario::{Chunk, RamaClient, SERVER_NAME, StreamScenario, take_and_answer, upload_and_ask},
    support::{Peer, localhost},
};

/// How Rama's client starts and what it offers (RFC 9368 §3).
#[derive(Debug, Clone, Copy)]
pub struct ClientVersions {
    /// The version of the first flight.
    pub original: Version,
    /// The versions the first flight is compatible with, most preferred first.
    pub compatible: &'static [Version],
    /// The versions a restart after Version Negotiation may pick from, most preferred first.
    pub supported: &'static [Version],
}

/// What Rama's server accepts and prefers.
#[derive(Debug, Clone, Copy)]
pub struct ServerVersions {
    /// The versions the endpoint accepts and offers.
    pub acceptable: &'static [Version],
    /// The compatible versions it moves a connection to, most preferred first.
    pub prefer: Option<&'static [Version]>,
}

/// The version a connection ends in.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Outcome {
    /// Always this version.
    Always(Version),
    /// `switched` when Rama's TLS backend can change version during the handshake, `kept`
    /// when it cannot and therefore offered nothing to switch to.
    IfSwitchable { switched: Version, kept: Version },
}

impl Outcome {
    /// The version expected given whether a switch was possible.
    #[must_use]
    pub fn expected(self, switchable: bool) -> Version {
        match self {
            Self::Always(version) => version,
            Self::IfSwitchable { switched, kept } => {
                if switchable {
                    switched
                } else {
                    kept
                }
            }
        }
    }
}

#[derive(Debug, Clone)]
pub struct VersionScenario {
    /// The versions the peer speaks, most preferred first; also what it starts in as a client.
    pub peer_versions: &'static [Version],
    pub rama_client: ClientVersions,
    pub rama_server: ServerVersions,
    /// The version to end in with Rama as the client.
    pub as_client: Outcome,
    /// The version to end in with Rama as the server.
    pub as_server: Outcome,
    /// Whether the client's first flight is answered with Version Negotiation and started over.
    pub restarts: bool,
    pub traffic: StreamScenario,
}

const V1: Version = Version::V1;
const V2: Version = Version::V2;
const BOTH: &[Version] = &[V1, V2];
const V2_FIRST: &[Version] = &[V2, V1];
const ONLY_V2: &[Version] = &[V2];

fn traffic(seed: u8) -> StreamScenario {
    StreamScenario {
        up: Chunk {
            seed,
            len: octets::kib(8),
        },
        down: Chunk {
            seed: seed.wrapping_add(1),
            len: octets::kib(4),
        },
        question: Chunk {
            seed: seed.wrapping_add(2),
            len: octets::kib(2),
        },
        answer: Chunk {
            seed: seed.wrapping_add(3),
            len: octets::kib(3),
        },
    }
}

/// Every version case each eligible peer runs, in both roles.
#[must_use]
pub fn version_cases() -> Vec<Case<VersionScenario>> {
    vec![
        // A first flight in v2 against a peer that speaks it.
        Case {
            name: "version-v2-first-flight",
            scenario: VersionScenario {
                peer_versions: V2_FIRST,
                rama_client: ClientVersions {
                    original: V2,
                    compatible: ONLY_V2,
                    supported: V2_FIRST,
                },
                rama_server: ServerVersions {
                    acceptable: BOTH,
                    prefer: None,
                },
                as_client: Outcome::Always(V2),
                as_server: Outcome::Always(V2),
                restarts: false,
                traffic: traffic(0x60),
            },
        },
        // v1 first flights offering v2, with nobody preferring to move: v1 stays.
        Case {
            name: "version-v1-kept",
            scenario: VersionScenario {
                peer_versions: BOTH,
                rama_client: ClientVersions {
                    original: V1,
                    compatible: BOTH,
                    supported: BOTH,
                },
                rama_server: ServerVersions {
                    acceptable: BOTH,
                    prefer: None,
                },
                as_client: Outcome::Always(V1),
                as_server: Outcome::Always(V1),
                restarts: false,
                traffic: traffic(0x70),
            },
        },
        // RFC 9368 §2.3: a v1 first flight preferring v2, moved to v2 by the server.
        Case {
            name: "version-compatible-upgrade",
            scenario: VersionScenario {
                peer_versions: BOTH,
                rama_client: ClientVersions {
                    original: V1,
                    compatible: V2_FIRST,
                    supported: BOTH,
                },
                rama_server: ServerVersions {
                    acceptable: BOTH,
                    prefer: Some(ONLY_V2),
                },
                as_client: Outcome::IfSwitchable {
                    switched: V2,
                    kept: V1,
                },
                as_server: Outcome::Always(V2),
                restarts: false,
                traffic: traffic(0x80),
            },
        },
        // RFC 9368 §2.1: a v1 first flight to a v2-only server, started over in v2.
        Case {
            name: "version-incompatible-restart",
            scenario: VersionScenario {
                peer_versions: ONLY_V2,
                rama_client: ClientVersions {
                    original: V1,
                    compatible: &[V1],
                    supported: BOTH,
                },
                rama_server: ServerVersions {
                    acceptable: ONLY_V2,
                    prefer: None,
                },
                as_client: Outcome::Always(V2),
                as_server: Outcome::Always(V2),
                restarts: true,
                traffic: traffic(0x90),
            },
        },
    ]
}

/// Rama's client configuration for a case, or the reason this backend cannot run it.
pub fn rama_client_config_for(
    run: &CaseRun<VersionScenario>,
) -> Result<(ClientConfig, bool), &'static str> {
    let versions = &run.scenario.rama_client;
    let policy = ClientVersionPolicy::new(versions.original)
        .expect("a usable original version")
        .try_with_compatible(versions.compatible.to_vec())
        .expect("a usable compatible list")
        .try_with_supported(versions.supported.to_vec())
        .expect("a usable supported list");
    let switchable = policy.needs_switch();
    let mut config = rama_client_config(anchor_of(&run.identity));
    match config.set_versions(policy) {
        Ok(_) => Ok((config, switchable)),
        Err(ConfigError::VersionPolicy(VersionPolicyError::SwitchUnsupported)) => Err(
            "this TLS backend cannot change QUIC version during the handshake, so the client offers nothing to move to",
        ),
        Err(error) => panic!("{}: the version policy is refused: {error}", run.what),
    }
}

fn endpoint_config(acceptable: &[Version]) -> EndpointConfig {
    EndpointConfig::new(rama::crypto::hmac::HmacSha2::try_rand_256().expect("a random reset key"))
        .with_supported_versions(acceptable.to_vec())
}

/// Rama's server configuration for a case.
#[must_use]
pub fn rama_server_config_for(run: &CaseRun<VersionScenario>) -> ServerConfig {
    let versions = &run.scenario.rama_server;
    let mut policy = ServerVersionPolicy::new();
    if let Some(prefer) = versions.prefer {
        policy = policy
            .try_with_preference(VersionPreference::Prefer(prefer.to_vec()))
            .expect("a usable preference");
    }
    rama_server_config(&run.identity).with_versions(policy)
}

/// Rama as the client: connect with the case's policy, check the version it settled on, then
/// run the case's traffic. `None` when this backend cannot offer what the case asks for.
pub async fn rama_client_side(
    run: &CaseRun<VersionScenario>,
    peer_addr: SocketAddr,
) -> Result<RamaClient, &'static str> {
    let (config, switchable) = rama_client_config_for(run)?;
    let expected = run.scenario.as_client.expected(switchable);
    let CaseRun { what, deadline, .. } = run;
    let endpoint = deadline
        .wait(
            what,
            Endpoint::build(rama::rt::Executor::new())
                .with_config(endpoint_config(BOTH))
                .bind_address(localhost()),
        )
        .await
        .expect("the rama client binds");
    let connection = deadline
        .wait(
            what,
            endpoint
                .connect_with(config, peer_addr, SERVER_NAME)
                .expect("the attempt starts"),
        )
        .await
        .expect("the handshake completes");
    assert_eq!(
        connection.version(),
        expected,
        "{what}: the version the connection settled on"
    );
    assert_eq!(
        endpoint.stats().outgoing_handshakes,
        if run.scenario.restarts { 2 } else { 1 },
        "{what}: one first flight, plus one restart when Version Negotiation was expected"
    );
    let traffic = run.with_scenario(run.scenario.traffic);
    upload_and_ask(&traffic, &connection).await;
    Ok(RamaClient {
        endpoint,
        connection,
    })
}

/// Rama as the server: accept with the case's acceptable versions and preference, check the
/// version, then answer the case's traffic and stay until the peer is done.
pub async fn rama_server_side(run: &CaseRun<VersionScenario>) -> (Endpoint, SocketAddr, Peer<()>) {
    let CaseRun { what, deadline, .. } = run;
    let expected = run.scenario.as_server.expected(true);
    let server = deadline
        .wait(
            what,
            Endpoint::build(rama::rt::Executor::new())
                .with_config(endpoint_config(run.scenario.rama_server.acceptable))
                .with_server_config(rama_server_config_for(run))
                .bind_address(localhost()),
        )
        .await
        .expect("the rama server binds");
    let addr = server.local_addr().expect("its address");
    let serving = Peer::spawn({
        let run = run.clone();
        let server = server.clone();
        async move {
            let attempt = run
                .deadline
                .wait(&run.what, server.accept())
                .await
                .expect("an attempt arrives");
            let conn: Connection = run
                .deadline
                .wait(&run.what, attempt)
                .await
                .expect("the handshake completes");
            assert_eq!(
                conn.version(),
                expected,
                "{}: the version the connection settled on",
                run.what
            );
            let settled = conn
                .extensions()
                .get_ref::<NegotiatedTlsParameters>()
                .cloned()
                .expect("the handshake settled something");
            assert_eq!(
                settled.server_name,
                Some(Domain::from_static(SERVER_NAME)),
                "{}: the name the client asked for",
                run.what
            );
            let traffic = run.with_scenario(run.scenario.traffic);
            take_and_answer(&traffic, &conn).await;
            run.deadline.wait(&run.what, conn.closed()).await;
        }
    });
    (server, addr, serving)
}

/// A wait on the deadline, for peers that report the version they settled on.
pub fn check_peer_version(what: &str, reported: &str, expected: Version) {
    let reported = reported.trim_start_matches("0x");
    let reported = u32::from_str_radix(reported, 16).unwrap_or_else(|_| {
        panic!("{what}: the peer reported a version that is not hex: {reported}")
    });
    assert_eq!(
        Version::from_u32(reported),
        expected,
        "{what}: the version the peer settled on"
    );
}
