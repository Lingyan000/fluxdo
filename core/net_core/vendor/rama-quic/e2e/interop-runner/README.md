# QUIC interop runner

Runs all 22 [upstream QUIC interop](https://github.com/quic-interop/quic-interop-runner)
case families against quic-go and ngtcp2, as both client and server: 88 outcomes
per TLS backend. Boring is the default; CI also runs Rustls/ring and Rustls/AWS-LC.
The 50-connection loss cases allow up to 90s per handshake, idle timer included, within
the 300s batch limit. They start from a 100ms RTT estimate, near the simulator's 30ms,
so retries stay within peers' handshake timeouts (10s for quic-go).

## Run

Requires Linux, macOS or WSL2, Docker Engine >=28.1, Compose >=2.36,
tshark >=4.5, uv, Git, Bash and OpenSSL >=3. Docker needs IPv6 bridges and
`NET_ADMIN`/`NET_RAW`; Linux may need `sudo modprobe ip6table_filter`.
On macOS, put Homebrew `openssl@3/bin` on `PATH`. Run serially per Docker daemon.

From the repository root:

```sh
just rama-quic/test-interop-runner
just rama-quic/test-interop-runner --backend rustls-ring
just rama-quic/test-interop-runner --group loss
```

Use `--backend rustls-aws-lc` for AWS-LC and `--platform linux/arm64` on Apple
silicon (default: `linux/amd64`). `--tests handshake,transfer,retry` selects a subset.
CI splits the full suite into `core` (14 families), `paths` (4) and `loss` (4);
[runner.lock.json](runner.lock.json) lists their cases and pins the peers.

## Images

CI publishes `glendc/rama-quic-interop` for amd64 and arm64:

| Backend | Main | Release |
| --- | --- | --- |
| Boring | `edge` | `latest`, `<release>` |
| Rustls/ring | `edge-rustls-ring` | `latest-rustls-ring`, `<release>-rustls-ring` |

To reuse a published image:

```sh
platform=linux/amd64 # linux/arm64 on Apple silicon
docker pull --platform "$platform" glendc/rama-quic-interop:edge
just rama-quic/test-interop-runner --platform "$platform" --skip-build --image glendc/rama-quic-interop:edge
```

For Rustls/ring, pull/use `edge-rustls-ring` and add `--backend rustls-ring`.
`--skip-build` uses the local image; pull again to refresh a floating tag.

## Additional coverage

```sh
just rama-quic/qa-interop-runner boring
go -C examples/tests/masque_interop/peer build -o /tmp/rama-http-peer .
just examples/tests/http3-interop /tmp/rama-http-peer boring
just examples/tests/masque-interop /tmp/rama-masque-results
```

The QA recipe checks endpoints and Python verifiers without Docker. The H3 suite
covers streaming, trailers, multiplexing, cancellation, flow control and live
dynamic/blocked QPACK. Both accept `rustls-ring` or `rustls-aws-lc` instead of `boring`.
The Boring CONNECT-UDP suite builds its peers and covers both roles, tunneled H3,
native datagrams, H1/H2/H3 capsules, authentication, target policy and interception.
Its output directory must be new.

## Results and limits

- Rustls clients cannot perform the `v2` case's mid-handshake version switch.
  Boring clients and all servers support it.
- Pinned quic-go rejects `v2` and `ecn` in both roles, and `connectionmigration`
  as server. Unsupported cases require exit 127 from the declared endpoint.
- The pinned migration checker rejects valid response-first probing; the quic-go
  client may not attempt migration. [check_migration.py](check_migration.py)
  verifies both captures, path validation, file bytes and process exits before
  classifying these separately. Neither counts as an upstream pass.
- For the pinned ngtcp2 server, the port/address-rebinding checker also rejects an ACK
  before PATH_CHALLENGE. [check_rebinding.py](check_rebinding.py) verifies the
  original captures, every new NAT tuple's challenge/response, later stream
  progress, all delivered probes, exact 10 MiB download and endpoint exits.
  Only an ACK/PADDING prefix of at most four packets qualifies; missing or
  wrong-path responses fail. Longer prefixes require investigation, and address
  rebinding must also demonstrate multiple client IPs.
  Probes to obsolete NAT mappings are recorded separately only when the client
  capture proves they were not delivered. This deterministic verification needs
  no retry and retains the raw failure as a separate checker incompatibility.
  A response that crosses another NAT change and arrives on a different tuple
  remains a failure requiring investigation, even if that timing is benign.
- Both roles use the unmerged [upstream #509 counter fix](https://github.com/quic-interop/quic-interop-runner/pull/509), pinned by commit:
  expired server state must not count one attempt twice. Rama server qlogs reject
  overlapping connections for the same attempt.
- Unexplained failures, missing outcomes or invalid qlogs fail the gate.
  Raw upstream results are preserved.
- Upstream `goodput`/`crosstraffic` measurements, CONNECT-IP and WebTransport
  are outside this suite.

Reports, captures, TLS keylogs and qlogs are retained with provenance in
`target/quic-interop/<run>/`, or a new directory supplied with `--artifacts`.
When updating pins, review the upstream adapter and verifier assumptions, then
rerun QA and the full matrix.
