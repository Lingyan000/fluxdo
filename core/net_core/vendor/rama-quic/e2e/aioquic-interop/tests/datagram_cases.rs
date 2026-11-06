//! The shared DATAGRAM cases, run against aioquic in both roles.
//!
//! The child takes each datagram as the two numbers it follows from, so its payloads come from
//! the same case the Rama side is given, and it reports what it received for itself.
//!
//! The frame the child advertises is small enough that it, and not the path, is what bounds a
//! datagram here. Against quiche it is the path that binds, so the two projects cover the two
//! halves of the same limit.

mod common;

use common::*;
use interop_common::{
    DatagramObservation, DatagramScenario, Deadline, Ears, Role, UnsupportedObservation,
    backpressure::{
        bind_backpressure_server, rama_client_fills_and_cancels, rama_server_fills_and_cancels,
    },
    backpressure_cases,
    datagram::{rama_client_side, rama_server_side},
    datagram_cases, for_each_case_within,
    scenario::SERVER_NAME,
    unsupported::{rama_client_without_datagrams, rama_server_without_datagrams},
    unsupported_cases,
};

const PEER: &str = "aioquic";
/// The frame size the child advertises: large enough for either case's datagrams, small enough
/// that it, and not the path, is what limits them.
const FRAME: usize = 256;

/// This case's datagrams as the child takes them.
fn datagram_arguments(scenario: &DatagramScenario) -> Vec<String> {
    [
        ("--datagram-frame", FRAME),
        ("--datagram-out-seed", usize::from(scenario.out.seed)),
        ("--datagram-out-length", scenario.out.len),
        ("--datagram-answer-seed", usize::from(scenario.back.seed)),
        ("--datagram-answer-length", scenario.back.len),
    ]
    .into_iter()
    .flat_map(|(name, value)| [name.to_owned(), value.to_string()])
    .collect()
}

/// Rama opens the connection and aioquic answers it, for every registered datagram case.
#[tokio::test]
async fn datagram_cases_rama_client() {
    prepare().await;
    for_each_case_within(
        PEER,
        Role::RamaClient,
        datagram_cases(),
        LIMIT,
        |run| async move {
            let identity = Identity::generate(SERVER_NAME);
            let run = run.with_identity(identity.auth.clone());
            let mut arguments = vec![
                "--cert".to_owned(),
                identity.certificate().to_owned(),
                "--key".to_owned(),
                identity.key().to_owned(),
            ];
            arguments.extend(datagram_arguments(&run.scenario));
            let borrowed: Vec<&str> = arguments.iter().map(String::as_str).collect();
            let mut peer = AioQuic::spawn("server", &borrowed).await;
            let addr = peer.listening(run.deadline).await;

            let rama = rama_client_side(&run, addr).await;
            peer.expect("handshake", run.deadline).await;
            let reported = peer.expect("datagram", run.deadline).await;
            let (limit, sent) = (rama.limit, rama.sent);
            rama.close(&run.what, run.deadline).await;
            peer.expect("ended", run.deadline).await;
            let observed = observation(&reported);
            peer.finished(run.deadline).await;
            observed.check(&run.what, &run.scenario, run.role, sent);
            observed.bounds(&run.what, limit);
        },
    )
    .await;
}

/// aioquic opens the connection and Rama answers it, for every registered datagram case.
#[tokio::test]
async fn datagram_cases_rama_server() {
    prepare().await;
    for_each_case_within(
        PEER,
        Role::RamaServer,
        datagram_cases(),
        LIMIT,
        |run| async move {
            let identity = Identity::generate(SERVER_NAME);
            let run = run.with_identity(identity.auth.clone());
            let (endpoint, addr, serving) = rama_server_side(&run).await;

            let mut arguments = vec![
                "--ca".to_owned(),
                identity.certificate().to_owned(),
                "--port".to_owned(),
                addr.port().to_string(),
                "--streams".to_owned(),
                "0".to_owned(),
                "--datagrams".to_owned(),
                "1".to_owned(),
            ];
            arguments.extend(datagram_arguments(&run.scenario));
            let borrowed: Vec<&str> = arguments.iter().map(String::as_str).collect();
            let mut peer = AioQuic::spawn("client", &borrowed).await;

            peer.expect("handshake", run.deadline).await;
            peer.expect("connected", run.deadline).await;
            let reported = peer.expect("datagram", run.deadline).await;
            peer.expect("ended", run.deadline).await;
            let observed = observation(&reported);
            peer.finished(run.deadline).await;

            let (limit, sent) = serving.join(&run.what, run.deadline).await;
            observed.check(&run.what, &run.scenario, run.role, sent);
            observed.bounds(&run.what, limit);
            run.deadline.wait(&run.what, endpoint.wait_idle()).await;
        },
    )
    .await;
}

