//! The shared cases and the runner that executes them, so a case added here runs in every peer
//! project without any of them being edited.

use std::{fmt, future::Future, time::Duration};

use rama::utils::octets;

use crate::{
    identity::{Identity, server_identity},
    scenario::{Chunk, StreamScenario},
    support::{Deadline, SCENARIO_LIMIT},
};

/// Which end Rama is in a scenario.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Role {
    /// Rama opens the connection and the peer answers it.
    RamaClient,
    /// The peer opens the connection and Rama answers it.
    RamaServer,
}

impl Role {
    #[must_use]
    pub fn as_str(self) -> &'static str {
        match self {
            Self::RamaClient => "rama-client",
            Self::RamaServer => "rama-server",
        }
    }
}

impl fmt::Display for Role {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(self.as_str())
    }
}

/// One shared case: a name and the parameters that are the single source for every peer.
#[derive(Debug, Clone)]
pub struct Case<S> {
    pub name: &'static str,
    pub scenario: S,
}

/// Every stream case each eligible peer runs, in both roles. Adding one here runs it
/// everywhere.
#[must_use]
pub fn stream_cases() -> Vec<Case<StreamScenario>> {
    vec![
        Case {
            name: "stream-baseline",
            scenario: StreamScenario {
                up: Chunk {
                    seed: 0x11,
                    len: octets::kib(64),
                },
                down: Chunk {
                    seed: 0x91,
                    len: octets::kib(12),
                },
                question: Chunk {
                    seed: 0x22,
                    len: octets::kib(4),
                },
                answer: Chunk {
                    seed: 0x33,
                    len: octets::kib(8),
                },
            },
        },
        // Different lengths and seeds through the same code, so a peer that quietly kept its
        // own parameters carries the wrong bytes here.
        Case {
            name: "stream-compact",
            scenario: StreamScenario {
                up: Chunk {
                    seed: 0x44,
                    len: octets::kib(3),
                },
                down: Chunk {
                    seed: 0xa2,
                    len: 993,
                },
                question: Chunk {
                    seed: 0x55,
                    len: 777,
                },
                answer: Chunk {
                    seed: 0x66,
                    len: octets::kib(2) + 5,
                },
            },
        },
    ]
}

/// One case being run: its name for failures, its parameters, the identity in play and the
/// deadline every await under it shares.
#[derive(Debug, Clone)]
pub struct CaseRun<S> {
    pub what: String,
    pub scenario: S,
    pub identity: Identity,
    pub deadline: Deadline,
    pub role: Role,
}

impl<S> CaseRun<S> {
    /// The same case with an identity of the peer's own making, for a peer that needs one in a
    /// form only it can produce — files on disk, say. The payloads are unaffected: they come
    /// from the registry and nowhere else.
    /// The same case, its deadline and identity, around another scenario: how a case that
    /// settles something first hands its traffic to the shared stream helpers.
    #[must_use]
    pub fn with_scenario<T>(&self, scenario: T) -> CaseRun<T> {
        CaseRun {
            what: self.what.clone(),
            scenario,
            identity: self.identity.clone(),
            deadline: self.deadline,
            role: self.role,
        }
    }

    #[must_use]
    pub fn with_identity(self, identity: Identity) -> Self {
        Self { identity, ..self }
    }
}

/// Run `body` once for every shared case in `role`. The list a family names — [`stream_cases`],
/// [`crate::datagram::datagram_cases`], [`crate::trust::trust_cases`] — is the only one an
/// adapter iterates, so a case added there reaches every peer project without any of them
/// being edited.
///
/// The whole callback runs inside the case's deadline, not only the operations that take one:
/// binding a peer's socket and tearing its tasks down are part of a case's time too.
pub async fn for_each_case<S, F, Fut>(peer: &'static str, role: Role, cases: Vec<Case<S>>, body: F)
where
    F: FnMut(CaseRun<S>) -> Fut,
    Fut: Future<Output = ()>,
{
    for_each_case_within(peer, role, cases, SCENARIO_LIMIT, body).await;
}

/// The same, with a limit of the peer's own. A peer whose side is another process needs longer
/// than one in this one: starting an interpreter is part of its case's time, and several test
/// binaries run at once.
pub async fn for_each_case_within<S, F, Fut>(
    peer: &'static str,
    role: Role,
    cases: Vec<Case<S>>,
    limit: Duration,
    mut body: F,
) where
    F: FnMut(CaseRun<S>) -> Fut,
    Fut: Future<Output = ()>,
{
    assert!(!cases.is_empty(), "the registry names at least one case");
    for case in cases {
        let run = CaseRun {
            what: format!("{peer}/{}/{role}", case.name),
            scenario: case.scenario,
            identity: server_identity(),
            deadline: Deadline::of(limit),
            role,
        };
        let deadline = run.deadline;
        let what = run.what.clone();
        println!("running {what}");
        deadline.wait(&what, body(run)).await;
    }
}

/// Why a peer does not run a case. Reported alongside the passes, never in place of one.
#[derive(Debug, Clone)]
pub struct Unsupported {
    pub case: &'static str,
    pub peer: &'static str,
    pub reason: &'static str,
}

impl fmt::Display for Unsupported {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(
            f,
            "{} does not run {}: {}",
            self.peer, self.case, self.reason
        )
    }
}
