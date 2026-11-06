# Browser first-flight fixtures

Raw UDP payloads of the first two Initial datagrams each browser sent to
`www.cloudflare.com` over IPv6, captured with tshark 4.6.6 on macOS on 2026-09-16:

- `chrome-153-initial-*.hex`: Google Chrome 153.0.8010.48, fresh profile.
- `firefox-156-initial-*.hex`: Firefox 156.0, fresh profile, with
  `network.http.http3.version_negotiation.enabled` set.

Each file is one datagram as hex. The tests in `src/profile/tests/mod.rs` read them back with
`profile::capture` and check the browser profiles against them.

The `rama-standard-initial-*.hex` files are our own loopback test client flight,
produced on 2026-10-09 with the default Rustls/ring client configuration. They
contain no customer traffic. They pin the protected packet bytes for passive
observer regression; `rama-standard-first-flight.json` pins the decoded summary.
Live ClientHello randomness is deliberately not compared byte-for-byte with this
single sample. The live profile tests separately check the configured wire shape.

`chrome-155-initial-*.hex` are two owned loopback datagrams from Chrome 155's
shared browser journey against `rama serve fp`, captured on 2026-10-17. They
contain Initial packets only. Their packet numbers are 1 and 2, encoded on one
and two bytes respectively. This pins actual packet-number widths independently
of their numeric values; replay must not infer the second width from the first.
No customer traffic or TLS key log is included.

`safari-26.5-initial-*.hex` are Safari 26.5.2's first two client Initial UDP
payloads from the local credential-free fp journey on macOS, captured with
tshark 4.6.6 on 2026-10-22. They contain no application traffic or TLS key log.
The replay regression verifies the optional version-information omission and
Safari's advertised capacity for 64 peer connection IDs against native output.