/// What the child said about the datagram it received.
///
/// The child reports no send limit of its own: `--datagram-frame` is what this side told it to
/// advertise, an input rather than an observation, and aioquic exposes no usable send-payload
/// size through the event bridge. So `sendable` is left unset and the shared check makes no
/// claim about it; that it did send the answering datagram is shown by the delivery itself.
fn observation(event: &Event) -> DatagramObservation {
    DatagramObservation {
        sendable: None,
        // What this side told the child to advertise with `--datagram-frame`.
        advertised: Some(FRAME),
        received: Some(event.reported()),
    }
}

/// What the child is told for a case where it must not offer the extension: a frame size of
/// zero, which is how it is asked for no `max_datagram_frame_size` at all.
const NO_FRAME: &str = "0";

/// Rama opens the connection and an aioquic that offers no datagram size answers it.
#[tokio::test]
async fn unsupported_cases_rama_client() {
    prepare().await;
    for_each_case_within(
        PEER,
        Role::RamaClient,
        unsupported_cases(),
        LIMIT,
        |run| async move {
            let identity = Identity::generate(SERVER_NAME);
            let run = run.with_identity(identity.auth.clone());
            let mut peer = AioQuic::spawn(
                "server",
                &[
                    "--cert",
                    identity.certificate(),
                    "--key",
                    identity.key(),
                    "--datagram-frame",
                    NO_FRAME,
                ],
            )
            .await;
            let addr = peer.listening(run.deadline).await;

            let rama = rama_client_without_datagrams(&run, addr).await;
            peer.expect("handshake", run.deadline).await;
            let carried = peer.expect("stream", run.deadline).await;
            rama.close(&run.what, run.deadline).await;
            // Nothing between the exchange and the end: a datagram the child was sent would
            // be an event of its own here, and this would report it instead.
            peer.expect("ended", run.deadline).await;
            peer.finished(run.deadline).await;
            observed_without_datagrams(&carried).check(&run.what, &run.scenario);
        },
    )
    .await;
}

/// An aioquic that offers no datagram size opens the connection and Rama answers it.
#[tokio::test]
async fn unsupported_cases_rama_server() {
    prepare().await;
    for_each_case_within(
        PEER,
        Role::RamaServer,
        unsupported_cases(),
        LIMIT,
        |run| async move {
            let identity = Identity::generate(SERVER_NAME);
            let run = run.with_identity(identity.auth.clone());
            let (endpoint, addr, serving) = rama_server_without_datagrams(&run).await;
            let mut peer = AioQuic::spawn(
                "client",
                &[
                    "--ca",
                    identity.certificate(),
                    "--port",
                    &addr.port().to_string(),
                    "--datagram-frame",
                    NO_FRAME,
                    "--datagrams",
                    "0",
                    "--probe-seed",
                    &run.scenario.carried.seed.to_string(),
                    "--probe-length",
                    &run.scenario.carried.len.to_string(),
                ],
            )
            .await;

            peer.expect("handshake", run.deadline).await;
            peer.expect("connected", run.deadline).await;
            let carried = peer.expect("stream", run.deadline).await;
            peer.expect("ended", run.deadline).await;
            peer.finished(run.deadline).await;

            serving.join(&run.what, run.deadline).await;
            observed_without_datagrams(&carried).check(&run.what, &run.scenario);
            run.deadline.wait(&run.what, endpoint.wait_idle()).await;
        },
    )
    .await;
}

