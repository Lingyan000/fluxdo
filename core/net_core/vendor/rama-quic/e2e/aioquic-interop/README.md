# aioquic interoperability

Rama's QUIC transport against [aioquic](https://github.com/aiortc/aioquic), in both roles,
through the public API of the umbrella `rama` crate only.

The project is standalone: it is not a member of the rama workspace and has its own
`Cargo.lock`, so the peer's dependencies never reach the workspace resolution. The peer is a
separate interpreter running `peer/interop_peer.py`, with its own TLS (aioquic on
`cryptography`/OpenSSL), so the only thing the two stacks share is the wire.

All client scenarios bind a concrete source in the destination's address family.
On macOS, an automatic dual-stack IPv6 port can overlap an existing IPv4 bind,
diverting replies to another test. The name cases verify the actual socket family
for IPv4 and IPv6; TLS and QUIC processing remain aioquic's.

## What is covered

`tests/interop.rs` has the handshakes, streams, the two certificate-refusal controls and the
harness's own regressions. `tests/datagram_cases.rs` has DATAGRAM in both Rama roles: the peer
advertises a small `max_datagram_frame_size`, so what limits a datagram is the value it
advertised rather than the path, and the local outgoing buffer is set small so a test can fill
it deliberately.

`tests/resumption.rs` has resumption and 0-RTT: a client that asked for early data offers it
and the server accepts it, and a client that did not ask still resumes and offers none. Early
data is opt-in in this crate, so the second is the default behaviour rather than a failure.

`tests/key_cases.rs` runs key updates in both roles, asked for from each side in turn, with
the peer's key phase read back so the counter is not the only witness, and a control where no
update is asked for. quiche exposes no key update at all. Neither peer exposes a TLS
keying-material exporter, so exporters stay covered against Quinn.

`tests/version_cases.rs` exercises v2 first-flight, compatible-upgrade and
version-restart cases in both roles against aioquic 1.7.1. Its v2 key-update
implementation is checked against RFC 9369 Appendix A.5 before running the
matrix. The old 1.2.0 exclusion is removed: neither the peer cryptography nor
Rama's randomized early key-update policy is patched for these tests.
Rustls's inability to switch version mid-handshake is reported separately.

Set `RUST_LOG=rama_quic=trace` to capture Rama's packet and recovery traces when
investigating an interoperability failure.

## Prerequisites

- A Rust toolchain.
- [`uv`](https://docs.astral.sh/uv/) on `PATH`.

`uv.lock` pins the dependency graph and `.python-version` pins the interpreter uv selects
(CPython 3.12); `pyproject.toml` requires `>=3.12,<3.13`. uv keeps its download cache and its
managed interpreters outside this directory, so what is project-local is the environment and
the resolution, not everything uv touches.

## Running

Cold, on a new checkout:

```
uv sync --frozen
cargo test --locked --features rustls-ring
```

Select `boring`, `rustls-ring`, or `rustls-aws-lc` for Rama. The aioquic peer always
uses its own Python TLS implementation. Boring runs the same scenarios, including
both-role resumption and certificate failures. Early stream delivery may precede
the handshake event; tests require both events without imposing their order.

Warm, once `.venv` exists:

```
cargo test --locked --features rustls-ring
```

The test harness runs `uv sync --frozen` itself, once per test binary and under a five-minute
bound of its own, so the second form works either way; running it explicitly only keeps a cold
install out of the test run. The frozen sync reconciles stale environments against the lockfile;
an import probe then reports Python and aioquic's versions for diagnostics. The harness does
not duplicate those version pins in Rust. Nothing is skipped when a prerequisite is absent: a missing `uv` fails the
run with the command to fix it.

CI runs these for each backend through `just rama-quic/qa-interop-aioquic BACKEND`, in the
`test-quic-interop-qa` job. The project is not part of the workspace, so `cargo test` at the
repository root does not reach it.

The controlled-child tests around the setup runner use `kill -0` and are compiled on Unix
hosts only.
