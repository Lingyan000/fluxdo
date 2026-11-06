//! HTTP/0.9 and HTTP/3 file transfer endpoints for the QUIC interop runner.

#[cfg(feature = "boring")]
use rama::quic::tls::BoringTlsProvider;
use rama::quic::tls::{QuicClientConfigProvider, QuicServerConfigProvider, TlsOptions};
#[cfg(not(feature = "boring"))]
use rama::quic::tls::{default_server_tls_provider, default_tls_provider};
#[cfg(any(
    all(feature = "rustls-ring", feature = "rustls-aws-lc"),
    all(
        feature = "boring",
        any(feature = "rustls-ring", feature = "rustls-aws-lc")
    ),
))]
compile_error!("select exactly one Rama TLS backend: boring, rustls-ring or rustls-aws-lc");
#[cfg(not(any(feature = "boring", feature = "rustls-ring", feature = "rustls-aws-lc")))]
compile_error!("select a Rama TLS backend: boring, rustls-ring or rustls-aws-lc");

pub mod client;
mod http3;
pub mod server;

use rama::{
    error::{BoxError, ErrorContext as _},
    error_sink::TracingErrorSink,
    extensions::ExtensionsRef as _,
    net::tls::ApplicationProtocol,
    quic::{
        Connection, Endpoint, NegotiatedTlsParameters, ShutdownOutcome, TransportConfig,
        qlog::QlogConfig,
    },
    rt::Executor,
    telemetry::tracing::{
        self,
        level_filters::LevelFilter,
        subscriber::{EnvFilter, fmt, layer::SubscriberExt, util::SubscriberInitExt},
    },
    utils::octets,
};
use std::{path::Path, process::ExitCode, sync::Arc, time::Duration};

pub fn tls_options() -> TlsOptions {
    TlsOptions::default()
}

pub fn tls_provider() -> Arc<dyn QuicClientConfigProvider> {
    #[cfg(feature = "boring")]
    {
        Arc::new(BoringTlsProvider)
    }
    #[cfg(not(feature = "boring"))]
    {
        default_tls_provider().unwrap()
    }
}

pub fn server_tls_provider() -> Arc<dyn QuicServerConfigProvider> {
    #[cfg(feature = "boring")]
    {
        Arc::new(BoringTlsProvider)
    }
    #[cfg(not(feature = "boring"))]
    {
        default_server_tls_provider().unwrap()
    }
}

const ALPN: &[u8] = b"hq-interop";
const REQUEST_LIMIT: usize = octets::kib(4);
const STREAM_LIMIT: usize = 64;
/// Bytes moved per read on either side. Larger reads mean fewer trips through the connection's
/// lock and the blocking file pool, which is what bounds a client pulling many streams at once.
const BUFFER_SIZE: usize = octets::kib(256);
// Allow later PTO flights in the fifty-connection extreme-loss workload: backoff sends the
// seventh flight 63s in, and the runner counts a retried connection as an extra handshake.
const MULTICONNECT_HANDSHAKE_TIMEOUT: Duration = Duration::from_secs(90);
// The simulator's link has a 30 ms round trip; the 333 ms default delays retries.
const MULTICONNECT_INITIAL_RTT: Duration = Duration::from_millis(100);

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum TestCase {
    Handshake,
    Http3,
    Transfer,
    Retry,
    MultiConnect,
    Resumption,
    ZeroRtt,
    KeyUpdate,
    Ecn,
    ConnectionMigration,
    ChaCha20,
    /// The client starts in v1 offering v2 and the server moves the connection to v2
    /// (RFC 9368 §2.3, RFC 9369).
    V2,
}

impl TestCase {
    pub(crate) const fn alpn(self) -> &'static [u8] {
        match self {
            Self::Http3 => b"h3",
            _ => ALPN,
        }
    }

    pub fn parse(value: &str) -> Option<Self> {
        match value {
            "handshake" => Some(Self::Handshake),
            "http3" => Some(Self::Http3),
            "transfer" => Some(Self::Transfer),
            "retry" => Some(Self::Retry),
            "multiconnect" => Some(Self::MultiConnect),
            "resumption" => Some(Self::Resumption),
            "zerortt" => Some(Self::ZeroRtt),
            "keyupdate" => Some(Self::KeyUpdate),
            "ecn" => Some(Self::Ecn),
            "connectionmigration" => Some(Self::ConnectionMigration),
            "chacha20" => Some(Self::ChaCha20),
            "v2" => Some(Self::V2),
            _ => None,
        }
    }

    /// Whether this build's client can run the case. Offering a compatible version needs a TLS
    /// backend that changes version mid-handshake, which only Boring does.
    pub fn client_supported(self) -> bool {
        !matches!(self, Self::ConnectionMigration) && (self != Self::V2 || cfg!(feature = "boring"))
    }

    pub fn server_supported(self) -> bool {
        self != Self::KeyUpdate
    }
}