/// What the child said about the exchange it carried. It reports every datagram it is given as
/// an event of its own, and each role above reads its events in order, so a datagram that
/// arrived would have failed the read that follows the exchange rather than reaching here.
fn observed_without_datagrams(carried: &Event) -> UnsupportedObservation {
    UnsupportedObservation {
        datagram: None,
        carried: Some(carried.reported()),
    }
}

/// The child's own pause, as the shared backpressure case asks for it. `deaf` drops every
/// datagram at its socket, so acknowledgements stop and the transport stalls rather than only
/// its application reads.
struct Orders<'a> {
    peer: &'a mut AioQuic,
    deadline: Deadline,
    /// Whether the line the child writes when its handshake completes has been read. It says
    /// that before it takes an order, so reading it here keeps its output in step.
    greeted: bool,
}

impl Ears for Orders<'_> {
    async fn deaf(&mut self) {
        if !self.greeted {
            self.peer.expect("handshake", self.deadline).await;
            self.greeted = true;
        }
        self.peer.tell("deaf", self.deadline).await;
    }

    async fn hear(&mut self) {
        self.peer.tell("hear", self.deadline).await;
    }
}

/// Rama fills its outgoing buffer against an aioquic that has stopped reading, cancels the
/// send that has no room, and carries on once it is reading again.
#[tokio::test]
async fn backpressure_cases_rama_client() {
    backpressure(Role::RamaClient).await;
}

#[tokio::test]
async fn backpressure_cases_rama_server() {
    backpressure(Role::RamaServer).await;
}

async fn backpressure(role: Role) {
    prepare().await;
    for_each_case_within(PEER, role, backpressure_cases(), LIMIT, |run| async move {
        let identity = Identity::generate(SERVER_NAME);
        let run = run.with_identity(identity.auth.clone());
        let (mut peer, filled) = match role {
            Role::RamaClient => {
                let mut peer = AioQuic::spawn(
                    "server",
                    &[
                        "--cert",
                        identity.certificate(),
                        "--key",
                        identity.key(),
                        "--datagram-frame",
                        &FRAME.to_string(),
                        "--orders",
                    ],
                )
                .await;
                let address = peer.listening(run.deadline).await;
                let filled = rama_client_fills_and_cancels(
                    &run,
                    address,
                    &mut Orders {
                        peer: &mut peer,
                        deadline: run.deadline,
                        greeted: false,
                    },
                )
                .await;
                (peer, filled)
            }
            Role::RamaServer => {
                let endpoint = bind_backpressure_server(&run).await;
                let port = endpoint.local_addr().unwrap().port().to_string();
                let mut peer = AioQuic::spawn(
                    "backpressure-client",
                    &[
                        "--ca",
                        identity.certificate(),
                        "--port",
                        &port,
                        "--datagram-frame",
                        &FRAME.to_string(),
                    ],
                )
                .await;
                let filled = rama_server_fills_and_cancels(
                    &run,
                    endpoint,
                    &mut Orders {
                        peer: &mut peer,
                        deadline: run.deadline,
                        greeted: false,
                    },
                )
                .await;
                (peer, filled)
            }
        };

        // Read until the child has the one sent once there was room, so the connection is
        // not closed while it is still catching up, then close and read the rest. What
        // the child reports and in what order is not fixed here: datagrams are unordered
        // and the exchange may be reported among them, so each line is taken for what it
        // says.
        let mut reports = Vec::new();
        let mut carried = false;
        loop {
            let event = peer.event(&run.what, run.deadline).await;
            match event.name() {
                "datagram" => {
                    let report = event.reported();
                    let resumed = filled.sent.resumed(&report);
                    reports.push(report);
                    if resumed {
                        break;
                    }
                }
                "stream" => carried = true,
                other => panic!("{}: the child said {other} mid-case", run.what),
            }
        }
        let sent = filled.sent.clone();
        filled.close(&run.what, run.deadline).await;
        loop {
            let event = peer.event(&run.what, run.deadline).await;
            match event.name() {
                "datagram" => reports.push(event.reported()),
                "stream" => carried = true,
                "ended" => break,
                other => panic!("{}: the child said {other} as it ended", run.what),
            }
        }
        peer.finished(run.deadline).await;
        assert!(
            carried,
            "{}: the exchange after the stall was carried",
            run.what
        );
        sent.account_for(&run.what, &reports);
    })
    .await;
}
