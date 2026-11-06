"""Prove pinned ngtcp2 NAT-rebinding checker limitations independently.

RFC 9000 section 9.3 requires path validation, not a PATH_CHALLENGE in the
first datagram or a response to a probe lost before delivery. Keep upstream
failures visible; prove matched validation and transfer on every new NAT tuple.
"""
from pathlib import Path
import ast
import ipaddress
import re

from check_migration import PINNED_PEERS, has_non_probing_frame, has_stream, read_packets, verify_files
from check_results import InvalidResults

SERVER = ("193.167.100.100", 443)
CLIENT_IP = "193.167.0.100"
CLIENT_NETWORK = ipaddress.ip_network("193.167.0.0/24")
CASES = {"rebind-port": False, "rebind-addr": True}
# This is a conservative bound for this pinned peer's classifier, not an RFC
# limit. A longer prefix needs investigation rather than an automatic exception.
MAX_ACK_PREFIX = 4


def require(condition, message):
    if not condition:
        raise InvalidResults(f"NAT-rebinding evidence: {message}")


def verify_rebinding_packets(client_trace, server_trace, *, address_rebinding=False,
                             lost_challenges=frozenset(), ack_first_reported=False):
    """Check both sides of the NAT; frame numbers are local to each capture."""
    handshakes = []
    for trace in (client_trace, server_trace):
        require(bool(trace), "empty capture")
        numbers = [p["number"] for p in trace]
        require(numbers == sorted(set(numbers)), "capture order is ambiguous")
        require(all((p["src"] == SERVER and ipaddress.ip_address(p["dst"][0]) in CLIENT_NETWORK)
                    or (p["dst"] == SERVER and ipaddress.ip_address(p["src"][0]) in CLIENT_NETWORK) for p in trace),
                "unexpected endpoint")
        require(all(p["long_types"] or p["frames"] for p in trace), "undecoded 1-RTT packet")
        trace_handshake = []
        for from_server in (False, True):
            initials = [p for p in trace if 0 in p["long_types"]
                        and (p["src"] == SERVER) == from_server]
            cids = {cid for p in initials for cid in p["scids"]}
            require(len(cids) == 1 and bool(next(iter(cids))), "expected one client/server handshake")
            require({v for p in initials for v in p["versions"]} == {1}, "expected QUIC v1")
            trace_handshake.append(cids)
        handshakes.append(trace_handshake)
        for p in trace:
            require(bool(p["challenges"]) == (0x1a in p["frames"])
                    and bool(p["responses"]) == (0x1b in p["frames"]),
                    "incomplete path frame decoding")
            require(all(re.fullmatch(r"[0-9a-f]{16}", token)
                        for token in (*p["challenges"], *p["responses"])), "invalid path token")
            require(not (p["challenges"] if p["dst"] == SERVER else p["responses"]),
                    "unexpected client-initiated validation")
    require(handshakes[0] == handshakes[1], "captures describe different handshakes")

    local = {p["src"] for p in client_trace if p["dst"] == SERVER}
    require(len(local) == 1, "client changed its local endpoint")
    local = next(iter(local))
    require(local[0] == CLIENT_IP, "unexpected original client IP")
    require(all(p["dst"] == local for p in client_trace if p["src"] == SERVER),
            "client received traffic on another endpoint")
    incoming = [p for p in server_trace if p["dst"] == SERVER]
    paths = list(dict.fromkeys(p["src"] for p in incoming))
    require(len(paths) > 1 and paths[0] == local, "no port rebinding from the original tuple")
    require((len({path[0] for path in paths}) > 1) == address_rebinding,
            "client IP changes do not match the requested rebinding case")
    transitions = [p["src"] for i, p in enumerate(incoming)
                   if i == 0 or p["src"] != incoming[i - 1]["src"]]
    require(transitions == paths, "NAT tuple was reused or reordered")
    require({p["dst"] for p in server_trace if p["src"] == SERVER} == set(paths),
            "server/client path sets differ")
    starts = {path: next(p["number"] for p in incoming if p["src"] == path) for path in paths}
    require(all(not p["long_types"] for p in server_trace
                if (p["src"] if p["dst"] == SERVER else p["dst"]) != local),
            "new path contains another handshake")

    # Every token identifies a single server path, even if retransmitted.
    sent = {}
    for p in server_trace:
        for token in p["challenges"]:
            require(token not in sent or sent[token]["dst"] == p["dst"],
                    "challenge token reused across paths")
            sent.setdefault(token, p)
    received = {}
    answers = {}
    for p in client_trace:
        for token in p["challenges"]:
            received.setdefault(token, p)
        for token in p["responses"]:
            require(token in received and received[token]["number"] < p["number"],
                    "client responded before receiving the challenge")
            answers.setdefault(token, p)
    require(set(received) <= set(sent), "client challenge absent from server capture")
    require(set(answers) == set(received), "delivered challenge was not answered")
    validated = {}
    for p in incoming:
        for token in p["responses"]:
            require(token in sent and token in answers, "unmatched server-received response")
            require(p["src"] == sent[token]["dst"] and p["number"] > sent[token]["number"],
                    "response arrived on the wrong path or before the challenge")
            validated.setdefault(token, p["number"])
    require(set(validated) == set(received), "response did not reach the server")

    # RFC 9000 sections 8.2.1-8.2.4 allow a later challenge to validate a path
    # when an earlier probe was lost. Only classify tokens named by the pinned
    # checker, absent from the client capture, and replaced on that same path.
    require(lost_challenges <= set(sent) - set(received),
            "reported lost challenge was delivered or never sent")
    replaced = []
    for token in sorted(lost_challenges):
        probe = sent[token]
        index = paths.index(probe["dst"])
        end = starts[paths[index + 1]] if index + 1 < len(paths) else float("inf")
        replacements = [t for t in validated
                        if sent[t]["dst"] == probe["dst"]
                        and probe["number"] < sent[t]["number"] < validated[t] < end]
        require(index > 0 and bool(replacements), "lost probe has no later same-path validation")
        replacement = min(replacements, key=lambda t: validated[t])
        replaced.append({"token": token, "path": probe["dst"], "sent_at": probe["number"],
                         "replacement": replacement, "validated_at": validated[replacement]})

    dropped = []
    for token in set(sent) - set(received) - lost_challenges:
        p = sent[token]
        index = paths.index(p["dst"])
        require(index + 1 < len(paths) and p["number"] > starts[paths[index + 1]],
                "unanswered challenge on a current path")
        dropped.append({"token": token, "path": p["dst"], "sent_at": p["number"]})

    proofs = []
    ack_first = False
    for path in paths[1:]:
        outgoing = [p for p in server_trace if p["src"] == SERVER and p["dst"] == path]
        first_probe = next((i for i, p in enumerate(outgoing) if p["challenges"]), None)
        require(first_probe is not None, "server did not challenge a new path")
        prefix = outgoing[:first_probe]
        require(len(prefix) <= MAX_ACK_PREFIX, "ACK prefix exceeds reviewed bound")
        require(all(set(p["frames"]) <= {0, 2, 3} and set(p["frames"]) & {2, 3}
                    for p in prefix), "new path has more than ACK/PADDING before validation starts")
        require(outgoing[0]["number"] > starts[path], "server used a path before observing rebinding")
        ack_first |= bool(prefix)
        # Every delivered challenge must still be answered. A reported, proven
        # lost first probe can be followed by the independently matched replacement.
        delivered_probe = next((p for p in outgoing if set(p["challenges"]) & set(received)), None)
        require(delivered_probe is not None, "no challenge reached the client on the new path")
        first_tokens = tuple(t for t in delivered_probe["challenges"] if t in received)
        require(all(token in validated for token in first_tokens), "first new-path probe not answered")
        path_tokens = (*first_tokens, *(p["replacement"] for p in replaced if p["path"] == path))
        completed = max(validated[token] for token in path_tokens)
        require(any(p["src"] == path and p["number"] > completed and has_non_probing_frame(p)
                    for p in incoming), "no client non-probing progress after validation")
        require(any(has_stream(p) and p["number"] > completed for p in outgoing),
                "no stream progress after new-path validation")
        client_answered = max(answers[token]["number"] for token in path_tokens)
        require(any(p["src"] == SERVER and has_stream(p) and p["number"] > client_answered
                    for p in client_trace), "no delivered stream progress after validation")
        proofs.append({"client": path, "ack_prefix_packets": len(prefix),
                       "challenge_at": outgoing[first_probe]["number"], "validated_at": completed})
    require(not ack_first_reported or ack_first, "reported ACK-first failure has no capture proof")
    require(ack_first or replaced, "capture does not exhibit a reviewed ACK-first or lost-probe limitation")
    return {"classification": "checker-incompatible", "paths": proofs,
            "server_challenges_answered": len(validated),
            "undelivered_obsolete_path_probes": sorted(dropped, key=lambda p: p["token"]),
            "undelivered_replaced_path_probes": replaced}


