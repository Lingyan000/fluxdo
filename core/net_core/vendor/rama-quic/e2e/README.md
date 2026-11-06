# QUIC interoperability

These standalone projects exercise Rama's QUIC client and server against
independent implementations. They live outside the main Cargo workspace.
See the [QUIC justfile](../justfile) for QA recipes and backend selection.

The Quinn, quiche, aioquic projects and runner accept `boring`, `rustls-ring`, or
`rustls-aws-lc` as their Rama backend feature. Selection is explicit even when the peer enables another TLS
implementation. The Boring runs cover both roles, including resumption, early-data
acceptance/rejection where the peer supports it, and certificate failures. An aioquic
server cannot resume while rejecting offered early data; that case remains explicitly
unsupported in the shared inventory. Boring rejects early data by changing
the transport context bound to a ticket while retaining its native ticket keys.

`just rama-quic/qa-boring-isolation` checks dependency trees, including test fixtures.
Boring runs exclude the Rustls engine, ring, and AWS-LC from Rama's dependencies.
Quinn's own Rustls peer is checked separately from Rama's dependency subtree.
The Docker runner accepts `--backend` with the same three choices.

- [Shared scenarios](interop-common/)
- [Quinn](quinn-interop/)
- [quiche](quiche-interop/)
- [aioquic](aioquic-interop/)
- [Docker interop runner](interop-runner/)
- [HTTP/3 streaming against quic-go and aioquic](http-interop/), sharing the existing
  [masque-go CONNECT-UDP peer](../../examples/tests/masque_interop/) and locked
  [aioquic environment](aioquic-interop/). aioquic exercises both roles,
  including dynamic QPACK and concurrent uploads with trailers.
- [External GnuTLS provider](gnutls-interop/): tests against aioquic with all
  built-in Rama backends disabled; `just rama-quic/qa-interop-gnutls`.

Dependency updates and root formatting include all these projects. The Go-backed
HTTP/3 and MASQUE sessions use their explicit recipes and dedicated PR CI job;
they need a built external peer and do not run in an ordinary Cargo test invocation.
The GnuTLS project is POSIX-only, as its C bridge needs GnuTLS headers and its
fixtures need `certtool`; `just rama-quic/qa-interop-gnutls` reports that it is
skipping and succeeds on Windows, so `qa-full` still runs there.

## Manual release checks

`just fuzz/quic-h3-release` runs the QUIC, HTTP/3, QPACK and capsule targets for
one hour each. Pass a duration in seconds for a shorter campaign. Keep the
corpus between runs and retain logs and `fuzz/artifacts` when a target fails.

For load checks, repeat the ignored QUIC `stress_` library tests,
`rama-quic`'s `many_connections` integration test, and the HTTP/3
`concurrent_stream_waves` library tests. Record the duration and iterations;
these are bounded local workloads, not a claim about production capacity.

The [benchmark matrix](bench/) supports manual HTTP/3 peer comparisons with
`--protocol h3`. It is not run in CI.