/// Reject unsupported cases before opening sockets or reading runner mounts.
pub fn testcase_or_exit(value: &str) -> Result<TestCase, ExitCode> {
    TestCase::parse(value).ok_or_else(|| {
        eprintln!("unsupported TESTCASE: {value}");
        ExitCode::from(127)
    })
}

pub fn init_tracing() {
    tracing::subscriber::registry()
        .with(fmt::layer().with_writer(std::io::stderr))
        .with(
            EnvFilter::builder()
                .with_default_directive(LevelFilter::INFO.into())
                .from_env_lossy(),
        )
        .init();
}

/// Set to shrink the receive windows to 64 KiB per stream and 256 KiB per connection, so a
/// transfer of any size forces stream- and connection-level window updates. The default windows
/// are Rama's own, which is what a benchmark of this endpoint should see.
pub const SMALL_WINDOWS: &str = "RAMA_INTEROP_SMALL_WINDOWS";

async fn transport(
    executor: Executor,
    role: &str,
    testcase: TestCase,
) -> Result<Arc<TransportConfig>, BoxError> {
    let mut config =
        TransportConfig::default().with_max_concurrent_bidi_streams(STREAM_LIMIT as u32);
    if testcase == TestCase::MultiConnect {
        // The idle timer also runs during the handshake, so it must not end an attempt first.
        config.set_max_idle_timeout(
            MULTICONNECT_HANDSHAKE_TIMEOUT
                .try_into()
                .context("a usable idle timeout")?,
        );
        // PTO backoff doubles (RFC 9002 6.2.1); starting near the real RTT fits more
        // retries into a peer's handshake timeout, which some peers keep at 10 s.
        config.set_initial_rtt(MULTICONNECT_INITIAL_RTT);
    }
    if testcase == TestCase::ZeroRtt && role == "client" {
        // Upstream counts every encrypted 1-RTT byte, including padded PMTU
        // probes, against its request-data budget. Keep this case at the base MTU.
        config.unset_mtu_discovery_config();
    }
    if testcase == TestCase::Http3 {
        http3::config().configure_transport(&mut config)?;
    }
    if std::env::var_os(SMALL_WINDOWS).is_some() {
        config = config
            .with_stream_receive_window(octets::kib_u32(64))
            .with_receive_window(octets::kib_u32(256));
    }
    if let Some(directory) = std::env::var_os("QLOGDIR") {
        let directory = Path::new(&directory);
        tokio::fs::create_dir_all(directory)
            .await
            .context("create qlog directory")?;
        let file = tokio::fs::File::create(directory.join(format!("rama-{role}.sqlog")))
            .await
            .context("create qlog file")?;
        config.set_qlog_recorder(
            QlogConfig::default()
                .with_writer(file)
                .with_executor(executor)
                .with_error_sink(TracingErrorSink::warn())
                .start()?,
        );
    }
    Ok(Arc::new(config))
}

/// One line of transport counters per connection, so a benchmark run shows loss and queue drops.
fn log_connection_stats(connection: &Connection) {
    let stats = connection.stats();
    tracing::info!(
        rtt_ms = stats.path.rtt.as_millis() as u64,
        cwnd = stats.path.cwnd,
        sent_packets = stats.path.sent_packets,
        lost_packets = stats.path.lost_packets,
        current_mtu = stats.path.current_mtu,
        sent_mtu_probes = stats.path.sent_plpmtud_probes,
        lost_mtu_probes = stats.path.lost_plpmtud_probes,
        congestion_events = stats.path.congestion_events,
        rx_datagrams = stats.udp_rx.datagrams,
        rx_ios = stats.udp_rx.ios,
        tx_datagrams = stats.udp_tx.datagrams,
        tx_ios = stats.udp_tx.ios,
        max_data_sent = stats.frame_tx.max_data,
        max_stream_data_sent = stats.frame_tx.max_stream_data,
        preferred_address_probes = stats.path.preferred_address_probes,
        remote_address = %connection.remote_address(),
        "connection finished"
    );
}