def verify_rebinding(artifacts, role, peer, exits, *, peer_image, case="rebind-port"):
    require((role, peer) == ("client", "ngtcp2"), "pair has no reviewed rebinding limitation")
    require(case in CASES, "case has no reviewed rebinding limitation")
    require(peer_image == PINNED_PEERS[peer], "peer image digest has no reviewed classification")
    require((exits.get("client"), exits.get("server"), exits.get("case")) ==
            ("rama", "ngtcp2", case), "missing/mismatched Docker exit evidence")
    require(all(type(exits.get(f"{side}_exit")) is int for side in ("client", "server"))
            and exits["client_exit"] == 0 and exits["server_exit"] in (0, 137, 143),
            "client failed or server exited unexpectedly")
    directory = Path(artifacts) / "logs-rama-client/ngtcp2_rama" / case
    console = (directory / "output.txt").read_text()
    ack_first = re.search(r"First server packet on new path .* did not contain a PATH_CHALLENGE frame", console)
    lost_challenges = set()
    for line in console.splitlines():
        if "PATH_CHALLENGE without a PATH_RESPONSE" not in line:
            continue
        match = re.search(r"(?:^|\s)PATH_CHALLENGE without a PATH_RESPONSE: (.+)$", line)
        require(match is not None, "malformed missing-response report")
        try:
            tokens = ast.literal_eval(match[1])
        except (SyntaxError, ValueError) as error:
            raise InvalidResults("NAT-rebinding evidence: malformed missing-response tokens") from error
        require(isinstance(tokens, list) and bool(tokens)
                and all(isinstance(t, str) and re.fullmatch(r"(?:[0-9a-f]{2}:){7}[0-9a-f]{2}", t)
                        for t in tokens), "invalid missing-response tokens")
        lost_challenges.update(t.replace(":", "") for t in tokens)
    require(ack_first or lost_challenges, "unexpected upstream failure")
    require("Check of downloaded files succeeded" in console, "upstream did not verify the download")
    require(not re.search(r"Expected |Wrong version|File size of |Could not compare files|"
                          r"First client packet during active migration",
                          console), "console contains another upstream failure")
    keys = directory / "client/keys.log"
    require(bool(keys.read_text().strip()), "missing TLS keys")
    result = verify_rebinding_packets(read_packets(directory / "sim/trace_node_left.pcap", keys),
                                      read_packets(directory / "sim/trace_node_right.pcap", keys),
                                      address_rebinding=CASES[case],
                                      lost_challenges=lost_challenges,
                                      ack_first_reported=bool(ack_first))
    result.update(verify_files(directory, expected_size=10 * 1024 * 1024))
    result.update(role=role, peer=peer, case=case, upstream_result="failed", peer_image=peer_image)
    return result
