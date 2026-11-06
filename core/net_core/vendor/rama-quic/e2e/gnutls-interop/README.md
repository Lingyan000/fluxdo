# GnuTLS QUIC interoperability

Tests Rama's public custom-provider API with **GnuTLS** against **aioquic 1.7.1**
over UDP in both roles. Rama enables only `quic`; no Rustls, ring, AWS-LC, or
Boring backend is enabled. GnuTLS handles TLS and packet cryptography.

The fixture uses QUIC v1, TLS 1.3, AES128-GCM/SHA256, and X25519. It covers streams,
DATAGRAM, Retry, key updates, certificate verification, and exporters.
Resumption, 0-RTT, and mutual TLS are outside its scope.

Requires GnuTLS **3.7.2+** headers/library and `certtool`, a C compiler, Rust,
`just`, and `uv`. Locally tested with GnuTLS **3.8.13**. On Debian/Ubuntu, install
`libgnutls28-dev gnutls-bin pkg-config`, then run from the repository root:

```sh
just rama-quic/qa-interop-gnutls
```

On macOS, install Homebrew `gnutls` and prefix that command with
`GNUTLS_DIR="$(brew --prefix gnutls)"`. Otherwise the build uses `pkg-config`.
On Windows the recipe reports that it is skipping and succeeds, so that `qa-full`
remains runnable; CI covers this project on Linux.
The recipe prepares the pinned aioquic environment and runs isolation checks,
formatting, Clippy, tests, and rustdoc. Certificates are generated per test.