/// Join every transport producer before the shared shutdown drains the qlog recorder.
async fn shutdown_endpoint(
    endpoint: &Endpoint,
    outcome: Result<(), BoxError>,
) -> Result<(), BoxError> {
    let stats = endpoint.stats();
    tracing::info!(
        received_datagrams = stats.received_datagrams,
        dropped_packets = stats.dropped_packets,
        queue_peak_datagrams = stats.receive_queue.peak_datagrams,
        queue_peak_bytes = stats.receive_queue.peak_bytes,
        "endpoint finished"
    );
    match endpoint.shutdown().await {
        ShutdownOutcome::Drained => {}
        ShutdownOutcome::Forced => {
            tracing::debug!("endpoint shutdown reached its transport budget")
        }
        ShutdownOutcome::DriverFailed => {
            if outcome.is_ok() {
                return Err("endpoint driver failed during shutdown".into());
            }
            tracing::warn!("endpoint driver also failed during shutdown");
        }
    }
    outcome
}

fn check_alpn(connection: &Connection, testcase: TestCase) -> Result<(), BoxError> {
    if connection
        .extensions()
        .get_ref::<NegotiatedTlsParameters>()
        .cloned()
        .and_then(|data| data.application_layer_protocol)
        != Some(ApplicationProtocol::from(testcase.alpn()))
    {
        return Err("peer did not negotiate the testcase ALPN".into());
    }
    if testcase == TestCase::ChaCha20
        && connection
            .extensions()
            .get_ref::<NegotiatedTlsParameters>()
            .and_then(|tls| tls.algorithms.cipher_suite)
            != Some(rama::tls::CipherSuite::TLS13_CHACHA20_POLY1305_SHA256)
    {
        return Err("peer did not negotiate the required ChaCha20 cipher suite".into());
    }
    Ok(())
}

/// Runner filenames are ASCII. Reject encoded or ambiguous paths instead of decoding them.
fn relative_path(target: &str) -> Result<&Path, BoxError> {
    let relative = target
        .strip_prefix('/')
        .ok_or("request path must be absolute")?;
    if relative.is_empty() || target.len() > REQUEST_LIMIT - 6 {
        return Err("invalid request path length".into());
    }
    for segment in relative.split('/') {
        if segment.is_empty()
            || segment == "."
            || segment == ".."
            || !segment
                .bytes()
                .all(|b| b.is_ascii_alphanumeric() || matches!(b, b'-' | b'_' | b'.'))
        {
            return Err("request path contains an unsupported segment".into());
        }
    }
    Ok(Path::new(relative))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn runner_paths_are_confined() {
        assert_eq!(
            relative_path("/nested/file-1.bin").unwrap(),
            Path::new("nested/file-1.bin")
        );
        for target in [
            "",
            "/",
            "file",
            "//file",
            "/../file",
            "/a/./file",
            "/%2e%2e/file",
            "/a\\file",
            "/file?query",
            "/file\r\n",
        ] {
            assert!(relative_path(target).is_err(), "accepted {target:?}");
        }
        assert!(relative_path(&format!("/{}", "a".repeat(REQUEST_LIMIT))).is_err());
    }

    #[test]
    fn runner_paths_reserve_space_for_request_framing() {
        let framing_length = b"GET \r\n".len();
        let mut target = format!("/{}", "a".repeat(REQUEST_LIMIT - framing_length - 1));
        assert_eq!(format!("GET {target}\r\n").len(), REQUEST_LIMIT);
        assert_eq!(relative_path(&target).unwrap(), Path::new(&target[1..]));

        target.push('a');
        assert!(relative_path(&target).is_err());
    }

    #[tokio::test]
    async fn multiconnect_idle_timer_never_ends_a_handshake_first() {
        for role in ["client", "server"] {
            let config = transport(Executor::default(), role, TestCase::MultiConnect)
                .await
                .unwrap();
            assert!(config.get_max_idle_timeout() >= Some(MULTICONNECT_HANDSHAKE_TIMEOUT));
        }
    }

    #[test]
    fn unsupported_testcases_do_not_fall_back_to_transfer() {
        for value in ["", "unknown"] {
            assert_eq!(TestCase::parse(value), None);
        }
        assert_eq!(TestCase::parse("http3"), Some(TestCase::Http3));
        assert_eq!(TestCase::parse("retry"), Some(TestCase::Retry));
        assert_eq!(TestCase::parse("v2"), Some(TestCase::V2));
        for (name, testcase) in [
            ("resumption", TestCase::Resumption),
            ("zerortt", TestCase::ZeroRtt),
            ("keyupdate", TestCase::KeyUpdate),
            ("ecn", TestCase::Ecn),
            ("connectionmigration", TestCase::ConnectionMigration),
            ("chacha20", TestCase::ChaCha20),
        ] {
            assert_eq!(TestCase::parse(name), Some(testcase));
        }
    }
}
