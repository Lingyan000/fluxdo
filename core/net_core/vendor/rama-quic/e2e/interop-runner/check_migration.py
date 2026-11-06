"""Independent evidence for the pinned runner's preferred-address limitations.

Raw upstream failures remain failures in its JSON. This checker distinguishes a
verified migration rejected by its first-packet rule from a peer that never tried
the advertised address. Neither is an upstream test success.
"""
import hashlib
import ipaddress
from pathlib import Path
import re
import subprocess

from check_results import InvalidResults

FIELDS = [
    "frame.number", "ip.src", "ipv6.src", "udp.srcport", "ip.dst", "ipv6.dst", "udp.dstport",
    "quic.dcid", "quic.path_challenge.data", "quic.path_response.data", "quic.frame_type",
    "tls.quic.parameter.preferred_address.ipv4address",
    "tls.quic.parameter.preferred_address.ipv4port",
    "tls.quic.parameter.preferred_address.ipv6address",
    "tls.quic.parameter.preferred_address.ipv6port",
    "tls.quic.parameter.preferred_address.connectionid",
    "quic.scid", "quic.version", "quic.long.packet_type", "tls.handshake.type",
]
PINNED_PEERS = {
    "quic-go": "martenseemann/quic-go-interop@sha256:da5f6d1073d1d21c67c91ea8b052024bf75e735b89c01d7fafbe58f2dbb4fc2a",
    "ngtcp2": "ghcr.io/ngtcp2/ngtcp2-interop@sha256:f50753c009aa7de1b641d713cf8d6a482e084af767f6c14c6f7f9f0ab372637b",
}
PREFERRED = {("193.167.100.100", 4433), ("fd00:cafe:cafe:100::100", 4433)}


def require(condition, message):
    if not condition:
        raise InvalidResults(f"preferred-address evidence: {message}")


def values(value):
    return tuple(part for part in value.split(",") if part)


def read_packets(capture, keys):
    # An ephemeral peer port can select another dissector (for example,
    # Manolito on 41170). Decode both the original and preferred QUIC ports.
    command = ["tshark", "-r", str(capture),
               "-d", "udp.port==443,quic", "-d", "udp.port==4433,quic",
               "-o", f"tls.keylog_file:{keys}",
               "-Y", "quic && !icmp && !icmpv6", "-T", "fields", "-E", "occurrence=a"]
    for field in FIELDS:
        command += ["-e", field]
    try:
        result = subprocess.run(command, check=True, capture_output=True, text=True, timeout=60)
        return parse_packets(result.stdout)
    except (subprocess.SubprocessError, ValueError) as error:
        raise InvalidResults(f"preferred-address capture could not be decoded: {error}") from error


def parse_packets(output):
    try:
        return _parse_packets(output)
    except (ValueError, IndexError) as error:
        raise InvalidResults(f"invalid preferred-address tshark row: {error}") from error


def _parse_packets(output):
    packets = []
    for line in output.splitlines():
        row = line.split("\t")
        require(len(row) == len(FIELDS), "unexpected tshark field count")
        def address(v4, v6, port):
            return str(ipaddress.ip_address(row[v4] or row[v6])), int(row[port])
        packets.append({
            "number": int(row[0]), "src": address(1, 2, 3), "dst": address(4, 5, 6),
            "dcids": values(row[7]), "challenges": values(row[8]), "responses": values(row[9]),
            "frames": tuple(int(value, 0) for value in values(row[10])),
            "preferred": tuple((str(ipaddress.ip_address(row[ip])), int(row[port]))
                               for ip, port in ((11, 12), (13, 14)) if row[ip] and row[port]),
            "preferred_cids": values(row[15]),
            "scids": values(row[16]), "versions": tuple(int(v, 0) for v in values(row[17])),
            "long_types": tuple(int(v, 0) for v in values(row[18])),
            "tls_types": tuple(int(v, 0) for v in values(row[19])),
        })
    require(bool(packets), "empty or undecodable capture")
    return packets


def has_stream(packet):
    return any(0x08 <= frame <= 0x0f for frame in packet["frames"])


def has_non_probing_frame(packet):
    return any(frame not in (0, 0x1a, 0x1b, 0x18) for frame in packet["frames"])


