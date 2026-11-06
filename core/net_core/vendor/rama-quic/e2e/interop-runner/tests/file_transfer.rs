//! Subprocess checks of file transfers and TLS diagnostics, plus Unix shutdown signals.

mod common;

use common::endpoint_command;
use rama::utils::{fs::TempDir, octets};
use std::{collections::BTreeSet, fs, path::Path, process::Stdio, time::Duration};
#[cfg(unix)]
use tokio::process::Child;
use tokio::{
    io::{AsyncBufReadExt as _, AsyncReadExt as _, BufReader},
    process::Command,
};

#[tokio::test]
async fn runner_file_transfer_retry_and_http3() {
    for testcase in [
        "handshake",
        "chacha20",
        "transfer",
        "retry",
        "multiconnect",
        "http3",
        "resumption",
        "zerortt",
        "keyupdate",
        "ecn",
        "connectionmigration",
    ] {
        let directory = TempDir::with_prefix("rama-runner-smoke-").unwrap();
        let root = directory.path();
        let www = root.join("www");
        let downloads = root.join("downloads");
        fs::create_dir(&www).unwrap();
        let identity = interop_common::identity::server_identity();
        interop_common::identity::write_pem(
            &identity,
            &root.join("cert.pem"),
            &root.join("priv.key"),
        );
        let payload = vec![0x5a; octets::mib(2)];
        fs::write(www.join("large.bin"), &payload).unwrap();
        fs::write(www.join("empty.bin"), []).unwrap();
        // More than one advertised stream window catches missing MAX_STREAMS updates, and the
        // small byte windows force MAX_DATA and MAX_STREAM_DATA updates on a 2 MiB file.
        let count = if matches!(testcase, "transfer" | "http3") {
            130
        } else {
            2
        };
        let mut names = vec!["large.bin".to_owned(), "empty.bin".to_owned()];
        for index in 0..count {
            let name = format!("small-{index}.bin");
            fs::write(www.join(&name), name.as_bytes()).unwrap();
            names.push(name);
        }
        // Release the ephemeral port before the server binds its preferred socket.
        // A concurrent bind fails the server loudly; it cannot make migration pass.
        let preferred = std::net::UdpSocket::bind("127.0.0.1:0")
            .unwrap()
            .local_addr()
            .unwrap();
        let preferred_args = if testcase == "connectionmigration" {
            vec!["--preferred-address-v4".to_owned(), preferred.to_string()]
        } else {
            vec![]
        };
        let mut server = Command::from(endpoint_command(env!(
            "CARGO_BIN_EXE_rama-quic-interop-server"
        )))
        .env(
            "TESTCASE",
            if testcase == "keyupdate" {
                "transfer"
            } else {
                testcase
            },
        )
        .env(rama_quic_interop_runner::SMALL_WINDOWS, "1")
        .env("CERTS", root)
        .env("WWW", &www)
        .env("SSLKEYLOGFILE", root.join("server.keys"))
        .env("QLOGDIR", root.join("server-qlog"))
        .arg("--listen")
        .arg("[::]:0")
        .args(preferred_args)
        .stderr(Stdio::piped())
        .stdout(Stdio::null())
        .kill_on_drop(true)
        .spawn()
        .unwrap();
        let mut logs = BufReader::new(server.stderr.take().unwrap());
        let mut line = String::new();
        tokio::time::timeout(Duration::from_secs(10), logs.read_line(&mut line))
            .await
            .unwrap()
            .unwrap();
        assert!(line.contains("interop server listening"), "{line}");
        let port = line
            .split("[::]:")
            .nth(1)
            .unwrap()
            .split(|c: char| !c.is_ascii_digit())
            .next()
            .unwrap();
        let address = format!("https://127.0.0.1:{port}");
        let requests = names
            .iter()
            .map(|name| format!("{address}/{name}"))
            .collect::<Vec<_>>()
            .join(" ");
        let server_logs = tokio::spawn(async move {
            let mut output = String::new();
            logs.read_to_string(&mut output).await.unwrap();
            output
        });
        let output = tokio::time::timeout(
            Duration::from_secs(60),
            Command::from(endpoint_command(env!(
                "CARGO_BIN_EXE_rama-quic-interop-client"
            )))
            .env(
                "TESTCASE",
                if testcase == "connectionmigration" {
                    "transfer"
                } else {
                    testcase
                },
            )
            .env(rama_quic_interop_runner::SMALL_WINDOWS, "1")
            .env("REQUESTS", requests)
            .env("DOWNLOADS", &downloads)
            .env("SSLKEYLOGFILE", root.join("client.keys"))
            .env("QLOGDIR", root.join("qlog"))
            .arg("--timeout-seconds")
            .arg("45")
            .kill_on_drop(true)
            .output(),
        )
        .await
        .unwrap()
        .unwrap();
        #[cfg(unix)]
        {
            let status = signal_and_wait(&mut server, "TERM").await;
            assert_eq!(status.code(), Some(0), "server did not exit gracefully");
        }
        #[cfg(not(unix))]
        {
            // Transfers and the client's normal shutdown have finished. Terminate and reap
            // the long-running server; POSIX signal/drain assertions are covered on Unix.
            tokio::time::timeout(Duration::from_secs(15), server.kill())
                .await
                .expect("server termination completes within its deadline")
                .expect("terminate and reap server");
        }
        let server_logs = server_logs.await.unwrap();
        assert!(
            output.status.success(),
            "{testcase}: client={} server={server_logs}",
            String::from_utf8_lossy(&output.stderr)
        );
        let client_logs = String::from_utf8_lossy(&output.stderr);
        if matches!(testcase, "transfer" | "http3") {
            for counter in ["max_data_sent", "max_stream_data_sent"] {
                let value: u64 = client_logs
                    .split(&format!("{counter}="))
                    .nth(1)
                    .unwrap()
                    .split_whitespace()
                    .next()
                    .unwrap()
                    .parse()
                    .unwrap();
                assert!(value > 0, "{counter}: {client_logs}");
            }
        }
        if testcase == "connectionmigration" {
            assert!(
                client_logs
                    .split_whitespace()
                    .any(|field| field == format!("remote_address={preferred}")),
                "{client_logs}"
            );
            assert!(
                !client_logs.contains("preferred_address_probes=0"),
                "{client_logs}"
            );
        }
        for name in &names {
            assert_eq!(
                fs::read(downloads.join(name)).unwrap(),
                fs::read(www.join(name)).unwrap(),
                "{testcase}: {name}"
            );
        }
        for side in ["client", "server"] {
            let keys = fs::read_to_string(root.join(format!("{side}.keys"))).unwrap();
            assert!(
                keys.contains("CLIENT_HANDSHAKE_TRAFFIC_SECRET"),
                "{side}: missing secrets"
            );
        }
        assert_complete_qlog(&root.join("qlog/rama-client.sqlog"));
        #[cfg(unix)]
        assert_complete_qlog(&root.join("server-qlog/rama-server.sqlog"));
    }
}

