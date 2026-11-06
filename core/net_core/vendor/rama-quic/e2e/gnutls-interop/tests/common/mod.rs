use rama::{extensions::ExtensionsRef as _, quic::NegotiatedTlsParameters};
use rama::{
    quic::{Connection, Endpoint},
    rt::Executor,
    utils::fs::{TempDir, tempdir},
};
use rama_quic_gnutls_interop::{Client, Server};
use serde_json::Value;
use std::{future::IntoFuture, net::SocketAddr, path::PathBuf, process::Stdio, time::Duration};
use tokio::{
    io::{AsyncBufReadExt, BufReader, Lines},
    process::{Child, ChildStdout, Command},
};

pub const ALPN: &str = "rama-gnutls-interop";
pub const LIMIT: Duration = Duration::from_secs(30);

pub async fn within<T>(future: impl IntoFuture<Output = T>) -> T {
    tokio::time::timeout(LIMIT, future.into_future())
        .await
        .expect("interop deadline")
}

pub fn localhost() -> SocketAddr {
    SocketAddr::from((std::net::Ipv4Addr::LOCALHOST, 0))
}

pub fn payload(seed: u8, size: usize) -> Vec<u8> {
    (0..size).map(|i| (i % 251) as u8 ^ seed).collect()
}

pub struct Identity {
    pub _directory: TempDir,
    pub ca: String,
    pub certificate: String,
    pub key: String,
}

impl Identity {
    pub fn generate() -> Self {
        let directory = tempdir().unwrap();
        let file = |name: &str| directory.path().join(name).to_str().unwrap().to_owned();
        let ca = file("ca.pem");
        let ca_key = file("ca.key");
        let certificate = file("leaf.pem");
        let key = file("leaf.key");
        let root_template = file("root.cfg");
        let leaf_template = file("leaf.cfg");
        std::fs::write(
            &root_template,
            "cn = Rama interop root\nca\ncert_signing_key\nexpiration_days = 2\n",
        )
        .unwrap();
        std::fs::write(&leaf_template, "cn = localhost\ndns_name = localhost\nip_address = 127.0.0.1\ntls_www_server\nsigning_key\nexpiration_days = 1\n").unwrap();
        let certtool = std::env::var_os("GNUTLS_CERTTOOL")
            .map(PathBuf::from)
            .unwrap_or_else(|| {
                if let Some(prefix) = std::env::var_os("GNUTLS_DIR") {
                    for name in ["certtool", "gnutls-certtool"] {
                        let path = PathBuf::from(&prefix).join("bin").join(name);
                        if path.exists() {
                            return path;
                        }
                    }
                }
                PathBuf::from("certtool")
            });
        let run = |args: &[&str]| {
            let output = std::process::Command::new(&certtool)
                .args(args)
                .output()
                .expect("install GnuTLS certtool");
            assert!(
                output.status.success(),
                "certtool: {}",
                String::from_utf8_lossy(&output.stderr)
            );
        };
        // RSA: about half the EC keys certtool 3.8.3 (Ubuntu 24.04) writes are refused by
        // pyca/cryptography 50 on the aioquic side ("private key value is too short").
        for output in [&ca_key, &key] {
            run(&[
                "--generate-privkey",
                "--key-type",
                "rsa",
                "--bits",
                "2048",
                "--outfile",
                output,
            ]);
        }
        run(&[
            "--generate-self-signed",
            "--load-privkey",
            &ca_key,
            "--template",
            &root_template,
            "--outfile",
            &ca,
        ]);
        run(&[
            "--generate-certificate",
            "--load-privkey",
            &key,
            "--load-ca-certificate",
            &ca,
            "--load-ca-privkey",
            &ca_key,
            "--template",
            &leaf_template,
            "--outfile",
            &certificate,
        ]);
        Self {
            _directory: directory,
            ca,
            certificate,
            key,
        }
    }

    pub fn client(&self) -> rama::quic::ClientConfig {
        Client {
            ca: self.ca.clone(),
            alpn: ALPN.as_bytes().to_vec(),
        }
        .config()
    }