def verify_packets(client_trace, server_trace, *, peer_did_not_exercise=False,
                   allow_late_previous_path_probe=False):
    """Use both capture points; never infer peer behavior from a console message."""
    initials = [p for p in server_trace if p["src"][1] == 443 and 0 in p["long_types"]]
    require(len({cid for p in initials for cid in p["scids"]}) == 1,
            "expected exactly one server Initial SCID / handshake")
    require({v for p in initials for v in p["versions"]} == {1}, "expected QUIC v1")
    require(any(p["frames"] for p in client_trace if not p["long_types"]),
            "no decrypted 1-RTT packets")
    advertised = set()
    preferred_cids = set()
    for packet in client_trace:
        if packet["src"][1] == 443 and 8 in packet["tls_types"]:
            advertised.update(packet["preferred"])
            preferred_cids.update(packet["preferred_cids"])
    require(advertised == PREFERRED, "both expected preferred endpoints must be advertised")
    require(len(preferred_cids) == 1 and bool(next(iter(preferred_cids))), "missing/ambiguous preferred CID")
    preferred_cid = next(iter(preferred_cids))
    new_client = [p for p in client_trace if p["dst"] in advertised]
    new_server = [p for p in server_trace if p["src"] in advertised]
    if peer_did_not_exercise:
        require(not new_client and not new_server, "peer did try the preferred path")
        require(not any(p["dst"] in advertised or p["src"] in advertised for p in client_trace + server_trace),
                "unexpected preferred-path packet")
        return {"classification": "peer-did-not-exercise", "advertised": sorted(advertised),
                "preferred_cid": preferred_cid, "preferred_path_packets": 0}

    require(bool(new_client) and bool(new_server), "migration did not use the preferred path")
    first = new_client[0]
    original = [p for p in client_trace if p["number"] < first["number"] and p["dst"][1] == 443]
    require(bool(original), "missing original client path")
    require(first["dcids"] == (preferred_cid,), "first probe did not use the advertised preferred CID")
    require(preferred_cid not in original[-1]["dcids"], "migration reused the original DCID")
    require(bool(first["challenges"]) and not has_stream(first), "first client packet must validate the preferred path")
    require(not new_server[0]["challenges"] and bool(new_server[0]["responses"]),
            "first server packet does not match the known checker ordering limitation")
    matching = [p for p in client_trace if p["src"] == first["dst"] and p["dst"] == first["src"]
                and set(p["responses"]) & set(first["challenges"])]
    require(set(first["challenges"]) & set(new_server[0]["responses"]),
            "first server response did not answer the first client probe")
    require(bool(matching), "server did not answer the client's preferred-address probe")
    validated_at = matching[0]["number"]
    require(validated_at > first["number"], "invalid response ordering")
    require(not any(has_stream(p) and p["number"] < validated_at for p in new_client),
            "client sent streams on the preferred path before validation")
    require(any(p["number"] > validated_at for p in new_client), "client did not migrate after validation")
    require(any(p["src"] == first["dst"] and p["number"] > validated_at and has_stream(p)
                for p in client_trace), "no server stream traffic after validation")

    client_challenges = {(p["src"], p["dst"], token) for p in new_client for token in p["challenges"]}
    server_answers = {(p["dst"], p["src"], token) for p in server_trace for token in p["responses"]}
    require(client_challenges <= server_answers, "unanswered client preferred-address probe")
    first_challenge = next((p["number"] for p in new_server if p["challenges"]), None)
    non_probing = [p["number"] for p in new_server if has_non_probing_frame(p)]
    require(first_challenge is not None and (not non_probing or first_challenge <= min(non_probing)),
            "server sent non-probing traffic before challenging the preferred path")
    challenges = [(p["src"], p["dst"], token) for p in server_trace if p["src"][1] in (443, 4433)
                  for token in p["challenges"]]
    require(any(src == first["dst"] for src, _, _ in challenges), "server did not validate the new path")
    answered = {(p["dst"], p["src"], token) for p in client_trace for token in p["responses"]}
    unanswered = set(challenges) - answered
    previous_path_probes = []
    if unanswered:
        require(allow_late_previous_path_probe and len(unanswered) == 1,
                "server PATH_CHALLENGE without a matching path-specific response")
        src, dst, token = next(iter(unanswered))
        require(src == original[-1]["dst"] and dst == first["src"],
                "unanswered challenge is not on the previous path")
        migrated = [p["number"] for p in new_client
                    if p["number"] > validated_at and has_non_probing_frame(p)]
        observed_migration = [p["number"] for p in server_trace
                              if p["src"] == dst and p["dst"] == first["dst"] and has_non_probing_frame(p)]
        require(bool(migrated) and bool(observed_migration), "client did not send non-probing traffic after validation")
        migrated_at = min(migrated)
        sent = [p["number"] for p in server_trace
                if p["src"] == src and p["dst"] == dst and token in p["challenges"]]
        require(min(sent) > min(observed_migration), "previous-path challenge was sent before migration")
        received = [p["number"] for p in client_trace
                    if p["src"] == src and p["dst"] == dst and token in p["challenges"]]
        require(bool(received) and min(received) > migrated_at,
                "previous-path challenge was not received after migration")
        previous_path_probes.append({"server": src, "client": dst, "token": token,
                                     "sent_at": min(sent), "server_observed_migration_at": min(observed_migration),
                                     "received_at": min(received), "client_migrated_at": migrated_at})
    return {"classification": "checker-incompatible", "advertised": sorted(advertised),
            "preferred_cid": preferred_cid, "server_challenges_answered": len(set(challenges) & answered),
            "unanswered_previous_path_challenges": previous_path_probes,
            "client_preferred_packets": len(new_client), "server_preferred_packets": len(new_server)}