#[cfg(unix)]
async fn signal_and_wait(process: &mut Child, signal: &str) -> std::process::ExitStatus {
    let id = process.id().expect("child is running");
    let status = Command::new("kill")
        .arg(format!("-{signal}"))
        .arg(id.to_string())
        .status()
        .await
        .expect("send Unix signal to our child");
    assert!(status.success());
    tokio::time::timeout(Duration::from_secs(15), process.wait())
        .await
        .expect("child shuts down within its deadline")
        .expect("wait for child")
}

fn assert_complete_qlog(path: &Path) {
    let bytes = fs::read(path).unwrap();
    assert_eq!(
        bytes.first(),
        Some(&0x1e),
        "{}: missing record separator",
        path.display()
    );
    let mut records = bytes[1..].split(|byte| *byte == 0x1e);
    let header: serde_json::Value = serde_json::from_slice(records.next().unwrap()).unwrap();
    assert!(
        header.is_object(),
        "{}: header is not an object",
        path.display()
    );
    let mut started = BTreeSet::new();
    let mut closed = BTreeSet::new();
    let mut retired = BTreeSet::new();
    let mut count = 0;
    for record in records {
        assert!(
            record.ends_with(b"\n"),
            "{}: incomplete record",
            path.display()
        );
        let event: serde_json::Value = serde_json::from_slice(record).unwrap();
        assert!(
            event.is_object(),
            "{}: event is not an object",
            path.display()
        );
        let group = event["group_id"]
            .as_str()
            .expect("event has a connection group")
            .to_owned();
        match event["name"].as_str() {
            Some("quic:connection_started") => {
                started.insert(group);
            }
            Some("quic:connection_closed") => {
                closed.insert(group);
            }
            Some("quic:connection_state_updated") if event["data"]["new"] == "closed" => {
                retired.insert(group);
            }
            _ => {}
        }
        count += 1;
    }
    assert!(count > 0, "{}: no events", path.display());
    assert!(
        !started.is_empty(),
        "{}: no connections started",
        path.display()
    );
    assert_eq!(
        started,
        closed,
        "{}: missing connection-close events",
        path.display()
    );
    assert_eq!(
        started,
        retired,
        "{}: recorder stopped before transport retirement",
        path.display()
    );
}

#[cfg(unix)]
#[tokio::test]
async fn interrupted_client_drains_qlog_and_reports_failure() {
    for signal in ["TERM", "INT"] {
        let directory = TempDir::with_prefix("rama-runner-cancel-").unwrap();
        let root = directory.path();
        // Keep a UDP receiver alive without replying: the client's handshake remains pending.
        let peer = tokio::net::UdpSocket::bind((std::net::Ipv4Addr::LOCALHOST, 0))
            .await
            .unwrap();
        let mut client = Command::from(endpoint_command(env!(
            "CARGO_BIN_EXE_rama-quic-interop-client"
        )))
        .env("TESTCASE", "transfer")
        .env(
            "REQUESTS",
            format!("https://{}/pending.bin", peer.local_addr().unwrap()),
        )
        .env("DOWNLOADS", root.join("downloads"))
        .env("QLOGDIR", root.join("qlog"))
        .stderr(Stdio::piped())
        .stdout(Stdio::null())
        .kill_on_drop(true)
        .spawn()
        .unwrap();
        let mut packet = [0_u8; octets::kib(2)];
        tokio::time::timeout(Duration::from_secs(10), peer.recv_from(&mut packet))
            .await
            .expect("client sends an Initial")
            .unwrap();
        let status = signal_and_wait(&mut client, signal).await;
        assert_eq!(
            status.code(),
            Some(1),
            "client must report interruption, not signal termination"
        );
        let mut stderr = String::new();
        client
            .stderr
            .take()
            .unwrap()
            .read_to_string(&mut stderr)
            .await
            .unwrap();
        assert!(
            stderr.contains("download batch interrupted by shutdown signal"),
            "{stderr}"
        );
        assert_complete_qlog(&root.join("qlog/rama-client.sqlog"));
    }
}
