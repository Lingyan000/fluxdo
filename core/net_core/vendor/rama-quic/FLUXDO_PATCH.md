# FluxDO QUIC patch

Upstream: https://github.com/plabayo/rama/tree/23d59722e125fb6f2de66df588f772205318e555/rama-quic

Cargo.toml resolves workspace inheritance to the same pinned git revision.
BoringEchConfigList (tls/factory.rs) is applied in proto/crypto/boring/config.rs before creating SSL. Use fresh peer-bound config, never generic ClientConfigCache (its identity omits ECH). No verification bypass or early data.

BoringEchObservation receives the native ssl.ech_accepted() result only after handshake completion. Each attempt uses a separate observer; no result is inferred from configuration.