def verify_files(directory, *, expected_size=2 * 1024 * 1024):
    def require_transfer(condition, message):
        if not condition:
            raise InvalidResults(f"transfer evidence: {message}")

    source = directory / "server_www"
    downloaded = directory / "client_downloads"
    originals = sorted(path for path in source.iterdir() if path.is_file())
    copies = sorted(path for path in downloaded.iterdir() if path.is_file())
    require_transfer(len(originals) == len(copies) == 1, "expected one transferred file")
    require_transfer(originals[0].name == copies[0].name, "downloaded filename differs")
    require_transfer(originals[0].stat().st_size == expected_size, "incorrect workload size")
    digests = [hashlib.sha256(path.read_bytes()).hexdigest() for path in (originals[0], copies[0])]
    require_transfer(digests[0] == digests[1], "downloaded bytes differ")
    return {"file": originals[0].name, "sha256": digests[0], "bytes": originals[0].stat().st_size}


def verify_migration(artifacts, role, peer, exits, *, peer_image):
    require((role, peer) in {("client", "ngtcp2"), ("server", "ngtcp2"), ("server", "quic-go")},
            "pair has no declared runner limitation")
    require(peer_image == PINNED_PEERS.get(peer), "peer image digest has no reviewed classification")
    client, server = ("rama", peer) if role == "client" else (peer, "rama")
    require((exits.get("client"), exits.get("server"), exits.get("case")) ==
            (client, server, "connectionmigration"), "missing/mismatched Docker exit evidence")
    require(all(type(exits.get(f"{side}_exit")) is int for side in ("client", "server")),
            "missing Docker exit code")
    require(exits.get("client_exit") == 0 and exits.get("server_exit") in (0, 137, 143),
            "client failed or server exited unexpectedly")
    pair = f"{peer}_rama" if role == "client" else f"rama_{peer}"
    directory = Path(artifacts) / f"logs-rama-{role}" / pair / "connectionmigration"
    console = (directory / "output.txt").read_text()
    peer_did_not_exercise = (role, peer) == ("server", "quic-go")
    expected = ("Server saw only a single path in use; test broken?" if peer_did_not_exercise
                else "did not contain a PATH_CHALLENGE frame")
    require(expected in console, "upstream did not report the expected limitation")
    other_failures = re.findall(
        r"^\d{4}-\d\d-\d\d .*? (Expected |Wrong version|File size of |Could not compare files|"
        r"PATH_CHALLENGE without a PATH_RESPONSE|First client packet during active migration)",
        console, re.MULTILINE)
    require(not other_failures, "console contains another upstream failure")
    keys = directory / role / "keys.log"
    require(bool(keys.read_text().strip()), "missing TLS keys")
    result = verify_packets(read_packets(directory / "sim/trace_node_left.pcap", keys),
                            read_packets(directory / "sim/trace_node_right.pcap", keys),
                            peer_did_not_exercise=peer_did_not_exercise,
                            allow_late_previous_path_probe=(role, peer) == ("server", "ngtcp2"))
    result.update(verify_files(directory))
    result.update(role=role, peer=peer, case="connectionmigration", upstream_result="failed", peer_image=peer_image)
    return result
