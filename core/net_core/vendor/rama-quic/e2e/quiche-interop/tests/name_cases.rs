//! The shared server-name cases, run against quiche in both roles.
//!
//! quiche's server exposes what it received through `connection().server_name()`, so this
//! adapter reports that as well as driving Rama's own view.

mod common;

use common::{Identity, Quiche, quiche_client_config, quiche_server_config};
use interop_common::{
    CaseRun, NameObservation, NameScenario, Peer, Received, ReceivedName, Role, for_each_case,
    names::{name_cases, rama_client_side, rama_server_side},
};
use rama::utils::octets;

const PEER: &str = "quiche";
/// This adapter's no-SNI leg verifies the certificate chain but installs no address identity
/// parameter, so it does not check that the certificate carries the address. Rama's own
/// address verification runs in the other role, where Rama is the client.
const NO_IP_VERIFICATION: &str =
    "quiche's client installs no address identity parameter without also sending SNI";
const BI: u64 = 0;
const READ_CAP: usize = octets::kib(64);

/// Rama asks quiche for the case's name, or for none, and quiche reports what it received.
#[tokio::test]
async fn name_cases_rama_client() {
    for_each_case(PEER, Role::RamaClient, name_cases(), |run| async move {
        // quiche reads its identity from files, and an address case needs one valid for the
        // loopback address of the family it runs over rather than a name.
        let served = match run.scenario.asked {
            Some(name) => Identity::generate(name),
            None => Identity::generate(&run.scenario.bind.ip().to_string()),
        };
        let run = run.with_identity(served.auth.clone());
        let (addr, accepting) = Quiche::bind_server_on(
            run.scenario.bind,
            quiche_server_config(&served),
            run.deadline,
        )
        .await;
        let peer = Peer::spawn({
            let run = run.clone();
            async move {
                let mut server = accepting.await;
                quiche_answers(&run, &mut server).await
            }
        });

        rama_client_side(&run, addr).await;
        let observed = peer.join(&run.what, run.deadline).await;
        assert!(
            observed.check(&run.what, &run.scenario),
            "{}: this peer reports the name it received",
            run.what
        );
    })
    .await;
}

/// quiche asks Rama for the case's name, or for none, and Rama reports what it received.
#[tokio::test]
async fn name_cases_rama_server() {
    for_each_case(PEER, Role::RamaServer, name_cases(), |run| async move {
        // The same family-aware selection the client role uses: rama serves the address of
        // the case's family, so the certificate must carry that address and not another.
        let served = match run.scenario.asked {
            Some(name) => Identity::generate(name),
            None => Identity::generate(&run.scenario.bind.ip().to_string()),
        };
        let run = run.with_identity(served.auth.clone());
        let (endpoint, addr, serving) = rama_server_side(&run).await;
        // RFC 6066 §3: a client naming an address sends no SNI. Passing no name is that path;
        // it also installs no identity parameter, which `NO_IP_VERIFICATION` records.
        let mut client = match run.scenario.asked {
            Some(name) => {
                Quiche::connect(addr, name, quiche_client_config(&served), run.deadline).await
            }
            None => {
                Quiche::connect_without_a_name(addr, quiche_client_config(&served), run.deadline)
                    .await
            }
        };
        client
            .drive_until(&run.what, run.deadline, |connection| {
                connection.is_established()
            })
            .await;
        client
            .write_stream(BI, &run.scenario.probe.bytes(), run.deadline)
            .await;
        let back = client.read_stream(BI, READ_CAP, run.deadline).await;
        Received::Bytes(back).check(&run.what, "probe", run.scenario.probe);
        client.close(run.deadline).await;
        if run.scenario.asked.is_none() {
            // Visible with `cargo test -- --nocapture`.
            println!("{}: {NO_IP_VERIFICATION}", run.what);
        }
        serving.join(&run.what, run.deadline).await;
        run.deadline.wait(&run.what, endpoint.wait_idle()).await;
    })
    .await;
}

/// quiche's server: what it says the client asked for, and the probe answered.
async fn quiche_answers(run: &CaseRun<NameScenario>, server: &mut Quiche) -> NameObservation {
    let (what, deadline) = (&run.what, run.deadline);
    server
        .drive_until(what, deadline, |connection| connection.is_established())
        .await;
    let observed = NameObservation {
        server_name: ReceivedName::Seen(server.connection().server_name().map(str::to_owned)),
    };
    let received = server.read_stream(BI, READ_CAP, deadline).await;
    Received::Bytes(received).check(what, "probe", run.scenario.probe);
    server
        .write_stream(BI, &run.scenario.probe.bytes(), deadline)
        .await;
    server
        .drive_until(what, deadline, |connection| connection.is_closed())
        .await;
    observed
}
