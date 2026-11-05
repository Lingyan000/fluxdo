//! The interoperability scenarios each peer project runs, and the whole Rama side of them.
//!
//! A peer project depends on this by path, brings its own third-party QUIC implementation, and
//! writes an adapter that runs that implementation against the same parameters. What a scenario
//! asserts lives here, so every peer is held to the same expectations; what the peer read comes
//! back through its adapter.

#[cfg(any(
    all(feature = "rustls-ring", feature = "rustls-aws-lc"),
    all(
        feature = "boring",
        any(feature = "rustls-ring", feature = "rustls-aws-lc")
    )
))]
compile_error!("select exactly one Rama TLS backend: boring, rustls-ring or rustls-aws-lc");
#[cfg(not(any(feature = "boring", feature = "rustls-ring", feature = "rustls-aws-lc")))]
compile_error!("select a Rama TLS backend: boring, rustls-ring or rustls-aws-lc");

pub mod backend;
pub mod backpressure;
pub mod close;
pub mod datagram;
pub mod identity;
pub mod keys;
pub mod migration;
pub mod names;
pub mod registry;
pub mod resumption;
pub mod scenario;
pub mod serving;
pub mod support;
pub mod trust;
pub mod unsupported;
pub mod version;

pub use backpressure::{BackpressureScenario, Ears, Filled, Sent, backpressure_cases};
pub use close::{CloseObservation, CloseScenario, close_cases, told};
pub use datagram::{DatagramObservation, DatagramScenario, datagram_cases};
pub use identity::{
    ALPN, Identity, IssuedIdentities, IssuedIdentity, alpn, path_of, rama_client_config,
    rama_server_config, server_identity,
};
pub use keys::{Initiator, KeyObservation, KeyScenario, key_cases};
pub use migration::{MigrationObservation, MigrationScenario, RefusedMove, migration_cases};
pub use names::{
    MISMATCH_PROBE, Mismatch, NameObservation, NameScenario, ReceivedName, identity_alert,
    mismatch_cases, name_cases,
};
pub use registry::{
    Case, CaseRun, Role, Unsupported, for_each_case, for_each_case_within, stream_cases,
};
pub use resumption::{
    Arrival, Expected, Reported, ResumptionObservation, ResumptionScenario, ServerReport, Verdict,
    resumption_cases,
};
pub use scenario::{
    ANOTHER_ADDRESS, ANOTHER_NAME, Chunk, PeerObservation, Received, SERVER_NAME, StreamScenario,
};
pub use serving::{ServerOutcome, expect_outcome, rama_probe_server};
pub use support::{Deadline, Peer, digest, localhost, payload};
pub use trust::{TrustObservation, TrustScenario, trust_cases};
pub use unsupported::{UnsupportedObservation, UnsupportedScenario, unsupported_cases};
pub use version::{ClientVersions, Outcome, ServerVersions, VersionScenario, version_cases};

#[cfg(any(not(feature = "boring"), feature = "peer-rustls"))]
pub use resumption::RecordingSessions;
