//! Exit statuses are part of the runner's supported-case discovery protocol.

mod common;

use common::endpoint_command;

#[test]
fn testcase_probe_needs_neither_mounts_nor_network() {
    for binary in [
        env!("CARGO_BIN_EXE_rama-quic-interop-client"),
        env!("CARGO_BIN_EXE_rama-quic-interop-server"),
    ] {
        let is_server = binary == env!("CARGO_BIN_EXE_rama-quic-interop-server");
        for testcase in [
            "handshake",
            "transfer",
            "retry",
            "multiconnect",
            "http3",
            "resumption",
            "zerortt",
            "keyupdate",
            "ecn",
            "connectionmigration",
            "chacha20",
        ] {
            let status = endpoint_command(binary)
                .arg("--check-testcase")
                .env("TESTCASE", testcase)
                .status()
                .unwrap();
            let supported = match testcase {
                "keyupdate" => !is_server,
                "connectionmigration" => is_server,
                _ => true,
            };
            assert_eq!(
                status.code(),
                Some(if supported { 0 } else { 127 }),
                "{binary}: {testcase}"
            );
        }
        for testcase in ["unknown", "", "not-a-test"] {
            let status = endpoint_command(binary)
                .arg("--check-testcase")
                .env("TESTCASE", testcase)
                .status()
                .unwrap();
            assert_eq!(status.code(), Some(127), "{binary}: {testcase}");
        }
        // The server advertises v2 on any backend (it is the moved-to side); the client can only
        // run it with a version-switching TLS backend (Boring), so it is unsupported otherwise.
        let v2_expected = if is_server || cfg!(feature = "boring") {
            0
        } else {
            127
        };
        let status = endpoint_command(binary)
            .arg("--check-testcase")
            .env("TESTCASE", "v2")
            .status()
            .unwrap();
        assert_eq!(status.code(), Some(v2_expected), "{binary}: v2");
    }
}