    pub fn server(&self) -> rama::quic::ServerConfig {
        Server {
            certificate: self.certificate.clone(),
            key: self.key.clone(),
            alpn: ALPN.as_bytes().to_vec(),
        }
        .config()
        .unwrap()
    }
}

pub async fn client_endpoint() -> Endpoint {
    Endpoint::bind_client(Executor::new(), localhost())
        .await
        .unwrap()
}

pub async fn exchange(connection: &Connection, bytes: &[u8]) {
    let (mut send, mut recv) = within(connection.open_bi()).await.unwrap();
    within(send.write_all(bytes)).await.unwrap();
    send.finish().unwrap();
    assert_eq!(
        within(recv.read_to_end(bytes.len() + 1)).await.unwrap(),
        bytes
    );
}

pub fn metadata(connection: &Connection, client: bool) {
    let data = connection
        .extensions()
        .get_ref::<NegotiatedTlsParameters>()
        .cloned()
        .expect("TLS metadata");
    assert_eq!(data.protocol_version, rama::tls::ProtocolVersion::TLSv1_3);
    assert_eq!(
        data.application_layer_protocol.unwrap().as_bytes(),
        ALPN.as_bytes()
    );
    assert_eq!(data.resumed, Some(false));
    assert!(
        data.server_hello.is_none(),
        "fixture must not invent ServerHello observations"
    );
    if client {
        assert!(
            !connection
                .extensions()
                .get_ref::<NegotiatedTlsParameters>()
                .and_then(|tls| tls.peer_certificate_chain.clone())
                .expect("verified server certificate")
                .is_empty()
        );
    }
}

pub struct Peer {
    pub child: Child,
    pub lines: Lines<BufReader<ChildStdout>>,
    pub events: Vec<Value>,
}

impl Peer {
    pub fn spawn(role: &str, arguments: &[&str]) -> Self {
        let project = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../aioquic-interop");
        let python = std::env::var_os("GNUTLS_PEER_PYTHON")
            .map(PathBuf::from)
            .unwrap_or_else(|| project.join(".venv/bin/python"));
        let mut child = Command::new(python)
            .arg("-u")
            .arg(project.join("peer/interop_peer.py"))
            .arg(role)
            .args(["--alpn", ALPN])
            .args(arguments)
            .stdout(Stdio::piped())
            .stderr(Stdio::inherit())
            .kill_on_drop(true)
            .spawn()
            .expect("prepare the pinned aioquic environment with uv sync --frozen");
        let lines = BufReader::new(child.stdout.take().unwrap()).lines();
        Self {
            child,
            lines,
            events: Vec::new(),
        }
    }

    pub async fn event(&mut self, name: &str) -> Value {
        loop {
            // A peer that fails before the awaited event reports it as its last line; show
            // that report instead of a bare end of output.
            let Some(line) = within(self.lines.next_line()).await.unwrap() else {
                panic!(
                    "peer output ended before the {name:?} event; events seen: {:?}",
                    self.events
                );
            };
            let event: Value = serde_json::from_str(&line).unwrap();
            self.events.push(event.clone());
            if event["event"] == name {
                return event;
            }
        }
    }

    pub async fn listening(&mut self) -> SocketAddr {
        let event = self.event("listening").await;
        SocketAddr::from((
            [127, 0, 0, 1],
            u16::try_from(event["port"].as_u64().unwrap()).unwrap(),
        ))
    }

    pub async fn finish(&mut self) {
        while let Some(line) = within(self.lines.next_line()).await.unwrap() {
            self.events.push(serde_json::from_str(&line).unwrap());
        }
        assert!(within(self.child.wait()).await.unwrap().success());
    }

    pub fn observed(&self, name: &str, bytes: &[u8]) {
        use sha2::{Digest, Sha256};
        let hash = Sha256::digest(bytes)
            .iter()
            .map(|byte| format!("{byte:02x}"))
            .collect::<String>();
        assert!(
            self.events.iter().any(|event| event["event"] == name
                && event["len"] == bytes.len()
                && event["sha256"] == hash),
            "peer must report {name} length and digest: {:?}",
            self.events
        );
    }
}
